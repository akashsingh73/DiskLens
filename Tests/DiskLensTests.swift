import Foundation
import AppKit

/// DiskLens's tests. Run them with `bash test.sh` (no Xcode needed).
///
/// They build a small folder tree with known contents (hard links in one folder and across
/// folders, symbolic links, a sparse file, unreadable folders, an old file), scan it, and check
/// the results against the known contents and against `du`. Paths given on the command line
/// are also scanned and compared with `du`.
@main
struct DiskLensTests {
    @MainActor
    static func main() {
        let checks = Checks()
        unitTests(checks)
        changeTests(checks)
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixtureTests(fixture, checks)
            streamingTests(fixture, checks)
        } catch {
            checks.fail("Couldn't build the test folder: \(error)")
        }
        hardLinkTests(checks)
        for path in CommandLine.arguments.dropFirst() {
            compareWithDu(path: path, checks)
        }
        print(checks.failed == 0
              ? "All \(checks.passed) checks passed."
              : "\(checks.failed) of \(checks.passed + checks.failed) checks FAILED.")
        exit(checks.failed == 0 ? 0 : 1)
    }

    // MARK: - Hard links in Details and the Trash

    /// Which link of a hard-linked file Details counts, and what moving links (or folders holding
    /// them) to the Trash does to the scan: after each move, its numbers must match a new scan.
    @MainActor
    static func hardLinkTests(_ c: Checks) {
        c.section("Hard links in Details")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("DiskLensLinks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        guard (try? fm.createDirectory(at: base, withIntermediateDirectories: true)) != nil,
              let real = realpath(base.path, nil) else {
            c.fail("couldn't make the test folder")
            return
        }
        let root = String(cString: real)
        free(real)
        func write(_ relative: String, _ bytes: Int) {
            let url = URL(fileURLWithPath: root + "/" + relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0x62, count: bytes))
        }
        func hardLink(_ relative: String, to target: String) {
            try? fm.createDirectory(atPath: ((root + "/" + relative) as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            if Darwin.link(root + "/" + target, root + "/" + relative) != 0 { c.fail("couldn't link \(relative)") }
        }
        write("same/a.bin", 300_000)                   // two links in one folder
        hardLink("same/b.bin", to: "same/a.bin")
        write("trio/x.dat", 200_000)                   // three links in one folder
        hardLink("trio/y.dat", to: "trio/x.dat")
        hardLink("trio/z.dat", to: "trio/x.dat")
        write("one/split.bin", 150_000)                // one link in each of two folders
        hardLink("two/split-link.bin", to: "one/split.bin")
        write("one/plain.txt", 10_000)
        write("keep/k.bin", 120_000)                   // for moving a folder to the Trash
        hardLink("gone/k-link.bin", to: "keep/k.bin")
        write("gone/other.txt", 5_000)

        func scan() -> ScanResult? {
            guard case .finished(let result) = ScanEngine.scan(path: root, displayName: "Links", topCount: 50,
                                                               progress: ScanProgress()) else { return nil }
            return result
        }
        guard let result = scan() else {
            c.fail("the hard-link folder scan didn't finish")
            return
        }
        let folder = { (name: String) in result.root.descendant(atPath: root + "/" + name) }
        func files(_ name: String) -> [FolderFile] {
            guard let node = folder(name) else { return [] }
            return FolderReader.files(in: node.path, uncounted: node.uncountedLinks) ?? []
        }

        // Top Files lists every counted file here, under the name of the link the scan counted.
        let countedByScan = Set(result.topFiles.map(\.path))
        c.equal(countedByScan.count, 6, "the scan counts each of the six files once")
        for name in ["same", "trio", "one", "two", "keep", "gone"] {
            for file in files(name) {
                let path = root + "/" + name + "/" + file.name
                c.equal(file.counted, countedByScan.contains(path), "Details counts \(name)/\(file.name) as the scan did")
            }
        }

        // The rule itself: the first link here counts, unless every link here is an uncounted one.
        func facts(inode: UInt64) -> FileFacts {
            FileFacts(size: 10, allocated: 4096, modified: 0, device: 1, inode: inode, links: 3, mode: UInt32(S_IFREG), flags: 0)
        }
        let three = ["p", "q", "r"].map { FolderFile(name: $0, facts: facts(inode: 7), counted: true) }
        let key = FileKey(device: 1, inode: 7)
        c.equal(FolderReader.labelLinks(three, uncounted: [key: 2]).map(\.counted), [true, false, false],
                "of three links in a folder, the first counts")
        c.equal(FolderReader.labelLinks(three, uncounted: [key: 3]).map(\.counted), [false, false, false],
                "none count when the file was counted elsewhere")
        c.equal(FolderReader.labelLinks(three, uncounted: nil).map(\.counted), [true, true, true],
                "all count when the scan left none uncounted here")

        c.section("Moving hard links to the Trash")
        // The scan's numbers, after a move, against a new scan of what is left.
        func matchesNewScan(_ what: String) {
            guard let fresh = scan() else {
                c.fail("couldn't scan again (\(what))")
                return
            }
            c.equal(result.root.allocated, fresh.root.allocated, "\(what): space on disk")
            c.equal(result.root.fileCount, fresh.root.fileCount, "\(what): files")
            c.equal(result.hardLinkDuplicates, fresh.hardLinkDuplicates, "\(what): extra hard links")
            c.equal(result.root.uncountedLinksBelow, fresh.root.uncountedLinksBelow, "\(what): extra links in the tree")
            c.expect(result.extensions == fresh.extensions && result.ageAllocated == fresh.ageAllocated
                     && result.ageCounts == fresh.ageCounts, "\(what): File Types and Ages")
            var folders = [fresh.root]
            while let node = folders.popLast() {
                folders.append(contentsOf: node.children)
                guard let mine = result.root.descendant(atPath: node.path) else {
                    c.fail("\(what): \(node.name) missing")
                    continue
                }
                c.expect(mine.ownAllocated == node.ownAllocated && mine.ownFileCount == node.ownFileCount
                         && (mine.uncountedLinks ?? [:]) == (node.uncountedLinks ?? [:]),
                         "\(what): \(node.name)'s own files")
            }
        }
        // A file Details lists in `name`, counted or not.
        func link(in name: String, counted: Bool) -> (node: Node, file: FolderFile)? {
            guard let node = folder(name), let file = files(name).first(where: { $0.counted == counted }) else {
                c.fail("no \(counted ? "counted" : "uncounted") link in \(name)")
                return nil
            }
            return (node, file)
        }
        // What the app does after moving a file to the Trash (the file is deleted here instead).
        func trash(_ name: String, counted: Bool) -> Node? {
            guard let (node, file) = link(in: name, counted: counted) else { return nil }
            let path = node.path + "/" + file.name
            unlink(path)
            return result.removeFile(path, in: node, size: file.facts.size, allocated: file.facts.allocated,
                                     modified: file.facts.modified,
                                     uncountedLink: counted ? nil : file.facts.key,
                                     link: counted && file.facts.links > 1 ? file.facts.key : nil)
        }

        let sameKey = files("same").first?.facts.key
        let sameHolder = trash("same", counted: true)
        c.expect(sameHolder === folder("same"), "the counted link of two in one folder: the other one is counted now")
        matchesNewScan("Counted link next to another")
        if let sameKey, let same = folder("same") {
            c.expect(FolderReader.firstLink(to: sameKey, in: same.path) != nil, "and Top Files can find it by name")
        }

        c.expect(trash("trio", counted: false) == nil, "an uncounted link of three in one folder")
        matchesNewScan("Uncounted link")

        let splitCounted = folder("one")?.uncountedLinks == nil ? "one" : "two"
        let splitOther = splitCounted == "one" ? "two" : "one"
        let splitHolder = trash(splitCounted, counted: true)
        c.expect(splitHolder === folder(splitOther), "the counted link of a file linked from another folder: that folder counts it now")
        matchesNewScan("Counted link, other link elsewhere")

        // A folder holding the counted link, the other link outside it.
        let keepCounted = folder("keep")?.uncountedLinks == nil ? "keep" : "gone"
        if let node = folder(keepCounted) {
            let path = node.path
            let counted = CountedFiles.read(FileTally.folders(in: node, path: path), now: result.scanTime,
                                            progress: ScanProgress())
            c.equal(counted.linked.count, 1, "the folder's counted file with another link is kept apart")
            try? fm.removeItem(atPath: path)
            let kept = result.removeFolder(node, path: path, files: counted)
            c.equal(kept.map(\.folder.name), [keepCounted == "keep" ? "gone" : "keep"],
                    "a folder holding the counted link: the folder with the other link counts it now")
            matchesNewScan("Folder with a counted link")
        }
        // A folder holding every link to its file: the space is freed.
        if let node = folder("trio") {
            let path = node.path
            let counted = CountedFiles.read(FileTally.folders(in: node, path: path), now: result.scanTime,
                                            progress: ScanProgress())
            try? fm.removeItem(atPath: path)
            c.equal(result.removeFolder(node, path: path, files: counted).count, 0,
                    "a folder holding every link to a file frees its space")
            matchesNewScan("Folder with all the links")
        }
    }

    // MARK: - The tree arriving in pieces, and cloud folders

    @MainActor
    static func streamingTests(_ f: Fixture, _ c: Checks) {
        c.section("Showing the tree while it is read")
        var stat = Darwin.stat()
        stat.st_flags = UInt32(SF_DATALESS)
        c.expect(FileFacts(stat).isDataless, "a folder flagged dataless is only in the cloud")
        stat.st_flags = 0
        c.expect(!FileFacts(stat).isDataless, "an ordinary folder is not")
        c.expect(CloudFiles.isCloudOnly(errorCode: EDEADLK), "EDEADLK means only in the cloud")
        c.expect(!CloudFiles.isCloudOnly(errorCode: EACCES), "EACCES means no access, not cloud")

        guard case .finished(let whole) = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10,
                                                          progress: ScanProgress()) else {
            c.fail("the one-shot scan didn't finish")
            return
        }
        let inbox = ScanInbox()
        var shownBeforePieces = false
        var pendingAtShow = 0
        var shown: ScanResult?
        let outcome = ScanEngine.stream(path: f.root, displayName: "Fixture", topCount: 10, progress: ScanProgress(),
                                        showTree: { tree in
            shown = tree
            shownBeforePieces = inbox.takeAll().isEmpty
            var stack = [tree.root]
            while let node = stack.popLast() {
                if node.pending { pendingAtShow += 1 }
                stack.append(contentsOf: node.children)
            }
        }, deliver: { inbox.add($0) })
        guard case .finished(let live) = outcome, let tree = shown, tree === live else {
            c.fail("the streaming scan didn't finish with the tree it showed")
            return
        }
        c.expect(shownBeforePieces, "the tree is shown before any folder below it is delivered")
        c.expect(pendingAtShow > 0, "folders below the first two levels start out as still reading")
        let pieces = inbox.takeAll()
        c.expect(pieces.count >= pendingAtShow, "a piece arrives for each folder still being read (plus any handed to idle workers)")
        live.fillIn(pieces)
        c.equal(live.piecesWaiting, 0, "no piece is left waiting")
        var stillPending = 0
        var stack = [live.root]
        while let node = stack.popLast() {
            if node.pending { stillPending += 1 }
            stack.append(contentsOf: node.children)
        }
        c.equal(stillPending, 0, "every folder is filled in at the end")
        c.equal(live.root.allocated, whole.root.allocated, "filled in piece by piece: same space on disk")
        c.equal(live.root.size, whole.root.size, "same size")
        c.equal(live.root.fileCount, whole.root.fileCount, "same files")
        c.equal(live.root.folderCount, whole.root.folderCount, "same folders")
        c.equal(live.root.unreadableCount, whole.root.unreadableCount, "same unreadable folders")
        c.equal(live.extensions, whole.extensions, "same file types")
        c.equal(live.ageCounts, whole.ageCounts, "same ages")
        c.equal(live.topFiles.map(\.path), whole.topFiles.map(\.path), "same largest files")
        c.equal(live.hardLinkDuplicates, whole.hardLinkDuplicates, "same extra hard links")

        c.section("Scans in several windows at once")
        c.expect(DiskReaders.slots(for: UInt64.max - 1) === DiskReaders.slots(for: UInt64.max - 1),
                 "scans of the same disk share its readers")
        c.expect(DiskReaders.slots(for: UInt64.max - 1) !== DiskReaders.slots(for: UInt64.max - 2),
                 "scans of different disks don't")
        let together = ResultSlots<ScanResult>(count: 3)
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            if case .finished(let result) = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10,
                                                            progress: ScanProgress()) {
                together.set(index, result)
            }
        }
        let results = together.all()
        c.equal(results.count, 3, "three scans of the same folder at once all finish")
        for (index, result) in results.enumerated() {
            c.equal(result.root.allocated, whole.root.allocated, "scan \(index + 1): same space on disk as one alone")
            c.equal(result.root.fileCount, whole.root.fileCount, "scan \(index + 1): same files")
            c.equal(result.root.folderCount, whole.root.folderCount, "scan \(index + 1): same folders")
        }
        // Another scan of the same disk holds every reader: stopping this one still stops it at once.
        var rootStat = Darwin.stat()
        lstat(f.root, &rootStat)
        let busy = DiskReaders.slots(for: FileFacts(rootStat).device)
        let holder = ScanProgress()
        for _ in 0..<ScanEngine.readers { _ = busy.take(for: holder) }
        c.equal(busy.free, 0, "another scan holds every reader")
        let stopping = ScanProgress()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { stopping.cancel() }
        let started = Date()
        let waitingOutcome = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10, progress: stopping)
        let waited = Date().timeIntervalSince(started)
        if case .cancelled = waitingOutcome {
            c.expect(waited < 2, "a scan waiting for the disk's readers stops when told to (took \(waited) s)")
        } else {
            c.fail("a scan stopped while waiting for the disk's readers should end as stopped")
        }
        // The scan holding them is stopped, but its threads are stuck waiting on the disk and never
        // give them back: a new scan of the disk must still run, not wait for good.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { holder.cancel() }
        let next = ScanProgress()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { next.cancel() }
        let nextStarted = Date()
        if case .finished(let result) = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10, progress: next) {
            c.equal(result.root.allocated, whole.root.allocated, "a scan after a stuck, stopped one reads everything")
            c.expect(Date().timeIntervalSince(nextStarted) < 5, "…without waiting for the stuck one")
        } else {
            c.fail("a scan after a stopped scan that is stuck on the disk never ran")
        }
        c.equal(busy.free, ScanEngine.readers, "every reader is free again")
        busy.giveBack(for: holder)       // the stuck threads come back: nothing to give back by then
        c.equal(busy.free, ScanEngine.readers, "a stopped scan giving readers back late doesn't add any")

        c.section("Scans under load")
        // Swift's shared task threads all waiting on the disk (as when several windows wait on a
        // busy drive): scans, which have threads of their own, still finish.
        let stuck = DispatchSemaphore(value: 0)
        let blockers = ProcessInfo.processInfo.activeProcessorCount * 2
        for _ in 0..<blockers {
            Task.detached { stuck.wait() }
        }
        let crowd = 8
        let underLoad = ResultSlots<ScanResult>(count: crowd)
        let crowdStarted = Date()
        DiskThreads.run(crowd) { index in
            if case .finished(let result) = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10,
                                                            progress: ScanProgress()) {
                underLoad.set(index, result)
            }
        }
        let crowdResults = underLoad.all()
        c.equal(crowdResults.count, crowd, "\(crowd) scans of one disk at once all finish with the task threads stuck")
        c.expect(crowdResults.allSatisfy { $0.root.allocated == whole.root.allocated && $0.root.fileCount == whole.root.fileCount },
                 "…each with the same totals as one alone")
        c.expect(Date().timeIntervalSince(crowdStarted) < 20, "…in reasonable time")
        let answered = ResultSlots<Bool>(count: 1)
        DispatchQueue.global().async {
            Task { @MainActor in answered.set(0, await DiskThreads.value { true }) }
        }
        c.expect(runMainLoop(upTo: 5) { answered.all() == [true] }, "work for the disk runs while the task threads are stuck")
        for _ in 0..<blockers { stuck.signal() }

        c.section("Waiting for another window's scan")
        let holding = ScanProgress()
        for _ in 0..<ScanEngine.readers { _ = busy.take(for: holding) }
        let waitingScan = ScanProgress()
        let waitingDone = DispatchSemaphore(value: 0)
        DiskThreads.start {
            _ = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10, progress: waitingScan)
            waitingDone.signal()
        }
        var sawWaiting = false
        for _ in 0..<50 where !sawWaiting {
            Thread.sleep(forTimeInterval: 0.05)
            sawWaiting = waitingScan.read().waitingForOtherScan
        }
        c.expect(sawWaiting, "a scan with every reader taken says it's waiting for another scan")
        for _ in 0..<ScanEngine.readers { busy.giveBack(for: holding) }
        c.expect(waitingDone.wait(timeout: .now() + 10) == .success, "…and goes on once they're free")
        c.expect(!waitingScan.read().waitingForOtherScan, "…and no longer says so")

        c.section("Stopping while the top folders are listed")
        let stoppedEarly = ScanProgress()
        stoppedEarly.cancel()
        if case .cancelled = ScanEngine.scan(path: f.root, displayName: "Fixture", topCount: 10, progress: stoppedEarly) {
            c.pass()
        } else {
            c.fail("a scan stopped before it starts should end as stopped")
        }

        c.section("Stopping a cloud read without waiting for it")
        // A cloud folder that arrived, with a folder inside handed to another thread and never read
        // (that thread is still waiting on the internet), and a piece for a folder inside that one.
        let cloudRoot = Node(name: "Cloud", parent: nil)
        cloudRoot.rootPath = "/cloud"
        let arrived = Node(name: "Arrived", parent: cloudRoot)
        cloudRoot.children = [arrived]
        let handedOff = Node(name: "HandedOff", parent: arrived)
        handedOff.pending = true
        arrived.children = [handedOff]
        cloudRoot.finalize()
        let cloudScan = ScanResult(root: cloudRoot, rootPath: "/cloud", displayName: "Cloud", started: Date(),
                                   rootDevice: 1, topCount: 10, links: HardLinkRegistry())
        let inside = Node(name: "Inside", parent: nil)   // not in the tree: its folder never arrived
        let lostKey = FileKey(device: 1, inode: 42)
        _ = cloudScan.links.isFirstSighting(lostKey)
        var lostStats = ScanAccumulator(topCount: 0)
        lostStats.firstSightings = [lostKey]
        cloudScan.fillIn([ScanPiece(placeholder: inside, contents: Node(name: "Inside", parent: nil), stats: lostStats)])
        c.equal(cloudScan.piecesWaiting, 1, "a piece whose folder hasn't arrived waits")
        cloudScan.putBackUnread()
        c.expect(!handedOff.pending && handedOff.cloudOnly, "a folder handed off and never read is in the cloud again")
        c.expect(cloudScan.cloudFolders.contains { $0.node === handedOff && $0.path == "/cloud/Arrived/HandedOff" },
                 "…and is read the next time")
        c.equal(cloudScan.piecesWaiting, 0, "pieces that can't arrive any more are dropped")
        c.expect(cloudScan.links.isFirstSighting(lostKey), "…and the hard links they counted first count again")

        c.section("Open file limit")
        OpenFileLimit.raise()
        var limits = rlimit()
        getrlimit(RLIMIT_NOFILE, &limits)
        c.expect(OpenFileLimit.current >= min(OpenFileLimit.wanted, limits.rlim_max),
                 "DiskLens may open enough files for several windows' scans (\(OpenFileLimit.current))")

        c.section("Two copies of DiskLens sharing files")
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLensTests-history-\(getpid())")
        try? FileManager.default.removeItem(at: shared)
        HistoryStore.testFolder = shared
        defer {
            HistoryStore.testFolder = nil
            try? FileManager.default.removeItem(at: shared)
        }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        HistoryStore.append(HistoryEntry(path: "/a", date: day, size: 1, allocated: 1, files: 1))
        c.equal(HistoryStore.entries(for: "/a").count, 1, "a scan is in the history at once")
        HistoryStore.waitForWrites()
        // Another copy of DiskLens adds a scan to the file meanwhile.
        let file = shared.appendingPathComponent("history.json")
        if var theirs = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode([HistoryEntry].self, from: $0) }) {
            theirs.append(HistoryEntry(path: "/b", date: day + 1, size: 2, allocated: 2, files: 2))
            try? JSONEncoder().encode(theirs).write(to: file, options: .atomic)
        } else {
            c.fail("the history wasn't written to its file")
        }
        HistoryStore.append(HistoryEntry(path: "/a", date: day + 2, size: 3, allocated: 3, files: 3))
        HistoryStore.waitForWrites()
        let onDisk = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
        c.equal(onDisk.map(\.path), ["/a", "/b", "/a"], "neither copy's scans are lost")
        c.equal(HistoryStore.recent().map(\.path), ["/a", "/b"], "…and this copy shows the other's too")
        HistoryStore.update(HistoryEntry(path: "/b", date: day + 1, size: 9, allocated: 9, files: 9))
        HistoryStore.waitForWrites()
        c.equal(HistoryStore.entries(for: "/b").map(\.allocated), [9], "a scan the other copy added can be updated")
        // Two copies writing at the same moment: the file lock keeps every change.
        let counter = shared.appendingPathComponent("counter")
        try? "0".write(to: counter, atomically: true, encoding: .utf8)
        DiskThreads.run(4) { _ in
            for _ in 0..<50 {
                _ = try? FileLock.withLock(shared.appendingPathComponent("counter.lock")) {
                    let value = Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0
                    try? String(value + 1).write(to: counter, atomically: true, encoding: .utf8)
                }
            }
        }
        c.equal((try? String(contentsOf: counter, encoding: .utf8)).flatMap { Int($0) }, 200,
                "changes made under the file lock all land")

        c.section("Hidden files")
        let hiddenRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLensTests-hidden-\(getpid())").path
        try? FileManager.default.removeItem(atPath: hiddenRoot)
        defer { try? FileManager.default.removeItem(atPath: hiddenRoot) }
        let blob = Data(repeating: 7, count: 64 * 1024)
        for folder in ["shown", ".dotted", "flagged", "shown/deep/.inner"] {
            try? FileManager.default.createDirectory(atPath: hiddenRoot + "/" + folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: hiddenRoot + "/" + folder + "/file.bin", contents: blob)
        }
        FileManager.default.createFile(atPath: hiddenRoot + "/.dotfile", contents: blob)
        FileManager.default.createFile(atPath: hiddenRoot + "/plain", contents: blob)
        chflags(hiddenRoot + "/flagged", UInt32(UF_HIDDEN))
        if case .finished(let scanned) = ScanEngine.scan(path: hiddenRoot, displayName: "Hidden", topCount: 10,
                                                         progress: ScanProgress()) {
            let byName = Dictionary(uniqueKeysWithValues: scanned.root.children.map { ($0.name, $0) })
            c.expect(byName[".dotted"]?.hidden == true, "a folder whose name starts with a dot is hidden")
            c.expect(byName["flagged"]?.hidden == true, "a folder marked hidden in Finder is hidden")
            c.expect(byName["shown"]?.hidden == false, "an ordinary folder isn't")
            c.expect(scanned.root.descendant(atPath: hiddenRoot + "/shown/deep/.inner")?.hidden == true,
                     "…and so deeper down, read by another thread")
            c.equal(scanned.root.fileCount, 6, "hidden files and folders are counted all the same")
            let all = DetailLoader.listFiles(in: hiddenRoot, folderTotal: scanned.root.allocated, uncounted: nil).items
            c.equal(Set(all.map(\.name)), [".dotfile", "plain"], "Details lists hidden files when they're shown")
            c.expect(all.first { $0.name == ".dotfile" }?.hidden == true, "…marked hidden, to dim them")
            var someShown: [String] = []
            DetailLoader.streamFiles(in: hiddenRoot, folderTotal: scanned.root.allocated, uncounted: nil,
                                     showHidden: false) { rows in
                someShown += rows.map(\.name)
                return true
            }
            c.equal(someShown, ["plain"], "…and leaves them out when they're not")
            let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
            let metric: (Node) -> Double = { Double($0.allocated) }
            let everything = TreemapBuilder.tiles(for: scanned.root, in: rect, maxDepth: 1, minSide: 1, metric: metric)
            let noHidden = TreemapBuilder.tiles(for: scanned.root, in: rect, maxDepth: 1, minSide: 1, showHidden: false,
                                                metric: metric)
            c.expect(everything.contains { $0.node.name == ".dotted" }, "the treemap shows hidden folders")
            c.expect(!noHidden.contains { $0.node.hidden }, "…or leaves them out")
            func area(_ tiles: [TreemapTile], _ name: String) -> CGFloat {
                tiles.first { $0.node.name == name }.map { $0.rect.width * $0.rect.height } ?? 0
            }
            let before = area(everything, "shown"), after = area(noHidden, "shown")
            c.expect(before > 0 && abs(before - after) / before < 0.01,
                     "…keeping every other tile its size (\(Int(before)) and \(Int(after)))")
        } else {
            c.fail("couldn't scan the folder with hidden files")
        }

        c.section("Paths shown without asking the disk")
        // Firmlinks are checked once each; the answers match asking the disk for both paths.
        func asked(_ a: String, _ b: String) -> Bool {
            var x = Darwin.stat(), y = Darwin.stat()
            return lstat(a, &x) == 0 && lstat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
        }
        let data = "/System/Volumes/Data"
        for path in [NSHomeDirectory(), "/Applications", "/Users", "/Library/Preferences", "/private/tmp",
                     "/usr/local", "/usr/bin", "/System/Library/CoreServices", "/Volumes", f.root] {
            let expected = asked(path, data + path) ? data + path : nil
            c.equal(PathDisplay.onDataVolume(path), expected, "\(path) on the data volume")
            c.equal(PathDisplay.friendly(data + path), expected == nil ? data + path : path, "\(data + path) shown as")
        }

        c.section("Reading a cloud folder after the scan")
        // Turn folder "big" into a placeholder the way a folder only in the cloud looks after a scan,
        // then read it the way DiskLens reads cloud folders, and check it fills back in. ("big" has
        // no hard links: a real cloud folder was never read before, so none of its links were seen.)
        guard let a = whole.root.descendant(atPath: f.root + "/big") else {
            c.fail("folder big missing")
            return
        }
        let full = (allocated: whole.root.allocated, files: whole.root.fileCount, folders: whole.root.folderCount)
        let empty = Node(name: "big", parent: nil)
        empty.cloudOnly = true
        a.adopt(contentsOf: empty)
        whole.cloudOnlyFolders += 1
        c.expect(a.cloudOnly && a.ownFileCount == 0, "a placeholder holds nothing yet")
        c.expect(whole.root.allocated < full.allocated, "and the totals leave it out")
        let cloudInbox = ScanInbox()
        ScanEngine.readCloudFolders([CloudFolder(path: f.root + "/big", name: "big", node: a)],
                                    rootDevice: whole.rootDevice, links: HardLinkRegistry(), topCount: 10,
                                    now: whole.scanTime, progress: ScanProgress(), deliver: { cloudInbox.add($0) })
        for piece in cloudInbox.takeAll() { whole.fillIn(piece) }
        c.expect(!a.cloudOnly, "once read, the folder is no longer marked as in the cloud")
        c.equal(whole.cloudOnlyFolders, 0, "and isn't counted as unread")
        c.equal(whole.root.allocated, full.allocated, "the totals are whole again")
        c.equal(whole.root.fileCount, full.files, "files too")
        c.equal(whole.root.folderCount, full.folders, "and folders")
        c.equal(a.ownFileCount, 2, "its files are back")

        let stopped = ScanProgress()
        stopped.cancel()
        let stoppedInbox = ScanInbox()
        ScanEngine.readCloudFolders([CloudFolder(path: f.root + "/big", name: "big", node: a)],
                                    rootDevice: whole.rootDevice, links: HardLinkRegistry(), topCount: 10,
                                    now: whole.scanTime, progress: stopped, deliver: { stoppedInbox.add($0) })
        c.expect(stoppedInbox.takeAll().isEmpty, "stopping before a cloud folder is read delivers nothing")
    }

    // MARK: - Small pieces

    /// Runs the main run loop, so work handed to the main actor gets done, until `done` holds (for at
    /// most `seconds`). Whether it held.
    @MainActor
    static func runMainLoop(upTo seconds: TimeInterval = 30, until done: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return done()
    }

    @MainActor
    static func unitTests(_ c: Checks) {
        c.section("Hard links in a part thrown away")
        let registry = HardLinkRegistry()
        let linked = FileKey(device: 1, inode: 2)
        c.expect(registry.isFirstSighting(linked) && !registry.isFirstSighting(linked), "a hard link counts once")
        registry.forget([linked])
        c.expect(registry.isFirstSighting(linked), "and counts again once the part that counted it is thrown away")

        c.section("Folders handed over and never read")
        let queue = WorkQueue([CloudFolder(path: "/a", name: "a", node: Node(name: "a", parent: nil))])
        queue.add(CloudFolder(path: "/a/b", name: "b", node: Node(name: "b", parent: nil)))
        queue.stop()
        let left = queue.leftOver()
        c.equal(left.map(\.folder.name), ["a", "b"], "a stopped queue gives back what it never handed out")
        c.equal(left.map(\.handedOff), [false, true], "telling the folders it began with from those handed over")
        c.equal(queue.leftOver().count, 0, "once")

        c.section("File extensions")
        let extensions: [(String, String)] = [
            ("photo.JPG", "jpg"), ("archive.tar.gz", "gz"), (".zshrc", ""), ("README", ""),
            ("trailing.", ""), ("ab", ""), ("x.y", "y"), ("name.averyveryverylongext", ""),
        ]
        for (name, expected) in extensions {
            c.equal(NameTools.fileExtension(of: name), expected, "extension of \(name)")
        }

        c.section("Space folders themselves take (exFAT and FAT drives)")
        let top = Node(name: "Drive", parent: nil)
        top.rootPath = "/Volumes/Drive"
        top.folderAllocated = 128
        let photos = Node(name: "Photos", parent: top)
        photos.folderAllocated = 128
        photos.ownAllocated = 1_000
        photos.ownSize = 900
        photos.ownFileCount = 2
        let waiting = Node(name: "Backups", parent: top)
        waiting.folderAllocated = 128
        waiting.pending = true
        top.children = [photos, waiting]
        photos.finalize()
        top.finalize()
        c.equal(photos.allocated, 1_128, "a folder's total includes the space it takes itself")
        c.equal(photos.size, 900, "but not its size (what its files contain)")
        c.equal(photos.filesNode?.allocated, 1_000, "[Files] stays the files alone")
        c.equal(top.allocated, 1_256, "folders still being read count once they arrive")
        let contents = Node(name: "Backups", parent: nil)
        contents.ownAllocated = 500
        contents.ownFileCount = 1
        waiting.adopt(contentsOf: contents)
        c.equal(waiting.allocated, 628, "a folder read later keeps the space it takes itself")
        c.equal(top.allocated, 1_884, "and its total reaches the folders above")
        top.removeChild(photos)
        c.equal(top.allocated, 756, "moving a folder to the Trash takes away its own space too")

        c.section("Counts with nouns")
        c.equal(SizeFormat.count(1, "extra hard link"), "1 extra hard link", "one")
        c.equal(SizeFormat.count(2, "extra hard link"), "2 extra hard links", "two")
        c.equal(SizeFormat.count(0, "folder"), "0 folders", "zero")

        c.section("Sorting table rows")
        func row(_ name: String, _ allocated: Int64, _ size: Int64, _ day: Double) -> DetailItem {
            DetailItem(id: "/f/" + name, name: name, isFolder: false, size: size, allocated: allocated, files: 1,
                       folders: 0, modified: Date(timeIntervalSince1970: day * 86_400), kind: "Document",
                       percent: Double(allocated) / 100, unreadable: false)
        }
        // Many equal sizes (ties keep their order), names that sort by number ("File 2" before "File 10").
        let rows = (0..<200).map { i in row("File \((i * 37) % 200)", Int64(i % 7), Int64(i % 5), Double(i % 3)) }
        let orders: [[KeyPathComparator<DetailItem>]] = [
            [KeyPathComparator(\.allocated, order: .reverse)],
            [KeyPathComparator(\.allocated)],
            [KeyPathComparator(\.name)],
            [KeyPathComparator(\.name, order: .reverse)],
            [KeyPathComparator(\.percent, order: .reverse)],
            [KeyPathComparator(\.modified)],
            [KeyPathComparator(\.size, order: .reverse), KeyPathComparator(\.name)],
            [KeyPathComparator(\.modified, order: .reverse), KeyPathComparator(\.allocated), KeyPathComparator(\.name)],
        ]
        for (index, order) in orders.enumerated() {
            c.equal(FastSort.sorted(rows, using: order).map(\.id), rows.sorted(using: order).map(\.id), "order \(index + 1)")
        }
        c.equal(FastSort.sorted(rows, using: []).map(\.id), rows.map(\.id), "no sort order keeps the rows as they are")
        c.equal(FastSort.sorted(rows, using: [KeyPathComparator(\.name)]).prefix(3).map(\.name),
                ["File 0", "File 1", "File 2"], "names sort like Finder")

        c.section("Keeping Details rows sorted as they change")
        func folder(_ name: String, _ allocated: Int64, _ size: Int64, _ day: Double) -> DetailItem {
            DetailItem(id: "/f/" + name, name: name, isFolder: true, size: size, allocated: allocated, files: 3,
                       folders: 1, modified: Date(timeIntervalSince1970: day * 86_400), kind: "Folder",
                       percent: Double(allocated) / 100, unreadable: false)
        }
        func apart(_ folders: [DetailItem], _ files: [DetailItem], _ order: [KeyPathComparator<DetailItem>]) -> DetailRows {
            DetailRows(folders: FastSort.sorted(folders, using: order), files: FastSort.sorted(files, using: order),
                       total: 100, order: RowOrder(order))
        }
        // Sizes and dates shared with the files, so folders and files tie (the folder comes first).
        let folders = (0..<40).map { i in folder("Folder \((i * 13) % 40)", Int64(i % 7), Int64(i % 4), Double(i % 3)) }
        for (index, order) in orders.enumerated() {
            let together = FastSort.sorted(folders + rows, using: order).map(\.id)
            c.equal(apart(folders, rows, order).map(\.id), together,
                    "folders and files sorted apart show as sorted together, order \(index + 1)")
            // Files arriving in batches, each merged into those before, as while a folder is read.
            var merged: [DetailItem] = []
            for start in stride(from: 0, to: rows.count, by: 37) {
                let batch = FastSort.sorted(Array(rows[start..<min(start + 37, rows.count)]), using: order)
                merged = FastSort.merged(merged, batch, in: RowOrder(order))
            }
            c.equal(merged.map(\.id), FastSort.sorted(rows, using: order).map(\.id),
                    "files merged batch by batch end up sorted, order \(index + 1)")
            let few = FastSort.sorted(Array(rows[..<5]), using: order)
            let many = FastSort.sorted(Array(rows[5...]), using: order)
            c.equal(FastSort.merged(few, many, in: RowOrder(order)).map(\.id), FastSort.sorted(rows, using: order).map(\.id),
                    "many rows merged into a few, order \(index + 1)")
        }
        c.equal(FastSort.merged([], rows, in: RowOrder([KeyPathComparator(\.name)])).count, rows.count, "merging into nothing")
        c.equal(FastSort.firstIndex(from: 0, to: 100) { $0 >= 63 }, 63, "galloping finds the first index past")
        c.equal(FastSort.firstIndex(from: 10, to: 100) { $0 >= 5 }, 10, "already past at the start")
        c.equal(FastSort.firstIndex(from: 0, to: 100) { _ in false }, 100, "never past")

        // Files read while the folder was smaller have shares worked out from that smaller total.
        let byShare = [KeyPathComparator(\DetailItem.percent, order: .reverse)]
        let readEarlier = rows.map { row -> DetailItem in
            var row = row
            row.percent = Double(row.allocated) / 50
            return row
        }
        let shares = DetailRows(folders: FastSort.sorted(folders, using: byShare),
                                files: FastSort.sorted(readEarlier, using: byShare), total: 200, order: RowOrder(byShare))
        c.equal(shares.map(\.id), FastSort.sorted(folders + rows, using: byShare).map(\.id),
                "files read when the folder was smaller sort by their share of it now")
        c.expect(shares.allSatisfy { $0.percent == Double($0.allocated) / 200 }, "% of Parent follows the folder's total")

        let byName = apart(folders, rows, [KeyPathComparator(\.name)])
        let shown = Array(byName)
        for target in [shown[0], shown[57], shown[shown.count - 1], shown.first(where: \.isFolder)!] {
            let row = shown.firstIndex { $0.id == target.id }!
            c.equal(byName.row(of: target.id, near: row), row, "a row found where it is")
            c.equal(byName.row(of: target.id, near: max(0, row - 5)), row, "a row found near where it was")
            c.equal(byName.row(of: target.id, near: -1), row, "a row found with nothing to go on")
        }
        c.equal(byName.row(of: "/f/Missing", near: 3), nil, "a row not shown isn't found")
        c.equal(DetailRows().row(of: "/f/File 1", near: 0), nil, "nothing is found in no rows")

        c.section("Details rows as a folder changes")
        let state = DetailsState()
        state.show(folders: folders, files: rows, total: 100)
        c.equal(state.rows.map(\.id), FastSort.sorted(folders + rows, using: state.sortOrder).map(\.id),
                "a folder's rows, sorted")
        let grown = (0..<40).map { (i: Int) -> DetailItem in
            let size = Int64((i * 5) % 9)
            return folder("Folder \((i * 13) % 40)", size, Int64(i % 4), Double(i % 3))
        }
        state.show(folders: grown, total: 100)
        c.equal(state.rows.map(\.id), FastSort.sorted(grown + rows, using: state.sortOrder).map(\.id),
                "new folder rows with the same files")
        state.sortOrder = [KeyPathComparator(\.name)]
        c.equal(state.rows.map(\.id), FastSort.sorted(grown + rows, using: state.sortOrder).map(\.id), "sorted again by name")
        _ = runMainLoop(upTo: 0.4) { false }
        c.expect(state.sortingFiles == nil, "a quick sort shows no Sorting message")
        state.show(folders: [], files: [], total: 0)
        c.expect(state.rows.isEmpty, "an empty folder shows no rows")

        // Many files are sorted again on another thread: the rows keep their order until then.
        let many = (0..<(DetailsState.sortHereLimit + 5_000)).map { (i: Int) -> DetailItem in
            let name = "Many \((i * 7_919) % 25_000)"
            return row(name, Int64(i % 13), Int64(i % 5), Double(i % 11))
        }
        let big = DetailsState()
        big.show(folders: folders, files: many, total: 100)
        let bySize = big.rows.map(\.id)
        big.sortOrder = [KeyPathComparator(\.name)]
        c.equal(big.rows.map(\.id), bySize, "many files keep their order while they are sorted again")
        c.expect(big.needsSorting, "and are still to be sorted")
        c.expect(big.sortingFiles == nil, "with no Sorting message at once")
        let manyByName = FastSort.sorted(folders + many, using: big.sortOrder).map(\.id)
        c.expect(runMainLoop { big.rows.map(\.id) == manyByName }, "then show in the order chosen")
        c.expect(!big.needsSorting, "with nothing left to sort")
        _ = runMainLoop(upTo: 0.4) { false }
        c.expect(big.sortingFiles == nil, "and no Sorting message left")
        big.sortOrder = [KeyPathComparator(\.modified)]
        big.sortOrder = [KeyPathComparator(\.size, order: .reverse)]
        let manyBySize = FastSort.sorted(folders + many, using: big.sortOrder).map(\.id)
        c.expect(runMainLoop { !big.needsSorting && big.rows.map(\.id) == manyBySize },
                 "orders chosen one after another end in the last one")
        big.show(folders: grown, total: 100)
        c.equal(big.rows.map(\.id), FastSort.sorted(grown + many, using: big.sortOrder).map(\.id),
                "new folder rows go in the order the files are in")

        c.section("Age bands")
        let day: Int64 = 86_400
        c.equal(AgeBands.index(ageSeconds: 0), 0, "brand new")
        c.equal(AgeBands.index(ageSeconds: 6 * day), 0, "6 days")
        c.equal(AgeBands.index(ageSeconds: 7 * day), 1, "7 days")
        c.equal(AgeBands.index(ageSeconds: 3 * 365 * day), 6, "3 years")
        c.equal(AgeBands.index(ageSeconds: 6 * 365 * day), 7, "6 years")

        c.section("Largest files")
        var heap = TopFileHeap(capacity: 10)
        for i in (1...100).shuffled() {
            heap.insert(TopFile(path: "/f\(i)", size: Int64(i), allocated: Int64(i), modified: 0))
        }
        c.equal(heap.sortedDescending().map(\.allocated), (91...100).reversed().map { Int64($0) }, "keeps the 10 largest")
        var other = TopFileHeap(capacity: 10)
        other.insert(TopFile(path: "/huge", size: 1000, allocated: 1000, modified: 0))
        heap.merge(other)
        c.equal(heap.sortedDescending().first?.path, "/huge", "merge keeps a larger file")
        c.equal(heap.items.count, 10, "merge keeps the capacity")

        c.section("Folders DiskLens refuses to trash")
        let home = NSHomeDirectory()
        for path in [home, home + "/Library", "/", "/Users", "/Applications", "/Library", "/System/Library", "/Volumes/Backup"] {
            c.expect(FileActions.isProtected(path), "\(path) should be protected")
        }
        for path in [home + "/Downloads/old-project", "/Applications/Some App.app", "/Volumes/Backup/Old"] {
            c.expect(!FileActions.isProtected(path), "\(path) should not be protected")
        }

        suggestionTests(c)

        c.section("Scan failures")
        let cancelled = ScanProgress()
        cancelled.cancel()
        if case .cancelled = ScanEngine.scan(path: NSTemporaryDirectory(), displayName: "tmp", topCount: 10, progress: cancelled) {
            c.pass()
        } else {
            c.fail("a cancelled scan should end as cancelled")
        }
        if case .failed(let message) = ScanEngine.scan(path: "/no/such/folder-\(UUID())", displayName: "gone",
                                                       topCount: 10, progress: ScanProgress()) {
            c.expect(message.contains("no longer exists"), "missing folder message: \(message)")
        } else {
            c.fail("scanning a missing folder should fail")
        }

        searchUnitTests(c)
    }

    @MainActor
    static func searchUnitTests(_ c: Checks) {
        c.section("Search: matching names")
        let matches = { (query: String, name: String) in SearchQuery(query).matches(name) }
        c.expect(matches("cache", "Caches"), "case doesn't matter")
        c.expect(matches("CACHE", "app cache.db"), "upper-case query, lower-case name")
        c.expect(matches("resume", "Résumé.pdf"), "accents don't matter")
        c.expect(matches("résumé", "Re\u{301}sume\u{301}.pdf"), "a decomposed name (as some disks store it) matches")
        c.expect(matches("RÉSUMÉ", "resume.txt"), "an accented query matches a plain name")
        c.expect(matches("photo 2023", "2023 Holiday Photos"), "every word, in any order")
        c.expect(!matches("photo 2024", "2023 Holiday Photos"), "every word must appear")
        c.expect(matches(".dmg", "Installer.DMG"), "an extension")
        c.expect(!matches(".dmg", "dmg-notes.txt"), "an extension needs its dot")
        c.expect(matches("写真", "2023 写真"), "names that aren't in Latin letters")
        c.expect(matches("ｆｉｌｅ", "File.txt"), "full-width letters")
        c.expect(matches("strasse", "Straße"), "ß and ss")
        c.expect(matches("a", "A"), "a single letter")
        c.expect(!matches("abc", "ab"), "a word longer than the name")
        c.expect(!matches("", "anything"), "an empty query matches nothing")
        c.expect(SearchQuery(" \t ").isEmpty, "spaces only is an empty query")
        c.equal(SearchQuery("  two   words ").words, ["two", "words"], "the words as typed")
        let bytes = Array("Library".utf8)
        c.expect(bytes.withUnsafeBytes { SearchQuery("BRAR").matches(utf8: $0) }, "names straight from readdir")

        c.section("Search: ranking")
        func hit(_ name: String, _ allocated: Int64, size: Int64? = nil, kind: SearchHit.Kind = .file,
                 folder: Int32 = 1, path: String? = nil) -> SearchHit {
            SearchHit(kind: kind, name: name, folder: folder, size: size ?? allocated, allocated: allocated,
                      path: path ?? "/scan/\(name)")
        }
        var largest = LargestHits(capacity: 10, bySize: false)
        for i in (1...1000).shuffled() { largest.add(hit("f\(i)", Int64(i))) }
        c.equal(largest.matched, 1000, "every match is counted")
        c.equal(largest.sorted().map(\.allocated), (991...1000).reversed().map { Int64($0) }, "keeps the 10 largest, largest first")
        c.expect(!largest.wants(990) && largest.wants(1000), "knows which sizes it would keep")
        var ties = LargestHits(capacity: 5, bySize: false)
        ties.add(hit("b", 5))
        ties.add(hit("a", 5))
        ties.add(hit("z", 5, kind: .folder, folder: 3))
        c.equal(ties.sorted().map(\.name), ["z", "a", "b"], "equal sizes: folders first, then by name")
        var bySize = LargestHits(capacity: 2, bySize: true)
        bySize.add(hit("sparse", 1, size: 1000))
        bySize.add(hit("dense", 500))
        bySize.add(hit("small", 10))
        c.equal(bySize.sorted().map(\.name), ["sparse", "dense"], "the Size mode ranks by size, not space on disk")
        var first = LargestHits(capacity: 3, bySize: false)
        var second = LargestHits(capacity: 3, bySize: false)
        for i in 1...5 { first.add(hit("p\(i)", Int64(i))) }
        for i in 6...9 { second.add(hit("q\(i)", Int64(i * 10))) }
        first.merge(second)
        c.equal(first.matched, 9, "merging adds the counts")
        c.equal(first.sorted().map(\.name), ["q9", "q8", "q7"], "and keeps the largest of both")
        var none = LargestHits(capacity: 0, bySize: false)
        none.add(hit("x", 1))
        c.expect(none.heap.isEmpty && none.matched == 1, "a capacity of 0 only counts")

        var topFiles = LargestHits(capacity: 10, bySize: false)
        topFiles.add(hit("big.iso", 900, folder: -1, path: "/scan/a/big.iso"))
        var read = LargestHits(capacity: 10, bySize: false)
        read.add(hit("big.iso", 900, folder: 4, path: "/scan/a/big.iso"))
        read.add(hit("small.iso", 5, folder: 4, path: "/scan/a/small.iso"))
        var folders = LargestHits(capacity: 10, bySize: false)
        folders.add(hit("isos", 1000, kind: .folder, folder: 2, path: "/scan/isos"))
        let merged = ScanSearch.merge(folders: folders, files: [read, topFiles], bySize: false)
        c.equal(merged.map(\.name), ["isos", "big.iso", "small.iso"], "folders and files in one list, largest first")
        c.equal(merged.first { $0.name == "big.iso" }?.folder, 4, "a Top File found again is listed once")
        c.equal(ScanSearch.merge(folders: folders, files: [read, topFiles], bySize: false, limit: 2).count, 2, "the list is capped")

        c.section("Search: where results are")
        c.equal(SearchIndex.describe([String](), rootName: "Home"), "Home", "the top of the scan")
        c.equal(SearchIndex.describe(["Library"], rootName: "Home"), "Library", "one folder down")
        c.equal(SearchIndex.describe(["Library", "Caches"], rootName: "Home"), "Library › Caches", "two folders down")
        c.equal(SearchIndex.describe(["Library", "Caches", "com.example", "Cache"], rootName: "Home"),
                "Library › … › Cache", "deeper: first and last folder")
        c.equal(SearchIndex.components(of: "/Users/me/Library/Caches", below: "/Users/me"), ["Library", "Caches"], "folders below the root")
        c.equal(SearchIndex.components(of: "/Users/me", below: "/Users/me"), [], "the root itself")
        c.equal(SearchIndex.components(of: "/Volumes/X/a", below: "/"), ["Volumes", "X", "a"], "below /")
        c.equal(SearchIndex.join("/", ["a", "b"]), "/a/b", "joining onto /")
        c.equal(SearchIndex.join("/scan", []), "/scan", "joining nothing")
    }

    // MARK: - Changes since an earlier scan

    /// A tree for the snapshot tests: every folder's relative path, with the space its own files take.
    /// Parents must be listed too ("" is the scanned folder).
    static func tree(_ folders: [String: Int64], root rootPath: String = "/scan") -> Node {
        let root = Node(name: "scan", parent: nil)
        root.rootPath = rootPath
        root.ownAllocated = folders[""] ?? 0
        var nodes: [String: Node] = ["": root]
        var order: [Node] = []
        for path in folders.keys.sorted(by: { ($0.utf8.count, $0) < ($1.utf8.count, $1) }) where !path.isEmpty {
            let (parentPath, name) = FolderSnapshot.split(path)
            guard let parent = nodes[parentPath] else { continue }
            let node = Node(name: name, parent: parent)
            node.ownAllocated = folders[path] ?? 0
            parent.children.append(node)
            nodes[path] = node
            order.append(node)
        }
        for node in order.reversed() { node.finalize() }
        root.finalize()
        return root
    }

    @MainActor
    static func changeTests(_ c: Checks) {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(86_400)

        c.section("Folder snapshots")
        let small = tree(["": 10, "a": 100, "a/b": 50, "a/b/c": 5, "d": 0, "big": 1000, "big/x": 10])
        let snapshot = FolderSnapshot(root: small, path: "/scan", date: earlier)
        c.equal(snapshot.allocated, 1175, "total")
        c.equal(snapshot.children[""], ["a": 155, "d": 0, "big": 1010], "the scanned folder's child folders")
        c.equal(snapshot.allocated(at: "a/b"), 55, "a folder two levels down")
        c.equal(snapshot.allocated(at: "a/b/c"), 5, "three levels down")
        c.equal(snapshot.allocated(at: "nope"), nil, "a folder that isn't there")
        c.expect(snapshot.isOpened("a/b/c") && snapshot.isOpened("d"), "folders without subfolders are opened (nothing missing)")
        c.equal(FolderSnapshot(root: small, path: "/scan", date: earlier), snapshot, "the same tree gives the same snapshot")
        if let data = try? JSONEncoder().encode(snapshot) {
            c.equal(try? JSONDecoder().decode(FolderSnapshot.self, from: data), snapshot, "a snapshot survives saving and loading")
        } else {
            c.fail("couldn't encode a snapshot")
        }

        let shallow = FolderSnapshot(root: small, path: "/scan", date: earlier, maxDepth: 1)
        c.equal(shallow.children.keys.sorted(), [""], "maxDepth 1 opens only the scanned folder")
        c.equal(shallow.allocated(at: "a"), 155, "but records its child folders")

        let wide = tree(["": 0, "big": 1000, "big/1": 1, "big/2": 1, "big/3": 1, "big/4": 1, "big/5": 1,
                         "a": 100, "a/b": 50, "a/b/c": 5, "z": 1])
        let limited = FolderSnapshot(root: wide, path: "/scan", date: earlier, limit: 6)
        c.expect(!limited.isOpened("big"), "a folder whose children don't fit isn't opened")
        c.expect(limited.isOpened("a") && limited.isOpened("a/b"), "smaller folders that fit still are")
        c.expect(limited.folderCount <= 6, "the snapshot stays within its limit (\(limited.folderCount) folders)")
        c.equal(limited.allocated(at: "big"), 1005, "the unopened folder's own size is still recorded")

        let locked = tree(["": 0, "locked": 0, "disk": 0, "fine": 1])
        locked.children.first { $0.name == "locked" }?.unreadable = true
        locked.children.first { $0.name == "disk" }?.otherVolume = true
        let lockedSnapshot = FolderSnapshot(root: locked, path: "/scan", date: earlier)
        c.expect(!lockedSnapshot.isOpened("locked") && !lockedSnapshot.isOpened("disk"),
                 "unreadable folders and other disks are never opened")
        c.expect(lockedSnapshot.isOpened("fine"), "a readable empty folder is")

        c.section("Paths inside a scan")
        c.equal(FolderSnapshot.relativePath(of: "/scan/a/b", inside: "/scan"), "a/b", "relative path")
        c.equal(FolderSnapshot.relativePath(of: "/scan", inside: "/scan"), "", "the scanned folder itself")
        c.equal(FolderSnapshot.relativePath(of: "/scanner/a", inside: "/scan"), nil, "a folder next to it, with a longer name")
        c.equal(FolderSnapshot.relativePath(of: "/Users", inside: "/"), "Users", "inside the root of a disk")
        c.equal(FolderSnapshot.absolutePath(of: "Users", inside: "/"), "/Users", "and back")
        c.equal(FolderSnapshot.absolutePath(of: "", inside: "/scan"), "/scan", "the scanned folder's own path")

        c.section("Comparing two scans")
        let before = tree(["": 10, "a": 100, "a/b": 50, "gone": 300, "old-name": 400, "same": 7,
                           "shrinks": 900, "files-only": 20])
        let after = tree(["": 25, "a": 100, "a/b": 80, "a/new": 60, "new-name": 401, "same": 7,
                          "shrinks": 100, "files-only": 20, "empty-new": 0])
        let base = FolderSnapshot(root: before, path: "/scan", date: earlier)
        let now = FolderSnapshot(root: after, path: "/scan", date: later, opening: base)
        c.expect(now.isOpened("") && now.isOpened("a") && !now.isOpened("gone"),
                 "the current side opens what the earlier scan opened, where it still exists")
        let comparison = FolderComparison(base: base, current: now)
        c.equal(comparison.totalChange, after.allocated - before.allocated, "change of the total")
        c.equal(comparison.changes.map(\.id),
                ["folder:shrinks", "folder:gone", "folder:a", "folder:a/new", "folder:a/b", "files:", "folder:new-name"],
                "changes, biggest first")
        c.equal(comparison.change(at: "a")?.change, 90, "a grew by its subfolders")
        c.equal(comparison.change(at: "a/new")?.kind, .added, "a new folder")
        c.equal(comparison.changes.first { $0.path == "gone" }?.kind, .removed, "a removed folder")
        c.equal(comparison.changes.first { $0.path == "gone" }?.before, 300, "and what it took")
        c.equal(comparison.change(at: "new-name")?.kind, .renamed, "a renamed folder is recognised")
        c.equal(comparison.change(at: "new-name")?.oldName, "old-name", "with its earlier name")
        c.equal(comparison.change(at: "new-name")?.change, 1, "and how much it changed")
        c.equal(comparison.changes.first { $0.kind == .files }?.change, 15, "loose files in the scanned folder")
        c.equal(comparison.change(at: "same")?.change, 0, "an unchanged folder is known")
        c.expect(!comparison.changes.contains { $0.path == "same" || $0.path == "files-only" }, "but not listed")
        c.equal(comparison.change(at: "empty-new")?.kind, .added, "an empty new folder is known")
        c.expect(!comparison.changes.contains { $0.path == "empty-new" }, "but not listed (it takes no space)")
        c.equal(comparison.change(at: "gone"), nil, "nothing to show for a folder that no longer exists")
        c.equal([comparison.grew, comparison.shrank, comparison.added, comparison.removed, comparison.renamed],
                [3, 1, 1, 1, 1], "grew, shrank, new, removed, renamed")

        let flatBase = FolderSnapshot(root: tree(["": 10]), path: "/scan", date: earlier)
        let flat = FolderComparison(base: flatBase, current: FolderSnapshot(root: tree(["": 30]), path: "/scan",
                                                                            date: later, opening: flatBase))
        c.equal(flat.changes.map(\.id), ["files:"], "a folder without subfolders lists its loose files")

        let shallowBase = FolderSnapshot(root: before, path: "/scan", date: earlier, maxDepth: 1)
        let shallowComparison = FolderComparison(
            base: shallowBase, current: FolderSnapshot(root: after, path: "/scan", date: later, opening: shallowBase))
        c.equal(shallowComparison.change(at: "a")?.change, 90, "a folder the earlier scan recorded")
        c.equal(shallowComparison.change(at: "a/new"), nil, "nothing inside a folder the earlier scan didn't open")

        let twins = FolderComparison(
            base: FolderSnapshot(path: "/scan", date: earlier, allocated: 400,
                                 children: ["": ["x": 100, "y": 100, "r": 100, "e": 0, "e2": 0]]),
            current: FolderSnapshot(path: "/scan", date: later, allocated: 450,
                                    children: ["": ["p": 100, "q": 100, "s": 150, "f": 0]]))
        c.equal(twins.renamed, 2, "two renamed folders of the same size are both paired")
        c.equal(twins.removed, 1, "a folder with no match of about its size was removed")
        c.equal(twins.changes.first { $0.kind == .added }?.path, "s", "and the bigger one is new")
        c.equal(twins.change(at: "f")?.kind, .added, "empty folders are never taken for renamed ones")

        let unreadNow = tree(["": 0, "evicted": 0, "unread": 0, "kept": 5])
        unreadNow.children.first { $0.name == "evicted" }?.cloudOnly = true
        unreadNow.children.first { $0.name == "unread" }?.pending = true
        let unreadBase = FolderSnapshot(path: "/scan", date: earlier, allocated: 705,
                                        children: ["": ["evicted": 400, "unread": 300, "kept": 5]])
        let unread = FolderComparison(base: unreadBase, current: FolderSnapshot(root: unreadNow, path: "/scan",
                                                                                date: later, opening: unreadBase))
        c.equal(unread.removed, 0, "folders not read this time aren't taken for removed ones")
        c.equal(unread.change(at: "evicted")?.change, -400, "one now only in the cloud shows the space it freed")
        c.equal(unread.change(at: "unread")?.change, -300, "one still being read counts what the tree has for it")
        c.expect(!unread.changes.contains { $0.kind == .files },
                 "so the folder's loose files still add up (no change shows there)")

        c.section("Part of an earlier scan")
        if let part = base.part(at: "/scan/a") {
            c.equal(part.path, "/scan/a", "path of the part")
            c.equal(part.allocated, 150, "its total")
            c.equal(part.children[""], ["b": 50], "its child folders")
            c.equal(part.partOf, "/scan", "and where it came from")
        } else {
            c.fail("no part for an opened folder")
        }
        c.equal(base.part(at: "/scan/nope"), nil, "no part for a folder the scan didn't have")
        c.equal(base.part(at: "/scanner"), nil, "or for a folder outside it")
        c.equal(FolderSnapshot(path: "/", date: earlier, allocated: 5, children: ["": ["Users": 5], "Users": [:]])
                    .part(at: "/Users")?.allocated, 5, "a folder inside the root of a disk")
        let startupDisk = FolderSnapshot(path: "/System/Volumes/Data", date: earlier, allocated: 5,
                                         children: ["": ["Users": 5], "Users": [:]])
        c.equal(startupDisk.part(at: "/System/Volumes/Data/Users", shownAs: "/Users")?.path, "/Users",
                "a part of a startup disk scan takes the folder's usual path")
        c.equal(PathDisplay.onDataVolume("/System/Volumes/Data/Users"), nil, "a path already on the data volume stays")
        c.equal(PathDisplay.onDataVolume("/"), nil, "the root of the disk has no other name")
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data/Users") {
            c.equal(PathDisplay.onDataVolume("/Users"), "/System/Volumes/Data/Users",
                    "/Users is found where a startup disk scan keeps it")
            c.equal(PathDisplay.onDataVolume("/System/Library"), nil, "a folder on the system volume isn't")
        }

        c.section("Old scan history")
        let old = #"[{"date":816217450.1,"allocated":1324473909248,"path":"/Users/me","size":1981948116830,"files":6229192}]"#
        let entries = try? JSONDecoder().decode([HistoryEntry].self, from: Data(old.utf8))
        c.equal(entries?.first?.allocated, 1_324_473_909_248, "a history file from before snapshots still reads")

        storeTests(c, earlier: earlier)
        rescanTest(c)
    }

    static func storeTests(_ c: Checks, earlier: Date) {
        c.section("Storing snapshots")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLensSnapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var store = SnapshotStore(folder: folder)
        store.perRoot = 2
        store.maxRoots = 2
        func make(_ path: String, _ day: Double, _ size: Int64) -> FolderSnapshot {
            FolderSnapshot(path: path, date: earlier.addingTimeInterval(day * 86_400), allocated: size,
                           children: ["": ["a": size], "a": ["b": size]])
        }
        let first = make("/scan", 0, 10), second = make("/scan", 1, 20), third = make("/scan", 2, 30)
        c.equal(store.load() ?? [FolderSnapshot](), [], "no file yet: nothing stored, and nothing to compare with")
        c.equal(store.record(first), [], "the first scan of a folder has nothing to compare with")
        c.equal(store.record(second), [first], "the second is compared with the first")
        c.equal(store.record(third), [second, first], "the third can be compared with either")
        c.equal(store.load()?.filter { $0.path == "/scan" }.map(\.date).sorted(), [second.date, third.date],
                "only the last two scans of a folder are kept")
        c.equal(store.record(make("/other", 3, 5)), [], "another folder isn't compared with /scan")

        let part = store.record(make("/scan/a", 4, 7))
        c.equal(part.map(\.allocated), [30, 20], "a folder scanned before as part of another is compared with that")
        c.equal(part.first?.partOf, "/scan", "and says so")
        c.equal(Set(store.load()?.map(\.path) ?? []), ["/scan/a", "/other"], "only the most recently scanned folders are kept")

        var tiny = store
        tiny.maxBytes = 10
        _ = tiny.record(make("/third", 5, 1))
        c.equal(store.load()?.map(\.path), ["/third"], "when the file gets too big, the folders scanned longest ago go first")

        let url = store.fileURL
        try? Data("not json".utf8).write(to: url)
        c.equal(store.record(make("/scan", 6, 1)), [], "a damaged file gives nothing to compare with")
        c.expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("snapshots-damaged.json").path),
                 "and is kept aside")
        c.equal(store.load()?.count, 1, "a fresh file is started")

        let future = Data(#"{"version":99,"snapshots":[],"more":"from a newer DiskLens"}"#.utf8)
        try? future.write(to: url)
        c.equal(store.record(make("/scan", 7, 1)), [], "a file from a newer DiskLens gives nothing to compare with")
        c.equal(try? Data(contentsOf: url), future, "and is left as it was")

        // A scan of the startup disk is kept under the data volume's path, and has "/Users" as
        // "/System/Volumes/Data/Users". A later first scan of /Users is compared with that part.
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data/Users") {
            try? FileManager.default.removeItem(at: url)
            let disk = FolderSnapshot(path: "/System/Volumes/Data", date: earlier.addingTimeInterval(8 * 86_400),
                                      allocated: 100, children: ["": ["Users": 90], "Users": ["Shared": 40]])
            c.equal(store.record(disk), [], "a scan of the startup disk")
            let users = FolderSnapshot(path: "/Users", date: earlier.addingTimeInterval(9 * 86_400),
                                       allocated: 95, children: ["": ["Shared": 45]])
            let bases = store.record(users)
            c.equal(bases.map(\.path), ["/Users"], "a later first scan of /Users is compared with its part of it")
            c.equal(bases.first?.children[""], ["Shared": 40], "with what that scan found in it")
            c.equal(bases.first?.partOf, "/System/Volumes/Data", "and says which scan it came from")
        }
    }

    /// Scans a folder, changes it, scans it again and compares, the way the app does.
    static func rescanTest(_ c: Checks) {
        c.section("Rescanning a changed folder")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("DiskLensRescan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        guard (try? fm.createDirectory(at: base, withIntermediateDirectories: true)) != nil,
              let real = realpath(base.path, nil) else {
            c.fail("couldn't make the test folder")
            return
        }
        let root = String(cString: real)
        free(real)
        func write(_ relative: String, _ bytes: Int) {
            let url = URL(fileURLWithPath: root + "/" + relative)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data(repeating: 0x61, count: bytes))
        }
        func scan() -> ScanResult? {
            guard case .finished(let result) = ScanEngine.scan(path: root, displayName: "Rescan", topCount: 10,
                                                               progress: ScanProgress()) else { return nil }
            return result
        }
        write("top.dat", 10_000)
        write("keep/a.dat", 100_000)
        write("grow/g.dat", 50_000)
        write("shrink/s1.dat", 200_000)
        write("shrink/s2.dat", 200_000)
        write("remove/r.dat", 300_000)
        write("rename-me/n.dat", 150_000)
        write("deep/er/still.dat", 20_000)
        guard let first = scan() else {
            c.fail("the first scan didn't finish")
            return
        }
        let earlier = FolderSnapshot(root: first.root, path: root, date: first.started)

        write("grow/more.dat", 400_000)
        try? fm.removeItem(atPath: root + "/shrink/s2.dat")
        try? fm.removeItem(atPath: root + "/remove")
        try? fm.moveItem(atPath: root + "/rename-me", toPath: root + "/renamed")
        write("fresh/f.dat", 250_000)
        write("top2.dat", 30_000)
        write("deep/er/new/n.dat", 40_000)
        guard let second = scan() else {
            c.fail("the second scan didn't finish")
            return
        }
        let comparison = FolderComparison(
            base: earlier, current: FolderSnapshot(root: second.root, path: root, date: second.started, opening: earlier))
        let node = { (relative: String) in second.root.descendant(atPath: root + "/" + relative) }
        let oldNode = { (relative: String) in first.root.descendant(atPath: root + "/" + relative) }

        c.equal(comparison.totalChange, second.root.allocated - first.root.allocated, "total change")
        c.equal(comparison.change(at: "grow")?.after, node("grow")?.allocated, "grow: size now")
        c.equal(comparison.change(at: "grow")?.before, oldNode("grow")?.allocated, "grow: size before")
        c.expect((comparison.change(at: "grow")?.change ?? 0) >= 400_000, "grow grew by the new file")
        c.expect((comparison.change(at: "shrink")?.change ?? 0) <= -200_000, "shrink shrank by the removed file")
        c.equal(comparison.change(at: "keep")?.change, 0, "keep didn't change")
        c.equal(comparison.change(at: "fresh")?.kind, .added, "fresh is new")
        c.equal(comparison.change(at: "renamed")?.kind, .renamed, "rename-me was renamed")
        c.equal(comparison.change(at: "renamed")?.oldName, "rename-me", "from rename-me")
        let removed = comparison.changes.first { $0.path == "remove" }
        c.equal(removed?.kind, .removed, "remove was removed")
        c.equal(removed?.before, oldNode("remove")?.allocated, "with the space it took")
        c.equal(comparison.change(at: "deep/er/new")?.kind, .added, "a new folder deeper down")
        c.expect((comparison.changes.first { $0.kind == .files && $0.path == "" }?.change ?? 0) >= 30_000,
                 "new loose files in the scanned folder")
        c.expect(!comparison.changes.contains { $0.path == "keep" }, "unchanged folders aren't listed")
        c.equal(comparison.changes.first?.path, "grow", "the biggest change comes first")

        // What AppModel does after a folder is moved to the Trash: compare the changed tree again.
        if let grow = node("grow") {
            second.root.removeChild(grow)
            let afterTrash = FolderComparison(
                base: earlier, current: FolderSnapshot(root: second.root, path: root, date: second.started, opening: earlier))
            c.equal(afterTrash.changes.first { $0.path == "grow" }?.kind, .removed, "a folder moved to the Trash shows as removed")
            c.equal(afterTrash.totalChange, second.root.allocated - first.root.allocated, "and the total follows")
        }
    }

    // MARK: - Suggestions

    /// Finds well-known places in made-up trees (no files needed: suggestions come from the tree).
    @MainActor
    static func suggestionTests(_ c: Checks) {
        let mb: Int64 = 1_000_000
        let home = "/Users/test"
        let homeFolders: [(String, Int64)] = [
            ("Library/Developer/Xcode/DerivedData/App-abc/Build", 900 * mb),
            ("Library/Developer/Xcode/Archives/2026-01-01", 300 * mb),
            ("Library/Developer/Xcode/iOS DeviceSupport/18.0", 200 * mb),
            ("Library/Developer/CoreSimulator/Devices/UUID-1", 700 * mb),
            ("Library/Caches/com.example.app", 100 * mb),
            ("Library/Caches/Homebrew/downloads", 400 * mb),
            ("Library/Application Support/MobileSync/Backup/device-1", 800 * mb),
            ("Library/Containers/com.docker.docker/Data", 1_000 * mb),
            (".Trash/old-project/node_modules", 50 * mb),
            ("Projects/web/node_modules/react", 120 * mb),
            ("Projects/web/node_modules/react/node_modules/inner", 30 * mb),   // part of the outer one
            ("Projects/web/src", 1 * mb),
            ("Projects/mono/packages/ui/node_modules/x", 60 * mb),
            ("Projects/empty/node_modules", 0),                                  // nothing to free
            (".vscode/extensions/ext/node_modules/x", 70 * mb),                  // an editor extension
            ("Library/Application Support/Code/node_modules/x", 80 * mb),        // app data
            ("Applications/Tool.app/Contents/Resources/app/node_modules/x", 90 * mb),  // inside an app
            ("Documents/notes", 5 * mb),
        ]
        let homeScan = SuggestionTree.make(rootPath: home, folders: homeFolders)
        let found = Suggestions.find(in: homeScan, home: home)
        let byKind = Dictionary(found.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })

        c.section("Suggestions: a home folder scan")
        c.equal(Set(found.map(\.kind)), Set(Suggestions.Kind.allCases), "finds every kind of place")
        c.equal(found.map(\.allocated), found.map(\.allocated).sorted(by: >), "largest first")
        c.equal(found.first?.kind, .docker, "the largest is Docker's data")
        c.equal(byKind[.derivedData]?.nodes.first?.path, home + "/Library/Developer/Xcode/DerivedData", "DerivedData's path")
        c.equal(byKind[.derivedData]?.allocated, 900 * mb, "DerivedData's size")
        c.equal(byKind[.caches]?.allocated, 500 * mb, "Caches includes Homebrew's cache")
        c.equal(byKind[.homebrew]?.allocated, 400 * mb, "Homebrew's cache on its own")
        c.equal(byKind[.trash]?.allocated, 50 * mb, "the Trash")
        c.expect(byKind[.trash]?.kind.canTrash == false, "the Trash itself is never moved to the Trash")
        let packages = byKind[.nodeModules]
        c.equal(packages?.nodes.map(\.path), [home + "/Projects/web/node_modules", home + "/Projects/mono/packages/ui/node_modules"],
                "node_modules of projects only, outer ones only, largest first")
        c.equal(packages?.allocated, 210 * mb, "node_modules total")
        c.equal(Suggestions.total(of: found),
                (900 + 300 + 200 + 700 + 500 + 800 + 1_000 + 50 + 210) * mb, "the total counts Homebrew's cache once")
        for suggestion in found where suggestion.kind.canTrash {
            for node in suggestion.nodes {
                c.expect(node.parent != nil, "\(suggestion.kind) is below the scan's top folder")
            }
        }
        for kind in Suggestions.Kind.allCases where kind.canTrash {
            if let relative = kind.homePath {
                c.expect(!FileActions.isProtected(NSHomeDirectory() + "/" + relative), "\(kind) can be moved to the Trash")
            }
        }

        c.section("Suggestions: other scans")
        let disk = SuggestionTree.make(rootPath: "/System/Volumes/Data", folders: [
            ("Users/test/Library/Caches/x", 100 * mb),
            ("Users/test/code/site/node_modules/x", 20 * mb),
            ("Users/other/Library/Caches/x", 300 * mb),                          // another user's
            ("usr/local/lib/node_modules/npm", 40 * mb),                         // global packages
            ("opt/homebrew/lib/node_modules/x", 40 * mb),
            ("Applications/Big.app/Contents/node_modules/x", 40 * mb),
            ("private/var/folders/node_modules/x", 40 * mb),
        ])
        let diskFound = Suggestions.find(in: disk, home: home)
        c.equal(diskFound.map(\.kind), [.caches, .nodeModules], "startup disk: the user's caches and project packages")
        c.equal(diskFound.first?.nodes.first?.path, "/System/Volumes/Data/Users/test/Library/Caches",
                "startup disk: found inside the data volume")
        c.equal(diskFound.last?.nodes.map(\.path), ["/System/Volumes/Data/Users/test/code/site/node_modules"],
                "startup disk: no node_modules of apps or command-line tools")

        let library = SuggestionTree.make(rootPath: home + "/Library/Developer", folders: [
            ("Xcode/DerivedData/x", 10 * mb), ("CoreSimulator/Devices/x", 10 * mb),
        ])
        c.equal(Set(Suggestions.find(in: library, home: home).map(\.kind)), [.derivedData, .simulators],
                "a scan of ~/Library/Developer finds Xcode's folders only")
        let caches = SuggestionTree.make(rootPath: home + "/Library/Caches", folders: [("Homebrew/x", 10 * mb), ("y", 5 * mb)])
        c.equal(Suggestions.find(in: caches, home: home).map(\.kind), [.homebrew],
                "a scan of ~/Library/Caches suggests what's inside it, not the scan itself")
        let emptyTrash = SuggestionTree.make(rootPath: home, folders: [(".Trash", 0), ("Documents/a", 5 * mb)])
        c.expect(Suggestions.find(in: emptyTrash, home: home).isEmpty, "an empty Trash isn't suggested")
        let elsewhere = SuggestionTree.make(rootPath: "/Volumes/Work", folders: [("Library/Caches/x", 10 * mb), ("app/node_modules/x", 10 * mb)])
        c.equal(Suggestions.find(in: elsewhere, home: home).map(\.kind), [.nodeModules], "another disk: node_modules only")
        let extensions = SuggestionTree.make(rootPath: home + "/.vscode/extensions", folders: [("ext/node_modules/x", 10 * mb)])
        c.expect(Suggestions.nodeModules(in: extensions).isEmpty, "a scan inside a hidden tool folder suggests no node_modules")

        c.equal(Suggestions.candidatePaths("/Users/test/.Trash"), ["/Users/test/.Trash", "/System/Volumes/Data/Users/test/.Trash"],
                "a path, and the same path on the data volume")
        for path in ["/usr/local/lib", "/System/Volumes/Data/opt/homebrew", "/Applications/A.app/Contents", "/Users/test/Library/X",
                     "/Users/test/.nvm/versions", "/Library"] {
            c.expect(Suggestions.isToolPath(path), "\(path) holds tools, not projects")
        }
        for path in ["/", "/System/Volumes/Data", "/System/Volumes/Data/Users/test", "/Users/test/Projects", "/Volumes/Work/code"] {
            c.expect(!Suggestions.isToolPath(path), "\(path) can hold projects")
        }
    }

    // MARK: - The test folder

    @MainActor
    static func fixtureTests(_ f: Fixture, _ c: Checks) {
        c.section("Scanning the test folder")
        guard case .finished(let result) = ScanEngine.scan(path: f.root, displayName: "Fixture",
                                                           topCount: 10, progress: ScanProgress()) else {
            c.fail("the test folder scan didn't finish")
            return
        }
        let root = result.root
        let node = { (relative: String) in root.descendant(atPath: f.root + "/" + relative) }

        c.equal(root.fileCount, f.countedFiles, "files counted (hard links once)")
        c.equal(root.folderCount, f.folders, "folders")
        c.equal(root.size, f.countedLogicalSize, "logical size of the counted files")
        c.equal(result.hardLinkDuplicates, f.extraHardLinks, "extra hard links")
        c.equal(root.uncountedLinksBelow, f.extraHardLinks, "extra hard links remembered in the tree")
        c.equal(result.unreadableFolders, 2, "unreadable folders")
        c.expect(node("locked")?.unreadable == true, "locked is marked unreadable")
        c.expect(node("a/b/locked2")?.unreadable == true, "a/b/locked2 is marked unreadable (found by fts)")
        c.equal(result.statErrors, 0, "stat errors")
        if let du = Du.kilobytes(f.root) {
            c.equal((root.allocated + 1023) / 1024, du, "space on disk matches du -skx (KiB)")
        } else {
            c.fail("couldn't run du")
        }

        if let x = node("x") {
            c.expect(x.children.isEmpty, "symbolic link to a folder is not followed")
            // x may hold the counted copy of two.bin (100 KB); it must not include big.dat (2 MB).
            c.expect(x.fileCount <= 3 && x.allocated < 1_000_000, "symbolic link to a file is not followed")
        } else {
            c.fail("folder x missing")
        }
        if let big = node("big") {
            c.expect(big.ownSize - big.ownAllocated > 60 * 1024 * 1024, "sparse file counts its real blocks, not its length")
        } else {
            c.fail("folder big missing")
        }
        c.equal(result.topFiles.first.map { ($0.path as NSString).lastPathComponent }, "big.dat", "largest file")

        c.equal(result.extensions["txt"]?.count, 2, ".txt files (one.txt or its link, and three.TXT)")
        c.equal(result.extensions["bin"]?.count, 1, ".bin files (three links to one file)")
        c.equal(result.extensions["dat"]?.count, 3, ".dat files")
        c.equal(result.extensions[""]?.count, 3, "files with no extension (.zshrc and two symbolic links)")
        c.equal(result.extensions["gz"]?.count, 1, ".gz files")
        c.equal(result.ageCounts[6], 1, "one file is 2–5 years old")
        c.equal(result.ageCounts.reduce(0, +), f.countedFiles, "every counted file has an age")

        c.section("Reading folders again (Details)")
        var stack = [root]
        var checkedFolders = 0
        while let folder = stack.popLast() {
            stack.append(contentsOf: folder.children)
            guard !folder.unreadable, !folder.otherVolume else { continue }
            guard let files = FolderReader.files(in: folder.path, uncounted: folder.uncountedLinks) else {
                c.fail("couldn't read \(folder.path)")
                continue
            }
            let counted = files.filter(\.counted)
            c.equal(counted.count, folder.ownFileCount, "counted files in \(folder.name)")
            c.equal(counted.reduce(0) { $0 + $1.facts.allocated }, folder.ownAllocated, "space of counted files in \(folder.name)")
            c.equal(files.count - counted.count, folder.uncountedLinks?.values.reduce(0, +) ?? 0, "uncounted links in \(folder.name)")
            checkedFolders += 1
        }
        c.equal(checkedFolders, f.folders - 2 + 1, "readable folders checked (all but the two locked ones, plus the root)")

        if let a = node("a") {
            let listing = DetailLoader.listFiles(in: a.path, folderTotal: a.allocated, uncounted: a.uncountedLinks)
            let links = listing.items.filter { $0.uncountedLink != nil }
            c.equal(listing.items.count, 2, "Details lists one.txt and one-again.txt")
            c.equal(links.count, 1, "one of them is shown as a hard link counted elsewhere")
            c.equal(links.first?.allocated, 0, "that link takes no space")
            c.equal(links.first?.kind, DetailLoader.uncountedLinkKind, "and says why")
            c.equal(listing.items.reduce(0) { $0 + $1.allocated }, a.ownAllocated, "Details rows add up to the folder's own files")
        }
        if let old = node("old") {
            let listing = DetailLoader.listFiles(in: old.path, folderTotal: old.allocated, uncounted: nil)
            for item in listing.items {
                let finder = try? URL(fileURLWithPath: item.id).resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
                c.equal(item.kind, finder, "kind of \(item.name) matches Finder")
            }
        }

        c.section("Reading a folder in one pass")
        // Every folder of the test tree (hard links, a sparse file, symbolic links, an executable):
        // the one-pass reader gives exactly what asking for each file by name gives.
        var compared = 0
        var folders = [root]
        while let folder = folders.popLast() {
            folders.append(contentsOf: folder.children)
            guard !folder.unreadable, !folder.otherVolume,
                  let fast = FolderReader.files(in: folder.path, uncounted: folder.uncountedLinks) else { continue }
            var slow: [FolderFile] = []
            _ = FolderReader.readFileByFile(folder.path) { slow += $0; return true }
            slow = FolderReader.labelLinks(slow, uncounted: folder.uncountedLinks)
            func describe(_ files: [FolderFile]) -> [String] {
                files.map { f in
                    let x = f.facts
                    return "\(f.name) \(x.size) \(x.allocated) \(x.modified) \(x.device) \(x.inode) \(x.links) \(String(x.mode, radix: 8)) \(x.flags)"
                }.sorted()
            }
            c.equal(describe(fast), describe(slow), "every file's details in \(folder.name)")
            c.equal(fast.filter(\.counted).count, slow.filter(\.counted).count, "counted files in \(folder.name)")
            compared += 1
        }
        c.expect(compared > 5, "compared \(compared) folders")

        // A big folder arrives in batches while it is read, and reading stops when asked to.
        let many = (f.root as NSString).appendingPathComponent("many")
        try? FileManager.default.createDirectory(atPath: many, withIntermediateDirectories: true)
        for i in 0..<6_000 {
            FileManager.default.createFile(atPath: (many as NSString).appendingPathComponent("file \(i).dat"), contents: Data([1]))
        }
        var batches = 0
        var rows = 0
        DetailLoader.streamFiles(in: many, folderTotal: 1, uncounted: nil) { delivered in
            batches += 1
            rows += delivered.count
            return true
        }
        c.equal(rows, 6_000, "all 6,000 files of a big folder are listed")
        c.expect(batches > 1, "they arrive in \(batches) batches, not all at the end")
        var firstOnly = 0
        DetailLoader.streamFiles(in: many, folderTotal: 1, uncounted: nil) { delivered in
            firstOnly += delivered.count
            return false
        }
        c.expect(firstOnly > 0 && firstOnly < 6_000, "reading stops when asked (\(firstOnly) files read)")
        try? FileManager.default.removeItem(atPath: many)

        searchFixtureTests(f, result, c)

        c.section("Moving to the Trash (File Types and Ages)")
        let all = FileTally.read(FileTally.folders(in: root, path: f.root), now: result.scanTime, progress: ScanProgress())
        c.equal(all.extensions, result.extensions, "reading every folder again gives the scan's File Types")
        c.equal(all.ageAllocated, result.ageAllocated, "and the scan's Ages")
        let stopped = ScanProgress()
        stopped.cancel()
        c.equal(FileTally.read(FileTally.folders(in: root, path: f.root), now: result.scanTime, progress: stopped).ageCounts.reduce(0, +),
                0, "a cancelled count reads nothing")

        guard let a = node("a"), let aParent = a.parent else {
            c.fail("folder a missing")
            return
        }
        let aPath = f.root + "/a"
        let before = (allocated: root.allocated, files: root.fileCount, folders: root.folderCount)
        let removed = (allocated: a.allocated, files: a.fileCount, folders: a.folderCount)
        let tallyA = FileTally.read(FileTally.folders(in: a, path: aPath), now: result.scanTime, progress: ScanProgress())
        let rest = FileTally.read(FileTally.folders(in: root, path: f.root).filter { !($0.path == aPath || $0.path.hasPrefix(aPath + "/")) },
                                  now: result.scanTime, progress: ScanProgress())
        aParent.removeChild(a)
        result.remove(tallyA)
        c.equal(root.allocated, before.allocated - removed.allocated, "tree total drops by the folder's space")
        c.equal(root.fileCount, before.files - removed.files, "tree file count drops")
        c.equal(root.folderCount, before.folders - removed.folders - 1, "tree folder count drops")
        c.equal(result.extensions, rest.extensions, "File Types now match the files that are left")
        c.equal(result.ageAllocated, rest.ageAllocated, "Ages now match the files that are left")
        c.equal(result.ageCounts, rest.ageCounts, "Age counts now match the files that are left")

        // What AppModel.trashFile does for one file.
        if let old = node("old"),
           let log = FolderReader.files(in: old.path, uncounted: nil)?.first(where: { $0.name == "old.log" }) {
            var tally = FileTally()
            tally.add(ext: NameTools.fileExtension(of: log.name), size: log.facts.size, allocated: log.facts.allocated,
                      modified: log.facts.modified, now: result.scanTime)
            result.remove(tally)
            c.equal(result.ageCounts[6], 0, "trashing old.log empties the 2–5 years band")
            c.equal(result.ageAllocated[6], 0, "and its space")
            c.expect(result.extensions["log"] == nil, "and removes .log from File Types")
        } else {
            c.fail("old/old.log missing")
        }
    }

    @MainActor
    static func searchFixtureTests(_ f: Fixture, _ result: ScanResult, _ c: Checks) {
        c.section("Search (the test folder)")
        let root = result.root
        let node = { (relative: String) in root.descendant(atPath: f.root + "/" + relative) }
        let built = SearchIndex.build(root: root, rootPath: f.root, rootName: "Fixture", topFiles: result.topFiles)
        let index = built.index
        c.equal(index.count, f.folders + 1, "the index has every folder and the root")
        c.equal(built.nodes.count, index.count, "and each folder's node")
        c.expect(built.nodes.indices.allSatisfy { index.path(of: Int32($0)) == built.nodes[$0].path },
                 "index paths match the tree")

        let bFolders = ScanSearch.folders(in: index, matching: SearchQuery("B"), bySize: false).sorted()
        c.equal(bFolders.map(\.name), ["big", "b"], "folders by name, largest first")
        c.equal(bFolders.map(\.path), [f.root + "/big", f.root + "/a/b"], "with their paths")
        c.equal(bFolders.last.map { index.location(of: $0) }, "a", "and where they are")
        c.equal(ScanSearch.folders(in: index, matching: SearchQuery("locked"), bySize: false).matched, 2,
                "unreadable folders are found by name too")
        c.equal(ScanSearch.folders(in: index, matching: SearchQuery("fixture"), bySize: false).matched, 0,
                "the scan's root is not a result")
        let top = ScanSearch.topFiles(in: index, matching: SearchQuery("BIG.dat"), bySize: false).sorted()
        c.equal(top.map(\.name), ["big.dat"], "Top Files are searched without reading folders")
        c.equal(top.first.map { index.location(of: $0) }, "big", "and know where they are")

        func files(_ text: String, limit: Int = ScanSearch.limit) -> FileSearch.Snapshot {
            let search = FileSearch(index: index, query: SearchQuery(text), bySize: false, limit: limit)
            search.run()
            return search.snapshot()
        }
        let deep = files("deep")
        c.expect(deep.finished, "reading folders finishes")
        c.equal(deep.foldersRead, deep.foldersTotal, "and reads every folder with files")
        c.equal(Set(deep.found.heap.map(\.name)), ["deep.dat", "deep-link.bin"], "files in deep folders")
        c.equal(deep.found.heap.first.map { index.location(of: $0) }, "a › … › e", "and where they are")
        c.equal(files("dat").found.sorted().map(\.name), ["big.dat", "top.dat", "deep.dat"], "files largest first")
        c.equal(files("THREE").found.heap.map(\.name), ["three.TXT"], "case doesn't matter for files")
        if let big = node("big"), let file = FolderReader.files(in: big.path, uncounted: nil)?.first(where: { $0.name == "big.dat" }) {
            c.equal(files("big.dat").found.heap.first?.allocated, file.facts.allocated, "a file's space on disk")
        } else {
            c.fail("big/big.dat missing")
        }
        let one = files("one")
        c.equal(Set(one.found.heap.map(\.name)), ["one.txt", "one-again.txt"], "both hard links in one folder")
        c.equal(one.found.heap.filter { !$0.counted }.count, 1, "one of them is counted elsewhere")
        c.equal(one.found.heap.reduce(0) { $0 + $1.allocated }, node("a")?.ownAllocated, "together they take what the folder's files take")
        let bins = files(".bin")
        c.equal(bins.found.matched, 3, "three links to one file in three folders")
        c.equal(bins.found.heap.filter(\.counted).count, 1, "counted once, as in the scan")
        c.equal(files("link-to").found.matched, 2, "symbolic links are files (and aren't followed)")
        c.equal(files("secret").found.matched, 0, "files in unreadable folders aren't found")
        let dots = files(".")
        c.equal(dots.found.matched, 13, "every readable file with a dot, without . and .. or folders")
        c.expect(dots.found.heap.allSatisfy { $0.kind == .file && $0.name != "." && $0.name != ".." }, "only files")
        let capped = files(".", limit: 2)
        c.expect(capped.found.heap.count == 2 && capped.found.matched == 13, "keeps only the largest, counts all")
        let stopped = FileSearch(index: index, query: SearchQuery("dat"), bySize: false)
        stopped.cancel()
        stopped.run()
        c.expect(!stopped.snapshot().finished && stopped.snapshot().found.matched == 0, "a cancelled search reads nothing")

        let bigFolders = ScanSearch.folders(in: index, matching: SearchQuery("big"), bySize: false)
        let bigTop = ScanSearch.topFiles(in: index, matching: SearchQuery("big"), bySize: false)
        let merged = ScanSearch.merge(folders: bigFolders, files: [files("big").found, bigTop], bySize: false)
        c.equal(merged.filter { $0.name == "big.dat" }.count, 1, "a Top File found again is listed once")
        c.equal(merged.first?.path, f.root + "/big", "the folder holding it comes first (it's at least as large)")
    }

    // MARK: - Real folders

    static func compareWithDu(path: String, _ c: Checks) {
        c.section("Comparing with du: \(path)")
        guard case .finished(let result) = ScanEngine.scan(path: path, displayName: path, topCount: 10, progress: ScanProgress()) else {
            c.fail("couldn't scan \(path)")
            return
        }
        guard result.unreadableFolders == 0 else {
            print("  skipped: \(result.unreadableFolders) folders couldn't be read, so du would differ")
            return
        }
        if let du = Du.kilobytes(path) {
            c.equal((result.root.allocated + 1023) / 1024, du, "space on disk of \(path) matches du -skx (KiB)")
        } else {
            c.fail("couldn't run du on \(path)")
        }
    }
}

