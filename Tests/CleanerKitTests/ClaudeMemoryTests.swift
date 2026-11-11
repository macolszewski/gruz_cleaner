import Foundation
import ScannerKit
import SQLite3
import Testing
@testable import CleanerKit

final class MemoryFixture {
    let root: URL
    let backups: URL
    var location: ClaudeMemoryLocation { ClaudeMemoryLocation(root: root) }
    let boundary = Date(timeIntervalSince1970: 2000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-memory-\(UUID().uuidString)").resolvingSymlinksInPath()
        backups = root.deletingLastPathComponent().appendingPathComponent("cleaner-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(location.database.path, &db) == SQLITE_OK else { throw ClaudeMemoryError.message("fixture open") }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE sdk_sessions(id INTEGER PRIMARY KEY, memory_session_id TEXT UNIQUE, content_session_id TEXT, project TEXT, platform_source TEXT);
        CREATE TABLE observations(id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT, title TEXT, narrative TEXT, created_at_epoch INTEGER, origin_device_id TEXT);
        CREATE TABLE session_summaries(id INTEGER PRIMARY KEY, memory_session_id TEXT, project TEXT, request TEXT, created_at_epoch INTEGER, origin_device_id TEXT);
        CREATE TABLE user_prompts(id INTEGER PRIMARY KEY, session_db_id INTEGER, content_session_id TEXT, prompt_text TEXT, created_at_epoch INTEGER, origin_device_id TEXT);
        CREATE TABLE tool_uses(id INTEGER PRIMARY KEY, session_db_id INTEGER, project TEXT, created_at_epoch INTEGER);
        CREATE TABLE pending_messages(id INTEGER PRIMARY KEY, session_db_id INTEGER);
        CREATE VIRTUAL TABLE observations_fts USING fts5(title,narrative,content='observations',content_rowid='id');
        CREATE TRIGGER observations_ai AFTER INSERT ON observations BEGIN INSERT INTO observations_fts(rowid,title,narrative) VALUES(new.id,new.title,new.narrative); END;
        CREATE TRIGGER observations_ad AFTER DELETE ON observations BEGIN INSERT INTO observations_fts(observations_fts,rowid,title,narrative) VALUES('delete',old.id,old.title,old.narrative); END;
        INSERT INTO sdk_sessions VALUES(1,'m1','c1','alpha','claude'),(2,'m2','c2','beta','codex');
        INSERT INTO observations VALUES(1,'m1','alpha','oldneedle','old memory',1000000,NULL),(2,'m1','alpha','boundaryneedle','kept memory',2000000,NULL),(3,'m2','beta','otherneedle','other project',1000000,NULL),(4,'m1','alpha','remoteneedle','remote copy',1000000,'another-device');
        INSERT INTO session_summaries VALUES(1,'m1','alpha','old summary',1000000,NULL);
        INSERT INTO user_prompts VALUES(1,1,'c1','old prompt',1000000,NULL);
        INSERT INTO tool_uses VALUES(1,1,'alpha',1000000),(2,1,'alpha',3000000);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw ClaudeMemoryError.message(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: backups)
    }

    func preview(kinds: Set<ClaudeMemoryKind> = [.observations, .summaries, .prompts, .toolUses],
                 project: String? = "alpha", dateRule: ClaudeMemoryDateRule = .before) throws -> ClaudeMemoryPreview {
        try ClaudeMemoryReader(location: location).preview(filter: ClaudeMemoryFilter(cutoff: boundary, dateRule: dateRule, project: project, kinds: kinds))
    }

    func write(_ sql: String) throws { try ClaudeMemoryDatabase(url: location.database).execute(sql) }
    func count(_ table: String) throws -> Int { Int(try ClaudeMemoryReader(location: location).rows("SELECT count(*) AS n FROM \(table)").first?["n"] ?? "") ?? -1 }
}

actor MemoryRuntimeStub: ClaudeMemoryRuntime {
    var calls: [String] = []
    var idle = true
    var failIndex = false
    var failDeleteAt: Int?
    var deleteCalls = 0
    var running = true

    func setIdle(_ value: Bool) { idle = value }
    func setFailIndex(_ value: Bool) { failIndex = value }
    func setFailDeleteAt(_ value: Int) { failDeleteAt = value }
    func worker(location: ClaudeMemoryLocation) async throws -> ClaudeMemoryWorker {
        calls.append("worker")
        return ClaudeMemoryWorker(path: "/fixture/worker-service.cjs", version: "13.28.0", running: running)
    }
    func checkIdle(location: ClaudeMemoryLocation) async throws {
        if !idle { throw ClaudeMemoryError.message("active sessions") }
    }
    func prepareIndex(location: ClaudeMemoryLocation, worker: ClaudeMemoryWorker) async throws { calls.append("prepare") }
    func delete(_ record: ClaudeMemoryRecord, location: ClaudeMemoryLocation) async throws {
        deleteCalls += 1
        if failDeleteAt == deleteCalls { throw ClaudeMemoryError.message("cloud sync unavailable") }
        calls.append("delete:\(record.id)")
        try ClaudeMemoryDatabase(url: location.database).execute("DELETE FROM \(record.kind.table!) WHERE id=\(record.rowID)")
    }
    func stop(location: ClaudeMemoryLocation) async throws { calls.append("stop"); running = false }
    func checkStopped(location: ClaudeMemoryLocation) async throws {
        if running { throw ClaudeMemoryError.message("worker running") }
    }
    func rebuildIndex(location: ClaudeMemoryLocation, worker: ClaudeMemoryWorker, destination: URL, progress: @escaping @Sendable (String) async -> Void) async throws {
        calls.append("rebuild")
        if failIndex { throw ClaudeMemoryError.message("embedding failed") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: destination.appendingPathComponent("cleaner-watermarks.json"))
        try Data().write(to: destination.appendingPathComponent("chroma.sqlite3"))
    }
    func verifyIndex(location: ClaudeMemoryLocation, worker: ClaudeMemoryWorker, destination: URL) async throws { calls.append("verify") }
    func start(_ worker: ClaudeMemoryWorker, location: ClaudeMemoryLocation) async throws { calls.append("start"); running = true }
}

@Suite struct ClaudeMemoryTests {
    @Test func dateBoundaryProjectAndRemoteOwnership() throws {
        let fixture = try MemoryFixture()
        let before = try fixture.preview(kinds: [.observations, .prompts])
        #expect(before.records.map(\.id) == ["observations:1", "prompts:1"])
        #expect(before.excludedRemoteRecords == 1)
        let since = try fixture.preview(kinds: [.observations], dateRule: .since)
        #expect(since.records.map(\.rowID) == [2])
        #expect(try fixture.count("observations") == 4)
    }

