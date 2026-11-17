import SwiftUI
import GuardCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var loginOn = false

    var body: some View {
        let s = model.settings
        Form {
            Section("Questions") {
                Picker("Wait for an answer", selection: bind(\.askTimeout)) {
                    Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("1 minute").tag(60); Text("2 minutes").tag(120)
                }
                Picker("If nobody answers", selection: bind(\.timeoutAction)) {
                    Text("Block").tag(Fallback.block); Text("Allow").tag(Fallback.allow)
                }
                Picker("If \(Brand.appName) isn't running", selection: bind(\.noAppFallback)) {
                    Text("Block").tag(Fallback.block); Text("Allow").tag(Fallback.allow)
                }
                Text("Claude Code and Cursor (commands, MCP) fall back to their own prompt instead. Hard blocks always apply, app running or not.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use the agent's own prompt when it has one", isOn: bind(\.preferNativeAsk))
            }
            Section("Agents") {
                Toggle("Put hooks back automatically if they're removed", isOn: bind(\.autoRepairHooks))
                Toggle("Notify me when something is blocked", isOn: bind(\.notifyOnBlock))
                Toggle("In observe mode, notify me when something would have been blocked", isOn: bind(\.notifyInObserve))
            }
            Section("Evidence") {
                Picker("Keep activity for", selection: bind(\.retentionDays)) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }
                LabeledContent("Stored in", value: Paths.tildify(Paths.eventsDir))
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { loginOn }, set: { loginOn = $0; model.setOpensAtLogin($0) }))
                Button("Run setup again") { model.onboardingDone = false }
            }
            Section("Privacy") {
                Text("\(Brand.appName) works offline. No account, no telemetry. Commands, paths, code and logs never leave this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: "\(Brand.version) (\(Brand.build))")
                LabeledContent("Hook program", value: Paths.tildify(Paths.installedHook))
                LabeledContent("Preset", value: s.preset.title)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginOn = model.opensAtLogin }
    }

    func bind<T>(_ kp: WritableKeyPath<GuardSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }
}
