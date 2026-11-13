import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Search (⌘F) finds folders and files by name within the current scan.
//
// Folders are all in memory, so they are searched instantly, along with Top Files. Individual
// files are not kept after a scan (only per-folder totals, to keep memory low), so files are
// found by reading the scanned folders again in the background. That pass lists each folder's
// names and looks at a file's details only when its name matches, keeps only the largest
// matches, and stops as soon as the query changes.
//
// Threading: the folder tree stays on the main thread. `SearchIndex.build` copies what search
// needs into flat arrays on the main thread; matching and reading folders then run on
// background threads using only that copy.

// MARK: - Matching

/// What the user typed, prepared once so that many names can be checked quickly.
/// A name matches when it contains every word of the query, in any order, ignoring case, accents
/// and full-width forms: "resume 2024" finds "Résumé (2024).pdf", and ".dmg" finds disk images.
struct SearchQuery: Sendable, Equatable {
    /// The query without surrounding spaces.
    let text: String
    /// Each word, folded, as UTF-8.
    let terms: [[UInt8]]

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed
        terms = trimmed.split(whereSeparator: \.isWhitespace)
            .map { Array(Self.fold(String($0)).utf8) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// The words as typed, for highlighting them in results.
    var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    func matches(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { matches(utf8: UnsafeRawBufferPointer($0)) }
    }

    /// `name` is a name's UTF-8 bytes, from a String or straight from `readdir`.
    func matches(utf8 name: UnsafeRawBufferPointer) -> Bool {
        guard !terms.isEmpty else { return false }
        var isASCII = true
        for byte in name where byte >= 0x80 {
            isASCII = false
            break
        }
        if isASCII {
            // Folding an ASCII name only lowers its case, which `contains` does byte by byte.
            for term in terms where !Self.contains(name, term, lowercasing: true) { return false }
            return true
        }
        let folded = Array(Self.fold(String(decoding: name, as: UTF8.self)).utf8)
        return folded.withUnsafeBytes { buffer in
            terms.allSatisfy { Self.contains(buffer, $0, lowercasing: false) }
        }
    }

    /// Lower case, no accents, no full-width forms, composed: "Re\u{301}SUME\u{301}" becomes "resume".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8], lowercasing: Bool) -> Bool {
        needle.withUnsafeBufferPointer { needle in
            let count = needle.count
            guard count > 0 else { return true }
            guard count <= haystack.count else { return false }
            var start = 0
            let last = haystack.count - count
            while start <= last {
                var matched = 0
                while matched < count {
                    var byte = haystack[start + matched]
                    if lowercasing && byte >= 0x41 && byte <= 0x5A { byte += 0x20 }
                    if byte != needle[matched] { break }
                    matched += 1
                }
                if matched == count { return true }
                start += 1
            }
            return false
        }
    }
}

// MARK: - Results

/// A folder or file whose name matches.
struct SearchHit: Identifiable, Sendable, Equatable {
    enum Kind: Sendable { case folder, file }

    let kind: Kind
    let name: String
    /// For a folder, its position in the `SearchIndex`. For a file, the position of the folder it
    /// is in, or -1 when that isn't known yet (a Top Files entry, found without reading folders).
    let folder: Int32
    let size: Int64
    let allocated: Int64
    /// Absolute path. Set when a file is found; set for a folder once it makes the final list.
    var path: String
    /// False for a hard link whose space the scan counted through another link to the same file.
    /// Its On Disk is 0, as in Details.
    var counted = true

    var id: String { path }

    /// What results are ranked by: logical size in the Size mode, otherwise space on disk.
    func measure(bySize: Bool) -> Int64 { bySize ? size : allocated }

    /// Largest first; equal sizes put folders first, then go by name.
    static func precedes(_ a: SearchHit, _ b: SearchHit, bySize: Bool) -> Bool {
        let first = a.measure(bySize: bySize)
        let second = b.measure(bySize: bySize)
        if first != second { return first > second }
        if a.kind != b.kind { return a.kind == .folder }
        if a.name != b.name { return a.name < b.name }
        if a.folder != b.folder { return a.folder < b.folder }
        return a.path < b.path
    }
}

/// Keeps the largest matches seen so far (a min-heap of at most `capacity`) and counts every match,
/// so a broad query ("a") never holds more than a page of results in memory.
struct LargestHits: Sendable {
    let capacity: Int
    let bySize: Bool
    private(set) var heap: [SearchHit] = []
    /// Every match counted, kept or not.
    private(set) var matched = 0

