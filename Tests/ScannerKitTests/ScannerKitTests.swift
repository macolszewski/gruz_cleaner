import Foundation
import Testing
@testable import ScannerKit

/// Creates fixtures in a fresh temp directory. Fixtures are left for the OS to clean up; tests never remove files.
struct Fixture {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = (base.path as NSString).resolvingSymlinksInPath
    }

    func path(_ relative: String) -> String { Paths.join(root, relative) }

    func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int = 10) throws {
        try dir((relative as NSString).deletingLastPathComponent)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path(relative)))
    }

    func file(_ relative: String, contents: String) throws {
        try dir((relative as NSString).deletingLastPathComponent)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path(relative)))
    }
}

@Suite struct CommandPolicyTests {
    @Test func allowsKnownCleanCommands() {
        let sock = "unix:///Users/me/.orbstack/run/docker.sock"
        #expect(CommandPolicy.isAllowedCleanCommand(["docker", "--host", sock, "image", "rm", "nginx:alpine"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["docker", "--host", sock, "builder", "prune", "--force"]))
        // A Docker command must name the engine endpoint, never rely on the CLI's current context.
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "image", "rm", "nginx:alpine"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "--host", "-H", "image", "rm", "nginx:alpine"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["xcrun", "simctl", "delete", "2CC2A9FF-BC88-4309-87CE-AE583195DD9B"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["uv", "cache", "clean", "--cache-dir", "/Users/me/.cache/uv"]))
        // Without the folder, uv would clean whatever cache its configuration points to.
        #expect(!CommandPolicy.isAllowedCleanCommand(["uv", "cache", "clean"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["go", "clean", "-modcache"]))
        #expect(CommandPolicy.isAllowedCheckCommand(["go", "env", "GOMODCACHE"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["go", "clean", "-cache", "-modcache"]))
    }

    @Test func gitInspectionDisablesConfiguredPrograms() {
        let argv = ["git"] + GitInspection.options + ["-C", "/Users/me/code/app", "status", "--porcelain"]
        #expect(CommandPolicy.isAllowedReadOnlyCommand(argv))
        #expect(GitInspection.options.contains("core.fsmonitor=false"))
        #expect(GitInspection.options.contains("--no-optional-locks"))
        #expect(!CommandPolicy.isAllowedReadOnlyCommand(["git", "-C", "/Users/me/code/app", "status", "--porcelain"]))
    }

    @Test func rejectsEverythingElse() {
        #expect(!CommandPolicy.isAllowedCleanCommand(["rm", "-rf", "/"]))
        let host = ["docker", "--host", "unix:///var/run/docker.sock"]
        #expect(!CommandPolicy.isAllowedCleanCommand(host + ["system", "prune", "-a"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(host + ["volume", "rm", "-f"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(host + ["volume", "rm", "a", "b"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(host + ["volume", "prune"]))
        #expect(!CommandPolicy.isAllowedCleanCommand([]))
    }

    @Test func readOnlyListIsSeparate() {
        #expect(CommandPolicy.isAllowedReadOnlyCommand(["xcrun", "simctl", "list", "devices", "--json"]))
        #expect(!CommandPolicy.isAllowedReadOnlyCommand(["docker", "image", "rm", "x"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["xcrun", "simctl", "list", "devices", "--json"]))
    }
}

@Suite struct DenylistTests {
    let home = "/Users/tester"
    var denylist: Denylist { Denylist(home: home, protectedRoots: ["~/workspace", "~/code"]) }

    @Test func protectsHomeAndUserFolders() {
        #expect(denylist.check(home) != .allowed)
        #expect(denylist.check("\(home)/Documents/report.pdf") != .allowed)
        #expect(denylist.check("\(home)/Desktop") != .allowed)
        #expect(denylist.check("\(home)/Library/Caches") != .allowed)
        #expect(denylist.check("\(home)/.ssh/id_ed25519") != .allowed)
    }

    @Test func protectsSystemAndOutsideHome() {
        #expect(denylist.check("/System/Library") != .allowed)
        #expect(denylist.check("/usr/local/bin/x") != .allowed)
        #expect(denylist.check("/Applications/Xcode.app") != .allowed)
        #expect(denylist.check("/tmp/x") != .allowed)
        #expect(denylist.check("relative/path") != .allowed)
    }

    @Test func protectsGitAndProjectRoots() {
        #expect(denylist.check("\(home)/workspace") != .allowed)
        #expect(denylist.check("\(home)/code") != .allowed)
        #expect(denylist.check("\(home)/workspace/app/.git") != .allowed)
        #expect(denylist.check("\(home)/workspace/app/.git/objects") != .allowed)
    }

    @Test func allowsCacheAndArtifacts() {
        #expect(denylist.check("\(home)/Library/Caches/com.spotify.client") == .allowed)
        #expect(denylist.check("\(home)/workspace/app/node_modules") == .allowed)
        #expect(denylist.check("\(home)/.cache/uv") == .allowed)
    }

    @Test func normalizesTraversal() {
        #expect(denylist.check("\(home)/Library/Caches/../../Documents") != .allowed)
        #expect(denylist.check("\(home)/Library/Caches/x/..") != .allowed)
    }

    @Test func symlinkedParentCannotEscape() throws {
        let fx = try Fixture()
        try fx.dir("home/Library/Caches")
        try fx.dir("home/Documents/secret")
        try FileManager.default.createSymbolicLink(atPath: fx.path("home/Library/Caches/link"), withDestinationPath: fx.path("home/Documents"))
        let d = Denylist(home: fx.path("home"))
        #expect(d.check(fx.path("home/Library/Caches/link/secret")) != .allowed)
    }

