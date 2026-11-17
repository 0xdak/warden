import SwiftUI
import GuardCore

struct DecisionsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        Page(title: "Decisions", subtitle: "Choices you asked \(Brand.appName) to remember, and time-boxed exceptions.") {
            Card(title: "Remembered") {
                let items = model.book.remembered.filter { !$0.isExpired }
                if items.isEmpty { Text("Use “Allow for project” or “Always allow” in a prompt and it shows up here.").foregroundStyle(.secondary) }
                ForEach(items) { d in
                    HStack(alignment: .top) {
                        Image(systemName: d.allow ? "checkmark.circle" : "xmark.octagon").foregroundStyle(d.allow ? Theme.ok : Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.target).font(.system(.callout, design: .monospaced)).lineLimit(2)
                            Text("\(RuleCatalog.byId[d.ruleId]?.name ?? d.ruleId) · \(d.scope == .project ? Paths.tildify(d.project ?? "") : "Everywhere")\(d.agent.map { " · " + $0.displayName } ?? "")\(d.expiresAt.map { " · until " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.book.remembered.removeAll { $0.id == d.id }; model.saveBook() } label: { Image(systemName: "trash") }
                    }
                }
            }
            Card(title: "Exceptions") {
                let items = model.book.exceptions.filter { !$0.isExpired }
                if items.isEmpty { Text("Need an agent to work unhindered in one project for a while? Add an exception. Changes to agent hook files stay blocked.").foregroundStyle(.secondary) }
                ForEach(items) { x in
                    HStack {
                        Image(systemName: "clock.badge.checkmark").foregroundStyle(Theme.caution)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(x.ruleId.flatMap { RuleCatalog.byId[$0]?.name } ?? "All rules") · \(x.project.map { Paths.tildify($0) } ?? "All projects") · \(x.agent?.displayName ?? "All agents")")
                            Text("Ends \(x.expiresAt, style: .relative) from now\(x.note.isEmpty ? "" : " · " + x.note)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("End now") { model.book.exceptions.removeAll { $0.id == x.id }; model.saveBook() }
                    }
                }
                Button("Add exception…") { adding = true }
            }
        }
        .sheet(isPresented: $adding) { ExceptionEditor().environment(model) }
    }
}

struct ExceptionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var project: String?
    @State private var agent: Agent?
    @State private var rule: String?
    @State private var minutes = 60
    @State private var note = ""

    var body: some View {
        Form {
            Picker("Project", selection: $project) {
                Text("All projects").tag(String?.none)
                ForEach(model.projects, id: \.self) { Text(Paths.tildify($0)).tag(String?.some($0)) }
            }
            Picker("Agent", selection: $agent) {
                Text("All agents").tag(Agent?.none)
                ForEach(Agent.allCases) { Text($0.displayName).tag(Agent?.some($0)) }
            }
            Picker("Rule", selection: $rule) {
                Text("All rules").tag(String?.none)
                ForEach(RuleCatalog.all.filter { !RuleCatalog.alwaysOn.contains($0.id) }) { Text($0.name).tag(String?.some($0.id)) }
            }
            Picker("For", selection: $minutes) {
                Text("15 minutes").tag(15); Text("1 hour").tag(60); Text("1 day").tag(1440); Text("1 week").tag(10080)
            }
            TextField("Note", text: $note, prompt: Text("Why (optional)"))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.book.exceptions.append(GuardException(project: project, agent: agent, ruleId: rule, note: note,
                                                                expiresAt: Date().addingTimeInterval(Double(minutes) * 60)))
                    model.saveBook()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
    }
}
