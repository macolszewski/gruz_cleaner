import Foundation
import ScannerKit

/// One removal the user selected: move paths to the Trash, delete them, or run an allow-listed command.
public struct CleaningOperation: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case trash
        case permanentDelete
        case command([String])
    }

    public var id: String
    public var title: String
    public var app: String?
    public var paths: [String]
    public var kind: Kind
    public var sizeBytes: Int64
    public var ownerBundleIDs: [String]
    public var requiresAppClosed: Bool
    public var rustArtifact: RustArtifact?
    /// Read-only checks that must still match the scan right before the operation runs.
    public var preconditions: [CommandCheck] = []

    /// Commands count as permanent: what they remove never reaches the Trash.
    public var isPermanent: Bool {
        if case .trash = kind { return false }
        return true
    }

    /// The command as shown in the review sheet, with arguments containing spaces quoted.
    public var commandLine: String? {
        guard case .command(let argv) = kind else { return nil }
        return argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// The exact set of operations shown in the review sheet. Its `id` binds the user's confirmation to it.
public struct CleaningPlan: Identifiable, Sendable {
    public let id = UUID()
    public var operations: [CleaningOperation]

    public init(operations: [CleaningOperation]) { self.operations = operations }

    /// Builds a plan from selected leaves. `forcePermanent` lists item ids the user switched from Trash to permanent deletion.
    public static func make(from items: [ScanItem], forcePermanent: Set<String> = []) -> CleaningPlan {
        // Shorter paths first, so a selected parent claims its children and nothing is removed twice.
        var claimed: [String] = []
        let disjoint = items.filter(\.isSelectable).sorted { ($0.paths.first ?? "").count < ($1.paths.first ?? "").count }.filter { item in
            let paths = item.paths.map { Paths.normalize($0) }
            guard !paths.contains(where: { path in claimed.contains { Paths.isWithin(path, $0) || Paths.isWithin($0, path) } }) else { return false }
            claimed += paths
            return true
        }
        let ops = disjoint.compactMap { item -> CleaningOperation? in
            guard let action = item.action else { return nil }
            let kind: CleaningOperation.Kind = switch action {
            case .trash: forcePermanent.contains(item.id) ? .permanentDelete : .trash
            case .permanentDelete: .permanentDelete
            case .command(let argv): .command(argv)
            }
            return CleaningOperation(
                id: item.id, title: item.title, app: item.app, paths: item.paths, kind: kind, sizeBytes: item.sizeBytes,
                ownerBundleIDs: item.ownerBundleIDs, requiresAppClosed: item.requiresAppClosed, rustArtifact: item.rustArtifact,
                preconditions: item.preconditions ?? []
            )
        }
        return CleaningPlan(operations: ops)
    }

    public var totalBytes: Int64 { operations.reduce(0) { $0 + $1.sizeBytes } }
    public var trashOperations: [CleaningOperation] { operations.filter { $0.kind == .trash } }
    public var permanentOperations: [CleaningOperation] { operations.filter(\.isPermanent) }
    public var hasPermanent: Bool { operations.contains(where: \.isPermanent) }
}

/// Proof that the user went through the review sheet (and, for permanent operations, the extra alert).
public struct CleaningConfirmation: Sendable {
    public let planID: UUID
    public let permanentConfirmed: Bool

    public init(planID: UUID, permanentConfirmed: Bool) {
        self.planID = planID
        self.permanentConfirmed = permanentConfirmed
    }
}

/// Outcome of one operation. Reasons in `skipped` and `failed` are localized for display.
public struct OperationResult: Identifiable, Sendable {
    public enum Status: Sendable {
        case done
        /// Some paths were removed and some were not; the reason lists the failures.
        case partial(String)
        case skipped(String)
        case failed(String)
    }

    public var id: String { operation.id }
    public var operation: CleaningOperation
    public var status: Status
    /// Command output.
    public var output: String?
    /// Paths of the operation that are still on disk after a partial removal.
    public var remainingPaths: [String] = []

    public init(operation: CleaningOperation, status: Status, output: String? = nil, remainingPaths: [String] = []) {
        self.operation = operation
        self.status = status
        self.output = output
        self.remainingPaths = remainingPaths
    }
}

public struct CleaningReport: Sendable {
    public var results: [OperationResult]
    public var freeBefore: Int64?
    public var freeAfter: Int64?

    public init(results: [OperationResult] = [], freeBefore: Int64? = nil, freeAfter: Int64? = nil) {
        self.results = results
        self.freeBefore = freeBefore
        self.freeAfter = freeAfter
    }

    /// Change in free disk space; it can differ from the planned size (APFS snapshots, purgeable space, other writers).
    public var measuredFreedBytes: Int64? {
        guard let b = freeBefore, let a = freeAfter else { return nil }
        return a - b
    }

    /// Every operation of `plan` skipped for one reason, before anything ran.
    public static func skippingAll(_ plan: CleaningPlan, reason: String, freeBytes: Int64? = nil) -> CleaningReport {
        CleaningReport(results: plan.operations.map { OperationResult(operation: $0, status: .skipped(reason)) },
                       freeBefore: freeBytes, freeAfter: freeBytes)
    }

    public var doneCount: Int { results.filter { if case .done = $0.status { true } else { false } }.count }
}

// MARK: - Dependencies

/// File removal primitives, replaced by a recording fake in tests.
public protocol FileOperations: Sendable {
    func moveToTrash(_ path: String) throws
    func removePermanently(_ path: String) throws
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String)
    /// Absolute path of `tool`, or nil when it is not installed.
    func locate(_ tool: String) -> String?
}

