import Foundation

// MARK: - Folder snapshots

/// The space on disk of the biggest folders in the top levels of one scan, kept so the next scan of
/// the same folder can show which folders grew, shrank, appeared or disappeared.
///
/// Paths are relative to the scanned folder ("Library/Caches"); the scanned folder itself is "".
/// A snapshot *opens* some folders: it records every child folder of an opened folder, and only of
/// opened folders. That is what lets a comparison tell a new folder from one that was never recorded.
/// Bigger folders are opened first, down to `defaultDepth` levels and up to `defaultLimit` folders,
/// so a snapshot stays around a hundred kilobytes even for a whole disk.
struct FolderSnapshot: Codable, Equatable, Sendable {
    /// The scanned folder, as in `HistoryEntry.path`.
    var path: String
    /// When the scan started, as in `HistoryEntry.date`.
    var date: Date
    /// Space on disk of the scanned folder.
    var allocated: Int64
    /// For every opened folder (by relative path): its child folders by name, with their space on disk.
    var children: [String: [String: Int64]]
    /// Set only on a snapshot cut out of a scan of a folder that contains this one: that folder's path.
    var partOf: String?

    static let defaultLimit = 2_000
    static let defaultDepth = 4

    /// Space on disk of a recorded folder, or nil if the snapshot doesn't know it.
    func allocated(at relativePath: String) -> Int64? {
        if relativePath.isEmpty { return allocated }
        let (parent, name) = Self.split(relativePath)
        return children[parent]?[name]
    }

    /// Whether every child folder of this folder is recorded.
    func isOpened(_ relativePath: String) -> Bool { children[relativePath] != nil }

    /// How many folders the snapshot records.
    var folderCount: Int { children.values.reduce(0) { $0 + $1.count } }

    // MARK: Making snapshots

    /// Records a finished scan: opens folders biggest first, at most `maxDepth` levels down, while
    /// the snapshot holds no more than `limit` folders. Folders that couldn't be read and other disks
    /// are recorded but never opened, so reading them later doesn't make their contents look new.
    /// Reads the tree, so call it on the main thread once the scan is done.
    init(root: Node, path: String, date: Date, limit: Int = defaultLimit, maxDepth: Int = defaultDepth) {
        struct Candidate {
            let node: Node
            let path: String
            let depth: Int
        }
        /// Biggest first; then shallower, then by path, so one tree always gives one snapshot.
        func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.node.allocated != b.node.allocated { return a.node.allocated > b.node.allocated }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }

