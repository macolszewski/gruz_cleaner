import ScannerKit
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = model.item(id: model.focusedItemID) {
            ScrollView {
                ItemDetail(item: item)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select an Item",
                systemImage: "info.circle",
                description: Text("Click an item in the list to see what the data is and what happens if you remove it.")
            )
        }
    }
}

struct ItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ItemIcon(item: item, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let app = item.app { Text(app).foregroundStyle(.secondary) }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.sizeBytes.formattedBytes).font(.system(size: 28, weight: .semibold).monospacedDigit())
                SafetyBadge(safety: item.safety)
                if !item.isGroup, item.action?.isPermanent == true { PermanentBadge() }
            }

            if let growth = item.growth {
                section("Change in size") {
                    Text("Since \(Formatters.date.string(from: growth.baselineDate)): \(Formatters.signedBytes(growth.deltaBytes)). Previously: \(growth.previousBytes.formattedBytes).")
                }
            } else if let rust = item.rustArtifact {
                section("Files created since yesterday") {
                    Text("\(rust.recentBytes.formattedBytes) since \(Formatters.date.string(from: rust.since)). This is the size of new files that still exist, not net growth. Later scans will record a history to compare against.")
                }
            }
            section("What this data is") { Text(item.description) }

            section("Safety") {
                Text(item.safety.explanation).foregroundStyle(.secondary)
            }

            if let regeneration = item.regeneration {
                section("How it is recreated") { Text(regeneration) }
            }

            if let note = item.note {
                section("Notes") { Text(note) }
            }

            if item.requiresAppClosed {
                Label("Quit the app that owns this data before removing it.", systemImage: "xmark.app")
                    .foregroundStyle(.orange)
            }

            if let days = model.ageThreshold(for: item) {
                Label("Shown only if the data has not changed for \(days) days.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }

            section("Last modified") {
                Text(item.lastModified.map { "\(Formatters.date.string(from: $0)) (\(Formatters.age($0)))" } ?? String(localized: "Unknown"))
            }

            if let action = item.action, !item.isGroup {
                section("What GRUZ will do") { actionDescription(action) }
            }

            if !item.paths.isEmpty {
                section(item.paths.count == 1 ? "Path" : "Paths") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.paths, id: \.self) { path in
                            HStack(alignment: .top) {
                                Text(Paths.abbreviate(path))
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                            }
                        }
                    }
                }
            }

            if item.isGroup {
                section("Contents") {
                    Text("\(item.children.count) items. Expand the group in the list to select individual items.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionDescription(_ action: CleanAction) -> some View {
        switch action {
        case .trash:
            Label("Moves to the Trash. You can undo this until you empty the Trash.", systemImage: "trash")
        case .permanentDelete:
            Label("Deletes permanently, bypassing the Trash.", systemImage: "flame").foregroundStyle(.red)
        case .command(let argv):
            VStack(alignment: .leading, spacing: 6) {
                Label("Runs a command (permanent, no Trash):", systemImage: "terminal").foregroundStyle(.red)
                Text(argv.joined(separator: " "))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}