public protocol RunningAppsChecking: Sendable {
    /// Names of running apps among `bundleIDs`.
    func running(_ bundleIDs: [String]) -> [String]
}

/// Append-only audit trail of every operation, written in English.
public protocol OperationLogging: Sendable {
    /// Throws when the line could not be written.
    func record(_ line: String) throws
}

extension OperationLogging {
    /// Writes `entry` as one JSON line with the current time.
    func record(entry: [String: Any]) throws {
        let stamped = entry.merging(["time": ISO8601DateFormatter().string(from: Date())]) { current, _ in current }
        let data = try JSONSerialization.data(withJSONObject: stamped, options: [.sortedKeys])
        try record(String(decoding: data, as: UTF8.self))
    }

    /// Writes `entry` after an operation already ran. A failure cannot undo the operation, so it is
    /// returned as a localized note for the result instead of being lost.
    func recordAfterRun(_ entry: [String: Any]) -> String? {
        do {
            try record(entry: entry)
            return nil
        } catch {
            return LocalizedMessage("This result is missing from the operation log: \(error.localizedDescription)").text
        }
    }
}

public protocol FreeSpaceProviding: Sendable {
    func freeBytes() -> Int64?
}

// MARK: - Executor

/// Runs a confirmed plan. Every safety check is repeated right before each operation, because
/// the disk and running apps may have changed since the review sheet was shown.
public struct CleaningExecutor: Sendable {
    let files: FileOperations
    let commands: CommandRunning
    let apps: RunningAppsChecking
    let log: OperationLogging
    let space: FreeSpaceProviding
    let denylist: Denylist
    let rustGuard: any RustRemovalChecking

    public init(
        files: FileOperations, commands: CommandRunning, apps: RunningAppsChecking, log: OperationLogging,
        space: FreeSpaceProviding, denylist: Denylist, rustGuard: any RustRemovalChecking = SystemRustRemovalGuard()
    ) {
        self.files = files
        self.commands = commands
        self.apps = apps
        self.log = log
        self.space = space
        self.denylist = denylist
        self.rustGuard = rustGuard
    }

    /// Problems that block an operation right now; shown in the review sheet and re-checked before running.
    public func blockers(for op: CleaningOperation) -> [String] {
        blockerMessages(for: op).map(\.text)
    }

