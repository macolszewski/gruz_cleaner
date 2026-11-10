import Foundation
import Testing
@testable import ScannerKit

@Suite struct RustTests {
    @Test func profilesKeepApplicationsAndUnknownData() throws {
        let f = try Fixture()
        try f.file("app/Cargo.toml")
        for profile in ["debug", "release", "aarch64-apple-darwin/custom"] {
            try f.file("app/target/\(profile)/.cargo-lock", bytes: 0)
            try f.dir("app/target/\(profile)/.fingerprint")
            try f.file("app/target/\(profile)/deps/unit.o", bytes: 8000)
        }
        try f.file("app/target/release/App.app/Contents/MacOS/app", bytes: 8000)
        try f.file("app/target/debug/build/customer.sqlite", bytes: 8000)
        let item = RustArtifacts.items(target: f.path("app/target"))
        #expect(item.children.count == 3)
        let leaves = item.leaves
        #expect(leaves.filter(\.isSelectable).count == 3)
        #expect(leaves.filter(\.isSelectable).allSatisfy { $0.paths.first?.hasSuffix("/deps") == true })
        #expect(leaves.contains { $0.title.contains("App.app") && !$0.isSelectable })
        #expect(leaves.contains { $0.paths.first?.hasSuffix("/build") == true && !$0.isSelectable })
        #expect(leaves.filter(\.isSelectable).allSatisfy { $0.rustArtifact != nil })
    }

    @Test func refusesSymlinksAndUnknownTargets() throws {
        let f = try Fixture()
        try f.file("unknown/important.txt")
        #expect(RustArtifacts.items(target: f.path("unknown")).leaves.allSatisfy { !$0.isSelectable })
        try f.dir("deps")
        try FileManager.default.createSymbolicLink(atPath: f.path("deps/link"), withDestinationPath: f.path("unknown"))
        #expect(RustArtifacts.measure(f.path("deps"), since: .distantPast).problem != nil)
    }

    @Test func signatureDetectsRewritesAndMissingPaths() throws {
        let f = try Fixture()
        try f.file("deps/unit.o", bytes: 8192)
        let before = RustArtifacts.measure(f.path("deps"), since: .distantPast)
        #expect(before.recentBytes > 0)
        try f.file("deps/unit.o", bytes: 16384)
        let after = RustArtifacts.measure(f.path("deps"), since: .distantPast)
        #expect(before.signature != after.signature)
        #expect(RustArtifacts.measure(f.path("missing"), since: .distantPast).problem != nil)
    }

    @Test func hardlinksAreCountedOnceWithinSubtree() throws {
        let f = try Fixture()
        try f.file("deps/a.o", bytes: 8192)
        let before = RustArtifacts.measure(f.path("deps"), since: .distantPast)
        try FileManager.default.linkItem(atPath: f.path("deps/a.o"), toPath: f.path("deps/b.o"))
        let after = RustArtifacts.measure(f.path("deps"), since: .distantPast)
        #expect(before.bytes == after.bytes)
        #expect(before.signature != after.signature)
    }

    @Test func claimsRejectOverlapsInEitherOrder() async {
        let a = ClaimRegistry()
        #expect(await a.claim("/project/target/debug"))
        #expect(!(await a.claim("/project/target")))
        let b = ClaimRegistry()
        #expect(await b.claim("/project/target"))
        #expect(!(await b.claim("/project/target/debug")))
    }

    @Test func dockerSharedCacheAndVolumesAreNotSafeReclaim() throws {
        let json = #"{"BuildCache":[{"InUse":"false","Shared":"true","Size":"36GB"},{"InUse":"false","Shared":"false","Size":"5GB"},{"InUse":"true","Shared":"false","Size":"2GB"},{"Size":"7GB"}],"Volumes":[{"Name":"abc","Labels":"com.docker.volume.anonymous=true","Links":"0","Size":"1GB"}]}"#
        let items = DockerSource.parse(try JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8)), engine: "engine-1")
        #expect(items.first { $0.id == "docker.buildcache" }?.sizeBytes == 5_000_000_000)
        #expect(items.first { $0.id == "docker.volumes.anonymous" }?.children.first?.safety == .caution)
    }

    @Test func legacyScanItemsDecodeWithoutRustOrHistoryFields() throws {
        let item = ScanItem(id: "old", category: .projects, title: "old", description: "", safety: .regenerable)
        let decoded = try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.rustArtifact == nil && decoded.growth == nil)
    }
}

@Suite struct UsageHistoryTests {
    func item(_ bytes: Int64) -> ScanItem {
        ScanItem(id: "same", category: .rust, title: "target", description: "", safety: .regenerable, sizeBytes: bytes)
    }
    @Test func growthUsesComparableHistoryAndNeverInventsMissingBaseline() {
        let base = UsageSnapshot(date: Date(timeIntervalSince1970: 100), scope: "a", items: [item(100)])
        #expect(UsageHistory.annotate([item(250)], baseline: base).first?.growth?.deltaBytes == 150)
        #expect(UsageHistory.annotate([item(50)], baseline: base).first?.growth?.deltaBytes == -50)
        #expect(UsageHistory.annotate([item(50)], baseline: nil).first?.growth == nil)
        #expect(UsageHistory.baseline(in: [base], scope: "other", now: Date(timeIntervalSince1970: 200)) == nil)
    }
    @Test func keepsOneSnapshotPerDayAndThirtyDays() {
        let now = Date()
        let old = UsageSnapshot(date: now.addingTimeInterval(-40 * 86400), scope: "a", items: [item(1)])
        let prior = UsageSnapshot(date: now.addingTimeInterval(-1), scope: "a", items: [item(2)])
        let current = UsageSnapshot(date: now, scope: "a", items: [item(3)])
        let saved = UsageHistory.retaining([old, prior], adding: current)
        #expect(saved.count == 1)
        #expect(saved.first?.sizes["same"] == 3)
    }
}

@Suite struct RustDiscoveryTests {
    @Test func findsDefaultConfiguredAndHiddenWorktreeTargets() throws {
        let f = try Fixture()
        try f.file("ws/app/Cargo.toml")
        try f.dir("ws/app/target")
        try f.dir("ws/shared-output")
        try f.dir("ws/app/.cargo")
        try Data("[build]\ntarget-dir = '../shared-output'\n".utf8).write(to: URL(fileURLWithPath: f.path("ws/app/.cargo/config.toml")))
        try f.file("ws/app/.claude/worktrees/task/Cargo.toml")
        try f.dir("ws/app/.claude/worktrees/task/target")
        try f.file("ws/app/node_modules/not-a-project/Cargo.toml")
        try f.dir("ws/app/node_modules/not-a-project/target")
        let result = RustDiscovery.find(in: [f.path("ws")], home: f.path("home"), environment: [:])
        let paths = Set(result.map(\.target))
        #expect(paths.contains(f.path("ws/app/target")))
        #expect(paths.contains(f.path("ws/shared-output")))
        #expect(paths.contains(f.path("ws/app/.claude/worktrees/task/target")))
        #expect(!paths.contains { $0.contains("node_modules") })
        #expect(RustDiscovery.literalBuildDirectories("[build]\nbuild-dir = '{workspace-root}/build'").isEmpty)
    }
}
