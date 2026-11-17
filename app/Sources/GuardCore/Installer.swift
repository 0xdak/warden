import Foundation

public struct InstallRecord: Codable, Sendable, Equatable {
    public var agent: Agent
    public var configPath: String
    /// Copy of the config taken right before our most recent write (nil if the file didn't exist).
    public var backupPath: String?
    /// Copy taken before our very first install.
    public var originalBackupPath: String?
    /// True when the config file didn't exist and we created it.
    public var createdFile: Bool
    public var installedAt: Date
    public var command: String
}

public struct InstallManifest: Codable, Sendable {
    public var records: [String: InstallRecord] = [:]
    public init() {}
    public static func load() -> InstallManifest { JSONFile.read(InstallManifest.self, at: Paths.installsFile) ?? InstallManifest() }
    public func save() throws { try JSONFile.write(self, to: Paths.installsFile) }
}

public enum InstallState: Equatable, Sendable {
    case notDetected
    case notInstalled
    case installed
    /// We installed it, but our entries are gone (edited by hand, by the agent, or by an update).
    case removed
    /// Our entries exist but the agent ignores hooks (disableAllHooks, feature flag off).
    case disabled(String)

    public var title: String {
        switch self {
        case .notDetected: "Not found"
        case .notInstalled: "Not protected"
        case .installed: "Protected"
        case .removed: "Hooks removed"
        case .disabled: "Hooks turned off"
        }
    }
}

public enum InstallError: LocalizedError, Equatable {
    case unreadableConfig(String)
    case foreignHookFile(String)
    case noBackup
    case hookBinaryMissing(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableConfig(let p):
            return "\(Paths.tildify(p)) isn't plain JSON (it may contain comments), so \(Brand.appName) won't rewrite it. Add the hook by hand or clean up the file and try again."
        case .foreignHookFile(let p):
            return "\(Paths.tildify(p)) already exists and wasn't created by \(Brand.appName). Move it aside and try again."
        case .noBackup:
            return "There is no backup to restore."
        case .hookBinaryMissing(let p):
            return "The hook program wasn't found at \(p)."
        }
    }
}

/// Merges our hook entries into each agent's config. Idempotent, backs up first, never touches other keys.
public struct Installer {
    public var home: String
    public var hookPath: String
    /// Agent hook timeout (seconds). Must exceed the popup wait.
    public var timeoutSeconds = 120

    public init(home: String = Paths.home, hookPath: String = Paths.installedHook) {
        self.home = home
        self.hookPath = hookPath
    }

    // MARK: Agent facts

    public func configPath(_ a: Agent) -> String {
        switch a {
        case .claude: return "\(home)/.claude/settings.json"
        case .codex: return "\(home)/.codex/hooks.json"
        case .cursor: return "\(home)/.cursor/hooks.json"
        case .gemini: return "\(home)/.gemini/settings.json"
        case .windsurf: return "\(home)/.codeium/windsurf/hooks.json"
        case .cline: return "\(home)/Documents/Cline/Hooks/PreToolUse"
        }
    }

    /// Events we register, in the agent's naming.
    public func events(_ a: Agent) -> [String] {
        switch a {
        case .claude: return ["PreToolUse", "UserPromptSubmit", "SessionStart"]
        case .codex: return ["PreToolUse", "UserPromptSubmit", "SessionStart"]
        case .cursor: return ["beforeShellExecution", "beforeReadFile", "beforeMCPExecution", "beforeSubmitPrompt", "afterFileEdit"]
        case .gemini: return ["BeforeTool", "SessionStart"]
        case .windsurf: return ["pre_run_command", "pre_read_code", "pre_write_code", "pre_mcp_tool_use"]
        case .cline: return ["PreToolUse"]
        }
    }

    /// Extra steps the user must do in the agent itself.
    public func followUp(_ a: Agent) -> String? {
        switch a {
        case .codex: return "Open Codex and run /hooks, then trust the \(Brand.appName) hook once. Codex skips hooks you haven't trusted."
        case .cline: return "In Cline, open the Hooks tab and switch on the PreToolUse hook."
        case .gemini: return "Restart Gemini CLI so it picks up the new hook."
        case .cursor, .windsurf: return "Restart \(a.displayName) so it loads the new hooks."
        case .claude: return "New Claude Code sessions pick this up automatically. Restart running sessions."
        }
    }

    public func isDetected(_ a: Agent) -> Bool {
        let fm = FileManager.default
        let dirs: [String]
        switch a {
        case .claude: dirs = ["\(home)/.claude"]
        case .codex: dirs = ["\(home)/.codex"]
        case .cursor: dirs = ["\(home)/.cursor", "/Applications/Cursor.app"]
        case .gemini: dirs = ["\(home)/.gemini"]
        case .windsurf: dirs = ["\(home)/.codeium/windsurf", "/Applications/Windsurf.app"]
        case .cline: dirs = ["\(home)/Documents/Cline"]
        }
        return dirs.contains { fm.fileExists(atPath: $0) }
    }

