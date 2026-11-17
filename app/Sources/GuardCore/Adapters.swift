import Foundation

/// The decision handed back to an agent.
public enum Verdict: Equatable, Sendable {
    /// `explicit` = the user approved in the popup (Claude/Cursor get an explicit allow; otherwise we stay silent
    /// so the agent's own permission rules still apply).
    case allow(explicit: Bool)
    case deny(String)
    /// Let the agent show its own prompt (only where supported).
    case ask(String)
}

public struct HookOutput: Equatable, Sendable {
    public var stdout: String = ""
    public var stderr: String = ""
    public var exitCode: Int32 = 0
}

/// Agent dialects: stdin JSON → `ActionEvent`, `Verdict` → stdout/stderr/exit code.
public enum Adapters {

    // MARK: Parse

    public static func parse(agent: Agent, json o: [String: Any], env: [String: String]) -> ActionEvent {
        switch agent {
        case .claude, .codex: return parseClaudeLike(agent, o, env)
        case .cursor: return parseCursor(o, env)
        case .gemini: return parseGemini(o, env)
        case .windsurf: return parseWindsurf(o, env)
        case .cline: return parseCline(o, env)
        }
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func defaultCwd(_ env: [String: String]) -> String { env["PWD"] ?? FileManager.default.currentDirectoryPath }

    static func base(_ agent: Agent, event: String, phase: Phase, tool: String, kind: ActionKind, cwd: String, project: String?) -> ActionEvent {
        let proj = (project?.isEmpty == false) ? project! : Paths.projectRoot(for: cwd)
        return ActionEvent(agent: agent, hookEvent: event, phase: phase, tool: tool, kind: kind, cwd: cwd, project: proj)
    }

    /// Shell command from a string or an argv array (["bash","-lc","script"] → "script").
    static func commandString(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let a = v as? [Any] {
            let parts = a.compactMap { str($0) }
            if parts.count >= 3, ["bash", "sh", "zsh"].contains((parts[0] as NSString).lastPathComponent),
               parts[1].hasPrefix("-"), parts[1].hasSuffix("c") {
                return parts[2...].joined(separator: " ")
            }
            return parts.map { p in
                p.isEmpty || p.contains(where: { " \t\"'$`\\|&;<>()*?".contains($0) }) ? "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'" : p
            }.joined(separator: " ")
        }
        return nil
    }

    static let pathKeys = ["file_path", "path", "absolute_path", "notebook_path", "filePath", "target_file", "dir_path",
                           "directory", "file", "filename", "source", "destination"]

    /// Paths that apply_patch touches ("*** Update File: x").
    static func patchPaths(_ patch: String) -> [String] {
        var out: [String] = []
        for line in patch.split(separator: "\n") {
            for p in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(p) {
                out.append(String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                var p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("a/") || p.hasPrefix("b/") { p.removeFirst(2) }
                if p != "/dev/null", !p.isEmpty { out.append(p) }
            }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// Fills kind/command/paths/url/content of `e` from a tool name + input object.
    static func applyTool(_ e: inout ActionEvent, name: String, input: [String: Any]) {
        let n = name.lowercased()
        func paths() -> [String] {
            var out: [String] = []
            for k in pathKeys { if let s = str(input[k]), !s.isEmpty { out.append(s) } }
            for k in ["paths", "file_paths", "files"] { if let a = input[k] as? [Any] { out += a.compactMap { str($0) } } }
            return out
        }
        e.tool = name
        if ["bash", "shell", "exec_command", "local_shell", "container.exec", "run_shell_command", "execute_command",
            "run_terminal_cmd", "terminal", "unified_exec", "shell_command"].contains(n) {
            e.kind = .shell
            e.command = commandString(input["command"] ?? input["cmd"] ?? input["commandLine"])
            if let wd = str(input["workdir"] ?? input["cwd"] ?? input["dir_path"]), !wd.isEmpty {
                e.cwd = Paths.normalize(wd, cwd: e.cwd)
            }
        } else if n == "apply_patch" {
            e.kind = .write
            let patch = str(input["input"]) ?? str(input["patch"]) ?? commandString(input["command"]) ?? ""
            e.paths = patchPaths(patch)
            e.content = patch
        } else if ["read", "read_file", "view", "notebookread", "read_many_files", "readfile", "cat"].contains(n) {
            e.kind = .read; e.paths = paths()
        } else if ["write", "edit", "multiedit", "notebookedit", "write_file", "replace", "edit_file", "write_to_file",
                   "replace_in_file", "create_file", "str_replace_editor", "search_replace", "delete_file"].contains(n) {
            e.kind = .write; e.paths = paths()
            var content = [str(input["content"]), str(input["new_string"]), str(input["new_source"]), str(input["diff"]),
                           str(input["new_str"])].compactMap { $0 }
            if let edits = input["edits"] as? [[String: Any]] { content += edits.compactMap { str($0["new_string"]) } }
            e.content = content.joined(separator: "\n")
        } else if ["glob", "grep", "ls", "list_directory", "search_file_content", "search_files", "list_files", "codebase_search",
                   "file_search", "list_dir"].contains(n) {
            e.kind = .search; e.paths = paths()
            var globs = [str(input["glob"]), str(input["include"]), str(input["file_pattern"])].compactMap { $0 }
            if ["glob", "file_search"].contains(n) { globs += [str(input["pattern"]), str(input["query"])].compactMap { $0 } }
            else { e.searchPattern = str(input["pattern"]) ?? str(input["regex"]) ?? str(input["query"]) }
            e.globs = globs.filter { !$0.isEmpty }
        } else if ["webfetch", "websearch", "web_fetch", "google_web_search", "web_search", "browser_action", "fetch"].contains(n) {
            e.kind = .web
            e.url = str(input["url"]) ?? str(input["query"]) ?? str(input["prompt"])
        } else if n.hasPrefix("mcp__") || n.hasPrefix("mcp_") || n == "use_mcp_tool" || n == "access_mcp_resource" {
            e.kind = .mcp
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3 { e.mcpServer = parts[1] }
            if let s = str(input["server_name"]) { e.mcpServer = s }
            e.paths = paths()
            // Path-looking arguments of MCP tools (filesystem servers etc.)
            let args = (input["arguments"] as? [String: Any]) ?? input
            for (k, v) in args where k.lowercased().contains("path") || k.lowercased().contains("file") {
                if let s = str(v) { e.paths.append(s) }
            }
        } else {
            e.kind = .other; e.paths = paths()
        }
    }

    static func parseClaudeLike(_ agent: Agent, _ o: [String: Any], _ env: [String: String]) -> ActionEvent {
        let event = str(o["hook_event_name"]) ?? "PreToolUse"
        let cwd = str(o["cwd"]) ?? defaultCwd(env)
        let phase: Phase
        switch event {
        case "PreToolUse": phase = .preAction
        case "PermissionRequest": phase = .permissionRequest
        case "PostToolUse", "PostToolUseFailure": phase = .post
        case "UserPromptSubmit": phase = .prompt
        case "SessionStart", "SessionEnd", "Setup": phase = .session
        default: phase = .other
        }
        var e = base(agent, event: event, phase: phase, tool: "", kind: .other, cwd: cwd, project: env["CLAUDE_PROJECT_DIR"])
        e.sessionId = str(o["session_id"])
        e.permissionMode = str(o["permission_mode"])
        if let tool = str(o["tool_name"]) {
            applyTool(&e, name: tool, input: o["tool_input"] as? [String: Any] ?? [:])
        } else if phase == .prompt {
            e.kind = .prompt; e.tool = "prompt"; e.command = nil; e.url = nil
            e.content = str(o["prompt"])
        } else if phase == .session {
            e.kind = .session; e.tool = event
        }
        if let m = e.permissionMode?.lowercased(), m == "bypasspermissions" || m.contains("bypass") || m == "yolo" || m == "never"
            || m.contains("danger") {
            e.unsafeReasons.append("permission mode: \(e.permissionMode!)")
        }
        return e
    }

    static func parseCursor(_ o: [String: Any], _ env: [String: String]) -> ActionEvent {
        let event = str(o["hook_event_name"]) ?? "beforeShellExecution"
        let roots = (o["workspace_roots"] as? [Any])?.compactMap { str($0) } ?? []
        let cwd = str(o["cwd"]) ?? roots.first ?? env["CURSOR_PROJECT_DIR"] ?? env["CLAUDE_PROJECT_DIR"] ?? defaultCwd(env)
        var e = base(.cursor, event: event, phase: .preAction, tool: event, kind: .other, cwd: cwd, project: roots.first)
        e.sessionId = str(o["conversation_id"]) ?? str(o["session_id"])
        switch event {
        case "beforeShellExecution":
            e.kind = .shell; e.tool = "shell"; e.command = str(o["command"])
        case "beforeReadFile", "beforeTabFileRead":
            e.kind = .read; e.tool = "read"; e.paths = [str(o["file_path"])].compactMap { $0 }
        case "beforeMCPExecution":
            e.kind = .mcp
            e.tool = str(o["tool_name"]) ?? "mcp"
            e.mcpServer = str(o["mcp_server_name"]) ?? str(o["server"])
            var input = o["tool_input"] as? [String: Any] ?? [:]
            if input.isEmpty, let s = str(o["tool_input"]), let d = s.data(using: .utf8),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { input = j }
            for (k, v) in input where k.lowercased().contains("path") || k.lowercased().contains("file") {
                if let s = str(v) { e.paths.append(s) }
            }
            e.url = str(o["url"])
            if let c = str(o["command"]) { e.command = nil; e.url = e.url ?? c }
        case "beforeSubmitPrompt":
            e.phase = .prompt; e.kind = .prompt; e.tool = "prompt"; e.content = str(o["prompt"])
        case "preToolUse":
            applyTool(&e, name: str(o["tool_name"]) ?? "tool", input: o["tool_input"] as? [String: Any] ?? [:])
        case "afterFileEdit", "afterTabFileEdit", "postToolUse", "postToolUseFailure", "afterShellExecution", "afterMCPExecution":
            e.phase = .post; e.kind = event.contains("Edit") ? .write : .other
            e.paths = [str(o["file_path"])].compactMap { $0 }
            if let c = str(o["command"]) { e.kind = .shell; e.command = c }
        case "sessionStart", "sessionEnd", "workspaceOpen":
            e.phase = .session; e.kind = .session
        default:
            e.phase = .other
        }
        return e
    }

    static func parseGemini(_ o: [String: Any], _ env: [String: String]) -> ActionEvent {
        let event = str(o["hook_event_name"]) ?? "BeforeTool"
        let cwd = str(o["cwd"]) ?? env["GEMINI_PROJECT_DIR"] ?? defaultCwd(env)
        let phase: Phase = ["BeforeTool": .preAction, "AfterTool": .post, "BeforeAgent": .prompt,
                            "SessionStart": .session, "SessionEnd": .session][event] ?? .other
        var e = base(.gemini, event: event, phase: phase, tool: event, kind: .other, cwd: cwd, project: env["GEMINI_PROJECT_DIR"])
        e.sessionId = str(o["session_id"])
        if let tool = str(o["tool_name"]) {
            applyTool(&e, name: tool, input: o["tool_input"] as? [String: Any] ?? [:])
        } else if phase == .prompt {
            e.kind = .prompt; e.tool = "prompt"; e.content = str(o["prompt"])
        } else if phase == .session { e.kind = .session }
        return e
    }

    static func parseWindsurf(_ o: [String: Any], _ env: [String: String]) -> ActionEvent {
        let event = str(o["agent_action_name"]) ?? str(o["hook_event_name"]) ?? "pre_run_command"
        let info = o["tool_info"] as? [String: Any] ?? [:]
        let cwd = str(info["cwd"]) ?? defaultCwd(env)
        var e = base(.windsurf, event: event, phase: event.hasPrefix("pre_") ? .preAction : .post, tool: event, kind: .other,
                     cwd: cwd, project: nil)
        e.sessionId = str(o["trajectory_id"])
        switch event {
        case "pre_run_command", "post_run_command":
            e.kind = .shell; e.tool = "run_command"; e.command = str(info["command_line"]) ?? str(info["command"])
        case "pre_read_code", "post_read_code":
            e.kind = .read; e.tool = "read_code"; e.paths = [str(info["file_path"])].compactMap { $0 }
        case "pre_write_code", "post_write_code":
            e.kind = .write; e.tool = "write_code"; e.paths = [str(info["file_path"])].compactMap { $0 }
            if let edits = info["edits"] as? [[String: Any]] { e.content = edits.compactMap { str($0["new_string"]) }.joined(separator: "\n") }
        case "pre_mcp_tool_use", "post_mcp_tool_use":
            e.kind = .mcp
            e.mcpServer = str(info["mcp_server_name"])
            e.tool = "mcp__\(e.mcpServer ?? "server")__\(str(info["mcp_tool_name"]) ?? "tool")"
            if let args = info["mcp_tool_arguments"] as? [String: Any] {
                for (k, v) in args where k.lowercased().contains("path") || k.lowercased().contains("file") {
                    if let s = str(v) { e.paths.append(s) }
                }
            }
        case "pre_user_prompt":
            e.phase = .prompt; e.kind = .prompt; e.content = str(info["user_prompt"])
        default:
            e.phase = .other
        }
        return e
    }

    static func parseCline(_ o: [String: Any], _ env: [String: String]) -> ActionEvent {
        let event = str(o["hookName"]) ?? "PreToolUse"
        let roots = (o["workspaceRoots"] as? [Any])?.compactMap { str($0) } ?? []
        let cwd = roots.first ?? defaultCwd(env)
        let phase: Phase = ["PreToolUse": .preAction, "PostToolUse": .post, "UserPromptSubmit": .prompt,
                            "TaskStart": .session, "TaskResume": .session][event] ?? .other
        var e = base(.cline, event: event, phase: phase, tool: event, kind: .other, cwd: cwd, project: roots.first)
        e.sessionId = str(o["taskId"])
        if let pre = (o["preToolUse"] ?? o["postToolUse"]) as? [String: Any] {
            applyTool(&e, name: str(pre["toolName"]) ?? "tool", input: pre["parameters"] as? [String: Any] ?? [:])
        } else if phase == .prompt {
            e.kind = .prompt; e.tool = "prompt"
            e.content = str((o["userPromptSubmit"] as? [String: Any])?["prompt"])
        } else if phase == .session { e.kind = .session }
        return e
    }

    // MARK: Render

    public static func render(_ v: Verdict, for e: ActionEvent) -> HookOutput {
        func json(_ o: Any) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
            return String(decoding: d, as: UTF8.self)
        }
        var out = HookOutput()
        switch e.agent {
        case .claude:
            if e.phase == .preAction {
                switch v {
                case .allow(let explicit):
                    if explicit {
                        out.stdout = json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                                  "permissionDecisionReason": "Approved in \(Brand.appName)."]])
                    }
                case .deny(let r):
                    out.stdout = json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                              "permissionDecisionReason": r]])
                case .ask(let r):
                    out.stdout = json(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "ask",
                                                              "permissionDecisionReason": r]])
                }
            } else if e.phase == .permissionRequest {
                switch v {
                case .allow(let explicit):
                    if explicit { out.stdout = json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]) }
                case .deny(let r):
                    out.stdout = json(["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                                              "decision": ["behavior": "deny", "message": r]]])
                case .ask: break   // Claude's own permission dialog is already showing
                }
            }
        case .codex, .windsurf:
            if case .deny(let r) = v { out.stderr = r; out.exitCode = 2 }
        case .gemini:
            if case .deny(let r) = v {
                out.stdout = json(["decision": "deny", "reason": r])
                out.stderr = r
                out.exitCode = 2
            } else { out.stdout = "{}" }
        case .cursor:
            switch e.hookEvent {
            case "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "beforeTabFileRead", "preToolUse":
                switch v {
                case .allow: out.stdout = json(["permission": "allow"])
                case .deny(let r): out.stdout = json(["permission": "deny", "user_message": r, "agent_message": r])
                case .ask(let r): out.stdout = json(["permission": "ask", "user_message": r, "agent_message": r])
                }
            case "beforeSubmitPrompt":
                if case .deny(let r) = v { out.stdout = json(["continue": false, "user_message": r]) }
                else { out.stdout = json(["continue": true]) }
            default:
                out.stdout = "{}"
            }
        case .cline:
            if case .deny(let r) = v { out.stdout = json(["cancel": true, "errorMessage": r]) }
            else { out.stdout = json(["cancel": false]) }
        }
        return out
    }
}