// MARK: - Helpers

final class Checks {
    private(set) var passed = 0
    private(set) var failed = 0

    func section(_ title: String) { print("• \(title)") }
    func pass() { passed += 1 }

    func fail(_ message: String, line: UInt = #line) {
        failed += 1
        print("  FAIL (line \(line)): \(message)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        if condition { pass() } else { fail(message(), line: line) }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: UInt = #line) {
        expect(actual == expected, "\(what): got \(actual), expected \(expected)", line: line)
    }
}

/// Builds a scan tree in memory: each folder path (relative to the root) gets the given space in
/// its own files, and every folder on the way is created.
enum SuggestionTree {
    static func make(rootPath: String, folders: [(String, Int64)]) -> Node {
        let root = Node(name: (rootPath as NSString).lastPathComponent, parent: nil)
        root.rootPath = rootPath
        for (relative, allocated) in folders {
            var node = root
            for name in relative.split(separator: "/").map(String.init) {
                if let existing = node.children.first(where: { $0.name == name }) {
                    node = existing
                } else {
                    let child = Node(name: name, parent: node)
                    node.children.append(child)
                    node = child
                }
            }
            node.ownAllocated += allocated
            node.ownSize += allocated
            node.ownFileCount += allocated > 0 ? 1 : 0
        }
        finalize(root)
        return root
    }

