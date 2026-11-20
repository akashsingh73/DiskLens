import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import os

/// One row of the Details list: a folder from the scan or a file read from disk.
struct DetailItem: Identifiable, Hashable, Sendable {
    let id: String              // absolute path
    let name: String
    let isFolder: Bool
    let size: Int64
    let allocated: Int64
    let files: Int
    let folders: Int
    let modified: Date
    let kind: String
    var percent: Double         // share of the folder's space on disk
    let unreadable: Bool
    /// Set for a hard link whose space the scan counted through another link to the same file.
    /// Its On Disk is 0, because moving it to the Trash frees nothing.
    var uncountedLink: FileKey? = nil
    /// How a folder changed since the earlier scan History compares with; nil when that scan
    /// didn't record it (and for files).
    var change: FolderChange? = nil

    /// Biggest growth first when sorted descending; rows with nothing to compare come last.
    var changeSortKey: Int64 { change?.change ?? Int64.min }

    /// The path plus everything shown that can change while the same row stays (sizes grow while a
    /// scan fills in, the change arrives a moment after it): the table only redraws rows that differ.
    static func == (lhs: DetailItem, rhs: DetailItem) -> Bool {
        lhs.id == rhs.id && lhs.change == rhs.change && lhs.allocated == rhs.allocated && lhs.size == rhs.size
            && lhs.files == rhs.files && lhs.folders == rhs.folders && lhs.kind == rhs.kind
            && lhs.percent == rhs.percent && lhs.modified == rhs.modified
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension DetailItem: FastSortable {
    static func sortKey(for keyPath: PartialKeyPath<DetailItem>) -> SortKey<DetailItem>? {
        switch keyPath {
        case \DetailItem.name: return .text { $0.name }
        case \DetailItem.allocated: return .integer { $0.allocated }
        case \DetailItem.changeSortKey: return .integer { $0.changeSortKey }
        case \DetailItem.percent: return .real { $0.percent }
        case \DetailItem.size: return .integer { $0.size }
        case \DetailItem.files: return .integer { Int64($0.files) }
        case \DetailItem.folders: return .integer { Int64($0.folders) }
        case \DetailItem.modified: return .real { $0.modified.timeIntervalSinceReferenceDate }
        case \DetailItem.kind: return .text { $0.kind }
        default: return nil
        }
    }
}

/// Reads the files of one folder off the main thread.
enum DetailLoader {
    static let uncountedLinkKind = "Hard link (counted elsewhere)"

    struct Listing: Sendable {
        var items: [DetailItem] = []
        var total = 0
    }

    /// Lists a folder's files with the scanner's rules (space on disk from `st_blocks`, hard links
    /// counted once), so the rows add up to the folder's totals in the tree.
    /// `uncounted` is the folder's `Node.uncountedLinks`.
    static func listFiles(in path: String, folderTotal: Int64, uncounted: [FileKey: Int]?) -> Listing {
        var items: [DetailItem] = []
        streamFiles(in: path, folderTotal: folderTotal, uncounted: uncounted) { rows in
            items += rows
            return true
        }
        return Listing(items: items, total: items.count)
    }

    /// The rows with "% of Parent" worked out again for a folder now holding `total` bytes.
    static func withPercents(_ items: [DetailItem], of total: Int64) -> [DetailItem] {
        items.map { item in
            var copy = item
            copy.percent = total > 0 ? Double(item.allocated) / Double(total) : 0
            return copy
        }
    }

    /// Lists a folder's files like `listFiles`, handing each batch of rows over as soon as it is read
    /// (a few thousand at a time), so nothing already read waits behind a slow drive. `deliver` runs
    /// on this thread and returns false to stop. False if the folder can't be read, or reading it
    /// failed partway (the rows delivered so far are then only some of its files).
    @discardableResult
    static func streamFiles(in path: String, folderTotal: Int64, uncounted: [FileKey: Int]?,
                            deliver: ([DetailItem]) -> Bool) -> Bool {
        let folderPrefix = path.hasSuffix("/") ? path : path + "/"
        let readable = FolderReader.files(in: path, uncounted: uncounted) { files in
            var rows: [DetailItem] = []
            rows.reserveCapacity(files.count)
            for file in files {
                let filePath = folderPrefix + file.name
                let allocated = file.counted ? file.facts.allocated : 0
                rows.append(DetailItem(
                    id: filePath, name: file.name, isFolder: false,
                    size: file.facts.size, allocated: allocated, files: 1, folders: 0,
                    modified: Date(timeIntervalSince1970: TimeInterval(file.facts.modified)),
                    kind: file.counted ? KindNames.kind(of: file, at: filePath) : uncountedLinkKind,
                    percent: folderTotal > 0 ? Double(allocated) / Double(folderTotal) : 0,
                    unreadable: false,
                    uncountedLink: file.counted ? nil : file.facts.key))
            }
            return deliver(rows)
        }
        if !readable {
            let reason = String(cString: strerror(errno))
            Log.files.error("Couldn't list \(path, privacy: .public): \(reason, privacy: .public)")
        }
        // Every file is listed: the table only makes the rows on screen, however many there are.
        return readable
    }
}

/// Finder's kind names ("PDF document"), looked up once per extension instead of once per file.
/// Safe to use from any thread.
enum KindNames {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    static func kind(of file: FolderFile, at path: String) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let key: String
        if file.facts.isSymbolicLink {
            key = "link"
        } else if !ext.isEmpty {
            key = "ext:" + ext
        } else {
            key = file.facts.isExecutable ? "executable" : "plain"
        }
        if let cached = cache.withLock({ $0[key] }) { return cached }
        // Asking macOS takes about 0.1 ms, once per extension. Some apps give their cache files
        // random extensions ("a8f3b2c1"), one per file, which made a folder of them take seconds.
        // An extension that isn't a short word and that macOS doesn't know is "Document" in Finder
        // anyway, so that is what it gets, without asking (and without filling the cache).
        if !file.facts.isSymbolicLink, !ext.isEmpty, !looksLikeWord(ext),
           UTType(filenameExtension: ext)?.isDynamic ?? true {
            return "Document"
        }
        let url = URL(fileURLWithPath: path)
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "Document"
        cache.withLock { $0[key] = kind }
        return kind
    }

    /// Up to five letters ("dat"): an extension an app may give a name to without macOS knowing it.
    private static func looksLikeWord(_ ext: String) -> Bool {
        ext.utf8.count <= 5 && ext.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
    }
}

/// Icons for list rows, cached because Finder icons are slow to look up.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: DetailItem) -> NSImage {
        icon(name: item.name, path: item.id, isFolder: item.isFolder)
    }

    static func icon(name: String, path: String, isFolder: Bool) -> NSImage {
        let key: String
        if name.hasSuffix(".app") {
            key = path
        } else if isFolder {
            key = "/folder"
        } else {
            key = "ext:" + (name as NSString).pathExtension.lowercased()
        }
        if let cached = cache[key] { return cached }
        let image: NSImage
        if name.hasSuffix(".app") {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if isFolder {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (name as NSString).pathExtension
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        cache[key] = image
        return image
    }
}

/// TreeSize-style Details list for the selected folder. Double-click a folder to open it.
struct DetailsView: View {
    @ObservedObject var model: AppModel
    let node: Node
    let settings: DisplaySettings

    @StateObject private var state = DetailsState()

    private struct LoadKey: Equatable {
        let node: ObjectIdentifier
        let version: Int
        /// The earlier scan the Change column compares with.
        let comparedWith: Date?
    }

    var body: some View {
        DetailsTable(rows: state.rows, rowsVersion: state.rowsVersion, settings: settings,
                     since: model.changes.map { Theme.shortDate($0.base.date) } ?? "the last scan",
                     sortOrder: $state.sortOrder, selection: $state.selection, scrollTarget: $state.scrollTarget,
                     open: { openItem($0) }, showContents: { showContents($0) },
                     quickLook: { quickLook($0) }, trash: { trash($0) })
            .quickLookPreview($state.previewURL)
            .overlay(alignment: .bottom) {
                if state.loading && state.showProgress {
                    ReadingProgress(read: state.filesRead, expected: state.filesExpected)
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: state.loading && state.showProgress)
            .task(id: LoadKey(node: node.id, version: model.version, comparedWith: model.changes?.base.date)) {
                await reload()
            }
            .onChange(of: model.fileToHighlight) { showPendingFile() }
            .onDisappear { state.cancelReading() }
    }

    /// Double-click or Return: folders open inside DiskLens, files open in their app.
    private func openItem(_ item: DetailItem) {
        if item.isFolder {
            showContents(item)
        } else {
            FileActions.open(item.id)
        }
    }

    private func showContents(_ item: DetailItem) {
        if let folder = state.folderLookup[item.id] { model.navigate(to: folder) }
    }

    /// Space or the menu: shows the item in Quick Look, or closes Quick Look if it already shows it.
    private func quickLook(_ item: DetailItem) {
        let url = URL(fileURLWithPath: item.id)
        state.previewURL = state.previewURL == url ? nil : url
    }

    /// The direct child of `folder` that contains `node` (or is `node`), if there is one.
    private static func child(of folder: Node, leadingTo node: Node?) -> Node? {
        var current = node
        while let candidate = current {
            if candidate.parent === folder { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private func trash(_ item: DetailItem) {
        if item.isFolder {
            if let folder = state.folderLookup[item.id] { model.trash(node: folder) }
        } else {
            model.trashFile(path: item.id, size: item.size, allocated: item.allocated,
                            modified: Int64(item.modified.timeIntervalSince1970),
                            uncountedLink: item.uncountedLink)
        }
    }

    /// Selects the file a search result asked for, once this folder's files are listed.
    private func showPendingFile() {
        guard let target = model.fileToHighlight,
              state.listedFolder == (target as NSString).deletingLastPathComponent else { return }
        if state.rows.contains(where: { $0.id == target }) {
            state.selection = [target]
            state.scrollTarget = target
        }
        model.fileHighlightHandled()
    }

    private func reload() async {
        let directory = node.directory
        // While a scan fills in, the tree changes twice a second, mostly somewhere else: the folder
        // shown here is listed again only if something in it changed.
        let signature = DetailsState.Signature(directory, filesOnly: node.kind == .files,
                                               comparedWith: model.changes?.base.date)
        if state.shownFolder == ObjectIdentifier(directory), state.shownSignature == signature,
           state.listedFolder != nil {
            return
        }
        state.shownSignature = nil
        let path = directory.path
        state.listedFolder = nil
        let total = directory.allocated
        let uncounted = directory.uncountedLinks
        let comparison = model.changes
        let rootPath = model.result?.rootPath
        var folderRows: [DetailItem] = []
        var lookup: [String: Node] = [:]
        if node.kind == .directory {
            folderRows.reserveCapacity(directory.children.count)
            for child in directory.children {
                let childPath = (path as NSString).appendingPathComponent(child.name)
                lookup[childPath] = child
                let kind = child.otherVolume ? "Other disk" : child.cloudOnly ? "In the cloud" : child.pending ? "Reading…" : (child.unreadable ? "No access" : "Folder")
                let relative = rootPath.flatMap { FolderSnapshot.relativePath(of: childPath, inside: $0) }
                folderRows.append(DetailItem(
                    id: childPath, name: child.name, isFolder: true,
                    size: child.size, allocated: child.allocated,
                    files: child.fileCount, folders: child.folderCount,
                    modified: Date(timeIntervalSince1970: TimeInterval(child.newest)),
                    kind: kind,
                    percent: total > 0 ? Double(child.allocated) / Double(total) : 0,
                    unreadable: child.unreadable,
                    change: relative.flatMap { comparison?.change(at: $0) }))
            }
        }
        state.folderLookup = lookup
        let folderID = ObjectIdentifier(directory)
        let sameFolder = state.shownFolder == folderID
        state.shownFolder = folderID
        if !sameFolder {
            // Coming back up from a subfolder: highlight the folder you came out of.
            if let child = Self.child(of: directory, leadingTo: model.cameFrom), child.kind == .directory {
                state.selection = [(path as NSString).appendingPathComponent(child.name)]
            } else {
                state.selection = []
            }
        }
        // The folder's own files, as read last time or as being read now. A folder's own files
        // rarely change while a scan fills in the rest of the tree, so this outlives the redraws.
        let filesKey = DetailsState.FilesKey(folder: folderID, ownFiles: directory.ownFileCount,
                                             ownAllocated: directory.ownAllocated,
                                             uncountedLinks: uncounted?.values.reduce(0, +) ?? 0)
        state.signatureToShow = signature
        if state.isReading(filesKey) {
            // Still being read: show the new folder rows with the files so far, and let it finish.
            // (Starting over on every redraw, twice a second during a scan, a big folder would
            // never get listed.)
            state.folderRowsWhileReading = folderRows
            state.show(folderRows + state.filesSoFar)
            return
        }
        // Whatever else is being read (another folder) would otherwise go on showing its rows here.
        state.cancelReading()
        if let cached = state.cachedFiles, cached.key == filesKey {
            state.show(folderRows + DetailLoader.withPercents(cached.listing.items, of: total))
            state.finishLoading()
            state.listedFolder = path
            state.shownSignature = signature
            showPendingFile()
            return
        }
        state.show(folderRows)
        guard directory.ownFileCount > 0, !directory.unreadable else {
            state.finishLoading()
            state.listedFolder = path
            state.shownSignature = signature
            showPendingFile()
            return
        }
        // The scan counted the folder's files, so how far reading has got can be shown.
        state.startLoading(expecting: filesKey.ownFiles + filesKey.uncountedLinks)
        // A short pause, so clicking quickly through folders doesn't read every one of them from disk.
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }

        state.startReading(filesKey, path: path, folder: directory, folderRows: folderRows,
                           uncounted: uncounted) { @MainActor in showPendingFile() }
    }
}

/// A percentage with a small bar, for the "% of Parent" column.
struct PercentBar: View {
    let fraction: Double
    let settings: DisplaySettings

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                FractionBar(fraction: fraction)
                    .fill(LinearGradient(colors: [Color(nsColor: settings.barStart), Color(nsColor: settings.barEnd)],
                                         startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
            }
            .frame(height: 6)
            Text(SizeFormat.percent(fraction, decimals: 1))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

/// A bar filling `fraction` of its width from the left. Drawn from the space it is given, so it
/// needs no GeometryReader (and can never feed a size back into layout).
struct FractionBar: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(1, max(0, fraction))
        let width = rect.width * CGFloat(clamped)
        guard width > 0 else { return Path() }
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    cornerRadius: min(2, width / 2))
    }
}

/// View state for DetailsView, kept in a class so it builds without SwiftUI's macros.
final class DetailsState: ObservableObject {
    /// The rows in display order.
    @Published private(set) var rows: [DetailItem] = [] {
        didSet { rowsVersion += 1 }
    }
    /// Changes whenever `rows` does, so the table reloads only then.
    private(set) var rowsVersion = 0
    @Published var folderLookup: [String: Node] = [:]
    @Published var selection = Set<DetailItem.ID>()
    @Published var sortOrder = [KeyPathComparator(\DetailItem.allocated, order: .reverse)] {
        didSet { rows = FastSort.sorted(items, using: sortOrder) }
    }
    @Published var previewURL: URL?
    /// A row to scroll to (a file chosen in search).
    @Published var scrollTarget: DetailItem.ID?
    /// The folder whose files are fully listed in `rows`, nil while they are being read.
    var listedFolder: String?
    /// The folder shown last, to tell a new folder from the same one redrawn (while a scan fills in).
    var shownFolder: ObjectIdentifier?
    /// What the rows were made from, to skip listing the folder again when nothing in it changed.
    var shownSignature: Signature?
    /// The signature to record once the files being read are all listed (the latest redraw's).
    var signatureToShow: Signature?
    /// The files of the folder read last, reused while its own files stay the same.
    var cachedFiles: (key: FilesKey, listing: DetailLoader.Listing)?

    /// A folder's own files as the scan knows them: while this stays the same, so does the list.
    struct FilesKey: Equatable {
        let folder: ObjectIdentifier
        let ownFiles: Int
        let ownAllocated: Int64
        /// Hard links counted elsewhere: moving one to the Trash changes the list, not the totals.
        let uncountedLinks: Int
    }

    /// The read in progress, which outlives the view's redraws (see `startReading`).
    private var reading: (key: FilesKey, task: Task<Void, Never>)?
    /// While reading: the folder rows to show with the files (updated on each redraw), and the files so far.
    var folderRowsWhileReading: [DetailItem] = []
    private(set) var filesSoFar: [DetailItem] = []

    func isReading(_ key: FilesKey) -> Bool { reading?.key == key }

    @MainActor
    func cancelReading() {
        reading?.task.cancel()
        reading = nil
        filesSoFar = []
    }

    /// Reads a folder's files on another thread and shows them as they arrive, so a big folder (or
    /// a slow drive) fills in before your eyes instead of showing nothing until the last file is
    /// read. The read belongs to this state, not to the view's task: that task restarts whenever
    /// the tree changes (twice a second during a scan), which must not start the read over.
    @MainActor
    func startReading(_ key: FilesKey, path: String, folder: Node, folderRows: [DetailItem],
                      uncounted: [FileKey: Int]?, whenListed: @escaping @MainActor () -> Void) {
        cancelReading()
        folderRowsWhileReading = folderRows
        let total = folder.allocated
        let task = Task { @MainActor [weak self] in
            let stop = ScanProgress()
            let (arrivals, inbox) = AsyncStream<[DetailItem]>.makeStream()
            inbox.onTermination = { _ in stop.cancel() }   // also when this task is cancelled
            let reader = Task.detached(priority: .userInitiated) {
                let complete = DetailLoader.streamFiles(in: path, folderTotal: total, uncounted: uncounted) { rows in
                    guard !stop.isCancelled else { return false }
                    inbox.yield(rows)
                    return true
                }
                inbox.finish()
                return complete
            }
            var shown = Date.distantPast
            var counted = Date.distantPast
            var showTime: TimeInterval = 0
            for await rows in arrivals {
                // A stream hands over what it already holds even after its task is cancelled:
                // a read that was replaced must not show its rows in place of the new folder's.
                guard let self, !Task.isCancelled else { return }
                // Appended in place: a second copy of the array (a local one, say) would make
                // every batch copy all the rows read so far.
                self.filesSoFar += rows
                let now = Date()
                if now.timeIntervalSince(shown) >= max(0.25, showTime * 4) {
                    // Redraw a few times a second; less often when sorting all the rows takes a while.
                    self.filesRead = self.filesSoFar.count
                    self.show(self.folderRowsWhileReading + self.filesSoFar)
                    showTime = Date().timeIntervalSince(now)
                    shown = Date()
                    counted = shown
                } else if now.timeIntervalSince(counted) >= 0.1 {
                    // The count on the progress bar. Each change redraws the view, so not for every
                    // batch: with the Mac busy, redrawing for every batch made reading crawl.
                    self.filesRead = self.filesSoFar.count
                    counted = now
                }
            }
            let complete = await reader.value
            guard let self, !Task.isCancelled else { return }
            self.reading = nil
            let files = self.filesSoFar
            self.filesSoFar = []
            // The folder's size may have changed while its files were read (a scan filling in).
            let listed = DetailLoader.withPercents(files, of: folder.allocated)
            // A read that failed partway (a drive unplugged, say) shows what it got, but isn't kept:
            // coming back to the folder reads it again.
            if complete {
                self.cachedFiles = (key, DetailLoader.Listing(items: listed, total: listed.count))
            }
            self.show(self.folderRowsWhileReading + listed)
            self.finishLoading()
            self.listedFolder = path
            self.shownSignature = self.signatureToShow
            whenListed()
        }
        reading = (key, task)
    }
    @Published private(set) var loading = false
    /// While reading a folder's files: how many have arrived, and how many the scan found.
    @Published var filesRead = 0
    @Published private(set) var filesExpected = 0
    /// Reading has taken long enough to show how far it got (quick folders don't flash a progress bar).
    @Published private(set) var showProgress = false
    private var progressDelay: Task<Void, Never>?

    @MainActor
    func startLoading(expecting files: Int) {
        loading = true
        filesRead = 0
        filesExpected = files
        showProgress = false
        progressDelay?.cancel()
        progressDelay = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, self.loading else { return }
            self.showProgress = true
        }
    }

    @MainActor
    func finishLoading() {
        progressDelay?.cancel()
        progressDelay = nil
        loading = false
        showProgress = false
    }
    private var items: [DetailItem] = []

    /// Everything about a folder its rows show. When this is the same, so are the rows.
    struct Signature: Equatable {
        let size: Int64
        let allocated: Int64
        let files: Int
        let folders: Int
        let newest: Int64
        let subfolders: Int
        /// Subfolders still being read or only in the cloud: they change kind without changing size.
        let unfinished: Int
        /// Hard links counted elsewhere: moving one to the Trash changes the list, not the totals.
        let uncountedLinks: Int
        /// Showing only the folder's own files (its "[Files]" entry), not its subfolders.
        let filesOnly: Bool
        let comparedWith: Date?

        init(_ folder: Node, filesOnly: Bool, comparedWith: Date?) {
            size = folder.size
            allocated = folder.allocated
            files = folder.fileCount
            folders = folder.folderCount
            newest = folder.newest
            subfolders = folder.children.count
            unfinished = folder.children.reduce(0) { $0 + ($1.pending || $1.cloudOnly ? 1 : 0) }
            uncountedLinks = folder.uncountedLinks?.values.reduce(0, +) ?? 0
            self.filesOnly = filesOnly
            self.comparedWith = comparedWith
        }
    }

    /// Sorted once here rather than on every redraw: a folder can hold tens of thousands of files.
    func show(_ newItems: [DetailItem]) {
        items = newItems
        rows = FastSort.sorted(newItems, using: sortOrder)
    }
}

// MARK: - The table

/// The columns of the Details list.
enum DetailsColumn: String, CaseIterable {
    case name, allocated, change, percent, size, files, folders, modified, kind

    var title: String {
        switch self {
        case .name: return "Name"
        case .allocated: return "On Disk"
        case .change: return "Change"
        case .percent: return "% of Parent"
        case .size: return "Size"
        case .files: return "Files"
        case .folders: return "Folders"
        case .modified: return "Modified"
        case .kind: return "Kind"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 160
        case .percent: return 100
        case .change, .modified, .kind: return 80
        case .allocated, .size: return 70
        case .files, .folders: return 50
        }
    }

    var width: CGFloat {
        switch self {
        case .name: return 250
        case .percent, .kind: return 140
        case .modified: return 110
        case .change: return 100
        case .allocated, .size: return 80
        case .files, .folders: return 70
        }
    }

    /// Numbers are right-aligned, as in Finder.
    var isNumber: Bool { self == .allocated || self == .size || self == .files || self == .folders }

    /// The first click on a header sorts names and kinds A to Z, everything else biggest (or newest) first.
    var ascendingFirst: Bool { self == .name || self == .kind }

    func comparator(ascending: Bool) -> KeyPathComparator<DetailItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return KeyPathComparator(\DetailItem.name, order: order)
        case .allocated: return KeyPathComparator(\DetailItem.allocated, order: order)
        case .change: return KeyPathComparator(\DetailItem.changeSortKey, order: order)
        case .percent: return KeyPathComparator(\DetailItem.percent, order: order)
        case .size: return KeyPathComparator(\DetailItem.size, order: order)
        case .files: return KeyPathComparator(\DetailItem.files, order: order)
        case .folders: return KeyPathComparator(\DetailItem.folders, order: order)
        case .modified: return KeyPathComparator(\DetailItem.modified, order: order)
        case .kind: return KeyPathComparator(\DetailItem.kind, order: order)
        }
    }

    /// The column a sort order sorts by.
    init?(sortingBy comparator: KeyPathComparator<DetailItem>) {
        guard let column = Self.allCases.first(where: { $0.comparator(ascending: true).keyPath == comparator.keyPath })
        else { return nil }
        self = column
    }
}

