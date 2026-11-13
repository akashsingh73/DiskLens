import SwiftUI

/// The bar across the top of the window: scanning, Back / Forward / Up, and how sizes are shown.
/// It is ordinary window content rather than a SwiftUI toolbar: toolbar items that change size
/// can send SwiftUI and AppKit into an endless layout loop, which is what crashed version 1.0.
struct CommandBar: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.sizeMode) private var mode: SizeMode = .allocated
    @AppStorage(Prefs.unit) private var unit: SizeUnit = .auto

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

            Picker("Show", selection: $mode) {
                ForEach(SizeMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What the sizes and bars show")

            Picker("Unit", selection: $unit) {
                ForEach(SizeUnit.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Size unit")
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