        var opened: [String: [String: Int64]] = [:]
        var recorded = 0
        var candidates = [Candidate(node: root, path: "", depth: 0)]
        while !candidates.isEmpty {
            var best = 0
            for index in candidates.indices.dropFirst() where precedes(candidates[index], candidates[best]) {
                best = index
            }
            candidates.swapAt(best, candidates.count - 1)
            let candidate = candidates.removeLast()
            let node = candidate.node
            guard recorded + node.children.count <= limit else { continue }
            var sizes: [String: Int64] = [:]
            sizes.reserveCapacity(node.children.count)
            for child in node.children {
                sizes[child.name] = child.allocated
                if candidate.depth + 1 < maxDepth, !child.unreadable, !child.otherVolume {
                    candidates.append(Candidate(node: child, path: Self.join(candidate.path, child.name),
                                                depth: candidate.depth + 1))
                }
            }
            opened[candidate.path] = sizes
            recorded += sizes.count
        }
        self.init(path: path, date: date, allocated: root.allocated, children: opened)
    }

    /// Records a finished scan the way `earlier` recorded it: opens exactly the folders `earlier`
    /// opened, wherever they still exist and can be read. This is the "now" side of a comparison,
    /// so it has no size limit (it is never saved).
    init(root: Node, path: String, date: Date, opening earlier: FolderSnapshot) {
        var opened: [String: [String: Int64]] = [:]
        var nodes: [String: Node] = ["": root]
        // A folder's path is shorter than any path inside it, so parents come before their children.
        for folder in earlier.children.keys.sorted(by: { ($0.utf8.count, $0) < ($1.utf8.count, $1) }) {
            guard let node = nodes[folder], !node.unreadable, !node.otherVolume else { continue }
            var sizes: [String: Int64] = [:]
            sizes.reserveCapacity(node.children.count)
            for child in node.children {
                sizes[child.name] = child.allocated
                let childPath = Self.join(folder, child.name)
                if earlier.children[childPath] != nil { nodes[childPath] = child }
            }
            opened[folder] = sizes
        }
        self.init(path: path, date: date, allocated: root.allocated, children: opened)
    }

    init(path: String, date: Date, allocated: Int64, children: [String: [String: Int64]], partOf: String? = nil) {
        self.path = path
        self.date = date
        self.allocated = allocated
        self.children = children
        self.partOf = partOf
    }

    /// The part of this snapshot that covers `folder` (an absolute path inside the scanned folder),
    /// as if `folder` itself had been scanned. Nil unless the snapshot opened that folder.
    func part(at folder: String) -> FolderSnapshot? {
        guard let relative = Self.relativePath(of: folder, inside: path), !relative.isEmpty,
              let size = allocated(at: relative), isOpened(relative) else { return nil }
        let prefix = relative + "/"
        var part: [String: [String: Int64]] = [:]
        for (key, sizes) in children where key == relative || key.hasPrefix(prefix) {
            part[key == relative ? "" : String(key.dropFirst(prefix.count))] = sizes
        }
        return FolderSnapshot(path: folder, date: date, allocated: size, children: part, partOf: partOf ?? path)
    }

    // MARK: Paths

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// "a/b/c" → ("a/b", "c"); "a" → ("", "a").
    static func split(_ relativePath: String) -> (parent: String, name: String) {
        guard let slash = relativePath.lastIndex(of: "/") else { return ("", relativePath) }
        return (String(relativePath[..<slash]), String(relativePath[relativePath.index(after: slash)...]))
    }

    /// "/Users/me/Library/Caches" inside "/Users/me" → "Library/Caches"; the root itself → "".
    /// Nil for a path outside `root`.
    static func relativePath(of path: String, inside root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The absolute path of a relative path inside `root`.
    static func absolutePath(of relativePath: String, inside root: String) -> String {
        if relativePath.isEmpty { return root }
        return (root.hasSuffix("/") ? root : root + "/") + relativePath
    }
}

// MARK: - Changes between two scans

/// One folder that changed between two scans of the same folder.
struct FolderChange: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        /// In both scans. `before` and `after` may be equal.
        case changed
        /// Only in the newer scan.
        case added
        /// Only in the earlier scan.
        case removed
        /// Under another name in the earlier scan (same folder, about the same size).
        case renamed
        /// The loose files directly in the folder at `path` (the tree's "[Files]" entry).
        case files
    }

    let kind: Kind
    /// Relative path now; for a removed folder, where it was.
    let path: String
    let before: Int64
    let after: Int64
    /// The earlier name of a renamed folder.
    var oldName: String?

    var id: String { (kind == .files ? "files:" : "folder:") + path }
    var change: Int64 { after - before }
    /// The size of the change, whichever way it went.
    var amount: Int64 { abs(change) }
    var name: String { kind == .files ? "[Files]" : FolderSnapshot.split(path).name }
    /// The relative path of the folder this row sits in ("" for the scanned folder).
    var folder: String { kind == .files ? path : FolderSnapshot.split(path).parent }
}

/// What changed between an earlier scan and the current one, for every folder both scans opened.
struct FolderComparison: Sendable {
    /// The earlier scan.
    let base: FolderSnapshot
    /// Change of the scanned folder's total.
    let totalChange: Int64
    /// Every change worth listing, biggest first: folders whose size changed, new and removed
    /// folders that take space, renamed folders, and changes in a folder's loose files.
    let changes: [FolderChange]
    /// Folders that exist now and that the earlier scan knew about (unchanged ones too), by relative path.
    private let byPath: [String: FolderChange]

    /// How many listed folders (or loose files) grew or shrank, appeared, disappeared or were renamed.
    let grew: Int
    let shrank: Int
    let added: Int
    let removed: Int
    let renamed: Int

