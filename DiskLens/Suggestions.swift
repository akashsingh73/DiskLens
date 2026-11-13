import SwiftUI

// MARK: - Finding reclaimable places

/// Well-known places that often hold space you can get back: Xcode's build products, caches,
/// JavaScript packages, device backups, Docker's data and the Trash. They are looked up in the
/// scan's own tree, so nothing is read from disk, and only places inside the scan are found.
enum Suggestions {
    enum Kind: String, CaseIterable, Sendable {
        case derivedData, archives, deviceSupport, simulators, caches, homebrew, nodeModules, backups, docker, trash

        var title: String {
            switch self {
            case .derivedData: return "Xcode DerivedData"
            case .archives: return "Xcode Archives"
            case .deviceSupport: return "iOS Device Support"
            case .simulators: return "Simulator Devices"
            case .caches: return "Caches"
            case .homebrew: return "Homebrew Cache"
            case .nodeModules: return "node_modules"
            case .backups: return "iPhone and iPad Backups"
            case .docker: return "Docker Data"
            case .trash: return "Trash"
            }
        }

        /// Why it is usually safe to remove, in one short line.
        var reason: String {
            switch self {
            case .derivedData: return "Build products and indexes. Xcode makes them again on the next build."
            case .archives: return "Builds made with Product ▸ Archive. Keep any you still need for crash reports."
            case .deviceSupport: return "Debug symbols copied from devices you connected. Xcode copies them again when needed."
            case .simulators: return "Simulators and the apps on them. Quit Simulator first; Xcode can create new ones."
            case .caches: return "Files apps keep to start faster. They're rebuilt as needed; quit apps first."
            case .homebrew: return "Downloads of packages Homebrew has already installed, like brew cleanup removes."
            case .nodeModules: return "JavaScript packages for your projects. npm install (or yarn, pnpm) brings them back."
            case .backups: return "Backups Finder made of your devices. Old ones are easy to forget; check before removing."
            case .docker: return "Docker Desktop's images, containers and volumes. Quit Docker first; it starts empty."
            case .trash: return "Things you already deleted. Empty the Trash in Finder to free this space."
            }
        }

        var symbol: String {
            switch self {
            case .derivedData: return "hammer"
            case .archives: return "archivebox"
            case .deviceSupport: return "cable.connector"
            case .simulators: return "apps.iphone"
            case .caches: return "tray.full"
            case .homebrew: return "mug"
            case .nodeModules: return "shippingbox"
            case .backups: return "ipad.and.iphone"
            case .docker: return "cube.box"
            case .trash: return "trash"
            }
        }

        /// Where it lives, relative to the home folder. nil for node_modules, which can be anywhere.
        var homePath: String? {
            switch self {
            case .derivedData: return "Library/Developer/Xcode/DerivedData"
            case .archives: return "Library/Developer/Xcode/Archives"
            case .deviceSupport: return "Library/Developer/Xcode/iOS DeviceSupport"
            case .simulators: return "Library/Developer/CoreSimulator/Devices"
            case .caches: return "Library/Caches"
            case .homebrew: return "Library/Caches/Homebrew"
            case .nodeModules: return nil
            case .backups: return "Library/Application Support/MobileSync/Backup"
            case .docker: return "Library/Containers/com.docker.docker"
            case .trash: return ".Trash"
            }
        }

        /// The Trash itself can't go to the Trash: it is emptied from Finder.
        var canTrash: Bool { self != .trash }
    }

    struct Suggestion: Identifiable {
        let kind: Kind
        /// The folders, largest first: one for a fixed place, every node_modules folder for `.nodeModules`.
        let nodes: [Node]
        let allocated: Int64
        var id: Kind { kind }
    }

    private static let dataVolume = "/System/Volumes/Data"

    /// Folders at the top of a disk that hold the system, apps and command-line tools rather than projects.
    private static let systemFolders = ["/Applications", "/Library", "/System", "/opt", "/private", "/usr"]

    /// Folders that are really one item (apps, frameworks, plug-ins): their node_modules are part of them.
    private static let bundleExtensions: Set<String> = ["app", "appex", "bundle", "framework", "plugin", "xpc"]

    /// Everything worth suggesting in a scan, largest first. `home` is the user's home folder.
    static func find(in root: Node, home: String) -> [Suggestion] {
        var found: [Suggestion] = []
        for kind in Kind.allCases {
            guard let relative = kind.homePath else { continue }
            for path in candidatePaths(home + "/" + relative) {
                guard let node = root.descendant(atPath: path) else { continue }
                // The scan's own top folder can't be moved to the Trash or opened from here.
                if node !== root, node.kind == .directory, node.allocated > 0 {
                    found.append(Suggestion(kind: kind, nodes: [node], allocated: node.allocated))
                }
                break
            }
        }
        let packages = nodeModules(in: root)
        if !packages.isEmpty {
            found.append(Suggestion(kind: .nodeModules, nodes: packages,
                                    allocated: packages.reduce(0) { $0 + $1.allocated }))
        }
        return found.sorted { $0.allocated > $1.allocated }
    }

