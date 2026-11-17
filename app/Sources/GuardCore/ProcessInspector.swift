import Foundation

/// Reads process arguments with sysctl (same user only, no entitlement) to spot agents running with safety prompts off.
public enum ProcessInspector {
    public struct AgentProcess: Sendable, Identifiable, Equatable {
        public var pid: Int32
        public var agent: Agent?
        public var executable: String
        public var args: [String]
        public var reasons: [String]
        public var id: Int32 { pid }
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let p = info.kp_eproc.e_ppid
        return p > 1 ? p : nil
    }

    /// argv of `pid` (KERN_PROCARGS2), or nil.
    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }        // exec path
        while i < size, buf[i] == 0 { i += 1 }        // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Reasons a command line turns agent safety off.
    public static func unsafeReasons(args: [String]) -> [String] {
        var out: [String] = []
        for (i, a) in args.enumerated() {
            switch a {
            case "--dangerously-skip-permissions": out.append("started with --dangerously-skip-permissions")
            case "--dangerously-bypass-approvals-and-sandbox": out.append("started with --dangerously-bypass-approvals-and-sandbox")
            case "--yolo": out.append("started with --yolo")
            case "--approval-mode=yolo": out.append("started in yolo approval mode")
            case "--approval-mode" where i + 1 < args.count && args[i + 1] == "yolo": out.append("started in yolo approval mode")
            case "--permission-mode" where i + 1 < args.count && args[i + 1] == "bypassPermissions":
                out.append("started with --permission-mode bypassPermissions")
            case "--permission-mode=bypassPermissions": out.append("started with --permission-mode bypassPermissions")
            default:
                if a.contains("approval_policy=never") || a.contains("approval_policy=\"never\"") { out.append("approval_policy=never") }
                if a.contains("sandbox_mode=danger-full-access") || a == "danger-full-access" { out.append("sandbox: danger-full-access") }
            }
        }
        return out
    }

    /// Walks up to `depth` ancestors of the current process (the agent spawned the hook through a shell or directly).
    public static func ancestorUnsafeReasons(depth: Int = 5) -> [String] {
        var out: [String] = []
        var pid = getppid()
        for _ in 0..<depth {
            guard pid > 1 else { break }
            if let args = arguments(of: pid) { out += unsafeReasons(args: args) }
            guard let p = parentPID(of: pid) else { break }
            pid = p
        }
        if geteuid() == 0 { out.append("agent runs as root") }
        return Array(Set(out)).sorted()
    }

    static func agent(for args: [String]) -> Agent? {
        let joined = args.prefix(3).map { ($0 as NSString).lastPathComponent.lowercased() }
        for name in joined {
            if name == "claude" || name.hasPrefix("claude-code") { return .claude }
            if name == "codex" || name.hasPrefix("codex-") { return .codex }
            if name == "gemini" { return .gemini }
            if name.hasPrefix("cursor") { return .cursor }
            if name.hasPrefix("windsurf") { return .windsurf }
        }
        // node /…/bin/claude, node …/@openai/codex/…
        let all = args.prefix(3).joined(separator: " ").lowercased()
        if all.contains("claude-code") || all.contains("/bin/claude") { return .claude }
        if all.contains("@openai/codex") || all.contains("/bin/codex") { return .codex }
        if all.contains("gemini-cli") || all.contains("/bin/gemini") { return .gemini }
        return nil
    }

    /// This user's processes that look like coding agents running with prompts turned off.
    public static func unsafeAgentProcesses() -> [AgentProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var out: [AgentProcess] = []
        for i in 0..<n {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 1, pid != getpid(), let args = arguments(of: pid), !args.isEmpty else { continue }
            let reasons = unsafeReasons(args: args)
            guard !reasons.isEmpty else { continue }
            out.append(AgentProcess(pid: pid, agent: agent(for: args), executable: args[0], args: args, reasons: reasons))
        }
        return out
    }
}
