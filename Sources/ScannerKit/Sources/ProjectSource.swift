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
            found += findArtifacts(in: root, definitions: ctx.catalog.artifacts, home: ctx.options.home)
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
                return makeItem(definition, path: leaf.path, root: leaf.root, info: info, note: gitNotes[leaf.path])
            }
            if let group = makeGroup(definition, children: children) { items.append(group) }
        }
        return items
    }

    static func makeItem(_ definition: ArtifactDefinition, path: String, root: String, info: SizeInfo, note: String?) -> ScanItem {
        let rootName = (root as NSString).lastPathComponent
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let title = definition.childrenAreItems
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
        var byName: [String: [ArtifactDefinition]] = [:]
        for d in definitions { for n in d.dirNames { byName[n, default: []].append(d) } }
        let hiddenAllowed = Set(byName.keys.filter { $0.hasPrefix(".") }).union([".claude"])

        var results: [Found] = []
        let cRoot = strdup(root)
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return [] }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            guard Int32(entry.pointee.fts_info) == FTS_D, entry.pointee.fts_level > 0 else { continue }
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

    static func gitStatusNote(_ path: String) async -> String? {
        guard let out = try? await ReadOnlyCommand.run(["git"] + GitInspection.options + ["-C", path, "status", "--porcelain"], timeout: 20),
              out.status == 0 else { return String(localized: "Could not check the Git status", bundle: .scannerKit) }
        let lines = String(decoding: out.stdout, as: UTF8.self).split(separator: "\n").count
        return lines == 0 ? String(localized: "Git: no uncommitted changes", bundle: .scannerKit) : String(localized: "Git: \(lines) uncommitted changes. Check before removing!", bundle: .scannerKit)
    }
}
