import Darwin
import Foundation

/// Discovers manifests without entering dependency/build trees or following symlinks.
enum RustDiscovery {
    struct Location: Hashable { var target: String; var manifest: String }

    static func find(in roots: [String], home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [Location] {
        var found = Set<Location>()
        let skip: Set<String> = [".git", "node_modules", ".venv", "venv", ".build", "target", "vendor", "Pods"]
        for root in roots {
            let cRoot = strdup(root)
            defer { free(cRoot) }
            var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
            guard let tree = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { continue }
            defer { fts_close(tree) }
            while let entry = fts_read(tree) {
                if Task.isCancelled { break }
                guard Int32(entry.pointee.fts_info) == FTS_D else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                if entry.pointee.fts_level > 16 || (entry.pointee.fts_level > 0 && (skip.contains(name)
                    || (name.hasPrefix(".") && ![".claude", ".codex", ".worktrees"].contains(name)))) {
                    fts_set(tree, entry, FTS_SKIP); continue
                }
                let manifest = Paths.join(path, "Cargo.toml")
                guard Paths.exists(manifest) else { continue }
                var targets = [Paths.join(path, "target")]
                // A literal configured directory is additional evidence, never a reason to infer deletion of its root.
                var ancestors: [String] = []
                var ancestor = path
                while ancestor != "/" {
                    ancestors.append(ancestor)
                    ancestor = (ancestor as NSString).deletingLastPathComponent
                }
                let cargoHome = environment["CARGO_HOME"] ?? Paths.join(home, ".cargo")
                let configs = [Paths.join(cargoHome, "config"), Paths.join(cargoHome, "config.toml")]
                    + ancestors.reversed().flatMap { [Paths.join($0, ".cargo/config"), Paths.join($0, ".cargo/config.toml")] }
                for config in configs {
                    guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { continue }
                    let base = ((config as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                    for value in literalBuildDirectories(text) {
                        targets.append(value.hasPrefix("/") ? value : Paths.join(base, value))
                    }
                }
                for variable in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR", "CARGO_BUILD_BUILD_DIR"] {
                    if let value = environment[variable], value.hasPrefix("/") { targets.append(value) }
                }
                for target in targets.map(Paths.normalize) where Paths.isDirectory(target) {
                    // Only actual Cargo output with existing lock-bearing profiles is eligible later.
                    guard (target as NSString).resolvingSymlinksInPath == target else { continue }
                    found.insert(Location(target: target, manifest: manifest))
                }
            }
        }
        return found.sorted { $0.target == $1.target ? $0.manifest < $1.manifest : $0.target < $1.target }
    }

    /// Deliberately accepts only literal TOML strings; templates and complex forms are not guessed.
    static func literalBuildDirectories(_ text: String) -> [String] {
        var inBuild = false
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("[") { inBuild = clean == "[build]"; continue }
            let pair = clean.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            let key = pair[0]
            guard (inBuild && ["target-dir", "build-dir"].contains(key)) || ["build.target-dir", "build.build-dir"].contains(key) else { continue }
            let raw = pair[1]
            let value: String?
            if raw.hasPrefix("\""), raw.hasSuffix("\"") {
                value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
            } else if raw.hasPrefix("'"), raw.hasSuffix("'") { value = String(raw.dropFirst().dropLast()) }
            else { value = nil }
            if let value, !value.isEmpty, !value.contains("{"), !value.contains("$"), !value.contains("\n"), !value.hasPrefix("~") {
                result.append(value)
            }
        }
        return result
    }
}
