import SwiftUI
import AppKit

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage("detailTab") private var tab: DetailTab = .details

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isScanning)
                Button("Scan Home Folder") { model.scan(path: NSHomeDirectory()) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.isScanning)
                Button("Scan Startup Disk") { model.scan(path: "/") }
                    .disabled(model.isScanning)
                Divider()
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.result == nil || model.isScanning)
                Button("Stop Scan") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
            }
            CommandGroup(before: .toolbar) {
                ForEach(DetailTab.allCases) { option in
                    Button(option.rawValue) { tab = option }
                        .keyboardShortcut(KeyEquivalent(option.key))
                }
                Divider()
            }
            CommandMenu("Go") {
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.canGoForward)
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                    .disabled(!model.canGoUp)
                Divider()
                Button("Top of Scan") { model.goToTop() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                    .disabled(model.result == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
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