    @Test func symlinkedCacheFolderLeadingToSourceIsRefused() throws {
        // ~/.npm/_npx -> ~/workspace/app/src: the target is an allowed place, yet it is not a cache.
        let fx = try Fixture()
        try fx.file("home/workspace/app/src/main.swift")
        try fx.dir("home/.npm")
        try FileManager.default.createSymbolicLink(atPath: fx.path("home/.npm/_npx"), withDestinationPath: fx.path("home/workspace/app/src"))
        let d = Denylist(home: fx.path("home"))
        #expect(d.check(fx.path("home/.npm/_npx/main.swift")) != .allowed)
        // Removing the link itself only removes the link.
        #expect(d.check(fx.path("home/.npm/_npx")) == .allowed)
    }

    @Test func unreadableFolderMayHidePreservedData() throws {
        // Local History cannot be ruled out inside an IDE folder that cannot be entered, so the whole
        // JetBrains folder must not be taken by a broad cache rule.
        let fx = try Fixture()
        try fx.file("home/Library/Caches/JetBrains/Rider2025.2/LocalHistory/changes.storageData")
        try fx.file("home/Library/Caches/JetBrains/other.bin", contents: "x")
        let ide = fx.path("home/Library/Caches/JetBrains/Rider2025.2")
        chmod(ide, 0)
        defer { chmod(ide, 0o755) }
        let d = Denylist(home: fx.path("home"))
        #expect(d.check(fx.path("home/Library/Caches/JetBrains")) != .allowed)
        #expect(d.check(fx.path("home/Library/Caches/JetBrains/other.bin")) == .allowed)
    }

    @Test func everyRemovalRootChecksLinksBelowIt() {
        // An Android system image linked to a project folder must not turn its sources into "SDK data".
        let home = "/Users/tester"
        for root in Paths.removalRoots(home: home) {
            #expect(Paths.trustedAnchor(of: root + "/system-images/android-35/src", home: home) == root)
        }
        #expect(Paths.trustedAnchor(of: home + "/Library/Caches/x", home: home) == home)
        #expect(Paths.trustedAnchor(of: "/Applications/X.app", home: home) == nil)
    }

    @Test func dataThatCannotBeRecreatedIsKeptInsideCaches() throws {
        let fx = try Fixture()
        try fx.file("home/Library/Caches/JetBrains/Rider2025.2/LocalHistory/changes.storageData")
        try fx.dir("home/Library/Caches/JetBrains/Rider2025.2/caches")
        try fx.file("home/.cache/huggingface/token", contents: "hf_x")
        try fx.dir("home/.cache/huggingface/hub")
        let d = Denylist(home: fx.path("home"))
        #expect(d.check(fx.path("home/Library/Caches/JetBrains/Rider2025.2/caches")) == .allowed)
        #expect(d.check(fx.path("home/Library/Caches/JetBrains/Rider2025.2/LocalHistory")) != .allowed)
        // A broad rule over ~/Library/Caches/* must not take Local History along with its parent.
        #expect(d.check(fx.path("home/Library/Caches/JetBrains/Rider2025.2")) != .allowed)
        #expect(d.check(fx.path("home/Library/Caches/JetBrains")) != .allowed)
        #expect(d.check(fx.path("home/.cache/huggingface/hub")) == .allowed)
        #expect(d.check(fx.path("home/.cache/huggingface")) != .allowed)
    }
}

@Suite struct PathTests {
    @Test func expandsHome() {
        #expect(Paths.expand("~/x/", home: "/Users/a") == "/Users/a/x")
        #expect(Paths.expand("~", home: "/Users/a") == "/Users/a")
    }

    @Test func globMatchesComponentsAndSkipsHidden() throws {
        let fx = try Fixture()
        try fx.dir("Caches/a-updater")
        try fx.dir("Caches/b-updater")
        try fx.dir("Caches/.hidden-updater")
        try fx.dir("Caches/other")
        let found = Paths.glob(fx.path("Caches/*-updater"))
        #expect(found == [fx.path("Caches/a-updater"), fx.path("Caches/b-updater")])
        #expect(Paths.glob(fx.path("Missing/*")).isEmpty)
    }

    @Test func globDoesNotFollowSymlinkedFolders() throws {
        let fx = try Fixture()
        try fx.file("home/workspace/app/src/main.swift")
        try fx.dir("home/.npm/_cacache/index")
        try FileManager.default.createSymbolicLink(atPath: fx.path("home/.npm/_npx"), withDestinationPath: fx.path("home/workspace/app/src"))
        #expect(Paths.glob("~/.npm/_npx/*", home: fx.path("home")).isEmpty)
        #expect(Paths.glob("~/.npm/*", home: fx.path("home")) == [fx.path("home/.npm/_cacache"), fx.path("home/.npm/_npx")])
    }

    @Test func versionCompare() {
        #expect(VersionCompare.isNewer("v26.3.0", than: "v9.10.0"))
        #expect(VersionCompare.isNewer("1.10", than: "1.9"))
        #expect(!VersionCompare.isNewer("2.1.283", than: "2.1.286"))
    }
}

@Suite struct SizeTests {
    @Test func countsAllocatedBlocksAndDedupesHardlinks() throws {
        let fx = try Fixture()
        try fx.file("tree/a.bin", bytes: 100_000)
        try FileManager.default.linkItem(atPath: fx.path("tree/a.bin"), toPath: fx.path("tree/b.bin"))
        let info = SizeCalculator.measure(fx.path("tree"))
        #expect(info.fileCount == 1)
        #expect(info.allocatedBytes >= 100_000)
        #expect(info.allocatedBytes < 200_000)
        #expect(info.newestModification != nil)
    }

