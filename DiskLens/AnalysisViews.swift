import SwiftUI
import Charts
import QuickLook

// MARK: - File types

/// Space by file extension and by type group, for the whole scan.
struct FileTypesView: View {
    let result: ScanResult
    /// `AppModel.version`: changes when something is moved to the Trash.
    let version: Int
    let settings: DisplaySettings

    private struct ComputeKey: Equatable {
        let result: ObjectIdentifier
        let version: Int
    }

    struct ExtensionRow: Identifiable {
        let ext: String
        let group: FileGroup
        let size: Int64
        let allocated: Int64
        let count: Int
        let share: Double
        var id: String { ext }
        var displayName: String { ext.isEmpty ? "(no extension)" : "." + ext }
        var groupName: String { group.rawValue }
    }

    struct GroupRow: Identifiable {
        let group: FileGroup
        let allocated: Int64
        let count: Int
        var id: String { group.rawValue }
    }

    @StateObject private var state = FileTypesState()

    private var visibleRows: [ExtensionRow] {
        let filtered = state.groupFilter.map { group in state.rows.filter { $0.group == group } } ?? state.rows
        return FastSort.sorted(filtered, using: state.sortOrder)
    }

    var body: some View {
        let total = state.groups.reduce(Int64(0)) { $0 + $1.allocated }
        let shown = state.groupFilter.flatMap { filter in state.groups.first { $0.group == filter } }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 28) {
                ZStack {
                    Chart(state.groups) { row in
                        SectorMark(angle: .value("On disk", Double(row.allocated)),
                                   innerRadius: .ratio(0.64), angularInset: 1.5)
                            .cornerRadius(4)
                            .foregroundStyle(row.group.color)
                            .opacity(state.groupFilter == nil || state.groupFilter == row.group ? 1 : 0.25)
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 1) {
                        Text(settings.bytes(shown?.allocated ?? total))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        Text(shown?.group.rawValue ?? "All files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 110)
                }
                .frame(width: 190, height: 190)

                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "By type", systemImage: "square.stack.3d.up", detail: "whole scan")
                        .padding(.bottom, 6)
                    ForEach(state.groups) { row in
                        groupRow(row, total: total)
                    }
                    if state.groupFilter != nil {
                        Button("Show all types") { state.groupFilter = nil }
                            .buttonStyle(.link)
                            .font(.caption)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 360)
            }

            Table(visibleRows, sortOrder: $state.sortOrder) {
                TableColumn("Extension", value: \.displayName) { row in
                    Text(row.displayName).fontWeight(.medium)
                }
                .width(min: 90, ideal: 120)
                TableColumn("Type", value: \.groupName) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.group.symbol)
                            .foregroundStyle(row.group.color)
                            .frame(width: 16)
                        Text(row.groupName).lineLimit(1)
                    }
                }
                .width(min: 110, ideal: 170)
                TableColumn("On Disk", value: \.allocated) { row in
                    Text(settings.bytes(row.allocated)).monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Share", value: \.share) { row in
                    PercentBar(fraction: row.share, settings: settings)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Size", value: \.size) { row in
                    Text(settings.bytes(row.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Files", value: \.count) { row in
                    Text(SizeFormat.count(row.count)).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
            }
        }
        .padding()
        .task(id: ComputeKey(result: ObjectIdentifier(result), version: version)) { compute() }
    }

    private func groupRow(_ row: GroupRow, total: Int64) -> some View {
        let selected = state.groupFilter == row.group
        return Button {
            state.groupFilter = selected ? nil : row.group
        } label: {
            HStack(spacing: 8) {
                IconBadge(systemImage: row.group.symbol, tint: row.group.color, size: 22)
                Text(row.group.rawValue)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(settings.bytes(row.allocated))
                    .monospacedDigit()
                Text(SizeFormat.percent(total > 0 ? Double(row.allocated) / Double(total) : 0, decimals: 0))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? row.group.color.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Show all types" : "Show only \(row.group.rawValue)")
    }

    private func compute() {
        let total = max(1, result.root.allocated)
        var groupTotals: [FileGroup: (Int64, Int)] = [:]
        var newRows: [ExtensionRow] = []
        newRows.reserveCapacity(result.extensions.count)
        for (ext, totals) in result.extensions {
            let group = FileGroup.group(forExtension: ext)
            newRows.append(ExtensionRow(ext: ext, group: group, size: totals.size, allocated: totals.allocated,
                                        count: totals.count, share: Double(totals.allocated) / Double(total)))
            let current = groupTotals[group] ?? (0, 0)
            groupTotals[group] = (current.0 + totals.allocated, current.1 + totals.count)
        }
        state.rows = newRows
        state.groups = groupTotals
            .map { GroupRow(group: $0.key, allocated: $0.value.0, count: $0.value.1) }
            .sorted { $0.allocated > $1.allocated }
        if let filter = state.groupFilter, groupTotals[filter] == nil { state.groupFilter = nil }
    }
}

// MARK: - Top files

/// The largest files in the whole scan.
struct TopFilesView: View {
    @ObservedObject var model: AppModel
    let result: ScanResult
    let settings: DisplaySettings

    @StateObject private var state = TopFilesState()

    var body: some View {
        let total = max(1, result.root.allocated)
        Table(FastSort.sorted(result.topFiles, using: state.sortOrder), selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(name: file.name, path: file.path, isFolder: false))
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(location(of: file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
                .help(PathDisplay.friendly(file.path))
            }
            .width(min: 200, ideal: 300)
            TableColumn("On Disk", value: \.allocated) { file in
                Text(settings.bytes(file.allocated)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Share of Scan", value: \.allocated) { file in
                PercentBar(fraction: Double(file.allocated) / Double(total), settings: settings)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Size", value: \.size) { file in
                Text(settings.bytes(file.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Modified", value: \.modified) { file in
                Text(file.modifiedDate, format: .dateTime.year().month(.abbreviated).day())
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: TopFile.ID.self) { ids in
            if let path = ids.first, let file = result.topFiles.first(where: { $0.path == path }) {
                Button("Reveal in Finder") { FileActions.reveal(file.path) }
                Button("Open") { FileActions.open(file.path) }
                Button("Quick Look") { state.previewURL = URL(fileURLWithPath: file.path) }
                Button("Copy Path") { FileActions.copyPath(file.path) }
                Button("Show Folder in DiskLens") {
                    if let folder = result.root.descendant(atPath: file.folder) { model.navigate(to: folder) }
                }
                Divider()
                Button("Move to Trash…", role: .destructive) {
                    model.trashFile(path: file.path, size: file.size, allocated: file.allocated,
                                    modified: file.modified)
                }
            }
        } primaryAction: { ids in
            if let path = ids.first { FileActions.reveal(path) }
        }
        .quickLookPreview($state.previewURL)
    }

    /// Where a file sits inside the scan, short enough for one line:
    /// "Google Chrome.app › … › Versions" (first and last folders, with the middle left out).
    private func location(of file: TopFile) -> String {
        let root = result.rootPath.hasSuffix("/") ? result.rootPath : result.rootPath + "/"
        guard file.folder.hasPrefix(root) else {
            return file.folder == result.rootPath ? result.displayName : PathDisplay.friendly(file.folder)
        }
        let parts = file.folder.dropFirst(root.count).split(separator: "/").map(String.init)
        switch parts.count {
        case 0: return result.displayName
        case 1...2: return parts.joined(separator: " › ")
        default: return "\(parts[0]) › … › \(parts[parts.count - 1])"
        }
    }
}

// MARK: - Ages

/// How much data was last modified in each age band (whole scan).
struct AgesView: View {
    let result: ScanResult
    /// `AppModel.version`: changes when something is moved to the Trash, so the bars redraw.
    let version: Int
    let settings: DisplaySettings

    struct Band: Identifiable {
        let id: Int
        let label: String
        let allocated: Int64
        let count: Int
    }

    /// The first band that is a year or more old ("1–2 years").
    private static let firstYearBand = AgeBands.labels.firstIndex(of: "1–2 years") ?? 5

    private var bands: [Band] {
        AgeBands.labels.enumerated().map { index, label in
            Band(id: index, label: label, allocated: result.ageAllocated[index], count: result.ageCounts[index])
        }
    }

    var body: some View {
        let data = bands
        let total = max(1, data.reduce(0) { $0 + $1.allocated })
        let largest = max(1, data.map(\.allocated).max() ?? 1)
        let stale = data.filter { $0.id >= Self.firstYearBand }.reduce(0) { $0 + $1.allocated }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Last modified", systemImage: "clock", detail: "whole scan")

                if stale > 0 {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "hourglass", tint: .orange, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(settings.bytes(stale)) hasn't changed in over a year")
                                .font(.headline)
                            Text("That's \(SizeFormat.percent(Double(stale) / Double(total), decimals: 0)) of this scan. Old files are often safe to archive or clean up.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .card(tint: .orange)
                }

                VStack(spacing: 12) {
                    ForEach(data) { band in
                        HStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.ageColor(band.id, of: data.count))
                                    .frame(width: 8, height: 8)
                                Text(band.label)
                                    .lineLimit(1)
                            }
                            .frame(width: 104, alignment: .leading)
                            ShareBar(fraction: Double(band.allocated) / Double(largest),
                                     color: Theme.ageColor(band.id, of: data.count), height: 12)
                            Text(settings.bytes(band.allocated))
                                .monospacedDigit()
                                .frame(width: 76, alignment: .trailing)
                            Text(SizeFormat.percent(Double(band.allocated) / Double(total)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            Text(SizeFormat.count(band.count, "file"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 96, alignment: .trailing)
                        }
                    }
                }
                .card(padding: 16)
            }
            .padding()
        }
    }
}

// MARK: - History

/// Space used by the scanned folder across past scans, and which folders changed since an earlier scan.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    let settings: DisplaySettings

    @StateObject private var state = HistoryState()

    struct Row: Identifiable {
        let entry: HistoryEntry
        let change: Int64?
        var id: Date { entry.date }
    }

    var body: some View {
        let entries = model.history
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Space over time", systemImage: "chart.line.uptrend.xyaxis",
                         detail: SizeFormat.count(entries.count, "scan"))
            if entries.count < 2 {
                ContentUnavailableView("Not enough history yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Every scan of this folder adds a point. Scan it again later to see the trend."))
                    .frame(maxHeight: 140)
            } else {
                chart(entries)
                    .frame(minHeight: 110, idealHeight: 170, maxHeight: 200)
                    .card(padding: 16)
            }

            HStack(spacing: 10) {
                Picker("Show", selection: $state.shown) {
                    Text("Changes").tag(HistoryState.Shown.changes)
                    Text("Scans").tag(HistoryState.Shown.scans)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if state.shown == .changes, let bases = model.comparisonBases, bases.count > 1 {
                    let labels = Self.labels(for: bases.map(\.date))
                    Picker("Compare with", selection: $model.comparisonIndex) {
                        ForEach(bases.indices, id: \.self) { index in
                            Text(labels[index]).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Which earlier scan to compare this one with")
                }
            }

            switch state.shown {
            case .changes:
                ChangesList(model: model, settings: settings)
            case .scans:
                scans(entries)
            }
        }
        .padding()
    }

    /// Dates of earlier scans for the "Compare with" menu, with seconds when two fall in the same minute.
    static func labels(for dates: [Date]) -> [String] {
        let minutes = dates.map { $0.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()) }
        guard Set(minutes).count < minutes.count else { return minutes }
        return dates.map { $0.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second()) }
    }

    private func chart(_ entries: [HistoryEntry]) -> some View {
        Chart(entries) { entry in
            AreaMark(x: .value("Date", entry.date), y: .value("On disk", Double(entry.allocated)))
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Date", entry.date), y: .value("On disk", Double(entry.allocated)))
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Date", entry.date), y: .value("On disk", Double(entry.allocated)))
                .foregroundStyle(Color.accentColor)
                .symbolSize(30)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(settings.bytes(Int64(amount))) }
                }
            }
        }
    }

    private func scans(_ entries: [HistoryEntry]) -> some View {
        let rows: [Row] = entries.enumerated().map { index, entry in
            Row(entry: entry, change: index > 0 ? entry.allocated - entries[index - 1].allocated : nil)
        }.reversed()
        return Table(rows) {
            TableColumn("Scanned") { row in
                Text(row.entry.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
            }
            TableColumn("On Disk") { row in
                Text(settings.bytes(row.entry.allocated)).monospacedDigit()
            }
            TableColumn("Change") { row in
                if let change = row.change {
                    ChangeLabel(change: change, settings: settings)
                }
            }
            TableColumn("Files") { row in
                Text(SizeFormat.count(row.entry.files)).monospacedDigit()
            }
        }
    }
}

