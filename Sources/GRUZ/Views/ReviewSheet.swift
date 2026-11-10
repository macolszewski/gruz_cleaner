import CleanerKit
import ScannerKit
import SwiftUI

/// The only path to removal: full list of what will happen, then explicit confirmation.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case review
        case running
        case finished(CleaningReport)
    }

    @State private var phase: Phase = .review
    @State private var plan = CleaningPlan(operations: [])
    @State private var blockers: [String: [String]] = [:]
    @State private var confirmingPermanent = false
    @State private var checking = false
    @State private var checkGeneration = UUID()

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .review: review
            case .running: running
            case .finished(let report): ResultView(report: report) { finish() }
            }
        }
        .frame(width: 760, height: 620)
        .onAppear(perform: rebuild)
    }

    // MARK: Review

    private var review: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Before Removing").font(.title2.weight(.semibold))
                Text("Items in the Trash take up space until you empty it. Sizes are estimates; permanent deletion needs an extra confirmation.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            List {
                if !plan.trashOperations.isEmpty {
                    Section {
                        ForEach(plan.trashOperations) { op in
                            OperationRow(op: op, problems: blockers[op.id] ?? [], permanentToggle: binding(for: op))
                        }
                    } header: {
                        Label("Move to Trash (\(bytes(plan.trashOperations))), can be undone", systemImage: "trash")
                    }
                }
                if !plan.permanentOperations.isEmpty {
                    Section {
                        ForEach(plan.permanentOperations) { op in
                            OperationRow(
                                op: op, problems: blockers[op.id] ?? [],
                                permanentToggle: op.kind == .permanentDelete ? binding(for: op) : nil
                            )
                        }
                    } header: {
                        Label("Delete permanently (\(bytes(plan.permanentOperations))), skips the Trash, cannot be undone", systemImage: "flame")
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                let blocked = plan.operations.filter { !(blockers[$0.id] ?? []).isEmpty }.count
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total: **\(plan.totalBytes.formattedBytes)** in \(plan.operations.count) items")
                    if blocked > 0 {
                        Text("\(blocked) items will be skipped (reasons are in the list).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(action: refreshBlockers) {
                    checking ? Text("Checking…") : Text("Check Again")
                }
                    .disabled(checking)
                    .help("For example, after quitting apps")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    if plan.hasPermanent { confirmingPermanent = true } else { run(permanentConfirmed: false) }
                } label: {
                    plan.hasPermanent ? Text("Delete…") : Text("Move to Trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(plan.hasPermanent ? .red : .accentColor)
                .disabled(checking || plan.operations.isEmpty || blocked == plan.operations.count)
            }
            .padding(16)
        }
        .alert("Confirm Permanent Deletion", isPresented: $confirmingPermanent) {
            Button("Delete \(bytes(plan.permanentOperations)) Permanently", role: .destructive) { run(permanentConfirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: permanentDeletionMessage)
        }
    }

    private var permanentDeletionMessage: String {
        let permanent = String(localized: "\(plan.permanentOperations.count) items will be deleted permanently, bypassing the Trash. This cannot be undone.")
        guard !plan.trashOperations.isEmpty else { return permanent }
        return permanent + " " + String(localized: "The remaining \(plan.trashOperations.count) items will be moved to the Trash.")
    }

    private var running: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Removing…").font(.headline)
            Text("Docker and cache commands can take a few minutes.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func binding(for op: CleaningOperation) -> Binding<Bool> {
        Binding {
            model.forcePermanent.contains(op.id)
        } set: { on in
            if on { model.forcePermanent.insert(op.id) } else { model.forcePermanent.remove(op.id) }
            rebuild()
        }
    }

    private func rebuild() {
        plan = model.makePlan()
        refreshBlockers()
    }

    private func refreshBlockers() {
        let executor = model.executor
        let operations = plan.operations
        let generation = UUID()
        checkGeneration = generation
        checking = true
        Task {
            let checked = await Task.detached {
                Dictionary(uniqueKeysWithValues: operations.map { ($0.id, executor.blockers(for: $0)) })
            }.value
            guard generation == checkGeneration else { return }
            blockers = checked
            checking = false
        }
    }

    private func run(permanentConfirmed: Bool) {
        let current = plan
        let confirmation = CleaningConfirmation(planID: current.id, permanentConfirmed: permanentConfirmed)
        phase = .running
        Task {
            let report = await model.execute(current, confirmation: confirmation)
            phase = .finished(report)
        }
    }

    private func finish() {
        dismiss()
        model.scan()
    }

    private func bytes(_ ops: [CleaningOperation]) -> String {
        ops.reduce(Int64(0)) { $0 + $1.sizeBytes }.formattedBytes
    }
}

struct OperationRow: View {
    let op: CleaningOperation
    let problems: [String]
    let permanentToggle: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(op.title).lineLimit(1).truncationMode(.middle)
                    if let app = op.app { Text(app).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(op.sizeBytes.formattedBytes).monospacedDigit()
            }
            if let command = op.commandLine {
                Text(verbatim: "$ \(command)")
                    .font(.caption.monospaced())
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    .textSelection(.enabled)
            } else {
                ForEach(op.paths, id: \.self) { path in
                    Text(Paths.abbreviate(path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if let toggle = permanentToggle {
                Toggle("Skip Trash (delete permanently)", isOn: toggle)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            ForEach(problems, id: \.self) { problem in
                Label("Will be skipped: \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ResultView: View {
    let report: CleaningReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Done").font(.title2.weight(.semibold))
                if let freed = report.measuredFreedBytes {
                    if freed > 0 {
                        Text("Free space increased by **\(freed.formattedBytes)**.")
                    } else {
                        Text("Free space has not changed yet.")
                    }
                }
                if report.results.contains(where: { $0.operation.kind == .trash }) {
                    Text("Files moved to the Trash free up space only after you empty the Trash.")
                        .foregroundStyle(.secondary)
                }
                if report.results.contains(where: { $0.operation.commandLine?.hasPrefix("docker") == true }) {
                    Text("OrbStack returns space freed by Docker to macOS gradually, over a few minutes.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            List(report.results) { result in
                HStack(alignment: .top) {
                    statusIcon(result.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.operation.title)
                        if let detail = statusText(result.status) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let output = result.output {
                            Text(output).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                    Spacer()
                    Text(result.operation.sizeBytes.formattedBytes).monospacedDigit()
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("Operation log: \(FileOperationLog.displayPath)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close and Scan Again", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: OperationResult.Status) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func statusText(_ status: OperationResult.Status) -> String? {
        switch status {
        case .done: nil
        case .skipped(let why): String(localized: "Skipped: \(why)")
        case .failed(let why): String(localized: "Error: \(why)")
        }
    }
}

extension FileOperationLog {
    static var displayPath: String { Paths.abbreviate(defaultURL.path) }
}