    /// How a folder that exists now changed, by relative path. Nil when the earlier scan didn't
    /// record the folder's parent, so there's nothing to compare with.
    func change(at relativePath: String) -> FolderChange? { byPath[relativePath] }

    /// Compares two snapshots of the same folder. `current` should open the folders `base` opened
    /// (see `FolderSnapshot.init(root:path:date:opening:)`); folders opened by only one are skipped.
    init(base: FolderSnapshot, current: FolderSnapshot) {
        self.base = base
        totalChange = current.allocated - base.allocated
        var list: [FolderChange] = []
        var lookup: [String: FolderChange] = [:]

        for (folder, earlierChildren) in base.children {
            guard let nowChildren = current.children[folder],
                  let earlierTotal = base.allocated(at: folder),
                  let nowTotal = current.allocated(at: folder) else { continue }

            // The folder's own files: whatever its child folders don't account for. In a folder
            // without subfolders that's the folder's own change, already listed, so only the scanned
            // folder (which has no row of its own) and folders with subfolders get a "[Files]" row.
            let filesBefore = earlierTotal - earlierChildren.values.reduce(0, +)
            let filesAfter = nowTotal - nowChildren.values.reduce(0, +)
            let hasSubfolders = !earlierChildren.isEmpty || !nowChildren.isEmpty
            if filesBefore != filesAfter, folder.isEmpty || hasSubfolders {
                list.append(FolderChange(kind: .files, path: folder, before: filesBefore, after: filesAfter))
            }

            var removed: [(name: String, size: Int64)] = []
            var added: [(name: String, size: Int64)] = []
            for (name, before) in earlierChildren {
                let path = FolderSnapshot.join(folder, name)
                if let after = nowChildren[name] {
                    let change = FolderChange(kind: .changed, path: path, before: before, after: after)
                    lookup[path] = change
                    if before != after { list.append(change) }
                } else {
                    removed.append((name, before))
                }
            }
            for (name, after) in nowChildren where earlierChildren[name] == nil {
                added.append((name, after))
            }

            // A folder that disappeared while one of about the same size appeared next to it was
            // most likely renamed. Biggest first, each paired with the closest size.
            removed.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
            for gone in removed where gone.size > 0 {
                var best: Int?
                for (index, new) in added.enumerated() where Self.sameSize(gone.size, new.size) {
                    if best.map({ abs(new.size - gone.size) < abs(added[$0].size - gone.size) }) ?? true {
                        best = index
                    }
                }
                guard let index = best else { continue }
                let new = added.remove(at: index)
                let path = FolderSnapshot.join(folder, new.name)
                let change = FolderChange(kind: .renamed, path: path, before: gone.size, after: new.size, oldName: gone.name)
                lookup[path] = change
                list.append(change)
                removed.removeAll { $0.name == gone.name }
            }
            for gone in removed where gone.size > 0 {
                list.append(FolderChange(kind: .removed, path: FolderSnapshot.join(folder, gone.name), before: gone.size, after: 0))
            }
            for new in added {
                let path = FolderSnapshot.join(folder, new.name)
                let change = FolderChange(kind: .added, path: path, before: 0, after: new.size)
                lookup[path] = change
                if new.size > 0 { list.append(change) }
            }
        }

        changes = list.sorted { a, b in
            if a.amount != b.amount { return a.amount > b.amount }
            return a.id < b.id
        }
        byPath = lookup
        grew = changes.filter { ($0.kind == .changed || $0.kind == .files) && $0.change > 0 }.count
        shrank = changes.filter { ($0.kind == .changed || $0.kind == .files) && $0.change < 0 }.count
        added = changes.filter { $0.kind == .added }.count
        removed = changes.filter { $0.kind == .removed }.count
        renamed = changes.filter { $0.kind == .renamed }.count
    }

    /// Close enough in size to be the same folder under a new name: within 1 %.
    private static func sameSize(_ a: Int64, _ b: Int64) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) <= max(a, b) / 100
    }
}

// MARK: - Storing snapshots

