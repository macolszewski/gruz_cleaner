import CleanerKit
import ScannerKit
import SwiftUI

struct ClaudeMemoryView: View {
    @Bindable var memory: ClaudeMemoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label { Text(verbatim: "claude-mem") } icon: { Image(systemName: "brain.head.profile") }
                    .font(.title2.weight(.semibold))
                Text("Local memory and search indexes")
                    .foregroundStyle(.secondary)
                Text("Deleting memory does not reset the weekly cmem.ai limit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Form {
                Section("Data range") {
                    Picker("Date saved", selection: $memory.dateRule) {
                        ForEach(ClaudeMemoryDateRule.allCases, id: \.self) { rule in Text(rule.title).tag(rule) }
                    }
                    DatePicker("Day", selection: $memory.date, displayedComponents: .date)
                    (memory.dateRule == .since
                     ? Text("From midnight of the selected day, in the local time zone.")
                     : Text("Before midnight of the selected day, in the local time zone."))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Project", selection: $memory.project) {
                        Text("All Projects").tag("")
                        ForEach(memory.preview?.projects.filter { !$0.isEmpty } ?? [], id: \.self) { Text(projectTitle($0)).tag($0) }
                    }
                }
                Section("Data types") {
                    ForEach(ClaudeMemoryKind.allCases) { kind in
                        Toggle(isOn: Binding(get: { memory.kinds.contains(kind) }, set: { enabled in
                            if enabled { memory.kinds.insert(kind) } else { memory.kinds.remove(kind) }
                        })) {
                            HStack {
                                Text(kind.title)
                                Spacer()
                                if let preview = memory.preview, memory.isCurrent {
                                    Text(preview.count(for: kind), format: .number).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel(kind.title)
                        .disabled(kind.directory != nil && !memory.project.isEmpty)
                    }
                    Text("Logs and observer files are filtered by modification date and apply to all projects. Session metadata and the original Claude and Codex transcripts are not part of these types.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preview = memory.preview {
                    Section("Preview") {
                        LabeledContent("SQLite database", value: preview.databaseBytes.formattedBytes)
                        LabeledContent("Chroma index", value: preview.indexBytes.formattedBytes)
                        LabeledContent("Selected records and files",
                                       value: memory.isCurrent ? preview.count.formatted(.number.locale(Formatters.locale)) : String(localized: "Refresh the preview"))
                        Text("Database and index sizes are totals. The space you get back depends on the rebuild and on deleting the backups.")
                            .font(.caption).foregroundStyle(.secondary)
                        if preview.excludedRemoteRecords > 0 {
                            Label("Skipped \(preview.excludedRemoteRecords) records from other devices. Delete them on the source device.", systemImage: "externaldrive.badge.icloud")
                                .font(.caption)
                        }
                        if preview.pendingMessages > 0 {
                            Label("Messages in queue: \(preview.pendingMessages). Cleanup becomes available once the queue is empty.", systemImage: "clock")
                                .foregroundStyle(.orange)
                        }
                        if memory.maintenanceActive {
                            Label("Another GRUZ instance is running maintenance. Wait for it to finish, then refresh the preview.", systemImage: "clock")
                                .foregroundStyle(.secondary)
                        } else if memory.interrupted {
                            Label("The previous maintenance did not finish. Choose Rebuild Indexes.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let error = memory.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .disabled(memory.isLoading || memory.isRunning)
            Divider()
            HStack {
                Button("Refresh Preview") { memory.scan() }
                    .disabled(memory.isLoading || memory.isRunning)
                if memory.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Rebuild Indexes…") { memory.review(rebuildOnly: true) }
                    .disabled(!memory.isCurrent || memory.isLoading || memory.isRunning || memory.preview?.pendingMessages != 0 || memory.maintenanceActive)
                Button("Review and Delete…") { memory.review(rebuildOnly: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!memory.isCurrent || memory.isLoading || memory.isRunning || memory.preview?.count == 0 || memory.preview?.pendingMessages != 0 || memory.interrupted)
            }
            .padding(16)
        }
        .navigationTitle(Text(verbatim: "claude-mem"))
        .navigationSubtitle("Local memory and indexes")
        .task { if memory.preview == nil { memory.scan() } }
        .sheet(isPresented: $memory.reviewing) { ClaudeMemoryReview(memory: memory) }
    }
}

struct ClaudeMemoryInfo: View {
    let memory: ClaudeMemoryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("How cleanup works", systemImage: "info.circle").font(.headline)
                Text("1. You preview and confirm the selected data.\n\n2. GRUZ makes a consistent backup of the SQLite database.\n\n3. claude-mem deletes the records, so syncing is handled.\n\n4. GRUZ stops the worker, rebuilds FTS and Chroma, and verifies the index.\n\n5. claude-mem starts again.")
                Text("Before deleting, end agent sessions that use claude-mem. The preview itself only reads data.")
                    .foregroundStyle(.secondary)
                if let location = memory.preview?.location {
                    Divider()
                    Text("Data location").font(.headline)
                    Text(location.root.path).font(.caption.monospaced()).textSelection(.enabled)
                    (location.cloudConfigured
                     ? Text("cmem.ai sync is configured. Deletions may reach the cloud and your other devices after syncing.")
                     : Text("cmem.ai sync is not configured in the settings GRUZ read."))
                        .font(.callout)
                }
                Divider()
                Text("cmem.ai limit").font(.headline)
                Text("Usage is counted by cmem.ai. Cleaning memory or local indexes does not reset it.")
                    .foregroundStyle(.secondary)
                Link("Open cmem.ai", destination: URL(string: "https://cmem.ai")!)
            }
            .padding(20)
        }
    }
}

struct ClaudeMemoryReview: View {
    @Bindable var memory: ClaudeMemoryModel
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title.font(.title2.weight(.semibold))
            if memory.isRunning {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Text(memory.progress).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Text("Do not quit GRUZ or start agent sessions until maintenance finishes.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else if let report = memory.report {
                result(report)
            } else if let preview = memory.preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Database: \(preview.location.database.path)").font(.caption.monospaced()).textSelection(.enabled)
                        if !memory.rebuildOnly {
                            Text(verbatim: "\(preview.filter.dateRule.title): \(preview.filter.cutoff.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Formatters.locale)))")
                            Text("Project: \(preview.filter.project.map(projectTitle) ?? String(localized: "All Projects"))")
                            ForEach(ClaudeMemoryKind.allCases.filter { preview.count(for: $0) > 0 }) { kind in
                                LabeledContent(kind.title, value: preview.count(for: kind).formatted(.number.locale(Formatters.locale)))
                            }
                            DisclosureGroup("Exact list of records and files (\(preview.count))") {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(preview.records) { row in
                                        Text(verbatim: "\(row.kind.title) #\(row.rowID) · \(projectTitle(row.project)) · \(row.date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(Formatters.locale)))")
                                    }
                                    ForEach(preview.files) { file in Text(file.path) }
                                }.font(.caption.monospaced()).textSelection(.enabled)
                            }
                            Text("Database records will be deleted permanently. Log and observer files will be moved to the Trash.")
                                .foregroundStyle(.red)
                        }
                        Text("GRUZ will back up the database and keep the old index in ~/Library/Application Support/GRUZ/ClaudeMemBackups. The backups contain the deleted data and still take up space; delete them once you have checked the result.")
                        if preview.location.cloudConfigured {
                            Text("Deletions will be queued for syncing with cmem.ai and your other devices. The local backup does not undo deletions in the cloud. Finishing here does not mean syncing has finished.")
                                .foregroundStyle(.orange)
                        }
                        Text("A full rebuild covers the indexes of all projects. It needs a local Chroma and the default embedding model; the first run may download dependencies with uv.")
                        Text("The weekly cmem.ai limit stays the same.").fontWeight(.semibold)
                    }
                }
                Toggle(isOn: $confirmed) {
                    memory.rebuildOnly
                        ? Text("I confirm stopping the worker and rebuilding the indexes.")
                        : Text("I confirm permanently deleting the selected records and rebuilding the indexes.")
                }
                    .toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { memory.closeReview() }.keyboardShortcut(.cancelAction)
                    Button(role: .destructive) { memory.execute() } label: {
                        memory.rebuildOnly ? Text("Rebuild Indexes") : Text("Delete and Rebuild Indexes")
                    }
                        .buttonStyle(.borderedProminent).tint(memory.rebuildOnly ? .accentColor : .red)
                        .disabled(!confirmed)
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 640)
        .interactiveDismissDisabled(memory.isRunning)
    }

