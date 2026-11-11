import Darwin
import Foundation

/// Discovers manifests without entering dependency/build trees or following symlinks.
enum RustDiscovery {
    struct Location: Hashable, Sendable { var target: String; var manifest: String }

    static func find(in roots: [String], home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [Location] {
        let configs = CargoConfigReader()
        var found = Set<Location>()
        for root in roots {
            found.formUnion(ProjectDiscovery.walk(root: root, definitions: [], home: home, environment: environment, cargoConfigs: configs).rust)
        }
        return sorted(found)
    }

    static func sorted(_ locations: Set<Location>) -> [Location] {
        locations.sorted { $0.target == $1.target ? $0.manifest < $1.manifest : $0.target < $1.target }
    }

    /// Target folders of the Cargo project in `projectDir` (which holds `Cargo.toml`).
    static func locations(projectDir path: String, home: String, environment: [String: String], configs: CargoConfigReader) -> [Location] {
        let manifest = Paths.join(path, "Cargo.toml")
        var targets = [Paths.join(path, "target")]
        // A literal configured directory is additional evidence, never a reason to infer deletion of its root.
        var ancestors: [String] = []
        var ancestor = path
        while ancestor != "/" {
            ancestors.append(ancestor)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        let cargoHome = environment["CARGO_HOME"] ?? Paths.join(home, ".cargo")
        let files = [Paths.join(cargoHome, "config"), Paths.join(cargoHome, "config.toml")]
            + ancestors.reversed().flatMap { [Paths.join($0, ".cargo/config"), Paths.join($0, ".cargo/config.toml")] }
        for config in files {
            guard let text = configs.text(at: config) else { continue }
            let base = ((config as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            for value in literalBuildDirectories(text) {
                targets.append(value.hasPrefix("/") ? value : Paths.join(base, value))
            }
        }
        for variable in ["CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR", "CARGO_BUILD_BUILD_DIR"] {
            if let value = environment[variable], value.hasPrefix("/") { targets.append(value) }
        }
        var found: [Location] = []
        for target in targets.map(Paths.normalize) where Paths.isDirectory(target) {
            // Only actual Cargo output with existing lock-bearing profiles is eligible later.
            guard (target as NSString).resolvingSymlinksInPath == target else { continue }
            found.append(Location(target: target, manifest: manifest))
        }
        return found
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
