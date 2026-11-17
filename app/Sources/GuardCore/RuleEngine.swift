import Foundation

/// Pure rule evaluation: event + settings → matches (with the effective action for the active preset).
public enum RuleEngine {
    struct Hit { var ruleId: String; var reason: String }

    static let networkTools: Set<String> = ["curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "scp", "rsync",
                                            "sftp", "ftp", "ssh", "http", "https", "xh", "rclone", "gsutil", "aws", "ftp"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    static let interpreters: Set<String> = ["python", "python3", "perl", "ruby", "node", "php", "osascript"]
    static let readOnlyTools: Set<String> = ["cat", "less", "more", "head", "tail", "grep", "rg", "ag", "jq", "wc", "ls",
                                             "stat", "file", "diff", "bat", "cmp", "md5", "shasum", "plutil", "open", "code"]
    static let bypassFlags: Set<String> = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                                           "--dangerously-bypass-approvals-and-sandbox", "--yolo"]

    public static func evaluate(_ e: ActionEvent, settings: GuardSettings) -> [RuleMatch] {
        // H8: never spend unbounded time on one call (an agent's hook timeout counts as "allow").
        if let n = e.inputBytes, n > maxInputBytes {
            return oversize("the request is \(n / 1024) KB, too large to check automatically", settings)
        }
        if let cmd = e.command, cmd.utf8.count > maxCommandBytes {
            return oversize("the command is \(cmd.utf8.count / 1024) KB long, too long to check automatically", settings)
        }

        var hits: [Hit] = []
        let listing = ["ls", "list_directory", "list_dir", "list_files"].contains(e.tool.lowercased())
        switch e.kind {
        case .shell:
            if let cmd = e.command {
                let parsed = ShellLexer.parse(cmd)
                if parsed.allWords.count > maxCommandWords {
                    return oversize("the command has \(parsed.allWords.count) words, too many to check automatically", settings)
                }
                hits += shellHits(parsed, event: e)
            }
        case .read, .search:
            for p in e.paths {
                let n = Paths.normalize(p, cwd: e.cwd)
                // F1: listing a folder (names only) isn't reading the secrets in it.
                hits += resolvingPathHits(n, writing: false).filter { !(listing && $0.ruleId.hasPrefix("secret.")) }
            }
            if e.kind == .search { hits += toolSearchHits(e) }
        case .write:
            for p in e.paths {
                let n = Paths.normalize(p, cwd: e.cwd)
                hits += resolvingPathHits(n, writing: true)
                for t in [n] + [Paths.symlinkTarget(n)].compactMap({ $0 }) where SecretPaths.isShellStartup(t) {
                    hits.append(Hit(ruleId: "system.shell-rc", reason: "changes \(Paths.tildify(t)), which runs in every new terminal"))
                }
            }
            if let c = e.content, c.contains("disableAllHooks") {
                hits.append(Hit(ruleId: "guard.tamper", reason: "the change turns off agent hooks (disableAllHooks)"))
            }
        case .mcp, .web:
            for p in e.paths { hits += resolvingPathHits(Paths.normalize(p, cwd: e.cwd), writing: false) }
            if let u = e.url?.lowercased(), let h = metadataHosts.first(where: { u.contains($0) }) {
                hits.append(Hit(ruleId: "secret.metadata", reason: "fetches the cloud metadata service (\(h)), which hands out cloud credentials"))
            }
        default:
            break
        }

        var matches: [RuleMatch] = []
        var seen = Set<String>()
        for h in hits where !seen.contains(h.ruleId) {
            seen.insert(h.ruleId)
            guard let rule = RuleCatalog.byId[h.ruleId] else { continue }
            let action = settings.ruleOverrides[rule.id] ?? rule.action(for: settings.preset)
            if action == .off { continue }
            matches.append(RuleMatch(ruleId: rule.id, ruleName: rule.name, category: rule.category.rawValue,
                                     severity: rule.severity, action: action, reason: h.reason))
        }
        matches += customMatches(e, rules: settings.customRules)
        return matches.sorted { ($0.action, $0.severity) > ($1.action, $1.severity) }
    }

    static func oversize(_ why: String, _ settings: GuardSettings) -> [RuleMatch] {
        guard let rule = RuleCatalog.byId["guard.oversize"] else { return [] }
        let action = max(.ask, settings.ruleOverrides[rule.id] ?? rule.action(for: settings.preset))
        return [RuleMatch(ruleId: rule.id, ruleName: rule.name, category: rule.category.rawValue, severity: rule.severity,
                          action: action, reason: "can't be checked: \(why)")]
    }

