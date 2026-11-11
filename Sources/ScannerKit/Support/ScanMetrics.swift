import Foundation
import os
import Synchronization

/// Totals of the file system work a scan did, for comparing optimizations on the same data.
///
/// Walks add their counts once when they finish, so counting costs nothing per file. Process-wide: the
/// app runs one scan at a time, and `reset()` starts a new count.
public final class ScanMetrics: Sendable {
    public static let shared = ScanMetrics()

    public enum Counter: String, CaseIterable, Sendable {
        /// Entries the project discovery walk visited.
        case discoveryEntries = "discovery entries"
        /// Entries size measurements visited (rules, projects, apps, leftovers, unrecognized, Rust).
        case measuredEntries = "measured entries"
        case measurements
        case reusedMeasurements = "reused measurements"
        case directoryListings = "directory listings"
        case reusedListings = "reused listings"
        case peakConcurrentWork = "peak concurrent file system work"
    }

    private struct State {
        var counts: [Counter: Int] = [:]
        var active = 0
    }

    private let state = Mutex(State())

    static let signposter = OSSignposter(subsystem: "GRUZ", category: .pointsOfInterest)

    public func reset() { state.withLock { $0 = State() } }

    func add(_ counter: Counter, _ amount: Int = 1) {
        state.withLock { $0.counts[counter, default: 0] += amount }
    }

    func workStarted() {
        state.withLock {
            $0.active += 1
            $0.counts[.peakConcurrentWork] = max($0.counts[.peakConcurrentWork] ?? 0, $0.active)
        }
    }

    func workFinished() { state.withLock { $0.active -= 1 } }

    public func value(_ counter: Counter) -> Int { state.withLock { $0.counts[counter] ?? 0 } }

    public var report: [(name: String, value: Int)] {
        Counter.allCases.map { ($0.rawValue, value($0)) }
    }
}
