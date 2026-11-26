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
///   That includes what folders themselves take (`Node.folderAllocated`: only on exFAT and FAT drives),
///   so totals match `du`.
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
        // Waiting on the internet rather than the disk: more at once helps here.
        runWorkers(WorkQueue(folders), workers: max(2, ProcessInfo.processInfo.activeProcessorCount),
                   rootDevice: rootDevice, links: links, topCount: topCount, now: now,
                   progress: progress, fetchCloud: true, deliver: deliver)
        progress.startFinishing()
    }

    /// How many folders are read at once. Reading a folder is almost all work inside macOS's file
    /// system, which serializes much of it: past about six readers, extra threads mostly wait on
    /// each other there. Measured on a 16-core Mac scanning 477,000 files: 16 readers took 1.66 s
    /// and 17 s of CPU, 6 readers 0.89 s and 3.3 s. This is about the Mac, not the folder: any
    /// number of files is read, just by these few threads.
    static var readers: Int { max(2, min(ProcessInfo.processInfo.activeProcessorCount, 6)) }

    /// Reads the queue's folders with `workers` threads until all are read, delivering each
    /// as a piece. Busy workers hand subfolders to idle ones (see `WorkQueue`), so every worker
    /// stays busy until the end however lopsided the folders are.
    private static func runWorkers(_ queue: WorkQueue, workers: Int, rootDevice: UInt64, links: HardLinkRegistry,
                                   topCount: Int, now: Int64, progress: ScanProgress, fetchCloud: Bool,
                                   deliver: @escaping @Sendable (ScanPiece) -> Void) {
        // Reading from the disk, scans of the same disk (one per window) take turns at its readers.
        // Reading from the cloud waits on the internet instead, so it doesn't.
        let slots = fetchCloud ? nil : DiskReaders.slots(for: rootDevice)
        // A folder handed over from inside a cloud folder and then not read (the read was stopped)
        // goes back to being a folder in the cloud, so reading the cloud folders again finds it.
        // Otherwise the folder around it, delivered, would leave it waiting to be read for good.
        @Sendable func putBackInCloud(_ job: WorkQueue.Job) {
            guard fetchCloud, job.handedOff else { return }
            let contents = Node(name: job.folder.name, parent: nil)
            contents.cloudOnly = true
            var acc = ScanAccumulator(topCount: 0)
            acc.cloudOnly = 1
            acc.cloudFolders = [job.folder]
            deliver(ScanPiece(placeholder: job.folder.node, contents: contents, stats: acc))
        }
        // Threads of their own rather than GCD's shared ones (see `DiskThreads`).
        DiskThreads.run(workers, qos: fetchCloud ? .utility : .userInitiated) { _ in
            func work() {
                while let job = queue.next() {
                    defer { queue.finished() }
                    if progress.isCancelled {
                        queue.stop()
                        putBackInCloud(job)
                        continue
                    }
                    if let slots, !slots.take(for: progress) {
                        queue.stop()
                        putBackInCloud(job)
                        continue
                    }
                    let folder = job.folder
                    progress.branchStarted(job.id, path: folder.path)
                    let contents = Node(name: folder.name, parent: nil)
                    var acc = ScanAccumulator(topCount: topCount)
                    scanBranch(path: folder.path, root: contents, rootDevice: rootDevice, acc: &acc, links: links,
                               progress: progress, now: now, fetchCloud: fetchCloud, split: queue)
                    slots?.giveBack(for: progress)
                    if contents.cloudOnly {
                        acc.cloudFolders.append(CloudFolder(path: folder.path, name: folder.name, node: folder.node))
                    }
                    acc.flush(to: progress, currentPath: nil)
                    progress.branchFinished(job.id)
                    if progress.isCancelled {
                        // Thrown away: the hard-linked files it counted first must count when it's read again.
                        links.forget(acc.firstSightings)
                        putBackInCloud(job)
                        continue
                    }
                    // Kept with the piece: if it is never filled in (see `ScanResult.putBackUnread`),
                    // the hard links it counted first are forgotten.
                    deliver(ScanPiece(placeholder: folder.node, contents: contents, stats: acc))
                }
            }
            if fetchCloud { work() } else { CloudFiles.withoutFetching(work) }
        }
        queue.leftOver().forEach(putBackInCloud)
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
        main.addFolderSpace(rootFacts.allocated, to: root)

        // Read the first two levels directly, then scan each deeper branch on its own core.
        let firstLevel = listFolder(path: path, folder: root, rootDevice: rootDevice,
                                    acc: &main, links: links, now: now, progress: progress)
        var jobs: [(path: String, node: Node)] = []
        for entry in firstLevel {
            if progress.isCancelled { return .cancelled }
            jobs += listFolder(path: entry.path, folder: entry.node, rootDevice: rootDevice,
                               acc: &main, links: links, now: now, progress: progress)
        }
        if progress.isCancelled { return .cancelled }
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

        runWorkers(WorkQueue(branches), workers: readers, rootDevice: rootDevice, links: links, topCount: topCount,
                   now: now, progress: progress, fetchCloud: false, deliver: deliver)
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
                           now: Int64, progress: ScanProgress? = nil) -> [(path: String, node: Node)] {
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
        var counter = 0

        while true {
            // A folder of a million files near the top: show how far it got, and stop when told to.
            counter += 1
            if counter & 0x3FF == 0, let progress {
                acc.flush(to: progress, currentPath: path)
                if progress.isCancelled { return subfolders }
            }
            // readdir returns nil both at the end and on an error; only an error sets errno.
            errno = 0
            guard let entry = readdir(dir) else { break }
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
                child.hidden = HiddenFiles.isHidden(name: name, flags: facts.flags)
                folder.children.append(child)
                acc.pendingFolders += 1
                if facts.device == rootDevice { acc.addFolderSpace(facts.allocated, to: child) }
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
        let readError = errno
        if readError != 0 {
            // Reading stopped partway (a drive failing or unplugged, say): what was read stays,
            // and the folder is listed among those that couldn't be read in full.
            Log.scan.error("Couldn't finish reading \(path, privacy: .public): \(String(cString: strerror(readError)), privacy: .public)")
            folder.unreadable = true
            acc.noteUnreadable(path)
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
                child.hidden = HiddenFiles.isHidden(name: child.name,
                                                    flags: entry.pointee.fts_statp.map { UInt32($0.pointee.st_flags) } ?? 0)
                parentNode.children.append(child)
                let sameDisk = FileFacts.normalize(entry.pointee.fts_dev) == rootDevice
                if sameDisk, let st = entry.pointee.fts_statp {
                    acc.addFolderSpace(FileFacts(st.pointee).allocated, to: child)
                }
                if dataless {
                    child.cloudOnly = true
                    acc.cloudOnly += 1
                    acc.cloudFolders.append(CloudFolder(path: String(cString: entry.pointee.fts_path),
                                                        name: child.name, node: child))
                } else if !sameDisk {
                    child.otherVolume = true          // fts will not descend into it (FTS_XDEV)
                    acc.otherVolumes += 1
                } else if handOff, level <= 3, let split, worthHandingOff(entry) {
                    // Another worker is idle: hand it this subfolder instead of reading it here.
                    // Only folders near the top of this branch that hold a few things are worth
                    // the hand-off; tiny ones would cost more than they save. It arrives later as
                    // a piece of its own and fills this placeholder in.
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
                    child.hidden = HiddenFiles.isHidden(name: child.name,
                                                        flags: entry.pointee.fts_statp.map { UInt32($0.pointee.st_flags) } ?? 0)
                    if FileFacts.normalize(entry.pointee.fts_dev) == rootDevice, let st = entry.pointee.fts_statp {
                        acc.addFolderSpace(FileFacts(st.pointee).allocated, to: child)
                    }
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

    /// Whether a folder met while reading a branch is worth handing to an idle worker. APFS and Mac OS
    /// Extended give a folder a link count of 2 plus what it holds, so more than 4 means a few items.
    /// exFAT and FAT drives (and some network drives) always say 1: there any folder near the top
    /// is handed off, since how much it holds can't be told without reading it. Measured on an
    /// exFAT drive with nearly everything in one folder: 0.17 s without that, 0.06 s with it.
    @inline(__always)
    private static func worthHandingOff(_ entry: UnsafeMutablePointer<FTSENT>) -> Bool {
        let links = entry.pointee.fts_statp?.pointee.st_nlink ?? 0
        return links > 4 || links < 2
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

/// The readers of each disk, shared by every scan of it. Each window can run a scan of its own:
/// two scans of the same disk take turns at its `ScanEngine.readers` instead of each starting that
/// many, which would only make them wait on each other inside macOS. Scans of different disks
/// (the Mac and an external drive, say) don't wait for each other.
enum DiskReaders {
    private static let lock = NSLock()
    /// One pool per disk scanned since DiskLens opened.
    nonisolated(unsafe) private static var byDisk: [UInt64: DiskReaderPool] = [:]

    static func slots(for device: UInt64) -> DiskReaderPool {
        lock.lock()
        defer { lock.unlock() }
        if let slots = byDisk[device] { return slots }
        let slots = DiskReaderPool(capacity: ScanEngine.readers)
        byDisk[device] = slots
        return slots
    }
}

/// A disk's readers (see `DiskReaders`), each held by one scan at a time.
///
/// A scan that was stopped gives its readers back at once, even while its threads are still
/// inside macOS: on a disk that is waking up or busy with another app, a folder can take minutes
/// to answer, and a scan started meanwhile must not wait for that. (Those threads, once back,
/// stop without reading further.)
final class DiskReaderPool: @unchecked Sendable {
    private let condition = NSCondition()
    let capacity: Int
    private var inUse = 0
    private var holders: [ObjectIdentifier: (scan: ScanProgress, count: Int)] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Waits for a free reader for `scan`; false if the scan is stopped first.
    func take(for scan: ScanProgress) -> Bool {
        let id = ObjectIdentifier(scan)
        condition.lock()
        var waited = false
        defer {
            if waited { scan.waitingForReader(false) }
            condition.unlock()
        }
        while true {
            if scan.isCancelled { return false }
            reclaimStopped()
            if inUse < capacity {
                inUse += 1
                holders[id, default: (scan, 0)].count += 1
                return true
            }
            if !waited {
                waited = true
                scan.waitingForReader(true)
            }
            // Woken when a reader is given back; the timeout also notices a stop (this scan's or a holder's).
            condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
    }

    /// Gives back a reader `scan` took (nothing, if it was taken back when the scan stopped).
    func giveBack(for scan: ScanProgress) {
        let id = ObjectIdentifier(scan)
        condition.lock()
        defer { condition.unlock() }
        guard let holder = holders[id] else { return }
        inUse -= 1
        holders[id] = holder.count > 1 ? (holder.scan, holder.count - 1) : nil
        condition.signal()
    }

    /// Readers free right now (for the tests).
    var free: Int {
        condition.lock()
        defer { condition.unlock() }
        reclaimStopped()
        return capacity - inUse
    }

    /// Takes back the readers of scans that were stopped. Holds the lock.
    private func reclaimStopped() {
        for (id, holder) in holders where holder.scan.isCancelled {
            inUse -= holder.count
            holders[id] = nil
            condition.broadcast()
        }
    }
}
