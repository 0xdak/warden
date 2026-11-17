import Foundation

/// Whether any agent actually sends actions to the hook. Pure logic, shared by the UI and the self-test.
public struct ProtectionSummary: Equatable, Sendable {
    public var protected: [Agent]
    /// Detected agents that don't have the hook (not installed, or our entries were removed), in catalog order.
    public var installable: [Agent]

    public init(states: [Agent: InstallState]) {
        protected = Agent.allCases.filter { states[$0] == .installed }
        installable = Agent.allCases.filter { a in
            switch states[a] { case .notInstalled?, .removed?: true; default: false }
        }
    }

    public var hasProtection: Bool { !protected.isEmpty }
    public var firstInstallable: Agent? { installable.first }
    public var detectedNames: String { installable.map(\.displayName).joined(separator: ", ") }

    /// One-line explanation for the "not protecting anything" warning.
    public var warningBody: String {
        installable.isEmpty
            ? "No supported agent found on this Mac. \(Brand.appName) only sees what agents send to its hook."
            : "\(Brand.appName) only sees what agents send to its hook. Found: \(detectedNames). Install it to start."
    }
}

/// Observe-mode notices: "would have blocked/asked", at most once per interval per rule.
public struct ObserveNotifier: Sendable {
    public var interval: TimeInterval
    private var last: [String: Date] = [:]
    public init(interval: TimeInterval = 5) { self.interval = interval }

    /// Title/body for an event that enforcement would have stopped; nil for everything else.
    public static func notice(for e: EventRecord) -> (title: String, body: String)? {
        guard e.outcome == .observed, e.wouldBe == .blocked || e.wouldBe == .asked else { return nil }
        let verb = e.wouldBe == .blocked ? "blocked" : "asked about"
        let rule = e.ruleName.map { " \u{2014} \($0)" } ?? ""
        return ("\(Brand.appName) (observe)", "Would have \(verb) `\(e.summary.prefix(80))` in \(e.agent.displayName)\(rule)")
    }

    /// Returns true (and records it) when this event may notify now.
    public mutating func shouldNotify(_ e: EventRecord, now: Date = Date()) -> Bool {
        guard Self.notice(for: e) != nil else { return false }
        let key = e.ruleId ?? e.ruleName ?? "?"
        if let t = last[key], now.timeIntervalSince(t) < interval { return false }
        last[key] = now
        return true
    }
}
