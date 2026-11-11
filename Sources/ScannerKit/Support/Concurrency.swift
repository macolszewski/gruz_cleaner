import Foundation
import Synchronization

/// Runs `transform` over `inputs` with at most `width` tasks in flight and returns the results by input.
func concurrentMap<Input: Hashable & Sendable, Output: Sendable>(
    _ inputs: [Input], width: Int, _ transform: @escaping @Sendable (Input) async -> Output
) async -> [Input: Output] {
    await withTaskGroup(of: (Input, Output).self) { group in
        var results: [Input: Output] = [:]
        var iterator = inputs.makeIterator()
        func addNext() -> Bool {
            guard let input = iterator.next() else { return false }
            group.addTask { (input, await transform(input)) }
            return true
        }
        for _ in 0..<max(1, width) where !addNext() { break }
        for await (input, output) in group {
            results[input] = output
            _ = addNext()
        }
        return results
    }
}

/// Cancellation that blocking work can poll outside Swift Concurrency, where `Task.isCancelled`
/// no longer sees the task that asked for the work.
public final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    public var isCancelled: Bool { flag.load(ordering: .relaxed) }

    public func cancel() { flag.store(true, ordering: .relaxed) }
}

/// One limit on blocking file system work (`fts` walks) for a whole scan.
///
/// A walk blocks its thread for its whole duration. Running walks on Swift Concurrency's cooperative
/// threads would starve other tasks, and separate per-source limits added up to more parallel walks
/// than the disk serves well, so every source sends its walks here instead.
public final class IOPool: @unchecked Sendable {
    /// The fastest of 1, 2, 4 and 8 for a full scan on an Apple silicon Mac with an internal SSD
    /// (see docs/reference/architecture.md).
    public static let defaultWidth = 8

    let width: Int
    // OperationQueue is thread-safe; it is not marked Sendable in the SDK.
    private let queue: OperationQueue

    init(width: Int = IOPool.defaultWidth) {
        self.width = max(1, width)
        queue = OperationQueue()
        queue.name = "GRUZ file system work"
        queue.maxConcurrentOperationCount = self.width
        queue.qualityOfService = .utility
    }

    /// Runs `work` on the pool. Cancelling the calling task sets the flag `work` receives.
    func run<T: Sendable>(_ work: @escaping @Sendable (CancellationFlag) -> T) async -> T {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                queue.addOperation {
                    ScanMetrics.shared.workStarted()
                    let result = work(flag)
                    ScanMetrics.shared.workFinished()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Runs `work` for every input on the pool and returns the results by input.
    func map<Input: Hashable & Sendable, Output: Sendable>(
        _ inputs: [Input], _ work: @escaping @Sendable (Input, CancellationFlag) -> Output
    ) async -> [Input: Output] {
        await withTaskGroup(of: (Input, Output).self) { group in
            // The queue does the limiting; a task waiting for its turn is suspended, not blocking a thread.
            for input in Set(inputs) {
                group.addTask { (input, await self.run { work(input, $0) }) }
            }
            var results: [Input: Output] = [:]
            for await (input, output) in group { results[input] = output }
            return results
        }
    }
}