/// The Details list itself: an AppKit table, which only makes the rows on screen, so a folder of tens
/// of thousands of files shows at once. (SwiftUI's Table took over two seconds to take 50,000 rows,
/// with the window frozen meanwhile.) Sorting, selection and scrolling go through bindings; the table
/// is brought in step with them right after SwiftUI's update, never during it (see `scheduleSync`).
struct DetailsTable: NSViewRepresentable {
    let rows: [DetailItem]
    /// Changes whenever `rows` does, so the table reloads only then.
    let rowsVersion: Int
    let settings: DisplaySettings
    /// When the scan the Change column compares with was ("10 Nov"), for its tooltips.
    let since: String
    @Binding var sortOrder: [KeyPathComparator<DetailItem>]
    @Binding var selection: Set<DetailItem.ID>
    @Binding var scrollTarget: DetailItem.ID?
    let open: @MainActor (DetailItem) -> Void
    let showContents: @MainActor (DetailItem) -> Void
    let quickLook: @MainActor (DetailItem) -> Void
    let trash: @MainActor (DetailItem) -> Void

    /// The columns hidden with the header's menu.
    private static let hiddenColumnsKey = "detailsHiddenColumns"

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DetailsTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.allowsExpansionToolTips = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for column in DetailsColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.width
            tableColumn.headerCell.alignment = column.isNumber ? .right : .left
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.ascendingFirst)
            table.addTableColumn(tableColumn)
        }
        // macOS keeps the columns' order and widths between launches.
        table.autosaveName = "DiskLens.Details"
        table.autosaveTableColumns = true
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenColumnsKey) ?? [])
        for tableColumn in table.tableColumns where tableColumn.identifier.rawValue != DetailsColumn.name.rawValue {
            tableColumn.isHidden = hidden.contains(tableColumn.identifier.rawValue)
        }

        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onKey = { [weak coordinator] key, row in coordinator?.pressed(key, row: row) }
        table.menu = coordinator.makeMenu()
        table.headerView?.menu = coordinator.makeHeaderMenu()
        coordinator.table = table

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        coordinator.scheduleSync()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.scheduleSync()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DetailsTable
        weak var table: DetailsTableView?
        /// The rows the table shows (a copy of `parent.rows` from the last sync).
        private var rows: [DetailItem] = []
        private var shownVersion = -1
        private var shownSettings: DisplaySettings?
        private var shownSince = ""
        /// Each row's position by path, made when a selection or scroll target has to be found.
        private var positions: [String: Int]?
        private var syncScheduled = false
        /// Set while the table is changed from here, so its notifications don't echo back.
        private var applying = false
        private weak var rowMenu: NSMenu?
        private weak var headerMenu: NSMenu?

        init(parent: DetailsTable) {
            self.parent = parent
        }

        func detach() {
            table?.dataSource = nil
            table?.delegate = nil
            table?.onKey = nil
            table = nil
            rows = []
            positions = nil
        }

        // MARK: Keeping in step with SwiftUI

        /// Called while SwiftUI updates the window. Reloading, selecting or scrolling the table then
        /// would change AppKit layout in the middle of SwiftUI's own layout pass, so it happens right after.
        func scheduleSync() {
            guard !syncScheduled else { return }
            syncScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncScheduled = false
                self.sync()
            }
        }

        private func sync() {
            guard let table else { return }
            applying = true
            defer { applying = false }

            // The sort arrow in the header follows the sort order.
            if let comparator = parent.sortOrder.first, let column = DetailsColumn(sortingBy: comparator) {
                let ascending = comparator.order == .forward
                let current = table.sortDescriptors.first
                if current?.key != column.rawValue || current?.ascending != ascending {
                    table.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: ascending)]
                }
            }

            if parent.rowsVersion != shownVersion || parent.settings != shownSettings || parent.since != shownSince {
                let previousRow = table.selectedRow
                if parent.rowsVersion != shownVersion {
                    rows = parent.rows
                    positions = nil
                    shownVersion = parent.rowsVersion
                }
                shownSettings = parent.settings
                shownSince = parent.since
                table.reloadData()
                // The rows may have moved: keep the same item selected, not the same position.
                select(parent.selection.first, in: table, near: previousRow)
            } else if let wanted = parent.selection.first, wanted != selectedID(in: table) {
                select(wanted, in: table, near: table.selectedRow)
            } else if parent.selection.isEmpty, table.selectedRow >= 0 {
                table.deselectAll(nil)
            }

            if let target = parent.scrollTarget {
                if let row = position(of: target) { scrollToMiddle(row, in: table) }
                parent.scrollTarget = nil
            }
        }

        private func selectedID(in table: NSTableView) -> String? {
            let row = table.selectedRow
            return rows.indices.contains(row) ? rows[row].id : nil
        }

        private func select(_ id: String?, in table: NSTableView, near hint: Int) {
            guard let id else {
                if table.selectedRow >= 0 { table.deselectAll(nil) }
                return
            }
            // Usually the item is still where it was; look it up only when it moved.
            let row = rows.indices.contains(hint) && rows[hint].id == id ? hint : position(of: id)
            if let row {
                if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }

        private func position(of id: String) -> Int? {
            if positions == nil {
                var map = [String: Int](minimumCapacity: rows.count)
                for (row, item) in rows.enumerated() { map[item.id] = row }
                positions = map
            }
            return positions?[id]
        }

        /// Selects a row and scrolls it to the middle, with the Name column in view.
        private func scrollToMiddle(_ row: Int, in table: NSTableView) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            guard let clip = table.enclosingScrollView?.contentView else {
                table.scrollRowToVisible(row)
                return
            }
            let rect = table.rect(ofRow: row)
            let y = max(0, min(rect.midY - clip.bounds.height / 2, table.bounds.height - clip.bounds.height))
            clip.scroll(to: NSPoint(x: 0, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = DetailsColumn(rawValue: tableColumn.identifier.rawValue),
                  rows.indices.contains(row) else { return nil }
            let item = rows[row]
            let settings = parent.settings
            switch column {
            case .name:
                let cell = reuse(tableView, "name") { DetailsNameCell() }
                cell.show(item)
                return cell
            case .percent:
                let cell = reuse(tableView, "percent") { DetailsPercentCell() }
                cell.show(fraction: item.percent, settings: settings)
                return cell
            case .change:
                let cell = reuse(tableView, "change") { DetailsChangeCell() }
                cell.show(item.change, settings: settings, since: parent.since)
                return cell
            case .allocated, .size, .files, .folders:
                let cell = reuse(tableView, "number") { DetailsTextCell(alignment: .right) }
                switch column {
                case .allocated: cell.show(settings.bytes(item.allocated))
                case .size: cell.show(settings.bytes(item.size))
                case .files: cell.show(item.isFolder ? SizeFormat.count(item.files) : "")
                default: cell.show(item.isFolder ? SizeFormat.count(item.folders) : "")
                }
                return cell
            case .modified:
                let cell = reuse(tableView, "text") { DetailsTextCell(alignment: .left) }
                cell.show(item.modified > Date(timeIntervalSince1970: 0)
                          ? item.modified.formatted(.dateTime.year().month(.abbreviated).day()) : "")
                return cell
            case .kind:
                let cell = reuse(tableView, "text") { DetailsTextCell(alignment: .left) }
                cell.show(item.kind)
                return cell
            }
        }

        private func reuse<Cell: NSView>(_ tableView: NSTableView, _ kind: String, make: () -> Cell) -> Cell {
            let identifier = NSUserInterfaceItemIdentifier("DetailsCell." + kind)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
            let cell = make()
            cell.identifier = identifier
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            let id = selectedID(in: table)
            parent.selection = id.map { [$0] } ?? []
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let first = tableView.sortDescriptors.first, let key = first.key,
                  let column = DetailsColumn(rawValue: key) else { return }
            parent.sortOrder = [column.comparator(ascending: first.ascending)]
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.open(rows[row])
        }

        func pressed(_ key: DetailsTableView.Key, row: Int) {
            guard rows.indices.contains(row) else { return }
            switch key {
            case .open: parent.open(rows[row])
            case .quickLook: parent.quickLook(rows[row])
            }
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            rowMenu = menu
            return menu
        }

        /// Right-click on the column titles: show or hide columns.
        func makeHeaderMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            headerMenu = menu
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === headerMenu {
                for column in DetailsColumn.allCases where column != .name {
                    guard let tableColumn = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
                    else { continue }
                    let item = DetailsMenuItem(column.title) { [weak self, weak tableColumn] in
                        tableColumn?.isHidden.toggle()
                        self?.saveHiddenColumns()
                    }
                    item.state = tableColumn.isHidden ? .off : .on
                    menu.addItem(item)
                }
                return
            }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard rows.indices.contains(row) else { return }
            let item = rows[row]
            let parent = self.parent
            if item.isFolder {
                menu.addItem(DetailsMenuItem("Show Contents") { parent.showContents(item) })
                menu.addItem(.separator())
            }
            menu.addItem(DetailsMenuItem("Reveal in Finder") { FileActions.reveal(item.id) })
            menu.addItem(DetailsMenuItem("Open") { FileActions.open(item.id) })
            menu.addItem(DetailsMenuItem("Quick Look") { parent.quickLook(item) })
            menu.addItem(DetailsMenuItem("Copy Path") { FileActions.copyPath(item.id) })
            menu.addItem(.separator())
            menu.addItem(DetailsMenuItem("Move to Trash…") { parent.trash(item) })
        }

        private func saveHiddenColumns() {
            guard let table else { return }
            let hidden = table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue)
            UserDefaults.standard.set(hidden, forKey: DetailsTable.hiddenColumnsKey)
        }
    }
}

