import SwiftUI
import AppKit

/// A tile in the treemap.
struct TreemapTile {
    let node: Node
    let rect: CGRect
    let depth: Int
    let branch: Int          // index of the top-level child this tile belongs to (-1 for the root)
    var isLeaf: Bool
    /// Height of the title strip along the top of a top-level tile (0 when it has none).
    var header: CGFloat = 0
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
enum Squarify {
    /// Lays out `values` (sorted largest first) inside `rect`; returns one rectangle per value.
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start + 1
            var sum = areas[start]
            var rowMin = areas[start]
            var rowMax = areas[start]
            var best = worst(sum: sum, min: rowMin, max: rowMax, side: side)
            while end < areas.count {
                let candidate = areas[end]
                let newSum = sum + candidate
                let ratio = worst(sum: newSum, min: Swift.min(rowMin, candidate), max: Swift.max(rowMax, candidate), side: side)
                if ratio > best { break }
                sum = newSum
                rowMin = Swift.min(rowMin, candidate)
                rowMax = Swift.max(rowMax, candidate)
                best = ratio
                end += 1
            }

            // Place the row along the shorter side of what's left.
            if remaining.width >= remaining.height {
                let width = CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for i in start..<end {
                    let height = CGFloat(areas[i] / Double(width))
                    result[i] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for i in start..<end {
                    let width = CGFloat(areas[i] / Double(height))
                    result[i] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }

    /// The worst aspect ratio in a row of total area `sum` laid along `side`.
    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        guard sum > 0, min > 0 else { return .infinity }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return Swift.max(sideSquared * max / sumSquared, sumSquared / (sideSquared * min))
    }
}

enum TreemapBuilder {
    static let headerHeight: CGFloat = 18

    static func tiles(for root: Node, in rect: CGRect, maxDepth: Int, minSide: CGFloat,
                      metric: (Node) -> Double) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        add(root, rect: rect, depth: 0, branch: -1, maxDepth: maxDepth, minSide: minSide,
            metric: metric, into: &tiles)
        return tiles
    }

    private static func add(_ node: Node, rect: CGRect, depth: Int, branch: Int, maxDepth: Int,
                            minSide: CGFloat, metric: (Node) -> Double, into tiles: inout [TreemapTile]) {
        let index = tiles.count
        tiles.append(TreemapTile(node: node, rect: rect, depth: depth, branch: branch, isLeaf: true))
        guard depth < maxDepth, node.kind == .directory else { return }

        var items = node.children.filter { metric($0) > 0 }
        if let files = node.filesNode, metric(files) > 0 { items.append(files) }
        guard !items.isEmpty else { return }
        items.sort { metric($0) > metric($1) }

        let padding: CGFloat = depth < 3 ? 2 : 1
        var inner = rect.insetBy(dx: padding, dy: padding)
        // Top-level folders get a title strip with their name, like a group label.
        if depth == 1 && rect.width >= 70 && rect.height >= 48 {
            let header = TreemapBuilder.headerHeight
            inner = CGRect(x: rect.minX + padding, y: rect.minY + header,
                           width: rect.width - 2 * padding, height: rect.height - header - padding)
            tiles[index].header = header
        }
        guard inner.width > minSide, inner.height > minSide else { return }

        let rects = Squarify.layout(items.map(metric), in: inner)
        var drewChild = false
        for (offset, child) in items.enumerated() {
            let childRect = rects[offset]
            guard childRect.width >= minSide, childRect.height >= minSide else { continue }
            drewChild = true
            let childBranch = depth == 0 ? offset : branch
            add(child, rect: childRect, depth: depth + 1, branch: childBranch, maxDepth: maxDepth,
                minSide: minSide, metric: metric, into: &tiles)
        }
        tiles[index].isLeaf = !drewChild
    }
}

/// What a treemap layout depends on. When any of it changes, the tiles are laid out again.
struct TreemapLayoutKey: Equatable {
    let node: ObjectIdentifier
    let version: Int
    let size: CGSize
    let depth: Int
    let minTile: Double
    let mode: SizeMode
}

/// TreeSize-style treemap: nested tiles, area = size, colored by depth or by top-level folder.
///
/// The tiles are laid out inside the Canvas, from the size the Canvas is drawn at, and kept in a
/// cache that never triggers a redraw. Nothing measures the view and writes the size back into
/// state, so the layout can't feed back into itself.
///
/// Drawing every tile and its label takes around 12 ms, so the tiles are drawn by a view of their
/// own (`TreemapTiles`) that redraws only when they change. The highlight that follows the mouse
/// is drawn on top by a separate, tiny Canvas.
struct TreemapView: View {
    @ObservedObject var model: AppModel
    let node: Node
    let settings: DisplaySettings

