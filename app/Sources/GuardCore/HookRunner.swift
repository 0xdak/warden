import Foundation

/// The whole hook pipeline, as a pure-ish function so the self-test can call it in-process too.
public enum HookRunner {
    public struct Result: Sendable {
        public var output: HookOutput
        public var record: EventRecord?
        public var matches: [RuleMatch]
    }

    public struct Options: Sendable {
        public var scanAncestors = true
        public var writeLog = true
        public init(scanAncestors: Bool = true, writeLog: Bool = true) {
            self.scanAncestors = scanAncestors; self.writeLog = writeLog
        }
    }

    public static func run(agent: Agent, input: Data, env: [String: String] = ProcessInfo.processInfo.environment,
                           options: Options = Options()) -> Result {
        let t0 = Date()
        guard let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            // Unreadable input: stay out of the way (never break the agent on our parse error).
            let e = ActionEvent(agent: agent, hookEvent: "unknown", phase: .other, tool: "", kind: .other, cwd: "", project: "")
            return Result(output: Adapters.render(.allow(explicit: false), for: e), record: nil, matches: [])
        }
        var e = Adapters.parse(agent: agent, json: obj, env: env)
        e.inputBytes = input.count
        if options.scanAncestors, e.phase == .preAction || e.phase == .session || e.phase == .permissionRequest {
            e.unsafeReasons = Array(Set(e.unsafeReasons + ProcessInspector.ancestorUnsafeReasons())).sorted()
        }
        let settings = GuardSettings.load()
        let book = DecisionBook.load()
        let (verdict, record, matches) = decide(e, settings: settings, book: book, started: t0)
        if options.writeLog { EventLog.append(record) }
        return Result(output: Adapters.render(verdict, for: e), record: record, matches: matches)
    }

    static func agentMessage(_ m: RuleMatch) -> String {
        "\(Brand.appName) blocked this action because it \(m.reason) (rule: \(m.ruleName)). "
            + "Do not try to work around this. Tell the user what you needed and why, and let them decide."
    }

    public static func decide(_ e: ActionEvent, settings: GuardSettings, book: DecisionBook, started: Date = Date())
        -> (Verdict, EventRecord, [RuleMatch]) {
        var record = EventRecord(id: UUID().uuidString, ts: started, agent: e.agent, hookEvent: e.hookEvent, kind: e.kind,
                                 tool: e.tool, summary: Redactor.redact(summary(e), limit: 2000), cwd: e.cwd, project: e.project,
                                 sessionId: e.sessionId, outcome: .allowed, via: .noMatch,
                                 unsafe: e.unsafeReasons.isEmpty ? nil : e.unsafeReasons)
        func finish(_ v: Verdict) -> (Verdict, EventRecord, [RuleMatch]) {
            record.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            return (v, record, [])
        }

        guard e.phase == .preAction || e.phase == .permissionRequest else { return finish(.allow(explicit: false)) }

        let all = RuleEngine.evaluate(e, settings: settings)
        var active: [RuleMatch] = []
        var forcedBlock: RuleMatch?
        var skippedVia: EventRecord.Via?
        for m in all {
            if let d = book.remembered(for: e, ruleId: m.ruleId) {
                if d.allow { skippedVia = .remembered } else { forcedBlock = forcedBlock ?? m }
                continue
            }
            let protected = RuleCatalog.alwaysOn.contains(m.ruleId)
            if !protected, book.exception(for: e, ruleId: m.ruleId) != nil { skippedVia = skippedVia ?? .exception; continue }
            if !protected, settings.isPaused { skippedVia = skippedVia ?? .paused; continue }
            active.append(m)
        }

        if let m = forcedBlock {
            fill(&record, m)
            record.outcome = .blocked; record.via = .remembered
            let (v, r, _) = finish(.deny(agentMessage(m)))
            return (v, r, all)
        }

        guard let top = active.max(by: { ($0.action, $0.severity) < ($1.action, $1.severity) }), top.action >= .ask else {
            if let obs = active.first(where: { $0.action == .observe }) {
                fill(&record, obs); record.outcome = .observed; record.via = .rule
            } else if let s = skippedVia {
                record.via = s
                if let m = all.first { fill(&record, m) }
            }
            let (v, r, _) = finish(.allow(explicit: false))
            return (v, r, all)
        }
        fill(&record, top)

        if settings.mode == .observe {
            record.outcome = .observed; record.via = .observeMode
            record.wouldBe = top.action == .block ? .blocked : .asked
            let (v, r, _) = finish(.allow(explicit: false))
            return (v, r, all)
        }

        if top.action == .block {
            record.outcome = .blocked; record.via = .rule
            let (v, r, _) = finish(.deny(agentMessage(top)))
            return (v, r, all)
        }

        // Ask
        let native = e.agent.supportsNativeAsk(kind: e.kind)
        let askText = "\(Brand.appName): this action \(top.reason) (rule: \(top.ruleName)). Approve only if you expected it."
        if settings.preferNativeAsk && native {
            record.outcome = .asked; record.via = .nativePrompt
            let (v, r, _) = finish(.ask(askText))
            return (v, r, all)
        }
        let req = AskRequest(agent: e.agent, kind: e.kind, tool: e.tool, target: e.target, summary: record.summary, cwd: e.cwd,
                             project: e.project, match: top, otherMatches: active.filter { $0 != top },
                             timeout: max(5, settings.askTimeout), unsafe: e.unsafeReasons)
        switch GuardClient.ask(req, wait: Double(max(5, settings.askTimeout) + 5)) {
        case .success(let reply):
            if reply.timedOut == true {
                record.via = .timeout
                if reply.allows { record.outcome = .allowed; return withAll(finish(.allow(explicit: true)), all) }
                record.outcome = .blocked
                return withAll(finish(.deny(agentMessage(top) + " (No answer in time.)")), all)
            }
            record.via = .user
            if reply.allows { record.outcome = .allowed; return withAll(finish(.allow(explicit: true)), all) }
            record.outcome = .blocked
            return withAll(finish(.deny("The user declined this action in \(Brand.appName) (\(top.ruleName)). Do not retry it another way; ask the user how to proceed.")), all)
        case .failure(.notRunning):
            record.via = .fallback
            if native {
                record.outcome = .asked
                return withAll(finish(.ask(askText)), all)
            }
            if settings.noAppFallback == .allow { record.outcome = .allowed; return withAll(finish(.allow(explicit: false)), all) }
            record.outcome = .blocked
            return withAll(finish(.deny(agentMessage(top) + " \(Brand.appName) needs the user's approval for this, but the app isn't running. Ask the user to open \(Brand.appName) and try again.")), all)
        case .failure:
            record.via = .timeout
            if settings.timeoutAction == .allow { record.outcome = .allowed; return withAll(finish(.allow(explicit: false)), all) }
            record.outcome = .blocked
            return withAll(finish(.deny(agentMessage(top) + " (No answer in time.)")), all)
        }
    }

    private static func withAll(_ t: (Verdict, EventRecord, [RuleMatch]), _ all: [RuleMatch]) -> (Verdict, EventRecord, [RuleMatch]) {
        (t.0, t.1, all)
    }

    private static func fill(_ r: inout EventRecord, _ m: RuleMatch) {
        r.ruleId = m.ruleId; r.ruleName = m.ruleName; r.reason = m.reason; r.severity = m.severity
    }

    static func summary(_ e: ActionEvent) -> String {
        switch e.kind {
        case .prompt: return "Prompt (\(e.content?.count ?? 0) characters)"
        case .session: return e.hookEvent
        case .mcp: return [e.tool, e.paths.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " ")
        default: return e.target
        }
    }
}
