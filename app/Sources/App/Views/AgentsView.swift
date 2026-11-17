import SwiftUI
import GuardCore

struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var preview: Agent?

    var body: some View {
        Page(title: "Agents", subtitle: "\(Brand.appName) adds a hook to each agent's own config. A backup is saved before every change, and removing it puts things back.") {
            ForEach(Agent.allCases) { a in AgentCard(agent: a, preview: $preview) }
            Card(title: "What hooks can't do") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Hooks only run when the agent fires them. Sessions started with hooks disabled or untrusted (Codex) aren't covered.")
                    Text("• A determined agent can hide intent (python -c, base64, a script written then run). \(Brand.appName) catches common patterns, not all.")
                    Text("• This isn't a sandbox. For untrusted work, pair it with one.")
                }.font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $preview) { a in InstallPreview(agent: a).environment(model) }
    }
}

struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @Binding var preview: Agent?

    var body: some View {
        let st = model.states[agent] ?? .notDetected
        let inst = model.installer
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(agent.displayName).font(.headline)
                        Text(st.title).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(tint(st).opacity(0.15), in: Capsule()).foregroundStyle(tint(st))
                    }
                    Text(Paths.tildify(inst.configPath(agent))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text(coverage).font(.caption).foregroundStyle(.secondary)
                    if case .disabled(let why) = st { Text(why).font(.caption).foregroundStyle(Theme.danger) }
                    if st == .removed { Text("Our hook is gone from this file. \(model.settings.autoRepairHooks ? "It will be put back automatically." : "Install again to restore it.")").font(.caption).foregroundStyle(Theme.danger) }
                    if st == .installed, let f = inst.followUp(agent) { Label(f, systemImage: "info.circle").font(.caption) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    switch st {
                    case .installed, .disabled:
                        Button("Remove") { model.uninstall(agent) }
                    case .removed:
                        Button("Install again") { model.install(agent) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button("Forget") { model.uninstall(agent) }
                    case .notInstalled, .notDetected:
                        Button("Install…") { preview = agent }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                    if InstallManifest.load().records[agent.rawValue]?.backupPath != nil {
                        Button("Restore backup") { model.restoreBackup(agent) }.font(.caption)
                            .help("Put back the exact file saved before the last install")
                    }
                }
            }
        }
    }

    var coverage: String {
        switch agent {
        case .claude: "Commands, file reads/writes, search, web and MCP tools are checked before they run. Can hand questions to Claude's own prompt."
        case .codex: "Shell, apply_patch and MCP calls are checked before they run. Codex has no native ask, so questions come to \(Brand.appName)."
        case .cursor: "Shell, file reads and MCP calls are checked before they run (fails closed). Edits are logged after they happen."
        case .gemini: "Every tool call is checked before it runs (allow or block)."
        case .windsurf: "Commands, reads, writes and MCP calls are checked before they run (block only)."
        case .cline: "Tool calls are checked before they run. Turn the hook on in Cline's Hooks tab."
        }
    }

    func tint(_ s: InstallState) -> Color {
        switch s { case .installed: Theme.ok; case .removed, .disabled: Theme.danger; case .notInstalled: Theme.caution; case .notDetected: .secondary }
    }
}

struct InstallPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    var body: some View {
        let (before, after) = model.installer.preview(agent)
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(Brand.appName) to \(agent.displayName)").font(.title2.weight(.semibold))
            Text("This writes \(Paths.tildify(model.installer.configPath(agent))). Everything already in the file stays; a copy is saved first so you can restore it.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                CodeBox(title: "Now", text: before.isEmpty ? "(file doesn't exist yet)" : before)
                CodeBox(title: "After", text: after)
            }
            if let f = model.installer.followUp(agent) { Label(f, systemImage: "info.circle") }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { model.install(agent); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
    }
}

struct CodeBox: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
