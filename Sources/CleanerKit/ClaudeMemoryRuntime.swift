import Foundation
import ScannerKit

/// The claude-mem worker found before maintenance; stored in the maintenance marker so an
/// interrupted run can restart the same worker.
public struct ClaudeMemoryWorker: Codable, Sendable {
    public var path: String
    public var version: String
    public var running: Bool
    public init(path: String, version: String, running: Bool) {
        self.path = path
        self.version = version
        self.running = running
    }
}

/// Everything ClaudeMemoryCleaner needs from claude-mem and the Chroma tooling; replaced by a stub in tests.
/// Each check throws an error that explains to the user what to do.
public protocol ClaudeMemoryRuntime: Sendable {
    /// Identifies the worker serving `location`, or the stopped worker recorded by an interrupted maintenance.
    func worker(location: ClaudeMemoryLocation) async throws -> ClaudeMemoryWorker
    /// Throws while agent sessions or queued work could write to the database.
    func checkIdle(location: ClaudeMemoryLocation) async throws
    /// Makes sure the indexing helper and its embedding model are available before anything changes.
    func prepareIndex(location: ClaudeMemoryLocation) async throws
    /// Deletes a synced record through the worker API, so claude-mem records the deletion for sync.
    func delete(_ record: ClaudeMemoryRecord, location: ClaudeMemoryLocation) async throws
    func stop(location: ClaudeMemoryLocation) async throws
    /// Throws unless the worker is down and no process has claude-mem files open.
    func checkStopped(location: ClaudeMemoryLocation) async throws
    /// Builds a new Chroma index in `destination` from the current database.
    func rebuildIndex(location: ClaudeMemoryLocation, destination: URL, progress: @escaping @Sendable (String) async -> Void) async throws
    /// Throws unless the index in `destination` matches the current database exactly.
    func verifyIndex(location: ClaudeMemoryLocation, destination: URL) async throws
    func start(_ worker: ClaudeMemoryWorker, location: ClaudeMemoryLocation) async throws
}

/// Talks to the local claude-mem worker over HTTP and runs the bundled Python indexing helper through uv.
public struct LiveClaudeMemoryRuntime: ClaudeMemoryRuntime {
    public init() {}