    init(capacity: Int, bySize: Bool) {
        self.capacity = max(0, capacity)
        self.bySize = bySize
    }

    /// Whether a match of this size could be kept. Lets callers skip building a hit that would be dropped.
    func wants(_ measure: Int64) -> Bool {
        capacity > 0 && (heap.count < capacity || measure >= heap[0].measure(bySize: bySize))
    }

    /// Counts a match that was not built because `wants` said it would be dropped.
    mutating func count() { matched += 1 }

    mutating func add(_ hit: SearchHit) {
        matched += 1
        keep(hit)
    }

    /// Adds another collection's matches and counts.
    mutating func merge(_ other: LargestHits) {
        matched += other.matched
        for hit in other.heap { keep(hit) }
    }

    /// Sets the path of every kept match that has none. Folders are distinct by position, so this
    /// never changes their order.
    mutating func fillPaths(_ path: (SearchHit) -> String) {
        for i in heap.indices where heap[i].path.isEmpty {
            heap[i].path = path(heap[i])
        }
    }

    /// The kept matches, largest first.
    func sorted() -> [SearchHit] {
        heap.sorted { SearchHit.precedes($0, $1, bySize: bySize) }
    }

    private mutating func keep(_ hit: SearchHit) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(hit)
            siftUp(heap.count - 1)
        } else if SearchHit.precedes(hit, heap[0], bySize: bySize) {
            heap[0] = hit
            siftDown(0)
        }
    }

    /// The heap keeps the match that would be listed last at the top, ready to be replaced.
    private func below(_ i: Int, _ j: Int) -> Bool {
        SearchHit.precedes(heap[j], heap[i], bySize: bySize)
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard below(child, parent) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var lowest = parent
            if left < heap.count && below(left, lowest) { lowest = left }
            if right < heap.count && below(right, lowest) { lowest = right }
            if lowest == parent { return }
            heap.swapAt(parent, lowest)
            parent = lowest
        }
    }
}

// MARK: - Index

/// The scan's folders as flat arrays, so they can be searched off the main thread while the
/// folder tree itself is only ever touched on the main thread. Position 0 is the scan's root;
/// every folder comes after its parent.
struct SearchIndex: Sendable {
    /// A folder whose own files can be read again: readable, on the scanned disk, with files.
    struct FileFolder: Sendable {
        let folder: Int32
        let ownAllocated: Int64
        /// The folder's `Node.uncountedLinks`, so hard links come out as the scan counted them.
        let uncounted: [FileKey: Int]?
    }

    let rootPath: String
    let rootName: String
    let topFiles: [TopFile]
    private(set) var names: [String] = []
    private(set) var parents: [Int32] = []
    private(set) var sizes: [Int64] = []
    private(set) var allocated: [Int64] = []
    private(set) var fileFolders: [FileFolder] = []

    var count: Int { names.count }

    /// Copies the tree below `root` into an index. Main thread (it reads the tree). Also returns
    /// each folder's node, in index order, for turning a hit back into a folder on the main thread.
    static func build(root: Node, rootPath: String, rootName: String, topFiles: [TopFile]) -> (index: SearchIndex, nodes: [Node]) {
        var index = SearchIndex(rootPath: rootPath, rootName: rootName, topFiles: topFiles)
        var nodes: [Node] = []
        let expected = root.folderCount + 1
        index.names.reserveCapacity(expected)
        index.parents.reserveCapacity(expected)
        index.sizes.reserveCapacity(expected)
        index.allocated.reserveCapacity(expected)
        nodes.reserveCapacity(expected)

        var stack: [(node: Node, parent: Int32)] = [(root, -1)]
        while let (node, parent) = stack.popLast() {
            let position = Int32(index.names.count)
            index.names.append(node.name)
            index.parents.append(parent)
            index.sizes.append(node.size)
            index.allocated.append(node.allocated)
            nodes.append(node)
            if !node.unreadable && !node.otherVolume && (node.ownFileCount > 0 || node.uncountedLinks != nil) {
                index.fileFolders.append(FileFolder(folder: position, ownAllocated: node.ownAllocated,
                                                    uncounted: node.uncountedLinks))
            }
            for child in node.children.reversed() where child.kind == .directory {
                stack.append((child, position))
            }
        }
        return (index, nodes)
    }

