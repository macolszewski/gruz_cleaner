import Foundation
import Testing
@testable import CleanerKit
import ScannerKit

/// Test doubles: nothing here touches real files or runs real commands.
final class FakeFiles: FileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var trashed: [String] = []
    private(set) var deleted: [String] = []
    /// Paths whose removal fails, as with a file the user has no permission to move.
    var failing: Set<String> = []

    func moveToTrash(_ path: String) throws {
        if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { trashed.append(path) }
    }

    func removePermanently(_ path: String) throws {
        if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock { deleted.append(path) }
    }
}

final class FakeCommands: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []

    func locate(_ tool: String) -> String? { "/fake/bin/\(tool)" }

    /// Output of read-only checks, by arguments joined with spaces.
    var outputs: [String: String] = [:]

    func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String) {
        lock.withLock { calls.append([executable] + arguments) }
        return (0, outputs[arguments.joined(separator: " ")] ?? "")
    }
}

struct FakeApps: RunningAppsChecking {
    var runningIDs: Set<String> = []
    func running(_ bundleIDs: [String]) -> [String] { bundleIDs.filter(runningIDs.contains) }
}

final class FakeLog: OperationLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    var isWritable = true

    func record(_ line: String) throws {
        guard isWritable else { throw CocoaError(.fileWriteVolumeReadOnly) }
        lock.withLock { lines.append(line) }
    }

    /// Entries describing operations, without the line that opens each plan.
    var operations: [[String: String]] {
        lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }.filter { $0["item"] != nil }
    }
}

struct FakeSpace: FreeSpaceProviding {
    func freeBytes() -> Int64? { 1_000 }
}

struct TestEnvironment {
    let home: String
    let files = FakeFiles()
    let commands = FakeCommands()
    let log = FakeLog()

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-kit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = (base.path as NSString).resolvingSymlinksInPath
    }

    func make(_ relative: String) throws -> String {
        let path = Paths.join(home, relative)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func executor(running: Set<String> = []) -> CleaningExecutor {
        CleaningExecutor(
            files: files, commands: commands, apps: FakeApps(runningIDs: running), log: log, space: FakeSpace(),
            denylist: Denylist(home: home, protectedRoots: ["~/workspace"])
        )
    }

    func item(_ id: String, paths: [String], action: CleanAction, safety: Safety = .safe,
              owner: [String] = [], requiresClosed: Bool = false) -> ScanItem {
        ScanItem(id: id, category: .apps, title: id, description: "", safety: safety, sizeBytes: 100, paths: paths,
                 action: action, ownerBundleIDs: owner, requiresAppClosed: requiresClosed)
    }
}

@Suite struct PlanTests {
    @Test func onlySelectableLeavesBecomeOperations() throws {
        let h = try TestEnvironment()
        let leaf = h.item("leaf", paths: ["/x"], action: .trash)
        let data = h.item("data", paths: ["/y"], action: .trash, safety: .userData)
        var group = h.item("group", paths: [], action: .trash)
        group.children = [leaf]
        let info = ScanItem(id: "unrec", category: .unrecognized, title: "u", description: "", safety: .caution,
                            paths: ["/z"], action: .trash)
        let plan = CleaningPlan.make(from: [leaf, data, group, info])
        #expect(plan.operations.map(\.id) == ["leaf"])
    }

    @Test func forcePermanentSwitchesTrashOnly() throws {
        let h = try TestEnvironment()
        let a = h.item("a", paths: ["/a"], action: .trash)
        let b = h.item("b", paths: [], action: .command(argv: ["uv", "cache", "clean"]))
        let plan = CleaningPlan.make(from: [a, b], forcePermanent: ["a"])
        #expect(plan.operations.first { $0.id == "a" }?.kind == .permanentDelete)
        #expect(plan.hasPermanent)
        #expect(plan.trashOperations.isEmpty)
    }
}

