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
    /// Nothing has been read for a few seconds: the disk is busy (another app copying, a backup)
    /// or waking up, or a network drive isn't answering.
    @Published var stalled = false

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

/// The state of one window: its scan, where the user is, navigation history, and scan control.
/// Each window has a model of its own (see `ScanWindow`), so windows scan independently.
/// Everything here runs on the main thread; the scan itself runs on background threads.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var result: ScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var scanningName = ""
    /// The folder (or "[Files]" entry) shown in the right-hand views.
    @Published private(set) var selection: Node?
    /// The view shown on the right. A new window starts with the one used last.
    @Published var tab = DetailTab(rawValue: UserDefaults.standard.string(forKey: AppModel.tabKey) ?? "") ?? .details {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    private static let tabKey = "detailTab"
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
    /// Checked off the main thread (see `checkFullDiskAccess`); assumed on until then, so no notice flashes.
    @Published var fullDiskAccess = true
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
    private var volumeAgain = false

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
        checkFullDiskAccess()
        // Another window finished a scan: keep the recent scans and History up to date here too.
        historyObserver = NotificationCenter.default.addObserver(forName: HistoryStore.didChange, object: nil,
                                                                 queue: .main) { [weak self] note in
            let changedHere = note.object as AnyObject? === self
            MainActor.assumeIsolated {
                guard let self, !changedHere else { return }
                self.recentScans = HistoryStore.recent()
                if let path = self.result?.rootPath { self.history = HistoryStore.entries(for: path) }
            }
        }
    }

    /// Looks up whether DiskLens has Full Disk Access, without the main thread asking the disk.
    func checkFullDiskAccess() {
        Task { @MainActor [weak self] in
            let granted = await DiskThreads.value { FullDiskAccess.isGranted }
            if let self, self.fullDiskAccess != granted { self.fullDiskAccess = granted }
        }
    }

    /// The window this model belongs to, and what it watches there.
    private(set) weak var window: NSWindow?
    private var windowObserver: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?

    /// Called once the window's views are in place (see `WindowReader`): the mouse's back and
    /// forward buttons work in this window, and closing it stops whatever it is still reading.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        if let observer = windowObserver { NotificationCenter.default.removeObserver(observer) }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        installMouseNavigation()
    }

    /// The window is closing: stop the scan, the cloud folders and search, and stop listening.
    private func windowWillClose() {
        cancel()
        stopReadingCloud()
        search.isPresented = false
        search.scanStarted()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        for observer in [windowObserver, historyObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObserver = nil
        historyObserver = nil
    }

    private var activeProgress: ScanProgress?
    private var activeInbox: ScanInbox?
    private var pollTask: Task<Void, Never>?
    private var scanActivity: NSObjectProtocol?
    /// The scan shown while it is still being read (its tree fills in as folders finish).
    private var liveScan: ScanResult?
    private var lastRedraw = Date.distantPast
    private var needsRedraw = false
    /// Where the user was, to go back there when a rescan of the same folder finishes.
    private var placeToKeep: String?
    private var cloudProgress: ScanProgress?
    private var cloudInbox: ScanInbox?
    private var cloudScan: ScanResult?
    /// The scan on screen finished while the last scan's cloud read was still stopping (it waits on
    /// the internet): read this scan's cloud folders, and record its snapshot, once that one stops.
    private var readCloudWhenStopped = false
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
        // A folder being moved to the Trash is taken out of the tree once its files are counted.
        guard trashingName == nil else {
            NSSound.beep()
            return
        }
        stopReadingCloud()
        readCloudWhenStopped = false
        let progress = ScanProgress()
        let inbox = ScanInbox()
        let started = Date()
        let topCount = Prefs.topFilesCountValue

        search.scanStarted()
        activeProgress = progress
        activeInbox = inbox
        liveScan = nil
        isScanning = true
        // The folder's own name comes from the disk, with the rest (see below); until then, its last part.
        scanningName = requested == "/" ? "/" : (requested as NSString).lastPathComponent
        status.snapshot = ScanProgress.Snapshot()
        status.elapsed = 0
        status.expected = nil
        status.stalled = false
        showingError = false
        placeToKeep = nil
        // Keeps macOS from slowing the scan down while DiskLens is in the background.
        scanActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Scanning a folder")

        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var lastChange = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.activeProgress === progress else { return }
                let snapshot = progress.read()
                let before = self.status.snapshot
                if snapshot.files != before.files || snapshot.folders != before.folders
                    || snapshot.branchesDone != before.branchesDone || snapshot.phase != before.phase {
                    lastChange = Date()
                }
                let stalled = snapshot.phase != .finishing && Date().timeIntervalSince(lastChange) > Self.stallAfter
                if self.status.stalled != stalled { self.status.stalled = stalled }
                self.status.snapshot = snapshot
                self.status.elapsed = Date().timeIntervalSince(started)
                if let scan = self.liveScan { self.fillIn(from: inbox, into: scan, redrawEvery: 0.5) }
            }
        }

        // Everything that asks the disk happens on the scan's thread, the folder's name and size
        // included: on a disk that is busy or waking up, any of it can wait, and the window must not.
        DiskThreads.start { [weak self] in
            let target = Self.resolve(requested)
            let path = target.path
            let name = target.displayName
            let expected = Self.expectedSize(of: path)
            let access = FullDiskAccess.isGranted
            Log.scan.info("Scan started: \(path, privacy: .public)")
            DispatchQueue.main.async {
                // Before the tree is shown: that is queued after this.
                MainActor.assumeIsolated { self?.resolved(path: path, name: name, expected: expected, access: access,
                                                          progress: progress) }
            }
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

    /// The scan's folder is found: what to show while it is read.
    private func resolved(path: String, name: String, expected: Int64?, access: Bool, progress: ScanProgress) {
        guard progress === activeProgress else { return }
        scanningName = name
        status.expected = expected
        if fullDiskAccess != access { fullDiskAccess = access }
        // Rescanning the same folder keeps your place once the scan gets there.
        if let old = result, old.rootPath == path, let current = selection {
            placeToKeep = current.directory.path
        }
    }

    /// How long a scan goes without reading anything before it says it's waiting for the disk.
    static let stallAfter: TimeInterval = 4

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

    /// Stops the scan. The window lets go of it at once, without waiting for its threads: on a disk
    /// that is busy or waking up, they can be stuck in macOS for a long time before they notice.
    /// What was read so far stays; anything they finish afterwards is dropped.
    func cancel() {
        guard let progress = activeProgress else { return }
        progress.cancel()
        finish(.cancelled, progress: progress, inbox: activeInbox ?? ScanInbox())
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
        activeInbox = nil
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
        NotificationCenter.default.post(name: HistoryStore.didChange, object: self)
        refreshVolumes()

        if Prefs.cloudFolderMode == .read && !scan.cloudFolders.isEmpty {
            if cloudProgress != nil {
                readCloudWhenStopped = true      // see `cloudFinished`
            } else if !readCloudFolders() {      // records the snapshot when it's done
                recordSnapshot(of: scan)
            }
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
    /// False if there was nothing to read, or it can't start now.
    @discardableResult
    func readCloudFolders() -> Bool {
        guard let scan = result, scan.isComplete, !isScanning, cloudProgress == nil, trashingName == nil else { return false }
        let folders = scan.cloudFolders.filter { $0.node.cloudOnly }
        guard !folders.isEmpty else { return false }
        let progress = ScanProgress()
        let inbox = ScanInbox()
        cloudProgress = progress
        cloudInbox = inbox
        cloudScan = scan
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

        DiskThreads.start(qos: .utility) { [weak self] in
            ScanEngine.readCloudFolders(folders, rootDevice: rootDevice, links: links, topCount: topCount,
                                        now: now, progress: progress, deliver: { inbox.add($0) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cloudFinished(progress: progress, inbox: inbox, scan: scan) }
            }
        }
        return true
    }

    /// Stops reading cloud folders. What arrived so far stays; the rest stay marked as in the cloud.
    /// Doesn't wait for the threads reading: one waiting on the internet can take minutes to
    /// notice, and Move to Trash and Find wait until the tree stops changing.
    func stopReadingCloud() {
        guard let progress = cloudProgress, let inbox = cloudInbox, let scan = cloudScan else { return }
        progress.cancel()
        cloudFinished(progress: progress, inbox: inbox, scan: scan)
    }

    private func cloudFinished(progress: ScanProgress, inbox: ScanInbox, scan: ScanResult) {
        guard progress === cloudProgress else {
            // A read let go of when it was stopped: what its threads finished since is dropped, so
            // the hard links it counted first must count when those folders are read again.
            scan.links.forget(inbox.takeAll().flatMap(\.stats.firstSightings))
            return
        }
        cloudInbox = nil
        cloudScan = nil
        cloudPoll?.cancel()
        cloudPoll = nil
        cloudProgress = nil
        if let activity = cloudActivity {
            ProcessInfo.processInfo.endActivity(activity)
            cloudActivity = nil
        }
        if progress.isCancelled {
            _ = scan.fillIn(inbox.takeAll())
            scan.putBackUnread()
            needsRedraw = true
        }
        fillIn(from: inbox, into: scan, redrawEvery: 0)
        isReadingCloud = false
        scan.cloudFolders = scan.cloudFolders.filter { $0.node.cloudOnly }
        Log.scan.info("Cloud folders read; \(scan.cloudFolders.count) left unread")
        guard result === scan else {
            // A newer scan finished while this read was stopping: its turn now.
            if readCloudWhenStopped, let current = result {
                readCloudWhenStopped = false
                if !readCloudFolders() { recordSnapshot(of: current) }
            }
            return
        }
        version += 1
        HistoryStore.update(historyEntry(for: scan))
        history = HistoryStore.entries(for: scan.rootPath)
        recentScans = HistoryStore.recent()
        NotificationCenter.default.post(name: HistoryStore.didChange, object: self)
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
            let bases = await DiskThreads.value(qos: .utility) {
                SnapshotStore.standard.record(snapshot)
            }
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
    nonisolated static func expectedSize(of path: String) -> Int64? {
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
    nonisolated static func resolve(_ requested: String) -> (path: String, displayName: String) {
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

    nonisolated private static func canonicalPath(_ path: String) -> String {
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

    /// Lets the back and forward buttons on a mouse move through the folder history, in this
    /// model's window only.
    private func installMouseNavigation() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            let handled: Bool = MainActor.assumeIsolated {
                let button = event.buttonNumber
                guard button == 3 || button == 4, let self, event.window === self.window,
                      self.result != nil, !self.isScanning else { return false }
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
        let counting = Task {
            await DiskThreads.value { CountedFiles.read(folders, now: now, progress: reading) }
        }
        guard FileActions.confirmTrash(path: path, sizeText: SizeFormat.bytes(node.allocated)) else {
            reading.cancel()
            return
        }
        trashingName = node.name
        Task { @MainActor in
            let files = await Self.counted(counting, progress: reading, path: path)
            trashingName = nil
            guard await FileActions.moveToTrash(path: path) else { return }
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
            let topFiles = Set(scan.topFiles.map(\.path))
            let kept = scan.removeFolder(node, path: path, files: files)
            showInTopFiles(kept.filter { topFiles.contains($0.file.path) }, of: scan)
            refreshChanges()
            refreshVolumes()
            version += 1
        }
    }

    /// How long counting a folder's files for the Trash may go without reading any, before it is
    /// given up: the disk has stopped answering (a network drive gone, say).
    static let countGivesUpAfter: TimeInterval = 20

    /// The files `counting` counts, or none if the disk stops answering (see `countGivesUpAfter`).
    /// The folder is still moved to the Trash then, and its space taken out of the scan; only File
    /// Types and Ages keep its files, rather than the window waiting for good to move it.
    private static func counted(_ counting: Task<CountedFiles, Never>, progress: ScanProgress,
                                path: String) async -> CountedFiles {
        let done = ScanProgress()      // its cancel flag says the count is done
        Task {
            _ = await counting.value
            done.cancel()
        }
        var files = -1
        var lastRead = Date()
        while !done.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let now = progress.read().files
            if now != files {
                files = now
                lastRead = Date()
            } else if Date().timeIntervalSince(lastRead) > countGivesUpAfter {
                progress.cancel()
                Log.files.error("Counting the files of \(path, privacy: .public) stopped: the disk isn't answering. File Types and Ages keep them.")
                return CountedFiles()
            }
        }
        return await counting.value
    }

    /// Moves one file to the Trash and takes it out of the scan. `uncountedLink` is set for a hard
    /// link whose space the scan counted through another link: the totals don't change for it.
    /// Nor do they for a file the scan counted that has another link in the scan: that one is
    /// counted from now on (see `ScanResult.removeFile`).
    func trashFile(path: String, size: Int64, allocated: Int64, modified: Int64, uncountedLink: FileKey? = nil) {
        guard !isReadingTree else { return explainWaitForScan() }
        guard trashingName == nil else {
            NSSound.beep()
            return
        }
        let scan = result
        let folder = scan?.root.descendant(atPath: (path as NSString).deletingLastPathComponent)
        Task { @MainActor in
            // Asking the disk about the file, and moving it, happen off the main thread.
            var link: FileKey?
            if uncountedLink == nil {
                link = await DiskThreads.value {
                    var st = stat()
                    return lstat(path, &st) == 0 && st.st_nlink > 1 ? FileFacts(st).key : nil
                }
            }
            guard result === scan else { return }
            let freesNothing = uncountedLink != nil
                || link.flatMap { scan?.folderHoldingLink(to: $0, near: folder) } != nil
            guard FileActions.confirmTrash(path: path, sizeText: SizeFormat.bytes(allocated), extraHardLink: freesNothing),
                  await FileActions.moveToTrash(path: path) else { return }
            Log.files.info("Moved file to Trash: \(path, privacy: .public)")
            // A rescan may have replaced the tree meanwhile: it no longer has the file, or soon won't.
            guard result === scan else { return }
            trashedFile(path, scan: scan, folder: folder, size: size, allocated: allocated, modified: modified,
                        uncountedLink: uncountedLink, link: link)
        }
    }

    private func trashedFile(_ path: String, scan: ScanResult?, folder: Node?, size: Int64, allocated: Int64,
                             modified: Int64, uncountedLink: FileKey?, link: FileKey?) {
        if let scan, let folder {
            let wasTopFile = scan.topFiles.contains { $0.path == path }
            let holder = scan.removeFile(path, in: folder, size: size, allocated: allocated, modified: modified,
                                         uncountedLink: uncountedLink, link: link)
            if folder.ownFileCount == 0 {
                // The folder's "[Files]" entry is gone: don't leave anything pointing at it.
                if let current = selection, current.kind == .files, current.parent === folder {
                    selection = folder
                }
                backStack.removeAll { $0.kind == .files && $0.parent === folder }
                forwardStack.removeAll { $0.kind == .files && $0.parent === folder }
            }
            if wasTopFile, let holder, let link {
                let file = LinkedFile(path: path, key: link, size: size, allocated: allocated, modified: modified)
                showInTopFiles([(file, holder)], of: scan)
            }
        }
        refreshChanges()
        refreshVolumes()
        version += 1
    }

    /// Largest files moved to the Trash whose space is still taken through another hard link, now
    /// counted in `folder`: they stay in Top Files under that link's name, read from its folder in
    /// the background.
    private func showInTopFiles(_ kept: [(file: LinkedFile, folder: Node)], of scan: ScanResult) {
        let wanted = kept.map { (file: $0.file, folder: $0.folder.path) }
        guard !wanted.isEmpty else { return }
        Task { @MainActor [weak self] in
            let found = await DiskThreads.value {
                wanted.compactMap { item -> TopFile? in
                    guard let name = FolderReader.firstLink(to: item.file.key, in: item.folder) else { return nil }
                    return TopFile(path: (item.folder as NSString).appendingPathComponent(name), size: item.file.size,
                                   allocated: item.file.allocated, modified: item.file.modified)
                }
            }
            guard let self, self.result === scan, !found.isEmpty else { return }
            let shown = Set(scan.topFiles.map(\.path))
            scan.topFiles = (scan.topFiles + found.filter { !shown.contains($0.path) }).sorted { $0.allocated > $1.allocated }
            self.version += 1
        }
    }

    // MARK: - Volume

    struct VolumeInfo: Equatable, Sendable {
        let total: Int64
        let available: Int64
    }

    /// Looks up `volume` and `startupVolume` again, in the background.
    /// One lookup at a time: with the disk busy, asking how much space is free can take seconds,
    /// and asking again meanwhile only piled up waiting threads. A lookup asked for meanwhile runs
    /// once this one is back.
    func refreshVolumes() {
        guard volumeTask == nil else {
            volumeAgain = true
            return
        }
        let path = result?.rootPath
        volumeTask = Task { @MainActor [weak self] in
            let (scanned, startup) = await DiskThreads.value(qos: .utility) {
                (path.flatMap { AppModel.volumeInfo(at: $0) }, AppModel.volumeInfo(at: "/"))
            }
            guard let self else { return }
            self.volumeTask = nil
            if self.result?.rootPath == path {
                if self.volume != scanned { self.volume = scanned }
                if self.startupVolume != startup { self.startupVolume = startup }
            }
            if self.volumeAgain {
                self.volumeAgain = false
                self.refreshVolumes()
            }
        }
    }

    /// Size and free space of the disk that holds `path`. Takes several milliseconds.
    nonisolated static func volumeInfo(at path: String) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        // "For important usage" also counts space macOS can free up on its own (purgeable files), as
        // Finder does, but external drives report it as 0: there the plain free space is the right one.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let available = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(total: Int64(total), available: available)
    }
}
