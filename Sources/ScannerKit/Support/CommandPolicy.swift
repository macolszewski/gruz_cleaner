import Foundation

/// Exhaustive allow-lists of external commands. Anything not matching is refused.
public enum CommandPolicy {
    private enum Token {
        case literal(String)
        /// A single argument that is not an option (no leading "-") and not empty.
        case operand
    }

    private static let cleanPatterns: [[Token]] = [
        [.literal("docker"), .literal("image"), .literal("rm"), .operand],
        [.literal("docker"), .literal("volume"), .literal("rm"), .operand],
        [.literal("docker"), .literal("container"), .literal("rm"), .operand],
        [.literal("docker"), .literal("builder"), .literal("prune"), .literal("--force")],
        [.literal("xcrun"), .literal("simctl"), .literal("delete"), .operand],
        // The cache folder is passed explicitly, so the command cleans the folder that was measured.
        [.literal("uv"), .literal("cache"), .literal("clean"), .literal("--cache-dir"), .operand],
        [.literal("npm"), .literal("cache"), .literal("clean"), .literal("--force")],
        [.literal("brew"), .literal("cleanup"), .literal("--prune=all")],
        [.literal("dotnet"), .literal("nuget"), .literal("locals"), .literal("all"), .literal("--clear")],
    ]

    private static let readOnlyPatterns: [[Token]] = [
        [.literal("docker"), .literal("system"), .literal("df"), .literal("-v"), .literal("--format"), .literal("{{json .}}")],
        [.literal("docker"), .literal("info"), .literal("--format"), .literal("{{.ID}} {{.Name}}")],
        [.literal("xcrun"), .literal("simctl"), .literal("list"), .literal("devices"), .literal("--json")],
        [.literal("git")] + GitInspection.options.map { .literal($0) } + [.literal("-C"), .operand, .literal("status"), .literal("--porcelain")],
    ]

    /// Read-only commands whose output binds a removal to what was scanned (see `CommandCheck`).
    private static let checkPatterns: [[Token]] = [
        [.literal("docker"), .literal("info"), .literal("--format"), .literal("{{.ID}} {{.Name}}")],
        [.literal("docker"), .literal("image"), .literal("inspect"), .literal("--format"), .literal("{{.Id}}"), .operand],
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
}
