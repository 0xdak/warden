import Foundation

public enum RuleCategory: String, Codable, CaseIterable, Sendable {
    case secrets, destructive, git, exfiltration, system, selfProtection, custom
    public var title: String {
        switch self {
        case .secrets: "Secrets & credentials"
        case .destructive: "Destructive commands"
        case .git: "Git history"
        case .exfiltration: "Data leaving your Mac"
        case .system: "System & privileges"
        case .selfProtection: "Guard integrity"
        case .custom: "Your rules"
        }
    }
}

/// A rule shipped with the app. Detection logic lives in `RuleEngine`; this is the catalog the UI shows.
public struct BuiltinRule: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: RuleCategory
    public let severity: Severity
    public let summary: String
    /// Action under [strict, balanced, permissive].
    let defaults: (RuleAction, RuleAction, RuleAction)

    public func action(for preset: Preset) -> RuleAction {
        switch preset { case .strict: defaults.0; case .balanced: defaults.1; case .permissive: defaults.2 }
    }
}

public enum RuleCatalog {
    public static let all: [BuiltinRule] = [
        // Secrets
        .init(id: "secret.env", name: "Environment files", category: .secrets, severity: .high,
              summary: ".env, .env.local, .envrc… (.env.example and .env.sample are fine)", defaults: (.block, .block, .ask)),
        .init(id: "secret.ssh", name: "SSH keys", category: .secrets, severity: .critical,
              summary: "Anything in ~/.ssh and id_rsa / id_ed25519 style key files", defaults: (.block, .block, .block)),
        .init(id: "secret.cloud", name: "Cloud credentials", category: .secrets, severity: .critical,
              summary: "~/.aws, ~/.config/gcloud, ~/.azure, ~/.kube/config, ~/.docker/config.json", defaults: (.block, .block, .ask)),
        .init(id: "secret.tokens", name: "Token files", category: .secrets, severity: .high,
              summary: "~/.npmrc, ~/.pypirc, ~/.netrc, ~/.git-credentials, ~/.vault-token, ~/.config/gh/hosts.yml, ~/.gnupg", defaults: (.block, .block, .ask)),
        .init(id: "secret.keys", name: "Key & certificate files", category: .secrets, severity: .high,
              summary: "*.pem, *.key, *.p12, *.pfx, credentials*.json, secrets.json, *.tfstate, *.tfvars", defaults: (.block, .ask, .ask)),
        .init(id: "secret.keychain", name: "macOS Keychain", category: .secrets, severity: .critical,
              summary: "`security find-generic-password` and ~/Library/Keychains", defaults: (.block, .block, .block)),
        .init(id: "secret.browser", name: "Browser profiles", category: .secrets, severity: .high,
              summary: "Cookies and saved logins of Chrome, Safari, Firefox, Arc, Brave, Edge", defaults: (.block, .block, .ask)),
        .init(id: "secret.history", name: "Shell history", category: .secrets, severity: .medium,
              summary: "~/.zsh_history, ~/.bash_history and similar", defaults: (.block, .ask, .observe)),
        .init(id: "secret.indirect", name: "Hidden secret paths", category: .secrets, severity: .high,
              summary: "Paths built from variables or globs (cat ${x}nv, cat .e*) that could point at a secret file",
              defaults: (.block, .ask, .observe)),
        .init(id: "secret.search", name: "Searching for secrets", category: .secrets, severity: .medium,
              summary: "Grep/Glob for .env* files, or grep -r SECRET over a folder that holds secret files",
              defaults: (.ask, .ask, .observe)),
        .init(id: "secret.metadata", name: "Cloud metadata service", category: .secrets, severity: .critical,
              summary: "169.254.169.254 and similar endpoints that hand out cloud credentials", defaults: (.block, .block, .block)),
        // Destructive
        .init(id: "cmd.rm-critical", name: "Wipe home or system folders", category: .destructive, severity: .critical,
              summary: "rm / find -delete on /, ~, system folders, a parent of the project, or a .git folder", defaults: (.block, .block, .block)),
        .init(id: "cmd.rm-outside", name: "Delete outside the project", category: .destructive, severity: .high,
              summary: "rm, find -delete, rsync --delete on a path outside the project (temp folders are fine)", defaults: (.block, .ask, .observe)),
        .init(id: "cmd.rm-project", name: "Delete the whole project", category: .destructive, severity: .high,
              summary: "rm -rf . or rm -rf * at the project root, find . -delete", defaults: (.ask, .ask, .observe)),
        .init(id: "cmd.infra-destroy", name: "Destroy infrastructure or data", category: .destructive, severity: .high,
              summary: "terraform destroy, kubectl delete, helm uninstall, DROP TABLE/DATABASE, dropdb, crontab -r",
              defaults: (.block, .ask, .observe)),
        .init(id: "cmd.disk", name: "Disk erase & raw writes", category: .destructive, severity: .critical,
              summary: "dd to /dev, mkfs, diskutil erase/partition", defaults: (.block, .block, .ask)),
        .init(id: "cmd.pipe-shell", name: "Download and run", category: .system, severity: .high,
              summary: "curl | sh, base64 -d | sh, eval \"$(…)\", curl -o x && sh x", defaults: (.block, .ask, .ask)),
        .init(id: "cmd.chmod-777", name: "World-writable permissions", category: .system, severity: .medium,
              summary: "chmod 777, 666, a+rwx, o+w", defaults: (.block, .ask, .observe)),
        .init(id: "cmd.docker-host", name: "Container with host access", category: .system, severity: .high,
              summary: "docker run -v /:/host, a mount of your home folder or the Docker socket", defaults: (.block, .ask, .observe)),
        .init(id: "system.shell-rc", name: "Shell startup files", category: .system, severity: .medium,
              summary: "Writes to ~/.zshrc, ~/.bashrc, ~/.profile and similar (they run in every new terminal)",
              defaults: (.ask, .ask, .observe)),
        .init(id: "cmd.sudo", name: "Admin privileges", category: .system, severity: .high,
              summary: "sudo, su, doas", defaults: (.block, .ask, .observe)),
        .init(id: "env.dump", name: "Environment dump", category: .system, severity: .medium,
              summary: "env, printenv, export -p, /proc/*/environ", defaults: (.block, .ask, .observe)),
        // Git
        .init(id: "git.force-push", name: "Force push", category: .git, severity: .high,
              summary: "git push --force / -f / --force-with-lease / +refspec", defaults: (.block, .ask, .ask)),
        .init(id: "git.push-main", name: "Push to main", category: .git, severity: .medium,
              summary: "Pushing straight to main or master", defaults: (.ask, .ask, .observe)),
        .init(id: "git.reset-hard", name: "Hard reset", category: .git, severity: .medium,
              summary: "git reset --hard throws away uncommitted work", defaults: (.ask, .ask, .observe)),
        .init(id: "git.clean", name: "Clean untracked files", category: .git, severity: .medium,
              summary: "git clean -fd / -fdx deletes files git doesn't track", defaults: (.ask, .ask, .observe)),
        // Exfiltration
        .init(id: "exfil.secret", name: "Secret sent over the network", category: .exfiltration, severity: .critical,
              summary: "A secret file and a network tool in the same command", defaults: (.block, .block, .block)),
        .init(id: "exfil.upload", name: "File upload", category: .exfiltration, severity: .high,
              summary: "curl -d @file, --data-binary @…, -F x=@…, -T, wget --post-file", defaults: (.block, .ask, .ask)),
        .init(id: "exfil.socket", name: "Raw network socket", category: .exfiltration, severity: .high,
              summary: "nc, ncat, netcat, socat, telnet to a host", defaults: (.block, .ask, .observe)),
        .init(id: "exfil.remote-copy", name: "Copy to a remote host", category: .exfiltration, severity: .medium,
              summary: "scp, rsync or sftp to host:path", defaults: (.ask, .ask, .observe)),
        // Self-protection
        .init(id: "guard.tamper", name: "Changing agent hooks or guard settings", category: .selfProtection, severity: .critical,
              summary: "Edits to agent settings/hook files, the guard's folder, disableAllHooks, killing the guard",
              defaults: (.block, .block, .ask)),
        .init(id: "guard.bypass-flag", name: "Safety-off flags", category: .selfProtection, severity: .high,
              summary: "--dangerously-skip-permissions, --yolo, --dangerously-bypass-approvals-and-sandbox",
              defaults: (.block, .ask, .ask)),
        .init(id: "guard.oversize", name: "Too large to check", category: .selfProtection, severity: .medium,
              summary: "Commands over 100 KB or 20,000 words, or hook input over 1 MB, go to you instead of being analysed",
              defaults: (.ask, .ask, .ask)),
    ]

    public static let byId: [String: BuiltinRule] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Rules that pauses and exceptions never switch off (so an agent can't talk its way past the guard).
    public static let alwaysOn: Set<String> = ["guard.tamper"]
}
