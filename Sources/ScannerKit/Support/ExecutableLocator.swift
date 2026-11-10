import Foundation

/// GUI apps do not inherit the shell PATH, so tools are looked up in known install locations.
public enum ExecutableLocator {
    public static var searchDirectories: [String] {
        let h = Paths.home
        var dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(h)/.orbstack/bin", "/Applications/OrbStack.app/Contents/MacOS/xbin",
            "\(h)/.local/bin", "\(h)/.cargo/bin", "\(h)/.dotnet", "/usr/local/share/dotnet", "/usr/local/go/bin",
        ]
        // nvm installs npm per Node version; prefer the newest.
        let nvm = "\(h)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { VersionCompare.isNewer($0, than: $1) }.map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    public static func locate(_ tool: String) -> String? {
        for dir in searchDirectories {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Environment for child processes: PATH with all search directories, so tools can find their helpers.
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"].map { [$0] } ?? []
        env["PATH"] = (searchDirectories + existing).joined(separator: ":")
        env["HOME"] = Paths.home
        return env
    }
}

public enum VersionCompare {
    /// Compares dotted numeric versions ("1.10.2" > "1.9"); non-numeric parts are ignored.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = numbers(a), pb = numbers(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func numbers(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