    private func request(_ path: String, method: String = "GET", location: ClaudeMemoryLocation) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(location.port)/api/\(path)") else {
            throw LocalizedMessage("Invalid worker address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        let config = URLSessionConfiguration.ephemeral
        // The worker listens on localhost only; a system proxy must never see these requests.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LocalizedMessage("The worker rejected \(method) /api/\(path) (HTTP \(status)). Check the state of claude-mem and do not force anything.")
        }
        return result
    }

    public func worker(location: ClaudeMemoryLocation) async throws -> ClaudeMemoryWorker {
        let health: [String: Any]
        do { health = try await request("health", location: location) }
        catch {
            if let data = try? Data(contentsOf: location.maintenanceMarker),
               let marker = try? JSONDecoder().decode(ClaudeMemoryWorker.self, from: data) {
                try await checkStopped(location: location)
                return ClaudeMemoryWorker(path: marker.path, version: marker.version, running: false)
            }
            throw LocalizedMessage("Start claude-mem so GRUZ can confirm the database location and manage the worker safely.")
        }
        let stats = try await request("stats", location: location)
        guard let database = stats["database"] as? [String: Any], let path = database["path"] as? String,
              URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == location.database,
              let workerPath = health["workerPath"] as? String,
              let version = health["version"] as? String,
              health["initialized"] as? Bool == true else {
            throw LocalizedMessage("The worker does not serve this database or is still starting.")
        }
        // The HTTP API and the Chroma document layout were verified against this release line only.
        guard version.hasPrefix("13."), !VersionCompare.isNewer("13.28.0", than: version) else {
            throw LocalizedMessage("GRUZ supports claude-mem 13.x from version 13.28.0. Found version \(version).")
        }
        _ = try runtimeExecutable()
        guard workerPath.hasPrefix("/"), URL(fileURLWithPath: workerPath).lastPathComponent == "worker-service.cjs",
              FileManager.default.fileExists(atPath: workerPath) else {
            throw LocalizedMessage("The worker start script is missing.")
        }
        return ClaudeMemoryWorker(path: workerPath, version: version, running: true)
    }

    public func checkIdle(location: ClaudeMemoryLocation) async throws {
        let stats = try await request("stats", location: location)
        let status = try await request("processing-status", location: location)
        guard let worker = stats["worker"] as? [String: Any], let active = worker["activeSessions"] as? Int,
              let processing = status["isProcessing"] as? Bool, let queue = status["queueDepth"] as? Int,
              active == 0, !processing, queue == 0 else {
            throw LocalizedMessage("claude-mem has active sessions or queued work. End the agent sessions that use memory, then try again.")
        }
    }

    public func delete(_ record: ClaudeMemoryRecord, location: ClaudeMemoryLocation) async throws {
        guard let endpoint = record.kind.endpoint, record.rowID > 0, !record.isRemote else {
            throw LocalizedMessage("This record cannot be deleted through the worker.")
        }
        let response = try await request("\(endpoint)/\(record.rowID)", method: "DELETE", location: location)
        guard response["success"] as? Bool == true else { throw LocalizedMessage("The worker did not confirm the deletion.") }
    }

    public func stop(location: ClaudeMemoryLocation) async throws {
        _ = try await request("admin/shutdown", method: "POST", location: location)
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            if (try? await checkStopped(location: location)) != nil { return }
        }
        throw LocalizedMessage("The worker or Chroma still has files open. Maintenance was stopped.")
    }

    public func checkStopped(location: ClaudeMemoryLocation) async throws {
        if (try? await request("health", location: location)) != nil {
            throw LocalizedMessage("The worker is running. Quit the claude-mem clients and try again.")
        }
        // lsof exits with 1 and prints nothing when no process has a file open; anything else is unsafe.
        let result = try await ClaudeMemoryProcess.run("/usr/sbin/lsof", ["-t", "+D", location.root.path], timeout: 20)
        guard result.status == 1, result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalizedMessage("claude-mem files are open, or GRUZ cannot check that. Quit the clients and try again.")
        }
    }

    private func runtimeExecutable() throws -> String {
        let bun = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin/bun").path
        if FileManager.default.isExecutableFile(atPath: bun) { return bun }
        if let found = ExecutableLocator.locate("bun") { return found }
        throw LocalizedMessage("Cannot find Bun, which is needed to restart claude-mem.")
    }

    private func indexCommand() throws -> (String, [String]) {
        guard let uv = ExecutableLocator.locate("uv"),
              let helper = Bundle.cleanerKit.url(forResource: "claude_mem_reindex", withExtension: "py", subdirectory: "Helpers") else {
            throw LocalizedMessage("uv or the indexing script is missing. Install uv and rebuild GRUZ.")
        }
        // Python is pinned: uv would otherwise pick the newest interpreter on the machine, for which
        // onnxruntime may not have wheels yet. uv downloads this version when it is missing.
        return (uv, ["run", "--no-project", "--python", "3.13", "--with", "chromadb==1.5.9", "--with", "onnxruntime>=1.20", "--with", "protobuf<7", "python", helper.path])
    }

    public func prepareIndex(location: ClaudeMemoryLocation) async throws {
        guard location.chromaMode == "local", location.embeddingFunction == "default" else {
            throw LocalizedMessage("A full rebuild supports only a local Chroma with the default embedding model. A remote or custom index needs separate handling.")
        }
        let (tool, arguments) = try indexCommand()
        let result = try await ClaudeMemoryProcess.run(tool, arguments + ["--check"], timeout: 600)
        guard result.status == 0 else { throw LocalizedMessage("Could not prepare indexing: \(result.output)") }
    }

    public func rebuildIndex(location: ClaudeMemoryLocation, destination: URL, progress: @escaping @Sendable (String) async -> Void) async throws {
        let (tool, arguments) = try indexCommand()
        let updates = Task {
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: destination.appendingPathComponent("cleaner-progress.json")),
                   let counts = try? JSONDecoder().decode([String: Int].self, from: data),
                   let completed = counts["completed"], let total = counts["total"], total > 0 {
                    let percent = (Double(completed * 100 / total) / 100).formatted(.percent)
                    await progress(String(localized: "Rebuilding Chroma: \(completed) of \(total) documents (\(percent)).", bundle: .cleanerKit))
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        defer { updates.cancel() }
        let result = try await ClaudeMemoryProcess.run(tool, arguments + ["--database", location.database.path, "--output", destination.path], timeout: 3600)
        guard result.status == 0 else { throw LocalizedMessage("Rebuilding Chroma failed: \(result.output)") }
    }

    public func verifyIndex(location: ClaudeMemoryLocation, destination: URL) async throws {
        let (tool, arguments) = try indexCommand()
        let result = try await ClaudeMemoryProcess.run(tool, arguments + ["--verify", "--database", location.database.path, "--output", destination.path], timeout: 180)
        guard result.status == 0 else { throw LocalizedMessage("The index does not match the database: \(result.output)") }
    }

    public func start(_ worker: ClaudeMemoryWorker, location: ClaudeMemoryLocation) async throws {
        let result = try await ClaudeMemoryProcess.run(try runtimeExecutable(), [worker.path, "start"], timeout: 90,
                                                       environment: ["CLAUDE_MEM_DATA_DIR": location.root.path, "CLAUDE_MEM_WORKER_PORT": String(location.port)])
        guard result.status == 0 else { throw LocalizedMessage("Could not start claude-mem: \(result.output)") }
        for _ in 0..<60 {
            if let health = try? await request("health", location: location), health["initialized"] as? Bool == true {
                _ = try await self.worker(location: location)
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LocalizedMessage("The worker did not report that it is ready after starting.")
    }
}

/// Runs a helper process with a timeout and keeps only the tail of its output for error messages.
enum ClaudeMemoryProcess {
    struct Output: Sendable { let status: Int32; let output: String }
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String] = [:]) async throws -> Output {
        let out = try await ProcessRunner.run(
            executable: executable, arguments: arguments, timeout: timeout,
            outputLimit: 16_000, keepTail: true, environment: environment
        )
        return Output(status: out.status, output: String(decoding: out.stdout + out.stderr, as: UTF8.self))
    }
}
