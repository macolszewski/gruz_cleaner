import Foundation

/// How risky removing an item is. Ordered from safe to user data.
public enum Safety: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case regenerable
    case caution
    case userData

    public var title: String {
        switch self {
        case .safe: String(localized: "Safe", bundle: .scannerKit)
        case .regenerable: String(localized: "Regenerable", bundle: .scannerKit)
        case .caution: String(localized: "Caution", bundle: .scannerKit)
        case .userData: String(localized: "User data", bundle: .scannerKit)
        }
    }

    public var explanation: String {
        switch self {
        case .safe:
            String(localized: "A cache the app recreates on its own. Removing it costs at most a new download or a slower first launch.", bundle: .scannerKit)
        case .regenerable:
            String(localized: "Build artifacts or dependencies. They can be recreated, but that takes a project build, an install or a download.", bundle: .scannerKit)
        case .caution:
            String(localized: "May contain data that cannot be recreated (databases, sessions, settings). Remove it only if you know what it is.", bundle: .scannerKit)
        case .userData:
            String(localized: "Your data. It is shown for information only and cannot be removed with GRUZ.", bundle: .scannerKit)
        }
    }

    private var order: Int {
        switch self {
        case .safe: 0
        case .regenerable: 1
        case .caution: 2
        case .userData: 3
        }
    }

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.order < rhs.order }
}

/// The section of the interface an item is listed in.
public enum Category: String, Codable, Sendable, CaseIterable, Identifiable {
    case docker
    case packages
    case projects
    case rust
    case xcode
    case android
    case ai
    case apps
    case browsers
    case system
    case orphans
    case applications
    case unrecognized

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .docker: String(localized: "Docker and OrbStack", bundle: .scannerKit)
        case .packages: String(localized: "Package managers", bundle: .scannerKit)
        case .projects: String(localized: "Projects", bundle: .scannerKit)
        case .rust: String(localized: "Rust and Cargo", bundle: .scannerKit)
        case .xcode: String(localized: "Xcode and simulators", bundle: .scannerKit)
        case .android: "Android"
        case .ai: String(localized: "AI tools", bundle: .scannerKit)
        case .apps: String(localized: "App caches", bundle: .scannerKit)
        case .browsers: String(localized: "Browsers", bundle: .scannerKit)
        case .system: String(localized: "System and logs", bundle: .scannerKit)
        case .orphans: String(localized: "App leftovers", bundle: .scannerKit)
        case .applications: String(localized: "Applications", bundle: .scannerKit)
        case .unrecognized: String(localized: "Unrecognized", bundle: .scannerKit)
        }
    }

    public var symbol: String {
        switch self {
        case .docker: "shippingbox"
        case .packages: "archivebox"
        case .projects: "folder.badge.gearshape"
        case .rust: "gearshape.2"
        case .xcode: "hammer"
        case .android: "candybarphone"
        case .ai: "sparkles"
        case .apps: "square.stack.3d.up"
        case .browsers: "globe"
        case .system: "gearshape"
        case .orphans: "questionmark.folder"
        case .applications: "app.badge"
        case .unrecognized: "questionmark.circle"
        }
    }

    /// Informational categories never offer removal.
    public var isInformational: Bool { self == .applications || self == .unrecognized }
}

/// What happens when the user confirms removal of an item.
public enum CleanAction: Codable, Sendable, Hashable {
    /// Move paths to the Trash (reversible).
    case trash
    /// Remove paths immediately, bypassing the Trash.
    case permanentDelete
    /// Run an allow-listed command (always irreversible).
    case command(argv: [String])

    public var isPermanent: Bool {
        switch self {
        case .trash: false
        case .permanentDelete, .command: true
        }
    }

    private enum CodingKeys: String, CodingKey { case type, argv }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "trash": self = .trash
        case "permanentDelete": self = .permanentDelete
        case "command": self = .command(argv: try c.decode([String].self, forKey: .argv))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown action \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash: try c.encode("trash", forKey: .type)
        case .permanentDelete: try c.encode("permanentDelete", forKey: .type)
        case .command(let argv):
            try c.encode("command", forKey: .type)
            try c.encode(argv, forKey: .argv)
        }
    }
}

/// A found location, or a group of them, with what it is and how it can be removed.
public struct ScanItem: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var ruleID: String?
    public var category: Category
    public var title: String
    public var app: String?
    public var description: String
    public var regeneration: String?
    public var safety: Safety
    public var sizeBytes: Int64
    public var lastModified: Date?
    public var paths: [String]
    public var action: CleanAction?
    /// Apps that own the data; with `requiresAppClosed`, removal waits until they are closed.
    public var ownerBundleIDs: [String]
    public var requiresAppClosed: Bool
    /// Default age threshold from the rule; the user may override or disable it.
    public var defaultAgeDays: Int?
    public var note: String?
    public var children: [ScanItem]
    /// Snapshot revalidated before a Rust build folder is removed.
    public var rustArtifact: RustArtifact?
    /// Size change since an earlier scan, when history is available.
    public var growth: DiskGrowth?

    public init(
        id: String,
        ruleID: String? = nil,
        category: Category,
        title: String,
        app: String? = nil,
        description: String,
        regeneration: String? = nil,
        safety: Safety,
        sizeBytes: Int64 = 0,
        lastModified: Date? = nil,
        paths: [String] = [],
        action: CleanAction? = nil,
        ownerBundleIDs: [String] = [],
        requiresAppClosed: Bool = false,
        defaultAgeDays: Int? = nil,
        note: String? = nil,
        children: [ScanItem] = []
    ) {
        self.id = id
        self.ruleID = ruleID
        self.category = category
        self.title = title
        self.app = app
        self.description = description
        self.regeneration = regeneration
        self.safety = safety
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.paths = paths
        self.action = action
        self.ownerBundleIDs = ownerBundleIDs
        self.requiresAppClosed = requiresAppClosed
        self.defaultAgeDays = defaultAgeDays
        self.note = note
        self.children = children
    }

    public var isGroup: Bool { !children.isEmpty }

    /// Only leaves with an action, outside user data and informational categories, can be selected.
    public var isSelectable: Bool {
        !isGroup && action != nil && safety != .userData && !category.isInformational
    }

    public var leaves: [ScanItem] { isGroup ? children.flatMap(\.leaves) : [self] }
}

public extension Int64 {
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 KB" rather than "Zero KB", which reads badly inside a sentence.
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: self)
    }
}
