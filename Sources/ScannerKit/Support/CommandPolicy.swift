import Foundation

/// Exhaustive allow-lists of external commands. Anything not matching is refused.
public enum CommandPolicy {
    private enum Token {
        case literal(String)
        /// A single argument that is not an option (no leading "-") and not empty.
        case operand
    }

    private static let docker: [Token] = [.literal("docker"), .literal("--host"), .operand]

    private static let cleanPatterns: [[Token]] = [
        // Docker commands name the engine endpoint read during the scan, never the CLI's current context.
        docker + [.literal("image"), .literal("rm"), .operand],
        docker + [.literal("volume"), .literal("rm"), .operand],
        docker + [.literal("container"), .literal("rm"), .operand],
        docker + [.literal("builder"), .literal("prune"), .literal("--force")],
        [.literal("xcrun"), .literal("simctl"), .literal("delete"), .operand],
        // The cache folder is passed explicitly, so the command cleans the folder that was measured.
        [.literal("uv"), .literal("cache"), .literal("clean"), .literal("--cache-dir"), .operand],
        [.literal("npm"), .literal("cache"), .literal("clean"), .literal("--force")],
        [.literal("brew"), .literal("cleanup"), .literal("--prune=all")],
        [.literal("dotnet"), .literal("nuget"), .literal("locals"), .literal("all"), .literal("--clear")],
        // Go marks module files read-only, so its own command removes them; a `CommandCheck` on
        // `go env GOMODCACHE` binds it to the folder that was measured.
        [.literal("go"), .literal("clean"), .literal("-modcache")],
    ]

    private static let readOnlyPatterns: [[Token]] = [
        [.literal("docker"), .literal("context"), .literal("inspect"), .literal("--format"), .literal("{{.Endpoints.docker.Host}}")],
        docker + [.literal("system"), .literal("df"), .literal("-v"), .literal("--format"), .literal("{{json .}}")],
        docker + [.literal("info"), .literal("--format"), .literal("{{.ID}} {{.Name}}")],
        [.literal("xcrun"), .literal("simctl"), .literal("list"), .literal("devices"), .literal("--json")],
        [.literal("git")] + GitInspection.options.map { .literal($0) } + [.literal("-C"), .operand, .literal("status"), .literal("--porcelain")],
        [.literal("git")] + GitInspection.options.map { .literal($0) } + [.literal("-C"), .operand, .literal("config"), .literal("--get-regexp"), .literal("^filter\\.")],
        [.literal("git")] + GitInspection.options.map { .literal($0) } + [.literal("-C"), .operand, .literal("ls-files")],
    ]

    /// Read-only commands whose output binds a removal to what was scanned (see `CommandCheck`).
    private static let checkPatterns: [[Token]] = [
        docker + [.literal("info"), .literal("--format"), .literal("{{.ID}} {{.Name}}")],
        docker + [.literal("image"), .literal("inspect"), .literal("--format"), .literal("{{.Id}}"), .operand],
        [.literal("go"), .literal("env"), .literal("GOMODCACHE")],
    ]

    /// Whether `argv` may run as a check before a removal.
    public static func isAllowedCheckCommand(_ argv: [String]) -> Bool { matches(argv, checkPatterns) }

    public static func isAllowedCleanCommand(_ argv: [String]) -> Bool { matches(argv, cleanPatterns) }

    public static func isAllowedReadOnlyCommand(_ argv: [String]) -> Bool { matches(argv, readOnlyPatterns) }

    private static func matches(_ argv: [String], _ patterns: [[Token]]) -> Bool {
        patterns.contains { pattern in
            guard pattern.count == argv.count else { return false }
            return zip(pattern, argv).allSatisfy { token, arg in
                switch token {
                case .literal(let s): s == arg
                case .operand: !arg.isEmpty && !arg.hasPrefix("-")
                }
            }
        }
    }
}

/// How the scanner runs Git: read-only inspection must not start programs configured in the repository
/// (an fsmonitor hook) or take optional locks while refreshing the index.
public enum GitInspection {
    public static let options = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]

    /// Filter driver names from `git config --get-regexp '^filter\.'` (lines "filter.<name>.<key> <value>";
    /// a name may contain dots).
    public static func filterNames(fromConfig output: String) -> [String] {
        let names = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let key = line.prefix { !$0.isWhitespace }
            guard key.hasPrefix("filter."), let lastDot = key.lastIndex(of: "."), lastDot > key.index(key.startIndex, offsetBy: 6) else { return nil }
            return String(key[key.index(key.startIndex, offsetBy: 7)..<lastDot])
        }
        return Array(Set(names)).sorted()
    }

    /// Configuration passed through the environment (`GIT_CONFIG_COUNT`, Git 2.31+) that empties every
    /// command of the named filters: Git runs no filter whose command is empty.
    public static func environment(disablingFilters names: [String]) -> [String: String] {
        let keys = names.flatMap { name in ["clean", "smudge", "process"].map { "filter.\(name).\($0)" } }
        var env = ["GIT_CONFIG_COUNT": String(keys.count)]
        for (index, key) in keys.enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = key
            env["GIT_CONFIG_VALUE_\(index)"] = ""
        }
        return keys.isEmpty ? [:] : env
    }
}
