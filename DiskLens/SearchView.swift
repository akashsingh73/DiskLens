import SwiftUI
import AppKit

/// Search state: the query, the results, and the background work behind them. Kept apart from
/// AppModel (like ScanStatus) so typing and results streaming in redraw only the search panel.
/// Main thread only; the matching itself runs on background threads (see Search.swift).
@MainActor
final class SearchModel: ObservableObject {
    @Published var isPresented = false {
        didSet { if !isPresented && oldValue { closed() } }
    }
    @Published var text = "" {
        didSet { if text != oldValue { refresh(debounce: true) } }
    }
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var folderMatches = 0
    @Published private(set) var fileMatches = 0
    /// From the moment the text changes until every folder has been read for files (or the search stops).
    @Published private(set) var lookingForFiles = false
    /// While folders are being read for files: how many of them have been read (0…1).
    @Published private(set) var reading: Double?
    /// True once every folder has been read for files, so the counts are complete.
    @Published private(set) var filesComplete = false
    /// The folder and Top Files results for the current text haven't come back yet.
    @Published private(set) var searching = false
    /// The result Return goes to, moved with the arrow keys.
    @Published var highlighted: SearchHit.ID?
    /// Changes when ⌘F is pressed while the panel is already open, to put the cursor back in the field.
    @Published private(set) var focusRequest = 0

    weak var app: AppModel?

    private struct IndexKey: Equatable {
        let result: ObjectIdentifier
        let version: Int
    }

    private struct ResultsKey: Equatable {
        let index: IndexKey
        let query: SearchQuery
        let bySize: Bool
    }

    private var index: SearchIndex?
    /// The folders' nodes in index order, for turning a hit back into a folder.
    private var nodes: [Node] = []
    private var indexKey: IndexKey?
    private var resultsKey: ResultsKey?
    private var folderHits = LargestHits(capacity: 0, bySize: false)
    private var topFileHits = LargestHits(capacity: 0, bySize: false)
    private var task: Task<Void, Never>?
    /// Tells a finished search task apart from the one that replaced it.
    private var generation = 0
    private var fileSearch: FileSearch?

    /// ⌘F: opens the panel, or puts the cursor back in its field.
    func show() {
        guard let app, app.result != nil, !app.isReadingTree else {
            NSSound.beep()
            return
        }
        if isPresented {
            focusRequest += 1
        } else {
            _ = currentIndex()      // so the results kept from last time can say where they are
            isPresented = true
        }
        refresh(debounce: false)
    }

    /// A new scan started: close the panel, keep the text.
    func scanStarted() {
        isPresented = false
        stop()
    }

    /// A new scan replaced the tree: forget everything that pointed into the old one.
    func scanChanged() {
        stop()
        releaseIndex()
        resultsKey = nil
        clearResults()
    }

    /// The panel closed: stop reading folders, and free the index (tens of megabytes for a whole
    /// disk). The results stay for next time; the same tree always gives the same index.
    private func closed() {
        stop()
        releaseIndex()
    }

    private func releaseIndex() {
        index = nil
        nodes = []
        indexKey = nil
    }

