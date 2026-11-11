import Foundation

/// A kind of claude-mem data: a database table or a folder of files.
public enum ClaudeMemoryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case observations, summaries, prompts, toolUses, logs, observerSessions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .observations: String(localized: "Observations", bundle: .scannerKit)
        case .summaries: String(localized: "Session summaries", bundle: .scannerKit)
        case .prompts: String(localized: "User prompts", bundle: .scannerKit)
        case .toolUses: String(localized: "Tool call history", bundle: .scannerKit)
        case .logs: String(localized: "Diagnostic logs", bundle: .scannerKit)
        case .observerSessions: String(localized: "Observer session files", bundle: .scannerKit)
        }
    }
    public var table: String? {
        switch self {
        case .observations: "observations"
        case .summaries: "session_summaries"
        case .prompts: "user_prompts"
        case .toolUses: "tool_uses"
        default: nil
        }
    }
    public var endpoint: String? {
        switch self {
        case .observations: "observation"
        case .summaries: "summary"
        case .prompts: "prompt"
        default: nil
        }
    }
    public var directory: String? {
        switch self {
        case .logs: "logs"
        case .observerSessions: "observer-sessions"
        default: nil
        }
    }
}

/// Whether a filter selects data older than the cutoff or from the cutoff on.
public enum ClaudeMemoryDateRule: String, CaseIterable, Codable, Sendable {
    case before, since
    public var title: String { self == .before ? String(localized: "Older than", bundle: .scannerKit) : String(localized: "Since (inclusive)", bundle: .scannerKit) }
    public func includes(_ date: Date, cutoff: Date) -> Bool {
        self == .before ? date < cutoff : date >= cutoff
    }
}

public struct ClaudeMemoryFilter: Equatable, Sendable {
    public var cutoff: Date
    public var dateRule: ClaudeMemoryDateRule
    public var project: String?
    public var kinds: Set<ClaudeMemoryKind>
    public init(cutoff: Date, dateRule: ClaudeMemoryDateRule = .before, project: String? = nil,
                kinds: Set<ClaudeMemoryKind> = [.observations, .summaries, .prompts, .toolUses]) {
        self.cutoff = cutoff
        self.dateRule = dateRule
        self.project = project
        self.kinds = kinds
    }
}

public struct ClaudeMemoryRecord: Identifiable, Equatable, Sendable {
    public let kind: ClaudeMemoryKind
    public let rowID: Int64
    public let project: String
    public let date: Date
    /// Hash of the whole row; removal proceeds only if the row still matches it.
    public let fingerprint: String
    public let isRemote: Bool
    public var id: String { "\(kind.rawValue):\(rowID)" }
}

public struct ClaudeMemoryFile: Identifiable, Equatable, Sendable {
    public let kind: ClaudeMemoryKind
    public let path: String
    public let bytes: Int64
    public let modified: Date
    public var id: String { path }
}

public struct ClaudeMemoryPreview: Sendable {
    public let id: UUID
    public let location: ClaudeMemoryLocation
    public let filter: ClaudeMemoryFilter
    public let records: [ClaudeMemoryRecord]
    public let files: [ClaudeMemoryFile]
    public let projects: [String]
    public let databaseBytes: Int64
    public let indexBytes: Int64
    public let pendingMessages: Int64
    public let excludedRemoteRecords: Int
    public let createdAt: Date
    public var count: Int { records.count + files.count }
    public func count(for kind: ClaudeMemoryKind) -> Int {
        records.filter { $0.kind == kind }.count + files.filter { $0.kind == kind }.count
    }
}

/// Where claude-mem keeps its data and how it is configured (`settings.json` and environment).
public struct ClaudeMemoryLocation: Equatable, Sendable {
    public let root: URL
    public let port: Int
    public let chromaEnabled: Bool
    public let chromaMode: String
    public let embeddingFunction: String
    public let cloudConfigured: Bool
    /// Why GRUZ cannot manage this worker safely (it is controlled from outside or not reachable on
    /// loopback), or nil. Maintenance is refused while it is set.
    public let unsupportedSetup: String?
    public var database: URL { root.appendingPathComponent("claude-mem.db") }
    public var chroma: URL { root.appendingPathComponent("chroma") }
    public var syncState: URL { root.appendingPathComponent("chroma-sync-state.json") }
    public var maintenanceMarker: URL { root.appendingPathComponent(".cleaner-maintenance.json") }
    /// Written by the claude-mem auto-updater (15.14+), which stops and restarts the worker.
    public var autoUpdateState: URL { root.appendingPathComponent("auto-update-state.json") }