    public func command(_ a: Agent) -> String { "\"\(hookPath)\" --agent \(a.rawValue)" }

    static func isOurs(_ cmd: String?) -> Bool {
        guard let c = cmd else { return false }
        return c.contains(Brand.hookBinaryName) && c.contains("--agent")
    }

    // MARK: Status

    public func state(_ a: Agent, manifest: InstallManifest = .load()) -> InstallState {
        let path = configPath(a)
        let present = hasOurEntries(a)
        if present {
            if let why = disabledReason(a) { return .disabled(why) }
            return .installed
        }
        if manifest.records[a.rawValue] != nil { return .removed }
        return isDetected(a) || FileManager.default.fileExists(atPath: path) ? .notInstalled : .notDetected
    }

    public func hasOurEntries(_ a: Agent) -> Bool {
        let path = configPath(a)
        if a == .cline {
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return Self.isOurs(s)
        }
        guard let root = readJSON(path) else { return false }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        guard let first = events(a).first, let arr = hooks[first] as? [Any] else { return false }
        return arr.contains { entryIsOurs($0) || groupContainsOurs($0) }
    }

    func disabledReason(_ a: Agent) -> String? {
        switch a {
        case .claude:
            if let root = readJSON(configPath(a)), root["disableAllHooks"] as? Bool == true { return "disableAllHooks is set in settings.json" }
            if let local = readJSON("\(home)/.claude/settings.local.json"), local["disableAllHooks"] as? Bool == true {
                return "disableAllHooks is set in settings.local.json"
            }
        case .codex:
            if let toml = try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8) {
                for line in toml.split(separator: "\n") {
                    let t = line.replacingOccurrences(of: " ", with: "")
                    if t.hasPrefix("hooks=false") || t.hasPrefix("codex_hooks=false") { return "hooks are turned off in ~/.codex/config.toml" }
                }
            }
        default: break
        }
        return nil
    }

    // MARK: Install / uninstall

    @discardableResult
    public func install(_ a: Agent, hookSource: String? = nil, now: Date = Date()) throws -> InstallRecord {
        if let src = hookSource { try installHookBinary(from: src) }
        let path = configPath(a)
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: path)
        var manifest = InstallManifest.load()
        let previous = manifest.records[a.rawValue]

        if a == .cline {
            if existed, let s = try? String(contentsOfFile: path, encoding: .utf8), !Self.isOurs(s) {
                throw InstallError.foreignHookFile(path)
            }
        } else if existed, readJSON(path) == nil, !isEmptyFile(path) {
            throw InstallError.unreadableConfig(path)
        }

        let backup = existed ? try backupFile(a, path, now: now) : nil
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        if a == .cline {
            let script = "#!/bin/sh\n# Added by \(Brand.appName). Remove it from \(Brand.appName) ▸ Agents.\nexec \(command(a))\n"
            try Data(script.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o755)
        } else {
            var root = readJSON(path) ?? [:]
            root = merged(a, root)
            try writeJSON(root, to: path)
        }

        let rec = InstallRecord(agent: a, configPath: path, backupPath: backup,
                                originalBackupPath: previous?.originalBackupPath ?? backup,
                                createdFile: previous?.createdFile ?? !existed, installedAt: now, command: command(a))
        manifest.records[a.rawValue] = rec
        try manifest.save()
        return rec
    }

    /// Removes only our entries. Deletes the config file only if we created it and nothing else is left in it.
    public func uninstall(_ a: Agent) throws {
        let path = configPath(a)
        var manifest = InstallManifest.load()
        let rec = manifest.records[a.rawValue]
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if a == .cline {
                if let s = try? String(contentsOfFile: path, encoding: .utf8), Self.isOurs(s) {
                    try fm.removeItem(atPath: path)
                    if let b = rec?.originalBackupPath, fm.fileExists(atPath: b) { try fm.copyItem(atPath: b, toPath: path) }
                }
            } else {
                guard var root = readJSON(path) else { throw InstallError.unreadableConfig(path) }
                root = stripped(a, root)
                let leftover = root.filter { !($0.key == "version" && a == .cursor) }
                if rec?.createdFile == true && leftover.isEmpty {
                    try fm.removeItem(atPath: path)
                } else {
                    try writeJSON(root, to: path)
                }
            }
        }
        manifest.records[a.rawValue] = nil
        try manifest.save()
    }

    /// Puts back the exact file saved right before our last install (also forgets the install).
    public func restoreBackup(_ a: Agent) throws {
        var manifest = InstallManifest.load()
        guard let rec = manifest.records[a.rawValue] else { throw InstallError.noBackup }
        let fm = FileManager.default
        if let b = rec.backupPath, fm.fileExists(atPath: b) {
            let data = try Data(contentsOf: URL(fileURLWithPath: b))
            try data.write(to: URL(fileURLWithPath: rec.configPath), options: .atomic)
        } else if rec.createdFile {
            try uninstall(a)
            return
        } else {
            throw InstallError.noBackup
        }
        manifest.records[a.rawValue] = nil
        try manifest.save()
    }

    /// Before/after text for the install preview.
    public func preview(_ a: Agent) -> (before: String, after: String) {
        let path = configPath(a)
        let before = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if a == .cline { return (before, "#!/bin/sh\nexec \(command(a))\n") }
        guard let root = readJSON(path) ?? (before.isEmpty ? [:] : nil) else { return (before, "(file isn't plain JSON)") }
        return (before, Self.render(merged(a, root)))
    }

    // MARK: JSON surgery

    func ourHandler(_ a: Agent) -> [String: Any] {
        switch a {
        case .claude, .codex:
            return ["type": "command", "command": command(a), "timeout": timeoutSeconds]
        case .gemini:
            return ["type": "command", "command": command(a), "timeout": timeoutSeconds * 1000, "name": Brand.hookBinaryName]
        case .cursor:
            return ["command": command(a), "timeout": timeoutSeconds]
        case .windsurf:
            return ["command": command(a), "show_output": false]
        case .cline:
            return [:]
        }
    }

    func entryIsOurs(_ e: Any) -> Bool { Self.isOurs((e as? [String: Any])?["command"] as? String) }
    func groupContainsOurs(_ g: Any) -> Bool {
        ((g as? [String: Any])?["hooks"] as? [Any])?.contains { entryIsOurs($0) } ?? false
    }

    func merged(_ a: Agent, _ input: [String: Any]) -> [String: Any] {
        var root = stripped(a, input)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for ev in events(a) {
            var arr = hooks[ev] as? [Any] ?? []
            switch a {
            case .claude, .codex, .gemini:
                var group: [String: Any] = ["hooks": [ourHandler(a)]]
                if ["PreToolUse", "BeforeTool"].contains(ev) { group["matcher"] = a == .claude ? "*" : ".*" }
                arr.append(group)
            case .cursor:
                var h = ourHandler(a)
                if ev != "beforeSubmitPrompt" && ev != "afterFileEdit" { h["failClosed"] = true }
                arr.append(h)
            case .windsurf:
                arr.append(ourHandler(a))
            case .cline:
                break
            }
            hooks[ev] = arr
        }
        root["hooks"] = hooks
        if a == .cursor, root["version"] == nil { root["version"] = 1 }
        return root
    }

    func stripped(_ a: Agent, _ input: [String: Any]) -> [String: Any] {
        var root = input
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (ev, value) in hooks {
            guard let arr = value as? [Any] else { continue }
            var out: [Any] = []
            for item in arr {
                if entryIsOurs(item) { continue }
                if var g = item as? [String: Any], let inner = g["hooks"] as? [Any] {
                    let kept = inner.filter { !entryIsOurs($0) }
                    if kept.count != inner.count {
                        if kept.isEmpty { continue }
                        g["hooks"] = kept
                        out.append(g); continue
                    }
                }
                out.append(item)
            }
            if out.isEmpty { hooks[ev] = nil } else { hooks[ev] = out }
        }
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return root
    }

    // MARK: Files

    func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func isEmptyFile(_ path: String) -> Bool {
        (FileManager.default.contents(atPath: path) ?? Data()).allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    static func render(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    func writeJSON(_ o: [String: Any], to path: String) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        try Data(Self.render(o).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        if let p = perms { chmod(path, mode_t(p.uint16Value)) }
    }

    func backupFile(_ a: Agent, _ path: String, now: Date) throws -> String {
        let dir = "\(Paths.backupsDir)/\(a.rawValue)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let dest = "\(dir)/\(f.string(from: now))-\((path as NSString).lastPathComponent)"
        if FileManager.default.fileExists(atPath: dest) { try FileManager.default.removeItem(atPath: dest) }
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return dest
    }

    /// Copies the hook CLI to the stable path (only when it changed, so the hook definition never changes).
    public func installHookBinary(from src: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { throw InstallError.hookBinaryMissing(src) }
        try fm.createDirectory(atPath: (hookPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let a = fm.contents(atPath: src), let b = fm.contents(atPath: hookPath), a == b { return }
        let tmp = hookPath + ".new"
        try? fm.removeItem(atPath: tmp)
        try fm.copyItem(atPath: src, toPath: tmp)
        chmod(tmp, 0o755)
        if rename(tmp, hookPath) != 0 { throw InstallError.hookBinaryMissing(hookPath) }
    }
}