    private var title: Text {
        if memory.report != nil { return Text("Maintenance Results") }
        return memory.rebuildOnly ? Text("Rebuild claude-mem Indexes") : Text("Review Before Deleting")
    }

    @ViewBuilder private func result(_ report: ClaudeMemoryReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    report.succeeded ? Text("Maintenance finished") : Text("Maintenance did not finish")
                } icon: {
                    Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                    .foregroundStyle(report.succeeded ? .green : .orange)
                Text("Deleted records: \(report.removedRecords). Files moved to the Trash: \(report.trashedFiles).")
                report.indexRebuilt ? Text("The indexes were rebuilt and verified.") : Text("The index rebuild was not confirmed.")
                if let error = report.failure { Text(error).textSelection(.enabled) }
                if let backup = report.backup {
                    Text("The database backup and the old index may contain deleted data. Delete the backup only after you have checked the memory.")
                    Button("Show Backup in Finder") { NSWorkspace.shared.open(backup) }
                    Text(backup.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                if report.cloudNotice { Text("Cloud deletions go through the claude-mem queue. Check syncing in its dashboard.") }
                Text("Operation log: \(FileOperationLog.displayPath)").font(.caption).foregroundStyle(.secondary)
            }
        }
        HStack { Spacer(); Button("Close and Refresh") { memory.closeReview() }.keyboardShortcut(.defaultAction) }
    }
}

/// Display name of a claude-mem project; prompts without a session project get a translated label.
private func projectTitle(_ project: String) -> String {
    project == ClaudeMemoryReader.noProject ? String(localized: "(no project)") : project
}