    @Test func reportsUnreadableContents() throws {
        let fx = try Fixture()
        try fx.file("tree/readable.bin", bytes: 10_000)
        try fx.file("tree/locked/hidden.bin", bytes: 10_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.path("tree/locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path("tree/locked")) }
        let info = SizeCalculator.measure(fx.path("tree"))
        #expect(info.isPartial)
        #expect(SizeCalculator.measure(fx.path("tree/readable.bin")).isPartial == false)
        #expect(SizeCalculator.measure(fx.path("missing")).isPartial == false)
    }

    @Test func excludesSubtrees() throws {
        let fx = try Fixture()
        try fx.file("tree/keep.bin", bytes: 50_000)
        try fx.file("tree/skip/big.bin", bytes: 500_000)
        let all = SizeCalculator.measure(fx.path("tree"))
        let partial = SizeCalculator.measure(fx.path("tree"), excluding: [fx.path("tree/skip")])
        #expect(all.allocatedBytes > partial.allocatedBytes + 400_000)
    }
}

@Suite struct RuleTests {
    @Test func builtInCatalogLoadsAndValidates() throws {
        let catalog = try RuleCatalog.builtIn()
        #expect(catalog.rules.count > 40)
        #expect(!catalog.artifacts.isEmpty)
        for rule in catalog.rules where rule.safety == .userData {
            #expect(rule.action == nil, "\(rule.id)")
        }
        for rule in catalog.rules {
            if case .command(let argv)? = rule.action { #expect(CommandPolicy.isAllowedCleanCommand(argv), "\(rule.id)") }
        }
    }

    @Test func removableRulesNeverTargetProtectedPaths() throws {
        let catalog = try RuleCatalog.builtIn()
        let home = "/Users/tester"
        let denylist = Denylist(home: home, protectedRoots: ["~/workspace"])
        for rule in catalog.rules where rule.action != nil {
            for pattern in rule.paths {
                // Replace globs with a sample name to get a concrete candidate path.
                let sample = Paths.expand(pattern, home: home)
                    .split(separator: "/").map { Paths.isGlob(String($0)) ? "sample" : String($0) }.joined(separator: "/")
                guard !sample.contains("$TMPDIR") else { continue }
                #expect(denylist.check("/" + sample) == .allowed, "\(rule.id): \(pattern)")
            }
        }
    }

    @Test func oldVersionsKeepNewestPerName() throws {
        let fx = try Fixture()
        for d in ["chromium-1208", "chromium-1243", "chromium-1234", "webkit-2248", "ffmpeg-1011", "ffmpeg-1020"] {
            try fx.dir("pw/\(d)")
        }
        let old = RuleSource.oldVersions(in: fx.path("pw"), pattern: "^(?<name>.+)-(?<version>[0-9]+)$")
        #expect(Set(old) == [fx.path("pw/chromium-1208"), fx.path("pw/chromium-1234"), fx.path("pw/ffmpeg-1011")])
    }

    @Test func childTitles() {
        #expect(RuleSource.childTitle("/x/DerivedData/Runner-cwxmrjqzjxbbaagxigbifokpegju", style: .derivedData, home: "/Users/a") == "Runner")
        #expect(RuleSource.childTitle("/x/models--mlx-community--whisper", style: .huggingFace, home: "/Users/a") == "mlx-community/whisper")
        #expect(RuleSource.prettyClaudeProject("-Users-a-workspace-cleaner", home: "/Users/a") == "~/workspace-cleaner")
    }

    @Test func ruleSourceGroupsAndRespectsOverlap() async throws {
        let fx = try Fixture()
        try fx.file("home/Library/Caches/com.spotify.client/data", bytes: 20_000)
        try fx.file("home/Library/Caches/Homebrew/bottle.tar.gz", bytes: 30_000)
        try fx.file("home/Library/Caches/com.example.tool/x", bytes: 5_000)
        try fx.file("home/.npm/_cacache/index", bytes: 5_000)
        let catalog = try RuleCatalog.builtIn()
        let ctx = ScanContext(
            catalog: catalog, options: ScanOptions(projectRoots: [], home: fx.path("home")), claims: ClaimRegistry(),
            denylist: Denylist(home: fx.path("home")), warnings: WarningSink()
        )
        let items = await RuleSource.scan(ctx)
        let ids = Set(items.map(\.id))
        #expect(ids.contains("spotify.cache"))
        #expect(ids.contains("homebrew.cache"))
        #expect(ids.contains("npm.cacache"))
        let other = try #require(items.first { $0.id == "system.other-caches" })
        // Spotify and Homebrew are claimed by their own rules; only the unknown cache falls into the catch-all.
        #expect(other.children.map(\.title) == ["com.example.tool"])
    }

    @Test func foldersThatCannotBeReadAreReported() async throws {
        let fx = try Fixture()
        try fx.file("home/Library/Caches/com.example.tool/x", bytes: 5_000)
        try fx.file("home/workspace/app/locked/node_modules/x/index.js", bytes: 5_000)
        let locked = [fx.path("home/Library/Caches"), fx.path("home/workspace/app/locked")]
        for path in locked { chmod(path, 0) }
        defer { for path in locked { chmod(path, 0o755) } }

        let ctx = ScanContext(
            catalog: try RuleCatalog.builtIn(),
            options: ScanOptions(projectRoots: [fx.path("home/workspace")], home: fx.path("home")), claims: ClaimRegistry(),
            denylist: Denylist(home: fx.path("home")), warnings: WarningSink()
        )
        _ = await RuleSource.scan(ctx)
        _ = await ProjectSource.scan(ctx)
        let warning = try #require(await ctx.warnings.messages.first { $0.contains("could not be read") })
        #expect(warning.contains("Library/Caches"))
        #expect(warning.contains("locked"))
    }

    @Test func informationalRuleMeasuresTheRemainderAroundClaimedPaths() async throws {
        let fx = try Fixture()
        try fx.file("home/.tool/cache/blob", bytes: 40_000)
        try fx.file("home/.tool/settings.json", bytes: 3_000)
        try fx.file("rules/rules-10-test.json", contents: """
        [
          {"id": "tool.cache", "category": "apps", "title": "Cache", "description": "d", "safety": "safe",
           "paths": ["~/.tool/cache"], "action": {"type": "trash"}},
          {"id": "tool.data", "category": "apps", "title": "Data", "description": "d", "safety": "userData",
           "paths": ["~/.tool"]}
        ]
        """)
        try fx.file("rules/artifacts.json", contents: "[]")
        try fx.file("rules/orphans.json", contents: #"{"searchDirs": [], "ignoredIDs": [], "aliases": {}, "minimumSizeMB": 10}"#)
        let catalog = try RuleCatalog.load(from: URL(fileURLWithPath: fx.path("rules")), language: "en")
        let ctx = ScanContext(
            catalog: catalog, options: ScanOptions(projectRoots: [], home: fx.path("home")), claims: ClaimRegistry(),
            denylist: Denylist(home: fx.path("home")), warnings: WarningSink()
        )
        let items = await RuleSource.scan(ctx)
        let cache = try #require(items.first { $0.id == "tool.cache" })
        let data = try #require(items.first { $0.id == "tool.data" })
        // The user data item covers the folder but excludes the cache already reported on its own.
        #expect(data.sizeBytes < cache.sizeBytes)
        #expect(data.sizeBytes > 0)
    }
}

@Suite struct DockerParsingTests {
    let json = """
    {"Images":[
      {"Containers":"0","CreatedAt":"2026-09-30 10:45:46 +0200 CEST","ID":"sha256:aaa","Repository":"shop-worker","Tag":"audit","UniqueSize":"23.86MB","Size":"23.9MB"},
      {"Containers":"1","CreatedAt":"2026-09-30 10:45:46 +0200 CEST","ID":"sha256:bbb","Repository":"shop-api","Tag":"latest","UniqueSize":"602.9MB","Size":"2.43GB"},
      {"Containers":"0","ID":"sha256:ccccccccccccccc","Repository":"<none>","Tag":"<none>","UniqueSize":"1GB","Size":"1GB"}],
     "Containers":[{"ID":"c1","Names":"old","State":"exited","Size":"10MB","Image":"x"},{"ID":"c2","Names":"web","State":"running","Size":"1MB"}],
     "Volumes":[
      {"Name":"351266fc976bb3c7b065f4d85a0f1d76faaec29120c8667f0cab84feae23d039","Links":"0","Size":"69.77MB","Labels":"com.docker.volume.anonymous="},
      {"Name":"shop_db","Links":"0","Size":"19.33GB","Labels":"com.docker.compose.project=shop,com.docker.compose.volume=db"},
      {"Name":"used","Links":"1","Size":"5GB"}],
     "BuildCache":[{"InUse":"false","Shared":"false","Size":"8.6GB"},{"InUse":"true","Size":"1GB"}]}
    """

    static let host = "unix:///Users/me/.orbstack/run/docker.sock"
    let engine = DockerSource.Engine(host: host, identity: "engine-1")

    @Test func parsesUnusedResourcesOnly() throws {
        let df = try JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8))
        let items = DockerSource.parse(df, engine: engine)
        let images = try #require(items.first { $0.id == "docker.images.unused" })
        #expect(images.children.count == 2)
        #expect(images.children.contains { $0.action == .command(argv: ["docker", "--host", Self.host, "image", "rm", "shop-worker:audit"]) })
        #expect(images.children.contains { $0.action == .command(argv: ["docker", "--host", Self.host, "image", "rm", "sha256:ccccccccccccccc"]) })

        let named = try #require(items.first { $0.id == "docker.volumes.named" })
        #expect(named.children.map(\.title) == ["shop_db"])
        #expect(named.children[0].safety == .caution)
        #expect(named.children[0].note?.contains("shop") == true)

        let anonymous = try #require(items.first { $0.id == "docker.volumes.anonymous" })
        #expect(anonymous.children.count == 1)

        let stopped = try #require(items.first { $0.id == "docker.containers.stopped" })
        #expect(stopped.children.map(\.title) == ["old"])

        let cache = try #require(items.first { $0.id == "docker.buildcache" })
        #expect(cache.sizeBytes == 8_600_000_000)
        #expect(!items.contains { $0.paths.contains { $0.contains("orbstack") } && $0.action != nil })
    }

    @Test func removalsAreBoundToTheScannedEngineAndImage() throws {
        let df = try JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8))
        let leaves = DockerSource.parse(df, engine: engine).flatMap(\.leaves).filter { $0.action != nil }
        #expect(!leaves.isEmpty)
        let engineCheck = CommandCheck(argv: DockerSource.engineIdentityCommand(host: Self.host), expected: "engine-1", purpose: .dockerEngine)
        #expect(leaves.allSatisfy { $0.preconditions?.contains(engineCheck) == true })
        for leaf in leaves {
            guard case .command(let argv) = leaf.action else { continue }
            #expect(CommandPolicy.isAllowedCleanCommand(argv))
        }
        for check in leaves.flatMap({ $0.preconditions ?? [] }) {
            #expect(CommandPolicy.isAllowedCheckCommand(check.argv))
        }
        // A tag can move to another image after a pull or build; the scanned image id is checked first.
        let tagged = try #require(leaves.first { $0.title == "shop-worker:audit" })
        #expect(tagged.preconditions?.contains(CommandCheck(
            argv: ["docker", "--host", Self.host, "image", "inspect", "--format", "{{.Id}}", "shop-worker:audit"], expected: "sha256:aaa", purpose: .dockerImage
        )) == true)
    }

    @Test func withoutAnEngineIdentityNothingIsRemovable() throws {
        let df = try JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8))
        let items = DockerSource.parse(df, engine: nil)
        #expect(!items.isEmpty)
        #expect(items.flatMap(\.leaves).allSatisfy { $0.action == nil })
    }

    @Test func parsesDockerSizes() {
        #expect(DockerSource.parseSize("1.826GB") == 1_826_000_000)
        #expect(DockerSource.parseSize("81.92kB") == 81_920)
        #expect(DockerSource.parseSize("92B") == 92)
        #expect(DockerSource.parseSize("0B") == 0)
    }
}

