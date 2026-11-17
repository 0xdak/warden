import Foundation

/// Helpers for shell rules: variable / `cd` tracking, glob expansion, deletion targets, interpreter one-liners.
extension RuleEngine {

    // MARK: Limits (H8: oversized input must not time the hook out, which agents treat as "allow")

    /// Hook input bigger than this isn't analysed; the call is sent to a person instead.
    public static let maxInputBytes = 1_000_000
    public static let maxCommandBytes = 100_000
    public static let maxCommandWords = 20_000

    // MARK: Program sets

    /// Programs whose operands are names, not file contents: listing a folder or echoing a word isn't a secret read.
    static let nonReading: Set<String> = ["ls", "tree", "du", "exa", "eza", "lsd", "stat", "echo", "printf", "cd", "pushd",
                                          "mkdir", "test", "[", "[[", "which", "type", "basename", "dirname", "readlink",
                                          "realpath", "true", "false", ":"]
    static let deleters: Set<String> = ["rm", "srm", "trash", "trash-put", "unlink", "shred", "gio"]
    static let interpreterEval: [String: Set<String>] = [
        "python": ["-c"], "python3": ["-c"], "python2": ["-c"], "pypy3": ["-c"],
        "node": ["-e", "--eval", "-p", "--print"], "deno": ["eval"], "bun": ["-e", "--eval"],
        "ruby": ["-e"], "perl": ["-e", "-E"], "php": ["-r"], "osascript": ["-e"],
    ]
    static let dbClients: Set<String> = ["psql", "mysql", "mariadb", "sqlite3", "sqlcmd", "cockroach", "clickhouse-client",
                                         "clickhouse", "duckdb", "pgcli", "mycli", "snowsql", "bq"]
    static let secretSearchPattern = try! NSRegularExpression(
        pattern: #"(?i)(secret|token|passw|api[_-]?key|access[_-]?key|private[_-]?key|BEGIN [A-Z ]*PRIVATE|AKIA|credential)"#)
    static let dropPattern = try! NSRegularExpression(pattern: #"(?i)\bDROP\s+(TABLE|DATABASE|SCHEMA)\b"#)
    static let metadataHosts = ["169.254.169.254", "169.254.170.2", "metadata.google.internal", "fd00:ec2::254",
                                "100.100.100.200"]

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Variables

    /// A word after `$VAR` / `${VAR}` / `$(pwd)` expansion. `pattern` has `*` where something couldn't be resolved.
    struct Expanded { var text: String; var resolved: Bool; var pattern: String; var unknown: [String] }

    static func expand(_ w: String, vars: [String: String], cwd: String?) -> Expanded {
        guard w.contains("$") || w.contains("`") else { return Expanded(text: w, resolved: true, pattern: w, unknown: []) }
        let c = Array(w)
        var text = "", pattern = "", unknown: [String] = []
        var i = 0
        func lookup(_ name: String) -> String? {
            if let v = vars[name] { return v }
            switch name {
            case "HOME": return Paths.home
            case "PWD": return cwd
            case "TMPDIR": return ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
            default: return nil
            }
        }
        func put(_ v: String?, _ label: String) {
            if let v { text += v; pattern += v } else { pattern += "*"; unknown.append(label) }
        }
        while i < c.count {
            let ch = c[i]
            if ch == "`" || (ch == "$" && i + 1 < c.count && c[i + 1] == "(") {
                let open = ch == "`" ? i + 1 : i + 2
                var j = open, depth = 1
                while j < c.count {
                    if ch == "`" { if c[j] == "`" { break } }
                    else if c[j] == "(" { depth += 1 }
                    else if c[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                let inner = String(c[open..<min(j, c.count)]).trimmingCharacters(in: .whitespaces)
                put(inner == "pwd" || inner == "pwd -P" || inner == "pwd -L" ? cwd : nil, ch == "`" ? "`\(inner)`" : "$(\(inner))")
                i = j + 1
                continue
            }
            if ch == "$", i + 1 < c.count {
                if c[i + 1] == "{", let close = c[(i + 2)...].firstIndex(of: "}") {
                    let body = String(c[(i + 2)..<close])
                    var name = body, fallback: String?
                    if let r = body.range(of: ":-") ?? body.range(of: "-") {
                        name = String(body[..<r.lowerBound]); fallback = String(body[r.upperBound...])
                    }
                    put(lookup(name) ?? fallback, "${\(body)}")
                    i = close + 1
                    continue
                }
                if c[i + 1].isLetter || c[i + 1] == "_" {
                    var j = i + 1
                    while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                    let name = String(c[(i + 1)..<j])
                    put(lookup(name), "$\(name)")
                    i = j
                    continue
                }
                if "0123456789@*#?$!-".contains(c[i + 1]) { put(nil, "$\(c[i + 1])"); i += 2; continue }
            }
            text.append(ch); pattern.append(ch); i += 1
        }
        return Expanded(text: text, resolved: unknown.isEmpty, pattern: pattern, unknown: unknown)
    }

    /// Records `NAME=value` (plain assignments and `export`/`local`/…). `d=$(mktemp -d)` counts as a temp folder.
    static func recordAssignments(_ c: ShellCommand, vars: inout [String: String], cwd: String?) {
        var words: [String] = []
        if c.argv.isEmpty { words = c.assigns }
        else if ["export", "local", "declare", "typeset", "readonly"].contains(c.name) {
            words = c.args.filter { !$0.hasPrefix("-") && ShellLexer.isAssignment($0) }
        }
        for w in words {
            guard let eq = w.firstIndex(of: "=") else { continue }
            let name = String(w[..<eq]), value = String(w[w.index(after: eq)...])
            if value.hasPrefix("$(mktemp") || value.hasPrefix("`mktemp") {
                vars[name] = (NSTemporaryDirectory() as NSString).appendingPathComponent("mktemp.XXXXXX"); continue
            }
            let x = expand(value, vars: vars, cwd: cwd)
            if x.resolved { vars[name] = x.text } else { vars.removeValue(forKey: name) }
        }
    }

    /// New working folder after `cd X` / `pushd X`; nil = can't tell.
    static func cdTarget(_ c: ShellCommand, vars: [String: String], cwd: String?) -> String?? {
        guard c.name == "cd" || c.name == "pushd" || c.name == "popd" else { return .none }
        if c.name == "popd" { return .some(nil) }
        let ops = c.args.filter { !$0.hasPrefix("-") || $0 == "-" }
        guard let t = ops.first else { return .some(Paths.home) }
        if t == "-" { return .some(nil) }
        let x = expand(t, vars: vars, cwd: cwd)
        guard x.resolved else { return .some(nil) }
        if !x.text.hasPrefix("/") && !x.text.hasPrefix("~") && cwd == nil { return .some(nil) }
        return .some(Paths.normalize(x.text, cwd: cwd))
    }

    // MARK: Globs

    static func hasGlob(_ s: String) -> Bool { s.contains("*") || s.contains("?") || s.contains("[") }

    /// Expands an absolute glob on disk (like the shell would, dotfiles only for patterns starting with ".").
    /// nil = the folder part doesn't exist, so there was nothing to match against.
    static func diskGlob(_ pattern: String, limit: Int = 200) -> [String]? {
        var g = glob_t()
        defer { globfree(&g) }
        let rc = glob(pattern, GLOB_LIMIT, nil, &g)
        if rc != 0 {
            let dir = (pattern.prefix { $0 != "*" && $0 != "?" && $0 != "[" } as Substring)
            let parent = dir.hasSuffix("/") ? String(dir) : (String(dir) as NSString).deletingLastPathComponent
            return FileManager.default.fileExists(atPath: parent.isEmpty ? "/" : parent) ? [] : nil
        }
        var out: [String] = []
        for i in 0..<min(Int(g.gl_matchc), limit) {
            if let p = g.gl_pathv[i] { out.append(String(cString: p)) }
        }
        return out
    }

    // MARK: Interpreter one-liners

    /// The code string of `python -c CODE`, `node -e CODE`, `perl -ne CODE`, … if any.
    static func inlineCode(_ c: ShellCommand) -> String? {
        let base = c.name.lowercased()
        let key = interpreterEval.keys.first { base == $0 || (base.hasPrefix($0) && base.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }) }
        guard let k = key, let flags = interpreterEval[k] else { return nil }
        let a = c.args
        for (i, w) in a.enumerated() {
            if flags.contains(w), i + 1 < a.count { return a[i + 1] }
            // clusters: perl -ne / -pe / -lne, python -Ic
            if w.hasPrefix("-"), !w.hasPrefix("--"), w.count > 2, let last = w.last,
               flags.contains("-\(last)"), i + 1 < a.count { return a[i + 1] }
        }
        return nil
    }

    /// Path-looking string pieces of a code snippet (`open('.env')`, `'~/.ssh/id_rsa'`, `HOME+'/.aws/credentials'`).
    /// Dotted identifiers like `process.env` don't count: only pieces that start with `.`/`~`/`/`, contain a `/`,
    /// or are a well-known secret file name.
    static func codePaths(_ code: String) -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./~-*")
        var out: [String] = []
        for t in code.components(separatedBy: allowed.inverted) where !t.isEmpty && t.count < 300 {
            var tok = t
            while tok.hasSuffix(".") && tok.count > 1 { tok.removeLast() }
            let base = (tok as NSString).lastPathComponent.lowercased()
            if tok.hasPrefix(".") || tok.hasPrefix("~") || tok.contains("/")
                || SecretPaths.sampleSecretNames.contains(base) || SecretPaths.tokenFiles.contains(base) {
                if tok == "." || tok == ".." { continue }
                out.append(tok)
            }
        }
        return out
    }

    // MARK: Deletion

    struct DeleteContext {
        var cwd: String?          // effective working folder (after `cd`), nil = unknown
        var vars: [String: String]
        let origCwd: String       // resolved
        let project: String       // resolved
    }

    enum DeleteScope { case full, filtered }

    static func isUnder(_ p: String, _ root: String) -> Bool { root == "/" ? p != "/" : p.hasPrefix(root + "/") }

    static func tempRootsResolved() -> [String] {
        var r = tempRoots()
        for t in r { let x = Paths.resolve(t); if !r.contains(x) { r.append(x) } }
        return r
    }

    /// Decides one deletion target. `raw` is the word as written; the reason always shows the resolved absolute path.
    static func deletionHit(_ raw: String, recursive: Bool, scope: DeleteScope = .full, verb: String = "deletes",
                            ctx: DeleteContext) -> Hit? {
        let x = expand(raw, vars: ctx.vars, cwd: ctx.cwd)
        guard x.resolved else {
            guard recursive else { return nil }
            return Hit(ruleId: "cmd.rm-outside",
                       reason: "\(verb) “\(raw)”, a path built from \(x.unknown.joined(separator: ", ")) that can't be checked before it runs")
        }
        var text = x.text
        if text.isEmpty { return nil }
        let isAbs = text.hasPrefix("/") || text.hasPrefix("~")
        guard isAbs || ctx.cwd != nil else {
            guard recursive else { return nil }
            return Hit(ruleId: "cmd.rm-outside", reason: "\(verb) “\(raw)” after a `cd` into a folder that can't be determined")
        }
        // `dir/*`, `*`, `.*`: the deletion covers everything in `dir`.
        var contents = false
        if hasGlob(text) {
            let comps = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let last = comps.last, comps.dropLast().allSatisfy({ !hasGlob($0) }),
               last.allSatisfy({ "*.?".contains($0) }), last.contains("*") || last.contains("?") {
                contents = true
                text = comps.dropLast().joined(separator: "/")
                if text.isEmpty { text = raw.hasPrefix("/") ? "/" : "." }
            }
        }
        let trailingSlash = text.hasSuffix("/") || text == "." || text == ".." || text.hasSuffix("/.") || text.hasSuffix("/..")
        let abs = Paths.normalize(text, cwd: ctx.cwd)
        let p = Paths.resolve(abs, keepLast: !(trailingSlash || contents))
        let shown = p == Paths.home ? "\(p) (your home folder)" : p
        let what = contents ? "everything in \(shown)" : shown
        let filtered = scope == .filtered

        if isCriticalTarget(p) {
            if filtered { return Hit(ruleId: "cmd.rm-outside", reason: "\(verb) matching files anywhere under \(shown)") }
            return Hit(ruleId: "cmd.rm-critical", reason: "\(verb) \(what)")
        }
        if recursive || contents {
            if p.hasSuffix("/.git") || p == "/.git" {
                if filtered { return nil }
                return Hit(ruleId: "cmd.rm-critical", reason: "\(verb) the git history at \(p)")
            }
            for root in [ctx.origCwd, ctx.project] where isUnder(root, p) {
                if filtered { return Hit(ruleId: "cmd.rm-outside", reason: "\(verb) matching files under \(p), which contains the current project") }
                return Hit(ruleId: "cmd.rm-critical", reason: "\(verb) \(what), which contains the current project (\(root))")
            }
            let cwdInsideProject = isUnder(ctx.origCwd, ctx.project)
            if !filtered, p == ctx.project || (p == ctx.origCwd && !cwdInsideProject) {
                return Hit(ruleId: "cmd.rm-project", reason: "\(verb) \(contents ? "everything in" : "the whole") project folder \(p)")
            }
        }
        let home = Paths.home
        let roots = [ctx.project, ctx.origCwd].filter { $0 != "/" && $0 != home && !$0.isEmpty }
        if roots.contains(where: { p == $0 || isUnder(p, $0) }) { return nil }
        if !isUnder(p, home), tempRootsResolved().contains(where: { isUnder(p, $0) }) { return nil }
        if filtered { return Hit(ruleId: "cmd.rm-outside", reason: "\(verb) matching files under \(p), outside the project") }
        return Hit(ruleId: "cmd.rm-outside", reason: "\(recursive ? "recursively " : "")\(verb) \(what), outside the project")
    }

    static func rmHits(_ c: ShellCommand, ctx: DeleteContext, pipelineFind: ShellCommand?) -> [Hit] {
        var recursive = c.hasFlag(short: "r", long: "recursive") || c.hasFlag(short: "R")
        if c.name == "trash" || c.name == "trash-put" || (c.name == "gio" && c.operands.first == "trash") { recursive = true }
        if c.name == "gio", c.operands.first != "trash" && c.operands.first != "remove" { return [] }
        var ops = c.operands
        if c.name == "gio" { ops = Array(ops.dropFirst()) }
        if c.viaXargs {
            if let f = pipelineFind { return findHits(f, ctx: ctx, forceDelete: true) }
            if recursive {
                return [Hit(ruleId: "cmd.rm-outside",
                            reason: "recursively deletes paths it reads from the previous command (xargs), which can't be checked in advance")]
            }
            return []
        }
        return ops.compactMap { deletionHit($0, recursive: recursive, ctx: ctx) }
    }

    /// `find ROOTS … -delete` / `-exec rm …`.
    static func findHits(_ c: ShellCommand, ctx: DeleteContext, forceDelete: Bool = false) -> [Hit] {
        let a = c.args
        let deletes = forceDelete || a.contains("-delete") || a.indices.contains { i in
            ["-exec", "-execdir", "-ok", "-okdir"].contains(a[i]) && i + 1 < a.count
                && deleters.contains((a[i + 1] as NSString).lastPathComponent)
        }
        guard deletes else { return [] }
        var roots: [String] = []
        var i = 0
        while i < a.count {
            let w = a[i]
            if ["-H", "-L", "-P", "-E", "-X", "-s", "-x", "-d"].contains(w) { i += 1; continue }
            if w == "-f", i + 1 < a.count { roots.append(a[i + 1]); i += 2; continue }
            if w.hasPrefix("-") || w == "(" || w == "!" { break }
            roots.append(w); i += 1
        }
        if roots.isEmpty { roots = ["."] }
        let filters: Set<String> = ["-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex", "-iregex",
                                    "-mtime", "-mmin", "-atime", "-amin", "-ctime", "-cmin", "-newer", "-size", "-empty",
                                    "-user", "-group", "-perm", "-lname", "-ilname", "-links", "-inum", "-samefile"]
        let scope: DeleteScope = a.contains(where: { filters.contains($0) }) ? .filtered : .full
        return roots.compactMap { deletionHit($0, recursive: true, scope: scope, ctx: ctx) }
    }

    /// `rsync --delete SRC DST`: files in DST that aren't in SRC get deleted.
    static func rsyncDeleteHits(_ c: ShellCommand, ctx: DeleteContext) -> [Hit] {
        guard c.flags.contains(where: { $0.hasPrefix("--del") }), let dst = c.operands.last, c.operands.count >= 2 else { return [] }
        if let colon = dst.firstIndex(of: ":"), colon != dst.startIndex, !dst.hasPrefix("/"), !dst.hasPrefix(".") { return [] }
        let d = dst.hasSuffix("/") ? dst : dst + "/"
        return deletionHit(d, recursive: true, verb: "syncs over (deleting extra files in)", ctx: ctx).map { [$0] } ?? []
    }

    /// 777, 666, 0777, 1777, a+rwx, o+w, ugo=rwx … (others get write access).
    static func worldWritable(_ mode: String) -> Bool {
        if !mode.isEmpty, mode.allSatisfy({ $0.isNumber }) {
            guard mode.count >= 3, let d = mode.last?.wholeNumberValue else { return false }
            return d & 2 != 0
        }
        for clause in mode.split(separator: ",") {
            let who = clause.prefix { "ugoa".contains($0) }
            guard who.contains("o") || who.contains("a") else { continue }
            let rest = clause.dropFirst(who.count)
            guard let op = rest.first, op == "+" || op == "=" else { continue }
            if rest.dropFirst().contains("w") { return true }
        }
        return false
    }

    // MARK: Writes to shell startup files

    /// Files a command writes to: redirects, `tee`, the destination of cp/mv/ln/install, `sed -i`/`perl -i` operands, `dd of=`.
    static func writeTargets(_ c: ShellCommand) -> [String] {
        var out = c.redirOut
        switch c.name {
        case "tee": out += c.operands
        case "cp", "mv", "ln", "install", "rsync", "ditto": if c.operands.count >= 2, let l = c.operands.last { out.append(l) }
        case "sed", "gsed", "perl", "ruby":
            if c.flags.contains(where: { $0.hasPrefix("-i") || $0 == "--in-place" || $0.hasPrefix("--in-place=")
                || (!$0.hasPrefix("--") && $0.contains("i") && c.name == "perl") }) { out += c.operands }
        case "dd": out += c.args.filter { $0.hasPrefix("of=") }.map { String($0.dropFirst(3)) }
        case "truncate": out += c.operands
        default: break
        }
        return out
    }

    // MARK: Recursive search for secrets (H5)

    /// True when `dir` directly contains a secret file (hidden ones only when the tool searches hidden files).
    static func folderHasSecret(_ dir: String, includeHidden: Bool) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return SecretPaths.classify(dir) != nil }
        if SecretPaths.classify(dir + "/x") != nil { return true }     // ~/.ssh, ~/.aws …
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        for n in names.prefix(2000) where includeHidden || !n.hasPrefix(".") {
            if SecretPaths.classify(dir + "/" + n) != nil { return true }
        }
        return false
    }