    @Test func scanCannotWriteOrCreateDatabase() throws {
        let fixture = try MemoryFixture()
        let reader = try ClaudeMemoryReader(location: fixture.location)
        #expect(throws: (any Error).self) { try reader.rows("DELETE FROM observations") }
        let missing = ClaudeMemoryLocation(root: fixture.root.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try ClaudeMemoryReader(location: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.database.path))
    }

    @Test func fileFilterSkipsSymlinksAndProjectScopedLogs() throws {
        let fixture = try MemoryFixture()
        let logs = fixture.root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("old.log")
        try Data("log".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("outside"), withDestinationURL: fixture.root.deletingLastPathComponent())
        let selected = try fixture.preview(kinds: [.logs], project: nil).files
        #expect(selected.map(\.path) == [file.standardizedFileURL.path], "root=\(fixture.location.root.path), file=\(file.path), selected=\(selected)")
        #expect(try fixture.preview(kinds: [.logs]).files.isEmpty)
    }

    @Test func confirmationIsBoundToPreview() async throws {
        let fixture = try MemoryFixture()
        let runtime = MemoryRuntimeStub()
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let result = await cleaner.execute(preview, confirmedID: UUID(), permanentConfirmed: true)
        #expect(!result.succeeded)
        #expect(await runtime.calls.isEmpty)
        let second = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: false)
        #expect(!second.succeeded)
        #expect(try fixture.count("observations") == 4)
    }

    @Test func stalePreviewRefusesAllMutation() async throws {
        let fixture = try MemoryFixture()
        let preview = try fixture.preview()
        try fixture.write("UPDATE user_prompts SET prompt_text='changed' WHERE id=1")
        let runtime = MemoryRuntimeStub()
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(!result.succeeded)
        #expect(result.removedRecords == 0)
        #expect(result.backup == nil)
    }

    @Test func activeWorkerBlocksDeletion() async throws {
        let fixture = try MemoryFixture()
        let preview = try fixture.preview()
        let runtime = MemoryRuntimeStub()
        await runtime.setIdle(false)
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(!result.succeeded)
        #expect(try fixture.count("observations") == 4)
    }

