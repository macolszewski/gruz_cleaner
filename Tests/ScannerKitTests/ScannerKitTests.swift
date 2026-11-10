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
        #expect(CommandPolicy.isAllowedCleanCommand(["docker", "image", "rm", "nginx:alpine"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["docker", "builder", "prune", "--force"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["xcrun", "simctl", "delete", "2CC2A9FF-BC88-4309-87CE-AE583195DD9B"]))
        #expect(CommandPolicy.isAllowedCleanCommand(["uv", "cache", "clean"]))
    }

    @Test func rejectsEverythingElse() {
        #expect(!CommandPolicy.isAllowedCleanCommand(["rm", "-rf", "/"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "system", "prune", "-a"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "volume", "rm", "-f"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "volume", "rm", "a", "b"]))
        #expect(!CommandPolicy.isAllowedCleanCommand(["docker", "volume", "prune"]))
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

    @Test func parsesUnusedResourcesOnly() throws {
        let df = try JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8))
        let items = DockerSource.parse(df)
        let images = try #require(items.first { $0.id == "docker.images.unused" })
        #expect(images.children.count == 2)
        #expect(images.children.contains { $0.action == .command(argv: ["docker", "image", "rm", "shop-worker:audit"]) })
        #expect(images.children.contains { $0.action == .command(argv: ["docker", "image", "rm", "sha256:ccccccccccccccc"]) })

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
