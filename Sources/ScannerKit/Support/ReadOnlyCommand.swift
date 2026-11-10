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

/// Process launcher for read-only commands. Internal so other modules cannot reach it through ScannerKit.
enum Subprocess {
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let out = try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        if out.wasStopped { throw ReadOnlyCommandError.timedOut }
        return CommandOutput(status: out.status, stdout: out.stdout, stderr: String(decoding: out.stderr, as: UTF8.self))
    }
}