@Suite struct ExecutorTests {
    @Test func refusesPlanWithoutMatchingConfirmation() async throws {
        let h = try TestEnvironment()
        let path = try h.make("Library/Caches/a")
        let plan = CleaningPlan.make(from: [h.item("a", paths: [path], action: .trash)])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: UUID(), permanentConfirmed: true))
        #expect(h.files.trashed.isEmpty)
        #expect(report.doneCount == 0)
    }

    @Test func trashesConfirmedItems() async throws {
        let h = try TestEnvironment()
        let path = try h.make("Library/Caches/a")
        let plan = CleaningPlan.make(from: [h.item("a", paths: [path], action: .trash)])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed == [path])
        #expect(h.files.deleted.isEmpty)
        #expect(report.doneCount == 1)
        #expect(h.log.operations.count == 1)
    }

    @Test func partialRemovalIsReportedAndLogged() async throws {
        let h = try TestEnvironment()
        let cache = try h.make("Library/Caches/com.example.removedapp")
        let support = try h.make("Library/Application Support/com.example.removedapp")
        h.files.failing = [support]
        let plan = CleaningPlan.make(from: [h.item("orphan", paths: [cache, support], action: .trash)])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed == [cache])
        guard case .partial = report.results.first?.status else {
            Issue.record("expected a partial result")
            return
        }
        #expect(report.results.first?.remainingPaths == [support])
        #expect(report.doneCount == 0)
        let entry = try #require(h.log.operations.first)
        #expect(entry["status"]?.hasPrefix("partial:") == true)
        #expect(entry["status"]?.contains("Application Support") == true)
    }

    @Test func nothingRunsWhenTheLogCannotBeWritten() async throws {
        let h = try TestEnvironment()
        h.log.isWritable = false
        let path = try h.make("Library/Caches/a")
        let plan = CleaningPlan.make(from: [h.item("a", paths: [path], action: .trash)])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed.isEmpty)
        guard case .skipped = report.results.first?.status else {
            Issue.record("expected a skip")
            return
        }
    }

    @Test func dockerCommandsRunOnlyAgainstTheScannedEngine() async throws {
        let h = try TestEnvironment()
        let infoArgs = ["info", "--format", "{{.ID}} {{.Name}}"]
        var item = h.item("vol", paths: [], action: .command(argv: ["docker", "volume", "rm", "shop_db"]))
        item.preconditions = [CommandCheck(argv: ["docker"] + infoArgs, expected: "engine-1 orbstack", purpose: .dockerEngine)]
        let plan = CleaningPlan.make(from: [item])
        let confirmation = CleaningConfirmation(planID: plan.id, permanentConfirmed: true)

        // The CLI context was switched to another engine after the scan.
        h.commands.outputs[infoArgs.joined(separator: " ")] = "engine-2 remote\n"
        let refused = await h.executor().execute(plan, confirmation: confirmation)
        guard case .skipped = refused.results.first?.status else {
            Issue.record("expected a skip")
            return
        }
        #expect(!h.commands.calls.contains { $0.contains("rm") })

        h.commands.outputs[infoArgs.joined(separator: " ")] = "engine-1 orbstack\n"
        let report = await h.executor().execute(plan, confirmation: confirmation)
        #expect(report.doneCount == 1)
        #expect(h.commands.calls.last == ["/fake/bin/docker", "volume", "rm", "shop_db"])
    }

    @Test func oneEngineCheckServesTheWholePlan() async throws {
        let h = try TestEnvironment()
        let info = ["docker", "info", "--format", "{{.ID}} {{.Name}}"]
        h.commands.outputs[info.dropFirst().joined(separator: " ")] = "engine-1 orbstack"
        let items = ["a", "b", "c"].map { name -> ScanItem in
            var item = h.item(name, paths: [], action: .command(argv: ["docker", "volume", "rm", name]))
            item.preconditions = [CommandCheck(argv: info, expected: "engine-1 orbstack", purpose: .dockerEngine)]
            return item
        }
        let plan = CleaningPlan.make(from: items)
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: true))
        #expect(report.doneCount == 3)
        #expect(h.commands.calls.filter { $0.contains("info") }.count == 1)
    }

    @Test func commandsOnFoldersRespectTheDenylist() async throws {
        let h = try TestEnvironment()
        let uvCache = try h.make(".cache/uv")
        let ok = h.item("uv", paths: [uvCache], action: .command(argv: ["uv", "cache", "clean", "--cache-dir", uvCache]))
        let documents = try h.make("Documents")
        let bad = h.item("bad", paths: [documents], action: .command(argv: ["uv", "cache", "clean", "--cache-dir", documents]))
        let plan = CleaningPlan.make(from: [ok, bad])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: true))
        #expect(h.commands.calls == [["/fake/bin/uv", "cache", "clean", "--cache-dir", uvCache]])
        #expect(report.doneCount == 1)
    }

    @Test func permanentNeedsExplicitConfirmation() async throws {
        let h = try TestEnvironment()
        let a = try h.make("Library/Caches/a")
        let b = try h.make("Library/Caches/b")
        let plan = CleaningPlan.make(
            from: [h.item("a", paths: [a], action: .trash), h.item("b", paths: [b], action: .trash)],
            forcePermanent: ["b"]
        )
        let executor = h.executor()
        _ = await executor.execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed == [a])
        #expect(h.files.deleted.isEmpty)

        _ = await executor.execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: true))
        #expect(h.files.deleted == [b])
    }

    @Test func skipsProtectedPaths() async throws {
        let h = try TestEnvironment()
        let documents = try h.make("Documents/important")
        let root = try h.make("workspace")
        let git = try h.make("workspace/app/.git")
        let items = [documents, root, git, h.home].enumerated().map { h.item("p\($0.offset)", paths: [$0.element], action: .trash) }
        let plan = CleaningPlan.make(from: items)
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: true))
        #expect(h.files.trashed.isEmpty)
        #expect(report.doneCount == 0)
    }

    @Test func skipsWhileOwnerAppRuns() async throws {
        let h = try TestEnvironment()
        let path = try h.make("Library/Caches/com.spotify.client")
        let plan = CleaningPlan.make(from: [h.item("s", paths: [path], action: .trash, owner: ["com.spotify.client"], requiresClosed: true)])
        let report = await h.executor(running: ["com.spotify.client"])
            .execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed.isEmpty)
        guard case .skipped(let why) = report.results.first?.status else {
            Issue.record("expected skip")
            return
        }
        #expect(why.contains("com.spotify.client"))
    }

    @Test func runsOnlyAllowListedCommands() async throws {
        let h = try TestEnvironment()
        let ok = h.item("ok", paths: [], action: .command(argv: ["docker", "volume", "rm", "shop_db"]))
        var bad = h.item("bad", paths: [], action: .command(argv: ["docker", "system", "prune", "-af"]))
        bad.safety = .safe
        let plan = CleaningPlan.make(from: [ok, bad])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: true))
        #expect(h.commands.calls == [["/fake/bin/docker", "volume", "rm", "shop_db"]])
        #expect(report.doneCount == 1)
    }

    @Test func commandsAreTreatedAsPermanent() async throws {
        let h = try TestEnvironment()
        let plan = CleaningPlan.make(from: [h.item("uv", paths: [], action: .command(argv: ["uv", "cache", "clean", "--cache-dir", "/tmp/uv"]))])
        _ = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.commands.calls.isEmpty)
    }

    @Test func operationLogIsEnglishWhateverTheUILanguage() async throws {
        let h = try TestEnvironment()
        let path = try h.make("Library/Caches/a")
        let plan = CleaningPlan.make(from: [h.item("a", paths: [path], action: .trash)], forcePermanent: ["a"])
        _ = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        let entry = try #require(h.log.operations.first)
        #expect(entry["status"] == "skipped: Permanent deletion was not confirmed")
        #expect(entry["action"] == "delete \(path)")
    }

    @Test func missingPathIsReportedNotRemoved() async throws {
        let h = try TestEnvironment()
        let plan = CleaningPlan.make(from: [h.item("gone", paths: [Paths.join(h.home, "Library/Caches/gone")], action: .trash)])
        let report = await h.executor().execute(plan, confirmation: CleaningConfirmation(planID: plan.id, permanentConfirmed: false))
        #expect(h.files.trashed.isEmpty)
        guard case .failed = report.results.first?.status else {
            Issue.record("expected failure")
            return
        }
    }
}

@Suite struct LocalizationTests {
    @Test func englishTableAppliesPluralRules() {
        #expect(LocalizedMessage("Removed only part of the data (\(1) records):").english == "Removed only part of the data (1 record):")
        #expect(LocalizedMessage("Removed only part of the data (\(3) records):").english == "Removed only part of the data (3 records):")
        let progress = String(localized: "Rebuilding Chroma: \(1) of \(1) documents (\("100%")).", bundle: .cleanerKitEnglish)
        #expect(progress == "Rebuilding Chroma: 1 of 1 document (100%).")
    }
}
