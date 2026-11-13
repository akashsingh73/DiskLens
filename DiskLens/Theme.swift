import SwiftUI
import AppKit

/// DiskLens's visual language: one colour palette shared by the charts and the treemap,
/// card and chip styles, and an SF Symbol for each kind of thing.
enum Theme {
    /// A colour as hue, saturation and brightness, so the treemap can make lighter shades of it.
    struct Swatch {
        let hue: Double
        let saturation: Double
        let brightness: Double

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

        /// A quiet version of the colour, for a folder's loose files in the treemap.
        var muted: Color { Color(hue: hue, saturation: saturation * 0.32, brightness: brightness * 0.9) }

        /// Softer and lighter by `amount` (0…1), for treemap tiles deeper in the tree.
        func lightened(_ amount: Double) -> Color {
            let t = min(1, max(0, amount))
            return Color(hue: hue,
                         saturation: saturation * (1 - 0.45 * t),
                         brightness: min(1, brightness + (1 - brightness) * 0.7 * t))
        }
    }

    /// Distinct hues of similar weight that read well on light and dark backgrounds.
    static let swatches: [Swatch] = [
        Swatch(hue: 0.60, saturation: 0.68, brightness: 0.93),  // blue
        Swatch(hue: 0.08, saturation: 0.72, brightness: 0.97),  // orange
        Swatch(hue: 0.43, saturation: 0.62, brightness: 0.74),  // green
        Swatch(hue: 0.96, saturation: 0.58, brightness: 0.92),  // rose
        Swatch(hue: 0.74, saturation: 0.50, brightness: 0.88),  // violet
        Swatch(hue: 0.51, saturation: 0.72, brightness: 0.76),  // teal
        Swatch(hue: 0.13, saturation: 0.74, brightness: 0.95),  // amber
        Swatch(hue: 0.67, saturation: 0.52, brightness: 0.86),  // indigo
        Swatch(hue: 0.02, saturation: 0.55, brightness: 0.86),  // coral
        Swatch(hue: 0.27, saturation: 0.55, brightness: 0.72),  // lime
        Swatch(hue: 0.55, saturation: 0.55, brightness: 0.92),  // sky
        Swatch(hue: 0.85, saturation: 0.45, brightness: 0.85),  // orchid
    ]

    static func swatch(_ index: Int) -> Swatch {
        swatches[((index % swatches.count) + swatches.count) % swatches.count]
    }

    static func color(_ index: Int) -> Color { swatch(index).color }

    /// "Other" slices and a folder's loose files.
    static let neutral = Swatch(hue: 0.62, saturation: 0.06, brightness: 0.62)

    /// Fresh to old, green through amber to red, for the Ages view.
    static func ageColor(_ band: Int, of count: Int) -> Color {
        let t = count > 1 ? Double(band) / Double(count - 1) : 0
        return Color(hue: 0.38 * (1 - t), saturation: 0.62, brightness: 0.86)
    }

    static let cornerRadius: CGFloat = 10
}

/// Whether the pointer is over a view. A class with `@StateObject` instead of `@State`, because
/// `@State` is a macro and the Command Line Tools don't ship the plugin it needs.
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

// MARK: - Cards

/// A rounded panel that lifts a group of related things off the window background.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 12
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tint.map { $0.opacity(0.10) } ?? Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.25), lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(CardStyle(padding: padding, tint: tint))
    }
}

// MARK: - Small pieces

/// An SF Symbol on a soft rounded square of its own colour.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.15)))
    }
}

/// A small capsule with an icon and a short fact ("12 folders").
struct Chip: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(text)
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// A section title with a tinted icon.
struct SectionTitle: View {
    let title: String
    let systemImage: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A coloured dot with a label, for legends.
struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

/// Part of a bar, from `from` to `to` (fractions of the width). Drawn from the space it is
/// given, so it needs no GeometryReader and can never feed a size back into layout.
struct RangeBar: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        let start = rect.minX + rect.width * CGFloat(min(1, max(0, from)))
        let end = rect.minX + rect.width * CGFloat(min(1, max(0, to)))
        guard end > start else { return Path() }
        return Path(CGRect(x: start, y: rect.minY, width: end - start, height: rect.height))
    }
}

/// A rounded bar showing one share of a whole, on a faint track.
struct ShareBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            RangeBar(from: 0, to: fraction)
                .fill(color)
                .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

// MARK: - Changes between scans

extension Theme {
    /// Orange where space was taken, green where it was freed, grey for no change.
    static func changeColor(_ change: Int64) -> Color {
        change > 0 ? Color.orange : (change < 0 ? Color.green : Color.secondary)
    }

    static func changeSymbol(_ change: Int64) -> String {
        change > 0 ? "arrow.up.right" : (change < 0 ? "arrow.down.right" : "equal")
    }

    /// "14:05" for today, "10 Nov" for this year, "10 Nov 2025" before that: when an earlier scan was.
    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

extension DisplaySettings {
    /// "+1.2 GB", "−300 MB", "+0 B".
    func signedBytes(_ change: Int64) -> String {
        (change >= 0 ? "+" : "−") + bytes(abs(change))
    }
}

/// A change in size with an arrow, coloured by direction: "↗ +1.2 GB" or "↘ −300 MB".
struct ChangeLabel: View {
    let change: Int64
    let settings: DisplaySettings

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.changeSymbol(change))
            Text(settings.signedBytes(change))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.changeColor(change))
        .lineLimit(1)
    }
}

// MARK: - File type groups

extension FileGroup {
    var symbol: String {
        switch self {
        case .images: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .code: return "curlybraces"
        case .apps: return "square.grid.2x2"
        case .other: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .images: return Theme.color(2)
        case .video: return Theme.color(3)
        case .audio: return Theme.color(1)
        case .documents: return Theme.color(0)
        case .archives: return Theme.color(6)
        case .code: return Theme.color(5)
        case .apps: return Theme.color(7)
        case .other: return Theme.neutral.color
        }
    }
}
