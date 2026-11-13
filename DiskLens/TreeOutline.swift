import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The folder tree: an AppKit outline view (fast with very large trees) where every row
/// carries a size bar, like TreeSize's directory tree.
struct TreeOutline: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let settings: DisplaySettings

    func makeCoordinator() -> Coordinator { Coordinator(model: model, settings: settings) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menu = context.coordinator.makeMenu()

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.outline = outline
        context.coordinator.scheduleSync()
        return scrollView
    }

    /// Called by SwiftUI while it updates the window. Changing the outline view here (reloading,
    /// expanding, selecting, scrolling) would change AppKit layout in the middle of SwiftUI's own
    /// layout pass, so the work is only recorded and done right after.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.pendingSettings = settings
        context.coordinator.scheduleSync()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
        let model: AppModel
        weak var outline: NSOutlineView?
        /// The settings the rows are currently built with, and the newest ones from SwiftUI.
        private var settings: DisplaySettings
        var pendingSettings: DisplaySettings

        private var cache: [ObjectIdentifier: [Node]] = [:]
        private var shownRoot: Node?
        /// Returned only if AppKit ever asks for a row that doesn't exist (it shouldn't); kept
        /// alive here because outline views don't retain their items.
        private let placeholder = Node(name: "", parent: nil)
        private var shownVersion = -1
        private var handledRevealToken = -1
        private var syncScheduled = false
        private var applyingSelection = false

        init(model: AppModel, settings: DisplaySettings) {
            self.model = model
            self.settings = settings
            self.pendingSettings = settings
        }

        func detach() {
            outline?.dataSource = nil
            outline?.delegate = nil
            outline = nil
            cache.removeAll()
            shownRoot = nil
        }

        // MARK: Keeping in step with the model

        func scheduleSync() {
            guard !syncScheduled else { return }
            syncScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncScheduled = false
                self.sync()
            }
        }

        private func sync() {
            guard let outline else { return }
            reloadIfNeeded(outline)
            guard let selection = model.selection else { return }
            if model.revealToken != handledRevealToken {
                handledRevealToken = model.revealToken
                reveal(selection, in: outline)
            } else {
                selectIfShown(selection, in: outline)
            }
        }

        private func reloadIfNeeded(_ outline: NSOutlineView) {
            let root = model.result?.root
            let rootChanged = root !== shownRoot
            guard rootChanged || pendingSettings != settings || shownVersion != model.version else { return }

            let expanded = rootChanged ? [] : expandedNodes(outline)
            cache.removeAll()
            shownRoot = root
            settings = pendingSettings
            shownVersion = model.version

            applyingSelection = true
            defer { applyingSelection = false }
            outline.reloadData()
            if rootChanged {
                if let root { outline.expandItem(root) }
            } else {
                for node in expanded where outline.row(forItem: node) >= 0 {
                    outline.expandItem(node)
                }
            }
        }

        private func expandedNodes(_ outline: NSOutlineView) -> [Node] {
            var nodes: [Node] = []
            for row in 0..<outline.numberOfRows {
                if let node = outline.item(atRow: row) as? Node, outline.isItemExpanded(node) {
                    nodes.append(node)
                }
            }
            return nodes
        }

        /// The visible children of a folder in the current sort order, cached until something changes.
        func children(of node: Node) -> [Node] {
            if let cached = cache[node.id] { return cached }
            var list: [Node] = node.kind == .directory ? node.children : []
            if settings.showFilesNode, let files = node.filesNode { list.append(files) }
            if settings.hideBelowBytes > 0 {
                let limit = settings.hideBelowBytes
                list = list.filter { $0.allocated >= limit }
            }
            if settings.sortByName {
                list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            } else {
                let current = settings
                list.sort { current.metric($0) > current.metric($1) }
            }
            cache[node.id] = list
            return list
        }

        // MARK: Selection

        /// Selects a row only if it is already showing (a folder the user collapsed stays collapsed).
        private func selectIfShown(_ node: Node, in outline: NSOutlineView) {
            let row = outline.row(forItem: node)
            guard row >= 0, outline.selectedRow != row else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        /// Expands the tree down to a node, selects it and scrolls to it. If the node is hidden
        /// (for example by "Hide items smaller than"), its nearest shown ancestor is selected instead.
        private func reveal(_ node: Node, in outline: NSOutlineView) {
            applyingSelection = true
            defer { applyingSelection = false }
            var target: Node?
            for item in node.chain {
                guard outline.row(forItem: item) >= 0 else { break }
                target = item
                if item !== node { outline.expandItem(item) }
            }
            guard let target else { return }
            let row = outline.row(forItem: target)
            guard row >= 0 else { return }
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            outline.scrollRowToVisible(row)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
            Task { @MainActor [weak self] in
                guard let self, self.model.selection !== node else { return }
                self.model.navigate(to: node, reveal: false)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return shownRoot == nil ? 0 : 1 }
            return children(of: node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return shownRoot ?? placeholder }
            let list = children(of: node)
            guard list.indices.contains(index) else { return placeholder }
            return list[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node, node.kind == .directory else { return false }
            return !children(of: node).isEmpty
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let root = shownRoot else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("TreeCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? TreeCellView) ?? {
                let view = TreeCellView(frame: .zero)
                view.identifier = identifier
                return view
            }()
            cell.configure(node: node, root: root, settings: settings)
            return cell
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let item = sender.item(atRow: row) else { return }
            if sender.isItemExpanded(item) {
                sender.collapseItem(item)
            } else {
                sender.expandItem(item)
            }
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open", action: #selector(openItem(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Expand All Below", action: #selector(expandAll(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Collapse All Below", action: #selector(collapseAll(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash…", action: #selector(moveToTrash(_:)), keyEquivalent: "").target = self
            return menu
        }

        private var clickedNode: Node? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? Node
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            guard let node = clickedNode else { return false }
            switch menuItem.action {
            case #selector(moveToTrash(_:)):
                return node.kind == .directory && !node.isRoot && !node.otherVolume && !node.pending && !model.isReadingTree
            case #selector(expandAll(_:)), #selector(collapseAll(_:)):
                return node.kind == .directory && !node.children.isEmpty
            default:
                return true
            }
        }

        @objc func revealInFinder(_ sender: Any?) {
            if let node = clickedNode { FileActions.reveal(node.path) }
        }

        @objc func openItem(_ sender: Any?) {
            if let node = clickedNode { FileActions.open(node.path) }
        }

        @objc func copyPath(_ sender: Any?) {
            if let node = clickedNode { FileActions.copyPath(node.path) }
        }

        /// Expands everything below a folder. A huge branch (a whole disk can hold hundreds of
        /// thousands of folders) opens only its first few thousand folders, biggest levels first,
        /// so the window never freezes.
        @objc func expandAll(_ sender: Any?) {
            guard let node = clickedNode, let outline else { return }
            let budget = 3_000
            if node.folderCount <= budget {
                outline.expandItem(node, expandChildren: true)
                return
            }
            var queue: [Node] = [node]
            var next = 0
            while next < queue.count && next < budget {
                let item = queue[next]
                next += 1
                outline.expandItem(item)
                queue.append(contentsOf: children(of: item).filter { $0.kind == .directory && !$0.children.isEmpty })
            }
        }

        @objc func collapseAll(_ sender: Any?) {
            if let node = clickedNode { outline?.collapseItem(node, collapseChildren: true) }
        }

        @objc func moveToTrash(_ sender: Any?) {
            guard let node = clickedNode, node.kind == .directory, !node.isRoot else {
                NSSound.beep()
                return
            }
            model.trash(node: node)
        }
    }
}

