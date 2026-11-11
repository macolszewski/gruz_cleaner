import Darwin
import Foundation

/// One walk over a project folder that finds both build artifacts (`ProjectSource`) and Cargo manifests
/// (`RustDiscovery`).
///
/// The two searches prune different subtrees and go to different depths, so the walk descends wherever
/// at least one of them still looks and evaluates each folder only for the searches that would have
/// reached it. Both find exactly what their separate walks found, while shared folders are read once.
enum ProjectDiscovery {
    struct Result: Sendable {
        var artifacts: [ProjectSource.Found] = []
        var rust: Set<RustDiscovery.Location> = []
        /// Folders the artifact search could not enter; artifacts inside them are missing.
        var unreadable: [String] = []
    }

    /// The deepest folder level each search looks at.
    static let artifactDepth = 12
    static let rustDepth = 16
    static let rustSkippedNames: Set<String> = [".git", "node_modules", ".venv", "venv", ".build", "target", "vendor", "Pods"]
    static let rustHiddenAllowed: Set<String> = [".claude", ".codex", ".worktrees"]

    /// - Parameters:
    ///   - findRust: false skips the Cargo search entirely.
    ///   - list: names in a folder, nil when it cannot be listed; a scan passes its shared listings.
    static func walk(
        root: String, definitions: [ArtifactDefinition], home: String, findRust: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cargoConfigs: CargoConfigReader = CargoConfigReader(),
        list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
        cancellation: CancellationFlag? = nil
    ) -> Result {
        var byName: [String: [ArtifactDefinition]] = [:]
        for d in definitions { for n in d.dirNames { byName[n, default: []].append(d) } }
        let hiddenParents = definitions.compactMap(\.parentName).filter { $0.hasPrefix(".") }
        let hiddenAllowed = Set(byName.keys.filter { $0.hasPrefix(".") }).union(hiddenParents)

        var result = Result()
        let cRoot = strdup(root)
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            result.unreadable.append(root)
            return result
        }
        defer { fts_close(fts) }

        // Level of the folder below which a search no longer looks, or nil while it still does.
        var artifactPruned: Int?
        var rustPruned: Int? = findRust ? nil : -1
        var visited = 0
        defer { ScanMetrics.shared.add(.discoveryEntries, visited) }

        while let entry = fts_read(fts) {
            visited += 1
            let kind = Int32(entry.pointee.fts_info)
            let level = Int(entry.pointee.fts_level)
            // A search sees an entry when it did not prune any of its ancestors. The pruned folder itself
            // comes back once more after its preorder visit (FTS_DP, or FTS_DNR when it cannot be read);
            // that return belongs to the search that saw the folder, not to the one that pruned it.
            func sees(_ pruned: Int?) -> Bool {
                guard let pruned else { return true }
                return level < pruned || (level == pruned && kind == FTS_D)
            }
            let artifactSees = sees(artifactPruned)
            let rustSees = sees(rustPruned)
            if let p = artifactPruned, level <= p { artifactPruned = nil }
            if let p = rustPruned, p >= 0, level <= p { rustPruned = nil }

            if kind == FTS_DNR || kind == FTS_ERR, entry.pointee.fts_errno != ENOENT {
                if artifactSees { result.unreadable.append(String(cString: entry.pointee.fts_path)) }
                continue
            }
            guard kind == FTS_D else { continue }
            if visited % 256 == 0, cancellation?.isCancelled ?? Task.isCancelled { break }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent

            if rustSees {
                if level > rustDepth || (level > 0 && (rustSkippedNames.contains(name) || (name.hasPrefix(".") && !rustHiddenAllowed.contains(name)))) {
                    rustPruned = level
                } else if Paths.exists(Paths.join(path, "Cargo.toml")) {
                    result.rust.formUnion(RustDiscovery.locations(projectDir: path, home: home, environment: environment, configs: cargoConfigs))
                }
            }

            if artifactSees, level > 0 {
                if level > artifactDepth || name == ".git" || (name.hasPrefix(".") && !hiddenAllowed.contains(name)) {
                    artifactPruned = level
                } else if (path as NSString).deletingLastPathComponent == home, name == "Library" {
                    artifactPruned = level
                } else if let candidates = byName[name] {
                    let parent = (path as NSString).deletingLastPathComponent
                    if let match = candidates.first(where: { ProjectSource.matches($0, path: path, parent: parent, list: list) }) {
                        result.artifacts.append(ProjectSource.Found(definition: match, path: path, root: root))
                        artifactPruned = level
                    } else if !candidates.contains(where: { $0.parentName != nil }) {
                        // Unmatched dependency/build folders are still not worth descending into.
                        artifactPruned = level
                    }
                }
            }

            if artifactPruned != nil, rustPruned != nil {
                fts_set(fts, entry, FTS_SKIP)
            }
        }
        return result
    }
}

/// Cargo configuration files read once per scan: every manifest in a workspace consults the same
/// files in its ancestor folders and in Cargo's home.
final class CargoConfigReader: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String?] = [:]

    func text(at path: String) -> String? {
        if let cached = lock.withLock({ texts[path] }) { return cached }
        let text = try? String(contentsOfFile: path, encoding: .utf8)
        lock.withLock { texts[path] = .some(text) }
        return text
    }
}
