import SwiftUI
import Charts

/// Pie and bar charts of the selected folder's direct subfolders.
struct ChartsView: View {
    @ObservedObject var model: AppModel
    let node: Node
    let settings: DisplaySettings

    enum Style: String, CaseIterable, Identifiable {
        case pie = "Pie"
        case bar = "Bar"
        var id: String { rawValue }
    }

    @AppStorage("chartStyle") private var style: Style = .pie

    /// A slice's colour: palette colours for folders, greys for loose files and "Other".
    private static func color(for slice: Slice, at index: Int) -> Color {
        switch slice.id {
        case "other": return Theme.neutral.color
        case "files": return Theme.neutral.lightened(0.5)
        default: return Theme.color(index)
        }
    }

    struct Slice: Identifiable {
        let id: String
        let label: String
        let value: Double
        let text: String
        let node: Node?
    }

    private var scope: Node { node.directory }

    private var slices: [Slice] {
        let current = settings
        var entries = scope.children.filter { current.metric($0) > 0 }
        if let files = scope.filesNode, current.metric(files) > 0 { entries.append(files) }
        entries.sort { current.metric($0) > current.metric($1) }
        let limit = 12
        // Chart categories must be unique; folder names already are, the extra entries might not be.
        var used = Set<String>()
        func unique(_ label: String) -> String {
            var candidate = label
            var number = 2
            while used.contains(candidate) {
                candidate = "\(label) (\(number))"
                number += 1
            }
            used.insert(candidate)
            return candidate
        }
        var result = entries.prefix(limit).map { child in
            Slice(id: child.kind == .files ? "files" : "folder:" + child.name,
                  label: unique(child.kind == .files ? "Files in this folder" : child.name),
                  value: current.metric(child),
                  text: current.label(for: child),
                  node: child)
        }
        if entries.count > limit {
            let rest = entries.dropFirst(limit)
            let value = rest.reduce(0.0) { $0 + settings.metric($1) }
            let text: String
            switch settings.mode {
            case .files: text = SizeFormat.count(Int(value), "file")
            case .size: text = settings.bytes(rest.reduce(0) { $0 + $1.size })
            case .allocated, .percent: text = settings.bytes(rest.reduce(0) { $0 + $1.allocated })
            }
            result.append(Slice(id: "other", label: unique("Other (\(rest.count) more)"), value: value, text: text, node: nil))
        }
        return result
    }

    var body: some View {
        let data = slices
        let colors = data.enumerated().map { Self.color(for: $0.element, at: $0.offset) }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(title: scope.kind == .files ? "Files" : scope.name,
                             systemImage: style == .pie ? "chart.pie" : "chart.bar.xaxis",
                             detail: settings.label(for: scope))
                Spacer(minLength: 12)
                Picker("Chart", selection: $style) {
                    Label("Pie", systemImage: "chart.pie").tag(Style.pie)
                    Label("Bar", systemImage: "chart.bar.xaxis").tag(Style.bar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if data.isEmpty {
                ContentUnavailableView("Nothing to chart", systemImage: "chart.pie",
                                       description: Text("This folder has no subfolders with data."))
            } else if style == .pie {
                HStack(alignment: .top, spacing: 28) {
                    ZStack {
                        Chart(data) { slice in
                            SectorMark(angle: .value("Amount", slice.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .foregroundStyle(by: .value("Folder", slice.label))
                                .cornerRadius(4)
                        }
                        .chartForegroundStyleScale(domain: data.map(\.label), range: colors)
                        .chartLegend(.hidden)
                        VStack(spacing: 1) {
                            Text(settings.label(for: scope))
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(SizeFormat.count(data.count, "item"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 120)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(minWidth: 160, idealWidth: 260, maxWidth: 300)

                    legend(data, colors: colors)
                        .frame(minWidth: 240, maxWidth: 420)
                        .layoutPriority(1)
                }
            } else {
                ScrollView {
                    Chart(data) { slice in
                        BarMark(x: .value("Amount", slice.value), y: .value("Folder", slice.label))
                            .foregroundStyle(by: .value("Folder", slice.label))
                            .cornerRadius(4)
                            .annotation(position: .trailing) {
                                Text(slice.text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                    }
                    .chartForegroundStyleScale(domain: data.map(\.label), range: colors)
                    .chartLegend(.hidden)
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(data.count) * 30 + 20)
                    .padding(.trailing, 80)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private func legend(_ data: [Slice], colors: [Color]) -> some View {
        let total = data.reduce(0) { $0 + $1.value }
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.element.id) { index, slice in
                    LegendRow(slice: slice, color: colors[index],
                              share: total > 0 ? slice.value / total : 0) {
                        if let target = slice.node, target.kind == .directory { model.navigate(to: target) }
                    }
                }
            }
        }
    }
}

/// One line of the pie chart's legend. Folders open with a click.
private struct LegendRow: View {
    let slice: ChartsView.Slice
    let color: Color
    let share: Double
    let open: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    private var opens: Bool { slice.node?.kind == .directory }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(slice.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(slice.text)
                .monospacedDigit()
            Text(SizeFormat.percent(share, decimals: 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .opacity(opens && hover.isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(opens && hover.isHovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture { if opens { open() } }
        .help(opens ? "Open \(slice.label)" : slice.label)
    }
}