    /// Where an absolute path can sit in a scan: as itself, and inside the startup disk's data
    /// volume, which is what DiskLens scans for "/" ("/System/Volumes/Data/Users/…").
    static func candidatePaths(_ path: String) -> [String] {
        path.hasPrefix(dataVolume + "/") ? [path] : [path, dataVolume + path]
    }

    /// Every node_modules folder of a project in the scan, largest first. A node_modules folder
    /// inside another one is part of it. Those that belong to apps and tools are left out, because
    /// removing them breaks the app: anything inside an app or other bundle, a hidden folder (editor
    /// extensions, Node version managers, the Trash), a Library folder, or the system's folders.
    static func nodeModules(in root: Node) -> [Node] {
        guard let rootPath = root.rootPath, !isToolPath(rootPath) else { return [] }
        var skipped = Set<ObjectIdentifier>()
        for folder in systemFolders {
            for path in candidatePaths(folder) {
                if let node = root.descendant(atPath: path), node !== root { skipped.insert(node.id) }
            }
        }
        var found: [Node] = []
        var stack = [root]
        while let node = stack.popLast() {
            for child in node.children where child.kind == .directory {
                if child.name == "node_modules" {
                    if child.allocated > 0 { found.append(child) }
                } else if !isToolFolder(child.name) && !skipped.contains(child.id) {
                    stack.append(child)
                }
            }
        }
        return found.sorted { $0.allocated > $1.allocated }
    }

    /// A folder whose node_modules belong to an app or tool (see `nodeModules(in:)`).
    static func isToolFolder(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Library"
            || bundleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a whole scan sits inside a folder whose node_modules belong to an app or tool.
    static func isToolPath(_ path: String) -> Bool {
        var plain = path
        if path == dataVolume {
            plain = "/"
        } else if path.hasPrefix(dataVolume + "/") {
            plain = String(path.dropFirst(dataVolume.count))
        }
        if systemFolders.contains(where: { plain == $0 || plain.hasPrefix($0 + "/") }) { return true }
        return (plain as NSString).pathComponents.contains { $0 != "/" && isToolFolder($0) }
    }

    /// The space all suggestions take together, each folder counted once
    /// (Homebrew's cache, for one, sits inside Caches).
    static func total(of suggestions: [Suggestion]) -> Int64 {
        let nodes = suggestions.flatMap(\.nodes)
        let ids = Set(nodes.map(\.id))
        var total: Int64 = 0
        for node in nodes {
            var inside = false
            var current = node.parent
            while let ancestor = current {
                if ids.contains(ancestor.id) { inside = true; break }
                current = ancestor.parent
            }
            if !inside { total += node.allocated }
        }
        return total
    }
}

// MARK: - The view

/// Well-known places in the scan that often hold space you can get back, largest first.
struct SuggestionsView: View {
    @ObservedObject var model: AppModel
    let result: ScanResult
    let settings: DisplaySettings
    /// Shows a folder's contents in Details.
    let show: @MainActor (Node) -> Void

    @StateObject private var state = SuggestionsState()

    /// How many folders of a group (node_modules) are listed; the rest are summed up in a line.
    private static let listLimit = 100

