import Foundation

/// Whether any agent actually sends actions to the hook. Pure logic, shared by the UI and the self-test.
public struct ProtectionSummary: Equatable, Sendable {
    public var protected: [Agent]
    /// Detected agents that don't have the hook (not installed, or our entries were removed), in catalog order.
    public var installable: [Agent]
    /// Agents that have our hook but ignore it (e.g. `disableAllHooks`).
    public var disabled: [Agent]

    public init(states: [Agent: InstallState]) {
        protected = Agent.allCases.filter { states[$0] == .installed }
        installable = Agent.allCases.filter { a in
            switch states[a] { case .notInstalled?, .removed?: true; default: false }
        }
        disabled = Agent.allCases.filter { if case .disabled? = states[$0] { true } else { false } }
    }

    public var hasProtection: Bool { !protected.isEmpty }
    /// Any supported agent on this Mac at all (protected or not).
    public var anyDetected: Bool { !(protected.isEmpty && installable.isEmpty && disabled.isEmpty) }
    public var firstInstallable: Agent? { installable.first }
    public var detectedNames: String { installable.map(\.displayName).joined(separator: ", ") }

    /// One-line explanation for the "not protecting anything" warning, including how to fix it.
    public var warningBody: String {
        if !installable.isEmpty {
            return "\(Brand.appName) only sees what agents send to its hook. Found: \(detectedNames). Install it to start."
        }
        if !disabled.isEmpty {
            return "The hook is in \(disabled.map(\.displayName).joined(separator: ", ")), but hooks are turned off there. See Agents."
        }
        return "No supported agent found on this Mac (\(Agent.allCases.map(\.displayName).joined(separator: ", "))). "
            + "Install one, then open Agents \u{25B8} Install."
    }
}

/// Observe-mode notices ("Would have blocked: <rule>"), rate-limited so a noisy baseline isn't spammy:
/// at most once per rule per `perRule` seconds and `maxPerWindow` in any `window` seconds overall.
public struct ObserveNotifier: Sendable {
    public var perRule: TimeInterval
    public var window: TimeInterval
    public var maxPerWindow: Int
    private var lastByRule: [String: Date] = [:]
    private var recent: [Date] = []

    public init(perRule: TimeInterval = 60, window: TimeInterval = 60, maxPerWindow: Int = 5) {
        self.perRule = perRule; self.window = window; self.maxPerWindow = maxPerWindow
    }

    /// Title/body for an event that enforcement would have stopped; nil for everything else.
    /// `summary` is already redacted when the hook logs the event.
    public static func notice(for e: EventRecord) -> (title: String, body: String)? {
        guard e.outcome == .observed, e.wouldBe == .blocked || e.wouldBe == .asked else { return nil }
        let verb = e.wouldBe == .blocked ? "Would have blocked" : "Would have asked"
        return ("\(verb): \(e.ruleName ?? "risky action")", "\(e.agent.displayName) \u{00B7} \(e.summary.prefix(120))")
    }

    /// Returns true (and records it) when this event may notify now.
    public mutating func shouldNotify(_ e: EventRecord, now: Date = Date()) -> Bool {
        guard Self.notice(for: e) != nil else { return false }
        let key = e.ruleId ?? e.ruleName ?? "?"
        if let t = lastByRule[key], now.timeIntervalSince(t) < perRule { return false }
        recent.removeAll { now.timeIntervalSince($0) >= window }
        guard recent.count < maxPerWindow else { return false }
        lastByRule[key] = now
        recent.append(now)
        return true
    }
}
