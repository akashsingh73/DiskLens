import SwiftUI
import AppKit

// MARK: - Choices

enum SizeMode: String, CaseIterable, Identifiable {
    case allocated, size, files, percent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocated: return "On Disk"
        case .size: return "Size"
        case .files: return "Files"
        case .percent: return "% of Parent"
        }
    }

    /// For the narrow switch above the folder tree.
    var shortTitle: String {
        switch self {
        case .allocated: return "On Disk"
        case .size: return "Size"
        case .files: return "Files"
        case .percent: return "%"
        }
    }

    var help: String {
        switch self {
        case .allocated: return "Space actually used on disk (like Finder's “on disk”)"
        case .size: return "What the files say they contain"
        case .files: return "Number of files"
        case .percent: return "Share of the parent folder's space on disk"
        }
    }
}

enum SizeUnit: String, CaseIterable, Identifiable {
    case auto, bytes, kilo, mega, giga, tera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .bytes: return "Bytes"
        case .kilo: return "KB"
        case .mega: return "MB"
        case .giga: return "GB"
        case .tera: return "TB"
        }
    }

    var exponent: Int? {
        switch self {
        case .auto: return nil
        case .bytes: return 0
        case .kilo: return 1
        case .mega: return 2
        case .giga: return 3
        case .tera: return 4
        }
    }
}

enum UnitBase: String, CaseIterable, Identifiable {
    case decimal, binary
    var id: String { rawValue }

    var title: String {
        switch self {
        case .decimal: return "Decimal: 1 KB = 1,000 bytes (like Finder)"
        case .binary: return "Binary: 1 KiB = 1,024 bytes (like Windows)"
        }
    }
}

enum BarScale: String, CaseIterable, Identifiable {
    case wholeScan, parent
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wholeScan: return "Whole scan (like TreeSize)"
        case .parent: return "Parent folder"
        }
    }
}

enum TreemapColoring: String, CaseIterable, Identifiable {
    case depth, branch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .depth: return "By depth"
        case .branch: return "By top-level folder"
        }
    }
}

/// What to do with folders that are only in the cloud (iCloud Drive, Google Drive, Dropbox…).
enum CloudFolderMode: String, CaseIterable, Identifiable {
    case read, skip
    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return "Read them after the scan, in the background"
        case .skip: return "Skip them"
        }
    }

    var help: String {
        switch self {
        case .read:
            return "Everything on this Mac shows up first. Then DiskLens fetches the folders that are only in the cloud from the internet and fills them in as they arrive; that can take a while for a big drive. Files that aren't downloaded count as 0 on disk (they take no space here) but show their size in Size mode."
        case .skip:
            return "Folders that are only in the cloud are marked and left unread: they take no space on this Mac. You can still read them from the summary above the folder tree."
        }
    }
}

// MARK: - Stored preferences

enum Prefs {
    static let sizeMode = "sizeMode"
    static let unit = "unit"
    static let unitBase = "unitBase"
    static let decimals = "decimals"
    static let showBars = "showBars"
    static let barScale = "barScale"
    static let barStart = "barStartHex"
    static let barEnd = "barEndHex"
    static let boldPercent = "boldPercent"
    static let hideBelowMB = "hideBelowMB"
    static let showFilesNode = "showFilesNode"
    static let sortByName = "sortByName"
    static let treemapDepth = "treemapDepth"
    static let treemapMinTile = "treemapMinTile"
    static let treemapCushion = "treemapCushion"
    static let treemapColoring = "treemapColoring"
    static let topFilesCount = "topFilesCount"

    static let defaultBarStart = "#7DBBFFFF"
    static let defaultBarEnd = "#3478F6FF"

    static let cloudFolders = "cloudFolders"

    static var cloudFolderMode: CloudFolderMode {
        UserDefaults.standard.string(forKey: cloudFolders).flatMap(CloudFolderMode.init(rawValue:)) ?? .read
    }

    static var topFilesCountValue: Int {
        let stored = UserDefaults.standard.integer(forKey: topFilesCount)
        return stored > 0 ? stored : 100
    }
}

/// A snapshot of every display preference, handed to views that draw sizes.
struct DisplaySettings: Equatable {
    var mode: SizeMode
    var unit: SizeUnit
    var base: UnitBase
    var decimals: Int
    var showBars: Bool
    var barScale: BarScale
    var barStartHex: String
    var barEndHex: String
    var boldPercent: Double
    var hideBelowMB: Double
    var showFilesNode: Bool
    var sortByName: Bool

