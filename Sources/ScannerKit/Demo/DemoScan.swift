#if DEBUG
import Foundation

/// A fictional scan for screenshots, documentation and UI work. Debug builds only.
///
/// Items are built by the same code and rule catalog as a real scan, so titles, descriptions
/// and safety levels are exactly what users see, in the current language. Only sizes, dates
/// and paths are invented; every path points into `home`, a folder that does not exist.
public enum DemoScan {
    public static let home = "/Users/demo"

    /// - Parameter growth: also attach a comparison with an earlier scan, for the What grew view.
    public static func result(catalog: RuleCatalog, now: Date = Date(), growth: Bool = false) -> ScanResult {
        let builder = Builder(catalog: catalog, now: now)
        var items = builder.docker() + builder.rules() + builder.projects() + builder.orphans()
            + builder.applications() + builder.unrecognized()
        if growth { items = items.map { builder.addGrowth(to: $0) } }
        return ScanResult(
            items: items, warnings: [], startedAt: now.addingTimeInterval(-14), finishedAt: now,
            freeBytes: 61_400_000_000, totalBytes: 494_380_000_000, hasFullDiskAccess: true
        )
    }

    /// Ids of a few items worth selecting in a screenshot of the review sheet.
    public static let suggestedSelection = [
        "docker.image:sha256:3f9a1c2b7d4e:shop-api:1.4.2",
        "docker.buildcache",
        "npm.cacache",
        "xcode.deriveddata:\(home)/Library/Developer/Xcode/DerivedData/ShopApp-bqzlwhfkyyqmvdgcpkhcxsrnbnsq",
    ]

    private struct Builder {
        let catalog: RuleCatalog
        let now: Date

        private let gigabyte: Int64 = 1_000_000_000
        private let megabyte: Int64 = 1_000_000

        func info(_ bytes: Int64, daysAgo: Double) -> SizeInfo {
            SizeInfo(allocatedBytes: bytes, newestModification: now.addingTimeInterval(-daysAgo * 86_400), fileCount: 1)
        }

        func path(_ relative: String) -> String { Paths.join(DemoScan.home, relative) }

        func docker() -> [ScanItem] {
            let json = """
            {"Images":[
              {"Containers":"0","CreatedAt":"2026-08-02 10:45:46 +0200 CEST","ID":"sha256:3f9a1c2b7d4e","Repository":"shop-api","Tag":"1.4.2","UniqueSize":"2.14GB","Size":"2.6GB"},
              {"Containers":"0","CreatedAt":"2026-06-11 09:12:03 +0200 CEST","ID":"sha256:8b1e0d55aa90","Repository":"<none>","Tag":"<none>","UniqueSize":"1.31GB","Size":"1.31GB"},
              {"Containers":"0","CreatedAt":"2026-09-20 18:01:44 +0200 CEST","ID":"sha256:c47d29e0f311","Repository":"postgres","Tag":"15","UniqueSize":"412MB","Size":"412MB"},
              {"Containers":"1","CreatedAt":"2026-11-01 08:00:00 +0100 CET","ID":"sha256:0aa1","Repository":"redis","Tag":"7","UniqueSize":"117MB","Size":"117MB"}],
             "Containers":[
              {"ID":"e1","Names":"shop-worker-old","State":"exited","Size":"84MB","Image":"shop-worker"},
              {"ID":"e2","Names":"migrate-test","State":"exited","Size":"12MB","Image":"shop-api"}],
             "Volumes":[
              {"Name":"shop_db","Links":"0","Size":"6.82GB","Labels":"com.docker.compose.project=shop,com.docker.compose.volume=db"},
              {"Name":"analytics_cache","Links":"0","Size":"1.24GB","Labels":"com.docker.compose.project=analytics,com.docker.compose.volume=cache"},
              {"Name":"9c2f6d0b8e7a41f3b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8","Links":"0","Size":"640MB","Labels":"com.docker.volume.anonymous="}],
             "BuildCache":[{"InUse":"false","Shared":"false","Size":"3.42GB"}]}
            """
            guard let df = try? JSONDecoder().decode(DockerSource.SystemDF.self, from: Data(json.utf8)) else { return [] }
            return DockerSource.parse(df, engine: "demo")
        }