    private init(rootPath: String, rootName: String, topFiles: [TopFile]) {
        self.rootPath = rootPath
        self.rootName = rootName
        self.topFiles = topFiles
    }

    /// The names of the folders from just below the root down to `folder` (empty for the root).
    func components(of folder: Int32) -> [String] {
        var list: [String] = []
        var current = folder
        while current > 0 {
            list.append(names[Int(current)])
            current = parents[Int(current)]
        }
        return list.reversed()
    }

    func path(of folder: Int32) -> String {
        Self.join(rootPath, components(of: folder))
    }

    /// Where a hit sits inside the scan: the folder it is in, short enough for one line.
    func location(of hit: SearchHit) -> String {
        switch hit.kind {
        case .folder:
            return Self.describe(components(of: hit.folder).dropLast(), rootName: rootName)
        case .file:
            if hit.folder >= 0 { return Self.describe(components(of: hit.folder), rootName: rootName) }
            return Self.describe(Self.components(of: (hit.path as NSString).deletingLastPathComponent,
                                                 below: rootPath), rootName: rootName)
        }
    }

    /// "Library › Caches" for a short path, "Library › … › Cache" for a longer one (the first and
    /// last folders, with the middle left out), and the scan's name for its top level.
    static func describe<C: Collection>(_ components: C, rootName: String) -> String where C.Element == String {
        let parts = Array(components)
        switch parts.count {
        case 0: return rootName
        case 1...2: return parts.joined(separator: " › ")
        default: return "\(parts[0]) › … › \(parts[parts.count - 1])"
        }
    }

    /// The folders of `path` below `rootPath` ([] for the root itself or a path outside it).
    static func components(of path: String, below rootPath: String) -> [String] {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    static func join(_ base: String, _ names: [String]) -> String {
        var result = base
        for name in names {
            if !result.hasSuffix("/") { result += "/" }
            result += name
        }
        return result
    }
}

// MARK: - Searching

enum ScanSearch {
    /// At most this many folders and this many files are kept and listed.
    static let limit = 500

    /// Folders whose names match, largest first, with their paths filled in. No disk access.
    /// The scan's root itself is not a result.
    static func folders(in index: SearchIndex, matching query: SearchQuery, bySize: Bool,
                        limit: Int = limit) -> LargestHits {
        var found = LargestHits(capacity: limit, bySize: bySize)
        guard !query.isEmpty, index.count > 1 else { return found }
        for position in 1..<index.count where query.matches(index.names[position]) {
            let measure = bySize ? index.sizes[position] : index.allocated[position]
            guard found.wants(measure) else {
                found.count()
                continue
            }
            found.add(SearchHit(kind: .folder, name: index.names[position], folder: Int32(position),
                                size: index.sizes[position], allocated: index.allocated[position], path: ""))
        }
        // Paths only for the folders kept: building one for every match of a broad query would be slow.
        found.fillPaths { index.path(of: $0.folder) }
        return found
    }

    /// Top Files entries whose names match. No disk access.
    static func topFiles(in index: SearchIndex, matching query: SearchQuery, bySize: Bool,
                         limit: Int = limit) -> LargestHits {
        var found = LargestHits(capacity: limit, bySize: bySize)
        guard !query.isEmpty else { return found }
        for file in index.topFiles where query.matches(file.name) {
            found.add(SearchHit(kind: .file, name: file.name, folder: -1, size: file.size,
                                allocated: file.allocated, path: file.path))
        }
        return found
    }

    /// Puts folders and files (from Top Files and from reading folders) into one list, largest
    /// first, without listing a file twice.
    static func merge(folders: LargestHits, files: [LargestHits], bySize: Bool, limit: Int = limit) -> [SearchHit] {
        var seen = Set<String>()
        var list = folders.heap
        for group in files {
            for hit in group.heap where seen.insert(hit.path).inserted {
                list.append(hit)
            }
        }
        list.sort { SearchHit.precedes($0, $1, bySize: bySize) }
        return Array(list.prefix(limit))
    }
}

// MARK: - Reading folders for files

/// Finds files by name by reading the scanned folders again, on background threads.
/// Shared between the thread that reads and the main thread, which shows what has been found so
/// far and can cancel; everything mutable is behind the lock.
final class FileSearch: @unchecked Sendable {
    struct Snapshot: Sendable {
        var found: LargestHits
        var foldersRead: Int
        var foldersTotal: Int
        var finished: Bool

