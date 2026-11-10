import Foundation

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
}

public enum ReadOnlyCommandError: Error, CustomStringConvertible {
    case notAllowed([String])
    case toolNotFound(String)
    case timedOut

    public var description: String {
        switch self {
        case .notAllowed(let argv): "Command not allow-listed: \(argv.joined(separator: " "))"
        case .toolNotFound(let tool): "Tool not found: \(tool)"
        case .timedOut: "Command timed out"
        }
    }
}

/// Runs only commands from `CommandPolicy`'s read-only list.
enum ReadOnlyCommand {
    static func run(_ argv: [String], timeout: TimeInterval = 60) async throws -> CommandOutput {
        guard CommandPolicy.isAllowedReadOnlyCommand(argv) else { throw ReadOnlyCommandError.notAllowed(argv) }
        guard let executable = ExecutableLocator.locate(argv[0]) else { throw ReadOnlyCommandError.toolNotFound(argv[0]) }
        return try await Subprocess.run(executable: executable, arguments: Array(argv.dropFirst()), timeout: timeout)
    }
}

/// Minimal process launcher. Internal so other modules cannot reach it through ScannerKit.
enum Subprocess {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ExecutableLocator.environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Drain pipes before waiting, otherwise large output blocks the child.
                let stdoutBox = DataBox(), stderrBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    stdoutBox.data = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    stderrBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
                let stdoutData = stdoutBox.data, stderrData = stderrBox.data
                timer.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ReadOnlyCommandError.timedOut)
                    return
                }
                continuation.resume(returning: CommandOutput(
                    status: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }
        }
    }
}

/// Written by exactly one reader before `group.wait()` returns, so unsynchronized access is safe.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
