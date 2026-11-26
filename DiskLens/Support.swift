import AppKit
import Darwin
import UniformTypeIdentifiers
import os

// MARK: - Logging

/// Diagnostics go to the system log. To read them: open Console, start streaming,
/// and search for "local.disklens.app".
enum Log {
    static let app = Logger(subsystem: "local.disklens.app", category: "app")
    static let scan = Logger(subsystem: "local.disklens.app", category: "scan")
    static let files = Logger(subsystem: "local.disklens.app", category: "files")
}

// MARK: - File type groups

enum FileGroup: String, CaseIterable, Identifiable {
    case images = "Images"
    case video = "Video"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives & Disk Images"
    case code = "Code & Data"
    case apps = "Apps & Libraries"
    case other = "Other"

    var id: String { rawValue }

    @MainActor private static var cache: [String: FileGroup] = [:]

    /// Groups an extension using the system's type registry (UTType).
    @MainActor
    static func group(forExtension ext: String) -> FileGroup {
        if let cached = cache[ext] { return cached }
        let group = classify(ext)
        cache[ext] = group
        return group
    }

    private static func classify(_ ext: String) -> FileGroup {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .database) || type.conforms(to: .propertyList) {
            return .code
        }
        if type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .framework) {
            return .apps
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .compositeContent) {
            return .documents
        }
        return .other
    }
}

// MARK: - Sorting table rows quickly

/// The value a table column sorts by, read from a row.
enum SortKey<Row> {
    case integer((Row) -> Int64)
    case real((Row) -> Double)
    /// Sorted the way Finder sorts names (and `KeyPathComparator` sorts text): "File 2" before "File 10".
    case text((Row) -> String)
}

/// A row type that can tell `FastSort` what its sortable columns hold.
protocol FastSortable {
    /// The value behind the column `keyPath` sorts by; nil for a column it doesn't know,
    /// which then sorts the slow way.
    static func sortKey(for keyPath: PartialKeyPath<Self>) -> SortKey<Self>?
}

/// Sorts table rows in the order of SwiftUI's `KeyPathComparator`s, much faster.
/// `sorted(using:)` reads two values through key paths for every comparison. Here each row's
/// value is read once, then only those values are compared and the rows put in that order.
/// For 50,000 rows: by size 6 ms instead of 340 ms; by name 190 ms instead of 1 s (comparing
/// names the way Finder does is the slow part there). The order is the same, ties included
/// (both use the standard library's stable sort).
enum FastSort {
    private enum Column {
        case integer([Int64])
        case real([Double])
        case text([String])

        @inline(__always)
        func compare(_ a: Int, _ b: Int) -> ComparisonResult {
            switch self {
            case .integer(let values):
                return values[a] < values[b] ? .orderedAscending : values[a] > values[b] ? .orderedDescending : .orderedSame
            case .real(let values):
                return values[a] < values[b] ? .orderedAscending : values[a] > values[b] ? .orderedDescending : .orderedSame
            case .text(let values):
                return values[a].localizedStandardCompare(values[b])
            }
        }
    }

    static func sorted<Row: FastSortable>(_ rows: [Row], using comparators: [KeyPathComparator<Row>]) -> [Row] {
        var columns: [(column: Column, ascending: Bool)] = []
        for comparator in comparators {
            guard let key = Row.sortKey(for: comparator.keyPath) else { return rows.sorted(using: comparators) }
            let column: Column
            switch key {
            case .integer(let value): column = .integer(rows.map(value))
            case .real(let value): column = .real(rows.map(value))
            case .text(let value): column = .text(rows.map(value))
            }
            columns.append((column, comparator.order == .forward))
        }
        guard !columns.isEmpty else { return rows }
        var order = Array(rows.indices)
        // The usual case, a single column of numbers, compares the numbers directly.
        if columns.count == 1, case .integer(let values) = columns[0].column {
            if columns[0].ascending { order.sort { values[$0] < values[$1] } } else { order.sort { values[$0] > values[$1] } }
        } else {
            order.sort { a, b in
                for (column, ascending) in columns {
                    let result = column.compare(a, b)
                    if result != .orderedSame { return result == (ascending ? .orderedAscending : .orderedDescending) }
                }
                return false
            }
        }
        return order.map { rows[$0] }
    }

    /// Two lists of rows, each sorted in `order`, as one: the order sorting `rows + more` would give,
    /// with `rows` first where they tie. Where each of `more` goes is found by galloping through
    /// `rows`, so a few new rows among many take a few comparisons, not one per row; the rows are
    /// copied once. (A list growing while it is read is kept sorted this way, rather than sorted
    /// again in full each time it is shown.)
    static func merged<Row>(_ rows: [Row], _ more: [Row], in order: RowOrder<Row>) -> [Row] {
        if more.isEmpty { return rows }
        if rows.isEmpty { return more }
        var result: [Row] = []
        result.reserveCapacity(rows.count + more.count)
        var start = 0
        for row in more {
            // The rows `row` doesn't come before stay in front of it, ties included.
            let end = firstIndex(from: start, to: rows.count) { order.precedes(row, rows[$0]) }
            result.append(contentsOf: rows[start..<end])
            result.append(row)
            start = end
        }
        result.append(contentsOf: rows[start...])
        return result
    }

