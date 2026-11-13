import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case details = "Details"
    case treemap = "Treemap"
    case chart = "Chart"
    case types = "File Types"
    case top = "Top Files"
    case ages = "Ages"
    case history = "History"
    var id: String { rawValue }

    /// ⌘1 … ⌘7 in the View menu.
    var key: Character {
        switch self {
        case .details: return "1"
        case .treemap: return "2"
        case .chart: return "3"
        case .types: return "4"
        case .top: return "5"
        case .ages: return "6"
        case .history: return "7"
        }
    }

    var symbol: String {
        switch self {
        case .details: return "list.bullet.rectangle"
        case .treemap: return "square.grid.3x3.square"
        case .chart: return "chart.pie"
        case .types: return "doc.on.doc"
        case .top: return "list.number"
        case .ages: return "clock"
        case .history: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// The main window: the command bar on top, the folder tree on the left, the views on the right.
///
/// The window deliberately has no SwiftUI toolbar and no NavigationSplitView (which always adds
/// one): version 1.0 crashed in a toolbar layout loop. A plain split view has no toolbar to loop.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    private var prefs = DisplayPrefs()
    @AppStorage("detailTab") private var tab: DetailTab = .details

    var body: some View {
        let settings = prefs.settings
        VStack(spacing: 0) {
            CommandBar(model: model)
            Divider()
            HSplitView {
                sidebar(settings)
                    .frame(minWidth: 270, idealWidth: 380, maxWidth: 760, maxHeight: .infinity)
                detail(settings)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.result?.displayName ?? "DiskLens")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isScanning else { return false }
            model.scan(path: url.path)
            return true
        }
        .alert("Couldn't scan", isPresented: $model.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorText)
        }
        .sheet(isPresented: $model.showingUnreadable) {
            if let result = model.result {
                UnreadableFoldersSheet(result: result) { model.showingUnreadable = false }
            }
        }
        .onAppear { model.installMouseNavigation() }
    }

    // MARK: Sidebar

    @ViewBuilder
    private func sidebar(_ settings: DisplaySettings) -> some View {
        let scanned = model.isScanning ? nil : model.result
        VStack(spacing: 0) {
            if !model.fullDiskAccess || scanned != nil {
                VStack(spacing: 10) {
                    if !model.fullDiskAccess { FullDiskAccessBanner(model: model) }
                    if let scanned {
                        SummaryCard(result: scanned, settings: settings, volume: model.volumeInfo,
                                    changes: model.changes) {
                            model.showingUnreadable = true
                        } showChanges: {
                            tab = .history
                        }
                    }
                }
                .padding(10)
            }
            if scanned != nil {
                Divider()
                TreeOutline(model: model, settings: settings)
            } else {
                RecentScansList(model: model, settings: settings)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ settings: DisplaySettings) -> some View {
        if model.isScanning {
            ScanProgressPanel(status: model.status, name: model.scanningName) { model.cancel() }
        } else if let result = model.result {
            let node = model.selection ?? result.root
            VStack(spacing: 0) {
                PathBar(node: node, settings: settings) { model.navigate(to: $0) }
                HStack {
                    TabBar(tab: $tab)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                Divider()
                Group {
                    switch tab {
                    case .details:
                        DetailsView(model: model, node: node, settings: settings)
                    case .treemap:
                        TreemapView(model: model, node: node, settings: settings)
                    case .chart:
                        ChartsView(model: model, node: node, settings: settings)
                    case .types:
                        FileTypesView(result: result, version: model.version, settings: settings)
                    case .top:
                        TopFilesView(model: model, result: result, settings: settings)
                    case .ages:
                        AgesView(result: result, version: model.version, settings: settings)
                    case .history:
                        HistoryView(model: model, settings: settings)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            WelcomePanel(model: model)
        }
    }
}

// MARK: - Tabs

/// The row of views on the right: an icon and a name for each. When the pane is too narrow, only
/// the selected view keeps its name, and when even that doesn't fit, all show icons only.
struct TabBar: View {
    @Binding var tab: DetailTab

    private enum Titles { case all, selected, none }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.all)
            row(.selected)
            row(.none)
        }
    }

    private func row(_ titles: Titles) -> some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { option in
                let showTitle = titles == .all || (titles == .selected && option == tab)
                TabButton(option: option, selected: tab == option, showTitle: showTitle) { tab = option }
            }
        }
        .fixedSize()
    }
}

private struct TabButton: View {
    let option: DetailTab
    let selected: Bool
    let showTitle: Bool
    let action: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: option.symbol)
                if showTitle { Text(option.rawValue) }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.14)
                                        : Color.primary.opacity(hover.isHovering ? 0.06 : 0))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help(option.rawValue + " (⌘" + String(option.key) + ")")
        .accessibilityLabel(option.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar pieces

/// The scan at a glance: its total, how much of the disk it is, and anything worth knowing.
struct SummaryCard: View {
    let result: ScanResult
    let settings: DisplaySettings
    let volume: AppModel.VolumeInfo?
    /// What changed since an earlier scan of the same folder, if there was one.
    let changes: FolderComparison?
    let showUnreadable: @MainActor () -> Void
    let showChanges: @MainActor () -> Void

    var body: some View {
        let root = result.root
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(systemImage: isVolume ? "internaldrive.fill" : "folder.fill", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Scanned in \(String(format: "%.1f", result.duration)) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(settings.bytes(root.allocated))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("on disk")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let changes {
                Button(action: showChanges) {
                    HStack(spacing: 6) {
                        ChangeLabel(change: changes.totalChange, settings: settings)
                        Text("since \(Theme.shortDate(changes.base.date))")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show which folders grew or shrank since the scan of \(changes.base.date.formatted(date: .abbreviated, time: .shortened))")
            }

            if let volume, volume.total > 0 {
                capacity(volume, scanned: root.allocated)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(root) }
                VStack(alignment: .leading, spacing: 6) { chips(root) }
            }

            if result.unreadableFolders > 0 || result.otherVolumeFolders > 0 || result.hardLinkDuplicates > 0 {
                Divider()
                notes
            }
        }
        .card()
    }

    @ViewBuilder
    private func chips(_ root: Node) -> some View {
        Chip(text: SizeFormat.count(root.fileCount, "file"), systemImage: "doc")
        Chip(text: SizeFormat.count(root.folderCount, "folder"), systemImage: "folder")
    }

    private func capacity(_ volume: AppModel.VolumeInfo, scanned: Int64) -> some View {
        let total = Double(volume.total)
        let used = Double(max(0, volume.total - volume.available))
        let scan = min(Double(scanned), used)
        return VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                RangeBar(from: 0, to: used / total).fill(Color.secondary.opacity(0.35))
                RangeBar(from: 0, to: scan / total).fill(Color.accentColor)
            }
            .clipShape(Capsule())
            .frame(height: 8)
            .help("This scan: \(settings.bytes(scanned)) · Rest of the disk in use: \(settings.bytes(Int64(used - scan))) · Free: \(settings.bytes(volume.available))")
            HStack(spacing: 10) {
                LegendDot(color: .accentColor, text: "This scan")
                LegendDot(color: Color.secondary.opacity(0.5), text: "Other")
                Spacer(minLength: 4)
                Text("\(settings.bytes(volume.available)) free of \(settings.bytes(volume.total))")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            if result.unreadableFolders > 0 {
                Button(action: showUnreadable) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text("\(SizeFormat.count(result.unreadableFolders, "folder")) couldn't be read")
                        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show which folders couldn't be read, and why")
            }
            if result.otherVolumeFolders > 0 {
                note(result.otherVolumeFolders == 1
                     ? "1 other disk inside was skipped"
                     : "\(SizeFormat.count(result.otherVolumeFolders)) other disks inside were skipped",
                     systemImage: "externaldrive")
            }
            if result.hardLinkDuplicates > 0 {
                note("\(SizeFormat.count(result.hardLinkDuplicates, "extra hard link")) counted once", systemImage: "link")
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func note(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var isVolume: Bool {
        let path = result.rootPath
        if path == "/" || path == "/System/Volumes/Data" { return true }
        let components = (path as NSString).pathComponents
        return components.count == 3 && components[1] == "Volumes"
    }
}

/// The sidebar before the first scan (and while scanning): folders scanned before.
struct RecentScansList: View {
    @ObservedObject var model: AppModel
    let settings: DisplaySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Recent Scans", systemImage: "clock.arrow.circlepath")
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)
            if model.recentScans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Folders you scan show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.recentScans, id: \.path) { entry in
                            RecentScanRow(entry: entry, settings: settings) { model.scan(path: entry.path) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(model.isScanning)
    }
}

private struct RecentScanRow: View {
    let entry: HistoryEntry
    let settings: DisplaySettings
    let action: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(systemImage: isVolume ? "internaldrive.fill" : "folder.fill", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(settings.bytes(entry.allocated)).monospacedDigit()
                        Text("·")
                        Text(entry.date, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .opacity(hover.isHovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover.isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help("Scan \(PathDisplay.friendly(entry.path)) again")
    }

    private var isVolume: Bool { entry.path == "/" || entry.path == "/System/Volumes/Data" }

    private var name: String {
        FileManager.default.displayName(atPath: isVolume ? "/" : entry.path)
    }
}

/// Shown at the top of the sidebar while DiskLens can't read protected folders.
struct FullDiskAccessBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access is off")
                    .font(.callout.weight(.semibold))
                Text("Protected folders are skipped, so totals may come out low.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Turn On…") { FullDiskAccess.openSettings() }
                        .controlSize(.small)
                    Button("Check Again") { model.fullDiskAccess = FullDiskAccess.isGranted }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.top, 3)
            }
        }
        .card(padding: 10, tint: .orange)
        .help("Turn on Full Disk Access for DiskLens in System Settings ▸ Privacy & Security, then quit and reopen DiskLens.")
    }
}

// MARK: - Scanning

struct ScanProgressPanel: View {
    @ObservedObject var status: ScanStatus
    let name: String
    let stop: @MainActor () -> Void

    var body: some View {
        let snapshot = status.snapshot
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(spacing: 4) {
                Text("Scanning \(name)")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(elapsedText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: 380)

            HStack(spacing: 12) {
                StatTile(value: SizeFormat.count(snapshot.files), label: "Files", systemImage: "doc")
                StatTile(value: SizeFormat.count(snapshot.folders), label: "Folders", systemImage: "folder")
                StatTile(value: SizeFormat.bytes(snapshot.bytes), label: "On disk", systemImage: "internaldrive")
            }
            .frame(maxWidth: 480)

            Label {
                Text(snapshot.currentPath.isEmpty ? " " : PathDisplay.friendly(snapshot.currentPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520)

            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var elapsedText: String {
        let seconds = max(0, Int(status.elapsed))
        return String(format: "%ld:%02ld elapsed", seconds / 60, seconds % 60)
    }
}

/// A big number with a label, for the scan progress.
struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Label(label, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12)
    }
}

// MARK: - Welcome

struct WelcomePanel: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.flexible(minimum: 150, maximum: 240), spacing: 12),
                           GridItem(.flexible(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                Text("See what's using your disk")
                    .font(.title.weight(.semibold))
                Text("Choose a place to scan, or drop any folder onto this window.")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(AppModel.quickTargets.enumerated()), id: \.element.id) { index, target in
                    TargetCard(title: target.title, subtitle: subtitle(for: target),
                               systemImage: target.systemImage + ".fill",
                               tint: Theme.color([0, 4, 5][index % 3])) {
                        model.scan(path: target.path)
                    }
                }
                TargetCard(title: "Choose Folder…", subtitle: "Any folder or disk",
                           systemImage: "folder.badge.plus", tint: Theme.color(1)) {
                    model.chooseFolder()
                }
            }
            .frame(maxWidth: 500)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(for target: AppModel.Target) -> String {
        if target.path == "/", let volume = AppModel.volumeInfo(at: "/") {
            return "\(SizeFormat.bytes(volume.available)) free of \(SizeFormat.bytes(volume.total))"
        }
        return (target.path as NSString).abbreviatingWithTildeInPath
    }
}

private struct TargetCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                IconBadge(systemImage: systemImage, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hover.isHovering ? tint.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: hover.isHovering ? 1.5 : 1))
            .shadow(color: .black.opacity(hover.isHovering ? 0.08 : 0.03), radius: hover.isHovering ? 6 : 2, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.isHovering)
    }
}

// MARK: - Unreadable folders

/// Lists the folders macOS kept DiskLens out of, and why.
struct UnreadableFoldersSheet: View {
    let result: ScanResult
    let close: @MainActor () -> Void

    var body: some View {
        let samples = result.unreadableSamples.map { PathDisplay.friendly($0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(systemImage: "lock.fill", tint: .orange, size: 32)
                Text("Folders DiskLens couldn't read")
                    .font(.title3.weight(.semibold))
            }
            Text("macOS kept DiskLens out of \(SizeFormat.count(result.unreadableFolders, "folder")), so what's inside them isn't counted. Most are app data that macOS protects (Mail, Messages, Safari, other users' folders). With Full Disk Access turned on, DiskLens can read nearly all of them; a few system folders stay closed to every app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(Array(samples.enumerated()), id: \.offset) { item in
                Label {
                    Text(item.element)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
            }
            if result.unreadableFolders > samples.count {
                Text("Showing the first \(SizeFormat.count(samples.count)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                Button("Copy List") { FileActions.copyText(samples.joined(separator: "\n")) }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}