/// The table behind Details: Return opens the selected item and Space shows it in Quick Look.
final class DetailsTableView: NSTableView {
    enum Key { case open, quickLook }
    var onKey: ((Key, Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        let row = selectedRow
        if row >= 0, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.charactersIgnoringModifiers {
            case " ":
                onKey?(.quickLook, row)
                return
            case "\r", "\u{3}":                     // Return, Enter
                onKey?(.open, row)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

/// A menu item that runs a closure.
private final class DetailsMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("DetailsMenuItem is created in code")
    }

    @MainActor @objc private func runAction() { run() }
}

// MARK: - Cells

private let detailsTextHeight: CGFloat = 17

/// One line of text, left or right aligned (numbers use digits of equal width).
final class DetailsTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(alignment: NSTextAlignment) {
        super.init(frame: .zero)
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.font = alignment == .right
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("DetailsTextCell is created in code")
    }

    func show(_ text: String) {
        label.stringValue = text
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 2, y: (bounds.height - detailsTextHeight) / 2,
                             width: max(0, bounds.width - 4), height: detailsTextHeight)
    }
}

/// The icon and name of a file or folder.
final class DetailsNameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("DetailsNameCell is created in code")
    }

    func show(_ item: DetailItem) {
        icon.image = IconCache.icon(for: item)
        label.stringValue = item.name
        label.textColor = item.unreadable ? .secondaryLabelColor : .labelColor
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 24, y: (bounds.height - detailsTextHeight) / 2,
                             width: max(0, bounds.width - 26), height: detailsTextHeight)
    }
}