    /// claude-mem's default port: 37700 plus the last two digits of the user id (all releases from 13.28).
    public static var defaultPort: Int { 37700 + Int(getuid() % 100) }

    public init(root: URL, port: Int = ClaudeMemoryLocation.defaultPort, chromaEnabled: Bool = true, chromaMode: String = "local",
                embeddingFunction: String = "default", cloudConfigured: Bool = false, unsupportedSetup: String? = nil) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.port = port
        self.chromaEnabled = chromaEnabled
        self.chromaMode = chromaMode
        self.embeddingFunction = embeddingFunction
        self.cloudConfigured = cloudConfigured
        self.unsupportedSetup = unsupportedSetup
    }

    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func settings(_ root: URL) throws -> [String: Any] {
            let file = root.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
            // claude-mem reads the nested `env` object only when it holds claude-mem keys.
            if let nested = raw["env"] as? [String: Any], nested.keys.contains(where: { $0.hasPrefix("CLAUDE_MEM_") }) { return nested }
            return raw
        }
        func expanded(_ path: String) -> URL {
            URL(fileURLWithPath: path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst() : path)
        }
        let fallback = home.appendingPathComponent(".claude-mem")
        let defaults = try settings(fallback)
        let path = environment["CLAUDE_MEM_DATA_DIR"] ?? defaults["CLAUDE_MEM_DATA_DIR"] as? String
        let root = path.flatMap { $0.isEmpty ? nil : expanded($0) } ?? fallback
        let config = try settings(root)
        func value(_ key: String) -> String? { environment[key] ?? config[key].map(settingText) }
        let configuredPort = value("CLAUDE_MEM_WORKER_PORT")?.trimmingCharacters(in: .whitespaces) ?? ""
        let port = configuredPort.isEmpty ? defaultPort : Int(configuredPort) ?? 0
        guard (1...65535).contains(port) else { throw ClaudeMemoryError.message(String(localized: "Invalid claude-mem port.", bundle: .scannerKit)) }
        return Self(root: root, port: port,
                    chromaEnabled: value("CLAUDE_MEM_CHROMA_ENABLED") != "false",
                    chromaMode: value("CLAUDE_MEM_CHROMA_MODE") ?? "local",
                    embeddingFunction: value("CLAUDE_MEM_CHROMA_EMBEDDING_FUNCTION") ?? "default",
                    cloudConfigured: ["CLAUDE_MEM_CLOUD_SYNC_TOKEN", "CLAUDE_MEM_CLOUD_SYNC_USER_ID", "CLAUDE_MEM_CLOUD_SYNC_HUB_URL"]
                        .allSatisfy { !(value($0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                    unsupportedSetup: unsupportedSetup(value))
    }

    /// A settings value as claude-mem reads it (JavaScript `String()`): JSON `true` is "true", not "1".
    static func settingText(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return String(describing: value)
    }

    /// Settings under which another component owns the worker, so stopping and restarting it from GRUZ
    /// would race with that component or not reach the worker at all.
    static func unsupportedSetup(_ value: (String) -> String?) -> String? {
        func setting(_ key: String) -> String { (value(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if setting("CLAUDE_MEM_WORKER_AUTOSTART") == "false" {
            return String(localized: "The claude-mem worker is managed outside claude-mem (CLAUDE_MEM_WORKER_AUTOSTART=false), so GRUZ cannot stop and restart it safely.", bundle: .scannerKit)
        }
        if !setting("CLAUDE_MEM_WORKER_URL").isEmpty {
            return String(localized: "claude-mem sends memory to a remote worker (CLAUDE_MEM_WORKER_URL). Maintain the data on that machine.", bundle: .scannerKit)
        }
        if ["server", "server-beta"].contains(setting("CLAUDE_MEM_RUNTIME")) {
            return String(localized: "claude-mem runs in server mode (CLAUDE_MEM_RUNTIME), which keeps memory outside this database.", bundle: .scannerKit)
        }
        if setting("CLAUDE_MEM_WORK_VIEW_SHARED_STATE") == "true" {
            return String(localized: "With CLAUDE_MEM_WORK_VIEW_SHARED_STATE=true another claude-mem process writes to the database while the worker is stopped.", bundle: .scannerKit)
        }
        // GRUZ talks to 127.0.0.1; a worker bound to ::1 (or to localhost resolved to ::1) would not answer there.
        if !["", "127.0.0.1", "0.0.0.0"].contains(setting("CLAUDE_MEM_WORKER_HOST")) {
            return String(localized: "The claude-mem worker does not listen on 127.0.0.1 (CLAUDE_MEM_WORKER_HOST), where GRUZ connects to it.", bundle: .scannerKit)
        }
        return nil
    }
}

public enum ClaudeMemoryError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
