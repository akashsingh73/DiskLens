import Foundation

/// One folder in a scan (or the "[Files]" pseudo-entry that stands for a folder's loose files).
/// Only folders are stored; individual files are summed into their folder to keep memory low.
///
/// Threading: a tree is built by the scanner's worker threads (each branch by exactly one worker),
/// then handed to the main thread, which is the only thread that reads or changes it afterwards.
/// That hand-over is why it is marked `@unchecked Sendable`.
final class Node: Identifiable, @unchecked Sendable {
    enum Kind { case directory, files }

    let kind: Kind
    var name: String
    /// Weak, so a node kept by a stale view never points at freed memory.
    weak var parent: Node?
    var children: [Node] = []

    /// Set only on the scan root: the absolute path that was scanned.
    var rootPath: String?

    // Totals for the whole branch.
    var size: Int64 = 0          // logical bytes (what the files say they contain)
    var allocated: Int64 = 0     // bytes actually used on disk
    var fileCount: Int = 0
    var folderCount: Int = 0
    var newest: Int64 = 0        // newest modification time in the branch (seconds since 1970)

    // Files directly inside this folder.
    var ownSize: Int64 = 0
    var ownAllocated: Int64 = 0
    var ownFileCount: Int = 0
    var ownNewest: Int64 = 0

    var unreadable = false       // could not be opened (permissions)
    var otherVolume = false      // a mount point for another disk; not scanned
    var cloudOnly = false        // only in the cloud (iCloud Drive, Google Drive…); not read (yet)
    var pending = false          // still being read; its contents arrive later (see `adopt`)
    var unreadableCount = 0      // unreadable folders anywhere in this branch

    /// Hard links directly in this folder that were not counted, because the scan had already
    /// counted the same file through another link, and how many such links each file has here.
    /// nil when there are none (almost every folder).
    private(set) var uncountedLinks: [FileKey: Int]?

