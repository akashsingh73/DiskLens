import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thread-safe progress counters and the cancel flag for one scan.
final class ScanProgress: @unchecked Sendable {
    enum Phase: Sendable {
        /// Reading the first two levels, which decides how the rest is split up.
        case listing
        /// Reading the folders below those, several at a time.
        case reading
        /// All folders read; adding up the totals.
        case finishing
    }

    struct Snapshot {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
        var currentPath = ""
        var phase = Phase.listing
        /// The folders read in parallel (each with everything inside it), and how many are done.
        var branchesTotal = 0
        var branchesDone = 0
        /// The folders being read right now, longest-running first.
        var reading: [String] = []
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var active: [Int: (path: String, since: Date)] = [:]
    private var cancelled = false

    func add(files: Int, folders: Int, bytes: Int64, currentPath: String?) {
        lock.lock()
        snapshot.files += files
        snapshot.folders += folders
        snapshot.bytes += bytes
        if let currentPath { snapshot.currentPath = currentPath }
        lock.unlock()
    }

    func startReading(branches: Int) {
        lock.lock()
        snapshot.phase = .reading
        snapshot.branchesTotal = branches
        lock.unlock()
    }

    /// A busy worker handed part of its folder to an idle one.
    func branchAdded() {
        lock.lock()
        snapshot.branchesTotal += 1
        lock.unlock()
    }

    func branchStarted(_ index: Int, path: String) {
        lock.lock()
        active[index] = (path, Date())
        lock.unlock()
    }

    func branchFinished(_ index: Int) {
        lock.lock()
        active[index] = nil
        snapshot.branchesDone += 1
        lock.unlock()
    }

    func startFinishing() {
        lock.lock()
        snapshot.phase = .finishing
        active.removeAll()
        lock.unlock()
    }

    func read() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var copy = snapshot
        copy.reading = active.values.sorted { $0.since < $1.since }.map(\.path)
        return copy
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Cloud storage folders (iCloud Drive, Google Drive, Dropbox, OneDrive…) keep most of their
/// folders in the cloud until something opens them; opening one makes macOS fetch its contents
/// from the internet first, which can make a scan crawl for many minutes. DiskLens never needs
/// that: what is only in the cloud takes no space on this Mac.
enum CloudFiles {
    /// Runs `body` with this thread set never to fetch anything from the cloud. Opening a folder
    /// that is only in the cloud then fails at once (with `EDEADLK`) instead of waiting.
    static func withoutFetching<T>(_ body: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let previous = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 { setiopolicy_np(type, IOPOL_SCOPE_THREAD, previous) }
        }
        return try body()
    }

    /// True for the error a folder that is only in the cloud gives while fetching is off.
    static func isCloudOnly(errorCode: Int32) -> Bool { errorCode == EDEADLK }
}

/// Remembers hard-linked files so their space is counted only once.
final class HardLinkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<FileKey>()

    func isFirstSighting(_ key: FileKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }
}

/// The parts of `stat` the scanner needs, the same on every platform.
struct FileFacts {
    var size: Int64
    var allocated: Int64
    var modified: Int64
    var device: UInt64
    var inode: UInt64
    var links: UInt64
    var mode: UInt32
    var flags: UInt32
    var isDirectory: Bool

    init(_ st: stat) {
        size = Int64(st.st_size)
        allocated = Int64(st.st_blocks) * 512          // st_blocks counts 512-byte blocks
        inode = UInt64(st.st_ino)
        links = UInt64(st.st_nlink)
        mode = UInt32(st.st_mode)
        flags = UInt32(st.st_flags)
        isDirectory = (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        device = FileFacts.normalize(st.st_dev)
        #if canImport(Darwin)
        modified = Int64(st.st_mtimespec.tv_sec)
        #else
        modified = Int64(st.st_mtim.tv_sec)
        #endif
    }

    var key: FileKey { FileKey(device: device, inode: inode) }
    /// Only in the cloud (iCloud Drive, Google Drive, Dropbox, OneDrive…): nothing of it is on this
    /// Mac, and for a folder even the list of what's inside has to be fetched from the internet.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
    var isSymbolicLink: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK) }
    var isExecutable: Bool { mode & 0o111 != 0 }

    @inline(__always)
    static func normalize(_ device: dev_t) -> UInt64 {
        #if canImport(Darwin)
        return UInt64(UInt32(bitPattern: device))
        #else
        return UInt64(device)
        #endif
    }
}

