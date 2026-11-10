import Foundation
import ScannerKit
import SQLite3

/// Write access is confined to CleanerKit and used only by a confirmed maintenance operation.
final class ClaudeMemoryDatabase {
    private var db: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            db = nil
            throw LocalizedMessage("Cannot open the database for maintenance.")
        }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw LocalizedMessage(verbatim: "SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func backup(to url: URL) throws {
        var target: OpaquePointer?
        guard sqlite3_open_v2(url.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let target { sqlite3_close(target) }
            throw LocalizedMessage("Cannot create a backup of the database.")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else {
            throw LocalizedMessage("Cannot start a consistent SQLite backup.")
        }
        let status = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            throw LocalizedMessage("The SQLite backup did not complete. No data was removed.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func removeLocalRecords(_ records: [ClaudeMemoryRecord]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for row in records {
                // Synced kinds must go through the worker API; tool history is local only.
                guard row.kind == .toolUses, !row.isRemote, row.rowID > 0 else {
                    throw LocalizedMessage("Direct deletion is allowed only for the local tool history.")
                }
                try execute("DELETE FROM tool_uses WHERE id = \(row.rowID)")
                guard sqlite3_changes(db) == 1 else { throw LocalizedMessage("The tool history changed. Refresh the preview.") }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rebuildFTS(tables: [String]) throws {
        // Table names are interpolated into SQL, so only the known FTS tables are accepted.
        let allowed = Set(["observations_fts", "session_summaries_fts", "user_prompts_fts"])
        try execute("BEGIN IMMEDIATE")
        do {
            for table in tables {
                guard allowed.contains(table) else { throw LocalizedMessage("Unrecognized FTS index.") }
                try execute("INSERT INTO \(table)(\(table)) VALUES('rebuild')")
                try execute("INSERT INTO \(table)(\(table), rank) VALUES('integrity-check', 1)")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
        try execute("PRAGMA optimize")
    }
}