    @Test func queueRowsLeftByAnEarlierVersionDoNotBlockAnIdleWorker() async throws {
        // The worker keeps its queue in memory and reports it as idle; the table row is a leftover it never reads.
        let fixture = try MemoryFixture()
        try fixture.write("INSERT INTO pending_messages VALUES(1,1)")
        let preview = try fixture.preview()
        #expect(preview.pendingMessages == 1)
        let cleaner = ClaudeMemoryCleaner(runtime: MemoryRuntimeStub(), log: FakeLog(), backupRoot: fixture.backups)
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(result.succeeded, "\(result.failure ?? "")")
        #expect(try fixture.count("pending_messages") == 1)
    }

    @Test func successfulCleanPreservesUnselectedDataAndRebuildsFTS() async throws {
        let fixture = try MemoryFixture()
        let runtime = MemoryRuntimeStub()
        let log = FakeLog()
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: log, backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(result.succeeded, "\(result.failure ?? "")")
        #expect(result.removedRecords == 4)
        #expect(result.indexRebuilt)
        #expect(try fixture.count("observations") == 3)
        #expect(try fixture.count("tool_uses") == 1)
        let reader = try ClaudeMemoryReader(location: fixture.location)
        #expect(try reader.rows("SELECT rowid FROM observations_fts WHERE observations_fts MATCH 'oldneedle'").isEmpty)
        #expect(try reader.rows("SELECT rowid FROM observations_fts WHERE observations_fts MATCH 'boundaryneedle'").count == 1)
        let backup = try #require(result.backup)
        #expect(try ClaudeMemoryReader(location: ClaudeMemoryLocation(root: backup)).rows("SELECT id FROM observations").count == 4)
        #expect(!FileManager.default.fileExists(atPath: fixture.location.maintenanceMarker.path))
        #expect(await runtime.calls.last == "start")
        #expect(log.lines.count == 1)
    }

    @Test func failedRebuildKeepsRecoveryMarkerAndCanBeResumed() async throws {
        let fixture = try MemoryFixture()
        let runtime = MemoryRuntimeStub()
        await runtime.setFailIndex(true)
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let failed = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(!failed.succeeded)
        #expect(!failed.indexRebuilt)
        #expect(FileManager.default.fileExists(atPath: fixture.location.maintenanceMarker.path))
        #expect(await runtime.running == false)
        await runtime.setFailIndex(false)
        let current = try fixture.preview()
        let recovered = await cleaner.execute(current, confirmedID: current.id, permanentConfirmed: true, rebuildOnly: true)
        #expect(recovered.succeeded, "\(recovered.failure ?? "")")
        #expect(recovered.removedRecords == 0)
        #expect(await runtime.running)
    }

    @Test func cloudFailureReportsPartialDeletionWithoutBypassingAPI() async throws {
        let fixture = try MemoryFixture()
        let runtime = MemoryRuntimeStub()
        await runtime.setFailDeleteAt(2)
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(!result.succeeded)
        #expect(result.removedRecords == 1)
        #expect(try fixture.count("session_summaries") == 1)
        #expect(try fixture.count("tool_uses") == 2)
        #expect(result.indexRebuilt)
        #expect(!FileManager.default.fileExists(atPath: fixture.location.maintenanceMarker.path))
    }

