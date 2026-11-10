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

    public func run(executable: String, arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ExecutableLocator.environment
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus, String(text.suffix(4000))))
            }
        }
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

    public func record(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
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
