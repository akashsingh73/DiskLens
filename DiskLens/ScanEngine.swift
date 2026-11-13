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
/// - Nothing is fetched from cloud storage during the scan: folders that are only in the cloud are
///   marked and listed in `ScanResult.cloudFolders`, to read afterwards with `readCloudFolders`.
enum ScanEngine {
    /// Scans `path` and returns the finished result in one go (the tests, and anything that doesn't
    /// show the tree while it is being read). Folders only in the cloud are left unread.
    static func scan(path: String, displayName: String, topCount: Int, progress: ScanProgress) -> ScanOutcome {
        let inbox = ScanInbox()
        let outcome = stream(path: path, displayName: displayName, topCount: topCount, progress: progress,
                             showTree: { _ in }, deliver: { inbox.add($0) })
        guard case .finished(let result) = outcome else { return outcome }
        result.fillIn(inbox.takeAll())
        result.duration = Date().timeIntervalSince(result.started)
        result.isComplete = true
        return .finished(result)
    }

    /// Scans `path`, handing the tree over in pieces as it goes:
    /// - `showTree` gets the result as soon as the first two levels are read (a fraction of a
    ///   second). From then on the tree belongs to the receiver, normally the main thread, and the
    ///   scan never touches it again. The folders below those two levels are marked `pending`.
    /// - `deliver` gets each of those folders once it has been read in full, on a worker thread;
    ///   the receiver adds it with `ScanResult.fillIn`.
    /// Returns once every piece has been delivered (or the scan was stopped).
    static func stream(path: String, displayName: String, topCount: Int, progress: ScanProgress,
                       showTree: (ScanResult) -> Void,
                       deliver: @escaping @Sendable (ScanPiece) -> Void) -> ScanOutcome {
        CloudFiles.withoutFetching {
            streamLocally(path: path, displayName: displayName, topCount: topCount, progress: progress,
                          showTree: showTree, deliver: deliver)
        }
    }

    /// Reads folders that were only in the cloud, now fetching them from the internet (the slow
    /// part), several at a time. Each is delivered like `stream` does; a folder still being read
    /// when `progress` is cancelled is not delivered, so it stays marked as in the cloud.
    static func readCloudFolders(_ folders: [CloudFolder], rootDevice: UInt64, links: HardLinkRegistry,
                                 topCount: Int, now: Int64, progress: ScanProgress,
                                 deliver: @escaping @Sendable (ScanPiece) -> Void) {
        progress.startReading(branches: folders.count)
        runWorkers(WorkQueue(folders), rootDevice: rootDevice, links: links, topCount: topCount, now: now,
                   progress: progress, fetchCloud: true, deliver: deliver)
        progress.startFinishing()
    }

