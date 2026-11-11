import CryptoKit
import Darwin
import Foundation

/// Snapshot of a generated subtree. Kept with the selection and revalidated before removal.
public struct RustArtifact: Codable, Hashable, Sendable {
    public var targetRoot: String
    public var profileRoot: String
    public var path: String
    public var signature: String
    public var recentBytes: Int64
    public var since: Date
    public var manifestPath: String?
}

public struct RustTreeMeasurement: Sendable {
    public var bytes: Int64 = 0
    public var recentBytes: Int64 = 0
    public var newest: Date?
    public var signature = ""
    /// Why the subtree is not offered for removal; nil when it can be removed.
    public var problem: String?
}

public enum RustArtifacts {
    public static let components: Set<String> = ["deps", "incremental", "build", ".fingerprint", "examples"]

    /// Prefix of the current signature format. A signature from another format never matches, so a
    /// selection made by an older version must be scanned again before removal.
    static let signatureFormat = "v2:"

    /// Reads metadata only; never follows links, crosses devices or runs Cargo/build scripts.
    ///
    /// The signature covers every entry's path, type, identity, size, link count and times. Entries are
    /// visited in name order within each folder and hashed as they are read, so memory does not grow
    /// with the size of the tree.
    public static func measure(_ path: String, since: Date, cancellation: CancellationFlag? = nil) -> RustTreeMeasurement {
        var result = RustTreeMeasurement()
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            result.problem = String(localized: "The folder is gone or is a symbolic link. Scan again.", bundle: .scannerKit)
            return result
        }
        let root = strdup(path)
        defer { free(root) }
        var argv: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let tree = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, compareNames) else {
            result.problem = String(localized: "The folder cannot be read.", bundle: .scannerKit)
            return result
        }
        defer { fts_close(tree) }
        var hash = SHA256()
        var record: [UInt8] = []
        record.reserveCapacity(512)
        // Only files with several links can be met twice; their blocks are counted once.
        var linked = Set<FileIdentity>()
        var visited = 0
        defer { ScanMetrics.shared.add(.measuredEntries, visited) }
        while let entry = fts_read(tree) {
            visited += 1
            if visited % 1024 == 0, cancellation?.isCancelled ?? Task.isCancelled {
                result.problem = String(localized: "Measurement canceled.", bundle: .scannerKit)
                break
            }
            let kind = Int32(entry.pointee.fts_info)
            if kind == FTS_DP { continue }
            guard kind == FTS_D || kind == FTS_F, let ptr = entry.pointee.fts_statp else {
                result.problem = String(localized: "Incomplete measurement: a link or special file was found. Review it manually.", bundle: .scannerKit)
                continue
            }
            let s = ptr.pointee
            let pathBytes = UnsafeRawBufferPointer(start: entry.pointee.fts_path, count: Int(entry.pointee.fts_pathlen))
            if s.st_dev != rootStat.st_dev { result.problem = String(localized: "The folder spans another volume.", bundle: .scannerKit) }
            if isProtectedName(lastComponent(of: pathBytes)) {
                result.problem = String(localized: "Data or an app bundle was found. GRUZ will not remove this subfolder.", bundle: .scannerKit)
            }

            record.removeAll(keepingCapacity: true)
            record.append(kind == FTS_D ? 1 : 2)
            append(UInt64(pathBytes.count), to: &record)
            record.append(contentsOf: pathBytes)
            let identity: [UInt64] = [UInt64(UInt32(bitPattern: s.st_dev)), s.st_ino, UInt64(s.st_mode), UInt64(s.st_nlink)]
            let sizes: [Int64] = [s.st_size, s.st_blocks]
            let times: [Int] = [s.st_mtimespec.tv_sec, s.st_mtimespec.tv_nsec, s.st_ctimespec.tv_sec, s.st_ctimespec.tv_nsec]
            for value in identity { append(value, to: &record) }
            for value in sizes { append(UInt64(bitPattern: value), to: &record) }
            for value in times { append(UInt64(bitPattern: Int64(value)), to: &record) }
            hash.update(data: record)

            if kind == FTS_D || s.st_nlink <= 1 || linked.insert(FileIdentity(device: s.st_dev, inode: s.st_ino)).inserted {
                let bytes = Int64(s.st_blocks) * 512
                result.bytes += bytes
                if kind == FTS_F, Double(s.st_birthtimespec.tv_sec) >= since.timeIntervalSince1970 { result.recentBytes += bytes }
            }
            let modified = Date(timeIntervalSince1970: Double(s.st_mtimespec.tv_sec))
            result.newest = max(result.newest ?? .distantPast, modified)
        }
        result.signature = signatureFormat + hash.finalize().map { String(format: "%02x", $0) }.joined()
        return result
    }

    private struct FileIdentity: Hashable {
        var device: dev_t
        var inode: ino_t
    }

    private static func append(_ value: UInt64, to record: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { record.append(contentsOf: $0) }
    }

    /// Byte order of names, so the visiting order (and the signature) does not depend on the file system.
    private static let compareNames: @convention(c) (
        UnsafeMutablePointer<UnsafePointer<FTSENT>?>?, UnsafeMutablePointer<UnsafePointer<FTSENT>?>?
    ) -> Int32 = { a, b in
        guard let x = a?.pointee, let y = b?.pointee else { return 0 }
        // `fts_name` is stored inline past the end of the declared struct; read it in place, never from a copy.
        let offset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!
        let xName = (UnsafeRawPointer(x) + offset).assumingMemoryBound(to: CChar.self)
        let yName = (UnsafeRawPointer(y) + offset).assumingMemoryBound(to: CChar.self)
        let xLength = Int(x.pointee.fts_namelen), yLength = Int(y.pointee.fts_namelen)
        let order = memcmp(xName, yName, min(xLength, yLength))
        if order != 0 { return order }
        return xLength < yLength ? -1 : (xLength > yLength ? 1 : 0)
    }

    private static func lastComponent(of path: UnsafeRawBufferPointer) -> String {
        let start = path.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
        return String(decoding: UnsafeRawBufferPointer(rebasing: path[start...]), as: UTF8.self)
    }

    /// Names that mean the folder holds more than build output.
    static func isProtectedName(_ name: String) -> Bool {
        if [".git", "Cargo.toml", "Cargo.lock", "config.json", "session.json"].contains(name) { return true }
        return ["app", "db", "sqlite", "sqlite3", "sql"].contains((name as NSString).pathExtension.lowercased())
    }

    static func items(target: String, manifestPath: String? = nil, cancellation: CancellationFlag? = nil) -> ScanItem {
        func isCancelled() -> Bool { cancellation?.isCancelled ?? Task.isCancelled }
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        var children: [ScanItem] = []
        func visit(_ path: String, depth: Int) {
            guard depth <= 2, !isCancelled() else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path).sorted() else { return }
            let isProfile = Paths.exists(Paths.join(path, ".cargo-lock")) && Paths.isDirectory(Paths.join(path, ".fingerprint"))
            if isProfile {
                let relative = String(path.dropFirst(target.count + 1))
                var parts: [ScanItem] = []
                for name in entries where components.contains(name) && Paths.isDirectory(Paths.join(path, name)) {
                    let part = Paths.join(path, name)
                    let measured = measure(part, since: since, cancellation: cancellation)
                    guard measured.bytes > 0 || measured.problem != nil else { continue }
                    var item = ScanItem(
                        id: "rust:\(part)", ruleID: "artifact.rust-target", category: .rust,
                        title: name, app: "Rust / Cargo", description: String(localized: "Build artifacts of the \(relative) profile. Removal does not touch sources, other profiles or built apps outside this subfolder.", bundle: .scannerKit),
                        regeneration: String(localized: "Cargo recreates the files on the next build or test run. The first run will be slower.", bundle: .scannerKit),
                        safety: .regenerable, sizeBytes: measured.bytes, lastModified: measured.newest,
                        paths: [part], action: measured.problem == nil ? .trash : nil,
                        note: measured.problem ?? String(localized: "Estimated size; shared blocks may reduce the reclaimed space. Before removal, GRUZ checks running processes, the Cargo lock and changes since the scan.", bundle: .scannerKit)
                    )
                    item.rustArtifact = RustArtifact(targetRoot: target, profileRoot: path, path: part,
                        signature: measured.signature, recentBytes: measured.recentBytes, since: since, manifestPath: manifestPath)
                    parts.append(item)
                }
                let retained = entries.filter { !components.contains($0) }
                    .filter { ![".cargo-lock", ".DS_Store"].contains($0) }
                for name in retained {
                    let full = Paths.join(path, name)
                    let info = SizeCalculator.measure(full, cancellation: cancellation)
                    guard info.allocatedBytes > 0 else { continue }
                    parts.append(ScanItem(id: "rust:retained:\(full)", category: .rust, title: String(localized: "Kept: \(name)", bundle: .scannerKit),
                        description: String(localized: "Build output or other profile contents. Not included in Rust cache cleanup.", bundle: .scannerKit),
                        safety: .userData, sizeBytes: info.allocatedBytes, paths: [full]).measured(info))
                }
                guard !parts.isEmpty else { return }
                children.append(ScanItem(id: "rust:profile:\(path)", category: .rust,
                    title: relative == "debug" ? String(localized: "Debug and tests (release is kept)", bundle: .scannerKit) : String(localized: "Profile \(relative)", bundle: .scannerKit),
                    app: "Rust / Cargo", description: String(localized: "Selecting the group includes only subfolders with recognized artifacts. Built programs and packages stay on disk.", bundle: .scannerKit),
                    safety: .regenerable, sizeBytes: parts.reduce(0) { $0 + $1.sizeBytes }, children: parts))
                return
            }
            for name in entries where !name.hasPrefix(".") {
                let next = Paths.join(path, name)
                var st = stat()
                guard lstat(next, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                visit(next, depth: depth + 1)
            }
        }
        visit(target, depth: 0)
        if children.isEmpty {
            let info = SizeCalculator.measure(target, cancellation: cancellation)
            children = [ScanItem(id: "rust:unknown:\(target)", category: .rust, title: String(localized: "Unrecognized target layout", bundle: .scannerKit),
                description: String(localized: "No recognized profile with a Cargo lock and a .fingerprint folder. Cleaning is disabled.", bundle: .scannerKit),
                safety: .caution, sizeBytes: info.allocatedBytes, paths: [target]).measured(info)]
        }
        return ScanItem(id: "rust:target:\(target)", category: .rust,
            title: ((target as NSString).deletingLastPathComponent as NSString).lastPathComponent,
            app: "Rust / Cargo", description: String(localized: "Build profiles and caches. Debug can be cleaned separately while keeping release. Space is freed only after the Trash is emptied.", bundle: .scannerKit),
            safety: .regenerable, sizeBytes: children.reduce(0) { $0 + $1.sizeBytes }, paths: [target], children: children)
    }
}
