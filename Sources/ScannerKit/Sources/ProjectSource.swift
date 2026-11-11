import Foundation

/// Finds regenerable directories (dependencies, build output) inside the user's project folders.
enum ProjectSource {
    struct Found: Sendable {
        var definition: ArtifactDefinition
        var path: String
        var root: String
    }

    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        var seenRoots = Set<String>()
        let roots = ctx.options.projectRoots.map { Paths.expand($0, home: ctx.options.home) }
            .filter { Paths.isDirectory($0) && seenRoots.insert($0).inserted }
        let definitions = ctx.catalog.artifacts, home = ctx.options.home, cache = ctx.cache
        let configs = CargoConfigReader()
        let walks = await ctx.pool.map(roots) { root, cancellation in
            ProjectDiscovery.walk(root: root, definitions: definitions, home: home, cargoConfigs: configs,
                                  list: cache.contents(of:), cancellation: cancellation)
        }

        // Rust targets are claimed first, in a stable order, so the generic `target` artifact cannot take them.
        var rustTargets: [RustDiscovery.Location] = []
        for location in RustDiscovery.sorted(roots.reduce(into: Set()) { $0.formUnion(walks[$1]?.rust ?? []) }) {
            guard ctx.isAllowed(location.target), await ctx.claims.claim(location.target) else { continue }
            rustTargets.append(location)
        }
        let rustMeasured = await ctx.pool.map(rustTargets) { location, cancellation in
            RustArtifacts.items(target: location.target, manifestPath: location.manifest, cancellation: cancellation)
        }
        var rustItems: [ScanItem] = []
        for location in rustTargets {
            guard let item = rustMeasured[location] else { continue }
            if item.leaves.contains(where: { $0.rustArtifact != nil && $0.action == nil }) {
                await ctx.warnings.add(String(localized: "Rust: some folders need manual review: \(Paths.abbreviate(location.target))", bundle: .scannerKit))
            }
            rustItems.append(item)
        }

        var found: [Found] = []
        for root in roots {
            found += walks[root]?.artifacts ?? []
            await ctx.warnings.addUnreadable(walks[root]?.unreadable ?? [])
        }

        // Expand container artifacts (worktrees) into their children.
        var leaves: [Found] = []
        for f in found {
            if f.definition.childrenAreItems {
                let entries = cache.contents(of: f.path) ?? []
                for entry in entries.sorted() where Paths.isDirectory(Paths.join(f.path, entry)) {
                    leaves.append(Found(definition: f.definition, path: Paths.join(f.path, entry), root: f.root))
                }
            } else {
                leaves.append(f)
            }
        }

        let allowed = leaves.filter { ctx.isAllowed($0.path) }
        let tracked = await concurrentMap(allowed.filter(\.definition.rejectGitTracked).map(\.path), width: 4) { await hasGitTrackedFiles($0) }
        var accepted: [Found] = []
        for leaf in allowed where tracked[leaf.path] != true {
            if await ctx.claims.claim(leaf.path) { accepted.append(leaf) }
        }
        async let measuredSizes = ctx.measureAll(accepted.filter { !isRustTarget($0) }.map(\.path))
        async let measuredTargets = ctx.pool.map(accepted.filter(isRustTarget).map(\.path)) { path, cancellation in
            RustArtifacts.items(target: path, cancellation: cancellation)
        }
        let checkouts = accepted.filter(\.definition.gitStatusCheck).map(\.path)
        async let notes = concurrentMap(checkouts, width: 4) { await gitStatusNote($0) }
        let sizes = await measuredSizes, targetItems = await measuredTargets
        let gitNotes = await notes.compactMapValues { $0 }