/// One row of the tree: icon, name, a slim size bar, and the size.
final class TreeCellView: NSTableCellView {
    private let track = TrackView()
    private let bar = GradientBar()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var fraction: CGFloat = 0
    private var showsBar = true

    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let filesIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Files")
    private static let lockIcon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "No access")
    private static let driveIcon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Other volume")
    private static let cloudIcon = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Only in the cloud")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        addSubview(track)
        addSubview(bar)
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(sizeLabel)
        icon.imageScaling = .scaleProportionallyDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        sizeLabel.alignment = .right
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        textField = nameLabel
        imageView = icon
    }

    func configure(node: Node, root: Node, settings: DisplaySettings) {
        nameLabel.stringValue = node.unreadable ? node.name + "  (no access)" : node.name
        sizeLabel.stringValue = node.otherVolume ? "other disk"
            : node.cloudOnly ? "in the cloud"
            : node.pending ? "reading…"
            : settings.label(for: node)

        let total: Double
        switch settings.barScale {
        case .wholeScan: total = settings.metric(root)
        case .parent: total = node.parent.map { settings.metric($0) } ?? settings.metric(root)
        }
        let share = total > 0 ? settings.metric(node) / total : 0
        showsBar = settings.showBars && !node.otherVolume
        fraction = showsBar ? CGFloat(max(0, min(1, share))) : 0
        track.isHidden = !showsBar
        bar.isHidden = !showsBar || fraction <= 0
        bar.setColors(settings.barStart, settings.barEnd)

        let rootShare = settings.metric(root) > 0 ? settings.metric(node) / settings.metric(root) : 0
        let bold = node !== root && rootShare * 100 >= settings.boldPercent && settings.boldPercent > 0
        nameLabel.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.textColor = node.unreadable || node.otherVolume || node.cloudOnly || node.pending
            ? .secondaryLabelColor : .labelColor

        switch true {
        case node.kind == .files: icon.image = Self.filesIcon
        case node.unreadable: icon.image = Self.lockIcon
        case node.otherVolume: icon.image = Self.driveIcon
        case node.cloudOnly: icon.image = Self.cloudIcon
        case node.name.hasSuffix(".app"): icon.image = IconCache.icon(name: node.name, path: node.path, isFolder: true)
        default: icon.image = Self.folderIcon
        }

        toolTip = Self.tooltip(for: node, settings: settings)
        needsLayout = true
    }

    private static func tooltip(for node: Node, settings: DisplaySettings) -> String {
        var lines = [node.kind == .files ? "Files directly in \(node.path)" : node.path]
        lines.append("On disk: \(SizeFormat.bytes(node.allocated, base: settings.base))")
        lines.append("Size: \(SizeFormat.bytes(node.size, base: settings.base))")
        lines.append("Files: \(SizeFormat.count(node.fileCount))")
        if node.kind == .directory { lines.append("Folders: \(SizeFormat.count(node.folderCount))") }
        if node.newest > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(node.newest))
            lines.append("Last modified: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if node.unreadableCount > 0 { lines.append("Unreadable folders inside: \(node.unreadableCount)") }
        if node.cloudOnly { lines.append("Only in the cloud: not downloaded, so it takes no space on this Mac") }
        if node.pending { lines.append("Still being read") }
        return lines.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let textHeight: CGFloat = 17
        let textY = (bounds.height - textHeight) / 2
        let sizeWidth: CGFloat = 72
        let barWidth: CGFloat = showsBar ? min(64, max(0, bounds.width * 0.22)) : 0
        let barHeight: CGFloat = 6
        let sizeX = max(0, bounds.width - sizeWidth - 6)
        let barX = sizeX - barWidth - 6
        let barY = (bounds.height - barHeight) / 2
        track.frame = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
        let filled = fraction > 0 ? max(barHeight, (barWidth * fraction).rounded()) : 0
        bar.frame = NSRect(x: barX, y: barY, width: min(barWidth, filled), height: barHeight)
        icon.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        sizeLabel.frame = NSRect(x: sizeX, y: textY, width: sizeWidth, height: textHeight)
        nameLabel.frame = NSRect(x: 23, y: textY, width: max(0, barX - 23 - 8), height: textHeight)
    }
}

/// The faint groove a tree row's size bar sits in. Its colour follows light and dark mode.
final class TrackView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A capsule filled with a left-to-right gradient.
final class GradientBar: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(gradient)
    }

    func setColors(_ start: NSColor, _ end: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = [start.cgColor, end.cgColor]
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        gradient.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
