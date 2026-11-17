import SwiftUI
import GuardCore

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.menuSymbol).font(.title2).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Brand.appName).font(.headline)
                    Text(model.statusTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !model.pending.isEmpty {
                Button { MainWindow.show(.review) } label: {
                    Label("\(model.pending.count) waiting for your answer", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderedProminent).tint(Theme.caution)
            }
            HStack(spacing: 8) {
                StatTile(value: model.today.count, label: "Actions today")
                StatTile(value: model.today.filter { $0.outcome == .blocked }.count, label: "Blocked", tint: Theme.danger)
                StatTile(value: model.today.filter { $0.via == .user || $0.outcome == .asked }.count, label: "Asked", tint: Theme.caution)
            }
            if !model.recentBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent blocks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.recentBlocks.prefix(4)) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.summary).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            Text("\(e.agent.displayName) · \(e.ruleName ?? "") · \(Text(e.ts, style: .relative)) ago")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.unsafeProcesses.isEmpty {
                Label("\(model.unsafeProcesses.count) agent session(s) running with safety prompts off", systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            Divider()
            if model.settings.isPaused {
                Button("Resume protection") { model.resume() }
            } else {
                HStack {
                    Text("Pause").foregroundStyle(.secondary)
                    Button("15 min") { model.pause(minutes: 15) }
                    Button("1 hour") { model.pause(minutes: 60) }
                }
            }
            HStack {
                Button("Open \(Brand.appName)") { MainWindow.show(.home) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var statusColor: Color {
        switch model.status {
        case .protected: Theme.ok; case .observing: Theme.accent; case .paused, .attention: Theme.caution; case .unprotected: .secondary
        }
    }
}
