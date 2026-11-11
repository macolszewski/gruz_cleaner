import Darwin
import Foundation

/// Path helpers. Existence and type checks use `lstat`, so symlinks are never followed.
public enum Paths {
    public static var home: String { NSHomeDirectory() }

    /// Fixed for the life of the process, so it is read once.
    public static let userTempDir: String = confstrPath(_CS_DARWIN_USER_TEMP_DIR) ?? NSTemporaryDirectory()

    public static var userCacheDir: String? { confstrPath(_CS_DARWIN_USER_CACHE_DIR) }

    private static func confstrPath(_ name: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Expands `~` and `$TMPDIR` and normalizes the path.
    public static func expand(_ path: String, home: String = Paths.home) -> String {
        var p = path
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if p.hasPrefix("$TMPDIR") { p = userTempDir + p.dropFirst("$TMPDIR".count) }
        return normalize(p)
    }

    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Displays a path with the home directory shortened to `~`.
    public static func abbreviate(_ path: String) -> String {
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func isGlob(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    public static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        Darwin.fnmatch(pattern, name, 0) == 0
    }

    /// Expands a path pattern whose components may contain globs. Hidden entries match only patterns
    /// that start with a dot. Results are sorted.
    ///
    /// Below a removal root (home, the temporary folders, the Android SDK) a match is dropped when one of
    /// its ancestors is a symbolic link: `~/.npm/_npx -> ~/code/app/src` must not turn source files into
    /// "npx cache". The match itself may be a link; moving a link to the Trash never touches its target,
    /// but a command that cleans a folder follows it, so `CleaningExecutor` refuses that case.
    public static func glob(_ pattern: String, home: String = Paths.home) -> [String] {
        globReporting(pattern, home: home).matches
    }

    public struct GlobResult: Sendable {
        public var matches: [String] = []
        /// Folders the expansion could not look into (no permission, I/O error), so matches may be missing.
        public var unreadable: [String] = []
    }

    /// `glob` that also says where it could not look, so "nothing there" and "could not check" stay apart.
    public static func globReporting(_ pattern: String, home: String = Paths.home) -> GlobResult {
        let expanded = expand(pattern, home: home)
        let components = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var result = GlobResult()
        var current = ["/"]
        for component in components {
            var next: [String] = []
            for base in current {
                if isGlob(component) {
                    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
                        if isDirectory(base) { result.unreadable.append(base) }
                        continue
                    }
                    for entry in entries.sorted() where fnmatch(component, entry) {
                        if entry.hasPrefix(".") && !component.hasPrefix(".") { continue }
                        next.append(join(base, entry))
                    }
                } else {
                    let candidate = join(base, component)
                    var st = stat()
                    if lstat(candidate, &st) == 0 {
                        next.append(candidate)
                    } else if errno != ENOENT && errno != ENOTDIR {
                        result.unreadable.append(base)
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        guard !components.isEmpty else { return result }
        result.matches = current.filter { !hasSymlinkedAncestor($0, home: home) }
        return result
    }

    /// Folders under which removal may happen at all (see `Denylist`).
    public static func removalRoots(home: String) -> [String] {
        [home, "/private/var/folders", "/var/folders", "/opt/homebrew/share/android-commandlinetools"]
    }

    /// The folder below which every path component must be a real directory: the deepest removal root
    /// that contains `path`, or nil for other locations. Symlinks above it (such as `/var`) are system ones.
    static func trustedAnchor(of path: String, home: String) -> String? {
        removalRoots(home: home).filter { path != $0 && isWithin(path, $0) }.max { $0.count < $1.count }
    }

    /// True when a component between the trusted anchor and `path` (exclusive) is a symbolic link.
    public static func hasSymlinkedAncestor(_ path: String, home: String = Paths.home) -> Bool {
        guard let anchor = trustedAnchor(of: path, home: home) else { return false }
        return ancestors(of: path).prefix { $0 != anchor && isWithin($0, anchor) }.contains(where: isSymlink)
    }

    /// Proper ancestors of an absolute path, nearest first, ending with "/".
    public static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var p = path
        while true {
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return result }
            result.append(parent)
            p = parent
        }
    }

    public static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    /// `lstat`-based existence check (a dangling symlink still exists).
    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// True when `path` equals `ancestor` or lies inside it.
    public static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        if ancestor == "/" { return true }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }
}