    var hideBelowBytes: Int64 { Int64(hideBelowMB * 1_000_000) }
    var barStart: NSColor { NSColor(hex: barStartHex) ?? .systemBlue }
    var barEnd: NSColor { NSColor(hex: barEndHex) ?? .systemIndigo }

    func bytes(_ value: Int64) -> String {
        SizeFormat.bytes(value, unit: unit, base: base, decimals: decimals)
    }

    /// The number used for sorting and bar lengths in the current mode.
    func metric(_ node: Node) -> Double {
        switch mode {
        case .size: return Double(node.size)
        case .files: return Double(node.fileCount)
        case .allocated, .percent: return Double(node.allocated)
        }
    }

    /// The size text shown next to a node.
    func label(for node: Node) -> String {
        switch mode {
        case .allocated:
            return bytes(node.allocated)
        case .size:
            return bytes(node.size)
        case .files:
            return SizeFormat.count(node.fileCount) + (node.fileCount == 1 ? " file" : " files")
        case .percent:
            guard let parent = node.parent, parent.allocated > 0 else { return "100 %" }
            return SizeFormat.percent(Double(node.allocated) / Double(parent.allocated), decimals: decimals)
        }
    }
}

/// Reads all display preferences in a view, kept in sync with the Settings window.
struct DisplayPrefs: DynamicProperty {
    @AppStorage(Prefs.sizeMode) var mode: SizeMode = .allocated
    @AppStorage(Prefs.unit) var unit: SizeUnit = .auto
    @AppStorage(Prefs.unitBase) var base: UnitBase = .decimal
    @AppStorage(Prefs.decimals) var decimals: Int = 1
    @AppStorage(Prefs.showBars) var showBars: Bool = true
    @AppStorage(Prefs.barScale) var barScale: BarScale = .wholeScan
    @AppStorage(Prefs.barStart) var barStartHex: String = Prefs.defaultBarStart
    @AppStorage(Prefs.barEnd) var barEndHex: String = Prefs.defaultBarEnd
    @AppStorage(Prefs.boldPercent) var boldPercent: Double = 10
    @AppStorage(Prefs.hideBelowMB) var hideBelowMB: Double = 0
    @AppStorage(Prefs.showFilesNode) var showFilesNode: Bool = true
    @AppStorage(Prefs.sortByName) var sortByName: Bool = false

    var settings: DisplaySettings {
        DisplaySettings(mode: mode, unit: unit, base: base, decimals: decimals,
                        showBars: showBars, barScale: barScale,
                        barStartHex: barStartHex, barEndHex: barEndHex,
                        boldPercent: boldPercent, hideBelowMB: hideBelowMB,
                        showFilesNode: showFilesNode, sortByName: sortByName)
    }
}

// MARK: - Formatting

enum SizeFormat {
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ number: Int) -> String {
        countFormatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// A count with its noun: "1 file", "2,048 files". `plural` defaults to `singular` + "s".
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        count(number) + " " + (number == 1 ? singular : plural ?? singular + "s")
    }

    static func bytes(_ value: Int64, unit: SizeUnit = .auto, base: UnitBase = .decimal, decimals: Int = 1) -> String {
        let k: Double = base == .binary ? 1024 : 1000
        let names = base == .binary
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB"]
        var exponent = 0
        if let fixed = unit.exponent {
            exponent = fixed
        } else {
            var scaled = Double(abs(value))
            while scaled >= k && exponent < names.count - 1 {
                scaled /= k
                exponent += 1
            }
        }
        if exponent == 0 { return count(Int(value)) + " B" }
        let places = max(0, min(decimals, 3))
        let scaled = Double(value) / pow(k, Double(exponent))
        return String(format: "%.\(places)f", scaled) + " " + names[exponent]
    }

    static func percent(_ fraction: Double, decimals: Int = 1) -> String {
        let places = max(0, min(decimals, 3))
        return String(format: "%.\(places)f", fraction * 100) + " %"
    }
}

// MARK: - Colors stored as hex

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let red, green, blue, alpha: CGFloat
        if text.count == 8 {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return Prefs.defaultBarStart }
        func byte(_ component: CGFloat) -> Int { Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent),
                      byte(color.blueComponent), byte(color.alphaComponent))
    }
}

extension Binding where Value == String {
    /// Bridges a stored hex string to a SwiftUI color picker.
    var asColor: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(hex: wrappedValue) ?? .systemBlue) },
            set: { wrappedValue = NSColor($0).hexString }
        )
    }
}
