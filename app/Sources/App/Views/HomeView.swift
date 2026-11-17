import SwiftUI
import GuardCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop: ProcessInspector.AgentProcess?

    var body: some View {
        Page(title: model.statusTitle, subtitle: "What needs your attention right now.") {
            if !model.protection.hasProtection {
                let p = model.protection
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution).font(.title2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No agent is protected. \(Brand.appName) can't see anything yet.").font(.headline)
                            Text(p.warningBody).foregroundStyle(.secondary)
                            HStack {
                                if let a = p.firstInstallable {
                                    Button("Install\u{2026}") { model.screen = .agents }.buttonStyle(.borderedProminent).tint(Theme.accent)
                                    Button("Protect \(a.displayName) now") { model.install(a) }
                                } else {
                                    Button("See supported agents") { NSWorkspace.shared.open(Brand.website) }
                                    Button("Open Agents") { model.screen = .agents }
                                }
                            }
                            if let e = model.lastError { Text(e).font(.caption).foregroundStyle(Theme.danger) }
                        }
                        Spacer()
                    }
                }
            } else if model.settings.mode == .observe {
                Card {
                    HStack(alignment: .top) {
                        Image(systemName: "eye").foregroundStyle(Theme.accent).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            let n = model.wouldHaveBeenStopped
                            Text("Observe mode: recording only, nothing is blocked").font(.headline)
                            Text("\(n) \(n == 1 ? "action" : "actions") would have been blocked or asked about so far. Tune rules in Protect, then start enforcing.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Start enforcing") { model.update { $0.mode = .enforce } }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
            if model.settings.isPaused {
                Card {
                    HStack {
                        Image(systemName: "pause.circle").foregroundStyle(Theme.caution).font(.title2)
                        Text("Protection is paused. Guard files stay protected.").font(.headline)
                        Spacer()
                        Button("Resume now") { model.resume() }
                    }
                }
            }
            if !model.pending.isEmpty {
                Card(title: "Waiting for you") {
                    ForEach(model.pending) { p in
                        HStack {
                            SeverityBadge(severity: p.req.match.severity)
                            Text(p.req.summary).font(.system(.callout, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text(p.req.agent.displayName).foregroundStyle(.secondary)
                        }
                    }
                    Button("Review") { model.screen = .review }
                }
            }
            if !model.unsafeProcesses.isEmpty {
                Card(title: "Agents running with safety prompts off") {
                    ForEach(model.unsafeProcesses) { p in
                        HStack {
                            Image(systemName: "bolt.trianglebadge.exclamationmark").foregroundStyle(Theme.danger)
                            VStack(alignment: .leading) {
                                Text("\(p.agent?.displayName ?? "Agent") (pid \(p.pid))").font(.callout.weight(.medium))
                                Text(p.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop…") { confirmStop = p }
                        }
                    }
                    Text("\(Brand.appName)'s hooks still run in these sessions, but the agent won't ask you before acting.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                StatTile(value: model.today.count, label: "Actions today")
                StatTile(value: model.today.filter { $0.outcome == .blocked }.count, label: "Blocked today", tint: Theme.danger)
                StatTile(value: model.today.filter { $0.via == .user }.count, label: "Answered by you", tint: Theme.caution)
                StatTile(value: model.today.filter { $0.outcome == .observed }.count, label: "Logged for review")
            }
            Card(title: "Agents") {
                ForEach(Agent.allCases) { a in
                    let st = model.states[a] ?? .notDetected
                    HStack {
                        Circle().fill(color(st)).frame(width: 8, height: 8)
                        Text(a.displayName)
                        Spacer()
                        Text(st.title).foregroundStyle(.secondary)
                    }
                }
                Button("Manage agents") { model.screen = .agents }
            }
            Card(title: "Recent blocks") {
                if model.recentBlocks.isEmpty {
                    Text("Nothing blocked yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentBlocks) { EventRow(e: $0) }
                    Button("See all activity") { model.screen = .evidence }
                }
            }
        }
        .confirmationDialog("Stop this agent session?", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }),
                            presenting: confirmStop) { p in
            Button("Stop pid \(p.pid)", role: .destructive) { model.stopProcess(p.pid) }
        } message: { p in Text("Sends a normal quit signal to \(p.executable). Unsaved agent work in that session may be lost.") }
    }

    func color(_ s: InstallState) -> Color {
        switch s {
        case .installed: Theme.ok; case .removed, .disabled: Theme.danger; case .notInstalled: Theme.caution; case .notDetected: .secondary.opacity(0.4)
        }
    }
}