enum NameTools {
    private static let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)

    /// The name of a directory entry from `readdir`.
    static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { tuple -> String in
            tuple.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(cString: $0) }
        }
    }

    /// Lower-cased extension without the dot, or "" when there is none.
    static func fileExtension(of name: UnsafeRawBufferPointer) -> String {
        let count = name.count
        guard count >= 3 else { return "" }
        var i = count - 1
        while i > 0 {                       // i > 0: a leading dot (".zshrc") is not an extension
            if name[i] == 0x2E {
                let length = count - i - 1
                if length == 0 || length > 12 { return "" }
                return String(decoding: UnsafeRawBufferPointer(rebasing: name[(i + 1)...]), as: UTF8.self).lowercased()
            }
            i -= 1
        }
        return ""
    }

    static func fileExtension(of name: String) -> String {
        var copy = name
        return copy.withUTF8 { fileExtension(of: UnsafeRawBufferPointer($0)) }
    }
}

/// Per-thread statistics, merged when the scan finishes.
struct ScanAccumulator {
    var tally = FileTally()
    var top: TopFileHeap
    var unreadable = 0
    var unreadableSamples: [String] = []
    var otherVolumes = 0
    var cloudOnly = 0
    /// The folders only in the cloud this part of the scan left unread, to read later.
    var cloudFolders: [CloudFolder] = []
    var hardLinkDuplicates = 0
    var statErrors = 0

    var pendingFiles = 0
    var pendingFolders = 0
    var pendingBytes: Int64 = 0

    /// How many unreadable folders are listed by name (all of them are counted).
    static let sampleLimit = 500

    init(topCount: Int) {
        top = TopFileHeap(capacity: topCount)
    }

    mutating func addFile(to folder: Node, facts: FileFacts, ext: String, now: Int64,
                          links: HardLinkRegistry, path: () -> String) {
        // A file with several hard links is one set of blocks: count it the first time only,
        // and remember the others so Details and the Trash can tell them apart later.
        if facts.links > 1 && !links.isFirstSighting(facts.key) {
            hardLinkDuplicates += 1
            folder.noteUncountedLink(facts.key)
            return
        }
        folder.ownSize += facts.size
        folder.ownAllocated += facts.allocated
        folder.ownFileCount += 1
        if facts.modified > folder.ownNewest { folder.ownNewest = facts.modified }

        tally.add(ext: ext, size: facts.size, allocated: facts.allocated, modified: facts.modified, now: now)

        if top.wants(facts.allocated) {
            top.insert(TopFile(path: path(), size: facts.size, allocated: facts.allocated, modified: facts.modified))
        }
        pendingFiles += 1
        pendingBytes += facts.allocated
    }

    mutating func noteUnreadable(_ path: String) {
        unreadable += 1
        if unreadableSamples.count < ScanAccumulator.sampleLimit { unreadableSamples.append(path) }
    }

    mutating func flush(to progress: ScanProgress, currentPath: String?) {
        progress.add(files: pendingFiles, folders: pendingFolders, bytes: pendingBytes, currentPath: currentPath)
        pendingFiles = 0
        pendingFolders = 0
        pendingBytes = 0
    }

    mutating func merge(_ other: ScanAccumulator) {
        tally.merge(other.tally)
        top.merge(other.top)
        unreadable += other.unreadable
        for sample in other.unreadableSamples where unreadableSamples.count < ScanAccumulator.sampleLimit {
            unreadableSamples.append(sample)
        }
        otherVolumes += other.otherVolumes
        cloudOnly += other.cloudOnly
        cloudFolders += other.cloudFolders
        hardLinkDuplicates += other.hardLinkDuplicates
        statErrors += other.statErrors
    }
}

/// A folder only in the cloud that a scan left unread, and where it sits in the tree.
struct CloudFolder: @unchecked Sendable {
    let path: String
    let name: String
    /// Belongs to the tree; touched only on the thread that owns the tree.
    let node: Node
}

/// One part of a scan, read on a worker thread into a tree of its own: the contents of
/// `placeholder` (a folder already in the tree on screen), plus its statistics.
struct ScanPiece: @unchecked Sendable {
    let placeholder: Node
    let contents: Node
    let stats: ScanAccumulator
}

/// The folders waiting to be read, shared by the scan's workers, one per core. A worker that
/// runs out of work waits; meanwhile the busy workers see that someone is waiting
/// (`wantsWork`) and hand over the next subfolder they come to instead of reading it themselves.
/// So the work splits itself up only as much as needed, and every core stays busy until the end,
/// however lopsided the folders are.
final class WorkQueue: @unchecked Sendable {
    struct Job {
        let id: Int
        let folder: CloudFolder
    }

    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var waiting = 0
    private var busy = 0
    private var stopped = false
    private var nextID = 0

    init(_ folders: [CloudFolder]) {
        jobs = folders.reversed().map { folder in
            defer { nextID += 1 }
            return Job(id: nextID, folder: folder)
        }
    }