    /// Reads the queue's folders with one worker per core until all are read, delivering each
    /// as a piece. Busy workers hand subfolders to idle ones (see `WorkQueue`), so every core
    /// stays busy until the end however lopsided the folders are.
    private static func runWorkers(_ queue: WorkQueue, rootDevice: UInt64, links: HardLinkRegistry,
                                   topCount: Int, now: Int64, progress: ScanProgress, fetchCloud: Bool,
                                   deliver: @escaping @Sendable (ScanPiece) -> Void) {
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            func work() {
                while let job = queue.next() {
                    defer { queue.finished() }
                    if progress.isCancelled {
                        queue.stop()
                        continue
                    }
                    let folder = job.folder
                    progress.branchStarted(job.id, path: folder.path)
                    let contents = Node(name: folder.name, parent: nil)
                    var acc = ScanAccumulator(topCount: topCount)
                    scanBranch(path: folder.path, root: contents, rootDevice: rootDevice, acc: &acc, links: links,
                               progress: progress, now: now, fetchCloud: fetchCloud, split: queue)
                    if contents.cloudOnly {
                        acc.cloudFolders.append(CloudFolder(path: folder.path, name: folder.name, node: folder.node))
                    }
                    acc.flush(to: progress, currentPath: nil)
                    progress.branchFinished(job.id)
                    if progress.isCancelled { continue }
                    deliver(ScanPiece(placeholder: folder.node, contents: contents, stats: acc))
                }
            }
            if fetchCloud { work() } else { CloudFiles.withoutFetching(work) }
        }
    }

    private static func streamLocally(path: String, displayName: String, topCount: Int, progress: ScanProgress,
                                      showTree: (ScanResult) -> Void,
                                      deliver: @escaping @Sendable (ScanPiece) -> Void) -> ScanOutcome {
        let started = Date()
        let now = Int64(started.timeIntervalSince1970)

        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            let code = errno
            return .failed(failureMessage(code, name: displayName))
        }
        let rootFacts = FileFacts(rootStat)
        guard rootFacts.isDirectory else { return .failed("“\(displayName)” is not a folder.") }
        guard !rootFacts.isDataless else { return .failed(cloudOnlyMessage(name: displayName)) }
        // Make sure the folder can be listed at all before building anything.
        guard let probe = opendir(path) else {
            let code = errno
            return .failed(CloudFiles.isCloudOnly(errorCode: code)
                           ? cloudOnlyMessage(name: displayName)
                           : failureMessage(code, name: displayName))
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

        // The first two levels become the tree on screen; the folders below them are read next,
        // each into a tree of its own, and filled in as they finish.
        for job in jobs { job.node.pending = true }
        for entry in firstLevel { entry.node.finalize() }
        root.finalize()
        let result = ScanResult(root: root, rootPath: path, displayName: displayName, started: started,
                                rootDevice: rootDevice, topCount: topCount, links: links)
        result.absorb(main)
        // Paths and names copied now, so the workers never touch the tree on screen.
        let branches = jobs.map { CloudFolder(path: $0.path, name: $0.node.name, node: $0.node) }
        progress.startReading(branches: branches.count)
        showTree(result)

        runWorkers(WorkQueue(branches), rootDevice: rootDevice, links: links, topCount: topCount, now: now,
                   progress: progress, fetchCloud: false, deliver: deliver)
        if progress.isCancelled { return .cancelled }
        progress.startFinishing()
        return .finished(result)
    }

    static func cloudOnlyMessage(name: String) -> String {
        "“\(name)” is only in the cloud: none of it is downloaded to this Mac, so it takes no space here. To scan it, download it first (in Finder, right-click it and choose Download Now)."
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
            if CloudFiles.isCloudOnly(errorCode: errno) {
                folder.cloudOnly = true
                acc.cloudOnly += 1
                acc.cloudFolders.append(CloudFolder(path: path, name: folder.name, node: folder))
            } else {
                folder.unreadable = true
                acc.noteUnreadable(path)
            }
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
                if facts.isDataless {
                    child.cloudOnly = true
                    acc.cloudOnly += 1
                    acc.cloudFolders.append(CloudFolder(path: childPath, name: name, node: child))
                } else if facts.device != rootDevice {
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

    /// Scans one branch with fts (the same traversal `du` uses). Folders only in the cloud are
    /// marked and listed rather than read, unless `fetchCloud` is set (reading them after a scan).
    /// The branch's own top folder, if it is in the cloud, is marked but not listed: the caller
    /// knows where it belongs in the tree.
    static func scanBranch(path: String, root: Node, rootDevice: UInt64,
                           acc: inout ScanAccumulator, links: HardLinkRegistry,
                           progress: ScanProgress, now: Int64, fetchCloud: Bool = false,
                           split: WorkQueue? = nil) {
        guard let cPath = strdup(path) else { return }
        defer { free(cPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            if CloudFiles.isCloudOnly(errorCode: errno) {
                root.cloudOnly = true
                acc.cloudOnly += 1
            } else {
                root.unreadable = true
                acc.noteUnreadable(path)
            }
            root.finalize()
            return
        }
        defer { fts_close(stream) }

        var stack: [Node] = []
        var counter = 0
        /// Another worker is idle: hand it the next folder with subfolders. Checked every 64
        /// entries rather than at every folder, so the shared queue's lock stays out of the way.
        var handOff = false

        while let entry = fts_read(stream) {
            counter += 1
            if counter & 0x3F == 0, let split { handOff = split.wantsWork }
            if counter & 0x3FF == 0 {
                acc.flush(to: progress, currentPath: String(cString: entry.pointee.fts_path))
                if progress.isCancelled { return }
            }

            let info = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)

            switch info {
            case FTS_D:
                // A folder only in the cloud: don't open it (that would wait on the internet).
                // fts then hands it back at once as FTS_DP, which closes it below.
                let dataless = !fetchCloud
                    && (entry.pointee.fts_statp.map { FileFacts($0.pointee).isDataless } ?? false)
                if dataless { fts_set(stream, entry, FTS_SKIP) }
                if level == 0 {
                    stack = [root]
                    if dataless {
                        root.cloudOnly = true
                        acc.cloudOnly += 1
                    }
                    continue
                }
                if stack.count > level { stack.removeLast(stack.count - level) }
                guard stack.count == level else { continue }
                let parentNode = stack[level - 1]
                let child = Node(name: entryName(entry), parent: parentNode)
                parentNode.children.append(child)
                if dataless {
                    child.cloudOnly = true
                    acc.cloudOnly += 1
                    acc.cloudFolders.append(CloudFolder(path: String(cString: entry.pointee.fts_path),
                                                        name: child.name, node: child))
                } else if FileFacts.normalize(entry.pointee.fts_dev) != rootDevice {
                    child.otherVolume = true          // fts will not descend into it (FTS_XDEV)
                    acc.otherVolumes += 1
                } else if handOff, level <= 3, let split, (entry.pointee.fts_statp?.pointee.st_nlink ?? 0) > 4 {
                    // Another worker is idle: hand it this subfolder instead of reading it here.
                    // Only folders near the top of this branch with at least three subfolders
                    // (a folder's link count is 2 plus its subfolders) are worth the hand-off;
                    // tiny ones would cost more than they save. It arrives later as a piece of
                    // its own and fills this placeholder in.
                    handOff = false
                    fts_set(stream, entry, FTS_SKIP)
                    child.pending = true
                    split.add(CloudFolder(path: String(cString: entry.pointee.fts_path), name: child.name, node: child))
                    progress.branchAdded()
                }
                stack.append(child)
                acc.pendingFolders += 1

            case FTS_DP:
                guard stack.count == level + 1 else { continue }
                stack.removeLast().finalize()

            case FTS_DNR:
                // fts reports an unreadable folder first as FTS_D, then again as FTS_DNR. A cloud
                // folder that slipped past the check above fails here without waiting, and is
                // marked as in the cloud rather than unreadable.
                let cloud = CloudFiles.isCloudOnly(errorCode: entry.pointee.fts_errno)
                let entryPath = String(cString: entry.pointee.fts_path)
                func mark(_ node: Node) {
                    if cloud {
                        node.cloudOnly = true
                        acc.cloudOnly += 1
                        if node !== root {
                            acc.cloudFolders.append(CloudFolder(path: entryPath, name: node.name, node: node))
                        }
                    } else {
                        node.unreadable = true
                    }
                }
                if !cloud { acc.noteUnreadable(entryPath) }
                if stack.count == level + 1 {
                    let node = stack.removeLast()
                    mark(node)
                    node.finalize()
                } else if level == 0 {
                    mark(root)
                    root.finalize()
                } else if stack.count >= level {
                    let parentNode = stack[level - 1]
                    let child = Node(name: entryName(entry), parent: parentNode)
                    mark(child)
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