    var body: some View {
        let key = SuggestionsState.Key(result: ObjectIdentifier(result), version: model.version)
        let scanTotal = max(1, result.root.allocated)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Suggestions", systemImage: "lightbulb", detail: "whole scan")
                if state.key?.result == key.result {
                    if state.items.isEmpty {
                        ContentUnavailableView("Nothing to suggest", systemImage: "checkmark.seal",
                                               description: Text("This scan has none of the usual places that fill up: Xcode's build files, caches, node_modules, device backups, Docker's data, or a full Trash."))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        summary(scanTotal: scanTotal)
                        ForEach(state.items) { suggestion in
                            SuggestionRow(suggestion: suggestion, scanTotal: scanTotal, settings: settings,
                                          listLimit: Self.listLimit, show: show) { model.trash(node: $0) }
                        }
                    }
                }
            }
            .padding()
        }
        .task(id: key) { compute(key) }
    }

    private func summary(scanTotal: Int64) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "lightbulb.fill", tint: .green, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(settings.bytes(state.total)) in places you can often clean up")
                    .font(.headline)
                Text("\(SizeFormat.count(state.items.count, "place")), \(SizeFormat.percent(Double(state.total) / Double(scanTotal), decimals: 0)) of this scan. Check each one before you remove it: DiskLens always asks first, and only moves things to the Trash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(tint: .green)
    }

    private func compute(_ key: SuggestionsState.Key) {
        let items = Suggestions.find(in: result.root, home: NSHomeDirectory())
        state.items = items
        state.total = Suggestions.total(of: items)
        state.key = key
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestions.Suggestion
    let scanTotal: Int64
    let settings: DisplaySettings
    let listLimit: Int
    let show: @MainActor (Node) -> Void
    let trash: @MainActor (Node) -> Void
    @StateObject private var disclosure = DisclosureState()

    var body: some View {
        let kind = suggestion.kind
        let single = suggestion.nodes.count == 1 ? suggestion.nodes.first : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemImage: kind.symbol, tint: kind.color, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(kind.title)
                            .font(.headline)
                        if single == nil {
                            Chip(text: SizeFormat.count(suggestion.nodes.count, "folder"), systemImage: "folder")
                        }
                    }
                    Text(kind.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let single {
                        Text(Self.displayPath(single.path))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(PathDisplay.friendly(single.path))
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(settings.bytes(suggestion.allocated))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text("\(Self.share(suggestion.allocated, of: scanTotal)) of scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Group {
                if let single {
                    actions(for: single)
                } else {
                    folderList
                }
            }
            .padding(.leading, 46)
        }
        .card()
    }

    private func actions(for node: Node) -> some View {
        HStack(spacing: 8) {
            if suggestion.kind == .trash {
                Button { FileActions.open(node.path) } label: {
                    Label("Open Trash", systemImage: "arrow.up.forward.app")
                }
            } else {
                Button { FileActions.reveal(node.path) } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
            }
            Button { show(node) } label: {
                Label("Show in DiskLens", systemImage: "arrow.right.circle")
            }
            if suggestion.kind.canTrash {
                Button(role: .destructive) { trash(node) } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
            }
        }
        .controlSize(.small)
    }

    /// A group (node_modules): a button to list its folders, each with its own actions.
    private var folderList: some View {
        let nodes = suggestion.nodes
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                disclosure.expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(disclosure.expanded ? 90 : 0))
                    Text(disclosure.expanded ? "Hide the folders" : "Show the \(SizeFormat.count(nodes.count, "folder"))")
                }
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)

            if disclosure.expanded {
                VStack(spacing: 0) {
                    ForEach(nodes.prefix(listLimit)) { node in
                        FolderLine(node: node, settings: settings, canTrash: suggestion.kind.canTrash,
                                   show: show, trash: trash)
                    }
                }
                if nodes.count > listLimit {
                    let rest = nodes.dropFirst(listLimit)
                    Text("And \(SizeFormat.count(rest.count, "smaller folder")) (\(settings.bytes(rest.reduce(0) { $0 + $1.allocated })) in all)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "3.2 %", or "< 0.1 %" for something too small to show as a share.
    static func share(_ part: Int64, of whole: Int64) -> String {
        let fraction = Double(part) / Double(max(1, whole))
        return part > 0 && fraction < 0.0005 ? "< 0.1 %" : SizeFormat.percent(fraction)
    }

    /// A path as Finder shows it, with the home folder as "~".
    static func displayPath(_ path: String) -> String {
        (PathDisplay.friendly(path) as NSString).abbreviatingWithTildeInPath
    }
}

/// One folder of a group, with small buttons for its actions.
private struct FolderLine: View {
    let node: Node
    let settings: DisplaySettings
    let canTrash: Bool
    let show: @MainActor (Node) -> Void
    let trash: @MainActor (Node) -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        // node_modules folders are told apart by the project they belong to.
        let project = node.parent.map { SuggestionRow.displayPath($0.path) } ?? node.name
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(project)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(PathDisplay.friendly(node.path))
            Spacer(minLength: 8)
            Text(settings.bytes(node.allocated))
                .monospacedDigit()
                .lineLimit(1)
            HStack(spacing: 2) {
                iconButton("magnifyingglass", help: "Reveal in Finder") { FileActions.reveal(node.path) }
                iconButton("arrow.right.circle", help: "Show in DiskLens") { show(node) }
                if canTrash {
                    iconButton("trash", help: "Move to Trash…") { trash(node) }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(hover.isHovering ? 0.05 : 0)))
        .onHover { hover.isHovering = $0 }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Suggestions.Kind {
    var color: Color {
        switch self {
        case .derivedData: return Theme.color(0)
        case .archives: return Theme.color(6)
        case .deviceSupport: return Theme.color(7)
        case .simulators: return Theme.color(5)
        case .caches: return Theme.color(10)
        case .homebrew: return Theme.color(1)
        case .nodeModules: return Theme.color(2)
        case .backups: return Theme.color(3)
        case .docker: return Theme.color(4)
        case .trash: return Theme.color(8)
        }
    }
}

/// View state kept in classes so the app builds without SwiftUI's macros.
final class SuggestionsState: ObservableObject {
    /// The scan (and its version, which changes after a move to the Trash) the list was made for.
    struct Key: Equatable {
        let result: ObjectIdentifier
        let version: Int
    }

    @Published var key: Key?
    @Published var items: [Suggestions.Suggestion] = []
    @Published var total: Int64 = 0
}

final class DisclosureState: ObservableObject {
    @Published var expanded = false
}