        var fraction: Double { foldersTotal > 0 ? Double(foldersRead) / Double(foldersTotal) : 1 }
    }

    let query: SearchQuery
    let bySize: Bool
    private let index: SearchIndex
    private let limit: Int
    private let lock = NSLock()
    private var found: LargestHits
    private var foldersRead = 0
    private var finished = false
    private var cancelled = false

    init(index: SearchIndex, query: SearchQuery, bySize: Bool, limit: Int = ScanSearch.limit) {
        self.index = index
        self.query = query
        self.bySize = bySize
        self.limit = limit
        found = LargestHits(capacity: limit, bySize: bySize)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(found: found, foldersRead: foldersRead, foldersTotal: index.fileFolders.count, finished: finished)
    }

    /// Reads every folder that has files, in parallel, and returns when done or cancelled.
    /// Folders whose own files take the most space go first, so big matches turn up early.
    func run() {
        guard !query.isEmpty else {
            markFinished()
            return
        }
        let folders = index.fileFolders.sorted { $0.ownAllocated > $1.ownAllocated }
        let chunkSize = 64
        let chunks = (folders.count + chunkSize - 1) / chunkSize
        let readers = ScanEngine.readers
        // As many threads as a scan uses (see `ScanEngine.readers`), each taking every n-th chunk,
        // so the biggest folders are still read first. Matches show up chunk by chunk.
        DispatchQueue.concurrentPerform(iterations: readers) { reader in
            for chunk in stride(from: reader, to: chunks, by: readers) {
                var local = LargestHits(capacity: limit, bySize: bySize)
                var read = 0
                for entry in folders[(chunk * chunkSize)..<min(folders.count, (chunk + 1) * chunkSize)] {
                    if isCancelled { return }
                    let path = index.path(of: entry.folder)
                    FolderReader.files(in: path, matching: query, uncounted: entry.uncounted) { name, facts, counted in
                        let allocated = counted ? facts.allocated : 0
                        guard local.wants(bySize ? facts.size : allocated) else {
                            local.count()
                            return
                        }
                        local.add(SearchHit(kind: .file, name: name, folder: entry.folder, size: facts.size,
                                            allocated: allocated, path: SearchIndex.join(path, [name]), counted: counted))
                    }
                    read += 1
                }
                lock.lock()
                found.merge(local)
                foldersRead += read
                lock.unlock()
            }
        }
        markFinished()
    }

    private func markFinished() {
        lock.lock()
        finished = !cancelled
        lock.unlock()
    }
}

extension FolderReader {
    private static let nameCapacity = MemoryLayout.size(ofValue: dirent().d_name)

    /// Calls `found` for each file (not folder) directly in `path` whose name matches. Names are
    /// checked as they are listed and only matching files are looked at, so a folder of thousands
    /// of files costs one listing. `uncounted` is the folder's `Node.uncountedLinks`: a hard link
    /// the scan counted through another link comes out with `counted` false, exactly as in Details.
    static func files(in path: String, matching query: SearchQuery, uncounted: [FileKey: Int]?,
                      found: (_ name: String, _ facts: FileFacts, _ counted: Bool) -> Void) {
        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var linkCounted: [String: Bool]?
        while let entry = readdir(dir) {
            let matches = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { name in
                    query.matches(utf8: UnsafeRawBufferPointer(start: name, count: strlen(name)))
                }
            }
            guard matches, Int32(entry.pointee.d_type) != Int32(DT_DIR) else { continue }
            let name = NameTools.name(of: entry)
            if name == "." || name == ".." { continue }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let facts = FileFacts(st)
            if facts.isDirectory { continue }
            var counted = true
            if facts.links > 1, let uncounted, uncounted[facts.key] != nil {
                // Which links the scan left uncounted depends on the order the folder lists them,
                // so ask the reader Details uses (rare: only folders with such hard links).
                if linkCounted == nil {
                    var map: [String: Bool] = [:]
                    for file in files(in: path, uncounted: uncounted) ?? [] { map[file.name] = file.counted }
                    linkCounted = map
                }
                counted = linkCounted?[name] ?? true
            }
            found(name, facts, counted)
        }
    }
}