    /// The next folder to read; nil once every folder is read (or the queue was stopped).
    /// The caller must call `finished()` after reading it.
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped { return nil }
            if let job = jobs.popLast() {
                busy += 1
                return job
            }
            if busy == 0 {
                condition.broadcast()
                return nil
            }
            waiting += 1
            condition.wait()
            waiting -= 1
        }
    }

    func finished() {
        condition.lock()
        busy -= 1
        if busy == 0 && jobs.isEmpty { condition.broadcast() }
        condition.unlock()
    }

    /// True when a worker is idle and nothing is queued: hand it the next subfolder.
    var wantsWork: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waiting > 0 && jobs.isEmpty && !stopped
    }

    /// Queues a folder (part of one being read) for an idle worker; returns its id.
    @discardableResult
    func add(_ folder: CloudFolder) -> Int {
        condition.lock()
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, folder: folder))
        condition.signal()
        condition.unlock()
        return id
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Finished pieces waiting for the main thread to add them to the tree.
final class ScanInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [ScanPiece] = []

    func add(_ piece: ScanPiece) {
        lock.lock()
        pieces.append(piece)
        lock.unlock()
    }

    func takeAll() -> [ScanPiece] {
        lock.lock()
        defer { lock.unlock() }
        let taken = pieces
        pieces = []
        return taken
    }
}

/// Collects per-job results from concurrent workers.
final class ResultSlots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Value?]

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: Value) {
        lock.lock()
        slots[index] = value
        lock.unlock()
    }

    func all() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}

// MARK: - Reading one folder again after the scan

/// A file directly inside a folder, read from disk with the scanner's rules.
struct FolderFile: Sendable {
    let name: String
    let facts: FileFacts
    /// False for a hard link whose space the scan counted through another link to the same file.
    let counted: Bool
}

enum FolderReader {
    /// The files (not folders) directly in `path`, or nil if the folder can't be read.
    /// `uncounted` is the folder's `Node.uncountedLinks`, so hard links come out exactly as the
    /// scan counted them: the folder's counted files add up to its `own` totals.
    static func files(in path: String, uncounted: [FileKey: Int]?) -> [FolderFile]? {
        CloudFiles.withoutFetching { readFiles(in: path, uncounted: uncounted) }
    }

    private static func readFiles(in path: String, uncounted: [FileKey: Int]?) -> [FolderFile]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var remaining = uncounted ?? [:]
        var files: [FolderFile] = []
        while let entry = readdir(dir) {
            let name = NameTools.name(of: entry)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let facts = FileFacts(st)
            if facts.isDirectory { continue }
            var counted = true
            if facts.links > 1, let left = remaining[facts.key], left > 0 {
                remaining[facts.key] = left - 1
                counted = false
            }
            files.append(FolderFile(name: name, facts: facts, counted: counted))
        }
        return files
    }
}

/// A folder to read again for `FileTally.read`.
struct TallyFolder: Sendable {
    let path: String
    let uncounted: [FileKey: Int]?
}

extension FileTally {
    /// The folders at and below `node` whose files the scan counted. Main thread (it reads the tree).
    static func folders(in node: Node, path: String) -> [TallyFolder] {
        var list: [TallyFolder] = []
        var stack: [(node: Node, path: String)] = [(node, path)]
        while let (folder, folderPath) = stack.popLast() {
            if folder.unreadable || folder.otherVolume { continue }
            if folder.ownFileCount > 0 {
                list.append(TallyFolder(path: folderPath, uncounted: folder.uncountedLinks))
            }
            for child in folder.children where child.kind == .directory {
                stack.append((child, (folderPath as NSString).appendingPathComponent(child.name)))
            }
        }
        return list
    }

    /// Reads the folders again and totals their files the way the scan did, using the scan's
    /// clock (`now`) so every file lands in the same age band. Stops early when cancelled.
    static func read(_ folders: [TallyFolder], now: Int64, progress: ScanProgress) -> FileTally {
        let readers = ScanEngine.readers
        let slots = ResultSlots<FileTally>(count: readers)
        // As many threads as a scan uses (see `ScanEngine.readers`), each taking every n-th folder.
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            var tally = FileTally()
            for index in stride(from: reader, to: folders.count, by: readers) {
                if progress.isCancelled { break }
                let folder = folders[index]
                for file in FolderReader.files(in: folder.path, uncounted: folder.uncounted) ?? [] where file.counted {
                    tally.add(ext: NameTools.fileExtension(of: file.name), size: file.facts.size,
                              allocated: file.facts.allocated, modified: file.facts.modified, now: now)
                }
            }
            slots.set(reader, tally)
        }
        var total = FileTally()
        for tally in slots.all() { total.merge(tally) }
        return total
    }
}
