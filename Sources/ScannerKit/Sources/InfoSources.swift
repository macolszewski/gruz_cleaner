import Foundation

/// Installed apps, shown for information only.
enum ApplicationsSource {
    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let roots = ["/Applications", Paths.expand("~/Applications", home: ctx.options.home)]
        var apps: [String] = []
        for root in roots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where entry.hasSuffix(".app") {
                apps.append(Paths.join(root, entry))
            }
        }
        let sizes = await SizeCalculator.measureAll(apps)
        return apps.compactMap { path -> ScanItem? in
            guard let info = sizes[path], info.allocatedBytes > 0 else { return nil }
            return makeItem(path: path, bundleID: Bundle(path: path)?.bundleIdentifier, info: info)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func makeItem(path: String, bundleID: String?, info: SizeInfo) -> ScanItem {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return ScanItem(
            id: "app:\(path)", category: .applications, title: name, app: bundleID,
            description: String(localized: "An app installed in \(Paths.abbreviate((path as NSString).deletingLastPathComponent)). GRUZ does not remove apps; uninstall it in the Finder, with Homebrew or with JetBrains Toolbox.", bundle: .scannerKit),
            safety: .userData, sizeBytes: info.allocatedBytes, lastModified: info.newestModification, paths: [path],
            ownerBundleIDs: bundleID.map { [$0] } ?? []
        )
    }
}

/// Large folders no rule describes. Shown so the catalog can be extended; never removable.
enum UnrecognizedSource {
    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let h = ctx.options.home
        let containers = ["~/Library/Application Support", "~/Library/Caches", "~/Library/Containers",
                          "~/Library/Group Containers", "~/.cache", "~/.local/share"].map { Paths.expand($0, home: h) }
        var candidates: [String] = []
        for dir in containers {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                if entry.hasPrefix("com.apple.") || entry.hasPrefix("group.com.apple.") { continue }
                candidates.append(Paths.join(dir, entry))
            }
        }
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: h)) ?? []
        where entry.hasPrefix(".") && ![".Trash", ".cache", ".local", ".DS_Store", ".CFUserTextEncoding"].contains(entry) {
            candidates.append(Paths.join(h, entry))
        }

        var work: [(String, Set<String>)] = []
        for path in candidates where Paths.isDirectory(path) {
            if await ctx.claims.isClaimed(path) { continue }
            work.append((path, await ctx.claims.claimedInside(path)))
        }

        let minimum = Int64(ctx.options.unrecognizedMinimumMB) * 1_000_000
        let results = await withTaskGroup(of: ScanItem?.self) { group in
            for (path, excluded) in work {
                group.addTask {
                    let info = SizeCalculator.measure(path, excluding: excluded)
                    guard info.allocatedBytes >= minimum else { return nil }
                    return makeItem(path: path, info: info, excludesClaimedPaths: !excluded.isEmpty)
                }
            }
            var items: [ScanItem] = []
            for await item in group { if let item { items.append(item) } }
            return items
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func makeItem(path: String, info: SizeInfo, excludesClaimedPaths: Bool) -> ScanItem {
        ScanItem(
            id: "unrecognized:\(path)", category: .unrecognized, title: Paths.abbreviate(path),
            description: String(localized: "No rule in the catalog describes this folder, so GRUZ cannot tell whether it is safe to remove. It is shown for information only.", bundle: .scannerKit),
            safety: .caution, sizeBytes: info.allocatedBytes, lastModified: info.newestModification,
            paths: [path], note: excludesClaimedPaths ? String(localized: "Excludes subfolders described in other categories", bundle: .scannerKit) : nil
        )
    }
}
