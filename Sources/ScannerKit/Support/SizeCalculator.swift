import Darwin
import Foundation

public struct SizeInfo: Sendable, Equatable {
    /// Allocated blocks on disk (what `du` reports), not the logical size; sparse files count only real data.
    public var allocatedBytes: Int64
    public var newestModification: Date?
    public var fileCount: Int

    public init(allocatedBytes: Int64 = 0, newestModification: Date? = nil, fileCount: Int = 0) {
        self.allocatedBytes = allocatedBytes
        self.newestModification = newestModification
        self.fileCount = fileCount
    }

    public mutating func merge(_ other: SizeInfo) {
        allocatedBytes += other.allocatedBytes
        fileCount += other.fileCount
        if let o = other.newestModification, o > (newestModification ?? .distantPast) { newestModification = o }
    }
}

/// Measures directory trees with `fts`, without following symlinks or crossing volumes.
public enum SizeCalculator {
    /// - Parameter excluding: absolute paths whose subtrees are skipped (already accounted elsewhere).
    public static func measure(_ path: String, excluding: Set<String> = []) -> SizeInfo {
        var info = SizeInfo()
        var seenInodes = Set<UInt64>()
        var newest: time_t = 0

        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return info }
        defer { fts_close(fts) }

        var visited = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited % 4096 == 0, Task.isCancelled { break }
            let info_ = Int32(entry.pointee.fts_info)
            switch info_ {
            case FTS_D:
                if !excluding.isEmpty, entry.pointee.fts_level > 0 {
                    let p = String(cString: entry.pointee.fts_path)
                    if excluding.contains(p) {
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                }
                if let st = entry.pointee.fts_statp { account(st.pointee, &info, &seenInodes, &newest, isFile: false) }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if !excluding.isEmpty {
                    let p = String(cString: entry.pointee.fts_path)
                    if excluding.contains(p) { continue }
                }
                if let st = entry.pointee.fts_statp { account(st.pointee, &info, &seenInodes, &newest, isFile: true) }
            default:
                break
            }
        }
        if newest > 0 { info.newestModification = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return info
    }

    private static func account(
        _ st: stat, _ info: inout SizeInfo, _ seen: inout Set<UInt64>, _ newest: inout time_t, isFile: Bool
    ) {
        if isFile, st.st_nlink > 1 {
            guard seen.insert(UInt64(st.st_ino)).inserted else { return }
        }
        info.allocatedBytes += Int64(st.st_blocks) * 512
        if isFile { info.fileCount += 1 }
        if st.st_mtimespec.tv_sec > newest { newest = st.st_mtimespec.tv_sec }
    }

    /// Measures several roots concurrently.
    public static func measureAll(_ paths: [String], excluding: Set<String> = []) async -> [String: SizeInfo] {
        await withTaskGroup(of: (String, SizeInfo).self) { group in
            var results: [String: SizeInfo] = [:]
            var iterator = paths.makeIterator()
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            func addNext() -> Bool {
                guard let p = iterator.next() else { return false }
                group.addTask { (p, measure(p, excluding: excluding)) }
                return true
            }
            for _ in 0..<width where !addNext() { break }
            for await (p, info) in group {
                results[p] = info
                _ = addNext()
            }
            return results
        }
    }
}

public enum DiskSpace {
    /// Free space on the volume holding the home directory, as Finder reports it.
    public static func available(at path: String = Paths.home) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    public static func total(at path: String = Paths.home) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }
}
