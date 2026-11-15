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

    var body: some View {
        ContentView()
            .environmentObject(model)
            // The menu commands act on the window in front (see `DiskLensCommands`).
            .focusedSceneObject(model)
            .frame(minWidth: 1000, minHeight: 620)
    }
}

/// The menu bar. Everything but New Window acts on the window in front, and is off while no scan
/// window is in front (the Settings window, say).
struct DiskLensCommands: Commands {
    @FocusedObject private var model: AppModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let scanning = model?.isScanning ?? true
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: ScanWindow.id) }
                .keyboardShortcut("n")
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
