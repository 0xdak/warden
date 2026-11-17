import Foundation

/// One line in events/YYYY-MM-DD.jsonl. Everything is redacted before it gets here; file contents are never stored.
public struct EventRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case allowed, blocked, asked, observed
        public var title: String {
            switch self { case .allowed: "Allowed"; case .blocked: "Blocked"; case .asked: "Asked agent"; case .observed: "Logged" }
        }
    }
    /// Who made the call.
    public enum Via: String, Codable, Sendable {
        case noMatch, rule, user, timeout, fallback, remembered, exception, paused, observeMode, nativePrompt
        public var title: String {
            switch self {
            case .noMatch: "No rule matched"; case .rule: "Rule"; case .user: "You"; case .timeout: "Timed out"
            case .fallback: "App not running"; case .remembered: "Remembered decision"; case .exception: "Exception"
            case .paused: "Protection paused"; case .observeMode: "Observe mode"; case .nativePrompt: "Agent's own prompt"
            }
        }
    }

    public var id: String
    public var ts: Date
    public var agent: Agent
    public var hookEvent: String
    public var kind: ActionKind
    public var tool: String
    /// Redacted command / path / URL.
    public var summary: String
    public var cwd: String
    public var project: String
    public var sessionId: String?
    public var outcome: Outcome
    public var via: Via
    public var ruleId: String?
    public var ruleName: String?
    public var reason: String?
    public var severity: Severity?
    /// What enforcement would have done (observe mode / observe rules).
    public var wouldBe: Outcome?
    public var unsafe: [String]?
    public var latencyMs: Int?

    public var projectName: String { (project as NSString).lastPathComponent }
}

public enum EventLog {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func file(for day: Date) -> String {
        (Paths.eventsDir as NSString).appendingPathComponent(dayFormatter.string(from: day) + ".jsonl")
    }

    /// Appends one line with O_APPEND (safe with concurrent hook processes).
    public static func append(_ r: EventRecord) {
        Paths.ensureSupport()
        guard var data = try? JSONFile.lineEncoder.encode(r) else { return }
        data.append(0x0A)
        let path = file(for: r.ts)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads records from `path` starting at byte `offset`; returns records and the new offset (only whole lines).
    public static func read(path: String, from offset: UInt64 = 0) -> ([EventRecord], UInt64) {
        guard let h = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let whole = data[data.startIndex...lastNL]
        var out: [EventRecord] = []
        for line in whole.split(separator: 0x0A) {
            if let r = try? JSONFile.decoder.decode(EventRecord.self, from: Data(line)) { out.append(r) }
        }
        return (out, offset + UInt64(whole.count))
    }

    /// Day files, newest first.
    public static func dayFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.eventsDir)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted(by: >).map { (Paths.eventsDir as NSString).appendingPathComponent($0) }
    }

    /// Deletes day files older than `days` (only our own event files).
    public static func prune(retentionDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = dayFormatter.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        for f in dayFiles() {
            let name = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
            if name < cutoff { try? FileManager.default.removeItem(atPath: f) }
        }
    }

    // MARK: Export

    public static func exportJSONL(_ records: [EventRecord]) -> Data {
        var d = Data()
        for r in records { if let line = try? JSONFile.lineEncoder.encode(r) { d.append(line); d.append(0x0A) } }
        return d
    }

    public static func exportCSV(_ records: [EventRecord]) -> Data {
        func esc(_ s: String?) -> String {
            let v = s ?? ""
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let iso = ISO8601DateFormatter()
        var lines = ["time,agent,event,kind,tool,outcome,via,rule,severity,reason,project,cwd,summary"]
        for r in records {
            lines.append([iso.string(from: r.ts), r.agent.rawValue, r.hookEvent, r.kind.rawValue, r.tool, r.outcome.rawValue,
                          r.via.rawValue, r.ruleId ?? "", r.severity?.rawValue ?? "", r.reason ?? "", r.project, r.cwd, r.summary]
                .map { esc($0) }.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