    func blockerMessages(for op: CleaningOperation) -> [LocalizedMessage] {
        var problems: [LocalizedMessage] = []
        if op.requiresAppClosed {
            let running = apps.running(op.ownerBundleIDs).joined(separator: ", ")
            if !running.isEmpty { problems.append(LocalizedMessage("Quit \(running) first")) }
        }
        switch op.kind {
        case .trash, .permanentDelete:
            if op.paths.isEmpty { problems.append(LocalizedMessage("No paths to remove")) }
            for path in op.paths {
                if case .denied(let why) = denylist.check(path) {
                    problems.append(LocalizedMessage(verbatim: why).prefixed(Paths.abbreviate(path)))
                }
            }
        case .command(let argv):
            if !CommandPolicy.isAllowedCleanCommand(argv) {
                problems.append(LocalizedMessage("The command is not on the allow list"))
            } else if commands.locate(argv[0]) == nil {
                problems.append(LocalizedMessage("Cannot find \(argv[0])"))
            }
            // A command that acts on a folder (uv cache clean --cache-dir) is held to the same rules as removing it.
            for path in op.paths {
                if case .denied(let why) = denylist.check(path) {
                    problems.append(LocalizedMessage(verbatim: why).prefixed(Paths.abbreviate(path)))
                }
            }
        }
        if let rust = op.rustArtifact {
            do { let lease = try rustGuard.acquire(rust, paths: op.paths); lease.release() }
            catch { problems.append(LocalizedMessage(error)) }
        }
        return problems
    }

    /// Runs `plan` only when `confirmation` belongs to it; permanent operations additionally need
    /// `permanentConfirmed`. Each result is appended to the operation log.
    public func execute(_ plan: CleaningPlan, confirmation: CleaningConfirmation) async -> CleaningReport {
        let freeBefore = space.freeBytes()
        var results: [OperationResult] = []

        guard confirmation.planID == plan.id else {
            return .skippingAll(plan, reason: LocalizedMessage("The plan was not confirmed").text, freeBytes: freeBefore)
        }
        // Nothing is removed without a record of it: if the log cannot be written, nothing runs.
        do {
            try log.record(entry: ["event": "plan", "operations": String(plan.operations.count)])
        } catch {
            let reason = LocalizedMessage("Cannot write the operation log: \(error.localizedDescription)")
            return .skippingAll(plan, reason: reason.text, freeBytes: freeBefore)
        }
        // Check outputs by argv: one `docker info` answers for every Docker operation of the plan.
        var checkOutputs: [[String]: String?] = [:]

        for op in plan.operations {
            if op.isPermanent, !confirmation.permanentConfirmed {
                results.append(finish(op, .skipped(LocalizedMessage("Permanent deletion was not confirmed"))))
                continue
            }
            var problems = blockerMessages(for: op)
            if problems.isEmpty { problems = await preconditionProblems(for: op, outputs: &checkOutputs) }
            if !problems.isEmpty {
                results.append(finish(op, .skipped(.joined(problems))))
                continue
            }
            if let rust = op.rustArtifact {
                // Hold Cargo's lock for the whole removal, not only during the check above.
                do {
                    let lease = try rustGuard.acquire(rust, paths: op.paths)
                    defer { lease.release() }
                    results.append(await run(op))
                } catch {
                    results.append(finish(op, .skipped(LocalizedMessage(error))))
                }
            } else {
                results.append(await run(op))
            }
        }
        return CleaningReport(results: results, freeBefore: freeBefore, freeAfter: space.freeBytes())
    }