    private static func finalize(_ node: Node) {
        for child in node.children { finalize(child) }
        node.finalize()
    }
}

enum Du {
    /// `du -skx`: space on disk in KiB, hard links once, one disk only.
    static func kilobytes(_ path: String) -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-skx", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap { Int64($0) }
    }
}

/// A folder tree with known contents, in a new temporary folder.
final class Fixture {
    let root: String
    let oldDate = Date(timeIntervalSinceNow: -3 * 365 * 86_400)

    /// Files the scan should count: every file and symbolic link, each hard-linked file once.
    private(set) var countedFiles = 0
    private(set) var countedLogicalSize: Int64 = 0
    private(set) var extraHardLinks = 0
    private(set) var folders = 0
    private var locked: [String] = []

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLensTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        root = String(cString: real)
        free(real)

        try file("top.dat", bytes: 300_000)
        try folder("a")
        try file("a/one.txt", bytes: 10_000)
        try hardLink("a/one-again.txt", to: "a/one.txt")             // same folder
        try folder("a/b")
        try file("a/b/two.bin", bytes: 100_000)
        try folder("a/b/c")
        try file("a/b/c/three.TXT", bytes: 5_000)
        try folder("a/b/c/d")
        try folder("a/b/c/d/e")
        try file("a/b/c/d/e/deep.dat", bytes: 20_000)
        try hardLink("a/b/c/d/e/deep-link.bin", to: "a/b/two.bin")   // deep, found by fts
        try folder("x")
        try hardLink("x/two-link.bin", to: "a/b/two.bin")           // another top-level folder
        try symbolicLink("x/link-to-a", to: "../a")
        try symbolicLink("x/link-to-big", to: "../big/big.dat")
        try folder("big")
        try file("big/big.dat", bytes: 2_000_000)
        try sparseFile("big/sparse.img", length: 64 * 1024 * 1024 + 1)
        try folder("old")
        try file("old/old.log", bytes: 4_000, modified: oldDate)
        try file("old/.zshrc", bytes: 100)
        try file("old/archive.tar.gz", bytes: 1_000)
        try folder("empty")
        try folder("locked")
        try lockedFile("locked/secret.txt")
        try folder("a/b/locked2")
        try lockedFile("a/b/locked2/hidden.txt")
        try lock("locked")
        try lock("a/b/locked2")
    }

    func remove() {
        for path in locked { chmod(path, 0o755) }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func full(_ relative: String) -> String { root + "/" + relative }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: full(relative), withIntermediateDirectories: false)
        folders += 1
    }

    private func file(_ relative: String, bytes: Int, modified: Date? = nil) throws {
        guard FileManager.default.createFile(atPath: full(relative), contents: Data(repeating: 0x61, count: bytes)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: full(relative))
        }
        countedFiles += 1
        countedLogicalSize += Int64(bytes)
    }

    /// A file inside a folder that is locked afterwards: the scan can't see it.
    private func lockedFile(_ relative: String) throws {
        guard FileManager.default.createFile(atPath: full(relative), contents: Data(count: 1_000)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func hardLink(_ relative: String, to target: String) throws {
        guard link(full(target), full(relative)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        extraHardLinks += 1
    }

    private func symbolicLink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: full(relative), withDestinationPath: destination)
        countedFiles += 1
        countedLogicalSize += Int64(destination.utf8.count)   // a symbolic link's size is its target's length
    }

    private func sparseFile(_ relative: String, length: Int64) throws {
        let fd = open(full(relative), O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var byte: UInt8 = 0x62
        guard ftruncate(fd, off_t(length)) == 0, pwrite(fd, &byte, 1, off_t(length - 1)) == 1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        countedFiles += 1
        countedLogicalSize += length
    }

    private func lock(_ relative: String) throws {
        guard chmod(full(relative), 0) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        locked.append(full(relative))
    }
}
