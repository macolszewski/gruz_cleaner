import Darwin
import Foundation

/// Finds regenerable directories (dependencies, build output) inside the user's project folders.
enum ProjectSource {
    struct Found: Sendable {
        var definition: ArtifactDefinition
        var path: String
        var root: String
    }

    static func scan(_ ctx: ScanContext) async -> [ScanItem] {
        let roots = ctx.options.projectRoots.map { Paths.expand($0, home: ctx.options.home) }.filter(Paths.isDirectory)
        var rustItems: [ScanItem] = []
        for location in RustDiscovery.find(in: roots, home: ctx.options.home) {
            guard ctx.denylist.check(location.target) == .allowed, await ctx.claims.claim(location.target) else { continue }
            let item = RustArtifacts.items(target: location.target, manifestPath: location.manifest)
            if item.leaves.contains(where: { $0.rustArtifact != nil && $0.action == nil }) {
                await ctx.warnings.add(String(localized: "Rust: some folders need manual review: \(Paths.abbreviate(location.target))", bundle: .scannerKit))
            }
            rustItems.append(item)
        }
        var found: [Found] = []
        for root in roots {
            var unreadable: [String] = []
            found += findArtifacts(in: root, definitions: ctx.catalog.artifacts, home: ctx.options.home, unreadable: &unreadable)
            await ctx.warnings.addUnreadable(unreadable)
        }

        // Expand container artifacts (worktrees) into their children.
        var leaves: [Found] = []
        for f in found {
            if f.definition.childrenAreItems {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []
                for entry in entries.sorted() where Paths.isDirectory(Paths.join(f.path, entry)) {
                    leaves.append(Found(definition: f.definition, path: Paths.join(f.path, entry), root: f.root))
                }
            } else {
                leaves.append(f)
            }
        }

        var accepted: [Found] = []
        for leaf in leaves where ctx.denylist.check(leaf.path) == .allowed {
            if leaf.definition.rejectGitTracked, await hasGitTrackedFiles(leaf.path) { continue }
            if await ctx.claims.claim(leaf.path) { accepted.append(leaf) }
        }
        let sizes = await SizeCalculator.measureAll(accepted.filter { $0.definition.id != "artifact.rust-target" }.map(\.path))

        var gitNotes: [String: String] = [:]
        for leaf in accepted where leaf.definition.gitStatusCheck {
            gitNotes[leaf.path] = await gitStatusNote(leaf.path)
        }

        var items: [ScanItem] = rustItems + accepted.filter { $0.definition.id == "artifact.rust-target" }.map { RustArtifacts.items(target: $0.path) }
        for definition in ctx.catalog.artifacts {
            let children = accepted.filter { $0.definition.id == definition.id }.compactMap { leaf -> ScanItem? in
                guard let info = sizes[leaf.path], info.allocatedBytes > 0 else { return nil }
                var item = makeItem(definition, path: leaf.path, root: leaf.root, info: info, note: gitNotes[leaf.path])
                if matchedOnlyGenericNames(definition, path: leaf.path) {
                    item.safety = .caution
                    item.note = String(localized: "Only generic folder names (such as lib or tmp) suggest that a build tool made this folder. Check its contents before removing it.", bundle: .scannerKit)
                }
                return item
            }
            if let group = makeGroup(definition, children: children) { items.append(group) }
        }
        return items
    }

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
            regeneration: definition.regeneration, safety: definition.safety,
            sizeBytes: children.reduce(0) { $0 + $1.sizeBytes }, lastModified: children.compactMap(\.lastModified).max(),
            children: children
        )
    }

    static func findArtifacts(in root: String, definitions: [ArtifactDefinition], home: String) -> [Found] {
        var unreadable: [String] = []
        return findArtifacts(in: root, definitions: definitions, home: home, unreadable: &unreadable)
    }

    /// - Parameter unreadable: folders the walk could not enter; artifacts inside them are missing.
    static func findArtifacts(in root: String, definitions: [ArtifactDefinition], home: String, unreadable: inout [String]) -> [Found] {
        var byName: [String: [ArtifactDefinition]] = [:]
        for d in definitions { for n in d.dirNames { byName[n, default: []].append(d) } }
        let hiddenParents = definitions.compactMap(\.parentName).filter { $0.hasPrefix(".") }
        let hiddenAllowed = Set(byName.keys.filter { $0.hasPrefix(".") }).union(hiddenParents)

        var results: [Found] = []
        let cRoot = strdup(root)
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            unreadable.append(root)
            return []
        }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let kind = Int32(entry.pointee.fts_info)
            if kind == FTS_DNR || kind == FTS_ERR, entry.pointee.fts_errno != ENOENT {
                unreadable.append(String(cString: entry.pointee.fts_path))
                continue
            }
            guard kind == FTS_D, entry.pointee.fts_level > 0 else { continue }
            if Task.isCancelled { break }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if entry.pointee.fts_level > 12 || name == ".git" || (name.hasPrefix(".") && !hiddenAllowed.contains(name)) {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            if (path as NSString).deletingLastPathComponent == home, name == "Library" {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            guard let candidates = byName[name] else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            if let match = candidates.first(where: { matches($0, path: path, parent: parent) }) {
                results.append(Found(definition: match, path: path, root: root))
                fts_set(fts, entry, FTS_SKIP)
            } else if !candidates.contains(where: { $0.parentName != nil }) {
                // Unmatched dependency/build folders are still not worth descending into.
                fts_set(fts, entry, FTS_SKIP)
            }
        }
        return results
    }

    static func matches(_ d: ArtifactDefinition, path: String, parent: String) -> Bool {
        if let parentName = d.parentName, (parent as NSString).lastPathComponent != parentName { return false }
        if !d.parentSiblingsAny.isEmpty {
            let workspace = (parent as NSString).deletingLastPathComponent
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: workspace)) ?? [])
                .filter { s in d.parentSiblingsAny.contains { Paths.fnmatch($0, s) } }
            guard !names.isEmpty else { return false }
            if !d.parentSiblingContainsAny.isEmpty, !names.contains(where: { fileContains(Paths.join(workspace, $0), any: d.parentSiblingContainsAny) }) {
                return false
            }
        }
        if !d.siblingsAny.isEmpty {
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            guard siblings.contains(where: { s in d.siblingsAny.contains { Paths.fnmatch($0, s) } }) else { return false }
        }
        if !d.insideAny.isEmpty || !d.insideNone.isEmpty {
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
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
        let text = String(decoding: data, as: UTF8.self)
        return needles.contains { text.contains($0) }
    }

    /// True when `definition` names tool-specific entries and none of them is inside `path`.
    static func matchedOnlyGenericNames(_ definition: ArtifactDefinition, path: String) -> Bool {
        guard !definition.insideStrong.isEmpty else { return false }
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
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
