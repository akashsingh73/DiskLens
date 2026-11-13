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
        } catch {
            checks.fail("Couldn't build the test folder: \(error)")
        }
        for path in CommandLine.arguments.dropFirst() {
            compareWithDu(path: path, checks)
        }
        print(checks.failed == 0
              ? "All \(checks.passed) checks passed."
              : "\(checks.failed) of \(checks.passed + checks.failed) checks FAILED.")
        exit(checks.failed == 0 ? 0 : 1)
    }

    // MARK: - Small pieces

    @MainActor
    static func unitTests(_ c: Checks) {
        c.section("File extensions")
        let extensions: [(String, String)] = [
            ("photo.JPG", "jpg"), ("archive.tar.gz", "gz"), (".zshrc", ""), ("README", ""),
            ("trailing.", ""), ("ab", ""), ("x.y", "y"), ("name.averyveryverylongext", ""),
        ]
        for (name, expected) in extensions {
            c.equal(NameTools.fileExtension(of: name), expected, "extension of \(name)")
        }

        c.section("Counts with nouns")
        c.equal(SizeFormat.count(1, "extra hard link"), "1 extra hard link", "one")
        c.equal(SizeFormat.count(2, "extra hard link"), "2 extra hard links", "two")
        c.equal(SizeFormat.count(0, "folder"), "0 folders", "zero")

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
