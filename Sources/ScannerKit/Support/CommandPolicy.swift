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
        [.literal("uv"), .literal("cache"), .literal("clean")],
        [.literal("uv"), .literal("cache"), .literal("prune")],
        [.literal("npm"), .literal("cache"), .literal("clean"), .literal("--force")],
        [.literal("brew"), .literal("cleanup"), .literal("--prune=all")],
        [.literal("dotnet"), .literal("nuget"), .literal("locals"), .literal("all"), .literal("--clear")],
    ]

    private static let readOnlyPatterns: [[Token]] = [
        [.literal("docker"), .literal("system"), .literal("df"), .literal("-v"), .literal("--format"), .literal("{{json .}}")],
        [.literal("xcrun"), .literal("simctl"), .literal("list"), .literal("devices"), .literal("--json")],
        [.literal("git"), .literal("-C"), .operand, .literal("status"), .literal("--porcelain")],
    ]

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
