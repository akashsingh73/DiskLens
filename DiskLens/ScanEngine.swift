import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Walks a folder tree once and builds the Node tree plus statistics.
///
/// Accuracy rules:
/// - Space on disk is `st_blocks × 512` (sparse, compressed and cloud-evicted files report honestly).
/// - Hard-linked files are counted once.
/// - The scan never leaves the starting volume; other disks mounted inside are marked, not entered.
/// - Symbolic links are not followed.
enum ScanEngine {
    static func scan(path: String, displayName: String, topCount: Int, progress: ScanProgress) -> ScanOutcome {
        let started = Date()
        let now = Int64(started.timeIntervalSince1970)

        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            let code = errno
            return .failed(failureMessage(code, name: displayName))
        }
        let rootFacts = FileFacts(rootStat)
        guard rootFacts.isDirectory else { return .failed("“\(displayName)” is not a folder.") }
        // Make sure the folder can be listed at all before building anything.
        guard let probe = opendir(path) else {
            let code = errno
            return .failed(failureMessage(code, name: displayName))
        }
        closedir(probe)
        let rootDevice = rootFacts.device
        let links = HardLinkRegistry()

        let root = Node(name: displayName, parent: nil)
        root.rootPath = path
        var main = ScanAccumulator(topCount: topCount)

        // Read the first two levels directly, then scan each deeper branch on its own core.
        let firstLevel = listFolder(path: path, folder: root, rootDevice: rootDevice,
                                    acc: &main, links: links, now: now)
        var jobs: [(path: String, node: Node)] = []
        for entry in firstLevel {
            if progress.isCancelled { return .cancelled }
            jobs += listFolder(path: entry.path, folder: entry.node, rootDevice: rootDevice,
                               acc: &main, links: links, now: now)
        }
        main.flush(to: progress, currentPath: path)

        let branches = jobs
        let collector = ResultSlots<ScanAccumulator>(count: branches.count)
        DispatchQueue.concurrentPerform(iterations: branches.count) { index in
            if progress.isCancelled { return }
            var acc = ScanAccumulator(topCount: topCount)
            let job = branches[index]
            scanBranch(path: job.path, root: job.node, rootDevice: rootDevice,
                       acc: &acc, links: links, progress: progress, now: now)
            acc.flush(to: progress, currentPath: nil)
            collector.set(index, acc)
        }
        if progress.isCancelled { return .cancelled }

        // Branches were finalized by their workers; now the two levels read directly.
        for entry in firstLevel { entry.node.finalize() }
        root.finalize()

        for acc in collector.all() { main.merge(acc) }

