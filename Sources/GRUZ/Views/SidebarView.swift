import ScannerKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let summaries = model.summaries
        // Rows are Buttons that set the selection themselves: List(selection:) with optional tags
        // did not bind on macOS 26, not even for the initial selection.
        List {
            Section {
                DiskHeader()
            }
            Section("AI memory") {
                Button {
                    model.showingClaudeMemory = true
                } label: {
                    Label { Text(verbatim: "claude-mem") } icon: { Image(systemName: "brain.head.profile") }
                        .foregroundStyle(model.showingClaudeMemory ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.showingClaudeMemory ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                .accessibilityAddTraits(model.showingClaudeMemory ? .isSelected : [])
            }
            Section("Reclaimable") {
                ForEach(summaries.filter { !$0.category.isInformational }) { summary in
                    CategoryRow(summary: summary)
                }
            }
            Section("For reference") {
                ForEach(summaries.filter { $0.category.isInformational }) { summary in
                    CategoryRow(summary: summary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if model.settings.ageFilterEnabled || model.hiddenByAgeCount > 0 {
                    AgeFilterInfo()
                }
                // Live check, never the cached scan: it may predate granting the permission.
                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                }
                if let warnings = model.result?.warnings, !warnings.isEmpty {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(12)
        }
    }
}

struct DiskHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let result = model.result, let free = result.freeBytes, let total = result.totalBytes, total > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(free.formattedBytes).font(.title2.weight(.semibold))
                    Text("free of \(total.formattedBytes)").foregroundStyle(.secondary)
                }
                SizeBar(fraction: Double(total - free) / Double(total), color: free < total / 10 ? .red : .accentColor)
                    .frame(height: 6)
            }
            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    (model.activeStages.isEmpty ? Text("Scanning…") : Text(verbatim: model.activeStages.map(\.title).joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let result = model.result {
                (model.resultIsCached
                     ? Text("Saved result from \(Formatters.date.string(from: result.finishedAt))")
                     : Text("Scanned \(Formatters.age(result.finishedAt)) in \(Formatters.duration(result.finishedAt.timeIntervalSince(result.startedAt)))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let summary: CategorySummary

    var body: some View {
        let selected = !model.showingClaudeMemory && model.selectedCategory == summary.category
        Button {
            model.showingClaudeMemory = false
            model.selectedCategory = summary.category
            model.focusedItemID = nil
        } label: {
            HStack {
                Label(summary.category.title, systemImage: summary.category.symbol)
                Spacer()
                Text((summary.category.isInformational ? summary.totalBytes : summary.removableBytes).formattedBytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }
}

struct AgeFilterInfo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if model.settings.ageFilterEnabled {
                    Text("Only data older than \(model.settings.ageFilterDays) days")
                }
                if model.hiddenByAgeCount > 0 {
                    Text("Hidden by age thresholds: \(model.hiddenByAgeCount)").foregroundStyle(.secondary)
                }
                Button("Change in Settings") { openSettings() }.buttonStyle(.link)
            }
        }
        .font(.caption)
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No Full Disk Access", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
            Text("The Trash, Mail and iPhone backups are not measured. Add GRUZ in System Settings, then restart it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
