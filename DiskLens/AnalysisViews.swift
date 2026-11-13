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
        return filtered.sorted(using: state.sortOrder)
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
        Table(result.topFiles.sorted(using: state.sortOrder), selection: $state.selection, sortOrder: $state.sortOrder) {
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

/// Space used by the scanned folder across past scans.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    let settings: DisplaySettings

    struct Row: Identifiable {
        let entry: HistoryEntry
        let change: Int64?
        var id: Date { entry.date }
    }

    var body: some View {
        let entries = model.history
        let rows: [Row] = entries.enumerated().map { index, entry in
            Row(entry: entry, change: index > 0 ? entry.allocated - entries[index - 1].allocated : nil)
        }.reversed()

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Space over time", systemImage: "chart.line.uptrend.xyaxis",
                         detail: SizeFormat.count(entries.count, "scan"))
            if entries.count < 2 {
                ContentUnavailableView("Not enough history yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Every scan of this folder adds a point. Scan it again later to see the trend."))
                    .frame(maxHeight: 220)
            } else {
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
                .frame(minHeight: 200)
                .card(padding: 16)
            }

            Table(rows) {
                TableColumn("Scanned") { row in
                    Text(row.entry.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                }
                TableColumn("On Disk") { row in
                    Text(settings.bytes(row.entry.allocated)).monospacedDigit()
                }
                TableColumn("Change") { row in
                    if let change = row.change {
                        HStack(spacing: 4) {
                            Image(systemName: change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "equal"))
                            Text((change >= 0 ? "+" : "−") + settings.bytes(abs(change)))
                                .monospacedDigit()
                        }
                        .foregroundStyle(change > 0 ? Color.orange : (change < 0 ? Color.green : Color.secondary))
                    }
                }
                TableColumn("Files") { row in
                    Text(SizeFormat.count(row.entry.files)).monospacedDigit()
                }
            }
        }
        .padding()
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