/// Keeps the latest snapshots of recently scanned folders in `snapshots.json`, next to the scan
/// history: the last `perRoot` scans of each of the `maxRoots` folders scanned most recently, and
/// never more than `maxBytes`. The scan history (`history.json`) is left as it was, so earlier
/// versions of DiskLens still read it; without this file there's simply nothing to compare with yet.
struct SnapshotStore: Sendable {
    let folder: URL
    var perRoot = 2
    var maxRoots = 10
    var maxBytes = 3_000_000

    static let standard = SnapshotStore(folder: HistoryStore.folderURL)

    /// The file format. A newer DiskLens may write a higher version; this one then leaves the file alone.
    static let version = 1

    private struct StoredFile: Codable {
        var version: Int
        var snapshots: [FolderSnapshot]
    }

    private struct Header: Decodable {
        var version: Int
    }

    /// Every read and write goes through this queue, so two scans finishing together can't
    /// overwrite each other's snapshots.
    private static let queue = DispatchQueue(label: "local.disklens.snapshots")

    var fileURL: URL { folder.appendingPathComponent("snapshots.json") }

    /// Saves the snapshot of a scan that just finished, and returns the earlier snapshots it can be
    /// compared with, newest first: earlier scans of the same folder or, if there are none, the parts
    /// of earlier scans of a folder that contains it. Call it off the main thread (it reads and writes a file).
    func record(_ snapshot: FolderSnapshot) -> [FolderSnapshot] {
        Self.queue.sync {
            guard var all = load() else {
                // Written by a newer DiskLens: compare with nothing rather than overwrite it.
                return []
            }
            let earlier = all
                .filter { $0.path == snapshot.path && $0.date < snapshot.date }
                .sorted { $0.date > $1.date }
            var bases = Array(earlier.prefix(perRoot))
            if bases.isEmpty {
                bases = Array(all
                    .filter { $0.date < snapshot.date }
                    .compactMap { $0.part(at: snapshot.path) }
                    .sorted { $0.date > $1.date }
                    .prefix(perRoot))
            }

            all.removeAll { $0.path == snapshot.path && $0.date == snapshot.date }
            all.append(snapshot)
            save(pruned(all, keeping: snapshot.path))
            return bases
        }
    }

    /// All stored snapshots. Empty when there's no file yet; nil when a newer DiskLens wrote it.
    /// A damaged file is kept as `snapshots-damaged.json` and DiskLens starts over.
    func load() -> [FolderSnapshot]? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.version > Self.version {
                Log.app.info("Folder snapshots were written by a newer DiskLens (format \(header.version)); leaving them alone")
                return nil
            }
            return try JSONDecoder().decode(StoredFile.self, from: data).snapshots
        } catch {
            Log.app.error("Folder snapshots unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            let backup = folder.appendingPathComponent("snapshots-damaged.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    /// The file to write: the newest `perRoot` snapshots of each of the `maxRoots` most recently
    /// scanned folders, dropping the folders scanned longest ago until it fits in `maxBytes`.
    /// `keeping` (the folder just scanned) always stays.
    private func pruned(_ snapshots: [FolderSnapshot], keeping current: String) -> Data? {
        var byRoot: [String: [FolderSnapshot]] = [:]
        for snapshot in snapshots { byRoot[snapshot.path, default: []].append(snapshot) }
        var roots = byRoot.map { path, list in
            (path: path, snapshots: Array(list.sorted { $0.date > $1.date }.prefix(max(1, perRoot))))
        }
        // Most recently scanned first, the folder just scanned before all others.
        roots.sort { a, b in
            if (a.path == current) != (b.path == current) { return a.path == current }
            return (a.snapshots.first?.date ?? .distantPast) > (b.snapshots.first?.date ?? .distantPast)
        }
        roots = Array(roots.prefix(max(1, maxRoots)))
        while true {
            let data = try? JSONEncoder().encode(StoredFile(version: Self.version, snapshots: roots.flatMap(\.snapshots)))
            guard let data, data.count > maxBytes, roots.count > 1 else { return data }
            roots.removeLast()
        }
    }

    private func save(_ data: Data?) {
        do {
            guard let data else { throw CocoaError(.coderInvalidValue) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't save folder snapshots: \(error.localizedDescription, privacy: .public)")
        }
    }
}
