import Foundation

/// Everything one scan found, plus the disk state at the time.
public struct ScanResult: Sendable, Codable {
    public var items: [ScanItem]
    public var warnings: [String]
    public var startedAt: Date
    public var finishedAt: Date
    public var freeBytes: Int64?
    public var totalBytes: Int64?
    public var hasFullDiskAccess: Bool
    /// Language of the item texts, so a cached result in another language can be discarded.
    /// Nil for results saved before it was recorded.
    public var language: String?

    public init(items: [ScanItem], warnings: [String], startedAt: Date, finishedAt: Date,
                freeBytes: Int64?, totalBytes: Int64?, hasFullDiskAccess: Bool, language: String? = Localization.current) {
        self.items = items
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.hasFullDiskAccess = hasFullDiskAccess
        self.language = language
    }

    public func items(in category: Category) -> [ScanItem] { items.filter { $0.category == category } }

    /// Every item in the tree, by id.
    public var index: [String: ScanItem] {
        var map: [String: ScanItem] = [:]
        func visit(_ i: ScanItem) {
            map[i.id] = i
            i.children.forEach(visit)
        }
        items.forEach(visit)
        return map
    }
}

/// A phase of the scan, reported for progress display.
public enum ScanStage: String, Sendable {
    case rules
    case docker
    case simulators
    case projects
    case orphans
    case applications
    case unrecognized

    public var title: String {
        switch self {
        case .rules: String(localized: "Known locations", bundle: .scannerKit)
        case .docker: "Docker"
        case .simulators: String(localized: "Simulators", bundle: .scannerKit)
        case .projects: String(localized: "Projects", bundle: .scannerKit)
        case .orphans: String(localized: "App leftovers", bundle: .scannerKit)
        case .applications: String(localized: "Applications", bundle: .scannerKit)
        case .unrecognized: String(localized: "Unrecognized", bundle: .scannerKit)
        }
    }
}

/// Orchestrates all read-only sources.
public struct Scanner: Sendable {
    public let catalog: RuleCatalog
    public let options: ScanOptions

    public init(catalog: RuleCatalog, options: ScanOptions) {
        self.catalog = catalog
        self.options = options
    }

    /// - Parameters:
    ///   - onStage: called when a stage starts (false) and finishes (true).
    ///   - onItems: called with each stage's items as soon as it finishes, for progressive display.
    public func scan(
        onStage: @escaping @Sendable (ScanStage, Bool) -> Void = { _, _ in },
        onItems: @escaping @Sendable ([ScanItem]) -> Void = { _ in }
    ) async -> ScanResult {
        let started = Date()
        let ctx = ScanContext(
            catalog: catalog, options: options, claims: ClaimRegistry(),
            denylist: Denylist(home: options.home, protectedRoots: options.projectRoots), warnings: WarningSink()
        )

        ScanMetrics.shared.reset()

        func run(_ stage: ScanStage, _ body: @Sendable (ScanContext) async -> [ScanItem]) async -> [ScanItem] {
            onStage(stage, false)
            let signposter = ScanMetrics.signposter
            let interval = signposter.beginInterval("Scan stage", id: signposter.makeSignpostID(), "\(stage.rawValue, privacy: .public)")
            let items = await body(ctx)
            signposter.endInterval("Scan stage", interval)
            onItems(items)
            onStage(stage, true)
            return items
        }

        // Docker and simulators claim their storage first so rules and orphans do not report it twice.
        // Only the claims come first: the CLI queries can take minutes and run alongside the rules.
        await ctx.claims.claimAll(DockerSource.reservedPaths(home: options.home) + SimulatorSource.reservedPaths(home: options.home))
        async let docker = run(.docker, DockerSource.scan)
        async let simulators = run(.simulators, SimulatorSource.scan)
        let ruleItems = await run(.rules, RuleSource.scan)

        async let projects = run(.projects, ProjectSource.scan)
        async let applications = run(.applications, ApplicationsSource.scan)
        let projectItems = await projects
        let orphanItems = await run(.orphans, OrphanSource.scan)
        let applicationItems = await applications
        // Unrecognized folders are what no other source describes, so every claim must be in.
        let dockerItems = await docker
        let simulatorItems = await simulators
        let unrecognizedItems = await run(.unrecognized, UnrecognizedSource.scan)

        let all = dockerItems + simulatorItems + ruleItems + projectItems + orphanItems + applicationItems + unrecognizedItems
        return ScanResult(
            items: all, warnings: await ctx.warnings.messages, startedAt: started, finishedAt: Date(),
            freeBytes: DiskSpace.available(at: options.home), totalBytes: DiskSpace.total(at: options.home),
            hasFullDiskAccess: FullDiskAccess.isGranted(home: options.home), language: Localization.current
        )
    }
}

public enum FullDiskAccess {
    /// Probes folders protected by TCC; reading them fails without Full Disk Access.
    public static func isGranted(home: String = Paths.home) -> Bool {
        for probe in ["Library/Mail", "Library/Safari", "Library/Messages", ".Trash"] {
            let path = Paths.join(home, probe)
            guard Paths.exists(path) else { continue }
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        return true
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
