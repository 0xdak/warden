import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GuardCore

struct EvidenceView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var agent: Agent?
    @State private var outcome: EventRecord.Outcome?
    @State private var project: String?
    @State private var range: Range = .week
    @State private var selection: EventRecord.ID?

    enum Range: String, CaseIterable { case today = "Today", week = "7 days", month = "30 days", all = "All" }

    var filtered: [EventRecord] {
        let since: Date? = {
            switch range {
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            case .month: return Date().addingTimeInterval(-30 * 86_400)
            case .all: return nil
            }
        }()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.events.filter { e in
            (since.map { e.ts >= $0 } ?? true)
                && (agent.map { e.agent == $0 } ?? true)
                && (outcome.map { e.outcome == $0 } ?? true)
                && (project.map { e.project == $0 } ?? true)
                && (q.isEmpty || e.summary.lowercased().contains(q) || (e.ruleName?.lowercased().contains(q) ?? false)
                    || e.project.lowercased().contains(q) || e.tool.lowercased().contains(q))
        }
    }

    var body: some View {
        let rows = filtered
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Evidence").font(.largeTitle.weight(.semibold))
                Text("Every action your agents tried and what happened, stored only on this Mac. Secrets are masked before they're saved.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search commands, paths, rules, projects", text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 220)
                Picker("Agent", selection: $agent) {
                    Text("All agents").tag(Agent?.none)
                    ForEach(Agent.allCases) { Text($0.displayName).tag(Agent?.some($0)) }
                }.frame(width: 150)
                Picker("Result", selection: $outcome) {
                    Text("Any result").tag(EventRecord.Outcome?.none)
                    ForEach(EventRecord.Outcome.allCases, id: \.self) { Text($0.title).tag(EventRecord.Outcome?.some($0)) }
                }.frame(width: 140)
                Picker("Project", selection: $project) {
                    Text("All projects").tag(String?.none)
                    ForEach(model.projects, id: \.self) { Text(($0 as NSString).lastPathComponent).tag(String?.some($0)) }
                }.frame(width: 160)
                Picker("", selection: $range) { ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 100)
                Menu("Export") {
                    Button("JSON Lines…") { export(rows, csv: false) }
                    Button("CSV…") { export(rows, csv: true) }
                }.frame(width: 80)
            }
            Table(rows, selection: $selection) {
                TableColumn("Time") { e in Text(e.ts, format: .dateTime.month(.abbreviated).day().hour().minute().second()).monospacedDigit() }
                    .width(min: 110, ideal: 130)
                TableColumn("Agent") { e in Text(e.agent.displayName) }.width(min: 70, ideal: 90)
                TableColumn("Result") { e in OutcomeBadge(outcome: e.outcome) }.width(min: 80, ideal: 90)
                TableColumn("Action") { e in Text(e.summary).font(.system(.body, design: .monospaced)).lineLimit(1).help(e.summary) }
                TableColumn("Rule") { e in Text(e.ruleName ?? "—").foregroundStyle(e.ruleName == nil ? .secondary : .primary) }.width(min: 90, ideal: 150)
                TableColumn("Project") { e in Text(e.projectName).help(e.project) }.width(min: 70, ideal: 110)
            }
            if let id = selection, let e = rows.first(where: { $0.id == id }) {
                EventDetail(e: e)
            }
            Text("\(rows.count) of \(model.events.count) actions").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    func export(_ rows: [EventRecord], csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Brand.appName.lowercased())-activity.\(csv ? "csv" : "jsonl")"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let data = csv ? EventLog.exportCSV(rows) : EventLog.exportJSONL(rows)
            do { try data.write(to: url) } catch { Task { @MainActor in AppModel.shared.lastError = error.localizedDescription } }
        }
    }
}

struct EventDetail: View {
    let e: EventRecord
    var body: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Action", e.summary, mono: true)
                row("Result", "\(e.outcome.title) · \(e.via.title)\(e.wouldBe.map { " (would have been: \($0.title.lowercased()))" } ?? "")")
                if let r = e.ruleName { row("Rule", "\(r) (\(e.ruleId ?? "")) — \(e.reason ?? "")") }
                row("Agent", "\(e.agent.displayName) · \(e.hookEvent) · \(e.tool)")
                row("Where", Paths.tildify(e.cwd))
                if let u = e.unsafe, !u.isEmpty { row("Unsafe mode", u.joined(separator: ", ")) }
                if let s = e.sessionId { row("Session", s, mono: true) }
                if let l = e.latencyMs { row("Decided in", "\(l) ms") }
            }
        }
    }
    @ViewBuilder func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(mono ? .system(.body, design: .monospaced) : .body).textSelection(.enabled).lineLimit(3)
        }
    }
}
