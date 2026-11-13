import SwiftUI
import AppKit
import os

/// Live numbers for the scan in progress. Kept apart from AppModel so the four-times-a-second
/// updates redraw only the progress panel, not the whole window. Main thread only.
final class ScanStatus: ObservableObject {
    @Published var snapshot = ScanProgress.Snapshot()
    @Published var elapsed: TimeInterval = 0
    /// Roughly how much space the scan will find, for a progress percentage: the last scan of
    /// the same folder, or the space in use when scanning a whole disk. nil when unknown.
    @Published var expected: Int64?

    /// How far the scan has got (0…0.99), or nil when there is nothing to measure it against.
    var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(0.99, Double(snapshot.bytes) / Double(expected))
    }
}

/// How far reading the folders only in the cloud has got, after a scan. Kept apart from AppModel,
/// like ScanStatus, so its twice-a-second updates redraw only the strip that shows them.
/// Main thread only.
final class CloudReadStatus: ObservableObject {
    struct Progress: Equatable {
        var total = 0
        var done = 0
        /// The folders being read right now, longest-running first.
        var reading: [String] = []
    }

    @Published fileprivate(set) var progress = Progress()
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
    /// Earlier scans the current one can be compared with, newest first (see `SnapshotStore.record`).
    /// nil while they're being read, just after a scan.
    @Published private(set) var comparisonBases: [FolderSnapshot]?
    /// Which of `comparisonBases` the changes are measured against.
    @Published var comparisonIndex = 0 {
        didSet { refreshChanges() }
    }
    /// Which folders grew or shrank since that earlier scan. nil when there's nothing to compare with.
    @Published private(set) var changes: FolderComparison?
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
    @Published private(set) var errorTitle = "Couldn't scan"
    @Published var showingUnreadable = false
    /// The folder being moved to the Trash, while its files are counted for File Types and Ages.
    @Published private(set) var trashingName: String?
    /// A file Details should select once it lists the folder being shown (a search result).
    @Published private(set) var fileToHighlight: String?

    /// Folders that were only in the cloud are being read, after a scan (how far: `cloud`).
    @Published private(set) var isReadingCloud = false
    let cloud = CloudReadStatus()

    /// Size and free space of the scanned disk, and of the startup disk (for the welcome screen).
    /// Each lookup takes several milliseconds, so they are made in the background when something
    /// changes the disk (a scan, a move to the Trash) rather than whenever the window redraws.
    @Published private(set) var volume: VolumeInfo?
    @Published private(set) var startupVolume: VolumeInfo?
    private var volumeTask: Task<Void, Never>?

    /// While the tree is still changing (a scan, or cloud folders being read after it), things
    /// that rely on it staying put, like Move to Trash and search, wait.
    var isReadingTree: Bool { isScanning || isReadingCloud }
    /// The scan on screen is the one still being read (its tree is filling in).
    var isShowingLiveScan: Bool { isScanning && result != nil && result === liveScan }

    let status = ScanStatus()
    let search = SearchModel()

    init() {
        search.app = self
        refreshVolumes()
    }

    private var activeProgress: ScanProgress?
    private var pollTask: Task<Void, Never>?
    private var scanActivity: NSObjectProtocol?
    /// The scan shown while it is still being read (its tree fills in as folders finish).
    private var liveScan: ScanResult?
    private var lastRedraw = Date.distantPast
    private var needsRedraw = false
    /// Where the user was, to go back there when a rescan of the same folder finishes.
    private var placeToKeep: String?
    private var cloudProgress: ScanProgress?
    private var cloudPoll: Task<Void, Never>?
    private var cloudActivity: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var snapshotTask: Task<Void, Never>?
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

