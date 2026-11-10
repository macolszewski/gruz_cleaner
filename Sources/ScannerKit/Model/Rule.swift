import Foundation

/// A catalog entry describing one known location and what it contains.
public struct Rule: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Paths (globs allowed). One match gives a single item, several give a group.
        case path
        /// Children of `paths` matching `versionPattern`; all but the newest version per name are offered.
        case versions
    }

    public enum ChildTitle: String, Codable, Sendable {
        case name
        case parentAndName
        case derivedData
        case huggingFace
    }

    public var id: String
    public var category: Category
    public var app: String?
    public var title: String
    public var description: String
    public var regeneration: String?
    public var safety: Safety
    public var kind: Kind
    public var paths: [String]
    public var action: CleanAction?
    public var requiresAppClosed: Bool
    public var ownerBundleIDs: [String]
    public var defaultAgeDays: Int?
    public var childTitle: ChildTitle
    public var excludeNames: [String]
    public var group: Bool
    public var versionPattern: String?
    public var note: String?

    private enum CodingKeys: String, CodingKey {
        case id, category, app, title, description, regeneration, safety, kind, paths, action
        case requiresAppClosed, ownerBundleIDs, defaultAgeDays, childTitle, excludeNames, group, versionPattern, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(Category.self, forKey: .category)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        regeneration = try c.decodeIfPresent(String.self, forKey: .regeneration)
        safety = try c.decode(Safety.self, forKey: .safety)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .path
        paths = try c.decode([String].self, forKey: .paths)
        action = try c.decodeIfPresent(CleanAction.self, forKey: .action)
        requiresAppClosed = try c.decodeIfPresent(Bool.self, forKey: .requiresAppClosed) ?? false
        ownerBundleIDs = try c.decodeIfPresent([String].self, forKey: .ownerBundleIDs) ?? []
        defaultAgeDays = try c.decodeIfPresent(Int.self, forKey: .defaultAgeDays)
        childTitle = try c.decodeIfPresent(ChildTitle.self, forKey: .childTitle) ?? .name
        excludeNames = try c.decodeIfPresent([String].self, forKey: .excludeNames) ?? []
        group = try c.decodeIfPresent(Bool.self, forKey: .group) ?? false
        versionPattern = try c.decodeIfPresent(String.self, forKey: .versionPattern)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// Describes a regenerable directory found inside project folders (e.g. `node_modules`).
public struct ArtifactDefinition: Codable, Sendable, Identifiable {
    public var id: String
    public var dirNames: [String]
    /// At least one sibling matching one of these globs must exist (empty means no requirement).
    public var siblingsAny: [String]
    /// At least one entry inside the directory must match (empty means no requirement).
    public var insideAny: [String]
    /// No entry inside the directory may match (source files that show the folder is not build output).
    public var insideNone: [String]
    /// Required name of the parent directory.
    public var parentName: String?
    public var title: String
    public var description: String
    public var regeneration: String?
    public var safety: Safety
    public var action: CleanAction
    /// The found directory is a container; each of its children becomes an item (agent worktrees).
    public var childrenAreItems: Bool
    public var gitStatusCheck: Bool

    private enum CodingKeys: String, CodingKey {
        case id, dirNames, siblingsAny, insideAny, insideNone, parentName, title, description, regeneration, safety, action
        case childrenAreItems, gitStatusCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        dirNames = try c.decode([String].self, forKey: .dirNames)
        siblingsAny = try c.decodeIfPresent([String].self, forKey: .siblingsAny) ?? []
        insideAny = try c.decodeIfPresent([String].self, forKey: .insideAny) ?? []
        insideNone = try c.decodeIfPresent([String].self, forKey: .insideNone) ?? []
        parentName = try c.decodeIfPresent(String.self, forKey: .parentName)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        regeneration = try c.decodeIfPresent(String.self, forKey: .regeneration)
        safety = try c.decode(Safety.self, forKey: .safety)
        action = try c.decodeIfPresent(CleanAction.self, forKey: .action) ?? .trash
        childrenAreItems = try c.decodeIfPresent(Bool.self, forKey: .childrenAreItems) ?? false
        gitStatusCheck = try c.decodeIfPresent(Bool.self, forKey: .gitStatusCheck) ?? false
    }
}

/// Translated texts of one rule or artifact, read from `Rules/Localizations/<language>.json`.
///
/// Rule files are written in English; a translation file maps rule and artifact ids to texts in
/// another language. Fields that are absent keep the English value.
public struct RuleTranslation: Codable, Sendable, Equatable {
    public var app: String?
    public var title: String?
    public var description: String?
    public var regeneration: String?
    public var note: String?
}

public struct OrphanConfig: Codable, Sendable {
    /// Library subfolders searched for leftovers of uninstalled apps.
    public var searchDirs: [String]
    /// Identifiers that are not apps (tools, system services) and must never be reported as orphans.
    public var ignoredIDs: [String]
    /// Folder identifier -> bundle identifier of the app that owns it, when they differ.
    public var aliases: [String: String]
    public var minimumSizeMB: Int
}

public struct RuleCatalog: Sendable {
    public var rules: [Rule]
    public var artifacts: [ArtifactDefinition]
    public var orphans: OrphanConfig

    public init(rules: [Rule], artifacts: [ArtifactDefinition], orphans: OrphanConfig) {
        self.rules = rules
        self.artifacts = artifacts
        self.orphans = orphans
    }

    public enum LoadError: Error, CustomStringConvertible {
        case notFound
        case duplicateID(String)
        case invalid(String, String)

        public var description: String {
            switch self {
            case .notFound: "Rules directory not found"
            case .duplicateID(let id): "Duplicate rule id \(id)"
            case .invalid(let id, let why): "Invalid rule \(id): \(why)"
            }
        }
    }

    /// Loads `rules-*.json`, `artifacts.json` and `orphans.json` from a directory, in file name order,
    /// then applies the translations for `language` when the directory provides them.
    public static func load(from directory: URL, language: String = Localization.current) throws -> RuleCatalog {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        let decoder = JSONDecoder()
        var rules: [Rule] = []
        for file in files where file.hasPrefix("rules-") && file.hasSuffix(".json") {
            let data = try Data(contentsOf: directory.appendingPathComponent(file))
            rules += try decoder.decode([Rule].self, from: data)
        }
        let artifacts = try decoder.decode(
            [ArtifactDefinition].self,
            from: Data(contentsOf: directory.appendingPathComponent("artifacts.json"))
        )
        let orphans = try decoder.decode(
            OrphanConfig.self,
            from: Data(contentsOf: directory.appendingPathComponent("orphans.json"))
        )
        var catalog = RuleCatalog(rules: rules, artifacts: artifacts, orphans: orphans)
        try catalog.validate()
        if language != Localization.developmentLanguage,
           let translations = try translations(in: directory, language: language) {
            catalog.apply(translations)
        }
        return catalog
    }

    /// The translation table for `language`, or nil when the catalog has none.
    public static func translations(in directory: URL, language: String) throws -> [String: RuleTranslation]? {
        let url = directory.appendingPathComponent("Localizations/\(language).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([String: RuleTranslation].self, from: Data(contentsOf: url))
    }

    /// Replaces user-facing texts with their translations, keyed by rule or artifact id.
    public mutating func apply(_ translations: [String: RuleTranslation]) {
        for index in rules.indices {
            guard let text = translations[rules[index].id] else { continue }
            rules[index].app = text.app ?? rules[index].app
            rules[index].title = text.title ?? rules[index].title
            rules[index].description = text.description ?? rules[index].description
            rules[index].regeneration = text.regeneration ?? rules[index].regeneration
            rules[index].note = text.note ?? rules[index].note
        }
        for index in artifacts.indices {
            guard let text = translations[artifacts[index].id] else { continue }
            artifacts[index].title = text.title ?? artifacts[index].title
            artifacts[index].description = text.description ?? artifacts[index].description
            artifacts[index].regeneration = text.regeneration ?? artifacts[index].regeneration
        }
    }

    /// The directory of the rule catalog shipped with ScannerKit.
    public static var builtInDirectory: URL? { Bundle.scannerKit.resourceURL?.appendingPathComponent("Rules") }

    /// The rule catalog shipped with ScannerKit, translated to the current language.
    public static func builtIn(language: String = Localization.current) throws -> RuleCatalog {
        guard let url = builtInDirectory else { throw LoadError.notFound }
        return try load(from: url, language: language)
    }

    public func validate() throws {
        var seen = Set<String>()
        for rule in rules {
            guard seen.insert(rule.id).inserted else { throw LoadError.duplicateID(rule.id) }
            if rule.paths.isEmpty { throw LoadError.invalid(rule.id, "no paths") }
            if rule.safety == .userData, rule.action != nil {
                throw LoadError.invalid(rule.id, "user data must not have an action")
            }
            if rule.kind == .versions, rule.versionPattern == nil {
                throw LoadError.invalid(rule.id, "versions rule needs versionPattern")
            }
            if case .command(let argv)? = rule.action, !CommandPolicy.isAllowedCleanCommand(argv) {
                throw LoadError.invalid(rule.id, "command not allow-listed: \(argv.joined(separator: " "))")
            }
        }
        for artifact in artifacts {
            guard seen.insert(artifact.id).inserted else { throw LoadError.duplicateID(artifact.id) }
            if case .command(let argv) = artifact.action, !CommandPolicy.isAllowedCleanCommand(argv) {
                throw LoadError.invalid(artifact.id, "command not allow-listed: \(argv.joined(separator: " "))")
            }
        }
    }

    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }
}
