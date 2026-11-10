import Darwin
import Foundation

/// Launches an external program with a deadline, bounded output buffers and cancellation.
///
/// `package` access keeps it inside this package: the scanner reaches it only through `ReadOnlyCommand`,
/// and the cleaner only for allow-listed commands. It runs whatever it is given and checks no policy.
package enum ProcessRunner {
    package struct Output: Sendable {
        package var status: Int32
        package var stdout: Data
        package var stderr: Data
        /// The program was stopped because the deadline passed or the task was cancelled.
        package var wasStopped: Bool
    }

    /// - Parameters:
    ///   - timeout: after this many seconds the program gets SIGTERM, and SIGKILL a few seconds later.
    ///   - outputLimit: bytes kept per stream; with `keepTail` the newest bytes are kept, otherwise the first.
    ///   - environment: variables set on top of `ExecutableLocator.environment`.
    package static func run(
        executable: String, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = 64 << 20, keepTail: Bool = false, environment: [String: String] = [:]
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ExecutableLocator.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let stdout = BoundedBuffer(limit: outputLimit, keepTail: keepTail)
        let stderr = BoundedBuffer(limit: outputLimit, keepTail: keepTail)
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        stdout.attach(outPipe.fileHandleForReading)
        stderr.attach(errPipe.fileHandleForReading)
        let stopper = Stopper(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    stopper.cancel()
                    // A child that inherited the pipes may keep them open; do not wait for it for long.
                    stdout.finish(within: 1)
                    stderr.finish(within: 1)
                    continuation.resume(returning: Output(
                        status: finished.terminationStatus, stdout: stdout.data, stderr: stderr.data,
                        wasStopped: stopper.didStop
                    ))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    stdout.finish(within: 0)
                    stderr.finish(within: 0)
                    continuation.resume(throwing: error)
                    return
                }
                stopper.schedule(after: timeout)
            }
        } onCancel: {
            stopper.stop()
        }
    }
}

/// Stops a process once: SIGTERM, then SIGKILL if it is still running after a grace period.
private final class Stopper: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timer: DispatchWorkItem?
    private var requested = false
    private var stopped = false

    init(_ process: Process) { self.process = process }

    /// True only when the program was actually signalled, not when it finished on its own.
    var didStop: Bool { lock.withLock { stopped } }

    /// Called once the process runs; honours a cancellation that arrived before it started.
    func schedule(after timeout: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        let alreadyRequested: Bool = lock.withLock {
            timer = item
            return requested
        }
        if alreadyRequested { stop() } else { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item) }
    }

    func cancel() { lock.withLock { timer?.cancel() } }

    func stop() {
        let shouldSignal: Bool = lock.withLock {
            requested = true
            guard !stopped, process.isRunning else { return false }
            stopped = true
            return true
        }
        guard shouldSignal else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Collects a pipe's output up to a limit, so a chatty program cannot exhaust memory.
private final class BoundedBuffer: @unchecked Sendable {
    private let limit: Int
    private let keepTail: Bool
    private let lock = NSLock()
    private var buffer = Data()
    private let closed = DispatchSemaphore(value: 0)
    private var handle: FileHandle?

    init(limit: Int, keepTail: Bool) {
        self.limit = limit
        self.keepTail = keepTail
    }

    var data: Data { lock.withLock { buffer } }

    func attach(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                self.closed.signal()
                return
            }
            self.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.withLock {
            if keepTail {
                if chunk.count >= limit {
                    buffer = chunk.suffix(limit)
                } else {
                    buffer.append(chunk)
                    if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
                }
            } else if buffer.count < limit {
                buffer.append(chunk.prefix(limit - buffer.count))
            }
        }
    }

    /// Waits up to `seconds` for the end of the stream, then stops reading.
    func finish(within seconds: TimeInterval) {
        _ = closed.wait(timeout: .now() + seconds)
        handle?.readabilityHandler = nil
        try? handle?.close()
    }
}
