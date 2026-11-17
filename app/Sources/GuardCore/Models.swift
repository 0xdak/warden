import Foundation

// MARK: - Agents

public enum Agent: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex, cursor, gemini, windsurf, cline
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .windsurf: return "Windsurf"
        case .cline: return "Cline"
        }
    }

    /// True when the agent can show its own approval prompt for an "ask" we hand back.
    public func supportsNativeAsk(kind: ActionKind) -> Bool {
        switch self {
        case .claude: return true
        case .cursor: return kind == .shell || kind == .mcp
        default: return false
        }
    }
}

// MARK: - Decisions

/// What a rule wants. Ordered by strength (block wins).
public enum RuleAction: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    public var id: String { rawValue }
    case off, allow, observe, ask, block
    var rank: Int { switch self { case .off: 0; case .allow: 1; case .observe: 2; case .ask: 3; case .block: 4 } }
    public static func < (a: RuleAction, b: RuleAction) -> Bool { a.rank < b.rank }
    public var title: String {
        switch self { case .off: "Off"; case .allow: "Allow"; case .observe: "Log only"; case .ask: "Ask"; case .block: "Block" }
    }
}

public enum Severity: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    public var id: String { rawValue }
    case low, medium, high, critical
    var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2; case .critical: 3 } }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var title: String { rawValue.capitalized }
}

public enum Preset: String, Codable, CaseIterable, Sendable, Identifiable {
    case strict, balanced, permissive
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var blurb: String {
        switch self {
        case .strict: return "Stops anything risky outright. Best for unattended runs and sensitive machines."
        case .balanced: return "Stops clear threats, checks with you on judgment calls. Recommended."
        case .permissive: return "Only stops the worst. Everything else is logged so you can review it later."
        }
    }
}

public enum ProtectionMode: String, Codable, CaseIterable, Sendable {
    /// Decisions are enforced.
    case enforce
    /// Everything is allowed, but what *would* have been stopped is recorded (rollout / baseline).
    case observe
}

// MARK: - Normalized action

public enum ActionKind: String, Codable, Sendable, CaseIterable {
    case shell, read, write, search, web, mcp, prompt, session, other
    public var title: String {
        switch self {
        case .shell: "Command"; case .read: "File read"; case .write: "File write"; case .search: "Search"
        case .web: "Web"; case .mcp: "MCP tool"; case .prompt: "Prompt"; case .session: "Session"; case .other: "Other"
        }
    }
}

public enum Phase: String, Codable, Sendable {
    case preAction, permissionRequest, post, prompt, session, other
}

/// One agent hook call, normalized across agents.
public struct ActionEvent: Codable, Sendable {
    public var agent: Agent
    public var hookEvent: String
    public var phase: Phase
    public var tool: String
    public var kind: ActionKind
    public var command: String?
    public var paths: [String] = []
    public var url: String?
    /// Write/Edit content. Used for rule checks only; never logged.
    public var content: String?
    public var cwd: String
    public var project: String
    public var sessionId: String?
    public var permissionMode: String?
    public var mcpServer: String?
    /// Reasons this session looks like it runs with safety prompts turned off.
    public var unsafeReasons: [String] = []
    /// File-name filters of search tools (Grep `glob`, Glob `pattern`, Gemini `include`).
    public var globs: [String]?
    /// The text/regex a search tool looks for (Grep `pattern`).
    public var searchPattern: String?
    /// Size of the raw hook input (oversized input is sent to a person instead of being analysed).
    public var inputBytes: Int?

    public init(agent: Agent, hookEvent: String, phase: Phase, tool: String, kind: ActionKind, cwd: String, project: String) {
        self.agent = agent; self.hookEvent = hookEvent; self.phase = phase; self.tool = tool; self.kind = kind
        self.cwd = cwd; self.project = project
    }

