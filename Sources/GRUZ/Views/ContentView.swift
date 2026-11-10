import AppKit
import ScannerKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showingReview = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 380)
        } content: {
            Group {
                if model.showingClaudeMemory {
                    ClaudeMemoryView(memory: model.claudeMemory)
                } else {
                    ItemListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 440, ideal: 560)
        } detail: {
            Group {
                if model.showingClaudeMemory {
                    ClaudeMemoryInfo(memory: model.claudeMemory)
                } else {
                    DetailView()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
        .modifier(CleanerSearchModifier())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.showingClaudeMemory { model.claudeMemory.scan() } else { model.scan() }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.showingClaudeMemory ? model.claudeMemory.isLoading || model.claudeMemory.isRunning : model.isScanning)
                .help("Scan again (⌘R). Scanning only reads data.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.showingClaudeMemory { SelectionBar(showingReview: $showingReview) }
        }
        .sheet(isPresented: $showingReview) {
            ReviewSheet()
                .environment(model)
        }
        #if DEBUG
        .task {
            guard ScreenshotScenario.current != nil else { return }
            // Same size on every run, whatever frame macOS restored.
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.setContentSize(NSSize(width: 1280, height: 800))
            NSApp.activate()
            switch ScreenshotScenario.current {
            case .review?: showingReview = true
            case .settings?:
                openSettings()
                // The Settings window remembers its frame; reset it to the size of its content.
                try? await Task.sleep(for: .milliseconds(400))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") != true }) {
                    window.setContentSize(NSSize(width: 560, height: 560))
                }
            default: break
            }
        }
        #endif
        .overlay {
            if !model.showingClaudeMemory, let error = model.catalogError {
                ContentUnavailableView("Cannot Load Rule Catalog", systemImage: "exclamationmark.octagon", description: Text(error))
            }
        }
    }
}

private struct CleanerSearchModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        @Bindable var model = model
        if model.showingClaudeMemory {
            content
        } else {
            content.searchable(text: $model.searchText, placement: .toolbar, prompt: "Search items or paths")
        }
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showingReview: Bool

    var body: some View {
        let count = model.selectedLeaves.count
        HStack(spacing: 12) {
            Image(systemName: count == 0 ? "checklist.unchecked" : "checklist.checked")
                .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
            if count == 0 {
                Text("Nothing is selected. Select the items you want to remove.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Selected: **\(model.selectedBytes.formattedBytes)**")
                Text("(\(count) items)").foregroundStyle(.secondary)
                Button("Clear Selection") { model.clearSelection() }
                    .buttonStyle(.link)
            }
            Spacer()
            GruzButton(isEnabled: count > 0 && !model.isScanning) { showingReview = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
