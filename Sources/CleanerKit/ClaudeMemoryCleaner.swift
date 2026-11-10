import Foundation
import CryptoKit
import Darwin
import ScannerKit

public struct ClaudeMemoryReport: Sendable {
    public var removedRecords = 0
    public var trashedFiles = 0
    public var indexRebuilt = false
    /// Folder holding the SQLite backup and the previous Chroma index.
    public var backup: URL?
    /// Localized reason the maintenance stopped or finished only partially.
    public var failure: String?
    /// The data is synced to the cloud, so deletions propagate to other devices.
    public var cloudNotice = false
    public var succeeded: Bool { failure == nil }
}

/// Deletes selected claude-mem memories and rebuilds its derived indexes (SQLite FTS and Chroma).
///
/// Synced records are deleted through the worker's API so claude-mem can propagate the deletion;
/// the worker is then stopped and the indexes are rebuilt from the remaining data. A backup of the
/// database is taken before any change.
public actor ClaudeMemoryCleaner {
    private let runtime: any ClaudeMemoryRuntime
    private let files: any FileOperations
    private let log: any OperationLogging
    private let backupRoot: URL
    private var busy = false

    /// True while any GRUZ process holds the maintenance lock for this claude-mem data folder.
    public static func isMaintenanceActive(at location: ClaudeMemoryLocation) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GRUZ/ClaudeMemBackups")
        let key = SHA256.hash(data: Data(location.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(root.appendingPathComponent(".\(key).lock").path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return errno == EWOULDBLOCK }
        flock(descriptor, LOCK_UN)
        return false
    }

    public init(runtime: any ClaudeMemoryRuntime = LiveClaudeMemoryRuntime(), files: any FileOperations = SystemFileOperations(),
                log: any OperationLogging = FileOperationLog(), backupRoot: URL? = nil) {
        self.runtime = runtime
        self.files = files
        self.log = log
        self.backupRoot = backupRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GRUZ/ClaudeMemBackups")
    }

    /// Runs the maintenance confirmed for `preview`. With `rebuildOnly`, nothing is deleted and only
    /// the indexes are rebuilt, which also finishes a maintenance that was interrupted.
    public func execute(_ preview: ClaudeMemoryPreview, confirmedID: UUID, permanentConfirmed: Bool,
                        rebuildOnly: Bool = false,
                        progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> ClaudeMemoryReport {
        var report = ClaudeMemoryReport()
        guard !busy, preview.id == confirmedID, permanentConfirmed else {
            report.failure = String(localized: "The operation was not confirmed, or another cleanup is already running.", bundle: .cleanerKit)
            return report
        }
        busy = true
        defer { busy = false }
        let location = preview.location
        var stopped = false
        var worker: ClaudeMemoryWorker?
        var lockFD: Int32 = -1
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var failure: LocalizedMessage?
        do {
            await progress(String(localized: "Checking the worker and whether the preview is current…", bundle: .cleanerKit))
            try validatePaths(location)
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = SHA256.hash(data: Data(location.root.path.utf8)).map { String(format: "%02x", $0) }.joined()
            lockFD = open(backupRoot.appendingPathComponent(".\(key).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw LocalizedMessage("Another GRUZ instance is maintaining this database.")
            }
            let identity = try await runtime.worker(location: location)
            worker = identity
            if identity.running { try await runtime.checkIdle(location: location) }
            if !identity.running, !rebuildOnly {
                throw LocalizedMessage("Maintenance was interrupted. Choose “Rebuild Indexes” first.")
            }
            let current = try ClaudeMemoryReader(location: location).preview(filter: preview.filter)
            guard current.pendingMessages == 0 else {
                throw LocalizedMessage("The claude-mem queue holds \(current.pendingMessages) messages. Wait until it is empty.")
            }
            if !rebuildOnly {
                guard current.records == preview.records, current.files == preview.files else {
                    throw LocalizedMessage("The data changed since the preview. Refresh the list and confirm the new scope.")
                }
                guard preview.count > 0 else { throw LocalizedMessage("Nothing to remove in this scope.") }
            }
            if location.chromaEnabled || FileManager.default.fileExists(atPath: location.chroma.path) {
                await progress(String(localized: "Preparing the local indexing model (the first run may download dependencies)…", bundle: .cleanerKit))
                try await runtime.prepareIndex(location: location)
            }
            if identity.running { try await runtime.checkIdle(location: location) }
            let backup = backupRoot.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ClaudeMemoryDatabase(url: location.database).backup(to: backup.appendingPathComponent("claude-mem.db"))
            report.backup = backup
            report.cloudNotice = location.cloudConfigured
            try JSONEncoder().encode(identity).write(to: location.maintenanceMarker, options: .atomic)

            // Let claude-mem produce sync tombstones. Direct SQL would strand cloud replicas.
            var deletionFailure: LocalizedMessage?
            if !rebuildOnly {
                let synced = preview.records.filter { $0.kind.endpoint != nil }
                for (offset, record) in synced.enumerated() {
                    await progress(String(localized: "Removing memories: \(offset + 1) of \(synced.count)…", bundle: .cleanerKit))
                    do {
                        try await runtime.checkIdle(location: location)
                        guard try ClaudeMemoryReader(location: location).matches(record) else {
                            throw LocalizedMessage("A record changed since the preview. Refresh the scope before removing more.")
                        }
                        try await runtime.delete(record, location: location)
                        report.removedRecords += 1
                    } catch {
                        deletionFailure = LocalizedMessage("Removed only part of the data (\(report.removedRecords) records):").appending(LocalizedMessage(error))
                        break
                    }
                }
            }

            await progress(String(localized: "Stopping the worker while the indexes are rebuilt…", bundle: .cleanerKit))
            if identity.running {
                try await runtime.checkIdle(location: location)
                try await runtime.stop(location: location)
            }
            stopped = true
            try await runtime.checkStopped(location: location)
            if !rebuildOnly, deletionFailure == nil {
                let localRows = preview.records.filter { $0.kind == .toolUses }
                let localFilter = ClaudeMemoryFilter(cutoff: preview.filter.cutoff, dateRule: preview.filter.dateRule,
                                                    project: preview.filter.project, kinds: Set<ClaudeMemoryKind>([.toolUses, .logs, .observerSessions]).intersection(preview.filter.kinds))
                let remaining = try ClaudeMemoryReader(location: location).preview(filter: localFilter)
                guard remaining.records == localRows, remaining.files == preview.files else {
                    throw LocalizedMessage("Local files or the tool history changed. Preview again after the indexes are rebuilt.")
                }
                try ClaudeMemoryDatabase(url: location.database).removeLocalRecords(localRows)
                report.removedRecords += localRows.count
                for file in preview.files {
                    try files.moveToTrash(file.path)
                    report.trashedFiles += 1
                }
            }
            await progress(String(localized: "Rebuilding text indexes and compacting SQLite…", bundle: .cleanerKit))
            try await runtime.checkStopped(location: location)
            let fts = try ClaudeMemoryReader(location: location)
                .rows("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('observations_fts','session_summaries_fts','user_prompts_fts')")
                .compactMap { $0["name"] }
            try ClaudeMemoryDatabase(url: location.database).rebuildFTS(tables: fts)
            let integrity = try ClaudeMemoryReader(location: location).rows("PRAGMA integrity_check")
            guard integrity.count == 1, integrity.first?.values.first == "ok" else {
                throw LocalizedMessage("The SQLite integrity check failed. The database backup is kept.")
            }
            if location.chromaEnabled || FileManager.default.fileExists(atPath: location.chroma.path) {
                await progress(String(localized: "Rebuilding Chroma from the remaining data. This can take a few minutes…", bundle: .cleanerKit))
                var reusable: URL?
                if rebuildOnly {
                    let candidates = try FileManager.default.contentsOfDirectory(at: location.root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        .filter { candidate in
                            guard candidate.lastPathComponent.hasPrefix(".cleaner-chroma-"),
                                  let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                            return values.isDirectory == true && values.isSymbolicLink == false
                        }
                    for candidate in candidates {
                        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("cleaner-watermarks.json").path) else { continue }
                        await progress(String(localized: "Checking the index kept from the interrupted maintenance…", bundle: .cleanerKit))
                        if (try? await runtime.verifyIndex(location: location, destination: candidate)) != nil {
                            reusable = candidate
                            break
                        }
                    }
                }
                let staging = reusable ?? location.root.appendingPathComponent(".cleaner-chroma-\(UUID().uuidString)")
                if reusable == nil { try await runtime.rebuildIndex(location: location, destination: staging, progress: progress) }
                try await runtime.checkStopped(location: location)
                try installIndex(staging, location: location, backup: backup)
            }
            report.indexRebuilt = true
            await progress(String(localized: "Restarting claude-mem…", bundle: .cleanerKit))
            try await runtime.start(identity, location: location)
            stopped = false
            try FileManager.default.removeItem(at: location.maintenanceMarker)
            failure = deletionFailure
        } catch {
            failure = LocalizedMessage(error)
            // Never roll back cloud deletes or restore an index containing deleted records.
            let stillStopped = LocalizedMessage("The worker is still stopped. Use “Rebuild Indexes” to finish maintenance.")
            if stopped, report.indexRebuilt, let worker {
                do {
                    try await runtime.start(worker, location: location)
                    failure = failure?.appending(LocalizedMessage("The worker was restarted."))
                } catch {
                    failure = failure?.appending(stillStopped)
                }
            } else if stopped {
                failure = failure?.appending(stillStopped)
            }
        }
        report.failure = failure?.text
        let entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "action": "claude-mem-clean",
                                   "records": report.removedRecords, "files": report.trashedFiles, "reindexed": report.indexRebuilt,
                                   "backup": report.backup?.path ?? "", "status": failure?.english ?? "done"]
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
            log.record(String(decoding: data, as: UTF8.self))
        }
        return report
    }

    private func validatePaths(_ location: ClaudeMemoryLocation) throws {
        let fm = FileManager.default
        guard location.root.path != "/", location.root != fm.homeDirectoryForCurrentUser,
              fm.fileExists(atPath: location.database.path) else { throw LocalizedMessage("The data location is unsafe or does not exist.") }
        for url in [location.database, location.chroma, location.syncState, location.maintenanceMarker] {
            guard url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL else {
                throw LocalizedMessage("Cleaning does not support symbolic links for the database and index files.")
            }
        }
    }

    private func installIndex(_ staging: URL, location: ClaudeMemoryLocation, backup: URL) throws {
        let fm = FileManager.default
        let marks = staging.appendingPathComponent("cleaner-watermarks.json")
        let state = try Data(contentsOf: marks)
        guard (try JSONSerialization.jsonObject(with: state)) is [String: Any],
              fm.fileExists(atPath: staging.appendingPathComponent("chroma.sqlite3").path) else {
            throw LocalizedMessage("The new index is incomplete.")
        }
        let old = backup.appendingPathComponent("chroma")
        if fm.fileExists(atPath: location.chroma.path) { try fm.moveItem(at: location.chroma, to: old) }
        if fm.fileExists(atPath: location.syncState.path) {
            try fm.copyItem(at: location.syncState, to: backup.appendingPathComponent("chroma-sync-state.json"))
        }
        try fm.moveItem(at: staging, to: location.chroma)
        try state.write(to: location.syncState, options: .atomic)
        try fm.removeItem(at: location.chroma.appendingPathComponent("cleaner-watermarks.json"))
        // The old index remains in the recovery folder, explicitly listed in the result.
    }
}
