import Foundation

/// All filesystem locations. Every path derives from `home`, which tests (and careful developers)
/// override with WARDEN_HOME_OVERRIDE so nothing touches the real agent configs.
public enum Paths {
    /// Uses getenv(3): `ProcessInfo.environment` builds a whole dictionary per call, which dominated rule
    /// evaluation time on long commands (one lookup per path candidate).
    public static func env(_ name: String) -> String? {
        guard let c = getenv(Brand.envPrefix + name) else { return nil }
        let v = String(cString: c)
        return v.isEmpty ? nil : v
    }

    /// The real home directory of this user (ignores $HOME tricks).
    public static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Home used for agent configs, the support folder and `~` expansion.
    public static var home: String {
        let raw = env("HOME_OVERRIDE")
        if let c = homeCache, c.0 == raw { return c.1 }
        let h = clean(raw ?? realHome)
        homeCache = (raw, h)
        return h
    }
    nonisolated(unsafe) private static var homeCache: (String?, String)?

    /// Collapses "//" and trailing "/" (mktemp paths often contain "T//x").
    public static func clean(_ p: String) -> String {
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        return p.hasPrefix("/") ? "/" + parts.joined(separator: "/") : parts.joined(separator: "/")
    }

    /// ~/Library/Application Support/Warden (or WARDEN_SUPPORT_OVERRIDE).
    public static var support: String {
        env("SUPPORT_OVERRIDE") ?? (home as NSString).appendingPathComponent("Library/Application Support/\(Brand.supportFolderName)")
    }

    public static var socket: String { env("SOCKET_OVERRIDE") ?? (support as NSString).appendingPathComponent("guard.sock") }
    public static var settingsFile: String { (support as NSString).appendingPathComponent("settings.json") }
    public static var decisionsFile: String { (support as NSString).appendingPathComponent("decisions.json") }
    public static var installsFile: String { (support as NSString).appendingPathComponent("installs.json") }
    public static var eventsDir: String { (support as NSString).appendingPathComponent("events") }
    public static var backupsDir: String { (support as NSString).appendingPathComponent("backups") }
    public static var binDir: String { (support as NSString).appendingPathComponent("bin") }
    /// The stable hook path written into agent configs (Codex trust is tied to the hook definition's hash).
    public static var installedHook: String { (binDir as NSString).appendingPathComponent(Brand.hookBinaryName) }

    public static func ensureSupport() {
        let fm = FileManager.default
        for d in [support, eventsDir, backupsDir, binDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Expands ~, $HOME, ${HOME} and makes `p` absolute relative to `cwd`; collapses . and .. lexically.
    public static func normalize(_ raw: String, cwd: String?) -> String {
        var p = raw
        if p.hasPrefix("\"") || p.hasPrefix("'") { p = String(p.dropFirst()) }
        if p.hasSuffix("\"") || p.hasSuffix("'") { p = String(p.dropLast()) }
        for v in ["${HOME}", "$HOME"] where p.hasPrefix(v) { p = home + p.dropFirst(v.count) }
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        if !p.hasPrefix("/") {
            let base = (cwd?.isEmpty == false ? cwd! : FileManager.default.currentDirectoryPath)
            // Fast path (one call per word of every command): a plain relative name under an already clean base.
            if isPlainRelative(p), let nb = cleanBase(base) { return nb == "/" ? "/" + p : nb + "/" + p }
            p = (base as NSString).appendingPathComponent(p)
        }
        var out: [Substring] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    /// No "." / ".." components, no "//", no trailing "/".
    static func isPlainRelative(_ p: String) -> Bool {
        var prev: UInt8 = UInt8(ascii: "/"), dots = 0, ok = true
        for b in p.utf8 {
            if b == UInt8(ascii: "/") {
                if prev == UInt8(ascii: "/") || (dots > 0 && dots <= 2) { ok = false; break }
                dots = 0
            } else if b == UInt8(ascii: ".") && (prev == UInt8(ascii: "/") || dots > 0) {
                dots += 1
            } else { dots = -100 }
            prev = b
        }
        return ok && !p.isEmpty && prev != UInt8(ascii: "/") && !(dots > 0 && dots <= 2)
    }

    nonisolated(unsafe) private static var baseCache: (String, String)?
    /// `base` normalized once (the cwd is the same for every word of a command).
    static func cleanBase(_ base: String) -> String? {
        guard base.hasPrefix("/") else { return nil }
        if let c = baseCache, c.0 == base { return c.1 }
        let n = normalize(base, cwd: "/")
        baseCache = (base, n)
        return n
    }

    /// Nearest ancestor of `dir` containing `.git`, else `dir`.
    public static func projectRoot(for dir: String) -> String {
        guard !dir.isEmpty else { return dir }
        var cur = dir
        let fm = FileManager.default
        for _ in 0..<30 {
            if fm.fileExists(atPath: (cur as NSString).appendingPathComponent(".git")) { return cur }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur || parent.isEmpty { break }
            cur = parent
        }
        return dir
    }

    /// `p` with symlinks resolved (realpath of the longest existing prefix, the rest appended), mapped back so a
    /// path under the resolved home reads as `Paths.home/…`. `keepLast` resolves only the parent folder, which is
    /// what `rm link` acts on (it deletes the link, not its target).
    public static func resolve(_ p: String, keepLast: Bool = false) -> String {
        guard p.hasPrefix("/") else { return p }
        var head = p
        var tail: [String] = []
        if keepLast, p != "/" {
            tail.append((p as NSString).lastPathComponent)
            head = (p as NSString).deletingLastPathComponent
        }
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if realpath(head, &buf) != nil {
                var r = String(cString: buf)
                for t in tail.reversed() { r = r == "/" ? "/" + t : r + "/" + t }
                return unresolveHome(r)
            }
            if head == "/" || head.isEmpty { break }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return p
    }

    /// realpath(home) differs from `home` when home sits under a symlink (/var → /private/var in tests).
    static func unresolveHome(_ r: String) -> String {
        let h = home
        let rh = resolvedHome
        if rh != h {
            if r == rh { return h }
            if r.hasPrefix(rh + "/") { return h + r.dropFirst(rh.count) }
        }
        return r
    }

    nonisolated(unsafe) private static var resolvedHomeCache: (String, String)?
    static var resolvedHome: String {
        let h = home
        if let c = resolvedHomeCache, c.0 == h { return c.1 }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let r = realpath(h, &buf) != nil ? String(cString: buf) : h
        resolvedHomeCache = (h, r)
        return r
    }

    /// The symlink-resolved form of `p` when it differs in a way that matters (not just /tmp → /private/tmp).
    public static func symlinkTarget(_ p: String) -> String? {
        // One realpath call: a path that doesn't exist can't be read through a link.
        guard p.hasPrefix("/") else { return nil }
        var st = stat()
        guard stat(p, &st) == 0 else {                   // most command words aren't files: one syscall, done
            // A dangling link still matters for writes (writing through it creates the target).
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK else { return nil }
            var lb = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(p, &lb, Int(PATH_MAX))
            guard n > 0 else { return nil }
            let dest = String(decoding: lb[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let t = normalize(dest, cwd: (p as NSString).deletingLastPathComponent)
            return t == p ? nil : unresolveHome(resolve(t))
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(p, &buf) != nil else { return nil }
        let r = unresolveHome(String(cString: buf))
        if r == p || r == "/private" + p { return nil }
        return r
    }

    /// "~/code/app" for display.
    public static func tildify(_ p: String) -> String {
        let h = home
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }
}