        func rules() -> [ScanItem] {
            let plan: [String: [(String, Int64, Double)]] = [
                "uv.cache": [(".cache/uv", 2_430 * megabyte, 3)],
                "npm.cacache": [(".npm/_cacache", 3_180 * megabyte, 1)],
                "gradle.caches": [(".gradle/caches", 4_120 * megabyte, 12)],
                "homebrew.cache": [("Library/Caches/Homebrew", 1_870 * megabyte, 6)],
                "pnpm.store": [("Library/pnpm/store", 2_260 * megabyte, 2)],
                "cargo.registry": [(".cargo/registry", 1_140 * megabyte, 9)],
                "xcode.deriveddata": [
                    ("Library/Developer/Xcode/DerivedData/ShopApp-bqzlwhfkyyqmvdgcpkhcxsrnbnsq", 7_310 * megabyte, 2),
                    ("Library/Developer/Xcode/DerivedData/Widgets-fhkzqmrdcxnyaaakpbvjtgwlkeuu", 2_050 * megabyte, 41),
                    ("Library/Developer/Xcode/DerivedData/Playground-gtwmtdfpwqgbbnhcvbzdymxgsrha", 380 * megabyte, 130),
                ],
                "xcode.devicesupport": [
                    ("Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 18.6 (22G86)", 4_820 * megabyte, 95),
                    ("Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 26.0 (23A341)", 5_130 * megabyte, 20),
                ],
                "huggingface.models": [(".cache/huggingface", 12_640 * megabyte, 18)],
                "ollama.models": [(".ollama/models", 9_870 * megabyte, 33)],
                "claude.code.versions": [
                    (".local/share/claude/versions/2.1.30", 212 * megabyte, 21),
                    (".local/share/claude/versions/2.1.34", 214 * megabyte, 12),
                ],
                "chrome.cache": [
                    ("Library/Caches/Google/Chrome", 1_460 * megabyte, 0.2),
                    ("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", 930 * megabyte, 0.5),
                ],
                "safari.cache": [("Library/Caches/com.apple.Safari", 410 * megabyte, 0.3)],
                "spotify.cache": [("Library/Caches/com.spotify.client", 2_710 * megabyte, 1)],
                "jetbrains.caches": [
                    ("Library/Caches/JetBrains/IntelliJIdea2025.2", 1_920 * megabyte, 150),
                    ("Library/Caches/JetBrains/IntelliJIdea2026.1", 2_340 * megabyte, 1),
                ],
                "vscode.cache": [
                    ("Library/Application Support/Code/CachedData", 690 * megabyte, 4),
                    ("Library/Application Support/Code/Cache", 240 * megabyte, 1),
                ],
                "system.logs": [
                    ("Library/Logs/JetBrains", 310 * megabyte, 3),
                    ("Library/Logs/DiagnosticReports", 46 * megabyte, 8),
                ],
                "system.trash": [(".Trash", 3_960 * megabyte, 5)],
            ]
            return catalog.rules.compactMap { rule -> ScanItem? in
                guard let entries = plan[rule.id] else { return nil }
                var sizes: [String: SizeInfo] = [:]
                for (relative, bytes, days) in entries { sizes[path(relative)] = info(bytes, daysAgo: days) }
                return RuleSource.makeItem(rule: rule, paths: entries.map { path($0.0) }, sizes: sizes, home: DemoScan.home)
            }
        }

        func projects() -> [ScanItem] {
            let root = path("Developer")
            let plan: [String: [(String, Int64, Double)]] = [
                "artifact.node_modules": [
                    ("shop-web/node_modules", 1_380 * megabyte, 4),
                    ("admin-panel/node_modules", 940 * megabyte, 62),
                    ("landing/node_modules", 410 * megabyte, 210),
                ],
                "artifact.venv": [("ml-experiments/.venv", 2_870 * megabyte, 47)],
                "artifact.dotnet-bin": [
                    ("billing-service/src/Billing.Api/bin", 310 * megabyte, 15),
                    ("billing-service/src/Billing.Api/obj", 95 * megabyte, 15),
                ],
                "artifact.agent-worktrees": [("shop-web/.claude/worktrees/fix-checkout", 1_120 * megabyte, 9)],
            ]
            return catalog.artifacts.compactMap { definition -> ScanItem? in
                guard let entries = plan[definition.id] else { return nil }
                let children = entries.map { relative, bytes, days in
                    ProjectSource.makeItem(definition, path: Paths.join(root, relative), root: root,
                                           info: info(bytes, daysAgo: days), note: nil)
                }
                return ProjectSource.makeGroup(definition, children: children)
            }
        }

        func orphans() -> [ScanItem] {
            [
                OrphanSource.makeItem(id: "com.example.photoeditor", paths: [
                    path("Library/Application Support/com.example.photoeditor"), path("Library/Caches/com.example.photoeditor"),
                ], info: info(2_810 * megabyte, daysAgo: 640)),
                OrphanSource.makeItem(id: "net.example.vpnclient", paths: [
                    path("Library/Containers/net.example.vpnclient"),
                ], info: info(530 * megabyte, daysAgo: 420)),
            ]
        }

        func applications() -> [ScanItem] {
            [
                ApplicationsSource.makeItem(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", info: info(12_100 * megabyte, daysAgo: 30)),
                ApplicationsSource.makeItem(path: "/Applications/Docker.app", bundleID: "com.docker.docker", info: info(2_050 * megabyte, daysAgo: 60)),
            ]
        }

        /// Some leaves grew since a scan three days earlier; the rest stayed the same.
        func addGrowth(to item: ScanItem) -> ScanItem {
            var copy = item
            copy.children = item.children.map(addGrowth)
            guard !item.isGroup else { return copy }
            let grown: [String: Int64] = [
                "npm.cacache": 640 * megabyte,
                "huggingface.models": 4_210 * megabyte,
                "docker.buildcache": 1_830 * megabyte,
                "xcode.deriveddata:\(path("Library/Developer/Xcode/DerivedData/ShopApp-bqzlwhfkyyqmvdgcpkhcxsrnbnsq"))": 2_960 * megabyte,
                "artifact.node_modules:\(path("Developer/shop-web/node_modules"))": 310 * megabyte,
            ]
            let delta = grown[item.id] ?? 0
            copy.growth = DiskGrowth(baselineDate: now.addingTimeInterval(-3 * 86_400), previousBytes: item.sizeBytes - delta, deltaBytes: delta)
            return copy
        }

        func unrecognized() -> [ScanItem] {
            [UnrecognizedSource.makeItem(path: path(".cache/some-tool"), info: info(860 * megabyte, daysAgo: 25), excludesClaimedPaths: false)]
        }
    }
}
#endif
