import Foundation

/// File system answers shared by the sources of one scan: directory listings, expanded patterns of
/// preserved data and finished measurements.
///
/// Rules, the denylist and project matching ask about the same folders many times (ten JetBrains cache
/// patterns list the same product folders, each `bin` and `obj` lists the same project folder). It lives
/// only as long as the scan; checks made before removal always read the current state.
final class ScanCache: @unchecked Sendable {
    private struct MeasurementKey: Hashable {
        var path: String
        var excluding: Set<String>
    }

    private let lock = NSLock()
    private var listings: [String: [String]?] = [:]
    private var globs: [String: Paths.GlobResult] = [:]
    private var measurements: [MeasurementKey: SizeInfo] = [:]

    /// Names in `directory`, or nil when it cannot be listed (missing, not a folder, no permission).
    func contents(of directory: String) -> [String]? {
        if let cached = lock.withLock({ listings[directory] }) {
            ScanMetrics.shared.add(.reusedListings)
            return cached
        }
        ScanMetrics.shared.add(.directoryListings)
        let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
        lock.withLock { listings[directory] = .some(entries) }
        return entries
    }

    func glob(_ pattern: String, home: String) -> Paths.GlobResult {
        let key = home + "\u{0}" + pattern
        if let cached = lock.withLock({ globs[key] }) { return cached }
        let result = Paths.globReporting(pattern, home: home, list: contents(of:))
        lock.withLock { globs[key] = result }
        return result
    }

    /// Measures `path` once per scan for the same exclusions. A folder measured without exclusions is
    /// not reused for a measurement that excludes some of it: subtracting subtrees would miscount hard links.
    func measure(_ path: String, excluding: Set<String> = [], pool: IOPool) async -> SizeInfo {
        let key = MeasurementKey(path: path, excluding: excluding)
        if let cached = lock.withLock({ measurements[key] }) {
            ScanMetrics.shared.add(.reusedMeasurements)
            return cached
        }
        let info = await pool.run { SizeCalculator.measure(path, excluding: excluding, cancellation: $0) }
        lock.withLock { measurements[key] = info }
        return info
    }

    func measureAll(_ paths: [String], pool: IOPool) async -> [String: SizeInfo] {
        await withTaskGroup(of: (String, SizeInfo).self) { group in
            for path in Set(paths) {
                group.addTask { (path, await self.measure(path, pool: pool)) }
            }
            var results: [String: SizeInfo] = [:]
            for await (path, info) in group { results[path] = info }
            return results
        }
    }
}
