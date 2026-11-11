import Foundation

/// Paths that must never be removed, regardless of what a rule says.
///
/// Checked for every candidate path during a scan, so the protected sets are built once in `init`.
public struct Denylist: Sendable {
    public let home: String
    /// User-configured project roots; the roots themselves are protected, their artifacts are not.
    public let protectedRoots: [String]
    private let exactPaths: Set<String>
    private let forbiddenSubtrees: [String]
    /// Roots under which removal may happen at all.
    private let allowedRoots: [String]
    private let preserved: [(pattern: String, fixedDir: String)]

    public init(home: String = Paths.home, protectedRoots: [String] = []) {
        let h = home
        self.home = h
        self.protectedRoots = protectedRoots.map { Paths.expand($0, home: h) }
        var exact: Set<String> = [
            "/", "/Applications", "/Library", "/Users", "/opt", "/opt/homebrew", "/private", "/private/var",
            "/private/var/folders", "/Volumes",
            h, "\(h)/Library", "\(h)/Library/Application Support", "\(h)/Library/Caches", "\(h)/Library/Containers",
            "\(h)/Library/Group Containers", "\(h)/Library/Logs", "\(h)/Library/Developer", "\(h)/Library/Preferences",
            "\(h)/Applications", "\(h)/.cache", "\(h)/.local", "\(h)/.local/share", "\(h)/.config",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/.Trash",
            Paths.userTempDir,
        ]
        exact.formUnion(ScanOptions.commonProjectRoots.map { Paths.expand($0, home: h) })
        exact.formUnion(self.protectedRoots)
        exactPaths = exact
        forbiddenSubtrees = [
            "/System", "/bin", "/sbin", "/usr", "/etc", "/private/etc", "/cores", "/dev",
            "\(h)/Library/Keychains", "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Photos",
            "\(h)/.ssh", "\(h)/.gnupg", "\(h)/Documents", "\(h)/Desktop", "\(h)/Pictures",
        ]
        allowedRoots = Paths.removalRoots(home: h)
        preserved = Self.preservedPatterns.map { pattern in
            let expanded = Paths.expand(pattern, home: h)
            let fixed = expanded.prefix { $0 != "*" && $0 != "?" && $0 != "[" }
            let fixedDir = fixed.hasSuffix("/") ? String(fixed.dropLast()) : (String(fixed) as NSString).deletingLastPathComponent
            return (expanded, fixedDir)
        }
    }

    /// Data kept inside otherwise disposable folders. A path is denied when it is one of these, lies
    /// inside one or contains one, so a broad cache rule cannot take it along with its parent.
    private static let preservedPatterns = [
        // JetBrains keeps Local History (recovery of deleted files and uncommitted changes) in its cache folder.
        "~/Library/Caches/JetBrains/*/LocalHistory",
        "~/Library/Caches/Google/AndroidStudio*/LocalHistory",
        // Hugging Face stores the login token next to its model cache.
        "~/.cache/huggingface/token",
        "~/.cache/huggingface/stored_tokens",
    ]

    private enum Preserved {
        case found(String)
        /// A folder that could hold preserved data cannot be read, so its absence is not proven.
        case unknown(String)
    }

    private func preservedLocation(insideOrAbove path: String) -> Preserved? {
        // Cheap prefix test first: only patterns that share the fixed part of the path need a file system check.
        for (pattern, fixedDir) in preserved where Paths.isWithin(path, fixedDir) || Paths.isWithin(fixedDir, path) {
            let result = Paths.globReporting(pattern, home: home)
            if let hit = result.matches.first(where: { Paths.isWithin(path, $0) || Paths.isWithin($0, path) }) {
                return .found(hit)
            }
            if let blind = result.unreadable.first(where: { Paths.isWithin($0, path) || Paths.isWithin(path, $0) }) {
                return .unknown(blind)
            }
        }
        return nil
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
        // A link inside the path would make a rule describe something it never saw (a cache folder that is
        // really a project's source folder), wherever the link points.
        if Paths.hasSymlinkedAncestor(path, home: home) {
            return .denied(String(localized: "A folder in the path is a symbolic link", bundle: .scannerKit))
        }
        switch preservedLocation(insideOrAbove: path) {
        case .found(let kept):
            return .denied(String(localized: "Contains data that cannot be recreated: \(Paths.abbreviate(kept))", bundle: .scannerKit))
        case .unknown(let blind):
            return .denied(String(localized: "Cannot check whether it holds data that cannot be recreated: \(Paths.abbreviate(blind)) is not readable", bundle: .scannerKit))
        case nil:
            break
        }
        // Resolve symlinks in parent components so a link cannot redirect removal elsewhere.
        let parent = (path as NSString).deletingLastPathComponent
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        if resolvedParent != parent {
            let resolved = Paths.join(resolvedParent, (path as NSString).lastPathComponent)
            if case .denied(let why) = checkResolved(resolved) {
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
