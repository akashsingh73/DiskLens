import SwiftUI
import AppKit
import os

/// Live numbers for the scan in progress. Kept apart from AppModel so the four-times-a-second
/// updates redraw only the progress panel, not the whole window. Main thread only.
final class ScanStatus: ObservableObject {
    @Published var snapshot = ScanProgress.Snapshot()
    @Published var elapsed: TimeInterval = 0
}

/// App state: the current scan, where the user is, navigation history, and scan control.
/// Everything here runs on the main thread; the scan itself runs on background threads.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var result: ScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var scanningName = ""
    /// The folder (or "[Files]" entry) shown in the right-hand views.
    @Published private(set) var selection: Node?
    /// Changes whenever the folder tree should expand down to `selection` and scroll to it.
    @Published private(set) var revealToken = 0
    /// Bumped whenever the tree changes after a scan (for example after moving something to the Trash).
    @Published private(set) var version = 0
    @Published private(set) var history: [HistoryEntry] = []
    /// The latest scan of each folder scanned before, newest first (shown before the first scan).
    @Published private(set) var recentScans: [HistoryEntry] = HistoryStore.recent()
    @Published private(set) var backStack: [Node] = []
    @Published private(set) var forwardStack: [Node] = []
    /// The folder shown before the current one. After going up, Details highlights the folder
    /// you came out of, the way Finder does.
    private(set) var cameFrom: Node?
    @Published var fullDiskAccess = FullDiskAccess.isGranted
    @Published var showingError = false
    @Published private(set) var errorText = ""
    @Published var showingUnreadable = false
    /// The folder being moved to the Trash, while its files are counted for File Types and Ages.
    @Published private(set) var trashingName: String?
    /// A file Details should select once it lists the folder being shown (a search result).
    @Published private(set) var fileToHighlight: String?

    let status = ScanStatus()
    let search = SearchModel()

    init() {
        search.app = self
    }

    private var activeProgress: ScanProgress?
    private var pollTask: Task<Void, Never>?
    private var scanActivity: NSObjectProtocol?
    private var mouseMonitor: Any?
    private static let historyLimit = 500

    struct Target: Identifiable {
        let title: String
        let systemImage: String
        let path: String
        var id: String { path }
    }

    static let quickTargets: [Target] = [
        Target(title: "Home Folder", systemImage: "house", path: NSHomeDirectory()),
        Target(title: "Applications", systemImage: "square.grid.2x2", path: "/Applications"),
        Target(title: FileManager.default.displayName(atPath: "/"), systemImage: "internaldrive", path: "/"),
    ]

    // MARK: - Scanning

    func scan(path requested: String) {
        guard !isScanning else { return }
        let target = Self.resolve(requested)
        let progress = ScanProgress()
        let started = Date()
        let path = target.path
        let name = target.displayName
        let topCount = Prefs.topFilesCountValue

        search.scanStarted()
        activeProgress = progress
        isScanning = true
        scanningName = name
        status.snapshot = ScanProgress.Snapshot()
        status.elapsed = 0
        showingError = false
        fullDiskAccess = FullDiskAccess.isGranted
        // Keeps macOS from slowing the scan down while DiskLens is in the background.
        scanActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Scanning a folder")
        Log.scan.info("Scan started: \(path, privacy: .public)")

        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.activeProgress === progress else { return }
                self.status.snapshot = progress.read()
                self.status.elapsed = Date().timeIntervalSince(started)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ScanEngine.scan(path: path, displayName: name, topCount: topCount, progress: progress)
            Task { @MainActor [weak self] in
                self?.finish(outcome, progress: progress)
            }
        }
    }

    func rescan() {
        guard let path = result?.rootPath else { return }
        scan(path: path)
    }

    func cancel() {
        activeProgress?.cancel()
    }

    func chooseFolder() {
        guard !isScanning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or disk to scan"
        if panel.runModal() == .OK, let url = panel.url {
            scan(path: url.path)
        }
    }

    private func finish(_ outcome: ScanOutcome, progress: ScanProgress) {
        guard progress === activeProgress else { return }
        pollTask?.cancel()
        pollTask = nil
        activeProgress = nil
        isScanning = false
        if let activity = scanActivity {
            ProcessInfo.processInfo.endActivity(activity)
            scanActivity = nil
        }

        switch outcome {
        case .cancelled:
            Log.scan.info("Scan cancelled")
        case .failed(let message):
            Log.scan.error("Scan failed: \(message, privacy: .public)")
            errorText = message
            showingError = true
        case .finished(let newResult):
            install(newResult)
        }
    }

    private func install(_ newResult: ScanResult) {
        let root = newResult.root
        let seconds = newResult.duration
        let unreadable = newResult.unreadableFolders
        Log.scan.info("Scan finished: \(root.fileCount) files, \(root.folderCount) folders, \(unreadable) unreadable, \(seconds, format: .fixed(precision: 1)) s")

        // Rescanning the same folder keeps your place.
        var keepPath: String?
        if let old = result, old.rootPath == newResult.rootPath, let current = selection {
            keepPath = current.directory.path
        }

        result = newResult
        search.scanChanged()
        backStack.removeAll()
        forwardStack.removeAll()
        cameFrom = nil
        fileHighlightHandled()
        if let keepPath, let node = root.descendant(atPath: keepPath) {
            selection = node
        } else {
            selection = root
        }
        revealToken += 1
        version += 1

        HistoryStore.append(HistoryEntry(path: newResult.rootPath, date: newResult.started,
                                         size: root.size, allocated: root.allocated, files: root.fileCount))
        history = HistoryStore.entries(for: newResult.rootPath)
        recentScans = HistoryStore.recent()
    }

    /// The folder to scan for a path the user picked, and the name to show for it.
    /// Symbolic links are followed, and a dropped file scans the folder it is in.
    /// Since macOS 10.15 the startup disk is two volumes and "/" shows the data volume through
    /// firmlinks; scanning the data volume counts every user byte exactly once.
    static func resolve(_ requested: String) -> (path: String, displayName: String) {
        var path = canonicalPath(requested)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = (path as NSString).deletingLastPathComponent
        }
        let dataVolume = "/System/Volumes/Data"
        if path == "/" || path == dataVolume {
            var dataIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dataVolume, isDirectory: &dataIsDirectory), dataIsDirectory.boolValue {
                return (dataVolume, FileManager.default.displayName(atPath: "/"))
            }
            return ("/", FileManager.default.displayName(atPath: "/"))
        }
        return (path, FileManager.default.displayName(atPath: path))
    }

    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { selection?.parent != nil }

    /// Shows a folder and remembers where the user came from, for Back.
    /// `reveal` also expands the folder tree down to it. `file` (a path in that folder) is selected
    /// in Details once it lists the folder.
    func navigate(to node: Node, reveal: Bool = true, highlightingFile file: String? = nil) {
        guard belongsToCurrentScan(node) else { return }
        if fileToHighlight != file { fileToHighlight = file }
        if let current = selection, current !== node {
            cameFrom = current
            backStack.append(current)
            if backStack.count > Self.historyLimit {
                backStack.removeFirst(backStack.count - Self.historyLimit)
            }
            forwardStack.removeAll()
        }
        selection = node
        if reveal { revealToken += 1 }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        fileHighlightHandled()
        cameFrom = selection
        if let current = selection { forwardStack.append(current) }
        selection = target
        revealToken += 1
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        fileHighlightHandled()
        cameFrom = selection
        if let current = selection { backStack.append(current) }
        selection = target
        revealToken += 1
    }

    /// Details calls this once it has selected (or given up on) `fileToHighlight`.
    func fileHighlightHandled() {
        if fileToHighlight != nil { fileToHighlight = nil }
    }

    /// Goes to the folder that contains the current one.
    func goUp() {
        guard let parent = selection?.parent else { return }
        navigate(to: parent)
    }

    func goToTop() {
        guard let root = result?.root else { return }
        navigate(to: root)
    }

    /// Lets the back and forward buttons on a mouse move through the folder history.
    func installMouseNavigation() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            let handled: Bool = MainActor.assumeIsolated {
                let button = event.buttonNumber
                guard button == 3 || button == 4, let self, self.result != nil, !self.isScanning else { return false }
                if button == 3 { self.goBack() } else { self.goForward() }
                return true
            }
            return handled ? nil : event
        }
    }

    private func belongsToCurrentScan(_ node: Node) -> Bool {
        guard let root = result?.root else { return false }
        return node === root || node.isInside(root)
    }

    // MARK: - Trash

    /// Moves a folder to the Trash and takes it out of the scan, including the File Types and
    /// Ages totals. Those come from the folder's files, which are read again while the user
    /// answers the confirmation (the scan keeps only folder totals), using the scan's rules.
    func trash(node: Node) {
        guard trashingName == nil, node.kind == .directory, node.parent != nil,
              let scan = result, belongsToCurrentScan(node) else {
            NSSound.beep()
            return
        }
        let path = node.path
        let folders = FileTally.folders(in: node, path: path)
        let now = scan.scanTime
        let reading = ScanProgress()
        let counting = Task.detached(priority: .userInitiated) {
            FileTally.read(folders, now: now, progress: reading)
        }
        guard FileActions.confirmTrash(path: path, sizeText: SizeFormat.bytes(node.allocated)) else {
            reading.cancel()
            return
        }
        trashingName = node.name
        Task { @MainActor in
            let tally = await counting.value
            trashingName = nil
            guard FileActions.moveToTrash(path: path) else { return }
            Log.files.info("Moved folder to Trash: \(path, privacy: .public)")
            // A rescan may have replaced the tree while the files were being counted.
            guard result === scan, let parent = node.parent, belongsToCurrentScan(node) else { return }
            if let current = selection, current === node || current.isInside(node) {
                selection = parent
            }
            backStack.removeAll { $0 === node || $0.isInside(node) }
            forwardStack.removeAll { $0 === node || $0.isInside(node) }
            if let previous = cameFrom, previous === node || previous.isInside(node) {
                cameFrom = nil
            }
            parent.removeChild(node)
            scan.topFiles.removeAll { $0.path.hasPrefix(path + "/") }
            scan.remove(tally)
            scan.hardLinkDuplicates = max(0, scan.hardLinkDuplicates - node.uncountedLinksBelow)
            version += 1
        }
    }

    /// Moves one file to the Trash and takes it out of the scan. `uncountedLink` is set for a hard
    /// link whose space the scan counted through another link: the totals don't change for it.
    func trashFile(path: String, size: Int64, allocated: Int64, modified: Int64, uncountedLink: FileKey? = nil) {
        guard trashingName == nil else {
            NSSound.beep()
            return
        }
        guard FileActions.confirmTrash(path: path, sizeText: SizeFormat.bytes(allocated),
                                       extraHardLink: uncountedLink != nil),
              FileActions.moveToTrash(path: path) else { return }
        Log.files.info("Moved file to Trash: \(path, privacy: .public)")
        let folderPath = (path as NSString).deletingLastPathComponent
        if let scan = result, let folder = scan.root.descendant(atPath: folderPath) {
            if let key = uncountedLink {
                folder.forgetUncountedLink(key)
                scan.hardLinkDuplicates = max(0, scan.hardLinkDuplicates - 1)
            } else {
                folder.removeOwnFile(size: size, allocated: allocated)
                var tally = FileTally()
                tally.add(ext: NameTools.fileExtension(of: (path as NSString).lastPathComponent),
                          size: size, allocated: allocated, modified: modified, now: scan.scanTime)
                scan.remove(tally)
                if folder.ownFileCount == 0 {
                    // The folder's "[Files]" entry is gone: don't leave anything pointing at it.
                    if let current = selection, current.kind == .files, current.parent === folder {
                        selection = folder
                    }
                    backStack.removeAll { $0.kind == .files && $0.parent === folder }
                    forwardStack.removeAll { $0.kind == .files && $0.parent === folder }
                }
            }
        }
        result?.topFiles.removeAll { $0.path == path }
        version += 1
    }

    // MARK: - Volume

    struct VolumeInfo {
        let total: Int64
        let available: Int64
    }

    var volumeInfo: VolumeInfo? {
        guard let path = result?.rootPath else { return nil }
        return Self.volumeInfo(at: path)
    }

    /// Size and free space of the disk that holds `path`.
    static func volumeInfo(at path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        return VolumeInfo(total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