    /// The first index in `start..<end` where `isPast` holds (`end` if none), for a test that, once
    /// it holds, holds for every later index, as "comes after this row" does in a sorted list.
    /// Looks 1, 2, 4, 8… ahead, then halves the last step: a nearby answer takes few looks.
    static func firstIndex(from start: Int, to end: Int, where isPast: (Int) -> Bool) -> Int {
        var low = start      // Everything before `low` is known not to be past.
        var probe = start
        var step = 1
        while probe < end, !isPast(probe) {
            low = probe + 1
            probe = low + step
            step *= 2
        }
        var high = min(probe, end)
        while low < high {
            let middle = low + (high - low) / 2
            if isPast(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

/// The order of a list of `KeyPathComparator`s, for comparing two rows at a time (merging sorted
/// lists, finding where a row goes in one) the way `FastSort` compares them: the same values,
/// names compared the same way, and ties left as they are.
struct RowOrder<Row: FastSortable> {
    private enum Key {
        case integer((Row) -> Int64)
        case real((Row) -> Double)
        case text((Row) -> String)
        /// A column `FastSort` has no key for, compared through its key path (in its own order).
        case other(KeyPathComparator<Row>)
    }

    private let keys: [(key: Key, ascending: Bool)]

    init(_ comparators: [KeyPathComparator<Row>]) {
        keys = comparators.map { comparator in
            let ascending = comparator.order == .forward
            switch Row.sortKey(for: comparator.keyPath) {
            case .integer(let value): return (.integer(value), ascending)
            case .real(let value): return (.real(value), ascending)
            case .text(let value): return (.text(value), ascending)
            case nil: return (.other(comparator), true)
            }
        }
    }

    /// Whether `a` comes before `b`. False when they tie: a stable sort keeps those as they came.
    func precedes(_ a: Row, _ b: Row) -> Bool {
        for (key, ascending) in keys {
            let result: ComparisonResult
            switch key {
            case .integer(let value):
                let (x, y) = (value(a), value(b))
                result = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case .real(let value):
                let (x, y) = (value(a), value(b))
                result = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case .text(let value):
                result = value(a).localizedStandardCompare(value(b))
            case .other(let comparator):
                result = comparator.compare(a, b)
            }
            if result != .orderedSame { return result == (ascending ? .orderedAscending : .orderedDescending) }
        }
        return false
    }
}

// MARK: - Paths as Finder shows them

enum PathDisplay {
    private static let dataVolume = "/System/Volumes/Data"

    /// "/System/Volumes/Data/Users/me" becomes "/Users/me" when both name the same folder
    /// (the startup disk's firmlinks), so paths look the way they do in Finder.
    static func friendly(_ path: String) -> String {
        guard path.hasPrefix(dataVolume + "/") else { return path }
        let candidate = String(path.dropFirst(dataVolume.count))
        if let known = Firmlinks.sameFolder(candidate) { return known ? candidate : path }
        return sameFile(path, candidate) ? candidate : path
    }

    /// The other way round: "/Users/me" becomes "/System/Volumes/Data/Users/me" when both name the
    /// same folder, which is where a scan of the startup disk keeps it. Nil when they don't.
    static func onDataVolume(_ path: String) -> String? {
        guard path.hasPrefix("/"), path != "/", !path.hasPrefix(dataVolume + "/"), path != dataVolume else { return nil }
        let candidate = dataVolume + path
        if let known = Firmlinks.sameFolder(path) { return known ? candidate : nil }
        return sameFile(path, candidate) ? candidate : nil
    }

    fileprivate static func sameFile(_ a: String, _ b: String) -> Bool {
        var first = stat()
        var second = stat()
        return lstat(a, &first) == 0 && lstat(b, &second) == 0
            && first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// The startup disk's firmlinks (/Users, /Applications, …: listed in /usr/share/firmlinks), each
    /// checked once. Asking the disk every time cost two lookups per path shown, several times a
    /// second while a scan redraws its progress, on the main thread: with the disk busy (another app
    /// copying, a backup running) each one could wait, and the window froze.
    private enum Firmlinks {
        private static let lock = NSLock()
        /// The firmlinked folders, as paths from "/"; nil if the list can't be read.
        nonisolated(unsafe) private static var roots: [String]?
        nonisolated(unsafe) private static var loaded = false
        /// Whether each firmlinked folder and its copy on the data volume were found to be one.
        nonisolated(unsafe) private static var checked: [String: Bool] = [:]

        /// For a path from "/": whether it names the same thing as on the data volume, as far as
        /// the firmlinks tell (true inside a firmlinked folder that checked out, false outside
        /// every firmlink). Nil when the firmlinks aren't known: ask the disk.
        static func sameFolder(_ path: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            if !loaded {
                loaded = true
                roots = (try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8))
                    .map { list in
                        list.split(separator: "\n").compactMap { line in
                            line.split(separator: "\t").first.map(String.init)
                        }.filter { $0.hasPrefix("/") && $0.count > 1 }
                    }
                if roots?.isEmpty ?? true { roots = nil }
            }
            guard let roots else { return nil }
            // The longest firmlink the path is in (or is).
            guard let root = roots.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
            else { return false }
            if let known = checked[root] { return known }
            let same = PathDisplay.sameFile(root, dataVolume + root)
            checked[root] = same
            return same
        }
    }
}

// MARK: - Finder actions

@MainActor
enum FileActions {
    static func reveal(_ path: String) {
        reveal([path])
    }

    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: PathDisplay.friendly($0)) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: PathDisplay.friendly(path)))
    }