    /// Runs each read-only check of `op` (reusing outputs already in `outputs`) and reports those whose
    /// output no longer matches the scan.
    func preconditionProblems(for op: CleaningOperation, outputs: inout [[String]: String?]) async -> [LocalizedMessage] {
        var problems: [LocalizedMessage] = []
        for check in op.preconditions {
            guard CommandPolicy.isAllowedCheckCommand(check.argv), let executable = commands.locate(check.argv[0]) else {
                problems.append(LocalizedMessage("Cannot verify the item before removing it. Scan again."))
                continue
            }
            if outputs[check.argv] == nil {
                let result = try? await commands.run(executable: executable, arguments: Array(check.argv.dropFirst()))
                outputs[check.argv] = result.flatMap { $0.status == 0 ? $0.output : nil }
            }
            if let output = outputs[check.argv] ?? nil, check.isSatisfied(by: output) { continue }
            problems.append(check.purpose.mismatch)
        }
        return problems
    }

    private enum Outcome {
        case done
        case partial(LocalizedMessage)
        case skipped(LocalizedMessage)
        case failed(LocalizedMessage)
    }

    private func run(_ op: CleaningOperation) async -> OperationResult {
        switch op.kind {
        case .trash, .permanentDelete:
            var errors: [LocalizedMessage] = []
            var remaining: [String] = []
            var anyDone = false
            for path in op.paths {
                guard Paths.exists(path) else {
                    errors.append(LocalizedMessage("no longer exists").prefixed(Paths.abbreviate(path)))
                    continue
                }
                do {
                    if op.kind == .trash { try files.moveToTrash(path) } else { try files.removePermanently(path) }
                    anyDone = true
                } catch {
                    errors.append(LocalizedMessage(error).prefixed(Paths.abbreviate(path)))
                    remaining.append(path)
                }
            }
            if errors.isEmpty { return finish(op, .done) }
            let summary = LocalizedMessage.joined(errors)
            return finish(op, anyDone ? .partial(summary) : .failed(summary), remainingPaths: remaining)
        case .command(let argv):
            guard let executable = commands.locate(argv[0]) else {
                return finish(op, .failed(LocalizedMessage("Cannot find \(argv[0])")))
            }
            do {
                let (status, output) = try await commands.run(executable: executable, arguments: Array(argv.dropFirst()))
                return finish(op, status == 0 ? .done : .failed(LocalizedMessage("Exit code \(Int(status))")),
                              output: output.isEmpty ? nil : output)
            } catch {
                return finish(op, .failed(LocalizedMessage(error)))
            }
        }
    }

    /// Logs the outcome in English and returns the localized result for the UI.
    private func finish(_ op: CleaningOperation, _ outcome: Outcome, output: String? = nil, remainingPaths: [String] = []) -> OperationResult {
        let status: OperationResult.Status
        let logStatus: String
        switch outcome {
        case .done:
            status = .done
            logStatus = "done"
        case .partial(let why):
            status = .partial(why.text)
            logStatus = "partial: \(why.english)"
        case .skipped(let why):
            status = .skipped(why.text)
            logStatus = "skipped: \(why.english)"
        case .failed(let why):
            status = .failed(why.text)
            logStatus = "failed: \(why.english)"
        }
        let what: String = switch op.kind {
        case .trash: "trash \(op.paths.joined(separator: ", "))"
        case .permanentDelete: "delete \(op.paths.joined(separator: ", "))"
        case .command(let argv): "run \(argv.joined(separator: " "))"
        }
        var entry: [String: Any] = [
            "item": op.id,
            "bytes": String(op.sizeBytes),
            "action": what,
            "status": logStatus,
        ]
        if let output, !output.isEmpty { entry["output"] = output }
        let note = log.recordAfterRun(entry)
        let shownOutput = note.map { [output, $0].compactMap { $0 }.joined(separator: "\n") } ?? output
        return OperationResult(operation: op, status: status, output: shownOutput, remainingPaths: remainingPaths)
    }
}

extension CommandCheck.Purpose {
    /// Why the operation is skipped when the check no longer matches the scan.
    var mismatch: LocalizedMessage {
        switch self {
        case .dockerEngine: LocalizedMessage("Docker now connects to a different engine than the one scanned. Scan again.")
        case .dockerImage: LocalizedMessage("The image tag now points to a different image. Scan again.")
        }
    }
}
