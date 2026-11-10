import ScannerKit
import SwiftUI

extension ScanItem {
    /// `List(children:)` expects nil for leaves.
    var childrenOrNil: [ScanItem]? { children.isEmpty ? nil : children }
}

struct ItemListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let category = model.selectedCategory {
            let items = model.visibleItems(in: category)
            let maxSize = items.map(\.sizeBytes).max() ?? 1
            Group {
                if items.isEmpty {
                    if model.isScanning && model.result == nil {
                        ProgressView("Scanning…")
                    } else if model.searchText.isEmpty {
                        ContentUnavailableView(
                            "No Items",
                            systemImage: category.symbol,
                            description: Text("Nothing to show in this category.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Results",
                            systemImage: category.symbol,
                            description: Text("Try a different search.")
                        )
                    }
                } else {
                    List(items, children: \.childrenOrNil, selection: $model.focusedItemID) { item in
                        ItemRow(item: item, maxSize: maxSize).tag(item.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("What grew", isOn: $model.growthOnly).toggleStyle(.switch)
                    if model.growthOnly {
                        Text("Compared with an earlier measurement. Without history: new Rust files since yesterday, not net growth. The age filter is ignored.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12).background(.bar)
            }
            .navigationTitle(category.title)
            .navigationSubtitle(subtitle(for: category, items: items))
        } else {
            ContentUnavailableView("Select a Category", systemImage: "sidebar.left")
        }
    }

    private func subtitle(for category: ScannerKit.Category, items: [ScanItem]) -> String {
        let total = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        if category.isInformational { return String(localized: "For reference only, \(total.formattedBytes)") }
        let leaves = items.flatMap(\.leaves)
        let removable = leaves.filter(\.isSelectable).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let safe = leaves.filter { $0.isSelectable && $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return String(localized: "About \(removable.formattedBytes) reclaimable, \(safe.formattedBytes) of it safe")
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    let maxSize: Int64

    var body: some View {
        let selectable = item.isGroup ? item.leaves.contains(where: \.isSelectable) : item.isSelectable
        HStack(spacing: 10) {
            TriStateCheckbox(state: model.selectionState(of: item, visible: item), enabled: selectable) {
                model.toggle(item)
            }
            ItemIcon(item: item)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if item.isGroup {
                        Text(item.children.count, format: .number)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    if let app = item.app { Text(app) }
                    if let modified = item.lastModified {
                        Text("· modified \(Formatters.age(modified))")
                    }
                    if let note = item.note, !item.isGroup { Text(verbatim: "· \(note)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let growth = item.growth {
                    // Unchanged items stay quiet; the detail panel still shows the comparison.
                    if growth.deltaBytes != 0 {
                        Text("Change: \(Formatters.signedBytes(growth.deltaBytes)) since \(Formatters.date.string(from: growth.baselineDate))")
                            .font(.caption).foregroundStyle(growth.deltaBytes > 0 ? Color.orange : Color.secondary)
                    }
                } else if let rust = item.rustArtifact {
                    Text("New since yesterday: \(rust.recentBytes.formattedBytes) · no baseline")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SizeBar(fraction: Double(item.sizeBytes) / Double(max(1, maxSize)), color: item.safety.color)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.sizeBytes.formattedBytes)
                    .font(.body.monospacedDigit().weight(.medium))
                HStack(spacing: 4) {
                    if !item.isGroup, item.action?.isPermanent == true { PermanentBadge() }
                    SafetyBadge(safety: item.safety, compact: true)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let path = item.paths.first {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }
}