    @AppStorage(Prefs.treemapDepth) private var maxDepth: Int = 6
    @AppStorage(Prefs.treemapMinTile) private var minTile: Double = 6
    @AppStorage(Prefs.treemapCushion) private var cushion: Bool = true
    @AppStorage(Prefs.treemapColoring) private var coloring: TreemapColoring = .branch

    @StateObject private var state = TreemapState()

    private var scope: Node { node.directory }

    var body: some View {
        let hoveredTile = state.hoveredTile
        VStack(spacing: 0) {
            TreemapTiles(state: state, scope: scope, version: model.version, settings: settings,
                         maxDepth: maxDepth, minTile: minTile, cushion: cushion, coloring: coloring)
                .equatable()
                .overlay {
                    Canvas { context, _ in
                        guard let rect = hoveredTile?.tile.rect else { return }
                        let radius: CGFloat = hoveredTile?.tile.depth == 1 ? 5 : 3
                        let path = Path(roundedRect: rect, cornerRadius: min(radius, rect.width / 3, rect.height / 3))
                        context.fill(path, with: .color(.white.opacity(0.18)))
                        context.stroke(path, with: .color(.white), lineWidth: 2)
                    }
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): state.hover(at: location)
                    case .ended: state.endHover()
                    }
                }
                .onTapGesture(count: 2) { location in
                    guard let tile = state.tile(at: location) else { return }
                    let target = tile.node.kind == .files ? (tile.node.parent ?? tile.node) : tile.node
                    model.navigate(to: target)
                }
                .contextMenu {
                    if let tile = state.hoveredTile?.tile {
                        let target = tile.node
                        if target.kind == .directory && target !== scope {
                            Button("Show Contents") { model.navigate(to: target) }
                            Divider()
                        }
                        Button("Reveal in Finder") { FileActions.reveal(target.path) }
                        Button("Copy Path") { FileActions.copyPath(target.path) }
                    }
                }
            Divider()
            footer(hoveredTile?.tile)
        }
    }

    private func footer(_ tile: TreemapTile?) -> some View {
        HStack(spacing: 8) {
            if let tile {
                Text(tile.node.kind == .files
                     ? "Files directly in \(PathDisplay.friendly(tile.node.path))"
                     : PathDisplay.friendly(tile.node.path))
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(settings.label(for: tile.node))
                    .monospacedDigit()
            } else {
                Text("Double-click a tile to open it. Right-click for more.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// The tiles of the treemap and their labels. Equatable on what it draws, so SwiftUI redraws it
/// only when that changes: not when the mouse moves, nor when something elsewhere in the window does.
private struct TreemapTiles: View, Equatable {
    /// Holds the layout cache, which drawing fills in. Not observed: the hover it publishes is
    /// drawn by `TreemapView`.
    let state: TreemapState
    let scope: Node
    let version: Int
    let settings: DisplaySettings
    let maxDepth: Int
    let minTile: Double
    let cushion: Bool
    let coloring: TreemapColoring

    /// `state` is left out: it belongs to the one `TreemapView` this is part of, so it never changes.
    nonisolated static func == (a: TreemapTiles, b: TreemapTiles) -> Bool {
        a.scope === b.scope && a.version == b.version && a.settings == b.settings
            && a.maxDepth == b.maxDepth && a.minTile == b.minTile && a.cushion == b.cushion && a.coloring == b.coloring
    }

    var body: some View {
        Canvas { context, size in
            draw(layout(for: size), in: &context)
        }
    }

    private func layout(for size: CGSize) -> [TreemapTile] {
        let key = TreemapLayoutKey(node: scope.id, version: version, size: size,
                                   depth: max(1, maxDepth), minTile: max(2, minTile), mode: settings.mode)
        let mode = settings.mode
        let scope = self.scope
        return state.layoutTiles(for: key) {
            guard size.width > 4, size.height > 4 else { return [] }
            let metric: (Node) -> Double = { node in
                switch mode {
                case .files: return Double(node.fileCount)
                case .size: return Double(node.size)
                case .allocated, .percent: return Double(node.allocated)
                }
            }
            return TreemapBuilder.tiles(for: scope, in: CGRect(origin: .zero, size: size),
                                        maxDepth: key.depth, minSide: CGFloat(key.minTile), metric: metric)
        }
    }

    /// The colour of a tile: its top-level folder's colour (or blue, when colouring by depth),
    /// lighter the deeper it sits. A folder's loose files get a quiet version of that colour.
    private func color(for tile: TreemapTile) -> Color {
        let depthFactor = min(1, Double(max(0, tile.depth - 1)) / Double(max(1, maxDepth - 1)))
        let swatch: Theme.Swatch
        switch coloring {
        case .depth: swatch = Theme.swatch(0)
        case .branch: swatch = tile.branch >= 0 ? Theme.swatch(tile.branch) : Theme.neutral
        }
        if tile.node.kind == .files { return swatch.muted }
        return swatch.lightened(0.5 * depthFactor)
    }

    private func draw(_ tiles: [TreemapTile], in context: inout GraphicsContext) {
        let gap = Color(nsColor: .windowBackgroundColor)
        for tile in tiles where tile.depth > 0 {
            let radius: CGFloat = tile.depth == 1 ? 5 : 3
            let path = Path(roundedRect: tile.rect, cornerRadius: min(radius, tile.rect.width / 3, tile.rect.height / 3))
            context.fill(path, with: .color(color(for: tile)))
            if cushion && tile.isLeaf && tile.rect.width > 6 && tile.rect.height > 6 {
                // A soft light from the top: depth without the muddy look of full cushion shading.
                let shine = Gradient(colors: [.white.opacity(0.22), .white.opacity(0)])
                context.fill(path, with: .linearGradient(shine,
                                                         startPoint: CGPoint(x: tile.rect.midX, y: tile.rect.minY),
                                                         endPoint: CGPoint(x: tile.rect.midX, y: tile.rect.maxY)))
            }
            context.stroke(path, with: .color(gap), lineWidth: tile.depth == 1 ? 1.5 : 1)
        }

        // Labels, with a soft shadow so white text stays readable on light tiles.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.2, y: 0.5))
            for tile in tiles where tile.depth > 0 {
                if tile.header > 0 {
                    let strip = CGRect(x: tile.rect.minX + 7, y: tile.rect.minY + 2,
                                       width: tile.rect.width - 14, height: tile.header - 3)
                    drawLabel(name: tile.node.name, detail: settings.label(for: tile.node),
                              in: strip, size: 11, weight: .semibold, layer: &layer)
                } else if tile.isLeaf && tile.rect.width > 60 && tile.rect.height > 22 {
                    let box = tile.rect.insetBy(dx: 6, dy: 4)
                    drawLabel(name: tile.node.name, detail: nil,
                              in: CGRect(x: box.minX, y: box.minY, width: box.width, height: 14),
                              size: 10, weight: .medium, layer: &layer)
                    if tile.rect.height > 38 {
                        drawText(settings.label(for: tile.node), size: 9, weight: .regular, opacity: 0.85,
                                 at: CGPoint(x: box.minX, y: box.minY + 14), width: box.width, layer: &layer)
                    }
                }
            }
        }
    }

    /// Draws "name  detail" on one line if it fits, otherwise the name alone, shortened if needed.
    private func drawLabel(name: String, detail: String?, in box: CGRect, size: CGFloat,
                           weight: Font.Weight, layer: inout GraphicsContext) {
        guard box.width > 12 else { return }
        let nameText = Text(name).font(.system(size: size, weight: weight)).foregroundColor(.white)
        let nameOnly = layer.resolve(nameText)
        let nameWidth = nameOnly.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: box.height)).width
        if let detail {
            let detailText = Text("  " + detail).font(.system(size: size - 1, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
            let both = layer.resolve(nameText + detailText)
            if both.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: box.height)).width <= box.width {
                layer.draw(both, at: CGPoint(x: box.minX, y: box.midY), anchor: .leading)
                return
            }
        }
        if nameWidth <= box.width {
            layer.draw(nameOnly, at: CGPoint(x: box.minX, y: box.midY), anchor: .leading)
            return
        }
        // Shorten the name to fit, keeping its start.
        var characters = Int(Double(name.count) * Double(box.width / nameWidth)) - 1
        while characters > 1 {
            let short = layer.resolve(Text(String(name.prefix(characters)) + "…")
                .font(.system(size: size, weight: weight)).foregroundColor(.white))
            if short.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: box.height)).width <= box.width {
                layer.draw(short, at: CGPoint(x: box.minX, y: box.midY), anchor: .leading)
                return
            }
            characters -= 1
        }
    }

    private func drawText(_ string: String, size: CGFloat, weight: Font.Weight, opacity: Double,
                          at origin: CGPoint, width: CGFloat, layer: inout GraphicsContext) {
        let text = layer.resolve(Text(string).font(.system(size: size, weight: weight)).foregroundColor(.white.opacity(opacity)))
        guard text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)).width <= width else { return }
        layer.draw(text, at: origin, anchor: .topLeading)
    }
}

