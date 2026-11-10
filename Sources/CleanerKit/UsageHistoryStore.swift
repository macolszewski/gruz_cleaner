import Foundation
import ScannerKit

/// Persists scan snapshots so the next scan can show how much each item grew.
public enum UsageHistoryStore {
    /// Annotates `result` with growth since the stored baseline and stores it as a new snapshot.
    /// Snapshots are compared only within the same scope (roots and Full Disk Access state).
    public static func update(_ result: ScanResult, roots: [String], directory: URL) -> ScanResult {
        var output = result
        let url = directory.appendingPathComponent("usage-history-v1.json")
        let decoder = JSONDecoder()
        let history = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([UsageSnapshot].self, from: $0) } ?? []
        let scope = "v1|\(result.hasFullDiskAccess)|" + roots.map { Paths.expand($0) }.sorted().joined(separator: "|")
        // Incomplete scans must neither become a baseline nor claim a negative growth.
        guard result.warnings.isEmpty, !Task.isCancelled else { return output }
        output.items = UsageHistory.annotate(result.items, baseline: UsageHistory.baseline(in: history, scope: scope, now: result.finishedAt))
        let current = UsageSnapshot(date: result.finishedAt, scope: scope, items: result.items)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(UsageHistory.retaining(history, adding: current)).write(to: url, options: .atomic)
        } catch {
            output.warnings.append(String(localized: "Could not save the disk usage history: \(error.localizedDescription)", bundle: .cleanerKit))
        }
        return output
    }
}
