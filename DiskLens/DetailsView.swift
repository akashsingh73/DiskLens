import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import os

/// One row of the Details list: a folder from the scan or a file read from disk.
struct DetailItem: Identifiable, Hashable, Sendable {
    let id: String              // absolute path
    let name: String
    let isFolder: Bool
    let size: Int64
    let allocated: Int64
    let files: Int
    let folders: Int
    let modified: Date
    let kind: String
    let percent: Double         // share of the folder's space on disk
    let unreadable: Bool
    /// Set for a hard link whose space the scan counted through another link to the same file.
    /// Its On Disk is 0, because moving it to the Trash frees nothing.
    var uncountedLink: FileKey? = nil

    static func == (lhs: DetailItem, rhs: DetailItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Reads the files of one folder off the main thread.
enum DetailLoader {
    /// Folders with more files than this list only the largest ones, so the list stays fast.
    static let fileLimit = 50_000
    static let uncountedLinkKind = "Hard link (counted elsewhere)"

    struct Listing: Sendable {
        var items: [DetailItem] = []
        var total = 0
    }

    /// Lists a folder's files with the scanner's rules (space on disk from `st_blocks`, hard links
    /// counted once), so the rows add up to the folder's totals in the tree.
    /// `uncounted` is the folder's `Node.uncountedLinks`.
    static func listFiles(in path: String, folderTotal: Int64, uncounted: [FileKey: Int]?) -> Listing {
        guard let files = FolderReader.files(in: path, uncounted: uncounted) else {
            let reason = String(cString: strerror(errno))
            Log.files.error("Couldn't list \(path, privacy: .public): \(reason, privacy: .public)")
            return Listing()
        }
        var items: [DetailItem] = []
        items.reserveCapacity(min(files.count, fileLimit))
        for file in files {
            let filePath = (path as NSString).appendingPathComponent(file.name)
            let allocated = file.counted ? file.facts.allocated : 0
            items.append(DetailItem(
                id: filePath, name: file.name, isFolder: false,
                size: file.facts.size, allocated: allocated, files: 1, folders: 0,
                modified: Date(timeIntervalSince1970: TimeInterval(file.facts.modified)),
                kind: file.counted ? KindNames.kind(of: file, at: filePath) : uncountedLinkKind,
                percent: folderTotal > 0 ? Double(allocated) / Double(folderTotal) : 0,
                unreadable: false,
                uncountedLink: file.counted ? nil : file.facts.key))
        }
        let total = items.count
        if items.count > fileLimit {
            items.sort { $0.allocated > $1.allocated }
            items.removeSubrange(fileLimit...)
        }
        return Listing(items: items, total: total)
    }
}

/// Finder's kind names ("PDF document"), looked up once per extension instead of once per file.
/// Safe to use from any thread.
enum KindNames {
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    static func kind(of file: FolderFile, at path: String) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let key: String
        if file.facts.isSymbolicLink {
            key = "link"
        } else if !ext.isEmpty {
            key = "ext:" + ext
        } else {
            key = file.facts.isExecutable ? "executable" : "plain"
        }
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let url = URL(fileURLWithPath: path)
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "Document"
        cache.withLock { $0[key] = kind }
        return kind
    }
}

/// Icons for list rows, cached because Finder icons are slow to look up.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: DetailItem) -> NSImage {
        icon(name: item.name, path: item.id, isFolder: item.isFolder)
    }

    static func icon(name: String, path: String, isFolder: Bool) -> NSImage {
        let key: String
        if name.hasSuffix(".app") {
            key = path
        } else if isFolder {
            key = "/folder"
        } else {
            key = "ext:" + (name as NSString).pathExtension.lowercased()
        }
        if let cached = cache[key] { return cached }
        let image: NSImage
        if name.hasSuffix(".app") {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if isFolder {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let ext = (name as NSString).pathExtension
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        cache[key] = image
        return image
    }
}

/// TreeSize-style Details list for the selected folder. Double-click a folder to open it.
struct DetailsView: View {
    @ObservedObject var model: AppModel
    let node: Node
    let settings: DisplaySettings

    @StateObject private var state = DetailsState()

    private struct LoadKey: Equatable {
        let node: ObjectIdentifier
        let version: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            table
            if state.hiddenFiles > 0 {
                Divider()
                Text("Showing the \(SizeFormat.count(DetailLoader.fileLimit)) largest of \(SizeFormat.count(state.totalFiles)) files in this folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
        }
        .task(id: LoadKey(node: node.id, version: model.version)) {
            await reload()
        }
    }

    private var table: some View {
        Table(state.rows, selection: $state.selection, sortOrder: $state.sortOrder,
              columnCustomization: $state.columns) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.unreadable ? Color.secondary : Color.primary)
                }
            }
            .width(min: 160, ideal: 250)
            .customizationID("name")

            TableColumn("On Disk", value: \.allocated) { item in
                Text(settings.bytes(item.allocated)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            .customizationID("allocated")

            TableColumn("% of Parent", value: \.percent) { item in
                PercentBar(fraction: item.percent, settings: settings)
            }
            .width(min: 100, ideal: 140)
            .customizationID("percent")

            TableColumn("Size", value: \.size) { item in
                Text(settings.bytes(item.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            .customizationID("size")

            TableColumn("Files", value: \.files) { item in
                Text(item.isFolder ? SizeFormat.count(item.files) : "").monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .customizationID("files")

            TableColumn("Folders", value: \.folders) { item in
                Text(item.isFolder ? SizeFormat.count(item.folders) : "").monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            .customizationID("folders")

            TableColumn("Modified", value: \.modified) { item in
                if item.modified > Date(timeIntervalSince1970: 0) {
                    Text(item.modified, format: .dateTime.year().month(.abbreviated).day())
                }
            }
            .width(min: 80, ideal: 110)
            .customizationID("modified")

            TableColumn("Kind", value: \.kind)
                .width(min: 80, ideal: 140)
                .customizationID("kind")
        }
        .contextMenu(forSelectionType: DetailItem.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            openItems(ids)
        }
        .quickLookPreview($state.previewURL)
        .onKeyPress(.space) {
            guard let id = state.selection.first else { return .ignored }
            state.previewURL = URL(fileURLWithPath: id)
            return .handled
        }
        .overlay {
            if state.loading && state.rows.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<DetailItem.ID>) -> some View {
        if let id = ids.first, let item = state.rows.first(where: { $0.id == id }) {
            if item.isFolder, let folder = state.folderLookup[item.id] {
                Button("Show Contents") { model.navigate(to: folder) }
                Divider()
            }
            Button("Reveal in Finder") { FileActions.reveal(item.id) }
            Button("Open") { FileActions.open(item.id) }
            Button("Quick Look") { state.previewURL = URL(fileURLWithPath: item.id) }
            Button("Copy Path") { FileActions.copyPath(item.id) }
            Divider()
            Button("Move to Trash…", role: .destructive) { trash(item) }
        }
    }

    /// Double-click or Return: folders open inside DiskLens, files open in their app.
    private func openItems(_ ids: Set<DetailItem.ID>) {
        guard let id = ids.first, let item = state.rows.first(where: { $0.id == id }) else { return }
        if item.isFolder {
            if let folder = state.folderLookup[item.id] { model.navigate(to: folder) }
        } else {
            FileActions.open(item.id)
        }
    }

    /// The direct child of `folder` that contains `node` (or is `node`), if there is one.
    private static func child(of folder: Node, leadingTo node: Node?) -> Node? {
        var current = node
        while let candidate = current {
            if candidate.parent === folder { return candidate }
            current = candidate.parent
        }
        return nil
    }

    private func trash(_ item: DetailItem) {
        if item.isFolder {
            if let folder = state.folderLookup[item.id] { model.trash(node: folder) }
        } else {
            model.trashFile(path: item.id, size: item.size, allocated: item.allocated,
                            modified: Int64(item.modified.timeIntervalSince1970),
                            uncountedLink: item.uncountedLink)
        }
    }

    private func reload() async {
        let directory = node.directory
        let path = directory.path
        let total = directory.allocated
        let uncounted = directory.uncountedLinks
        var folderRows: [DetailItem] = []
        var lookup: [String: Node] = [:]
        if node.kind == .directory {
            folderRows.reserveCapacity(directory.children.count)
            for child in directory.children {
                let childPath = (path as NSString).appendingPathComponent(child.name)
                lookup[childPath] = child
                let kind = child.otherVolume ? "Other disk" : (child.unreadable ? "No access" : "Folder")
                folderRows.append(DetailItem(
                    id: childPath, name: child.name, isFolder: true,
                    size: child.size, allocated: child.allocated,
                    files: child.fileCount, folders: child.folderCount,
                    modified: Date(timeIntervalSince1970: TimeInterval(child.newest)),
                    kind: kind,
                    percent: total > 0 ? Double(child.allocated) / Double(total) : 0,
                    unreadable: child.unreadable))
            }
        }
        state.folderLookup = lookup
        state.show(folderRows)
        state.totalFiles = 0
        state.hiddenFiles = 0
        // Coming back up from a subfolder: highlight the folder you came out of.
        if let child = Self.child(of: directory, leadingTo: model.cameFrom), child.kind == .directory {
            state.selection = [(path as NSString).appendingPathComponent(child.name)]
        } else {
            state.selection = []
        }
        guard directory.ownFileCount > 0, !directory.unreadable else {
            state.loading = false
            return
        }
        state.loading = true
        // A short pause, so clicking quickly through folders doesn't read every one of them from disk.
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled { return }
        let listing = await Task.detached(priority: .userInitiated) {
            DetailLoader.listFiles(in: path, folderTotal: total, uncounted: uncounted)
        }.value
        if Task.isCancelled { return }
        state.show(folderRows + listing.items)
        state.totalFiles = listing.total
        state.hiddenFiles = max(0, listing.total - listing.items.count)
        state.loading = false
    }
}

/// A percentage with a small bar, for the "% of Parent" column.
struct PercentBar: View {
    let fraction: Double
    let settings: DisplaySettings

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                FractionBar(fraction: fraction)
                    .fill(LinearGradient(colors: [Color(nsColor: settings.barStart), Color(nsColor: settings.barEnd)],
                                         startPoint: .leading, endPoint: .trailing))
                    .clipShape(Capsule())
            }
            .frame(height: 6)
            Text(SizeFormat.percent(fraction, decimals: 1))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

/// A bar filling `fraction` of its width from the left. Drawn from the space it is given, so it
/// needs no GeometryReader (and can never feed a size back into layout).
struct FractionBar: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(1, max(0, fraction))
        let width = rect.width * CGFloat(clamped)
        guard width > 0 else { return Path() }
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                    cornerRadius: min(2, width / 2))
    }
}

/// View state for DetailsView, kept in a class so it builds without SwiftUI's macros.
final class DetailsState: ObservableObject {
    /// The rows in display order.
    @Published private(set) var rows: [DetailItem] = []
    @Published var folderLookup: [String: Node] = [:]
    @Published var selection = Set<DetailItem.ID>()
    @Published var sortOrder = [KeyPathComparator(\DetailItem.allocated, order: .reverse)] {
        didSet { rows = items.sorted(using: sortOrder) }
    }
    @Published var columns = TableColumnCustomization<DetailItem>()
    @Published var previewURL: URL?
    @Published var loading = false
    @Published var totalFiles = 0
    @Published var hiddenFiles = 0
    private var items: [DetailItem] = []

    /// Sorted once here rather than on every redraw: a folder can hold tens of thousands of files.
    func show(_ newItems: [DetailItem]) {
        items = newItems
        rows = newItems.sorted(using: sortOrder)
    }
}
