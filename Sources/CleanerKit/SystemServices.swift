import AppKit
import Foundation
import ScannerKit

public struct SystemFileOperations: FileOperations {
    public init() {}

    public func moveToTrash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    public func removePermanently(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func locate(_ tool: String) -> String? { ExecutableLocator.locate(tool) }

    /// Cleanup commands can legitimately run for minutes (brew cleanup, large Docker images), so the
    /// deadline is generous; it exists so a hung tool cannot keep the app busy forever.
    public static let timeout: TimeInterval = 30 * 60

    public func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String) {
        let out = try await ProcessRunner.run(
            executable: executable, arguments: arguments, timeout: Self.timeout, outputLimit: 4_000, keepTail: true
        )
        if out.wasStopped { throw CommandStopped() }
        let text = String(decoding: out.stdout + out.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (out.status, String(text.suffix(4000)))
    }
}

/// The command was stopped before it finished (deadline or cancellation); its effect is unknown.
public struct CommandStopped: LocalizedError {
    public var errorDescription: String? {
        String(localized: "The command was stopped before it finished; part of the data may already be removed.", bundle: .cleanerKit)
    }
}

public struct SystemRunningApps: RunningAppsChecking {
    public init() {}

    public func running(_ bundleIDs: [String]) -> [String] {
        let wanted = Set(bundleIDs)
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(wanted.contains) ?? false }
            .compactMap { $0.localizedName }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

/// Appends JSON lines to `~/Library/Logs/GRUZ/operations.log`.
public struct FileOperationLog: OperationLogging {
    public static var defaultURL: URL {
        URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/Logs/GRUZ/operations.log")
    }

    let url: URL

    public init(url: URL = FileOperationLog.defaultURL) { self.url = url }

    public func record(_ line: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

public struct SystemFreeSpace: FreeSpaceProviding {
    public init() {}
    public func freeBytes() -> Int64? { DiskSpace.available() }
}

public extension CleaningExecutor {
    static func live(projectRoots: [String]) -> CleaningExecutor {
        CleaningExecutor(
            files: SystemFileOperations(), commands: SystemCommandRunner(), apps: SystemRunningApps(),
            log: FileOperationLog(), space: SystemFreeSpace(), denylist: Denylist(protectedRoots: projectRoots)
        )
    }
}
