import Foundation

public struct ScanOptions: Sendable {
    public var projectRoots: [String]
    public var unrecognizedMinimumMB: Int
    public var home: String

    public init(projectRoots: [String]? = nil, unrecognizedMinimumMB: Int = 100, home: String = Paths.home) {
        self.projectRoots = projectRoots ?? Self.defaultProjectRoots(home: home)
        self.unrecognizedMinimumMB = unrecognizedMinimumMB
        self.home = home
    }

    /// Folders developers commonly keep their code in. They are always protected from removal.
    public static let commonProjectRoots = ["~/Developer", "~/workspace", "~/Projects", "~/code", "~/src", "~/dev", "~/repos"]

    /// The common project folders that exist in `home`, or `~/Developer` when none does.
    public static func defaultProjectRoots(home: String = Paths.home) -> [String] {
        let existing = commonProjectRoots.filter { Paths.isDirectory(Paths.expand($0, home: home)) }
        return existing.isEmpty ? ["~/Developer"] : existing
    }
}

/// Tracks paths already described by some source, so each location is reported once.
public actor ClaimRegistry {
    private var claimed: Set<String> = []

    public init() {}

    /// Returns false when the path, one of its ancestors or one of its descendants is already claimed.
    public func claim(_ path: String) -> Bool {
        if isClaimed(path) || claimed.contains(where: { $0.hasPrefix(path + "/") }) { return false }
        claimed.insert(path)
        return true
    }

    public func claimAll(_ paths: [String]) { claimed.formUnion(paths) }

    public func isClaimed(_ path: String) -> Bool {
        var p = path
        while true {
            if claimed.contains(p) { return true }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return false }
            p = parent
        }
    }

    /// Claimed paths strictly inside `path`.
    public func claimedInside(_ path: String) -> Set<String> {
        claimed.filter { $0.hasPrefix(path + "/") }
    }

    public func all() -> Set<String> { claimed }
}

struct ScanContext: Sendable {
    let catalog: RuleCatalog
    let options: ScanOptions
    let claims: ClaimRegistry
    let denylist: Denylist
    let warnings: WarningSink
}

actor WarningSink {
    private(set) var messages: [String] = []
    func add(_ message: String) { messages.append(message) }
}