/// How a folder changed since the earlier scan: an arrow and the amount, coloured by direction,
/// with the details in a tooltip (as in History).
final class DetailsChangeCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    @MainActor private static var symbols: [String: NSImage] = [:]

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(icon)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("DetailsChangeCell is created in code")
    }

    func show(_ change: FolderChange?, settings: DisplaySettings, since: String) {
        guard let change else {
            icon.image = nil
            label.stringValue = ""
            toolTip = nil
            return
        }
        if change.kind != .added && change.kind != .renamed && change.change == 0 {
            icon.image = nil
            label.stringValue = "–"
            label.textColor = .tertiaryLabelColor
            toolTip = "No change since \(since)"
            needsLayout = true
            return
        }
        let color = NSColor(Theme.changeColor(change.change))
        icon.image = Self.symbol(Theme.changeSymbol(change.change))
        icon.contentTintColor = color
        label.textColor = color
        label.stringValue = settings.signedBytes(change.change)
        switch change.kind {
        case .added:
            toolTip = "New since \(since)"
        case .renamed:
            toolTip = "Called “\(change.oldName ?? "")” on \(since), when it took \(settings.bytes(change.before))"
        default:
            toolTip = "\(settings.bytes(change.before)) on \(since)"
        }
        needsLayout = true
    }

    private static func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        symbols[name] = image
        return image
    }

    override func layout() {
        super.layout()
        let iconWidth: CGFloat = icon.image == nil ? 0 : 14
        icon.frame = NSRect(x: 2, y: (bounds.height - 14) / 2, width: iconWidth, height: 14)
        let x: CGFloat = icon.image == nil ? 2 : 20
        label.frame = NSRect(x: x, y: (bounds.height - detailsTextHeight) / 2,
                             width: max(0, bounds.width - x - 2), height: detailsTextHeight)
    }
}

