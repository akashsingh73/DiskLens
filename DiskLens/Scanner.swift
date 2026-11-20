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

    /// Takes back first sightings from a part of a scan that was thrown away (stopped before it
    /// was delivered), so the file is counted when that part is read again.
    func forget(_ keys: [FileKey]) {
        guard !keys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for key in keys { seen.remove(key) }
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

    /// Facts read with `getattrlistbulk` rather than `stat` (see `FolderReader`): the same values.
    init(size: Int64, allocated: Int64, modified: Int64, device: UInt64, inode: UInt64, links: UInt64,
         mode: UInt32, flags: UInt32) {
        self.size = size
        self.allocated = allocated
        self.modified = modified
        self.device = device
        self.inode = inode
        self.links = links
        self.mode = mode
        self.flags = flags
        isDirectory = (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
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
    /// Hard-linked files this part of the scan counted first (see `HardLinkRegistry.forget`).
    var firstSightings: [FileKey] = []

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
        if facts.links > 1 {
            guard links.isFirstSighting(facts.key) else {
                hardLinkDuplicates += 1
                folder.noteUncountedLink(facts.key)
                return
            }
            firstSightings.append(facts.key)
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

    /// Records the space a folder itself takes (see `Node.folderAllocated`).
    mutating func addFolderSpace(_ allocated: Int64, to folder: Node) {
        folder.folderAllocated = allocated
        pendingBytes += allocated
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
        /// Handed over from inside another folder being read (`add`), not one the queue began with.
        var handedOff = false
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
        jobs.append(Job(id: id, folder: folder, handedOff: true))
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

    /// The folders a stopped queue never handed out (call once every worker is done).
    func leftOver() -> [Job] {
        condition.lock()
        defer { condition.unlock() }
        let left = jobs
        jobs = []
        return left
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
        var all: [FolderFile] = []
        let readable = files(in: path, uncounted: uncounted) { batch in
            all += batch
            return true
        }
        return readable ? all : nil
    }

    /// Reads the files directly in `path` a batch at a time, in the order the folder lists them, and
    /// hands each batch to `batch` (on this thread), which returns false to stop. Returns false if the
    /// folder can't be read. Folders whose own drive can't read in one pass are read file by file.
    ///
    /// Hard links the scan left uncounted here come last, in a batch of their own: which of a file's
    /// links the scan counted is known only once the whole folder is read (see `labelLinks`).
    @discardableResult
    static func files(in path: String, uncounted: [FileKey: Int]?, batch: ([FolderFile]) -> Bool) -> Bool {
        CloudFiles.withoutFetching {
            guard let uncounted, !uncounted.isEmpty else { return read(path, batch: batch) }
            var held: [FolderFile] = []
            var stopped = false
            let readable = read(path) { files in
                var ready: [FolderFile] = []
                ready.reserveCapacity(files.count)
                for file in files {
                    if file.facts.links > 1, uncounted[file.facts.key] != nil {
                        held.append(file)
                    } else {
                        ready.append(file)
                    }
                }
                guard !ready.isEmpty else { return true }
                stopped = !batch(ready)
                return !stopped
            }
            if !stopped, !held.isEmpty { _ = batch(labelLinks(held, uncounted: uncounted)) }
            return readable
        }
    }

    /// The scan's hard-link rule for one folder's files, given in the order the folder lists them:
    /// the scan counts the first link to a file it comes to and none after it, so here a file's
    /// first link counts, and the ones after it don't, unless every link to it here is one the scan
    /// left uncounted (`uncounted`: the folder's `Node.uncountedLinks`), having counted it elsewhere.
    static func labelLinks(_ files: [FolderFile], uncounted: [FileKey: Int]?) -> [FolderFile] {
        guard let uncounted, !uncounted.isEmpty else { return files }
        var here: [FileKey: Int] = [:]
        for file in files where file.facts.links > 1 && uncounted[file.facts.key] != nil {
            here[file.facts.key, default: 0] += 1
        }
        var seen: [FileKey: Int] = [:]
        return files.map { file in
            let key = file.facts.key
            guard file.facts.links > 1, let links = here[key] else {
                return FolderFile(name: file.name, facts: file.facts, counted: true)
            }
            let order = seen[key, default: 0]
            seen[key] = order + 1
            let countedHere = max(0, links - (uncounted[key] ?? 0))    // 1, or 0 when counted elsewhere
            return FolderFile(name: file.name, facts: file.facts, counted: order < countedHere)
        }
    }

    /// The first link to the file `key` that `path` lists: the one counted from now on, once the link
    /// the scan counted is moved to the Trash (see `labelLinks`). Nil if there is none, or the folder
    /// can't be read.
    static func firstLink(to key: FileKey, in path: String) -> String? {
        var found: String?
        files(in: path, uncounted: nil) { batch in
            found = batch.first { $0.facts.key == key }?.name
            return found == nil
        }
        return found
    }

    /// Every file, in one pass if the drive can, else file by file; all marked counted.
    private static func read(_ path: String, batch: ([FolderFile]) -> Bool) -> Bool {
        switch readInOnePass(path, batch: batch) {
        case .read: return true
        case .unreadable: return false
        case .unsupported: return readFileByFile(path, batch: batch)
        }
    }

    private enum OnePass { case read, unreadable, unsupported }

    /// Reads the folder's entries together with their details, a few thousand per call
    /// (`getattrlistbulk`, as Finder does). Asking for each file's details by name instead (`stat`)
    /// means a separate lookup per file, which on exFAT and FAT drives searches the whole folder each
    /// time: a 26,800-file folder on a USB drive took 3.3 s that way and 0.02 s this way.
    private static func readInOnePass(_ path: String, batch: ([FolderFile]) -> Bool) -> OnePass {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The values come back in this order: common attributes by bit (except the error, see
        // below), then file attributes by bit.
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_ACCESSMASK) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
            | attrgroup_t(ATTR_CMN_ERROR)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            | attrgroup_t(ATTR_FILE_DATALENGTH)
        let neededCommon = request.commonattr & ~attrgroup_t(ATTR_CMN_RETURNED_ATTRS) & ~attrgroup_t(ATTR_CMN_ERROR)
        let neededFile = request.fileattr

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var first = true
        while true {
            // Unsupported attributes are packed too (with zeros), so every entry has the same layout;
            // the returned set says which values are real.
            let count = getattrlistbulk(fd, &request, buffer, capacity, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count < 0 {
                // A drive that can't do this at all says so on the first call: read it file by file.
                // Any other error (a drive unplugged mid-read, say) means the folder wasn't read in
                // full, which is reported rather than passed off as a shorter folder.
                return first && (errno == ENOTSUP || errno == EINVAL || errno == ENOSYS) ? .unsupported : .unreadable
            }
            first = false
            if count == 0 { return .read }
            var files: [FolderFile] = []
            files.reserveCapacity(Int(count))
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                var offset = 0
                func next<T>(_: T.Type) -> T {
                    let value = entry.loadUnaligned(fromByteOffset: offset, as: T.self)
                    offset += MemoryLayout<T>.size
                    return value
                }
                let length = Int(next(UInt32.self))
                let returned = next(attribute_set_t.self)
                // The entry's error, if any, comes right after the returned set (not in bit order).
                let error = returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 ? next(UInt32.self) : 0
                let nameStart = offset
                let nameOffset = Int(next(Int32.self))
                _ = next(UInt32.self)
                let name = String(cString: (entry + nameStart + nameOffset).assumingMemoryBound(to: CChar.self))
                let device = next(dev_t.self)
                let type = next(fsobj_type_t.self)
                let modified = next(timespec.self)
                let access = next(UInt32.self)
                let flags = next(UInt32.self)
                let inode = next(UInt64.self)
                let links = next(UInt32.self)
                let allocated = next(off_t.self)
                let size = next(off_t.self)
                defer { entry += length }

                if type == VDIR.rawValue { continue }
                let facts: FileFacts
                if error == 0, returned.commonattr & neededCommon == neededCommon,
                   returned.fileattr & neededFile == neededFile {
                    facts = FileFacts(size: Int64(size), allocated: Int64(allocated), modified: Int64(modified.tv_sec),
                                      device: FileFacts.normalize(device), inode: inode, links: UInt64(links),
                                      mode: typeBits(type) | (access & 0o7777), flags: flags)
                } else {
                    // This drive left something out for this file: ask for it the usual way.
                    var st = stat()
                    guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    facts = FileFacts(st)
                    if facts.isDirectory { continue }
                }
                files.append(FolderFile(name: name, facts: facts, counted: true))
            }
            if !files.isEmpty, !batch(files) { return .read }
        }
    }

    /// The `stat` file type for a `getattrlistbulk` object type.
    private static func typeBits(_ type: fsobj_type_t) -> UInt32 {
        switch type {
        case VREG.rawValue: return UInt32(S_IFREG)
        case VDIR.rawValue: return UInt32(S_IFDIR)
        case VLNK.rawValue: return UInt32(S_IFLNK)
        case VBLK.rawValue: return UInt32(S_IFBLK)
        case VCHR.rawValue: return UInt32(S_IFCHR)
        case VSOCK.rawValue: return UInt32(S_IFSOCK)
        case VFIFO.rawValue: return UInt32(S_IFIFO)
        default: return UInt32(S_IFREG)
        }
    }

    /// Lists the folder and asks for each file's details by name: for drives that can't do `readInOnePass`.
    static func readFileByFile(_ path: String, batch: ([FolderFile]) -> Bool) -> Bool {
        guard let dir = opendir(path) else { return false }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var files: [FolderFile] = []
        while true {
            // readdir returns nil both at the end and on an error; only an error sets errno.
            errno = 0
            guard let entry = readdir(dir) else { break }
            let name = NameTools.name(of: entry)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let facts = FileFacts(st)
            if facts.isDirectory { continue }
            files.append(FolderFile(name: name, facts: facts, counted: true))
            if files.count == 1_000 {
                guard batch(files) else { return true }
                files.removeAll(keepingCapacity: true)
            }
        }
        let readError = errno
        if !files.isEmpty { _ = batch(files) }
        errno = readError   // for whoever logs why
        return readError == 0
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
        let files = CountedFiles.read(folders, now: now, progress: progress)
        var total = files.tally
        for file in files.linked { file.add(to: &total, now: now) }
        return total
    }
}

/// A file the scan counted that has other hard links: moving it to the Trash frees nothing while
/// another link to it stays in the scan (see `ScanResult.removeFolder`).
struct LinkedFile: Sendable {
    let path: String
    let key: FileKey
    let size: Int64
    let allocated: Int64
    let modified: Int64

    func add(to tally: inout FileTally, now: Int64) {
        tally.add(ext: NameTools.fileExtension(of: (path as NSString).lastPathComponent),
                  size: size, allocated: allocated, modified: modified, now: now)
    }
}

/// The files of some folders as the scan counted them (see `FileTally.read`), with the ones that
/// have other hard links kept apart.
struct CountedFiles: Sendable {
    /// File Types and Ages of the counted files, except `linked`.
    var tally = FileTally()
    var linked: [LinkedFile] = []

    static func read(_ folders: [TallyFolder], now: Int64, progress: ScanProgress) -> CountedFiles {
        let readers = ScanEngine.readers
        let slots = ResultSlots<CountedFiles>(count: readers)
        // As many threads as a scan uses (see `ScanEngine.readers`), each taking every n-th folder.
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            var counted = CountedFiles()
            for index in stride(from: reader, to: folders.count, by: readers) {
                if progress.isCancelled { break }
                let folder = folders[index]
                // Batch by batch: a big folder stops as soon as the count is cancelled, and a folder
                // whose reading fails partway still counts the files read.
                FolderReader.files(in: folder.path, uncounted: folder.uncounted) { batch in
                    for file in batch where file.counted {
                        if file.facts.links > 1 {
                            counted.linked.append(LinkedFile(path: (folder.path as NSString).appendingPathComponent(file.name),
                                                             key: file.facts.key, size: file.facts.size,
                                                             allocated: file.facts.allocated, modified: file.facts.modified))
                        } else {
                            counted.tally.add(ext: NameTools.fileExtension(of: file.name), size: file.facts.size,
                                              allocated: file.facts.allocated, modified: file.facts.modified, now: now)
                        }
                    }
                    return !progress.isCancelled
                }
            }
            slots.set(reader, counted)
        }
        var total = CountedFiles()
        for part in slots.all() {
            total.tally.merge(part.tally)
            total.linked += part.linked
        }
        return total
    }
}
