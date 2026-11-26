import SwiftUI
import AppKit

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Any number of windows (File ▸ New Window, ⌘N), each with a scan of its own.
        WindowGroup("DiskLens", id: ScanWindow.id) {
            ScanWindow()
        }
        .defaultSize(width: 1280, height: 820)
        .commands { DiskLensCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// One window: a scan of its own, with its own place in the tree, its own Back and Forward, and
/// its own view on the right. Settings and the scan history are shared by all windows.
struct ScanWindow: View {
    static let id = "scan"

    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            // The Dock menu's New Window (see `AppDelegate`) opens one the way ⌘N does.
            .onAppear { [openWindow] in AppDelegate.openScanWindow = { openWindow(id: ScanWindow.id) } }
            .environmentObject(model)
            // The menu commands act on the window in front (see `DiskLensCommands`).
            .focusedSceneObject(model)
            .frame(minWidth: 1000, minHeight: 620)
    }
}

/// Other copies of DiskLens running side by side, each a separate app with windows of its own
/// (File ▸ New Instance, ⌥⌘N, or the Dock menu). Windows of one DiskLens already scan
/// independently; a separate instance also keeps its own memory, so closing or quitting one
/// leaves the others as they are. They share Settings, the scan history and snapshots (see `FileLock`).
@MainActor
enum AppInstances {
    static func openNew() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            Log.app.error("Couldn't open another DiskLens: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }
}

/// The menu bar. Everything but New Window acts on the window in front, and is off while no scan
/// window is in front (the Settings window, say).
struct DiskLensCommands: Commands {
    @FocusedObject private var model: AppModel?
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.showHidden) private var showHidden = true

    var body: some Commands {
        let scanning = model?.isScanning ?? true
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: ScanWindow.id) }
                .keyboardShortcut("n")
            Button("New Instance") { AppInstances.openNew() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Scan Folder…") { model?.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(scanning)
            Button("Scan Home Folder") { model?.scan(path: NSHomeDirectory()) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(scanning)
            Button("Scan Startup Disk") { model?.scan(path: "/") }
                .disabled(scanning)
            Divider()
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r")
                .disabled(model?.result == nil || scanning)
            Button("Stop Scan") { model?.cancel() }
                .keyboardShortcut(".")
                .disabled(!(model?.isScanning ?? false))
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { model?.search.show() }
                .keyboardShortcut("f")
                .disabled(model?.result == nil || (model?.isReadingTree ?? true))
        }
        CommandGroup(before: .toolbar) {
            // Finder's shortcut for the same thing.
            Toggle("Show Hidden Files", isOn: $showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
            ForEach(DetailTab.allCases) { option in
                Button(option.rawValue) { model?.tab = option }
                    .keyboardShortcut(KeyEquivalent(option.key))
                    .disabled(model == nil)
            }
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(model?.canGoBack ?? false))
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(model?.canGoForward ?? false))
            Button("Enclosing Folder") { model?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!(model?.canGoUp ?? false))
            Divider()
            Button("Top of Scan") { model?.goToTop() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(model?.result == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens another scan window; set by the first one (SwiftUI opens windows only from a view).
    @MainActor static var openScanWindow: (() -> Void)?

    /// Right-clicking DiskLens in the Dock offers New Window and New Instance, as VS Code does.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("New Window", #selector(newWindow)), ("New Instance", #selector(newInstance))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc private func newInstance() {
        AppInstances.openNew()
    }

    @MainActor @objc private func newWindow() {
        if let open = Self.openScanWindow {
            open()
        } else {
            NSApp.activate()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        OpenFileLimit.raise()
        HistoryStore.followOtherCopies()
    }

    /// The scan history is written in the background: don't quit before it is.
    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.waitForWrites()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