/// View state for TreemapView, kept in a class so it builds without SwiftUI's macros.
/// Only the hovered tile is published; the tile cache is filled while drawing and must not
/// cause another redraw.
final class TreemapState: ObservableObject {
    struct Hover: Equatable {
        let index: Int
        let generation: Int
    }

    @Published private var hovering: Hover?
    private(set) var tiles: [TreemapTile] = []
    private var key: TreemapLayoutKey?
    private var generation = 0

    /// The tiles for a layout, recomputed only when the layout key changes.
    func layoutTiles(for newKey: TreemapLayoutKey, build: () -> [TreemapTile]) -> [TreemapTile] {
        if newKey != key {
            key = newKey
            tiles = build()
            generation += 1
        }
        return tiles
    }

    /// The hovered tile, if it belongs to the tiles currently drawn.
    var hoveredTile: (index: Int, tile: TreemapTile)? {
        guard let hovering, hovering.generation == generation, tiles.indices.contains(hovering.index) else { return nil }
        return (hovering.index, tiles[hovering.index])
    }

    func hover(at point: CGPoint) {
        let next = index(at: point).map { Hover(index: $0, generation: generation) }
        if next != hovering { hovering = next }
    }

    func endHover() {
        if hovering != nil { hovering = nil }
    }

    func tile(at point: CGPoint) -> TreemapTile? {
        index(at: point).map { tiles[$0] }
    }

    /// The deepest tile under a point (tiles are stored parents first).
    private func index(at point: CGPoint) -> Int? {
        for index in tiles.indices.reversed() where tiles[index].rect.contains(point) {
            return index
        }
        return nil
    }
}
