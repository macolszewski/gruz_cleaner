import Foundation
import Synchronization
import Testing
@testable import ScannerKit

/// The single project walk, the shared scan cache and the file system pool must give the same answers
/// as the separate walks and fresh reads they replace.
@Suite struct ProjectDiscoveryTests {
    @Test func oneWalkFindsWhatEachSearchFindsAlone() throws {
        let fx = try Fixture()
        try fx.file("ws/web/package.json")
        try fx.file("ws/web/node_modules/left-pad/index.js")
        // The artifact search skips `vendor`'s contents only for Cargo; it still finds this dependency folder.
        try fx.file("ws/vendor/lib/package.json")
        try fx.file("ws/vendor/lib/node_modules/x/index.js")
        // An unrecognized `build` folder is pruned by the artifact search but not by the Cargo search:
        // the crate inside is found, the dependency folder next to it is not.
        try fx.file("ws/build/crate/Cargo.toml")
        try fx.dir("ws/build/crate/target")
        try fx.file("ws/build/crate/package.json")
        try fx.file("ws/build/crate/node_modules/y/index.js")
        // A crate inside a dependency folder is never a project of the user.
        try fx.file("ws/web/node_modules/native/Cargo.toml")
        try fx.dir("ws/web/node_modules/native/target")
        // Deeper than the artifact search looks, within the Cargo search's depth.
        let deep = (1...13).map { "d\($0)" }.joined(separator: "/")
        try fx.file("ws/\(deep)/Cargo.toml")
        try fx.dir("ws/\(deep)/target")
        try fx.file("ws/\(deep)/package.json")
        try fx.file("ws/\(deep)/node_modules/z/index.js")

        let catalog = try RuleCatalog.builtIn()
        let walk = ProjectDiscovery.walk(root: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent", environment: [:])
        let artifacts = Set(walk.artifacts.map(\.path))
        let targets = Set(walk.rust.map(\.target))

        #expect(artifacts.contains(fx.path("ws/web/node_modules")))
        #expect(artifacts.contains(fx.path("ws/vendor/lib/node_modules")))
        #expect(!artifacts.contains(fx.path("ws/build/crate/node_modules")))
        #expect(!artifacts.contains(fx.path("ws/\(deep)/node_modules")))
        #expect(targets.contains(fx.path("ws/build/crate/target")))
        #expect(targets.contains(fx.path("ws/\(deep)/target")))
        #expect(!targets.contains(fx.path("ws/web/node_modules/native/target")))

        // Each search alone gives the same answer as the combined walk.
        let artifactsAlone = ProjectSource.findArtifacts(in: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent")
        #expect(artifactsAlone.map(\.path) == walk.artifacts.map(\.path))
        let rustAlone = RustDiscovery.find(in: [fx.path("ws")], home: "/nonexistent", environment: [:])
        #expect(rustAlone == RustDiscovery.sorted(walk.rust))
    }

    @Test func unreadableFoldersAreReportedOnlyWhereArtifactsAreSearched() throws {
        let fx = try Fixture()
        try fx.dir("ws/locked")
        try fx.file("ws/build/crate/Cargo.toml")
        try fx.dir("ws/build/crate/locked")
        chmod(fx.path("ws/locked"), 0)
        chmod(fx.path("ws/build/crate/locked"), 0)
        defer {
            chmod(fx.path("ws/locked"), 0o755)
            chmod(fx.path("ws/build/crate/locked"), 0o755)
        }
        let catalog = try RuleCatalog.builtIn()
        let walk = ProjectDiscovery.walk(root: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent", environment: [:])
        #expect(walk.unreadable == [fx.path("ws/locked")])
    }
}

@Suite struct ScanCacheTests {
    @Test func globWithSharedListingsMatchesAFreshExpansion() throws {
        let fx = try Fixture()
        for product in ["IntelliJIdea2025.3", "PyCharm2025.3", ".hidden"] {
            for sub in ["caches", "index", "LocalHistory"] { try fx.dir("Caches/JetBrains/\(product)/\(sub)") }
        }
        let cache = ScanCache()
        for pattern in ["Caches/JetBrains/*/caches", "Caches/JetBrains/*/index", "Caches/JetBrains/*", "Caches/JetBrains/.*"] {
            let shared = cache.glob(fx.path(pattern), home: fx.root)
            let fresh = Paths.globReporting(fx.path(pattern), home: fx.root)
            #expect(shared.matches == fresh.matches)
            #expect(shared.unreadable == fresh.unreadable)
        }
    }

    @Test func measurementsAreReusedOnlyForTheSameExclusions() async throws {
        let fx = try Fixture()
        try fx.file("tree/a.bin", bytes: 64_000)
        try fx.file("tree/skip/b.bin", bytes: 64_000)
        let cache = ScanCache(), pool = IOPool(width: 2)
        let whole = await cache.measure(fx.path("tree"), pool: pool)
        try fx.file("tree/c.bin", bytes: 64_000)
        // The same question within one scan gets the first answer.
        #expect(await cache.measure(fx.path("tree"), pool: pool) == whole)
        // Different exclusions are a different measurement, read from the disk.
        let partial = await cache.measure(fx.path("tree"), excluding: [fx.path("tree/skip")], pool: pool)
        #expect(partial == SizeCalculator.measure(fx.path("tree"), excluding: [fx.path("tree/skip")]))
        #expect(partial.fileCount == 2)
    }

    @Test func checksBeforeRemovalDoNotUseTheScanCache() throws {
        let fx = try Fixture()
        try fx.dir("home/Library/Caches/JetBrains/IntelliJIdea2025.3/caches")
        let denylist = Denylist(home: fx.path("home"))
        let cache = ScanCache()
        let path = fx.path("home/Library/Caches/JetBrains/IntelliJIdea2025.3")
        #expect(denylist.check(path, cache: cache) == .allowed)
        try fx.dir("home/Library/Caches/JetBrains/IntelliJIdea2025.3/LocalHistory")
        // The scan keeps the answer it read; the check the cleaner runs reads the disk again.
        #expect(denylist.check(path, cache: cache) == .allowed)
        #expect(denylist.check(path) != .allowed)
    }
}

@Suite struct IOPoolTests {
    @Test func neverRunsMoreThanItsWidth() async {
        final class Running: Sendable { let state = Mutex((now: 0, peak: 0)) }
        let pool = IOPool(width: 3), running = Running()
        let results = await pool.map(Array(0..<24)) { input, _ in
            running.state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            usleep(20_000)
            running.state.withLock { $0.now -= 1 }
            return input * 2
        }
        #expect(results.count == 24)
        #expect(results[5] == 10)
        #expect(running.state.withLock { $0.peak } <= 3)
    }

    @Test func cancellingTheTaskReachesTheWork() async {
        let pool = IOPool(width: 1)
        let task = Task {
            await pool.run { flag in
                for _ in 0..<500 where !flag.isCancelled { usleep(10_000) }
                return flag.isCancelled
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value)
    }
}

@Suite struct RustSignatureTests {
    @Test func signatureNamesItsFormatAndFollowsNameOrder() throws {
        let fx = try Fixture()
        try fx.file("deps/b.o", bytes: 4096)
        try fx.file("deps/a.o", bytes: 4096)
        try fx.file("deps/sub/c.o", bytes: 4096)
        let first = RustArtifacts.measure(fx.path("deps"), since: .distantPast)
        #expect(first.signature.hasPrefix(RustArtifacts.signatureFormat))
        #expect(first.problem == nil)
        #expect(RustArtifacts.measure(fx.path("deps"), since: .distantPast).signature == first.signature)
        try FileManager.default.moveItem(atPath: fx.path("deps/b.o"), toPath: fx.path("deps/d.o"))
        #expect(RustArtifacts.measure(fx.path("deps"), since: .distantPast).signature != first.signature)
    }

    @Test func dataInsideTheTreeStillBlocksRemoval() throws {
        let fx = try Fixture()
        try fx.file("deps/a.o")
        try fx.file("deps/nested/store.SQLite")
        #expect(RustArtifacts.measure(fx.path("deps"), since: .distantPast).problem != nil)
    }
}
