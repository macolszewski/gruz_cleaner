import AppKit
import SwiftUI

@main
struct GRUZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(Text(verbatim: "GRUZ"), id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, Formatters.locale)
                .frame(minWidth: 1000, minHeight: 620)
                .task { model.scan() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Again") {
                    if model.showingClaudeMemory { model.claudeMemory.scan() } else { model.scan() }
                }
                    .keyboardShortcut("r")
                    .disabled(model.showingClaudeMemory ? model.claudeMemory.isLoading || model.claudeMemory.isRunning : model.isScanning)
                Button("Deselect All") { model.clearSelection() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, Formatters.locale)
                .frame(width: 560, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
