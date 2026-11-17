import SwiftUI
import GuardCore

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(title: "Review", subtitle: "Paused actions wait here until you answer. You can also answer from the floating popup or with `\(Brand.hookBinaryName) approvals` in a terminal.") {
            if model.pending.isEmpty {
                Card { Label("Nothing is waiting for you.", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            ForEach(model.pending) { p in
                Card { ApprovalCard(item: p, compact: true) }
            }
            Card(title: "Recently answered") {
                let answered = model.events.filter { $0.via == .user || $0.via == .timeout || $0.via == .nativePrompt }.prefix(15)
                if answered.isEmpty { Text("No answers yet.").foregroundStyle(.secondary) }
                ForEach(Array(answered)) { e in
                    HStack { EventRow(e: e); Text(e.via.title).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !model.serverRunning {
                Text("The approval channel isn't running, so agents fall back to their own prompts or to your fallback setting.")
                    .foregroundStyle(Theme.danger)
            }
        }
    }
}
