import Foundation

/// Paths that must never be removed, regardless of what a rule says.
public struct Denylist: Sendable {
    public var home: String
    /// User-configured project roots; the roots themselves are protected, their artifacts are not.
    public var protectedRoots: [String]

    public init(home: String = Paths.home, protectedRoots: [String] = []) {
        self.home = home
        self.protectedRoots = protectedRoots.map { Paths.expand($0, home: home) }
    }

    private var exactPaths: Set<String> {
        let h = home
        var set: Set<String> = [
            "/", "/Applications", "/Library", "/Users", "/opt", "/opt/homebrew", "/private", "/private/var",
            "/private/var/folders", "/Volumes",
            h, "\(h)/Library", "\(h)/Library/Application Support", "\(h)/Library/Caches", "\(h)/Library/Containers",
            "\(h)/Library/Group Containers", "\(h)/Library/Logs", "\(h)/Library/Developer", "\(h)/Library/Preferences",
            "\(h)/Applications", "\(h)/.cache", "\(h)/.local", "\(h)/.local/share", "\(h)/.config",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/.Trash",
            Paths.userTempDir,
        ]
        set.formUnion(ScanOptions.commonProjectRoots.map { Paths.expand($0, home: h) })
        set.formUnion(protectedRoots)
        return set
    }

    private var forbiddenSubtrees: [String] {
        let h = home
        return [
            "/System", "/bin", "/sbin", "/usr", "/etc", "/private/etc", "/cores", "/dev",
            "\(h)/Library/Keychains", "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Photos",
            "\(h)/.ssh", "\(h)/.gnupg", "\(h)/Documents", "\(h)/Desktop", "\(h)/Pictures",
        ]
    }

    /// Roots under which removal may happen at all.
    private var allowedRoots: [String] {
        [home, "/private/var/folders", "/var/folders", "/opt/homebrew/share/android-commandlinetools"]
    }

    /// `denied` carries a reason shown to the user.
    public enum Verdict: Equatable, Sendable {
        case allowed
        case denied(String)
    }

    public func check(_ rawPath: String) -> Verdict {
        let path = Paths.normalize(rawPath)
        guard path.hasPrefix("/") else { return .denied(String(localized: "The path is not absolute", bundle: .scannerKit)) }
        if path.split(separator: "/").contains(where: { $0 == ".git" }) {
            return .denied(String(localized: "Git repositories are protected", bundle: .scannerKit))
        }
        if exactPaths.contains(path) { return .denied(String(localized: "Protected folder", bundle: .scannerKit)) }
        if let sub = forbiddenSubtrees.first(where: { Paths.isWithin(path, $0) }) {
            return .denied(String(localized: "Protected area: \(Paths.abbreviate(sub))", bundle: .scannerKit))
        }
        guard allowedRoots.contains(where: { Paths.isWithin(path, $0) && path != $0 }) else {
            return .denied(String(localized: "Outside the allowed area", bundle: .scannerKit))
        }
        // Resolve symlinks in parent components so a link cannot redirect removal elsewhere.
        let parent = (path as NSString).deletingLastPathComponent
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        if resolvedParent != parent {
            let resolved = Paths.join(resolvedParent, (path as NSString).lastPathComponent)
            if case .denied(let why) = Denylist(home: home, protectedRoots: protectedRoots).checkResolved(resolved) {
                return .denied(String(localized: "A symbolic link leads to a protected location: \(why)", bundle: .scannerKit))
            }
        }
        return .allowed
    }

    private func checkResolved(_ path: String) -> Verdict {
        if exactPaths.contains(path) { return .denied(String(localized: "Protected folder", bundle: .scannerKit)) }
        if forbiddenSubtrees.contains(where: { Paths.isWithin(path, $0) }) { return .denied(String(localized: "Protected area", bundle: .scannerKit)) }
        if path.split(separator: "/").contains(where: { $0 == ".git" }) { return .denied(String(localized: "Git repository", bundle: .scannerKit)) }
        guard allowedRoots.contains(where: { Paths.isWithin(path, $0) }) else { return .denied(String(localized: "Outside the allowed area", bundle: .scannerKit)) }
        return .allowed
    }
}