    /// Grep / Glob tools (H5): a file filter like `.env*` or a secret-looking search over a folder that holds secrets.
    static func toolSearchHits(_ e: ActionEvent) -> [Hit] {
        var hits: [Hit] = []
        for g in e.globs ?? [] where !g.hasPrefix("!") {
            if SecretPaths.globCouldMatchSecret(g) || SecretPaths.classify(Paths.normalize(g, cwd: e.cwd)) != nil {
                hits.append(Hit(ruleId: "secret.search", reason: "looks for files matching “\(g)”, which can be secret files"))
            }
        }
        if let pat = e.searchPattern, matches(secretSearchPattern, pat) {
            let roots = e.paths.isEmpty ? [e.cwd] : e.paths
            for r in roots where folderHasSecret(Paths.normalize(r, cwd: e.cwd), includeHidden: true) {
                hits.append(Hit(ruleId: "secret.search",
                                reason: "searches \(Paths.tildify(Paths.normalize(r, cwd: e.cwd))) for “\(pat)”, and that folder holds secret files"))
                break
            }
        }
        return hits
    }

    // MARK: Paths

    static func pathHits(_ path: String, writing: Bool, program: String? = nil) -> [Hit] {
        var out: [Hit] = []
        if let (kind, label) = SecretPaths.classify(path) {
            out.append(Hit(ruleId: kind.ruleId, reason: "\(writing ? "writes to" : "touches") \(label)"))
        }
        if SecretPaths.isGuardConfig(path) {
            let readOnly = program.map { readOnlyTools.contains($0) } ?? !writing
            if !readOnly {
                out.append(Hit(ruleId: "guard.tamper", reason: "changes \(Paths.tildify(path)), which controls agent hooks or the guard itself"))
            }
        }
        return out
    }

    /// `pathHits` on the path and, when it is a symlink (or sits under one), on its target too (H1).
    static func resolvingPathHits(_ path: String, writing: Bool, program: String? = nil, followLinks: Bool = true) -> [Hit] {
        var out = pathHits(path, writing: writing, program: program)
        if followLinks, let r = Paths.symlinkTarget(path) {
            out += pathHits(r, writing: writing, program: program).map {
                Hit(ruleId: $0.ruleId, reason: "\($0.reason) (through the symlink \(Paths.tildify(path)))")
            }
        }
        return out
    }

