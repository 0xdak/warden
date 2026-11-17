import AppKit
import SwiftUI
import GuardCore

/// Floating panel that sits above the terminal/IDE and takes keyboard focus without activating the whole app.
final class ApprovalNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ApprovalPanelController {
    static let shared = ApprovalPanelController()
    private var panel: ApprovalNSPanel?

    func show() {
        if panel == nil {
            let p = ApprovalNSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                    styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                    backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ApprovalPopup().environment(AppModel.shared))
            p.contentView = host
            panel = p
        }
        guard let p = panel else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.maxY - 460))
        }
        p.orderFrontRegardless()
        p.makeKey()
    }

    func hide() { panel?.orderOut(nil) }
}

struct ApprovalPopup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let p = model.pending.first {
            ApprovalCard(item: p, queued: model.pending.count - 1, compact: false)
                .padding(20)
                .frame(width: 520)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Nothing waiting").padding(30)
        }
    }
}

/// Used in the popup and on the Review screen.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let item: PendingApproval
    var queued: Int = 0
    var compact: Bool

    var body: some View {
        let r = item.req
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: item.isHighRisk ? "exclamationmark.shield.fill" : "questionmark.diamond.fill")
                    .font(.system(size: 26)).foregroundStyle(item.isHighRisk ? Theme.danger : Theme.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(r.agent.displayName) wants to \(verb(r.kind))").font(.headline)
                    Text("in \(Paths.tildify(r.project))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SeverityBadge(severity: r.match.severity)
            }
            ScrollView {
                Text(r.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: compact ? 80 : 120)
            .padding(10).background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Label { Text("**\(r.match.ruleName)**: this \(r.match.reason).") } icon: { Image(systemName: "list.bullet.clipboard") }
                ForEach(r.otherMatches, id: \.ruleId) { m in
                    Label { Text("Also: \(m.ruleName) (\(m.reason))") } icon: { Image(systemName: "plus.circle") }.foregroundStyle(.secondary)
                }
                ForEach(r.unsafe, id: \.self) { u in
                    Label("Safety prompts are off for this agent: \(u)", systemImage: "bolt.trianglebadge.exclamationmark").foregroundStyle(Theme.danger)
                }
            }.font(.callout)

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(item.deadline.timeIntervalSince(ctx.date)))
                    Text("\(model.settings.timeoutAction == .block ? "Blocks" : "Allows") in \(left)s")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if queued > 0 { Text("· \(queued) more waiting").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(role: .destructive) { model.resolve(item.id, .block) } label: { Text("Block").frame(minWidth: 60) }
                    .modifier(DefaultIf(item.isHighRisk))
                    .keyboardShortcut(item.isHighRisk ? .defaultAction : .cancelAction)
                Spacer()
                Button("Always allow") { model.resolve(item.id, .allowAlways) }
                    .help("Allow this exact action in every project from now on")
                Button("Allow for project") { model.resolve(item.id, .allowProject) }
                    .help("Allow this exact action in \(Paths.tildify(r.project)) from now on")
                Button { model.resolve(item.id, .allowOnce) } label: { Text("Allow once").frame(minWidth: 70) }
                    .modifier(DefaultIf(!item.isHighRisk))
                    .keyboardShortcut(item.isHighRisk ? nil : KeyboardShortcut.defaultAction)
                if item.isHighRisk {   // Esc blocks too
                    Button("") { model.resolve(item.id, .block) }.keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0)
                }
            }
            if item.isHighRisk && !compact {
                Text("High risk: Return and Esc both block.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    func verb(_ k: ActionKind) -> String {
        switch k {
        case .shell: "run a command"; case .read: "read a file"; case .write: "change a file"; case .search: "search files"
        case .web: "fetch from the web"; case .mcp: "use an MCP tool"; default: "do something"
        }
    }
}

struct DefaultIf: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent).tint(Theme.accent) } else { content }
    }
}