@Suite struct ProjectArtifactTests {
    @Test func detectsArtifactsWithContext() throws {
        let fx = try Fixture()
        try fx.file("ws/web/package.json")
        try fx.file("ws/web/node_modules/react/index.js", bytes: 2_000)
        try fx.file("ws/loose/node_modules/x.js")
        try fx.file("ws/api/Api.csproj")
        try fx.file("ws/api/bin/Debug/api.dll", bytes: 2_000)
        try fx.file("ws/scripts/bin/run.sh")
        try fx.file("ws/py/.venv/pyvenv.cfg")
        try fx.file("ws/py/.env/settings")
        try fx.file("ws/repo/.git/node_modules/package.json")
        try fx.dir("ws/repo/.claude/worktrees/agent-1")

        let catalog = try RuleCatalog.builtIn()
        let found = ProjectSource.findArtifacts(in: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent")
        let paths = Set(found.map(\.path))
        #expect(paths.contains(fx.path("ws/web/node_modules")))
        #expect(!paths.contains(fx.path("ws/loose/node_modules")))
        #expect(paths.contains(fx.path("ws/api/bin")))
        #expect(!paths.contains(fx.path("ws/scripts/bin")))
        #expect(paths.contains(fx.path("ws/py/.venv")))
        #expect(!paths.contains(fx.path("ws/py/.env")))
        #expect(!paths.contains { $0.contains("/.git/") })
        #expect(paths.contains(fx.path("ws/repo/.claude/worktrees")))
    }

    @Test func buildFolderNeedsGeneratedContent() throws {
        let fx = try Fixture()
        // A Python package that happens to be called build.
        try fx.file("ws/tool/pyproject.toml")
        try fx.file("ws/tool/build/__init__.py")
        try fx.file("ws/tool/build/lib/helpers.py")
        // setuptools output.
        try fx.file("ws/lib/setup.py")
        try fx.file("ws/lib/build/lib/pkg/__init__.py")
        try fx.dir("ws/lib/build/bdist.macosx-15.0-arm64")
        // Gradle output.
        try fx.file("ws/android/build.gradle.kts")
        try fx.dir("ws/android/build/intermediates")
        // A build folder with nothing that marks it as generated.
        try fx.file("ws/cpp/CMakeLists.txt")
        try fx.file("ws/cpp/build/notes.txt")

        let catalog = try RuleCatalog.builtIn()
        let paths = Set(ProjectSource.findArtifacts(in: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent").map(\.path))
        #expect(!paths.contains(fx.path("ws/tool/build")))
        #expect(paths.contains(fx.path("ws/lib/build")))
        #expect(paths.contains(fx.path("ws/android/build")))
        #expect(!paths.contains(fx.path("ws/cpp/build")))
    }

    @Test func buildFolderWithOnlyGenericNamesIsCautionAndTrackedSourcesAreKept() async throws {
        let fx = try Fixture()
        // Sources declared under build/lib: the generic name "lib" is all that matches.
        try fx.file("ws/pkg/pyproject.toml")
        try fx.file("ws/pkg/build/lib/helpers.py", bytes: 5_000)
        // The same layout committed to Git is source code.
        try fx.file("ws/repo/pyproject.toml")
        try fx.file("ws/repo/build/lib/helpers.py", bytes: 5_000)
        // CMake output is recognized by a file only CMake writes.
        try fx.file("ws/cpp/CMakeLists.txt")
        try fx.file("ws/cpp/build/CMakeCache.txt", bytes: 5_000)
        let git = { (args: [String]) throws in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", fx.path("ws/repo"), "-c", "user.name=t", "-c", "user.email=t@example.com"] + args
            try p.run()
            p.waitUntilExit()
        }
        try git(["init", "-q"])
        try git(["add", "."])
        try git(["commit", "-qm", "init"])

        let ctx = ScanContext(
            catalog: try RuleCatalog.builtIn(), options: ScanOptions(projectRoots: [fx.path("ws")], home: fx.path("home")),
            claims: ClaimRegistry(), denylist: Denylist(home: fx.root), warnings: WarningSink()
        )
        let items = await ProjectSource.scan(ctx)
        let leaves = items.flatMap(\.leaves)
        let pkg = try #require(leaves.first { $0.paths == [fx.path("ws/pkg/build")] })
        #expect(pkg.safety == .caution)
        #expect(!leaves.contains { $0.paths == [fx.path("ws/repo/build")] })
        let cpp = try #require(leaves.first { $0.paths == [fx.path("ws/cpp/build")] })
        #expect(cpp.safety == .regenerable)
        // The group header is as cautious as its most cautious item.
        let group = try #require(items.first { $0.children.contains { $0.paths == [fx.path("ws/pkg/build")] } })
        #expect(group.safety == .caution)
    }

    @Test func testResultsNeedTheirTestRunner() throws {
        let fx = try Fixture()
        try fx.file("ws/web/playwright.config.ts")
        try fx.file("ws/web/test-results/login-chromium/trace.zip")
        try fx.file("ws/web/playwright-report/index.html")
        // Same names without a Playwright configuration: the user's own data.
        try fx.file("ws/lab/package.json")
        try fx.file("ws/lab/test-results/summary.csv")
        try fx.file("ws/shop/cypress.config.ts")
        try fx.file("ws/shop/cypress/videos/cart.cy.ts.mp4")
        try fx.file("ws/shop/cypress/e2e/cart.cy.ts")
        try fx.file("ws/shop/cypress/fixtures/user.json")
        try fx.file("ws/old/cypress/screenshots/a.png")
        try fx.file("ws/photos/screenshots/a.png")
        try fx.file("ws/api/Api.csproj")
        try fx.file("ws/api/TestResults/run.trx")

        let catalog = try RuleCatalog.builtIn()
        let found = ProjectSource.findArtifacts(in: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent")
        let ids = Dictionary(found.map { ($0.path, $0.definition.id) }, uniquingKeysWith: { a, _ in a })
        #expect(ids[fx.path("ws/web/test-results")] == "artifact.playwright-results")
        #expect(ids[fx.path("ws/web/playwright-report")] == "artifact.playwright-results")
        #expect(ids[fx.path("ws/lab/test-results")] == nil)
        #expect(ids[fx.path("ws/shop/cypress/videos")] == "artifact.cypress-results")
        #expect(!ids.keys.contains { $0.hasPrefix(fx.path("ws/shop/cypress/e2e")) || $0.hasPrefix(fx.path("ws/shop/cypress/fixtures")) })
        #expect(ids[fx.path("ws/old/cypress/screenshots")] == nil)
        #expect(ids[fx.path("ws/photos/screenshots")] == nil)
        #expect(ids[fx.path("ws/api/TestResults")] == "artifact.dotnet-testresults")
    }

    @Test func workspaceCachesNeedTheWorkspaceFile() throws {
        let fx = try Fixture()
        try fx.file("ws/mono/nx.json")
        try fx.file("ws/mono/.nx/cache/123/outputs.txt")
        try fx.file("ws/mono/.nx/workspace-data/project-graph.json")
        try fx.file("ws/other/.nx/cache/1/a")
        try fx.file("ws/py/noxfile.py")
        try fx.file("ws/py/.nox/tests-3-13/pyvenv.cfg")
        try fx.file("ws/sln/Directory.Build.props", contents: "<Project><PropertyGroup><UseArtifactsOutput>true</UseArtifactsOutput></PropertyGroup></Project>")
        try fx.file("ws/sln/artifacts/bin/App/debug/App.dll")
        try fx.file("ws/sln/artifacts/obj/App/debug/App.pdb")
        try fx.file("ws/sln/artifacts/publish/App/release/App.dll")
        try fx.file("ws/sln/artifacts/package/release/App.1.0.0.nupkg")
        // Directory.Build.props without the artifacts layout.
        try fx.file("ws/plain/Directory.Build.props", contents: "<Project></Project>")
        try fx.file("ws/plain/artifacts/bin/tool")
        // The layout switched off or only mentioned in a comment.
        try fx.file("ws/off/Directory.Build.props", contents: "<Project><UseArtifactsOutput>false</UseArtifactsOutput></Project>")
        try fx.file("ws/off/artifacts/bin/tool")
        try fx.file("ws/commented/Directory.Build.props", contents: "<Project><!-- <UseArtifactsOutput>true</UseArtifactsOutput> --></Project>")
        try fx.file("ws/commented/artifacts/bin/tool")

        let catalog = try RuleCatalog.builtIn()
        let found = ProjectSource.findArtifacts(in: fx.path("ws"), definitions: catalog.artifacts, home: "/nonexistent")
        let ids = Dictionary(found.map { ($0.path, $0.definition.id) }, uniquingKeysWith: { a, _ in a })
        #expect(ids[fx.path("ws/mono/.nx/cache")] == "artifact.nx-cache")
        #expect(!ids.keys.contains { $0.contains("workspace-data") })
        #expect(ids[fx.path("ws/other/.nx/cache")] == nil)
        #expect(ids[fx.path("ws/py/.nox")] == "artifact.nox")
        #expect(ids[fx.path("ws/sln/artifacts/bin")] == "artifact.dotnet-artifacts")
        #expect(ids[fx.path("ws/sln/artifacts/obj")] == "artifact.dotnet-artifacts")
        #expect(!ids.keys.contains { $0.contains("publish") || $0.contains("package") })
        #expect(ids[fx.path("ws/plain/artifacts/bin")] == nil)
        #expect(ids[fx.path("ws/off/artifacts/bin")] == nil)
        #expect(ids[fx.path("ws/commented/artifacts/bin")] == nil)

        let definition = try #require(catalog.artifacts.first { $0.id == "artifact.nx-cache" })
        let item = ProjectSource.makeItem(definition, path: fx.path("ws/mono/.nx/cache"), root: fx.path("ws"), info: SizeInfo(allocatedBytes: 1), note: nil)
        #expect(item.title == "ws/mono/.nx/cache")
    }
}

@Suite struct ClaimRegistryTests {
    @Test func tracksAncestorsAndDescendants() async {
        let r = ClaimRegistry()
        #expect(await r.claim("/h/a/b"))
        #expect(await r.claim("/h/a/c"))
        #expect(!(await r.claim("/h/a")))
        #expect(!(await r.claim("/h/a/b/x")))
        #expect(await r.isClaimed("/h/a/b/x"))
        #expect(!(await r.isClaimed("/h/a")))
        #expect(await r.claimedInside("/h/a") == ["/h/a/b", "/h/a/c"])
        #expect(await r.claimedInside("/h") == ["/h/a/b", "/h/a/c"])
        #expect(await r.claimedInside("/h/a/b").isEmpty)
        // A prefix of a name is not an ancestor.
        #expect(await r.claim("/h/a/bb"))
    }
}

@Suite struct RuleCommandTests {
    @Test func uvCleansTheMeasuredFolder() throws {
        let catalog = try RuleCatalog.builtIn()
        let rule = try #require(catalog.rules.first { $0.id == "uv.cache" })
        let item = try #require(RuleSource.makeItem(
            rule: rule, paths: ["/Users/me/.cache/uv"], sizes: ["/Users/me/.cache/uv": SizeInfo(allocatedBytes: 1)], home: "/Users/me"
        ))
        #expect(item.action == .command(argv: ["uv", "cache", "clean", "--cache-dir", "/Users/me/.cache/uv"]))
        #expect(item.paths == ["/Users/me/.cache/uv"])
    }

    @Test func goModulesAreRemovedOnlyFromTheScannedFolder() throws {
        let catalog = try RuleCatalog.builtIn()
        let rule = try #require(catalog.rules.first { $0.id == "go.modcache" })
        let path = "/Users/me/go/pkg/mod"
        let item = try #require(RuleSource.makeItem(rule: rule, paths: [path], sizes: [path: SizeInfo(allocatedBytes: 1)], home: "/Users/me"))
        #expect(item.action == .command(argv: ["go", "clean", "-modcache"]))
        #expect(item.preconditions == [CommandCheck(argv: ["go", "env", "GOMODCACHE"], expected: path, purpose: .toolLocation)])
    }

    @Test func agentWorktreesMustBeGitCheckouts() throws {
        let fx = try Fixture()
        try fx.file("home/.codex/worktrees/a1b2/shop/.git", contents: "gitdir: /Users/me/code/shop/.git/worktrees/shop")
        try fx.file("home/.codex/worktrees/a1b2/shop/src/main.ts")
        try fx.file("home/.codex/worktrees/a1b2/notes/todo.md")
        try fx.file("home/.cursor/worktrees/api/feature/.git", contents: "gitdir: x")
        // A full clone has its own history and unpushed commits; it is not a disposable worktree.
        try fx.file("home/.cursor/worktrees/api/clone/.git/HEAD", contents: "ref: refs/heads/main")
        let catalog = try RuleCatalog.builtIn()
        let codex = try #require(catalog.rules.first { $0.id == "codex.worktrees" })
        let cursor = try #require(catalog.rules.first { $0.id == "cursor.worktrees" })
        #expect(RuleSource.matches(for: codex, home: fx.path("home")) == [fx.path("home/.codex/worktrees/a1b2/shop")])
        #expect(RuleSource.matches(for: cursor, home: fx.path("home")) == [fx.path("home/.cursor/worktrees/api/feature")])
        // They come before the informational rule that covers the rest of ~/.codex.
        let ids = catalog.rules.map(\.id)
        #expect(try #require(ids.firstIndex(of: "codex.worktrees")) < #require(ids.firstIndex(of: "codex.data")))
    }

    @Test func gitStatusDoesNotRunConfiguredFilters() async throws {
        let fx = try Fixture()
        try fx.file("repo/f.txt", contents: "a\n")
        try fx.file("repo/.gitattributes", contents: "*.txt filter=mark\n")
        let marker = fx.path("filter-ran")
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", fx.path("repo"), "-c", "user.name=t", "-c", "user.email=t@example.com"] + args
            try p.run()
            p.waitUntilExit()
        }
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-qm", "init")
        try git("config", "filter.mark.clean", "touch '\(marker)'; cat")
        // As `git lfs install` does: a filter that must not fail.
        try git("config", "filter.mark.required", "true")
        // An older modification time makes Git re-read the file through its filter.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: fx.path("repo/f.txt"))
        let note = await ProjectSource.gitStatusNote(fx.path("repo"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(note != String(localized: "Could not check the Git status", bundle: .scannerKit))
    }

    @Test func filterNamesComeFromConfigKeys() {
        let config = "filter.lfs.clean git-lfs clean -- %f\nfilter.lfs.process git-lfs filter-process\nfilter.a.b.smudge cat\nfilter.x\n"
        #expect(GitInspection.filterNames(fromConfig: config) == ["a.b", "lfs"])
        let env = GitInspection.environment(disablingFilters: ["lfs"])
        #expect(env["GIT_CONFIG_COUNT"] == "4")
        #expect(env["GIT_CONFIG_KEY_3"] == "filter.lfs.required" && env["GIT_CONFIG_VALUE_3"] == "false")
        #expect(env["GIT_CONFIG_KEY_0"] == "filter.lfs.clean" && env["GIT_CONFIG_VALUE_0"] == "")
        #expect(GitInspection.environment(disablingFilters: []).isEmpty)
    }

    @Test func jetBrainsRuleNeverCoversLocalHistory() throws {
        let catalog = try RuleCatalog.builtIn()
        let rule = try #require(catalog.rules.first { $0.id == "jetbrains.caches" })
        #expect(rule.paths.allSatisfy { !$0.hasSuffix("/*") && !$0.contains("LocalHistory") })
    }
}

@Suite struct OrphanTests {
    @Test func extractsBundleIDs() {
        #expect(OrphanSource.bundleID(fromFolderName: "com.example.removedapp") == "com.example.removedapp")
        #expect(OrphanSource.bundleID(fromFolderName: "HUAQ24HBR6.dev.orbstack") == "dev.orbstack")
        #expect(OrphanSource.bundleID(fromFolderName: "group.net.whatsapp.WhatsApp.shared") == "net.whatsapp.WhatsApp.shared")
        #expect(OrphanSource.bundleID(fromFolderName: "com.spotify.client.savedState") == "com.spotify.client")
        #expect(OrphanSource.bundleID(fromFolderName: "JetBrains") == nil)
        #expect(OrphanSource.bundleID(fromFolderName: "Google Chrome") == nil)
    }

    @Test func matchesInstalledAppsAndAliases() {
        let installed: Set<String> = ["dev.kdrag0n.macvirt", "net.whatsapp.whatsapp", "com.spotify.client"]
        let aliases = ["dev.orbstack": "dev.kdrag0n.MacVirt"]
        #expect(OrphanSource.isInstalled("dev.orbstack", installed: installed, aliases: aliases))
        #expect(OrphanSource.isInstalled("net.whatsapp.WhatsApp.shared", installed: installed, aliases: aliases))
        #expect(OrphanSource.isInstalled("com.spotify.client.helper", installed: installed, aliases: aliases))
        #expect(!OrphanSource.isInstalled("com.example.removedapp", installed: installed, aliases: aliases))
    }
}

@Suite struct LocalizationResourceTests {
    static let translatedLanguages = Localization.supportedLanguages.filter { $0 != Localization.developmentLanguage }

    @Test(arguments: translatedLanguages)
    func translatedTablesResolveKeysAndPlurals(language: String) throws {
        let path = try #require(Bundle.scannerKit.path(forResource: language, ofType: "lproj"))
        let translated = try #require(Bundle(path: path))
        #expect(translated.localizedString(forKey: "Safe", value: nil, table: nil) != "Safe")

        // Polish has separate "few" and "many" forms, so 2 and 5 must not share a phrase.
        let key = "Git: %lld uncommitted changes. Check before removing!"
        let format = translated.localizedString(forKey: key, value: nil, table: nil)
        let locale = Locale(identifier: language)
        let two = String(format: format, locale: locale, 2)
        let five = String(format: format, locale: locale, 5)
        #expect(two.contains("2") && five.contains("5"))
        #expect(two.replacingOccurrences(of: "2", with: "5") != five)
    }

    @Test func scanResultsSavedWithoutLanguageStillDecode() throws {
        let result = ScanResult(items: [], warnings: [], startedAt: Date(), finishedAt: Date(),
                                freeBytes: nil, totalBytes: nil, hasFullDiskAccess: true, language: "en")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(json["language"] as? String == "en")
        json["language"] = nil
        let legacy = try JSONDecoder().decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.language == nil)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func stopsAProgramAtTheDeadline() async throws {
        let started = Date()
        let out = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5)
        #expect(out.wasStopped)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aChildHoldingThePipeDoesNotBlock() async throws {
        // The shell exits at once, but the background sleep keeps stdout open.
        let started = Date()
        let out = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo ready; /bin/sleep 30 &"], timeout: 20)
        #expect(!out.wasStopped)
        #expect(String(decoding: out.stdout, as: UTF8.self).hasPrefix("ready"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func helpersDoNotOutliveTheProgram() async throws {
        // Work a program leaves behind must not go on after its result is reported, whether it exited
        // on its own or was stopped at the deadline.
        let fx = try Fixture()
        let finished = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 1; touch '\(fx.path("after-exit"))') &"], timeout: 20
        )
        let stopped = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "(/bin/sleep 1; touch '\(fx.path("after-stop"))') & /bin/sleep 30"], timeout: 0.3
        )
        #expect(!finished.wasStopped)
        #expect(stopped.wasStopped)
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: fx.path("after-exit")))
        #expect(!FileManager.default.fileExists(atPath: fx.path("after-stop")))
    }

    @Test func reportsTheExitCodeAndMissingPrograms() async throws {
        let out = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], timeout: 20)
        #expect(out.status == 3)
        #expect(String(decoding: out.stderr, as: UTF8.self) == "oops\n")
        await #expect(throws: (any Error).self) {
            _ = try await ProcessRunner.run(executable: "/nonexistent/tool", arguments: [], timeout: 5)
        }
    }

    @Test func boundsTheOutput() async throws {
        let out = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "yes 0123456789 | head -c 1000000; echo END"], timeout: 20,
            outputLimit: 1_000, keepTail: true
        )
        #expect(out.stdout.count == 1_000)
        #expect(String(decoding: out.stdout, as: UTF8.self).hasSuffix("END\n"))
        #expect(!out.wasStopped)
    }

    @Test func checkOutputMayCarryWarnings() {
        let check = CommandCheck(argv: ["docker", "info"], expected: "engine-1 orbstack", purpose: .dockerEngine)
        #expect(check.isSatisfied(by: "WARNING: something\nengine-1 orbstack\n"))
        #expect(!check.isSatisfied(by: "engine-1 orbstack-2\n"))
        #expect(!check.isSatisfied(by: ""))
    }
}