    /// Words of a command that could be paths: operands, `--flag=value` values, `@file` references, redirects.
    static func pathCandidates(_ c: ShellCommand) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func add(_ w: String, _ writing: Bool) {
            var w = w
            if w.hasPrefix("@") || w.hasPrefix("<") { w.removeFirst() }
            // `$(…)` words stay: `expand` resolves `$(pwd)/.env` and treats the rest as unknown parts.
            guard !w.isEmpty, !w.contains("://"), !w.hasPrefix("<("),
                  !(w.allSatisfy { $0.isNumber }) else { return }
            out.append((w, writing))
        }
        for a in c.args {
            if a.hasPrefix("-") {
                if let eq = a.firstIndex(of: "=") { add(String(a[a.index(after: eq)...]), false) }
                continue
            }
            if let eq = a.firstIndex(of: "="), a.firstIndex(of: "/") ?? a.endIndex > eq {
                add(String(a[a.index(after: eq)...]), false)   // key=@file / of=/dev/disk
            }
            add(a, false)
        }
        for r in c.redirOut { add(r, true) }
        for r in c.redirIn { add(r, false) }
        return out
    }

    // MARK: Shell

    static func shellHits(_ parsed: ParsedShell, event e: ActionEvent) -> [Hit] {
        let raw = parsed.raw
        var hits: [Hit] = []
        var secretSeen: String?
        var networkSeen = false
        var vars: [String: String] = [:]
        var cwd: String? = e.cwd               // effective folder after `cd` (nil = unknown)
        var downloads = Set<String>()          // files written by curl/wget earlier in this command line
        let origCwd = Paths.resolve(e.cwd)
        let project = Paths.resolve(e.project.isEmpty ? e.cwd : e.project)
        var checked = Set<String>()            // (program, word) pairs already looked at (long repetitive commands)
        var globBudget = 64                    // disk glob expansions per command line; past that, name patterns only

        // Per pipeline: earliest position of a downloader / decoder / find (keeps the pipe checks linear).
        var downloaderAt: [Int: Int] = [:], decoderAt: [Int: Int] = [:], findIn: [Int: ShellCommand] = [:]
        for c in parsed.commands {
            if ["curl", "wget", "fetch"].contains(c.name) { downloaderAt[c.pipeline] = min(downloaderAt[c.pipeline] ?? .max, c.position) }
            if isDecoder(c) { decoderAt[c.pipeline] = min(decoderAt[c.pipeline] ?? .max, c.position) }
            if c.name == "find", findIn[c.pipeline] == nil { findIn[c.pipeline] = c }
        }

        for c in parsed.commands {
            let name = c.name
            recordAssignments(c, vars: &vars, cwd: cwd)
            if networkTools.contains(name) { networkSeen = true }
            let wcwd = cwd ?? e.cwd
            let writes = !readOnlyTools.contains(name)
            // `find` only lists names unless it runs something or deletes.
            let listsOnly = nonReading.contains(name)
                || (name == "find" && !c.args.contains { ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fls"].contains($0) })

            for (cand, isRedirOut) in pathCandidates(c) {
                guard checked.insert("\(name)\u{0}\(isRedirOut)\u{0}\(cand)").inserted else { continue }
                let skipSecrets = listsOnly && !isRedirOut
                let program = isRedirOut ? "" : (writes ? name : "cat")
                let x = expand(cand, vars: vars, cwd: cwd)
                guard x.resolved else {
                    // H2: `cat ${x}nv`, `cat $(pwd)/.e*` … only when the known parts could still spell a secret file.
                    if !skipSecrets, SecretPaths.globCouldMatchSecret(x.pattern) {
                        hits.append(Hit(ruleId: "secret.indirect",
                                        reason: "reads “\(cand)”, a path built from \(x.unknown.joined(separator: ", ")) that could point at a secret file"))
                    }
                    continue
                }
                let p = Paths.normalize(x.text, cwd: wcwd)
                // `rm link` removes the link, not its target; deletions are judged by deletionHit.
                let isDeleter = deleters.contains(name) && !isRedirOut
                var found = resolvingPathHits(p, writing: isRedirOut, program: program, followLinks: !isDeleter)
                if hasGlob(x.text), !skipSecrets, !isDeleter {
                    // H2: `cat .e*`, `.[e]nv`, `.en?`, `cat .*` → expand on disk like the shell will.
                    globBudget -= 1
                    if globBudget >= 0, let ms = diskGlob(p) {
                        for m in ms {
                            found += resolvingPathHits(m, writing: isRedirOut, program: program).map {
                                Hit(ruleId: $0.ruleId, reason: "\($0.reason) (matched by “\(cand)”)")
                            }
                        }
                    } else if SecretPaths.globCouldMatchSecret(x.text) {   // folder missing, or past the budget
                        found.append(Hit(ruleId: "secret.indirect", reason: "reads “\(cand)”, a pattern that could match a secret file"))
                    }
                }
                if skipSecrets { found.removeAll { $0.ruleId.hasPrefix("secret.") } }
                for h in found where h.ruleId.hasPrefix("secret.") && h.ruleId != "secret.indirect" { secretSeen = secretSeen ?? Paths.tildify(p) }
                hits += found
            }

            // H2: python -c / node -e / ruby -e / perl -e code that names a secret path.
            if let code = inlineCode(c) {
                for t in codePaths(code) {
                    let p = Paths.normalize(t, cwd: wcwd)
                    for h in resolvingPathHits(p, writing: false, program: "cat") where h.ruleId.hasPrefix("secret.") {
                        hits.append(Hit(ruleId: h.ruleId, reason: "runs \(name) code that \(h.reason)"))
                        secretSeen = secretSeen ?? Paths.tildify(p)
                    }
                }
            }

            // Download-and-run (incl. H3: decoded text into a shell, download then execute)
            if shells.contains(name) || interpreters.contains(name) {
                if c.position > 0, let d = downloaderAt[c.pipeline], d < c.position {
                    hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "pipes a download straight into \(name)"))
                }
                if c.position > 0, let d = decoderAt[c.pipeline], d < c.position {
                    hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "decodes hidden text and runs it with \(name)"))
                }
                if c.args.contains(where: { $0.contains("$(curl") || $0.contains("$(wget") || $0.contains("`curl")
                    || $0.contains("`wget") || ($0.hasPrefix("<(") && ($0.contains("curl") || $0.contains("wget"))) }) {
                    hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "runs a downloaded script with \(name)"))
                }
            }
            if shells.contains(name) || name == "eval" {
                let subst = c.args.filter { $0.contains("$(") || $0.contains("`") || $0.hasPrefix("<(") }
                if subst.contains(where: { $0.contains("base64") || $0.contains("xxd") || $0.contains("openssl") && $0.contains("-d") }) {
                    hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "decodes hidden text and runs it with \(name)"))
                } else if name == "eval", subst.contains(where: { $0.contains("curl") || $0.contains("wget") }) {
                    hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "runs downloaded text with eval"))
                }
            }
            if name == "source" || name == "." , c.args.contains(where: { $0.hasPrefix("<(") && ($0.contains("curl") || $0.contains("wget")) }) {
                hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "sources a downloaded script"))
            }
            if !downloads.isEmpty {
                var runs: [String] = []
                if shells.contains(name) || interpreters.contains(name) || name == "source" || name == "." {
                    if let f = c.operands.first { runs.append(f) }
                }
                if let a0 = c.argv.first, a0.contains("/") { runs.append(a0) }
                for r in runs {
                    let p = Paths.normalize(r, cwd: wcwd)
                    if downloads.contains(p) {
                        hits.append(Hit(ruleId: "cmd.pipe-shell", reason: "downloads \(Paths.tildify(p)) and then runs it"))
                    }
                }
            }
            for d in downloadedFiles(c) { downloads.insert(Paths.normalize(d, cwd: wcwd)) }

            let dctx = DeleteContext(cwd: cwd, vars: vars, origCwd: origCwd, project: project)
            switch name {
            case _ where deleters.contains(name):
                hits += rmHits(c, ctx: dctx, pipelineFind: c.position > 0 ? findIn[c.pipeline] : nil)
            case "find":
                hits += findHits(c, ctx: dctx)
            case "scp", "rsync", "sftp":
                let remote = c.operands.contains { op in
                    guard let colon = op.firstIndex(of: ":"), !op.hasPrefix("/"), !op.hasPrefix(".") else { return false }
                    return colon != op.startIndex
                }
                if remote || name == "sftp" {
                    hits.append(Hit(ruleId: "exfil.remote-copy", reason: "copies files to or from a remote host with \(name)"))
                }
                if name == "rsync" { hits += rsyncDeleteHits(c, ctx: dctx) }
            case "dd":
                if c.args.contains(where: { $0.hasPrefix("of=/dev/") }) {
                    hits.append(Hit(ruleId: "cmd.disk", reason: "writes raw data to a disk device"))
                }
            case "diskutil":
                let sub = c.operands.first?.lowercased() ?? ""
                if ["erase", "partition", "zero", "random", "reformat", "delete"].contains(where: { sub.contains($0) })
                    || (sub == "apfs" && c.operands.dropFirst().first.map { $0.lowercased().contains("delete") || $0.lowercased().contains("erase") } == true) {
                    hits.append(Hit(ruleId: "cmd.disk", reason: "erases or repartitions a disk (diskutil \(c.operands.first ?? ""))"))
                }
            case "fdisk", "gpt", "newfs_apfs", "newfs_hfs":
                hits.append(Hit(ruleId: "cmd.disk", reason: "modifies disk partitions"))
            case "chmod":
                let ops = c.operands
                if let mode = ops.first, worldWritable(mode) {
                    let targets = ops.dropFirst().map { t -> String in
                        let x = expand(t, vars: vars, cwd: cwd)
                        return x.resolved ? Paths.normalize(x.text, cwd: wcwd) : t
                    }
                    let rec = c.hasFlag(short: "R", long: "recursive") ? ", recursively" : ""
                    hits.append(Hit(ruleId: "cmd.chmod-777",
                                    reason: "makes \(targets.isEmpty ? "files" : targets.joined(separator: ", ")) writable by everyone (\(mode)\(rec))"))
                }
            case "su":
                hits.append(Hit(ruleId: "cmd.sudo", reason: "switches to another user"))
            case "git":
                hits += gitHits(c, event: e)
            case "curl":
                let dataFlags: Set<String> = ["-d", "--data", "--data-binary", "--data-raw", "--data-urlencode", "--data-ascii",
                                              "-F", "--form", "--json", "-T", "--upload-file"]
                var uploads: [String] = []
                for (i, a) in c.argv.enumerated() {
                    var flag = a, value: String?
                    if let eq = a.firstIndex(of: "="), a.hasPrefix("--") { flag = String(a[..<eq]); value = String(a[a.index(after: eq)...]) }
                    else if i + 1 < c.argv.count { value = c.argv[i + 1] }
                    if a.hasPrefix("-d") && a.count > 2 && !a.hasPrefix("--") { flag = "-d"; value = String(a.dropFirst(2)) }
                    guard dataFlags.contains(flag), let v = value else { continue }
                    if flag == "-T" || flag == "--upload-file" { uploads.append(v); continue }
                    if v.hasPrefix("@") { uploads.append(String(v.dropFirst())) }
                    else if let r = v.range(of: "=@") ?? v.range(of: "=<") { uploads.append(String(v[r.upperBound...])) }
                }
                for u in uploads {
                    let p = Paths.normalize(u, cwd: wcwd)
                    if u != "-", SecretPaths.classify(p) != nil {
                        hits.append(Hit(ruleId: "exfil.secret", reason: "uploads \(Paths.tildify(p)) with curl"))
                    } else {
                        hits.append(Hit(ruleId: "exfil.upload", reason: "uploads \(u == "-" ? "piped data" : Paths.tildify(p)) with curl"))
                    }
                }
            case "wget":
                if let a = c.args.first(where: { $0.hasPrefix("--post-file") || $0.hasPrefix("--body-file") }) {
                    hits.append(Hit(ruleId: "exfil.upload", reason: "uploads a file with wget (\(a))"))
                }
            case "nc", "ncat", "netcat", "socat", "telnet":
                if !c.operands.isEmpty || name == "socat" {
                    hits.append(Hit(ruleId: "exfil.socket", reason: "opens a raw network connection with \(name)"))
                }
            case "env", "printenv":
                if c.operands.isEmpty { hits.append(Hit(ruleId: "env.dump", reason: "prints every environment variable (often includes tokens)")) }
            case "export":
                if c.args.isEmpty || c.args == ["-p"] { hits.append(Hit(ruleId: "env.dump", reason: "prints every exported variable")) }
            case "set":
                if c.args.isEmpty { hits.append(Hit(ruleId: "env.dump", reason: "prints every shell variable")) }
            case "declare", "typeset":
                if c.operands.isEmpty, c.flags.contains(where: { $0.contains("x") || $0.contains("p") }) {
                    hits.append(Hit(ruleId: "env.dump", reason: "prints exported variables"))
                }
            case "security":
                let sub = c.operands.first ?? ""
                if ["find-generic-password", "find-internet-password", "dump-keychain", "export", "find-certificate",
                    "unlock-keychain", "set-generic-password-partition-list"].contains(sub) {
                    hits.append(Hit(ruleId: "secret.keychain", reason: "reads the macOS Keychain (security \(sub))"))
                }
            case "kill", "pkill", "killall":
                if c.args.contains(where: { $0.lowercased().contains(Brand.appName.lowercased()) || $0.contains(Brand.hookBinaryName) }) {
                    hits.append(Hit(ruleId: "guard.tamper", reason: "tries to stop \(Brand.appName)"))
                }
            case "terraform", "tofu", "terragrunt", "pulumi":
                let sub = c.operands.first ?? ""
                if sub == "destroy" || (sub == "apply" && c.flags.contains { $0 == "-destroy" || $0 == "--destroy" }) {
                    hits.append(Hit(ruleId: "cmd.infra-destroy", reason: "destroys infrastructure (\(name) \(sub))"))
                }
            case "kubectl", "oc", "helm":
                let sub = c.operands.prefix(3)
                if sub.contains("delete") || (name == "helm" && sub.contains("uninstall")) {
                    hits.append(Hit(ruleId: "cmd.infra-destroy", reason: "deletes cluster resources (\(name) \(sub.contains("uninstall") ? "uninstall" : "delete"))"))
                }
            case "crontab":
                if c.hasFlag(short: "r") { hits.append(Hit(ruleId: "cmd.infra-destroy", reason: "removes every cron job of this user (crontab -r)")) }
            case "dropdb":
                hits.append(Hit(ruleId: "cmd.infra-destroy", reason: "drops a database (dropdb)"))
            case "docker", "podman", "nerdctl":
                if let h = dockerHostMount(c) {
                    hits.append(Hit(ruleId: "cmd.docker-host", reason: "starts a container with \(h) of this Mac mounted inside it"))
                }
            default:
                break
            }
            hits += searchHits(c, cwd: wcwd)

            // Writes to shell startup files (persistence)
            for t in writeTargets(c) {
                let x = expand(t, vars: vars, cwd: cwd)
                guard x.resolved else { continue }
                let p = Paths.normalize(x.text, cwd: wcwd)
                for q in [p] + [Paths.symlinkTarget(p)].compactMap({ $0 }) where SecretPaths.isShellStartup(q) {
                    hits.append(Hit(ruleId: "system.shell-rc", reason: "changes \(Paths.tildify(q)), which runs in every new terminal"))
                }
            }

            if c.viaSudo { hits.append(Hit(ruleId: "cmd.sudo", reason: "runs \(name.isEmpty ? "a command" : name) as administrator (sudo)")) }
            for r in c.redirOut where r.hasPrefix("/dev/disk") || r.hasPrefix("/dev/rdisk") {
                hits.append(Hit(ruleId: "cmd.disk", reason: "writes raw data to \(r)"))
            }
            if name.hasPrefix("mkfs") { hits.append(Hit(ruleId: "cmd.disk", reason: "formats a filesystem")) }

            if case .some(let next) = cdTarget(c, vars: vars, cwd: cwd) { cwd = next }
        }

        if parsed.commands.contains(where: { dbClients.contains($0.name) }), matches(dropPattern, raw) {
            hits.append(Hit(ruleId: "cmd.infra-destroy", reason: "drops a database table or schema (DROP …)"))
        }
        for w in parsed.allWords {
            if w.contains("/proc/") && w.contains("environ") {
                hits.append(Hit(ruleId: "env.dump", reason: "reads another process's environment"))
            }
            if bypassFlags.contains(w) || w == "--approval-mode=yolo" || w.contains("approval_policy=never")
                || w.contains("sandbox_mode=danger-full-access") || w == "danger-full-access" {
                hits.append(Hit(ruleId: "guard.bypass-flag", reason: "starts an agent with its safety prompts turned off (\(w))"))
            }
        }
        if let h = metadataHosts.first(where: { raw.contains($0) }) {
            hits.append(Hit(ruleId: "secret.metadata", reason: "contacts the cloud metadata service (\(h)), which hands out cloud credentials"))
        }
        if let i = parsed.allWords.firstIndex(of: "--approval-mode"), i + 1 < parsed.allWords.count, parsed.allWords[i + 1] == "yolo" {
            hits.append(Hit(ruleId: "guard.bypass-flag", reason: "starts an agent in yolo mode"))
        }
        if raw.contains("disableAllHooks") {
            hits.append(Hit(ruleId: "guard.tamper", reason: "turns off agent hooks (disableAllHooks)"))
        }
        if let s = secretSeen, networkSeen {
            hits.insert(Hit(ruleId: "exfil.secret", reason: "combines \(s) with a network tool in one command"), at: 0)
        }
        return hits
    }

    /// base64 -d / --decode / -D, openssl base64 -d, xxd -r, uudecode.
    static func isDecoder(_ c: ShellCommand) -> Bool {
        switch c.name {
        case "base64", "gbase64", "base32": return c.hasFlag(short: "d", long: "decode") || c.hasFlag(short: "D")
        case "openssl": return (c.operands.first == "base64" || c.operands.first == "enc") && c.flags.contains("-d")
        case "xxd": return c.hasFlag(short: "r")
        case "uudecode": return true
        default: return false
        }
    }

    /// Files `curl -o X` / `curl -O URL` / `wget -O X` / `wget URL` / `curl … > X` write.
    static func downloadedFiles(_ c: ShellCommand) -> [String] {
        guard ["curl", "wget"].contains(c.name) else { return [] }
        var out = c.redirOut
        let a = c.args
        let urls = c.operands.filter { $0.contains("://") }
        for (i, w) in a.enumerated() {
            if c.name == "curl" {
                if w == "-o" || w == "--output" || (w.hasPrefix("-") && !w.hasPrefix("--") && w.hasSuffix("o")), i + 1 < a.count { out.append(a[i + 1]) }
                if w.hasPrefix("--output=") { out.append(String(w.dropFirst(9))) }
                if w == "-O" || w == "--remote-name" || (w.hasPrefix("-") && !w.hasPrefix("--") && w.hasSuffix("O")) {
                    out += urls.map { (($0.split(separator: "?").first.map(String.init) ?? $0) as NSString).lastPathComponent }
                }
            } else {
                if w == "-O" || w == "--output-document", i + 1 < a.count { out.append(a[i + 1]) }
                if w.hasPrefix("--output-document=") { out.append(String(w.dropFirst(18))) }
            }
        }
        if c.name == "wget", !a.contains(where: { $0 == "-O" || $0.hasPrefix("--output-document") || $0 == "-qO-" }) {
            out += urls.map { (($0.split(separator: "?").first.map(String.init) ?? $0) as NSString).lastPathComponent }
        }
        return out.filter { $0 != "-" && !$0.isEmpty }
    }

    /// `docker run -v /:/host …`, `--volume=$HOME:/x`, `--mount type=bind,source=/,…` → what's mounted.
    static func dockerHostMount(_ c: ShellCommand) -> String? {
        guard c.operands.contains(where: { $0 == "run" || $0 == "create" }) else { return nil }
        let a = c.args
        var specs: [String] = []
        for (i, w) in a.enumerated() {
            if (w == "-v" || w == "--volume" || w == "--mount"), i + 1 < a.count { specs.append(a[i + 1]) }
            if w.hasPrefix("--volume=") || w.hasPrefix("--mount=") { specs.append(String(w[w.index(after: w.firstIndex(of: "=")!)...])) }
            if w.hasPrefix("-v"), w.count > 2, !w.hasPrefix("--") { specs.append(String(w.dropFirst(2))) }
        }
        for s in specs {
            var host = String(s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            if s.contains("source=") || s.contains("src=") {
                host = s.split(separator: ",").first { $0.hasPrefix("source=") || $0.hasPrefix("src=") }
                    .map { String($0.split(separator: "=", maxSplits: 1).last ?? "") } ?? ""
            }
            let p = Paths.normalize(host, cwd: "/")
            if host.hasPrefix("/") || host.hasPrefix("~") || host.hasPrefix("$HOME") {
                if p == "/" { return "the whole disk (/)" }
                if p == Paths.home { return "your home folder" }
                if p == "/Users" || p == "/var/run/docker.sock" || p == "/private/var/run/docker.sock" { return p }
            }
        }
        return nil
    }

    static func tempRoots() -> [String] {
        var r = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        let t = NSTemporaryDirectory()
        if !t.isEmpty { r.append(Paths.normalize(t, cwd: "/")) }
        return r
    }

    static func isCriticalTarget(_ p: String) -> Bool {
        let h = Paths.home
        if p == "/" || p == h { return true }
        if tempRoots().contains(p) { return true }                // /tmp itself, $TMPDIR itself
        let comps = p.split(separator: "/")
        if comps.count <= 1 { return true }                        // /Users, /System, /*, …
        if ["System", "Library", "Applications", "usr", "bin", "sbin", "etc", "var", "private", "opt", "Users", "Volumes", "cores"]
            .contains(String(comps[0])) && comps.count <= 2 && !p.hasPrefix(h + "/") {
            if !tempRoots().contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return true }
        }
        if p.hasPrefix(h + "/") {
            let rest = p.dropFirst(h.count + 1).split(separator: "/")
            if rest.count <= 1 { return true }                     // ~/Documents, ~/*, ~/.config
            if rest.count == 2 && rest[0] == "Library" { return true }
        }
        return false
    }

    static func gitHits(_ c: ShellCommand, event e: ActionEvent) -> [Hit] {
        var a = c.args
        var repoDir = e.cwd
        while let f = a.first, f.hasPrefix("-") {
            a.removeFirst()
            if (f == "-C"), let d = a.first { repoDir = Paths.normalize(d, cwd: e.cwd); a.removeFirst() }
            else if f == "-c", !a.isEmpty { a.removeFirst() }
        }
        guard let sub = a.first else { return [] }
        let rest = Array(a.dropFirst())
        let sc = ShellCommand(argv: ["git-\(sub)"] + rest, pipeline: 0, position: 0)
        var hits: [Hit] = []
        switch sub {
        case "push":
            let ops = sc.operands
            if sc.hasFlag(short: "f", long: "force") || sc.hasFlag(long: "force-with-lease") || sc.hasFlag(long: "mirror")
                || ops.dropFirst().contains(where: { $0.hasPrefix("+") }) {
                hits.append(Hit(ruleId: "git.force-push", reason: "force-pushes, which can overwrite history on the remote"))
            }
            let protected: Set<String> = ["main", "master"]
            let refspecs = Array(ops.dropFirst())
            let toMain = refspecs.contains { r in
                let dst = r.split(separator: ":").last.map(String.init) ?? r
                let clean = dst.hasPrefix("+") ? String(dst.dropFirst()) : dst
                return protected.contains(clean) || protected.contains(clean.replacingOccurrences(of: "refs/heads/", with: ""))
            }
            if toMain || (refspecs.isEmpty && currentBranch(repoDir).map { protected.contains($0) } == true) {
                hits.append(Hit(ruleId: "git.push-main", reason: "pushes directly to main/master"))
            }
        case "reset":
            if sc.hasFlag(long: "hard") { hits.append(Hit(ruleId: "git.reset-hard", reason: "discards uncommitted changes (git reset --hard)")) }
        case "clean":
            if sc.hasFlag(short: "f", long: "force"), sc.hasFlag(short: "d") || sc.hasFlag(short: "x") {
                hits.append(Hit(ruleId: "git.clean", reason: "deletes untracked files (git clean)"))
            }
        default:
            break
        }
        return hits
    }

    /// Reads .git/HEAD of the repo containing `dir` (no git process).
    static func currentBranch(_ dir: String) -> String? {
        let root = Paths.projectRoot(for: dir)
        let headPath = (root as NSString).appendingPathComponent(".git/HEAD")
        guard let s = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("ref: refs/heads/") else { return nil }
        return String(t.dropFirst("ref: refs/heads/".count))
    }

    // MARK: Custom rules

    static func customMatches(_ e: ActionEvent, rules: [CustomRule]) -> [RuleMatch] {
        var out: [RuleMatch] = []
        guard rules.contains(where: { $0.enabled && $0.action != .off }) else { return out }
        var paths = e.paths.map { Paths.normalize($0, cwd: e.cwd) }
        if e.kind == .shell, let cmd = e.command {
            for c in ShellLexer.parse(cmd).commands { paths += pathCandidates(c).map { Paths.normalize($0.0, cwd: e.cwd) } }
        }
        let text = e.target
        for r in rules where r.enabled && r.action != .off && (r.agents.isEmpty || r.agents.contains(e.agent)) {
            let p = r.pattern.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var hit = false
            switch r.kind {
            case .pathGlob:
                let pat = p.hasPrefix("~") || p.hasPrefix("/") ? Paths.normalize(p, cwd: "/") : p
                hit = paths.contains { path in
                    pat.contains("/") ? globMatch(pat, path) : globMatch(pat, (path as NSString).lastPathComponent)
                }
            case .commandPattern:
                hit = e.kind == .shell && text.range(of: p, options: .caseInsensitive) != nil
            case .regex:
                hit = (try? NSRegularExpression(pattern: p)).map {
                    $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                } ?? false
            }
            if hit {
                out.append(RuleMatch(ruleId: "custom.\(r.id)", ruleName: r.name, category: RuleCategory.custom.rawValue,
                                     severity: r.severity, action: r.action, reason: "matches your rule “\(r.name)”"))
            }
        }
        return out
    }

    /// fnmatch-style glob; `**` crosses folders.
    public static func globMatch(_ pattern: String, _ s: String) -> Bool {
        if pattern.contains("**") {
            var re = "^"
            var i = pattern.startIndex
            while i < pattern.endIndex {
                let ch = pattern[i]
                if ch == "*" {
                    let n = pattern.index(after: i)
                    if n < pattern.endIndex, pattern[n] == "*" { re += ".*"; i = pattern.index(after: n); continue }
                    re += "[^/]*"
                } else if ch == "?" { re += "[^/]" }
                else { re += NSRegularExpression.escapedPattern(for: String(ch)) }
                i = pattern.index(after: i)
            }
            re += "$"
            return s.range(of: re, options: .regularExpression) != nil
        }
        return fnmatch(pattern, s, 0) == 0
    }
}
