import CryptoKit
import Foundation
import SQLite3

/// Read-only access to the claude-mem database. Never creates or modifies it, even when the file is missing.
public final class ClaudeMemoryReader {
    /// Project value of prompts whose session has no project. It is part of the query and of record
    /// fingerprints, so it is a fixed identifier; the app shows a translated label for it.
    public static let noProject = "(no project)"

    private var db: OpaquePointer?
    public let location: ClaudeMemoryLocation

    public init(location: ClaudeMemoryLocation) throws {
        self.location = location
        guard (try? location.database.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              sqlite3_open_v2(location.database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw ClaudeMemoryError.message(String(localized: "Cannot read the claude-mem database: \(location.database.path)", bundle: .scannerKit))
        }
        sqlite3_busy_timeout(db, 3000)
        let tables = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
        guard Set(["observations", "session_summaries", "user_prompts", "sdk_sessions", "pending_messages"]).isSubset(of: tables) else {
            throw ClaudeMemoryError.message(String(localized: "Unrecognized claude-mem database schema. Cleaning is blocked.", bundle: .scannerKit))
        }
    }

    deinit { sqlite3_close(db) }

    public func rows(_ sql: String, parameters: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw ClaudeMemoryError.message(String(localized: "The scanner allows read-only SQL only.", bundle: .scannerKit))
        }
        for (offset, value) in parameters.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw failure() }
        }
        var result: [[String: String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { continue }
                let key = String(cString: sqlite3_column_name(statement, column))
                if let text = sqlite3_column_text(statement, column) { row[key] = String(cString: text) }
            }
            result.append(row)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func preview(filter: ClaudeMemoryFilter) throws -> ClaudeMemoryPreview {
        guard filter.cutoff.timeIntervalSince1970.isFinite else { throw ClaudeMemoryError.message(String(localized: "Invalid date.", bundle: .scannerKit)) }
        var records: [ClaudeMemoryRecord] = []
        var remoteCount = 0
        let tables = Set(try rows("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] })
        let comparison = filter.dateRule == .before ? "<" : ">="
        for kind in ClaudeMemoryKind.allCases where filter.kinds.contains(kind) {
            guard let table = kind.table, tables.contains(table) else { continue }
            let project = kind == .prompts ? "COALESCE(s.project, '\(Self.noProject)')" : "t.project"
            let join = kind == .prompts ? "LEFT JOIN sdk_sessions s ON s.id = t.session_db_id" : ""
            let projectClause = filter.project == nil ? "" : " AND \(project) = ?"
            let sql = "SELECT t.*, \(project) AS cleaner_project FROM \(table) t \(join) WHERE t.created_at_epoch \(comparison) ?\(projectClause) ORDER BY t.id"
            var parameters = [String(Int64(filter.cutoff.timeIntervalSince1970 * 1000))]
            if let project = filter.project { parameters.append(project) }
            for row in try rows(sql, parameters: parameters) {
                guard let id = row["id"].flatMap(Int64.init), let epoch = row["created_at_epoch"].flatMap(Double.init) else {
                    throw ClaudeMemoryError.message(String(localized: "A record has an invalid identifier or date.", bundle: .scannerKit))
                }
                if row["origin_device_id"] != nil { remoteCount += 1; continue }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                records.append(ClaudeMemoryRecord(kind: kind, rowID: id, project: row["cleaner_project"] ?? "",
                                                 date: Date(timeIntervalSince1970: epoch / 1000),
                                                 fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                                 isRemote: false))
            }
        }
        var files: [ClaudeMemoryFile] = []
        if filter.project == nil {
            for kind in ClaudeMemoryKind.allCases where filter.kinds.contains(kind) {
                guard let directory = kind.directory else { continue }
                let root = location.root.appendingPathComponent(directory)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                guard root.resolvingSymlinksInPath().path == root.path else { continue }
                let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
                var traversalError: Error?
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, error in
                    traversalError = error
                    return false
                })
                while let file = enumerator?.nextObject() as? URL {
                    let values = try file.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
                    guard values.isRegularFile == true, let date = values.contentModificationDate,
                          filter.dateRule.includes(date, cutoff: filter.cutoff) else { continue }
                    files.append(ClaudeMemoryFile(kind: kind, path: file.standardizedFileURL.path, bytes: Int64(values.fileSize ?? 0), modified: date))
                }
                if let traversalError { throw traversalError }
            }
        }
        let projects = try rows("SELECT project FROM observations UNION SELECT project FROM session_summaries UNION SELECT project FROM sdk_sessions ORDER BY project")
            .compactMap { $0["project"] }
        let pending = try rows("SELECT count(*) AS n FROM pending_messages").first?["n"].flatMap(Int64.init) ?? 0
        return ClaudeMemoryPreview(id: UUID(), location: location, filter: filter, records: records, files: files.sorted { $0.path < $1.path },
                                  projects: projects, databaseBytes: Self.diskBytes(location.database) + Self.diskBytes(URL(fileURLWithPath: location.database.path + "-wal")),
                                  indexBytes: Self.diskBytes(location.chroma), pendingMessages: pending,
                                  excludedRemoteRecords: remoteCount, createdAt: Date())
    }

    public func matches(_ record: ClaudeMemoryRecord) throws -> Bool {
        guard let table = record.kind.table else { return false }
        let project = record.kind == .prompts ? "COALESCE(s.project, '\(Self.noProject)')" : "t.project"
        let join = record.kind == .prompts ? "LEFT JOIN sdk_sessions s ON s.id = t.session_db_id" : ""
        guard let row = try rows("SELECT t.*, \(project) AS cleaner_project FROM \(table) t \(join) WHERE t.id = ?",
                                 parameters: [String(record.rowID)]).first else { return false }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == record.fingerprint
    }

    public static func diskBytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var size: Int64 = 0
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return size
    }

    private func failure() -> ClaudeMemoryError {
        .message(String(localized: "SQLite read error: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "no connection", bundle: .scannerKit))", bundle: .scannerKit))
    }
}
