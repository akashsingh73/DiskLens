import SwiftUI

/// The bar across the top of the window: scanning, Back / Forward / Up, and search.
/// It is ordinary window content rather than a SwiftUI toolbar: toolbar items that change size
/// can send SwiftUI and AppKit into an endless layout loop, which is what crashed version 1.0.
struct CommandBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AppModel.quickTargets) { target in
                    Button {
                        model.scan(path: target.path)
                    } label: {
                        Label(target.title, systemImage: target.systemImage)
                    }
                }
                Divider()
                Button("Choose Folder…") { model.chooseFolder() }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .fixedSize()
            .disabled(model.isScanning)
            .help("Scan a folder or disk")

            if model.isScanning {
                Button {
                    model.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the scan (⌘.)")
            } else {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.result == nil)
                .help("Scan the same folder again (⌘R)")
            }

            Divider()
                .frame(height: 18)

            iconButton("Back", systemImage: "chevron.left", help: "Back (⌘[)", enabled: model.canGoBack) {
                model.goBack()
            }
            iconButton("Forward", systemImage: "chevron.right", help: "Forward (⌘])", enabled: model.canGoForward) {
                model.goForward()
            }
            iconButton("Enclosing Folder", systemImage: "arrow.up", help: "Enclosing folder (⌘↑)", enabled: model.canGoUp) {
                model.goUp()
            }

            if let name = model.trashingName {
                ProgressView()
                    .controlSize(.small)
                Text("Moving “\(name)” to the Trash…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            SearchButton(model: model, search: model.search)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    private func iconButton(_ title: String, systemImage: String, help: String, enabled: Bool,
                            action: @escaping @MainActor () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 18)
        }
        .disabled(!enabled)
        .help(help)
    }
}

/// The row just above the folder tree: what the sizes and bars show (On Disk, Size, Files or % of
/// the parent folder) and the unit. It sits next to the tree because the tree is what it changes
/// most; the views on the right follow it too.
struct SizeModeBar: View {
    @AppStorage(Prefs.sizeMode) private var mode: SizeMode = .allocated
    @AppStorage(Prefs.unit) private var unit: SizeUnit = .auto

    var body: some View {
        // The widest layout that fits the sidebar; the last one fits even the narrowest sidebar.
        ViewThatFits(in: .horizontal) {
            row(unitTitle: true)
            row(unitTitle: false)
            compactRow
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Both choices as small menus, for a very narrow sidebar.
    private var compactRow: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: $mode) {
                ForEach(SizeMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Sizes and bars show: \(mode.help)")
            Spacer(minLength: 0)
            unitMenu(showTitle: false)
        }
        .controlSize(.small)
    }

    private func unitMenu(showTitle: Bool) -> some View {
        Menu {
            Picker("Unit", selection: $unit) {
                ForEach(SizeUnit.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if showTitle {
                Label(unit.title, systemImage: "ruler")
            } else {
                Label(unit.title, systemImage: "ruler").labelStyle(.iconOnly)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Size unit: \(unit.title)")
    }

    private func row(unitTitle: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(SizeMode.allCases) { option in
                    ModeSegment(option: option, selected: mode == option) { mode = option }
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()

            Spacer(minLength: 0)

            unitMenu(showTitle: unitTitle)
        }
        .controlSize(.small)
    }
}

/// One choice in the size-mode switch: a pill that fills with the accent colour when chosen.
private struct ModeSegment: View {
    let option: SizeMode
    let selected: Bool
    let action: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(option.shortTitle)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor
                                                    : Color.primary.opacity(hover.isHovering ? 0.07 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help("\(option.title): \(option.help)")
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Breadcrumbs for the folder being shown. Click any part of the path to go there.
struct PathBar: View {
    let node: Node
    let settings: DisplaySettings
    let navigate: @MainActor (Node) -> Void

    /// Paths deeper than this show the first folder, a "…" menu, and the last few folders.
    private static let maxShown = 6
    private static let tailShown = 4

    var body: some View {
        let folder = node.directory
        let chain = folder.chain
        let collapse = chain.count > Self.maxShown
        let head: [Node] = collapse ? [chain[0]] : chain
        let hidden: [Node] = collapse ? Array(chain[1..<(chain.count - Self.tailShown)]) : []
        let tail: [Node] = collapse ? Array(chain.suffix(Self.tailShown)) : []

        HStack(spacing: 4) {
            ForEach(head) { crumb in
                crumbButton(crumb, isCurrent: crumb === folder && node.kind == .directory)
                if crumb !== chain.last {
                    separator
                }
            }
            if collapse {
                Menu {
                    ForEach(hidden) { crumb in
                        Button(crumb.name) { navigate(crumb) }
                    }
                } label: {
                    Text("…")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More folders")
                separator
                ForEach(tail) { crumb in
                    crumbButton(crumb, isCurrent: crumb === folder && node.kind == .directory)
                    if crumb !== chain.last {
                        separator
                    }
                }
            }
            if node.kind == .files {
                separator
                Text("Files")
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(summary(for: node))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func crumbButton(_ crumb: Node, isCurrent: Bool) -> some View {
        Button {
            navigate(crumb)
        } label: {
            HStack(spacing: 4) {
                if crumb.isRoot {
                    Image(systemName: Self.isVolume(crumb) ? "internaldrive" : "folder")
                        .foregroundStyle(.secondary)
                }
                Text(crumb.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(PathDisplay.friendly(crumb.path))
    }

    private func summary(for node: Node) -> String {
        var parts = [settings.bytes(node.allocated) + " on disk"]
        parts.append(SizeFormat.count(node.fileCount) + (node.fileCount == 1 ? " file" : " files"))
        if node.kind == .directory {
            parts.append(SizeFormat.count(node.folderCount) + (node.folderCount == 1 ? " folder" : " folders"))
        }
        return parts.joined(separator: " · ")
    }

    private static func isVolume(_ root: Node) -> Bool {
        guard let path = root.rootPath else { return false }
        if path == "/" || path == "/System/Volumes/Data" { return true }
        let components = (path as NSString).pathComponents
        return components.count == 3 && components[1] == "Volumes"
    }
}
