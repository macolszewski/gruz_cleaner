import Foundation

/// Turns catalog rules into items by expanding their paths and measuring them.
enum RuleSource {
    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        // Resolve sequentially so earlier rules win overlapping paths, then measure in parallel.
        var resolved: [(Rule, [String])] = []
        var exclusions: [String: Set<String>] = [:]
        for rule in ctx.catalog.rules {
            var accepted: [String] = []
            for path in matches(for: rule, home: ctx.options.home) {
                if rule.action != nil, ctx.denylist.check(path) != .allowed { continue }
                if await ctx.claims.isClaimed(path) { continue }
                let inside = await ctx.claims.claimedInside(path)
                // A removable catch-all must not overlap a more specific item; informational ones show the remainder.
                if !inside.isEmpty {
                    if rule.action != nil { continue }
                    exclusions[path] = inside
                    // `claim` refuses paths with claimed descendants, so take the remainder explicitly.
                    await ctx.claims.claimAll([path])
                    accepted.append(path)
                    continue
                }
                if await ctx.claims.claim(path) { accepted.append(path) }
            }
            if !accepted.isEmpty { resolved.append((rule, accepted)) }
        }

        var sizes = await SizeCalculator.measureAll(resolved.flatMap(\.1).filter { exclusions[$0] == nil })
        for (path, excluded) in exclusions { sizes[path] = SizeCalculator.measure(path, excluding: excluded) }

        var items: [ScanItem] = []
        for (rule, paths) in resolved {
            if let item = makeItem(rule: rule, paths: paths, sizes: sizes, home: ctx.options.home) { items.append(item) }
        }
        return items
    }

    static func matches(for rule: Rule, home: String) -> [String] {
        let bases = rule.paths.flatMap { Paths.glob($0, home: home) }
        let filtered = bases.filter { path in
            let name = (path as NSString).lastPathComponent
            return !rule.excludeNames.contains { Paths.fnmatch($0, name) }
        }
        switch rule.kind {
        case .path:
            return filtered
        case .versions:
            guard let pattern = rule.versionPattern else { return [] }
            return filtered.flatMap { oldVersions(in: $0, pattern: pattern) }
        }
    }

    /// Children of `directory` matching `pattern` (named groups `name` and `version`), except the newest per name.
    static func oldVersions(in directory: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var byName: [String: [(version: String, path: String)]] = [:]
        for entry in entries {
            let path = Paths.join(directory, entry)
            let range = NSRange(entry.startIndex..., in: entry)
            guard let m = regex.firstMatch(in: entry, range: range), m.range == range else { continue }
            func group(_ name: String) -> String? {
                let r = m.range(withName: name)
                guard r.location != NSNotFound, let rr = Range(r, in: entry) else { return nil }
                return String(entry[rr])
            }
            guard let version = group("version") else { continue }
            byName[group("name") ?? "", default: []].append((version, path))
        }
        return byName.values.flatMap { list -> [String] in
            let sorted = list.sorted { VersionCompare.isNewer($0.version, than: $1.version) }
            return sorted.dropFirst().map(\.path)
        }.sorted()
    }

    static func makeItem(rule: Rule, paths: [String], sizes: [String: SizeInfo], home: String) -> ScanItem? {
        func base(id: String, title: String, paths: [String], info: SizeInfo) -> ScanItem {
            ScanItem(
                id: id, ruleID: rule.id, category: rule.category, title: title, app: rule.app,
                description: rule.description, regeneration: rule.regeneration, safety: rule.safety,
                sizeBytes: info.allocatedBytes, lastModified: info.newestModification, paths: paths,
                action: rule.action, ownerBundleIDs: rule.ownerBundleIDs, requiresAppClosed: rule.requiresAppClosed,
                defaultAgeDays: rule.defaultAgeDays, note: rule.note
            )
        }

        let grouped = rule.group || paths.count > 1 || rule.kind == .versions
        if !grouped, let path = paths.first {
            let info = sizes[path] ?? SizeInfo()
            guard info.allocatedBytes > 0 else { return nil }
            return base(id: rule.id, title: rule.title, paths: [path], info: info)
        }

        let children = paths.compactMap { path -> ScanItem? in
            let info = sizes[path] ?? SizeInfo()
            guard info.allocatedBytes > 0 else { return nil }
            return base(id: "\(rule.id):\(path)", title: childTitle(path, style: rule.childTitle, home: home), paths: [path], info: info)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
        guard !children.isEmpty else { return nil }

        var group = base(id: rule.id, title: rule.title, paths: [], info: SizeInfo())
        group.action = nil
        group.children = children
        group.sizeBytes = children.reduce(0) { $0 + $1.sizeBytes }
        group.lastModified = children.compactMap(\.lastModified).max()
        return group
    }

    static func childTitle(_ path: String, style: Rule.ChildTitle, home: String) -> String {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        switch style {
        case .name:
            return name
        case .parentAndName:
            return "\(prettyClaudeProject(parent, home: home)) / \(name)"
        case .derivedData:
            if let r = name.range(of: #"-[a-z]{28}$"#, options: .regularExpression) { return String(name[..<r.lowerBound]) }
            return name
        case .huggingFace:
            let parts = name.components(separatedBy: "--")
            return parts.count >= 3 ? parts.dropFirst().joined(separator: "/") : name
        }
    }

    /// Claude Code encodes project paths as directory names ("/Users/me/x" -> "-Users-me-x").
    static func prettyClaudeProject(_ encoded: String, home: String) -> String {
        let encodedHome = home.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        if encoded.hasPrefix(encodedHome + "-") { return "~/" + encoded.dropFirst(encodedHome.count + 1) }
        return encoded
    }
}