        let result = ScanResult(root: root, rootPath: path, displayName: displayName, started: started)
        result.duration = Date().timeIntervalSince(started)
        result.extensions = main.tally.extensions
        result.ageAllocated = main.tally.ageAllocated
        result.ageCounts = main.tally.ageCounts
        result.topFiles = main.top.sortedDescending()
        result.unreadableFolders = main.unreadable
        result.unreadableSamples = main.unreadableSamples
        result.otherVolumeFolders = main.otherVolumes
        result.hardLinkDuplicates = main.hardLinkDuplicates
        result.statErrors = main.statErrors
        return .finished(result)
    }

    /// A sentence for the user explaining why a folder couldn't be scanned.
    static func failureMessage(_ code: Int32, name: String) -> String {
        if code == EPERM || code == EACCES {
            return "DiskLens isn't allowed to read “\(name)”. Turn on Full Disk Access for DiskLens in System Settings ▸ Privacy & Security, then quit and reopen DiskLens."
        }
        if code == ENOENT {
            return "“\(name)” no longer exists."
        }
        return "Couldn't read “\(name)”: \(String(cString: strerror(code)))."
    }

    /// Lists one folder directly: adds its files to `folder` and returns subfolders still to scan.
    static func listFolder(path: String, folder: Node, rootDevice: UInt64,
                           acc: inout ScanAccumulator, links: HardLinkRegistry,
                           now: Int64) -> [(path: String, node: Node)] {
        guard let dir = opendir(path) else {
            folder.unreadable = true
            acc.noteUnreadable(path)
            return []
        }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var subfolders: [(path: String, node: Node)] = []

        while let entry = readdir(dir) {
            let name = NameTools.name(of: entry)
            if name == "." || name == ".." { continue }

            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                acc.statErrors += 1
                continue
            }
            let facts = FileFacts(st)
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name

            if facts.isDirectory {
                let child = Node(name: name, parent: folder)
                folder.children.append(child)
                acc.pendingFolders += 1
                if facts.device != rootDevice {
                    child.otherVolume = true
                    acc.otherVolumes += 1
                } else {
                    subfolders.append((childPath, child))
                }
            } else {
                acc.addFile(to: folder, facts: facts, ext: NameTools.fileExtension(of: name),
                            now: now, links: links, path: { childPath })
            }
        }
        return subfolders
    }

    /// Scans one branch with fts (the same traversal `du` uses).
    static func scanBranch(path: String, root: Node, rootDevice: UInt64,
                           acc: inout ScanAccumulator, links: HardLinkRegistry,
                           progress: ScanProgress, now: Int64) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            root.unreadable = true
            acc.noteUnreadable(path)
            root.finalize()
            return
        }
        defer { fts_close(stream) }

        var stack: [Node] = []
        var counter = 0

        while let entry = fts_read(stream) {
            counter += 1
            if counter & 0x3FF == 0 {
                acc.flush(to: progress, currentPath: String(cString: entry.pointee.fts_path))
                if progress.isCancelled { return }
            }

            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)

            switch info {
            case FTS_D:
                if level == 0 {
                    stack = [root]
                    continue
                }
                if stack.count > level { stack.removeLast(stack.count - level) }
                guard stack.count == level else { continue }
                let parentNode = stack[level - 1]
                let child = Node(name: entryName(entry), parent: parentNode)
                parentNode.children.append(child)
                if FileFacts.normalize(entry.pointee.fts_dev) != rootDevice {
                    child.otherVolume = true          // fts will not descend into it (FTS_XDEV)
                    acc.otherVolumes += 1
                }
                stack.append(child)
                acc.pendingFolders += 1

            case FTS_DP:
                guard stack.count == level + 1 else { continue }
                stack.removeLast().finalize()

            case FTS_DNR:
                // fts reports an unreadable folder first as FTS_D, then again as FTS_DNR.
                acc.noteUnreadable(String(cString: entry.pointee.fts_path))
                if stack.count == level + 1 {
                    let node = stack.removeLast()
                    node.unreadable = true
                    node.finalize()
                } else if level == 0 {
                    root.unreadable = true
                    root.finalize()
                } else if stack.count >= level {
                    let parentNode = stack[level - 1]
                    let child = Node(name: entryName(entry), parent: parentNode)
                    child.unreadable = true
                    child.finalize()
                    parentNode.children.append(child)
                }

            case FTS_DC:
                continue                               // a directory cycle; never count twice

            case FTS_NS, FTS_ERR:
                acc.statErrors += 1

            default:                                   // files, symlinks, other file types
                guard level > 0, stack.count >= level, let st = entry.pointee.fts_statp else { continue }
                let folder = stack[level - 1]
                let facts = FileFacts(st.pointee)
                let ext = NameTools.fileExtension(of: entryNameBuffer(entry))
                acc.addFile(to: folder, facts: facts, ext: ext, now: now, links: links,
                            path: { String(cString: entry.pointee.fts_path) })
            }
        }

        // Only reached with folders still open after an unexpected error: close them out.
        while let node = stack.popLast() { node.finalize() }
    }

    @inline(__always)
    private static func entryNameBuffer(_ entry: UnsafeMutablePointer<FTSENT>) -> UnsafeRawBufferPointer {
        let path = UnsafeRawPointer(entry.pointee.fts_path!)
        let pathLength = Int(entry.pointee.fts_pathlen)
        let nameLength = Int(entry.pointee.fts_namelen)
        return UnsafeRawBufferPointer(start: path + (pathLength - nameLength), count: nameLength)
    }

    @inline(__always)
    private static func entryName(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
        String(decoding: entryNameBuffer(entry), as: UTF8.self)
    }
}
