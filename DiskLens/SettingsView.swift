import SwiftUI

/// The Settings window (DiskLens ▸ Settings…, ⌘,).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    private var prefs = DisplayPrefs()

    @AppStorage(Prefs.treemapDepth) private var treemapDepth: Int = 6
    @AppStorage(Prefs.treemapMinTile) private var treemapMinTile: Double = 6
    @AppStorage(Prefs.treemapCushion) private var treemapCushion: Bool = true
    @AppStorage(Prefs.treemapColoring) private var treemapColoring: TreemapColoring = .branch
    @AppStorage(Prefs.topFilesCount) private var topFilesCount: Int = 100

    var body: some View {
        TabView {
            sizes.tabItem { Label("Sizes", systemImage: "ruler") }
            tree.tabItem { Label("Tree", systemImage: "list.bullet.indent") }
            treemap.tabItem { Label("Treemap", systemImage: "square.grid.3x3.square") }
            scanning.tabItem { Label("Scanning", systemImage: "magnifyingglass") }
        }
        .frame(width: 560, height: 420)
    }

    private var sizes: some View {
        Form {
            Picker("Show", selection: prefs.$mode) {
                ForEach(SizeMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text(prefs.mode.help).font(.caption).foregroundStyle(.secondary)
            Picker("Unit", selection: prefs.$unit) {
                ForEach(SizeUnit.allCases) { unit in Text(unit.title).tag(unit) }
            }
            Picker("Unit system", selection: prefs.$base) {
                ForEach(UnitBase.allCases) { base in Text(base.title).tag(base) }
            }
            Stepper(value: prefs.$decimals, in: 0...3) {
                Text("Decimal places: \(prefs.decimals)")
            }
            Text("Example: " + SizeFormat.bytes(1_234_567_890, unit: prefs.unit, base: prefs.base, decimals: prefs.decimals))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var tree: some View {
        Form {
            Toggle("Show size bars", isOn: prefs.$showBars)
            Picker("Bar length relative to", selection: prefs.$barScale) {
                ForEach(BarScale.allCases) { scale in Text(scale.title).tag(scale) }
            }
            ColorPicker("Bar color (left)", selection: prefs.$barStartHex.asColor, supportsOpacity: true)
            ColorPicker("Bar color (right)", selection: prefs.$barEndHex.asColor, supportsOpacity: true)
            Button("Reset bar colors") {
                prefs.barStartHex = Prefs.defaultBarStart
                prefs.barEndHex = Prefs.defaultBarEnd
            }
            Stepper(value: prefs.$boldPercent, in: 0...100, step: 1) {
                Text(prefs.boldPercent > 0
                     ? "Bold folders using at least \(Int(prefs.boldPercent)) % of the scan"
                     : "Never bold folders")
            }
            Picker("Hide items smaller than", selection: prefs.$hideBelowMB) {
                Text("Show everything").tag(0.0)
                Text("1 MB").tag(1.0)
                Text("10 MB").tag(10.0)
                Text("100 MB").tag(100.0)
                Text("1 GB").tag(1_000.0)
                Text("10 GB").tag(10_000.0)
            }
            Toggle("Show a [Files] entry for each folder's loose files", isOn: prefs.$showFilesNode)
            Toggle("Sort by name instead of size", isOn: prefs.$sortByName)
        }
        .formStyle(.grouped)
    }

    private var treemap: some View {
        Form {
            Stepper(value: $treemapDepth, in: 1...12) {
                Text("Levels shown: \(treemapDepth)")
            }
            VStack(alignment: .leading) {
                Slider(value: $treemapMinTile, in: 2...40, step: 1) {
                    Text("Smallest tile")
                }
                Text("Tiles smaller than \(Int(treemapMinTile)) points are not drawn. Lower shows more detail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Cushion shading", isOn: $treemapCushion)
            Picker("Colors", selection: $treemapColoring) {
                ForEach(TreemapColoring.allCases) { coloring in Text(coloring.title).tag(coloring) }
            }
        }
        .formStyle(.grouped)
    }

    private var scanning: some View {
        Form {
            Stepper(value: $topFilesCount, in: 10...2_000, step: 10) {
                Text("Largest files to list: \(topFilesCount)")
            }
            Text("Applies to the next scan.").font(.caption).foregroundStyle(.secondary)

            LabeledContent("Full Disk Access") {
                HStack {
                    Text(model.fullDiskAccess ? "On" : "Off")
                        .foregroundStyle(model.fullDiskAccess ? Color.green : Color.orange)
                    Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                    Button("Check Again") { model.fullDiskAccess = FullDiskAccess.isGranted }
                }
            }
            Text("After turning it on, quit and reopen DiskLens.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("How sizes are counted") {
                Text("“On Disk” is the space files really occupy, so cloud-only, sparse and compressed files count correctly. Hard-linked files count once. Scans stay on one disk and don't follow symbolic links. Totals can still differ from System Settings, which also counts local snapshots and purgeable space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