/// "Changes since …": the folders that grew, shrank, appeared, disappeared or were renamed since an
/// earlier scan of the same folder, biggest change first.
struct ChangesList: View {
    @ObservedObject var model: AppModel
    let settings: DisplaySettings

    @StateObject private var state = ChangesState()
    @AppStorage("detailTab") private var tab: DetailTab = .details

    var body: some View {
        if let comparison = model.changes, let scan = model.result {
            VStack(alignment: .leading, spacing: 10) {
                header(comparison, scan: scan)
                if comparison.changes.isEmpty {
                    ContentUnavailableView("No folder changed", systemImage: "checkmark.circle",
                                           description: Text("The folders DiskLens keeps track of are the same size as on \(Theme.shortDate(comparison.base.date))."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table(comparison, scan: scan)
                }
            }
        } else if model.comparisonBases == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Nothing to compare with yet", systemImage: "arrow.up.arrow.down",
                                   description: Text("After every scan, DiskLens remembers how big this folder's largest subfolders are. Scan it again later to see which ones grew or shrank."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ comparison: FolderComparison, scan: ScanResult) -> some View {
        let base = comparison.base
        let source = base.partOf.map { "from a scan of " + FileManager.default.displayName(atPath: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Changes since " + base.date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()),
                         systemImage: "arrow.up.arrow.down", detail: source)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    totalChip(comparison)
                    countChips(comparison, all: true)
                }
                HStack(spacing: 6) {
                    totalChip(comparison)
                    countChips(comparison, all: false)
                }
                totalChip(comparison)
            }
        }
    }

    private func totalChip(_ comparison: FolderComparison) -> some View {
        Chip(text: settings.signedBytes(comparison.totalChange) + " in all",
             systemImage: Theme.changeSymbol(comparison.totalChange), tint: Theme.changeColor(comparison.totalChange))
            .help("\(model.result?.displayName ?? "This folder") was \(settings.bytes(comparison.base.allocated)) then")
    }

    @ViewBuilder
    private func countChips(_ comparison: FolderComparison, all: Bool) -> some View {
        if comparison.grew > 0 {
            Chip(text: "\(SizeFormat.count(comparison.grew)) grew", systemImage: "arrow.up.right", tint: .orange)
        }
        if comparison.shrank > 0 {
            Chip(text: "\(SizeFormat.count(comparison.shrank)) shrank", systemImage: "arrow.down.right", tint: .green)
        }
        if all {
            if comparison.added > 0 {
                Chip(text: "\(SizeFormat.count(comparison.added)) new", systemImage: "plus")
            }
            if comparison.removed > 0 {
                Chip(text: "\(SizeFormat.count(comparison.removed)) removed", systemImage: "minus")
            }
            if comparison.renamed > 0 {
                Chip(text: "\(SizeFormat.count(comparison.renamed)) renamed", systemImage: "pencil")
            }
        }
    }

    private func table(_ comparison: FolderComparison, scan: ScanResult) -> some View {
        Table(FastSort.sorted(comparison.changes, using: state.sortOrder), selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Folder", value: \.name) { change in
                HStack(spacing: 8) {
                    icon(for: change, scan: scan)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(change.kind == .removed ? Color.secondary : Color.primary)
                        Text(detail(for: change, scan: scan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
                .help(PathDisplay.friendly(FolderSnapshot.absolutePath(of: change.path, inside: scan.rootPath)))
            }
            .width(min: 160, ideal: 220)
            TableColumn("Before", value: \.before) { change in
                Text(change.kind == .added ? "—" : settings.bytes(change.before))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80)
            TableColumn("Now", value: \.after) { change in
                Text(change.kind == .removed ? "—" : settings.bytes(change.after))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("Change", value: \.amount) { change in
                ChangeLabel(change: change.change, settings: settings)
            }
            .width(min: 90, ideal: 100)
        }
        .contextMenu(forSelectionType: FolderChange.ID.self) { ids in
            if let change = comparison.changes.first(where: { ids.contains($0.id) }) {
                let path = FolderSnapshot.absolutePath(of: change.path, inside: scan.rootPath)
                Button("Show in Details") { show(change, scan: scan) }
                    .disabled(folder(for: change, scan: scan) == nil)
                Button("Reveal in Finder") { FileActions.reveal(path) }
                    .disabled(change.kind == .removed)
                Button("Copy Path") { FileActions.copyPath(path) }
            }
        } primaryAction: { ids in
            if let change = comparison.changes.first(where: { ids.contains($0.id) }) { show(change, scan: scan) }
        }
    }

    @ViewBuilder
    private func icon(for change: FolderChange, scan: ScanResult) -> some View {
        switch change.kind {
        case .files:
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
        case .removed:
            Image(nsImage: IconCache.icon(name: change.name, path: "", isFolder: true))
                .resizable()
                .opacity(0.45)
        default:
            Image(nsImage: IconCache.icon(name: change.name,
                                          path: FolderSnapshot.absolutePath(of: change.path, inside: scan.rootPath),
                                          isFolder: true))
                .resizable()
        }
    }

    /// Where the folder is, and what happened to it: "Library › Caches · New folder".
    private func detail(for change: FolderChange, scan: ScanResult) -> String {
        let location = change.folder.isEmpty
            ? scan.displayName
            : change.folder.split(separator: "/").joined(separator: " › ")
        switch change.kind {
        case .changed: return location
        case .files: return "Files directly in " + location
        case .added: return location + " · New folder"
        case .removed: return location + " · Removed"
        case .renamed: return location + " · Renamed from “\(change.oldName ?? "")”"
        }
    }

    /// The folder in the current scan that a row is about (for loose files, their folder).
    private func folder(for change: FolderChange, scan: ScanResult) -> Node? {
        guard change.kind != .removed else { return nil }
        return scan.root.descendant(atPath: FolderSnapshot.absolutePath(of: change.path, inside: scan.rootPath))
    }

    /// Opens the folder in Details.
    private func show(_ change: FolderChange, scan: ScanResult) {
        guard let node = folder(for: change, scan: scan) else { return }
        model.navigate(to: node)
        tab = .details
    }
}

// MARK: - Sorting

extension FileTypesView.ExtensionRow: FastSortable {
    typealias Row = FileTypesView.ExtensionRow
    static func sortKey(for keyPath: PartialKeyPath<Row>) -> SortKey<Row>? {
        switch keyPath {
        case \Row.displayName: return .text { $0.displayName }
        case \Row.groupName: return .text { $0.groupName }
        case \Row.allocated: return .integer { $0.allocated }
        case \Row.share: return .real { $0.share }
        case \Row.size: return .integer { $0.size }
        case \Row.count: return .integer { Int64($0.count) }
        default: return nil
        }
    }
}

extension TopFile: FastSortable {
    static func sortKey(for keyPath: PartialKeyPath<TopFile>) -> SortKey<TopFile>? {
        switch keyPath {
        case \TopFile.name: return .text { $0.name }
        case \TopFile.allocated: return .integer { $0.allocated }
        case \TopFile.size: return .integer { $0.size }
        case \TopFile.modified: return .integer { $0.modified }
        default: return nil
        }
    }
}

extension FolderChange: FastSortable {
    static func sortKey(for keyPath: PartialKeyPath<FolderChange>) -> SortKey<FolderChange>? {
        switch keyPath {
        case \FolderChange.name: return .text { $0.name }
        case \FolderChange.before: return .integer { $0.before }
        case \FolderChange.after: return .integer { $0.after }
        case \FolderChange.amount: return .integer { $0.amount }
        default: return nil
        }
    }
}

/// View state kept in classes so the app builds without SwiftUI's macros.
final class FileTypesState: ObservableObject {
    @Published var rows: [FileTypesView.ExtensionRow] = []
    @Published var groups: [FileTypesView.GroupRow] = []
    @Published var groupFilter: FileGroup?
    @Published var sortOrder = [KeyPathComparator(\FileTypesView.ExtensionRow.allocated, order: .reverse)]
}

final class TopFilesState: ObservableObject {
    @Published var selection = Set<TopFile.ID>()
    @Published var sortOrder = [KeyPathComparator(\TopFile.allocated, order: .reverse)]
    @Published var previewURL: URL?
}

final class HistoryState: ObservableObject {
    enum Shown: Hashable { case changes, scans }
    @Published var shown = Shown.changes
}

final class ChangesState: ObservableObject {
    @Published var selection = Set<FolderChange.ID>()
    @Published var sortOrder = [KeyPathComparator(\FolderChange.amount, order: .reverse)]
}