        var items: [ScanItem] = rustItems + accepted.filter(isRustTarget).compactMap { targetItems[$0.path] }
        for definition in ctx.catalog.artifacts {
            let children = accepted.filter { $0.definition.id == definition.id }.compactMap { leaf -> ScanItem? in
                guard let info = sizes[leaf.path], info.allocatedBytes > 0 else { return nil }
                var item = makeItem(definition, path: leaf.path, root: leaf.root, info: info, note: gitNotes[leaf.path])
                if matchedOnlyGenericNames(definition, path: leaf.path, list: cache.contents(of:)) {
                    item.safety = .caution
                    item.note = String(localized: "Only generic folder names (such as lib or tmp) suggest that a build tool made this folder. Check its contents before removing it.", bundle: .scannerKit)
                }
                return item
            }
            if let group = makeGroup(definition, children: children) { items.append(group) }
        }
        return items
    }

    static func isRustTarget(_ leaf: Found) -> Bool { leaf.definition.id == "artifact.rust-target" }

    static func makeItem(_ definition: ArtifactDefinition, path: String, root: String, info: SizeInfo, note: String?) -> ScanItem {
        let rootName = (root as NSString).lastPathComponent
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        // A project can hold several folders of one definition (bin and obj, test-results and playwright-report),
        // so those are named in full; single-name folders by their project.
        let title = definition.childrenAreItems || definition.parentName != nil || definition.dirNames.count > 1
            ? "\(rootName)/\(relative)"
            : "\(rootName)/\((relative as NSString).deletingLastPathComponent)"
        return ScanItem(
            id: "\(definition.id):\(path)", ruleID: definition.id, category: .projects,
            title: title, app: nil, description: definition.description, regeneration: definition.regeneration,
            safety: definition.safety, sizeBytes: info.allocatedBytes, lastModified: info.newestModification,
            paths: [path], action: definition.action, note: note
        ).measured(info)
    }

    static func makeGroup(_ definition: ArtifactDefinition, children: [ScanItem]) -> ScanItem? {
        guard !children.isEmpty else { return nil }
        let children = children.sorted { $0.sizeBytes > $1.sizeBytes }
        return ScanItem(
            id: definition.id, ruleID: definition.id, category: .projects,
            title: "\(definition.title) (\(children.count))", description: definition.description,
            // The header must not look safer than any item inside it.
            regeneration: definition.regeneration, safety: children.map(\.safety).max() ?? definition.safety,
            sizeBytes: children.reduce(0) { $0 + $1.sizeBytes }, lastModified: children.compactMap(\.lastModified).max(),
            children: children
        )
    }

    static func findArtifacts(in root: String, definitions: [ArtifactDefinition], home: String) -> [Found] {
        ProjectDiscovery.walk(root: root, definitions: definitions, home: home, findRust: false).artifacts
    }

    typealias Lister = (String) -> [String]?

    static func matches(_ d: ArtifactDefinition, path: String, parent: String,
                        list: Lister = { try? FileManager.default.contentsOfDirectory(atPath: $0) }) -> Bool {
        if let parentName = d.parentName, (parent as NSString).lastPathComponent != parentName { return false }
        if !d.parentSiblingsAny.isEmpty {
            let workspace = (parent as NSString).deletingLastPathComponent
            let names = (list(workspace) ?? []).filter { s in d.parentSiblingsAny.contains { Paths.fnmatch($0, s) } }
            guard !names.isEmpty else { return false }
            if !d.parentSiblingContainsAny.isEmpty, !names.contains(where: { fileContains(Paths.join(workspace, $0), any: d.parentSiblingContainsAny) }) {
                return false
            }
        }
        if !d.siblingsAny.isEmpty {
            let siblings = list(parent) ?? []
            guard siblings.contains(where: { s in d.siblingsAny.contains { Paths.fnmatch($0, s) } }) else { return false }
        }
        if !d.insideAny.isEmpty || !d.insideNone.isEmpty {
            let inside = list(path) ?? []
            if !d.insideAny.isEmpty, !inside.contains(where: { s in d.insideAny.contains { Paths.fnmatch($0, s) } }) { return false }
            if inside.contains(where: { s in d.insideNone.contains { Paths.fnmatch($0, s) } }) { return false }
        }
        return true
    }

    /// Reads at most 1 MB: project files that declare build settings are small.
    static func fileContains(_ path: String, any needles: [String]) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20) else { return false }
        // A commented-out setting (`<!-- <UseArtifactsOutput>true</UseArtifactsOutput> -->`) is not a setting.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        return needles.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// True when `definition` names tool-specific entries and none of them is inside `path`.
    static func matchedOnlyGenericNames(_ definition: ArtifactDefinition, path: String,
                                        list: Lister = { try? FileManager.default.contentsOfDirectory(atPath: $0) }) -> Bool {
        guard !definition.insideStrong.isEmpty else { return false }
        let inside = list(path) ?? []
        return !inside.contains { name in definition.insideStrong.contains { Paths.fnmatch($0, name) } }
    }

    /// Build output is ignored by Git; tracked files mean the folder is part of the project's sources.
    /// Outside a repository (or when Git cannot answer) nothing is known, and the other checks decide.
    static func hasGitTrackedFiles(_ path: String) async -> Bool {
        guard let out = try? await ReadOnlyCommand.run(["git"] + GitInspection.options + ["-C", path, "ls-files"], timeout: 20),
              out.status == 0 else { return false }
        return !out.stdout.isEmpty
    }

    static func gitStatusNote(_ path: String) async -> String? {
        let couldNotCheck = String(localized: "Could not check the Git status", bundle: .scannerKit)
        // `git status` runs the clean filters a repository configures (Git LFS and others) on files it
        // re-reads. Their names come from plain config reading, then each is switched off for the status run.
        guard let config = try? await ReadOnlyCommand.run(["git"] + GitInspection.options + ["-C", path, "config", "--get-regexp", "^filter\\."], timeout: 20),
              config.status == 0 || (config.status == 1 && config.stdout.isEmpty) else { return couldNotCheck }
        let filters = GitInspection.filterNames(fromConfig: String(decoding: config.stdout, as: UTF8.self))
        guard let out = try? await ReadOnlyCommand.run(
            ["git"] + GitInspection.options + ["-C", path, "status", "--porcelain"], timeout: 20,
            environment: GitInspection.environment(disablingFilters: filters)
        ), out.status == 0 else { return couldNotCheck }
        let lines = String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").count
        return lines == 0 ? String(localized: "Git: no uncommitted changes", bundle: .scannerKit) : String(localized: "Git: \(lines) uncommitted changes. Check before removing!", bundle: .scannerKit)
    }
}
