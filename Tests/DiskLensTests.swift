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
