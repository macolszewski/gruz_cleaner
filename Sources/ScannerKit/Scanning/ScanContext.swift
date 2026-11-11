import Foundation

public struct ScanOptions: Sendable {
    public var projectRoots: [String]
    public var unrecognizedMinimumMB: Int
    public var home: String
    /// Folder walks allowed to run at the same time across the whole scan.
    public var fileSystemWidth: Int

    public init(projectRoots: [String]? = nil, unrecognizedMinimumMB: Int = 100, home: String = Paths.home,
                fileSystemWidth: Int = IOPool.defaultWidth) {
        self.projectRoots = projectRoots ?? Self.defaultProjectRoots(home: home)
        self.unrecognizedMinimumMB = unrecognizedMinimumMB
        self.home = home
        self.fileSystemWidth = fileSystemWidth
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
    public enum Outcome: Sendable, Equatable {
        case claimed
        /// The path or one of its ancestors is already claimed.
        case covered
        /// Paths inside it are claimed; it was not claimed.
        case hasDescendants(Set<String>)
    }

    private var claimed: Set<String> = []
    /// Number of claimed paths below each ancestor, so "is anything inside?" is one lookup instead of a
    /// scan of every claim, which kept large scans quadratic.
    private var descendantCount: [String: Int] = [:]

    public init() {}

    /// Claims `path` unless it is covered or has claimed descendants, in a single actor call.
    public func tryClaim(_ path: String) -> Outcome {
        let ancestors = Paths.ancestors(of: path)
        if claimed.contains(path) || ancestors.contains(where: claimed.contains) { return .covered }
        if descendantCount[path] != nil { return .hasDescendants(claimedInside(path)) }
        insert(path, ancestors: ancestors)
        return .claimed
    }

    /// Returns false when the path, one of its ancestors or one of its descendants is already claimed.
    public func claim(_ path: String) -> Bool { tryClaim(path) == .claimed }

    public func claimAll(_ paths: [String]) {
        for path in paths { insert(path, ancestors: Paths.ancestors(of: path)) }
    }

    public func isClaimed(_ path: String) -> Bool {
        claimed.contains(path) || Paths.ancestors(of: path).contains(where: claimed.contains)
    }

    /// Claimed paths strictly inside `path`. Rarely needed, so it is computed on demand.
    public func claimedInside(_ path: String) -> Set<String> {
        guard descendantCount[path] != nil else { return [] }
        return claimed.filter { Paths.isWithin($0, path) && $0 != path }
    }

    public func all() -> Set<String> { claimed }

    private func insert(_ path: String, ancestors: [String]) {
        guard claimed.insert(path).inserted else { return }
        for ancestor in ancestors { descendantCount[ancestor, default: 0] += 1 }
    }
}

struct ScanContext: Sendable {
    let catalog: RuleCatalog
    let options: ScanOptions
    let claims: ClaimRegistry
    let denylist: Denylist
    let warnings: WarningSink
    let cache: ScanCache
    let pool: IOPool

    init(catalog: RuleCatalog, options: ScanOptions, claims: ClaimRegistry, denylist: Denylist, warnings: WarningSink) {
        self.catalog = catalog
        self.options = options
        self.claims = claims
        self.denylist = denylist
        self.warnings = warnings
        cache = ScanCache()
        pool = IOPool(width: options.fileSystemWidth)
    }

    func isAllowed(_ path: String) -> Bool { denylist.check(path, cache: cache) == .allowed }

    func measure(_ path: String, excluding: Set<String> = []) async -> SizeInfo {
        await cache.measure(path, excluding: excluding, pool: pool)
    }

    func measureAll(_ paths: [String]) async -> [String: SizeInfo] { await cache.measureAll(paths, pool: pool) }
}

actor WarningSink {
    private var notes: [String] = []
    private var unreadable: Set<String> = []

    func add(_ message: String) { notes.append(message) }

    /// Places the scan could not look into or measure. They are reported even when no item comes from
    /// them, because a missing item would otherwise read as "nothing there".
    func addUnreadable(_ paths: [String]) { unreadable.formUnion(paths) }

    var messages: [String] {
        guard !unreadable.isEmpty else { return notes }
        let shown = unreadable.sorted().prefix(3).map(Paths.abbreviate)
        let list = shown.joined(separator: ", ") + (unreadable.count > shown.count ? ", …" : "")
        return notes + [String(localized: "Some folders could not be read, so data in them is missing from this scan: \(list)", bundle: .scannerKit)]
    }
}
