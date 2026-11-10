import Foundation

/// How much an item changed since the baseline scan.
public struct DiskGrowth: Codable, Hashable, Sendable {
    public var baselineDate: Date
    public var previousBytes: Int64
    public var deltaBytes: Int64
}

/// A compact history entry, independent of UI filters and selection.
public struct UsageSnapshot: Codable, Sendable {
    public var date: Date
    public var scope: String
    public var sizes: [String: Int64]

    public init(date: Date, scope: String, items: [ScanItem]) {
        self.date = date
        self.scope = scope
        // A partly read item is no baseline: once it can be read in full it would look like growth.
        let measured = items.flatMap(\.leaves).filter { $0.isPartiallyMeasured != true }
        self.sizes = Dictionary(measured.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Daily size snapshots (30 days at most) used to show what grew between scans.
public enum UsageHistory {
    public static func annotate(_ items: [ScanItem], baseline: UsageSnapshot?) -> [ScanItem] {
        items.map { item in
            var copy = item
            copy.growth = nil
            copy.children = annotate(item.children, baseline: baseline)
            if let baseline, let previous = baseline.sizes[item.id], !item.isGroup, item.isPartiallyMeasured != true {
                copy.growth = DiskGrowth(baselineDate: baseline.date, previousBytes: previous, deltaBytes: item.sizeBytes - previous)
            } else if item.isGroup, let date = copy.children.first?.growth?.baselineDate,
                      copy.children.allSatisfy({ $0.growth?.baselineDate == date }) {
                copy.growth = DiskGrowth(baselineDate: date, previousBytes: copy.children.reduce(0) { $0 + ($1.growth?.previousBytes ?? 0) },
                    deltaBytes: copy.children.reduce(0) { $0 + ($1.growth?.deltaBytes ?? 0) })
            }
            return copy
        }
    }

    public static func baseline(in history: [UsageSnapshot], scope: String, now: Date, calendar: Calendar = .current) -> UsageSnapshot? {
        let eligible = history.filter { $0.scope == scope && $0.date < now }
        let today = calendar.startOfDay(for: now)
        return eligible.filter { $0.date < today }.max(by: { $0.date < $1.date })
            ?? eligible.max(by: { $0.date < $1.date })
    }

    public static func retaining(_ history: [UsageSnapshot], adding current: UsageSnapshot, calendar: Calendar = .current) -> [UsageSnapshot] {
        let cutoff = calendar.date(byAdding: .day, value: -30, to: current.date)!
        var snapshots = history.filter { $0.date >= cutoff && $0.date < current.date }
        // Keep the latest measurement per day and scope, bounded across changed scopes too.
        snapshots.removeAll { $0.scope == current.scope && calendar.isDate($0.date, inSameDayAs: current.date) }
        snapshots.append(current)
        return Array(snapshots.sorted { $0.date < $1.date }.suffix(90))
    }
}