    @Test func completedIndexIsVerifiedAndReusedWithoutDeletingAgain() async throws {
        let fixture = try MemoryFixture()
        let staging = fixture.root.appendingPathComponent(".cleaner-chroma-completed")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appendingPathComponent("cleaner-watermarks.json"))
        try Data().write(to: staging.appendingPathComponent("chroma.sqlite3"))
        let runtime = MemoryRuntimeStub()
        try await runtime.stop(location: fixture.location)
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true, rebuildOnly: true)
        #expect(result.succeeded, "\(result.failure ?? "")")
        #expect(result.indexRebuilt)
        #expect(result.removedRecords == 0)
        #expect(try fixture.count("observations") == 4)
        #expect(try fixture.count("tool_uses") == 2)
        let calls = await runtime.calls
        #expect(calls.contains("verify"))
        #expect(!calls.contains("rebuild"))
        #expect(!calls.contains(where: { $0.hasPrefix("delete:") }))
        #expect(await runtime.running)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: fixture.location.chroma.appendingPathComponent("chroma.sqlite3").path))
    }

    @Test func nestedSettingsAndCustomDataDirectory() throws {
        let fixture = try MemoryFixture()
        let home = fixture.root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".claude-mem")
        let data = home.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"{"env":{"CLAUDE_MEM_DATA_DIR":"~/memory"}}"#.utf8).write(to: config.appendingPathComponent("settings.json"))
        try Data(#"{"CLAUDE_MEM_WORKER_PORT":"39999","CLAUDE_MEM_CHROMA_ENABLED":"false"}"#.utf8).write(to: data.appendingPathComponent("settings.json"))
        let result = try ClaudeMemoryLocation.discover(home: home, environment: [:])
        #expect(result.root.path == data.path)
        #expect(result.port == 39999)
        #expect(!result.chromaEnabled)
    }

    @Test func everyReleaseFrom13_28To15IsAccepted() {
        for version in ["13.28.0", "13.41.0", "14.0.1", "15.12.1", "15.17.0", "15.20.3", "15.2.0-beta.1"] {
            #expect(ClaudeMemoryWorker.isSupported(version), "\(version)")
        }
        for version in ["13.27.1", "12.4.3", "16.0.0", "development", "15.1", ""] {
            #expect(!ClaudeMemoryWorker.isSupported(version), "\(version)")
        }
        func layout(_ version: String) -> String { ClaudeMemoryWorker(path: "/w", version: version, running: true).indexLayout }
        #expect(layout("13.28.0") == "13.28")
        #expect(layout("13.29.0") == "13.29")
        #expect(layout("13.33.0") == "13.29")
        #expect(layout("13.34.0") == "13.34")
        #expect(layout("15.17.0") == "13.34")
    }

    @Test func defaultPortAndSettingsShapeFollowClaudeMem() throws {
        let fixture = try MemoryFixture()
        let home = fixture.root.appendingPathComponent("home")
        let data = home.appendingPathComponent(".claude-mem")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // A nested `env` without claude-mem keys is not the settings object.
        try Data(#"{"env":{"OTHER":"1"},"CLAUDE_MEM_CHROMA_ENABLED":"false"}"#.utf8).write(to: data.appendingPathComponent("settings.json"))
        let result = try ClaudeMemoryLocation.discover(home: home, environment: [:])
        #expect(result.port == 37700 + Int(getuid() % 100))
        #expect(!result.chromaEnabled)
        #expect(result.unsupportedSetup == nil)
        #expect(try ClaudeMemoryLocation.discover(home: home, environment: ["CLAUDE_MEM_WORKER_PORT": "38000"]).port == 38000)
    }

    @Test func externallyManagedWorkersAreRefused() async throws {
        let fixture = try MemoryFixture()
        let home = fixture.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-mem"), withIntermediateDirectories: true)
        for environment in [["CLAUDE_MEM_WORKER_AUTOSTART": "false"], ["CLAUDE_MEM_WORKER_URL": "http://10.0.0.2:37701"],
                            ["CLAUDE_MEM_RUNTIME": "server"], ["CLAUDE_MEM_WORK_VIEW_SHARED_STATE": "true"],
                            ["CLAUDE_MEM_WORKER_HOST": "192.168.1.5"]] {
            let location = try ClaudeMemoryLocation.discover(home: home, environment: environment)
            #expect(location.unsupportedSetup != nil, "\(environment)")
            await #expect(throws: (any Error).self) { try await LiveClaudeMemoryRuntime().worker(location: location) }
        }
        for environment in [["CLAUDE_MEM_RUNTIME": "worker", "CLAUDE_MEM_WORKER_HOST": "127.0.0.1"], ["CLAUDE_MEM_WORKER_HOST": "0.0.0.0"]] {
            #expect(try ClaudeMemoryLocation.discover(home: home, environment: environment).unsupportedSetup == nil)
        }
    }

    @Test func schemaWithoutQueueTableIsReadable() throws {
        let fixture = try MemoryFixture()
        try fixture.write("DROP TABLE pending_messages")
        let preview = try fixture.preview()
        #expect(preview.pendingMessages == 0)
        #expect(preview.records.count == 4)
    }

    @Test func counterUpdatesByTheWorkerDoNotInvalidateThePreview() async throws {
        let fixture = try MemoryFixture()
        try fixture.write("ALTER TABLE observations ADD COLUMN relevance_count INTEGER DEFAULT 0")
        let preview = try fixture.preview()
        try fixture.write("UPDATE observations SET relevance_count = relevance_count + 1")
        let record = try #require(preview.records.first { $0.kind == .observations })
        #expect(try ClaudeMemoryReader(location: fixture.location).matches(record))
        try fixture.write("UPDATE observations SET narrative = 'edited' WHERE id = \(record.rowID)")
        #expect(try !ClaudeMemoryReader(location: fixture.location).matches(record))
    }

    @Test func fullTextIndexesAreReadFromTheSchema() throws {
        let fixture = try MemoryFixture()
        try fixture.write("""
            CREATE VIRTUAL TABLE user_prompts_fts USING fts5(prompt_text, content='user_prompts', content_rowid='id');
            CREATE VIRTUAL TABLE tool_uses_fts USING fts5(tool_input, content='tool_uses', content_rowid='id');
            """)
        #expect(try ClaudeMemoryReader(location: fixture.location).fullTextIndexes() == ["observations_fts", "user_prompts_fts"])
        try fixture.write("CREATE VIRTUAL TABLE observations_search USING fts5(title, content = 'observations', content_rowid='id')")
        #expect(throws: (any Error).self) { try ClaudeMemoryReader(location: fixture.location).fullTextIndexes() }
    }

    @Test func toolHistoryWithDependentDataIsNotRemovedDirectly() throws {
        let fixture = try MemoryFixture()
        try ClaudeMemoryReader(location: fixture.location).checkToolHistoryStandalone()
        // claude-mem's own index with its delete trigger is fine.
        try fixture.write("""
            CREATE VIRTUAL TABLE tool_uses_fts USING fts5(project, content='tool_uses', content_rowid='id');
            INSERT INTO tool_uses_fts(tool_uses_fts) VALUES('rebuild');
            """)
        #expect(throws: (any Error).self) { try ClaudeMemoryReader(location: fixture.location).checkToolHistoryStandalone() }
        try fixture.write("CREATE TRIGGER tool_uses_fts_ad AFTER DELETE ON tool_uses BEGIN INSERT INTO tool_uses_fts(tool_uses_fts, rowid, project) VALUES('delete', old.id, old.project); END")
        try ClaudeMemoryReader(location: fixture.location).checkToolHistoryStandalone()
        try fixture.write("CREATE TABLE tool_links(id INTEGER PRIMARY KEY, tool_use_id INTEGER REFERENCES tool_uses(id))")
        #expect(throws: (any Error).self) { try ClaudeMemoryReader(location: fixture.location).checkToolHistoryStandalone() }
    }

    @Test func unknownSchemaIsRefusedBeforeAnythingIsDeleted() async throws {
        let fixture = try MemoryFixture()
        try fixture.write("CREATE VIRTUAL TABLE observations_search USING fts5(title, content=observations, content_rowid=id)")
        let runtime = MemoryRuntimeStub()
        let cleaner = ClaudeMemoryCleaner(runtime: runtime, log: FakeLog(), backupRoot: fixture.backups)
        let preview = try fixture.preview()
        let result = await cleaner.execute(preview, confirmedID: preview.id, permanentConfirmed: true)
        #expect(!result.succeeded)
        #expect(result.removedRecords == 0)
        #expect(await !runtime.calls.contains(where: { $0.hasPrefix("delete:") || $0 == "stop" }))
        #expect(await runtime.running)
        #expect(try fixture.count("observations") == 4)
    }

    @Test func booleanSettingsAreReadLikeClaudeMem() throws {
        let fixture = try MemoryFixture()
        let home = fixture.root.appendingPathComponent("home")
        let data = home.appendingPathComponent(".claude-mem")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"{"CLAUDE_MEM_WORKER_AUTOSTART":false,"CLAUDE_MEM_CHROMA_ENABLED":false}"#.utf8).write(to: data.appendingPathComponent("settings.json"))
        let location = try ClaudeMemoryLocation.discover(home: home, environment: [:])
        #expect(location.unsupportedSetup != nil)
        #expect(!location.chromaEnabled)
        for host in ["::1", "localhost"] {
            #expect(try ClaudeMemoryLocation.discover(home: home, environment: ["CLAUDE_MEM_WORKER_AUTOSTART": "true", "CLAUDE_MEM_WORKER_HOST": host]).unsupportedSetup != nil, "\(host)")
        }
    }
}