    /// The single string the user sees and remembered decisions match on.
    public var target: String {
        if let c = command, !c.isEmpty { return c }
        if !paths.isEmpty { return paths.joined(separator: " ") }
        if let u = url { return u }
        return tool
    }
}

public struct RuleMatch: Codable, Sendable, Equatable {
    public var ruleId: String
    public var ruleName: String
    public var category: String
    public var severity: Severity
    public var action: RuleAction
    public var reason: String

    public init(ruleId: String, ruleName: String, category: String, severity: Severity, action: RuleAction, reason: String) {
        self.ruleId = ruleId; self.ruleName = ruleName; self.category = category
        self.severity = severity; self.action = action; self.reason = reason
    }
}

// MARK: - Settings (settings.json, written by the app, read by every hook call)

public struct CustomRule: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case pathGlob, commandPattern, regex
        public var title: String {
            switch self { case .pathGlob: "Path glob"; case .commandPattern: "Command contains"; case .regex: "Regex" }
        }
    }
    public var id: String
    public var name: String
    public var kind: Kind
    public var pattern: String
    public var action: RuleAction
    public var severity: Severity
    /// Empty = all agents.
    public var agents: [Agent]
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, kind: Kind, pattern: String, action: RuleAction,
                severity: Severity = .high, agents: [Agent] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.pattern = pattern; self.action = action
        self.severity = severity; self.agents = agents; self.enabled = enabled
    }
}

public enum Fallback: String, Codable, CaseIterable, Sendable {
    case block, allow
}

public struct GuardSettings: Codable, Sendable, Equatable {
    public var preset: Preset = .balanced
    /// Fresh installs observe until onboarding records the user's choice (hooks that fire before then only log).
    public var mode: ProtectionMode = .observe
    /// When the current observe-mode baseline started (nil = since install).
    public var observeSince: Date?
    /// Seconds the hook waits for an answer in the approval popup.
    public var askTimeout: Int = 60
    /// What happens when the popup times out.
    public var timeoutAction: Fallback = .block
    /// For "ask" when the app isn't running and the agent has no native prompt.
    public var noAppFallback: Fallback = .block
    /// Hand "ask" to the agent's own prompt (Claude Code, Cursor shell/MCP) instead of our popup.
    public var preferNativeAsk: Bool = false
    public var pausedUntil: Date?
    /// Per built-in rule action overrides (rule id → action).
    public var ruleOverrides: [String: RuleAction] = [:]
    public var customRules: [CustomRule] = []
    public var retentionDays: Int = 30
    public var notifyOnBlock: Bool = true
    public var notifyInObserve: Bool = true
    public var autoRepairHooks: Bool = true

    public init() {}

    public var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: unknown/missing keys fall back to defaults so old files keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardSettings()
        preset = (try? c.decode(Preset.self, forKey: .preset)) ?? d.preset
        // A saved file without a mode predates the observe-first default: keep its old behaviour (enforce).
        mode = (try? c.decode(ProtectionMode.self, forKey: .mode)) ?? .enforce
        observeSince = try? c.decode(Date.self, forKey: .observeSince)
        askTimeout = (try? c.decode(Int.self, forKey: .askTimeout)) ?? d.askTimeout
        timeoutAction = (try? c.decode(Fallback.self, forKey: .timeoutAction)) ?? d.timeoutAction
        noAppFallback = (try? c.decode(Fallback.self, forKey: .noAppFallback)) ?? d.noAppFallback
        preferNativeAsk = (try? c.decode(Bool.self, forKey: .preferNativeAsk)) ?? d.preferNativeAsk
        pausedUntil = try? c.decode(Date.self, forKey: .pausedUntil)
        ruleOverrides = (try? c.decode([String: RuleAction].self, forKey: .ruleOverrides)) ?? [:]
        customRules = (try? c.decode([CustomRule].self, forKey: .customRules)) ?? []
        retentionDays = (try? c.decode(Int.self, forKey: .retentionDays)) ?? d.retentionDays
        notifyOnBlock = (try? c.decode(Bool.self, forKey: .notifyOnBlock)) ?? d.notifyOnBlock
        notifyInObserve = (try? c.decode(Bool.self, forKey: .notifyInObserve)) ?? d.notifyInObserve
        autoRepairHooks = (try? c.decode(Bool.self, forKey: .autoRepairHooks)) ?? d.autoRepairHooks
    }

    /// Observed events that enforcement would have blocked or asked about, since the baseline started.
    public func wouldHaveBeenStopped(in events: [EventRecord]) -> Int {
        events.reduce(0) { n, e in
            let since = observeSince.map { e.ts >= $0 } ?? true
            return n + (since && e.outcome == .observed && (e.wouldBe == .blocked || e.wouldBe == .asked) ? 1 : 0)
        }
    }

    public static func load() -> GuardSettings { JSONFile.read(GuardSettings.self, at: Paths.settingsFile) ?? GuardSettings() }
    public func save() throws { try JSONFile.write(self, to: Paths.settingsFile) }
}