    private var cachedFilesNode: Node?

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, kind: Kind = .directory, parent: Node?) {
        self.name = name
        self.kind = kind
        self.parent = parent
    }

    var isRoot: Bool { parent == nil }

    /// A pseudo-node that represents the files sitting directly in this folder.
    var filesNode: Node? {
        guard kind == .directory, ownFileCount > 0 else { return nil }
        if let cached = cachedFilesNode { return cached }
        let node = Node(name: "[Files]", kind: .files, parent: self)
        node.size = ownSize
        node.allocated = ownAllocated
        node.fileCount = ownFileCount
        node.newest = ownNewest
        node.ownSize = ownSize
        node.ownAllocated = ownAllocated
        node.ownFileCount = ownFileCount
        node.ownNewest = ownNewest
        cachedFilesNode = node
        return node
    }

    /// The folder whose contents this node shows (a "[Files]" node shows its parent's files).
    var directory: Node { kind == .files ? (parent ?? self) : self }

    /// Absolute path on disk.
    var path: String {
        if kind == .files, let parent { return parent.path }
        var names: [String] = []
        var current: Node? = self
        while let node = current {
            if let rootPath = node.rootPath {
                var result = rootPath
                for name in names.reversed() {
                    if !result.hasSuffix("/") { result += "/" }
                    result += name
                }
                return result
            }
            names.append(node.name)
            current = node.parent
        }
        return "/" + names.reversed().joined(separator: "/")
    }

    var depth: Int {
        var d = 0
        var current = parent
        while let node = current { d += 1; current = node.parent }
        return d
    }

    /// Ancestors from the root down to (not including) this node.
    var ancestors: [Node] {
        var list: [Node] = []
        var current = parent
        while let node = current { list.append(node); current = node.parent }
        return list.reversed()
    }

    /// The root, then every folder down to and including this node.
    var chain: [Node] { ancestors + [self] }

    /// True when `ancestor` contains this node (at any depth).
    func isInside(_ ancestor: Node) -> Bool {
        var current = parent
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }

    /// Recomputes branch totals from the folder's own files and its (already final) children.
    func finalize() {
        var size = ownSize
        var allocated = ownAllocated
        var files = ownFileCount
        var folders = 0
        var newest = ownNewest
        var unreadable = self.unreadable ? 1 : 0
        for child in children {
            size += child.size
            allocated += child.allocated
            files += child.fileCount
            folders += child.folderCount + 1
            if child.newest > newest { newest = child.newest }
            unreadable += child.unreadableCount
        }
        self.size = size
        self.allocated = allocated
        self.fileCount = files
        self.folderCount = folders
        self.newest = newest
        self.unreadableCount = unreadable
        children.sort { $0.allocated > $1.allocated }
        cachedFilesNode = nil
    }

    // MARK: - Hard links

    /// Called by the scanner for a hard link it skipped because the file was already counted.
    func noteUncountedLink(_ key: FileKey) {
        var links = uncountedLinks ?? [:]
        uncountedLinks = nil                  // keep one reference, so the change happens in place
        links[key, default: 0] += 1
        uncountedLinks = links
    }

    /// Uncounted hard links in this folder and every folder below it.
    var uncountedLinksBelow: Int {
        var total = 0
        var stack: [Node] = [self]
        while let node = stack.popLast() {
            total += node.uncountedLinks?.values.reduce(0, +) ?? 0
            stack.append(contentsOf: node.children)
        }
        return total
    }

    /// Forgets one uncounted hard link (moved to the Trash). The folder's totals don't change.
    func forgetUncountedLink(_ key: FileKey) {
        guard var links = uncountedLinks, let count = links[key] else { return }
        links[key] = count > 1 ? count - 1 : nil
        uncountedLinks = links.isEmpty ? nil : links
    }

    // MARK: - Filling in a folder read later

    /// Takes over the contents of `scanned` (this same folder, read on another thread into a
    /// tree of its own) and updates the totals of every folder above. This is how folders read
    /// during a scan, and cloud folders read after it, appear in a tree that is already on screen.
    /// Main thread once the tree is shown.
    func adopt(contentsOf scanned: Node) {
        let before = (size: size, allocated: allocated, files: fileCount, folders: folderCount,
                      unreadable: unreadableCount)
        children = scanned.children
        for child in children { child.parent = self }
        ownSize = scanned.ownSize
        ownAllocated = scanned.ownAllocated
        ownFileCount = scanned.ownFileCount
        ownNewest = scanned.ownNewest
        uncountedLinks = scanned.uncountedLinks
        unreadable = scanned.unreadable
        cloudOnly = scanned.cloudOnly
        pending = false
        finalize()
        scanned.children = []

        var current = parent
        while let node = current {
            node.size += size - before.size
            node.allocated += allocated - before.allocated
            node.fileCount += fileCount - before.files
            node.folderCount += folderCount - before.folders
            node.unreadableCount += unreadableCount - before.unreadable
            if newest > node.newest { node.newest = newest }
            current = node.parent
        }
    }

    // MARK: - Updates after a deletion

    /// Removes a child folder (moved to the Trash) and subtracts it from every ancestor.
    func removeChild(_ child: Node) {
        guard children.contains(where: { $0 === child }) else { return }
        children.removeAll { $0 === child }
        var current: Node? = self
        while let node = current {
            node.size = max(0, node.size - child.size)
            node.allocated = max(0, node.allocated - child.allocated)
            node.fileCount = max(0, node.fileCount - child.fileCount)
            node.folderCount = max(0, node.folderCount - child.folderCount - 1)
            node.unreadableCount = max(0, node.unreadableCount - child.unreadableCount)
            current = node.parent
        }
    }

    /// Subtracts one file that sat directly in this folder (moved to the Trash).
    func removeOwnFile(size: Int64, allocated: Int64) {
        guard ownFileCount > 0 else { return }
        ownSize = max(0, ownSize - size)
        ownAllocated = max(0, ownAllocated - allocated)
        ownFileCount -= 1
        // Update the "[Files]" entry in place, so anything showing it keeps the same entry.
        if let files = cachedFilesNode {
            if ownFileCount == 0 {
                cachedFilesNode = nil
            } else {
                files.size = ownSize
                files.allocated = ownAllocated
                files.fileCount = ownFileCount
                files.ownSize = ownSize
                files.ownAllocated = ownAllocated
                files.ownFileCount = ownFileCount
            }
        }
        var current: Node? = self
        while let node = current {
            node.size = max(0, node.size - size)
            node.allocated = max(0, node.allocated - allocated)
            node.fileCount = max(0, node.fileCount - 1)
            current = node.parent
        }
    }

    /// Finds the folder node for an absolute path inside this scan (self must be the root).
    func descendant(atPath target: String) -> Node? {
        guard let rootPath else { return nil }
        if target == rootPath { return self }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let relative = target.dropFirst(prefix.count)
        var node: Node = self
        for component in relative.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }
}