    /// Searches again if the text, the scan or the size mode changed since the results shown were
    /// found, or if reading folders for files was stopped before it finished.
    func refresh(debounce: Bool) {
        guard isPresented, let app, let result = app.result, !app.isReadingTree else {
            stop()
            return
        }
        let query = SearchQuery(text)
        let key = ResultsKey(index: IndexKey(result: ObjectIdentifier(result), version: app.version),
                             query: query, bySize: Self.bySize)
        if key == resultsKey && (filesComplete || task != nil) { return }
        stop()
        resultsKey = key
        guard !query.isEmpty else {
            clearResults()
            return
        }
        searching = true
        lookingForFiles = true
        generation += 1
        let current = generation
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 90_000_000) }
            if !Task.isCancelled { await self?.run(query, key: key) }
            self?.ended(current)
        }
    }

    private func ended(_ finished: Int) {
        guard finished == generation else { return }
        task = nil
        searching = false
    }

    /// Goes to a result: its folder, or for a file the folder it is in, with the file selected in Details.
    func choose(_ hit: SearchHit) {
        guard let app, let result = app.result,
              indexKey == IndexKey(result: ObjectIdentifier(result), version: app.version) else {
            refresh(debounce: false)
            return
        }
        let folder: Node?
        if hit.folder >= 0 && Int(hit.folder) < nodes.count {
            folder = nodes[Int(hit.folder)]
        } else {
            folder = result.root.descendant(atPath: (hit.path as NSString).deletingLastPathComponent)
        }
        guard let folder else {
            NSSound.beep()
            return
        }
        highlighted = hit.id
        isPresented = false
        switch hit.kind {
        case .folder: app.navigate(to: folder)
        case .file: app.navigate(to: folder, highlightingFile: hit.path)
        }
    }

    /// Moves the highlight up (-1) or down (+1) the list.
    func moveHighlight(_ step: Int) {
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : hits.count)
        highlighted = hits[min(hits.count - 1, max(0, current + step))].id
    }

    /// Where a result sits inside the scan ("Library › … › Caches").
    func location(of hit: SearchHit) -> String {
        index?.location(of: hit) ?? ""
    }

    // MARK: - Searching

    private static var bySize: Bool {
        UserDefaults.standard.string(forKey: Prefs.sizeMode) == SizeMode.size.rawValue
    }

    private func run(_ query: SearchQuery, key: ResultsKey) async {
        guard let index = currentIndex(), indexKey == key.index else { return }
        let bySize = key.bySize

        // Folders and Top Files: in memory, so they come back at once.
        let quick = await Task.detached(priority: .userInitiated) {
            (ScanSearch.folders(in: index, matching: query, bySize: bySize),
             ScanSearch.topFiles(in: index, matching: query, bySize: bySize))
        }.value
        guard !Task.isCancelled else { return }
        folderHits = quick.0
        topFileHits = quick.1
        searching = false
        publish(nil, bySize: bySize)

        // Other files: read the folders again, after a short pause so that typing a word doesn't
        // start a pass for every letter. Results stream in while it reads.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let search = FileSearch(index: index, query: query, bySize: bySize)
        fileSearch = search
        reading = 0
        DispatchQueue.global(qos: .userInitiated).async { search.run() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, fileSearch === search else { return }
            let snapshot = search.snapshot()
            publish(snapshot, bySize: bySize)
            if snapshot.finished { break }
        }
        if fileSearch === search { fileSearch = nil }
    }

    private func publish(_ snapshot: FileSearch.Snapshot?, bySize: Bool) {
        var files = [topFileHits]
        if let snapshot { files.insert(snapshot.found, at: 0) }   // first, so its copy of a Top File is kept
        hits = ScanSearch.merge(folders: folderHits, files: files, bySize: bySize)
        folderMatches = folderHits.matched
        if let snapshot {
            fileMatches = snapshot.finished ? snapshot.found.matched : max(snapshot.found.matched, topFileHits.matched)
            filesComplete = snapshot.finished
            reading = snapshot.finished ? nil : snapshot.fraction
            if snapshot.finished { lookingForFiles = false }
        } else {
            fileMatches = topFileHits.matched
            filesComplete = false
        }
        if highlighted == nil || !hits.contains(where: { $0.id == highlighted }) {
            highlighted = hits.first?.id
        }
    }

    /// The index for the scan as it is now, built when the panel opens and again after anything is
    /// moved to the Trash. Building reads the tree, so it happens here on the main thread (tens of
    /// milliseconds for most of a million folders).
    private func currentIndex() -> SearchIndex? {
        guard let app, let result = app.result else { return nil }
        let key = IndexKey(result: ObjectIdentifier(result), version: app.version)
        if key != indexKey || index == nil {
            let built = SearchIndex.build(root: result.root, rootPath: result.rootPath,
                                          rootName: result.displayName, topFiles: result.topFiles)
            index = built.index
            nodes = built.nodes
            indexKey = key
        }
        return index
    }

    /// Stops looking. Results found so far stay on screen.
    private func stop() {
        task?.cancel()
        task = nil
        fileSearch?.cancel()
        fileSearch = nil
        searching = false
        lookingForFiles = false
        reading = nil
    }

    private func clearResults() {
        hits = []
        folderMatches = 0
        fileMatches = 0
        filesComplete = false
        highlighted = nil
    }
}

// MARK: - The search field in the command bar