// MARK: - Remembered decisions & expiring exceptions (decisions.json)

public struct RememberedDecision: Codable, Sendable, Identifiable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case project, everywhere
        public var title: String { self == .project ? "This project" : "Everywhere" }
    }
    public var id: String = UUID().uuidString
    public var agent: Agent?
    public var project: String?
    public var ruleId: String
    /// Exact target (command or path) the decision applies to.
    public var target: String
    public var allow: Bool
    public var scope: Scope
    public var createdAt: Date = Date()
    public var expiresAt: Date?

    public init(agent: Agent?, project: String?, ruleId: String, target: String, allow: Bool, scope: Scope, expiresAt: Date? = nil) {
        self.agent = agent; self.project = project; self.ruleId = ruleId; self.target = target
        self.allow = allow; self.scope = scope; self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

/// A time-boxed bypass: everything (or one rule) is allowed for a project and/or agent until `expiresAt`.
public struct GuardException: Codable, Sendable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var project: String?
    public var agent: Agent?
    /// nil = every rule except self-protection.
    public var ruleId: String?
    public var note: String
    public var createdAt: Date = Date()
    public var expiresAt: Date

    public init(project: String?, agent: Agent?, ruleId: String?, note: String, expiresAt: Date) {
        self.project = project; self.agent = agent; self.ruleId = ruleId; self.note = note; self.expiresAt = expiresAt
    }
    public var isExpired: Bool { expiresAt <= Date() }
}

public struct DecisionBook: Codable, Sendable, Equatable {
    public var remembered: [RememberedDecision] = []
    public var exceptions: [GuardException] = []
    public init() {}

    public static func load() -> DecisionBook { JSONFile.read(DecisionBook.self, at: Paths.decisionsFile) ?? DecisionBook() }
    public func save() throws { try JSONFile.write(self, to: Paths.decisionsFile) }

    public func remembered(for e: ActionEvent, ruleId: String) -> RememberedDecision? {
        remembered.first { d in
            !d.isExpired && d.ruleId == ruleId && d.target == e.target
                && (d.agent == nil || d.agent == e.agent)
                && (d.scope == .everywhere || d.project == e.project)
        }
    }

    public func exception(for e: ActionEvent, ruleId: String) -> GuardException? {
        exceptions.first { x in
            !x.isExpired && (x.ruleId == nil || x.ruleId == ruleId)
                && (x.agent == nil || x.agent == e.agent)
                && (x.project == nil || x.project == e.project)
        }
    }

    public mutating func pruneExpired() {
        remembered.removeAll { $0.isExpired }
        exceptions.removeAll { $0.isExpired }
    }
}

// MARK: - JSON helpers

public enum JSONFile {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    public static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func read<T: Decodable>(_ type: T.Type, at path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    public static func write<T: Encodable>(_ value: T, to path: String) throws {
        Paths.ensureSupport()
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }
}
