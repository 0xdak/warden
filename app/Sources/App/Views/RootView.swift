import SwiftUI
import GuardCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Screen.allCases, selection: Binding(get: { model.screen }, set: { if let s = $0 { model.screen = s } })) { s in
                Label {
                    HStack {
                        Text(s.title)
                        if s == .review, !model.pending.isEmpty {
                            Spacer()
                            Text("\(model.pending.count)").font(.caption.bold()).padding(.horizontal, 6)
                                .background(Theme.caution, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                } icon: { Image(systemName: s.symbol) }
                .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if let err = model.lastError {
                    Banner(text: err, color: Theme.danger) { model.lastError = nil }
                }
                if let t = model.toast {
                    Banner(text: t, color: Theme.ok) { model.toast = nil }
                }
                Group {
                    switch model.screen {
                    case .home: HomeView()
                    case .review: ReviewView()
                    case .protect: ProtectView()
                    case .agents: AgentsView()
                    case .evidence: EvidenceView()
                    case .decisions: DecisionsView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: Binding(get: { !model.onboardingDone }, set: { if !$0 { model.finishOnboarding() } })) {
            OnboardingView().environment(model)
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.callout)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(color.opacity(0.15))
    }
}

/// Page scaffold: title + subtitle + scrolling content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if let s = subtitle { Text(s).foregroundStyle(.secondary) }
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