    static func copyPath(_ path: String) {
        copyText(PathDisplay.friendly(path))
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Folders DiskLens refuses to trash: the home folder and everything that contains it,
    /// ~/Library, the top level of any disk, and the system.
    static func isProtected(_ path: String) -> Bool {
        let friendly = PathDisplay.friendly(path)
        let home = NSHomeDirectory()
        if friendly == home || home.hasPrefix(friendly + "/") { return true }
        if friendly == home + "/Library" { return true }
        if friendly == "/System" || friendly.hasPrefix("/System/") { return true }
        let components = (friendly as NSString).pathComponents
        if components.count <= 2 { return true }                                   // "/", "/Applications", "/Library"
        if components.count == 3 && components[1] == "Volumes" { return true }    // another disk itself
        return false
    }

    /// Asks before moving an item to the Trash. Protected folders are refused with an explanation.
    /// `extraHardLink` is for a hard link whose space is counted with another link to the same file.
    static func confirmTrash(path: String, sizeText: String, extraHardLink: Bool = false) -> Bool {
        let name = (path as NSString).lastPathComponent
        if isProtected(path) {
            let refusal = NSAlert()
            refusal.messageText = "DiskLens won't move “\(name)” to the Trash."
            refusal.informativeText = "It's a system folder, your home folder, or a folder that contains it. Delete things inside it instead."
            refusal.alertStyle = .informational
            refusal.runModal()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = extraHardLink
            ? "It's a hard link: the same file is also in another place, so this frees no space. You can put it back from the Trash until you empty it."
            : "It takes \(sizeText). You can put it back from the Trash until you empty it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Moves an item to the Trash (never deletes outright). Shows an alert if that fails.
    /// Moves an item to the Trash on a thread of its own (a busy disk can take a while to answer)
    /// and says why if it can't.
    static func moveToTrash(path: String) async -> Bool {
        let failed: (any Error)? = await DiskThreads.value {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                return nil
            } catch {
                return error
            }
        }
        guard let failed else { return true }
        Log.files.error("Couldn't move to Trash: \(path, privacy: .public): \(failed.localizedDescription, privacy: .public)")
        NSAlert(error: failed).runModal()
        return false
    }
}

// MARK: - Full Disk Access

enum FullDiskAccess {
    /// macOS only lets apps with Full Disk Access read the privacy database.
    static var isGranted: Bool {
        let paths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in paths {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true   // could not tell; don't nag
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Scan history

struct HistoryEntry: Codable, Identifiable, Hashable {
    let path: String
    let date: Date
    let size: Int64
    let allocated: Int64
    let files: Int
    var id: Date { date }
}

enum HistoryStore {
    private static let limit = 5000

    /// Posted (on the main thread) after a window adds a scan to the history; the object is that
    /// window's `AppModel`. Other windows refresh their recent scans and History.
    static let didChange = Notification.Name("DiskLens.HistoryStore.didChange")

    /// Where DiskLens keeps its scan history (and the folder snapshots, see `SnapshotStore`).
    static var folderURL: URL {
        if let testFolder { return testFolder }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskLens", isDirectory: true)
    }

    private static var fileURL: URL { folderURL.appendingPathComponent("history.json") }

    /// Where the tests keep a history of their own, instead of the real one.
    nonisolated(unsafe) static var testFolder: URL? {
        didSet {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private static let lock = NSLock()
    /// The history, read from its file once and kept: every window reads it when any scan finishes,
    /// on the main thread, which must not wait for a busy disk each time.
    nonisolated(unsafe) private static var cached: [HistoryEntry]?
    /// Changes made here and not yet in the file.
    nonisolated(unsafe) private static var unwritten = 0
    /// Writes the file in the background, in order.
    private static let writer = DispatchQueue(label: "local.disklens.history", qos: .utility)
    /// Told to every copy of DiskLens running (`open -n` starts another) when one changes the file.
    private static let changedElsewhere = Notification.Name("local.disklens.history.changed")

    static func load() -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let all = readFile()
        cached = all
        return all
    }

    /// Makes `change` to the history: at once to what this copy of DiskLens shows, and in the
    /// background to the file. There it is made to the file as it is then, under a lock, so another
    /// copy of DiskLens running at the same time and changing it too doesn't lose its changes, or
    /// this one's.
    private static func change(_ change: @escaping @Sendable (inout [HistoryEntry]) -> Void) {
        _ = load()
        lock.lock()
        if var all = cached {
            change(&all)
            cached = all
        }
        unwritten += 1
        lock.unlock()
        let folder = folderURL
        let lockFile = folderURL.appendingPathComponent("history.lock")
        writer.async {
            var merged: [HistoryEntry]?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileLock.withLock(lockFile) {
                    var all = readFile()
                    change(&all)
                    try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
                    merged = all
                }
            } catch {
                Log.app.error("Couldn't save scan history: \(error.localizedDescription, privacy: .public)")
            }
            lock.lock()
            unwritten -= 1
            // The file now also holds what other copies of DiskLens added. With more changes of this
            // copy still on their way, the history kept here stays as it is until the last is written.
            if let merged, unwritten == 0 { cached = merged }
            lock.unlock()
            DistributedNotificationCenter.default().postNotificationName(
                changedElsewhere, object: String(getpid()), userInfo: nil, deliverImmediately: true)
        }
    }

    /// Follows changes other copies of DiskLens make to the history: reads the file again (in the
    /// background) and tells this copy's windows (`didChange`, with no object). Call once at launch.
    static func followOtherCopies() {
        let me = String(getpid())
        DistributedNotificationCenter.default().addObserver(forName: changedElsewhere, object: nil, queue: nil) { note in
            guard (note.object as? String) != me else { return }
            writer.async {
                let all = readFile()
                lock.lock()
                if unwritten == 0 { cached = all }
                lock.unlock()
                DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
            }
        }
    }

    /// Waits until the history is written: before DiskLens quits, and for the tests.
    static func waitForWrites() {
        writer.sync {}
    }

    private static func readFile() -> [HistoryEntry] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            // Keep the damaged file for inspection and start a fresh history.
            Log.app.error("Scan history unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            let backup = folderURL.appendingPathComponent("history-damaged.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func entries(for path: String) -> [HistoryEntry] {
        load().filter { $0.path == path }.sorted { $0.date < $1.date }
    }

    /// Replaces the entry of the same scan (same folder and time), e.g. once cloud folders were read.
    static func update(_ entry: HistoryEntry) {
        change { all in
            if let index = all.lastIndex(where: { $0.path == entry.path && $0.date == entry.date }) {
                all[index] = entry
            } else {
                add(entry, to: &all)
            }
        }
    }

    /// The latest scan of each folder, newest first.
    static func recent(limit: Int = 8) -> [HistoryEntry] {
        var latest: [String: HistoryEntry] = [:]
        for entry in load() where latest[entry.path].map({ entry.date > $0.date }) ?? true {
            latest[entry.path] = entry
        }
        return Array(latest.values.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func append(_ entry: HistoryEntry) {
        change { add(entry, to: &$0) }
    }

    private static func add(_ entry: HistoryEntry, to all: inout [HistoryEntry]) {
        all.append(entry)
        if all.count > limit { all.removeFirst(all.count - limit) }
    }
}

/// A lock on a file, shared by every copy of DiskLens running (`flock`): what one copy reads,
/// changes and writes back, no other changes in between.
enum FileLock {
    static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }       // also lets go of the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }
}

/// How many files DiskLens may have open at once. macOS starts an app at 256: every window's scan
/// keeps a few folders open on each of its threads, Details and Search more, and past the limit
/// folders fail to open and come out as unreadable, so the totals come out short, with nothing
/// actually wrong with them. Raised at launch, as far as macOS allows.
enum OpenFileLimit {
    static let wanted: rlim_t = 10_240

    static func raise() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < wanted else { return }
        let target = min(wanted, limit.rlim_max, rlim_t(OPEN_MAX))
        guard target > limit.rlim_cur else { return }
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            Log.app.error("Couldn't raise the open file limit: \(String(cString: strerror(errno)), privacy: .public)")
        }
    }

    static var current: rlim_t {
        var limit = rlimit()
        return getrlimit(RLIMIT_NOFILE, &limit) == 0 ? limit.rlim_cur : 0
    }
}