    static func searchHits(_ c: ShellCommand, cwd: String) -> [Hit] {
        let name = c.name
        let isGrep = ["grep", "egrep", "fgrep", "ggrep"].contains(name)
        let isRg = ["rg", "ag", "ack", "pt", "ugrep"].contains(name)
        guard isGrep || isRg else { return [] }
        var hits: [Hit] = []
        let a = c.args
        // --include=GLOB / -g GLOB / --glob GLOB
        for (i, w) in a.enumerated() {
            var g: String?
            for f in ["--include=", "--glob=", "--iglob="] where w.hasPrefix(f) { g = String(w.dropFirst(f.count)) }
            if ["--include", "-g", "--glob", "--iglob"].contains(w), i + 1 < a.count { g = a[i + 1] }
            if let g, !g.hasPrefix("!"), SecretPaths.globCouldMatchSecret(g) || SecretPaths.classify("/x/" + g) != nil {
                hits.append(Hit(ruleId: "secret.search", reason: "searches inside files matching “\(g)”, which can be secret files"))
            }
        }
        let recursive = isRg || c.hasFlag(short: "r", long: "recursive") || c.hasFlag(short: "R", long: "dereference-recursive")
        guard recursive else { return hits }
        var ops = c.operands
        var pattern: String?
        if let i = a.firstIndex(where: { $0 == "-e" || $0 == "--regexp" }), i + 1 < a.count { pattern = a[i + 1] }
        else if !ops.isEmpty { pattern = ops.removeFirst() }
        guard let pat = pattern, matches(secretSearchPattern, pat) else { return hits }
        let hidden = isGrep || c.flags.contains { $0 == "--hidden" || $0 == "-." || $0.hasPrefix("-u") || $0 == "--unrestricted" }
        let roots = ops.isEmpty ? ["."] : ops
        for r in roots {
            let p = Paths.normalize(r, cwd: cwd)
            if folderHasSecret(p, includeHidden: hidden) {
                hits.append(Hit(ruleId: "secret.search",
                                reason: "searches \(Paths.tildify(p)) for “\(pat)”, and that folder holds secret files"))
                break
            }
        }
        return hits
    }
}
