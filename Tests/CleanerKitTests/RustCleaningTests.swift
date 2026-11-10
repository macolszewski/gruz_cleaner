import Darwin
import Foundation
import Testing
@testable import ScannerKit
@testable import CleanerKit

private struct RustFixture {
    let h: TestEnvironment
    let artifact: RustArtifact
    let item: ScanItem
    init() throws {
        h = try TestEnvironment()
        let root = try h.make("workspace/app")
        try Data("[package]\nname = 'fixture'".utf8).write(to: URL(fileURLWithPath: root + "/Cargo.toml"))
        let profile = try h.make("workspace/app/target/debug")
        try Data().write(to: URL(fileURLWithPath: profile + "/.cargo-lock"))
        let path = try h.make("workspace/app/target/debug/deps")
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path + "/unit.o"))
        let measurement = RustArtifacts.measure(path, since: .distantPast)
        artifact = RustArtifact(targetRoot: root + "/target", profileRoot: profile, path: path,
            signature: measurement.signature, recentBytes: 8192, since: .distantPast)
        var value = h.item("rust", paths: [path], action: .trash, safety: .regenerable)
        value.rustArtifact = artifact
        item = value
    }
    func executor(processes: String = "") -> CleaningExecutor {
        CleaningExecutor(files: h.files, commands: h.commands, apps: FakeApps(), log: h.log, space: FakeSpace(),
            denylist: Denylist(home: h.home), rustGuard: SystemRustRemovalGuard(processListing: { processes }))
    }
}

@Suite struct RustCleaningTests {
    @Test func confirmedArtifactUsesFakeTrashOnly() async throws {
        let f = try RustFixture()
        let plan = CleaningPlan.make(from: [f.item])
        let report = await f.executor().execute(plan, confirmation: .init(planID: plan.id, permanentConfirmed: false))
        #expect(report.doneCount == 1)
        #expect(f.h.files.trashed == [f.artifact.path])
        #expect(FileManager.default.fileExists(atPath: f.artifact.path + "/unit.o"))
    }
    @Test func activeCompilerAndRunningArtifactBlockRemoval() async throws {
        let f = try RustFixture()
        let plan = CleaningPlan.make(from: [f.item])
        for process in ["/toolchain/bin/rustc", f.artifact.profileRoot + "/program"] {
            let report = await f.executor(processes: process).execute(plan, confirmation: .init(planID: plan.id, permanentConfirmed: false))
            #expect(report.doneCount == 0)
        }
        #expect(f.h.files.trashed.isEmpty)
    }
    @Test func changedFilesInvalidateSelection() async throws {
        let f = try RustFixture()
        try Data(repeating: 2, count: 16384).write(to: URL(fileURLWithPath: f.artifact.path + "/unit.o"))
        let plan = CleaningPlan.make(from: [f.item])
        let report = await f.executor().execute(plan, confirmation: .init(planID: plan.id, permanentConfirmed: false))
        #expect(report.doneCount == 0)
        #expect(f.h.files.trashed.isEmpty)
    }
    @Test func cargoLockBlocksRemoval() throws {
        let f = try RustFixture()
        let fd = open(f.artifact.profileRoot + "/.cargo-lock", O_RDWR)
        #expect(fd >= 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let guarder = SystemRustRemovalGuard(processListing: { "" })
        #expect(throws: RustRemovalError.self) { try guarder.acquire(f.artifact, paths: [f.artifact.path]) }
    }
    @Test func overlappingSelectionsCannotDoubleDelete() throws {
        let f = try RustFixture()
        let parent = f.h.item("parent", paths: [f.artifact.profileRoot], action: .trash)
        let plan = CleaningPlan.make(from: [f.item, parent, f.item])
        #expect(plan.operations.count == 1)
    }
}
