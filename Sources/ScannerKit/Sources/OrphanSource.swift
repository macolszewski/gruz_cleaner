import Foundation

/// Finds Library folders that belong to apps no longer installed.
enum OrphanSource {
    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let config = ctx.catalog.orphans
        let installed = installedBundleIDs()
        var candidates: [String: [String]] = [:]

        for dir in config.searchDirs.map({ Paths.expand($0, home: ctx.options.home) }) {
            guard let entries = ctx.cache.contents(of: dir) else { continue }
            for entry in entries {
                let path = Paths.join(dir, entry)
                guard Paths.isDirectory(path), let id = bundleID(fromFolderName: entry) else { continue }
                if isIgnored(id, config: config) { continue }
                if isInstalled(id, installed: installed, aliases: config.aliases) { continue }
                if await ctx.claims.isClaimed(path) { continue }
                candidates[id, default: []].append(path)
            }
        }

        // Measure first: the size filter is cheap compared with a Spotlight query per candidate.
        let sizes = await ctx.measureAll(candidates.values.flatMap { $0 })
        func size(of paths: [String]) -> SizeInfo { paths.reduce(into: SizeInfo()) { $0.merge(sizes[$1] ?? SizeInfo()) } }
        let minimum = Int64(config.minimumSizeMB) * 1_000_000
        let large = candidates.filter { size(of: $0.value).allocatedBytes >= minimum }

        // Spotlight catches apps outside the usual folders. When it cannot answer, the data is not
        // reported as a leftover: an unknown answer is no evidence that the app is gone.
        let lookups = await concurrentMap(Array(large.keys), width: 4) { await spotlightLookup($0) }
        let undetermined = lookups.values.filter { $0 == .unknown }.count
        if undetermined > 0 {
            await ctx.warnings.add(String(localized: "Spotlight did not answer, so \(undetermined) possible app leftovers were not checked.", bundle: .scannerKit))
        }

        var items: [ScanItem] = []
        for (id, paths) in large where lookups[id] == .notFound {
            let allowed = paths.filter { ctx.isAllowed($0) }
            guard !allowed.isEmpty else { continue }
            await ctx.claims.claimAll(allowed)
            items.append(makeItem(id: id, paths: allowed, info: size(of: allowed)))
        }
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func makeItem(id: String, paths: [String], info: SizeInfo) -> ScanItem {
        let places = paths.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
        return ScanItem(
            id: "orphan:\(id)", ruleID: "orphans", category: .orphans, title: id, app: String(localized: "App not found", bundle: .scannerKit),
            description: String(localized: "Data of the app with identifier \(id) (\(places.joined(separator: ", "))). No app with this identifier is installed, so it is most likely left over from an uninstalled app.", bundle: .scannerKit),
            regeneration: String(localized: "If you install the app again, it will start with default settings.", bundle: .scannerKit),
            safety: .caution, sizeBytes: info.allocatedBytes, lastModified: info.newestModification,
            paths: paths.sorted(), action: .trash
        ).measured(info)
    }

    /// "ABCDE12345.com.x.y" / "group.com.x.y" / "com.x.y.savedState" -> "com.x.y"; nil for non-identifiers.
    static func bundleID(fromFolderName name: String) -> String? {
        var id = name
        for suffix in [".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id.removeLast(suffix.count) }
        var prefixed = false
        if id.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) != nil {
            id = String(id.dropFirst(11))
            prefixed = true
        }
        if id.hasPrefix("group.") {
            id = String(id.dropFirst(6))
            prefixed = true
        }
        let parts = id.split(separator: ".")
        // Plain folder names need three components to look like a bundle id; team/group prefixes make two enough.
        guard parts.count >= (prefixed ? 2 : 3), parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        return id
    }

    static func isIgnored(_ id: String, config: OrphanConfig) -> Bool {
        if id.hasPrefix("com.apple.") { return true }
        return config.ignoredIDs.contains { Paths.fnmatch($0, id) }
    }

    static func isInstalled(_ id: String, installed: Set<String>, aliases: [String: String]) -> Bool {
        let lower = id.lowercased()
        if let alias = aliases[id], installed.contains(alias.lowercased()) { return true }
        if installed.contains(lower) { return true }
        return installed.contains { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
    }

    static func installedBundleIDs() -> Set<String> {
        let h = Paths.home
        var ids = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "\(h)/Applications", "/System/Applications",
                     "/System/Applications/Utilities", "/Library/Application Support", "\(h)/Applications/Chrome Apps.localized",
                     "\(h)/Applications/Brave Browser Apps.localized"]
        for root in roots {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where entry.hasSuffix(".app") {
                collect(Paths.join(root, entry), into: &ids)
            }
        }
        return ids
    }

    private static func collect(_ bundle: String, into ids: inout Set<String>) {
        if let id = Bundle(path: bundle)?.bundleIdentifier { ids.insert(id.lowercased()) }
        let contents = Paths.join(bundle, "Contents")
        for sub in ["Library/LoginItems", "PlugIns", "Helpers", "Frameworks", "XPCServices", "Library", "Applications", "MacOS"] {
            let dir = Paths.join(contents, sub)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let ext = (entry as NSString).pathExtension
                guard ["app", "appex", "xpc", "bundle", "framework"].contains(ext) else { continue }
                if let id = Bundle(path: Paths.join(dir, entry))?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
        }
    }

    enum Lookup: Equatable {
        case found
        case notFound
        case unknown
    }

    static func spotlightLookup(_ id: String) async -> Lookup {
        // mdfind is read-only; called directly because it only queries the Spotlight index.
        guard let out = try? await Subprocess.run(
            executable: "/usr/bin/mdfind", arguments: ["kMDItemCFBundleIdentifier == '\(id.replacingOccurrences(of: "'", with: ""))'"],
            timeout: 10
        ), out.status == 0 else { return .unknown }
        return out.stdout.isEmpty ? .notFound : .found
    }
}
