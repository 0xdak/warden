import Foundation

public enum SecretKind: String, Sendable {
    case env, ssh, cloud, tokens, keys, keychain, browser, history

    public var ruleId: String { "secret.\(rawValue)" }
}

/// Classifies paths as secret stores or as configuration that keeps the guard itself in place.
public enum SecretPaths {
    static let envAllowlist: Set<String> = [".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults"]
    static let tokenFiles: Set<String> = [".npmrc", ".pypirc", ".netrc", ".git-credentials", ".pgpass", ".my.cnf", ".s3cfg",
                                          ".vault-token"]
    /// Unambiguous "this file is a secret store" names (kept short on purpose: false positives make people turn
    /// guards off).
    static let secretStoreNames: Set<String> = ["secrets.json", "secrets.yml", "secrets.yaml", "secrets.toml", ".secrets"]
    static let sshKeyNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk"]
    static let keyExtensions: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "ppk", "p8"]
    static let historyFiles: Set<String> = [".bash_history", ".zsh_history", ".sh_history", ".python_history",
                                            ".node_repl_history", ".psql_history", ".mysql_history", ".sqlite_history",
                                            ".lesshst", ".irb_history", "fish_history", ".rediscli_history"]
    static let browserMarkers = ["/Library/Application Support/Google/Chrome", "/Library/Application Support/BraveSoftware",
                                 "/Library/Application Support/Microsoft Edge", "/Library/Application Support/Arc/User Data",
                                 "/Library/Application Support/Firefox/Profiles", "/Library/Application Support/Vivaldi",
                                 "/Library/Application Support/com.operasoftware", "/Library/Safari", "/Library/Cookies",
                                 "/Library/Containers/com.apple.Safari"]

    /// `path` should be absolute and normalized (see `Paths.normalize`). Globs like `~/.ssh/*` work too.
    public static func classify(_ path: String) -> (SecretKind, String)? {
        let comps = Set(path.split(separator: "/").suffix(12).map(String.init))   // folder names (sets: one hash each)
        guard let baseSub = path.split(separator: "/").last else { return nil }
        let base = String(baseSub)
        let lower = base.lowercased()

        if comps.contains(".ssh") { return (.ssh, "SSH keys and config (~/.ssh)") }
        if sshKeyNames.contains(lower) {
            return (.ssh, "an SSH private key")
        }
        if comps.contains(".aws") { return (.cloud, "AWS credentials (~/.aws)") }
        if comps.contains(".azure") { return (.cloud, "Azure credentials (~/.azure)") }
        if path.fastContains("/.config/gcloud") { return (.cloud, "Google Cloud credentials (~/.config/gcloud)") }
        if comps.contains(".kube"), lower == "config" || base != ".kube" { return (.cloud, "Kubernetes credentials (~/.kube)") }
        if comps.contains(".docker"), lower == "config.json" { return (.cloud, "Docker registry credentials") }
        if comps.contains(".gnupg") { return (.tokens, "GPG keys (~/.gnupg)") }
        if lower == "hosts.yml", path.hasSuffix("/.config/gh/hosts.yml") {
            return (.tokens, "the GitHub CLI token (~/.config/gh/hosts.yml)")
        }
        if tokenFiles.contains(lower) { return (.tokens, "a credentials file (\(base))") }

        if !envAllowlist.contains(lower) {
            if lower == ".env" || lower == ".envrc" || lower.hasPrefix(".env.") || lower.hasPrefix(".env*")
                || (lower.hasSuffix(".env") && lower.count > 4) {
                return (.env, "an environment file (\(base)) that usually holds API keys and passwords")
            }
        }

        if path.fastContains("/Library/Keychains") || lower.hasSuffix(".keychain-db") || lower.hasSuffix(".keychain") {
            return (.keychain, "the macOS Keychain")
        }
        if path.fastContains("/Library/") {
            for m in browserMarkers where path.fastContains(m) { return (.browser, "a browser profile (cookies, saved logins)") }
        }
        if historyFiles.contains(lower) || comps.contains(".zsh_sessions") { return (.history, "shell history") }

        let ext = (lower as NSString).pathExtension
        if keyExtensions.contains(ext) { return (.keys, "a private key or certificate file (\(base))") }
        if ext == "tfstate" || lower.hasSuffix(".tfstate.backup") {
            return (.keys, "Terraform state (\(base)), which stores secrets in plain text")
        }
        if ext == "tfvars" || lower.hasSuffix(".tfvars.json") { return (.keys, "Terraform variables (\(base)), which often hold secrets") }
        if secretStoreNames.contains(lower) { return (.keys, "a secrets file (\(base))") }
        if (lower.hasPrefix("credentials") || lower.hasPrefix("client_secret") || lower.hasPrefix("service-account"))
            && ext == "json" {
            return (.keys, "a credentials file (\(base))")
        }
        return nil
    }

    /// Agent hook configs and the guard's own folder: editing these can switch protection off.
    public static func isGuardConfig(_ path: String) -> Bool {
        let (exact, prefixes) = guardConfigLists()
        if exact.contains(path) { return true }
        for p in prefixes where path == p || path.hasPrefix(p + "/") { return true }
        for s in projectSuffixes where path.hasSuffix(s) { return true }
        return false
    }

    static let projectSuffixes = ["/.claude/settings.json", "/.claude/settings.local.json", "/.cursor/hooks.json",
                                  "/.codex/hooks.json", "/.codex/config.toml", "/.gemini/settings.json", "/.windsurf/hooks.json"]

    nonisolated(unsafe) private static var guardCache: (String, Set<String>, [String])?
    /// Built once per home (this runs once per path candidate, so it has to be cheap).
    static func guardConfigLists() -> (Set<String>, [String]) {
        let h = Paths.home
        if let c = guardCache, c.0 == h { return (c.1, c.2) }
        let exact: Set<String> = [
            "\(h)/.claude/settings.json", "\(h)/.claude/settings.local.json",
            "\(h)/.codex/config.toml", "\(h)/.codex/hooks.json", "\(h)/.cursor/hooks.json",
            "\(h)/.gemini/settings.json", "\(h)/.codeium/windsurf/hooks.json",
            "/Library/Application Support/Cursor/hooks.json", "/etc/gemini-cli/settings.json",
            "/Library/Application Support/ClaudeCode/managed-settings.json",
        ]
        let prefixes = [Paths.support, "\(h)/Documents/Cline/Hooks"]
        guardCache = (h, exact, prefixes)
        return (exact, prefixes)
    }

    /// Shell startup files: a line appended here runs in every future terminal (persistence).
    public static func isShellStartup(_ path: String) -> Bool {
        let h = Paths.home
        guard path.hasPrefix(h + "/") else { return false }
        let rel = String(path.dropFirst(h.count + 1))
        return shellStartupFiles.contains(rel)
    }
    static let shellStartupFiles: Set<String> = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile",
                                                 ".bash_login", ".profile", ".kshrc", ".config/fish/config.fish"]

    /// Basenames that stand for each secret kind. Used to decide whether a glob or a path with unknown parts
    /// (`.e*`, `${x}nv`) could plausibly hit a secret file.
    static let sampleSecretNames = [".env", ".env.local", ".env.production", ".envrc", "id_rsa", "id_ed25519", "id_ecdsa",
                                    "credentials", "credentials.json", "client_secret.json", "service-account.json",
                                    "server.pem", "server.key", "cert.p12", ".npmrc", ".pypirc", ".netrc", ".git-credentials",
                                    ".pgpass", ".my.cnf", ".vault-token", "terraform.tfstate", "prod.tfvars", "secrets.json",
                                    ".zsh_history", ".bash_history", "login.keychain-db"]

    /// True when a glob-ish last path component (`*`, `?`, `[…]`) could match a secret file name. A component
    /// that is only wildcards (`*`) doesn't count: that would flag every `cat $f`.
    public static func globCouldMatchSecret(_ pattern: String) -> Bool {
        let comps = pattern.split(separator: "/").map(String.init)
        for c in comps where [".ssh", ".aws", ".gnupg", ".azure", ".kube", "Keychains"].contains(c) { return true }
        guard let last = comps.last else { return false }
        if last.allSatisfy({ "*?".contains($0) }) { return false }
        for n in sampleSecretNames where fnmatch(last, n, 0) == 0 || fnmatch(last.lowercased(), n, 0) == 0 { return true }
        return false
    }
}

extension String {
    /// Byte substring search (memmem). Foundation's `contains` walks Characters and dominated rule time on long paths.
    func fastContains(_ needle: String) -> Bool {
        var h = self, n = needle
        return h.withUTF8 { hb in
            n.withUTF8 { nb in
                guard nb.count > 0 else { return true }
                guard hb.count >= nb.count, let hp = hb.baseAddress, let np = nb.baseAddress else { return false }
                return memmem(hp, hb.count, np, nb.count) != nil
            }
        }
    }
}
