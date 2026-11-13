import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thread-safe progress counters and the cancel flag for one scan.
final class ScanProgress: @unchecked Sendable {
    struct Snapshot {
        var files = 0
        var folders = 0
        var bytes: Int64 = 0
        var currentPath = ""
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var cancelled = false

    func add(files: Int, folders: Int, bytes: Int64, currentPath: String?) {
        lock.lock()
        snapshot.files += files
        snapshot.folders += folders
        snapshot.bytes += bytes
        if let currentPath { snapshot.currentPath = currentPath }
        lock.unlock()
    }

    func read() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
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
    var isDirectory: Bool

    init(_ st: stat) {
        size = Int64(st.st_size)
        allocated = Int64(st.st_blocks) * 512          // st_blocks counts 512-byte blocks
        inode = UInt64(st.st_ino)
        links = UInt64(st.st_nlink)
        mode = UInt32(st.st_mode)
        isDirectory = (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
        device = FileFacts.normalize(st.st_dev)
        #if canImport(Darwin)
        modified = Int64(st.st_mtimespec.tv_sec)
        #else
        modified = Int64(st.st_mtim.tv_sec)
        #endif
    }

    var key: FileKey { FileKey(device: device, inode: inode) }
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
        hardLinkDuplicates += other.hardLinkDuplicates
        statErrors += other.statErrors
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
        let chunkSize = 32
        let chunks = (folders.count + chunkSize - 1) / chunkSize
        let slots = ResultSlots<FileTally>(count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var tally = FileTally()
            for folder in folders[(chunk * chunkSize)..<min(folders.count, (chunk + 1) * chunkSize)] {
                if progress.isCancelled { break }
                for file in FolderReader.files(in: folder.path, uncounted: folder.uncounted) ?? [] where file.counted {
                    tally.add(ext: NameTools.fileExtension(of: file.name), size: file.facts.size,
                              allocated: file.facts.allocated, modified: file.facts.modified, now: now)
                }
            }
            slots.set(chunk, tally)
        }
        var total = FileTally()
        for tally in slots.all() { total.merge(tally) }
        return total
    }
}
