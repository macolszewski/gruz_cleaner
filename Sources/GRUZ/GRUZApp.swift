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
                .task {
                    delegate.model = model
                    model.scan()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Again") {
                    if model.showingClaudeMemory { model.claudeMemory.scan() } else { model.scan() }
                }
                    .keyboardShortcut("r")
                    .disabled(model.showingClaudeMemory ? model.claudeMemory.isLoading || model.claudeMemory.isRunning : !model.canScan)
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
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting in the middle of a removal would leave it half done with no result shown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ model?.isBusy }) == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "GRUZ is still removing data")
        alert.informativeText = String(localized: "Quit after it finishes, so every result is shown and logged.")
        alert.runModal()
        return .terminateCancel
    }
}