    /// Scans a folder. The tree appears as soon as the first two levels are read (a fraction of a
    /// second); the folders below fill in as they finish, then any folders only in the cloud are
    /// read in the background (unless Settings says to skip them).
    func scan(path requested: String) {
        guard !isScanning else { return }
        stopReadingCloud()
        let target = Self.resolve(requested)
        let progress = ScanProgress()
        let inbox = ScanInbox()
        let started = Date()
        let path = target.path
        let name = target.displayName
        let topCount = Prefs.topFilesCountValue

        search.scanStarted()
        activeProgress = progress
        liveScan = nil
        isScanning = true
        scanningName = name
        status.snapshot = ScanProgress.Snapshot()
        status.elapsed = 0
        status.expected = Self.expectedSize(of: path)
        showingError = false
        fullDiskAccess = FullDiskAccess.isGranted
        // Rescanning the same folder keeps your place once the scan gets there.
        placeToKeep = nil
        if let old = result, old.rootPath == path, let current = selection {
            placeToKeep = current.directory.path
        }
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
                if let scan = self.liveScan { self.fillIn(from: inbox, into: scan, redrawEvery: 0.5) }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = ScanEngine.stream(path: path, displayName: name, topCount: topCount, progress: progress,
                                            showTree: { tree in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.show(tree, progress: progress) }
                }
            }, deliver: { inbox.add($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(outcome, progress: progress, inbox: inbox) }
            }
        }
    }

    /// The first two levels are read: show the tree, with the folders below still to come.
    private func show(_ tree: ScanResult, progress: ScanProgress) {
        guard progress === activeProgress else { return }
        liveScan = tree
        install(tree)
    }

    /// Adds the folders that finished since last time to the tree on screen. Redraws at most
    /// every `redrawEvery` seconds: each redraw rebuilds the tree's rows and the views.
    private func fillIn(from inbox: ScanInbox, into scan: ScanResult, redrawEvery interval: TimeInterval) {
        let pieces = inbox.takeAll()
        if !pieces.isEmpty, scan.fillIn(pieces) > 0 {
            needsRedraw = true
        }
        guard needsRedraw, result === scan, Date().timeIntervalSince(lastRedraw) >= interval else { return }
        needsRedraw = false
        lastRedraw = Date()
        version += 1
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

    private func finish(_ outcome: ScanOutcome, progress: ScanProgress, inbox: ScanInbox) {
        guard progress === activeProgress else { return }
        pollTask?.cancel()
        pollTask = nil
        activeProgress = nil
        if let activity = scanActivity {
            ProcessInfo.processInfo.endActivity(activity)
            scanActivity = nil
        }
        let scan = liveScan
        liveScan = nil
        if let scan { fillIn(from: inbox, into: scan, redrawEvery: 0) }
        isScanning = false

        switch outcome {
        case .cancelled:
            Log.scan.info("Scan stopped")
            // What was read so far stays on screen; folders not read yet are marked as such.
            if let scan, result === scan { version += 1 }
        case .failed(let message):
            Log.scan.error("Scan failed: \(message, privacy: .public)")
            errorTitle = "Couldn't scan"
            errorText = message
            showingError = true
        case .finished(let finished):
            finished.duration = Date().timeIntervalSince(finished.started)
            finished.isComplete = true
            complete(finished)
        }
    }

    /// Puts a scan on screen: the tree (possibly still filling in), with the whole scan selected.
    private func install(_ newResult: ScanResult) {
        // Freeing a big tree takes a moment: let the old one go off the main thread.
        let previous = result
        result = newResult
        if let previous { DispatchQueue.global(qos: .utility).async { _ = previous } }
        if previous?.rootPath != newResult.rootPath { volume = nil }
        refreshVolumes()
        search.scanChanged()
        backStack.removeAll()
        forwardStack.removeAll()
        cameFrom = nil
        fileHighlightHandled()
        selection = newResult.root
        comparisonBases = nil
        changes = nil
        lastRedraw = Date()
        needsRedraw = false
        revealToken += 1
        version += 1
    }

    /// The scan is read in full (everything on this Mac): record it, go back to where the user was
    /// on a rescan, and read any folders only in the cloud.
    private func complete(_ scan: ScanResult) {
        let root = scan.root
        let seconds = scan.duration
        Log.scan.info("Scan finished: \(root.fileCount) files, \(root.folderCount) folders, \(scan.unreadableFolders) unreadable, \(scan.cloudOnlyFolders) only in the cloud, \(seconds, format: .fixed(precision: 1)) s")
        guard result === scan else { return }

        if let keep = placeToKeep, selection === root, let node = root.descendant(atPath: keep) {
            selection = node
            revealToken += 1
        }
        placeToKeep = nil
        version += 1

        HistoryStore.append(historyEntry(for: scan))
        history = HistoryStore.entries(for: scan.rootPath)
        recentScans = HistoryStore.recent()
        refreshVolumes()

        if Prefs.cloudFolderMode == .read && !scan.cloudFolders.isEmpty {
            readCloudFolders()       // records the snapshot when it's done
        } else {
            recordSnapshot(of: scan)
        }
    }

    private func historyEntry(for scan: ScanResult) -> HistoryEntry {
        HistoryEntry(path: scan.rootPath, date: scan.started, size: scan.root.size,
                     allocated: scan.root.allocated, files: scan.root.fileCount)
    }

    // MARK: - Folders only in the cloud

    /// Reads the scan's folders that are only in the cloud, fetching them from the internet, in
    /// the background. They fill in on screen as they arrive; `stopReadingCloud` stops.
    func readCloudFolders() {
        guard let scan = result, scan.isComplete, !isScanning, cloudProgress == nil else { return }
        let folders = scan.cloudFolders.filter { $0.node.cloudOnly }
        guard !folders.isEmpty else { return }
        let progress = ScanProgress()
        let inbox = ScanInbox()
        cloudProgress = progress
        cloud.progress = CloudReadStatus.Progress(total: folders.count)
        isReadingCloud = true
        cloudActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                               reason: "Reading folders from the cloud")
        Log.scan.info("Reading \(folders.count) folders from the cloud")
        let rootDevice = scan.rootDevice
        let links = scan.links
        let topCount = scan.topCount
        let now = scan.scanTime

        cloudPoll?.cancel()
        cloudPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.cloudProgress === progress else { return }
                let snapshot = progress.read()
                let next = CloudReadStatus.Progress(total: max(snapshot.branchesTotal, folders.count),
                                                    done: snapshot.branchesDone, reading: snapshot.reading)
                if self.cloud.progress != next { self.cloud.progress = next }
                self.fillIn(from: inbox, into: scan, redrawEvery: 1)
            }
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            ScanEngine.readCloudFolders(folders, rootDevice: rootDevice, links: links, topCount: topCount,
                                        now: now, progress: progress, deliver: { inbox.add($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cloudFinished(progress: progress, inbox: inbox, scan: scan) }
            }
        }
    }

    /// Stops reading cloud folders. What arrived so far stays; the rest stay marked as in the cloud.
    func stopReadingCloud() {
        cloudProgress?.cancel()
    }

    private func cloudFinished(progress: ScanProgress, inbox: ScanInbox, scan: ScanResult) {
        guard progress === cloudProgress else { return }
        cloudPoll?.cancel()
        cloudPoll = nil
        cloudProgress = nil
        if let activity = cloudActivity {
            ProcessInfo.processInfo.endActivity(activity)
            cloudActivity = nil
        }
        fillIn(from: inbox, into: scan, redrawEvery: 0)
        isReadingCloud = false
        scan.cloudFolders = scan.cloudFolders.filter { $0.node.cloudOnly }
        Log.scan.info("Cloud folders read; \(scan.cloudFolders.count) left unread")
        guard result === scan else { return }
        version += 1
        HistoryStore.update(historyEntry(for: scan))
        history = HistoryStore.entries(for: scan.rootPath)
        recentScans = HistoryStore.recent()
        refreshVolumes()
        recordSnapshot(of: scan)
    }

    // MARK: - Changes since an earlier scan

    /// Saves the sizes of the scan's biggest folders, then compares the scan with the earlier ones.
    /// The snapshot is taken here (the tree belongs to the main thread); the file is read and
    /// written in the background.
    private func recordSnapshot(of scan: ScanResult) {
        let snapshot = FolderSnapshot(root: scan.root, path: scan.rootPath, date: scan.started)
        comparisonBases = nil
        changes = nil
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor [weak self] in
            let bases = await Task.detached(priority: .utility) {
                SnapshotStore.standard.record(snapshot)
            }.value
            guard let self, self.result === scan else { return }
            self.comparisonBases = bases
            self.comparisonIndex = 0   // compares (didSet)
        }
    }

    /// Compares the current tree with the chosen earlier scan. Cheap: it only looks at the folders
    /// that scan recorded. Called after every change to the tree, so moving things to the Trash
    /// shows up here too.
    private func refreshChanges() {
        guard let scan = result, let bases = comparisonBases, bases.indices.contains(comparisonIndex) else {
            changes = nil
            return
        }
        let base = bases[comparisonIndex]
        let now = FolderSnapshot(root: scan.root, path: scan.rootPath, date: scan.started, opening: base)
        changes = FolderComparison(base: base, current: now)
    }

    /// Roughly how much a scan of `path` will find: what the last scan of it found, or for a
    /// whole disk, the space in use on it.
    static func expectedSize(of path: String) -> Int64? {
        if let last = HistoryStore.entries(for: path).last, last.allocated > 0 { return last.allocated }
        let components = (path as NSString).pathComponents
        let isDisk = path == "/" || path == "/System/Volumes/Data"
            || (components.count == 3 && components[1] == "Volumes")
        if isDisk, let volume = volumeInfo(at: path), volume.total > volume.available {
            return volume.total - volume.available
        }
        return nil
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

    /// Moving things to the Trash waits until the tree stops changing.
    private func explainWaitForScan() {
        errorTitle = "Wait for the scan to finish"
        errorText = isReadingCloud
            ? "DiskLens is still reading folders from the cloud. Moving things to the Trash works once it's done, or stop reading them in the summary above the folder tree."
            : "DiskLens is still reading folders. Moving things to the Trash works once the scan is done."
        showingError = true
    }

    /// Moves a folder to the Trash and takes it out of the scan, including the File Types and
    /// Ages totals. Those come from the folder's files, which are read again while the user
    /// answers the confirmation (the scan keeps only folder totals), using the scan's rules.
    func trash(node: Node) {
        guard !isReadingTree else { return explainWaitForScan() }
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
            refreshChanges()
            refreshVolumes()
            version += 1
        }
    }

    /// Moves one file to the Trash and takes it out of the scan. `uncountedLink` is set for a hard
    /// link whose space the scan counted through another link: the totals don't change for it.
    func trashFile(path: String, size: Int64, allocated: Int64, modified: Int64, uncountedLink: FileKey? = nil) {
        guard !isReadingTree else { return explainWaitForScan() }
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
        refreshChanges()
        refreshVolumes()
        version += 1
    }

    // MARK: - Volume

    struct VolumeInfo: Equatable, Sendable {
        let total: Int64
        let available: Int64
    }

    /// Looks up `volume` and `startupVolume` again, in the background.
    func refreshVolumes() {
        let path = result?.rootPath
        volumeTask?.cancel()
        volumeTask = Task { @MainActor [weak self] in
            let (scanned, startup) = await Task.detached(priority: .utility) {
                (path.flatMap { AppModel.volumeInfo(at: $0) }, AppModel.volumeInfo(at: "/"))
            }.value
            guard let self, !Task.isCancelled, self.result?.rootPath == path else { return }
            if self.volume != scanned { self.volume = scanned }
            if self.startupVolume != startup { self.startupVolume = startup }
        }
    }

    /// Size and free space of the disk that holds `path`. Takes several milliseconds.
    nonisolated static func volumeInfo(at path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        return VolumeInfo(total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
