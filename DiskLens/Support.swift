import AppKit
import Darwin
import UniformTypeIdentifiers
import os

// MARK: - Logging

/// Diagnostics go to the system log. To read them: open Console, start streaming,
/// and search for "local.disklens.app".
enum Log {
    static let app = Logger(subsystem: "local.disklens.app", category: "app")
    static let scan = Logger(subsystem: "local.disklens.app", category: "scan")
    static let files = Logger(subsystem: "local.disklens.app", category: "files")
}

// MARK: - File type groups

enum FileGroup: String, CaseIterable, Identifiable {
    case images = "Images"
    case video = "Video"
    case audio = "Audio"
    case documents = "Documents"
    case archives = "Archives & Disk Images"
    case code = "Code & Data"
    case apps = "Apps & Libraries"
    case other = "Other"

    var id: String { rawValue }

    @MainActor private static var cache: [String: FileGroup] = [:]

    /// Groups an extension using the system's type registry (UTType).
    @MainActor
    static func group(forExtension ext: String) -> FileGroup {
        if let cached = cache[ext] { return cached }
        let group = classify(ext)
        cache[ext] = group
        return group
    }

    private static func classify(_ ext: String) -> FileGroup {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .database) || type.conforms(to: .propertyList) {
            return .code
        }
        if type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .framework) {
            return .apps
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation) || type.conforms(to: .compositeContent) {
            return .documents
        }
        return .other
    }
}

// MARK: - Paths as Finder shows them

enum PathDisplay {
    private static let dataVolume = "/System/Volumes/Data"

    /// "/System/Volumes/Data/Users/me" becomes "/Users/me" when both name the same folder
    /// (the startup disk's firmlinks), so paths look the way they do in Finder.
    static func friendly(_ path: String) -> String {
        guard path.hasPrefix(dataVolume + "/") else { return path }
        let candidate = String(path.dropFirst(dataVolume.count))
        var original = stat()
        var shortened = stat()
        guard lstat(path, &original) == 0, lstat(candidate, &shortened) == 0,
              original.st_dev == shortened.st_dev, original.st_ino == shortened.st_ino else { return path }
        return candidate
    }
}

// MARK: - Finder actions

@MainActor
enum FileActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PathDisplay.friendly(path))])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: PathDisplay.friendly(path)))
    }

    static func copyPath(_ path: String) {
        copyText(PathDisplay.friendly(path))
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Folders DiskLens refuses to trash: the home folder and everything that contains it,
    /// ~/Library, the top level of any disk, and the system.
    static func isProtected(_ path: String) -> Bool {
        let friendly = PathDisplay.friendly(path)
        let home = NSHomeDirectory()
        if friendly == home || home.hasPrefix(friendly + "/") { return true }
        if friendly == home + "/Library" { return true }
        if friendly == "/System" || friendly.hasPrefix("/System/") { return true }
        let components = (friendly as NSString).pathComponents
        if components.count <= 2 { return true }                                   // "/", "/Applications", "/Library"
        if components.count == 3 && components[1] == "Volumes" { return true }    // another disk itself
        return false
    }

    /// Asks before moving an item to the Trash. Protected folders are refused with an explanation.
    /// `extraHardLink` is for a hard link whose space is counted with another link to the same file.
    static func confirmTrash(path: String, sizeText: String, extraHardLink: Bool = false) -> Bool {
        let name = (path as NSString).lastPathComponent
        if isProtected(path) {
            let refusal = NSAlert()
            refusal.messageText = "DiskLens won't move “\(name)” to the Trash."
            refusal.informativeText = "It's a system folder, your home folder, or a folder that contains it. Delete things inside it instead."
            refusal.alertStyle = .informational
            refusal.runModal()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"
        alert.informativeText = extraHardLink
            ? "It's a hard link: the same file is also in another place, so this frees no space. You can put it back from the Trash until you empty it."
            : "It takes \(sizeText). You can put it back from the Trash until you empty it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Moves an item to the Trash (never deletes outright). Shows an alert if that fails.
    static func moveToTrash(path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return true
        } catch {
            Log.files.error("Couldn't move to Trash: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert(error: error)
            failure.runModal()
            return false
        }
    }
}

// MARK: - Full Disk Access

enum FullDiskAccess {
    /// macOS only lets apps with Full Disk Access read the privacy database.
    static var isGranted: Bool {
        let paths = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in paths {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return true   // could not tell; don't nag
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Scan history

struct HistoryEntry: Codable, Identifiable, Hashable {
    let path: String
    let date: Date
    let size: Int64
    let allocated: Int64
    let files: Int
    var id: Date { date }
}

enum HistoryStore {
    private static let limit = 5000

    /// Where DiskLens keeps its scan history (and the folder snapshots, see `SnapshotStore`).
    static var folderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskLens", isDirectory: true)
    }

    private static var fileURL: URL { folderURL.appendingPathComponent("history.json") }

    static func load() -> [HistoryEntry] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            // Keep the damaged file for inspection and start a fresh history.
            Log.app.error("Scan history unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            let backup = folderURL.appendingPathComponent("history-damaged.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    static func entries(for path: String) -> [HistoryEntry] {
        load().filter { $0.path == path }.sorted { $0.date < $1.date }
    }

    /// Replaces the entry of the same scan (same folder and time), e.g. once cloud folders were read.
    static func update(_ entry: HistoryEntry) {
        var all = load()
        guard let index = all.lastIndex(where: { $0.path == entry.path && $0.date == entry.date }) else {
            append(entry)
            return
        }
        all[index] = entry
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't save scan history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The latest scan of each folder, newest first.
    static func recent(limit: Int = 8) -> [HistoryEntry] {
        var latest: [String: HistoryEntry] = [:]
        for entry in load() where latest[entry.path].map({ entry.date > $0.date }) ?? true {
            latest[entry.path] = entry
        }
        return Array(latest.values.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func append(_ entry: HistoryEntry) {
        var all = load()
        all.append(entry)
        if all.count > limit { all.removeFirst(all.count - limit) }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't save scan history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