/// Looks like a search field; clicking it (or ⌘F) opens the search panel below it.
struct SearchButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: SearchModel
    @StateObject private var hover = HoverState()

    var body: some View {
        let enabled = model.result != nil && !model.isReadingTree
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button {
            search.show()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(search.text.isEmpty ? "Search" : search.text)
                    .foregroundStyle(search.text.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘F")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(width: 180, height: 24)
            .background(shape.fill(Color.primary.opacity(hover.isHovering && enabled ? 0.08 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(search.isPresented ? 0.25 : 0.10), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hover.isHovering = $0 }
        .help("Find folders and files by name in this scan (⌘F)")
        .accessibilityLabel("Search")
        .popover(isPresented: $search.isPresented, arrowEdge: .bottom) {
            SearchPanel(model: model, search: search)
        }
    }
}

// MARK: - The search panel

struct SearchPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: SearchModel
    @FocusState private var fieldFocused: Bool
    @AppStorage("detailTab") private var tab: DetailTab = .details
    private var prefs = DisplayPrefs()

    init(model: AppModel, search: SearchModel) {
        self.model = model
        self.search = search
    }

    var body: some View {
        let settings = prefs.settings
        VStack(spacing: 0) {
            field
            Divider()
            results(settings)
            Divider()
            footer
        }
        .frame(width: 620, height: 470)
        .onAppear { fieldFocused = true }
        .onChange(of: search.focusRequest) { fieldFocused = true }
        .onChange(of: settings.mode) { search.refresh(debounce: false) }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("Search folders and files in \(model.result?.displayName ?? "this scan")", text: $search.text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { go(nil) }
                .onKeyPress(.downArrow) {
                    search.moveHighlight(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    search.moveHighlight(-1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Like Spotlight: Escape clears the text first, then closes.
                    guard !search.text.isEmpty else { return .ignored }
                    search.text = ""
                    return .handled
                }
            if !search.text.isEmpty {
                Button {
                    search.text = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    @ViewBuilder
    private func results(_ settings: DisplaySettings) -> some View {
        let query = SearchQuery(search.text)
        if query.isEmpty {
            hint
        } else if search.hits.isEmpty {
            if search.searching || search.lookingForFiles {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(search.searching ? "Searching…" : "Looking for files…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query.text)
            }
        } else {
            let total = max(1, model.result.map { settings.mode == .size ? $0.root.size : $0.root.allocated } ?? 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(search.hits) { hit in
                            SearchRow(hit: hit, location: search.location(of: hit), words: query.words,
                                      settings: settings, total: total,
                                      highlighted: hit.id == search.highlighted) { go(hit) }
                                .id(hit.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: search.highlighted) {
                    if let id = search.highlighted { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var hint: some View {
        VStack(spacing: 12) {
            IconBadge(systemImage: "magnifyingglass", size: 40)
            Text("Find folders and files by name")
                .font(.headline)
            Text("Type part of a name, or several words in any order. Case and accents don't matter, and “.dmg” finds every disk image. Folders and Top Files show up at once; other files turn up as DiskLens reads the scanned folders again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !SearchQuery(search.text).isEmpty {
                Text(countsText)
                    .monospacedDigit()
                    .lineLimit(1)
                if let reading = search.reading {
                    ProgressView(value: reading)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("Reading folders… \(SizeFormat.percent(reading, decimals: 0))")
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(search.hits.count < search.folderMatches + search.fileMatches && !search.hits.isEmpty
                 ? "Showing the \(SizeFormat.count(search.hits.count)) largest"
                 : "↑↓ to choose, Return to show")
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var countsText: String {
        let folders = SizeFormat.count(search.folderMatches, "folder")
        let files = SizeFormat.count(search.fileMatches, "file")
        if search.searching { return "Searching…" }
        return search.filesComplete ? "\(folders) · \(files)" : "\(folders) · \(files) so far"
    }

    /// Goes to a result (or the highlighted one). Results that are only shown in Details (files) or
    /// that a whole-scan view wouldn't show switch the view to Details.
    private func go(_ hit: SearchHit?) {
        guard let target = hit ?? search.hits.first(where: { $0.id == search.highlighted }) ?? search.hits.first else {
            NSSound.beep()
            return
        }
        if target.kind == .file || ![.details, .treemap, .chart].contains(tab) {
            tab = .details
        }
        search.choose(target)
    }
}

/// One result: icon, name (with the words searched for in bold), where it is, and its size.
private struct SearchRow: View {
    let hit: SearchHit
    let location: String
    let words: [String]
    let settings: DisplaySettings
    let total: Int64
    let highlighted: Bool
    let action: @MainActor () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        let measure = hit.measure(bySize: settings.mode == .size)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(name: hit.name, path: hit.path, isFolder: hit.kind == .folder))
                    .resizable()
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(hit.counted ? location : location + " · hard link, counted elsewhere")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(settings.bytes(measure))
                        .monospacedDigit()
                    ShareBar(fraction: Double(measure) / Double(total), height: 4)
                        .frame(width: 56)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? Color.accentColor.opacity(0.16)
                                  : Color.primary.opacity(hover.isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .help(PathDisplay.friendly(hit.path))
        .contextMenu {
            Button("Show in DiskLens") { action() }
            Button("Reveal in Finder") { FileActions.reveal(hit.path) }
            Button("Copy Path") { FileActions.copyPath(hit.path) }
        }
    }

    /// The name with each searched word in bold where it appears.
    private var name: AttributedString {
        var text = AttributedString(hit.name)
        for word in words {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text[start...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
                text[range].inlinePresentationIntent = .stronglyEmphasized
                start = range.upperBound
            }
        }
        return text
    }
}
