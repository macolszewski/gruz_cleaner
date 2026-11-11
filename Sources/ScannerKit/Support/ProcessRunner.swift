import Darwin
import Foundation

/// Launches an external program with a deadline, bounded output buffers and cancellation.
///
/// `package` access keeps it inside this package: the scanner reaches it only through `ReadOnlyCommand`,
/// and the cleaner only for allow-listed commands. It runs whatever it is given and checks no policy.
///
/// The program starts in a process group of its own, so stopping it reaches every process it started,
/// and helpers still running when it exits are ended before its result is reported.
package enum ProcessRunner {
    package struct Output: Sendable {
        /// Exit code, or the signal number when a signal ended the program.
        package var status: Int32
        package var stdout: Data
        package var stderr: Data
        /// The program was stopped because the deadline passed or the task was cancelled.
        package var wasStopped: Bool
    }

    /// - Parameters:
    ///   - timeout: after this many seconds the process group gets SIGTERM, and SIGKILL a few seconds later.
    ///   - outputLimit: bytes kept per stream; with `keepTail` the newest bytes are kept, otherwise the first.
    ///   - environment: variables set on top of `ExecutableLocator.environment`.
    package static func run(
        executable: String, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = 64 << 20, keepTail: Bool = false, environment: [String: String] = [:]
    ) async throws -> Output {
        let outPipe = Pipe(), errPipe = Pipe()
        let stdout = BoundedBuffer(limit: outputLimit, keepTail: keepTail)
        let stderr = BoundedBuffer(limit: outputLimit, keepTail: keepTail)
        let env = ExecutableLocator.environment.merging(environment) { _, new in new }
        let pid = try spawn(
            executable, [executable] + arguments, env: env,
            stdout: outPipe.fileHandleForWriting.fileDescriptor, stderr: errPipe.fileHandleForWriting.fileDescriptor
        )
        // The child has its own copies; keeping ours open would hide the end of the streams.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        stdout.attach(outPipe.fileHandleForReading)
        stderr.attach(errPipe.fileHandleForReading)
        let group = ProcessGroup(pid)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Output, Never>) in
                Thread.detachNewThread {
                    let status = group.waitAndReap()
                    // A helper that left the group (setsid) may still hold the pipes; do not wait for it for long.
                    stdout.finish(within: 1)
                    stderr.finish(within: 1)
                    continuation.resume(returning: Output(
                        status: status, stdout: stdout.data, stderr: stderr.data, wasStopped: group.didStop
                    ))
                }
                group.schedule(after: timeout)
            }
        } onCancel: {
            group.stop()
        }
    }

    private static func spawn(_ path: String, _ argv: [String], env: [String: String], stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        // A new group led by the child; every other descriptor of this app is closed in it. Signal handling
        // starts from the defaults, so an ignored or blocked SIGTERM in this process cannot make it unstoppable.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, cArgs, cEnv)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }
}

/// The process group of one launched program. Signals go to the whole group, and only while its leader
/// has not been reaped, so its id cannot have been reused by an unrelated process.
private final class ProcessGroup: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var timer: DispatchWorkItem?
    private var requested = false
    private var stopped = false
    private var reaped = false

    init(_ pid: pid_t) { self.pid = pid }

    /// True only when the program was actually signalled, not when it finished on its own.
    var didStop: Bool { lock.withLock { stopped } }

    /// Called once the program runs; honours a cancellation that arrived before it.
    func schedule(after timeout: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        let alreadyRequested: Bool = lock.withLock {
            timer = item
            return requested
        }
        if alreadyRequested { stop() } else { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item) }
    }

    /// SIGTERM to the group, then SIGKILL to whatever is still in it after a grace period.
    func stop() {
        let signalled: Bool = lock.withLock {
            requested = true
            guard !stopped, !reaped else { return false }
            stopped = true
            killpg(pid, SIGTERM)
            return true
        }
        guard signalled else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            lock.withLock { if !reaped { _ = killpg(pid, SIGKILL) } }
        }
    }

    /// Blocks until the leader exits, ends the helpers it left in the group, then reaps it.
    func waitAndReap() -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        var status: Int32 = 0
        lock.withLock {
            timer?.cancel()
            // The exited leader still holds its id, so the group id is ours until the reap below.
            _ = killpg(pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            reaped = true
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
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