/// A share of the folder: a small bar and the percentage.
final class DetailsPercentCell: NSTableCellView {
    private let track = TrackView()
    private let bar = GradientBar()
    private let label = NSTextField(labelWithString: "")
    private var fraction: CGFloat = 0

    init() {
        super.init(frame: .zero)
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        addSubview(track)
        addSubview(bar)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("DetailsPercentCell is created in code")
    }

    func show(fraction: Double, settings: DisplaySettings) {
        self.fraction = CGFloat(min(1, max(0, fraction)))
        bar.setColors(settings.barStart, settings.barEnd)
        bar.isHidden = self.fraction <= 0
        label.stringValue = SizeFormat.percent(fraction, decimals: 1)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelWidth: CGFloat = 52
        let barHeight: CGFloat = 6
        let barWidth = max(0, bounds.width - labelWidth - 10)
        let y = (bounds.height - barHeight) / 2
        track.frame = NSRect(x: 2, y: y, width: barWidth, height: barHeight)
        let filled = fraction > 0 ? max(barHeight, (barWidth * fraction).rounded()) : 0
        bar.frame = NSRect(x: 2, y: y, width: min(barWidth, filled), height: barHeight)
        label.frame = NSRect(x: bounds.width - labelWidth - 2, y: (bounds.height - detailsTextHeight) / 2,
                             width: labelWidth, height: detailsTextHeight)
    }
}

/// "Reading 12,000 of 63,855 files" with a bar: shown while a folder's files are being read, once
/// that takes more than a moment, so a big folder or a slow drive never just looks stuck.
private struct ReadingProgress: View {
    let read: Int
    let expected: Int

    var body: some View {
        // Files added since the scan can make the folder hold a few more than it expected.
        let total = max(expected, read)
        HStack(spacing: 10) {
            if total > 0 {
                ProgressView(value: Double(read), total: Double(total))
                    .frame(width: 150)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(read > 0 ? "Reading \(SizeFormat.count(read)) of \(SizeFormat.count(total, "file"))"
                          : "Reading \(SizeFormat.count(total, "file"))…")
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
