import SwiftUI
import GuardCore

/// First run: welcome → agents → preset & baseline → install → test.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var chosen: Set<Agent> = []
    @State private var preset: Preset = .balanced
    @State private var observeFirst = true
    @State private var testResult: String?
    @State private var installErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0: welcome
            case 1: agents
            case 2: policy
            default: done
            }
            Spacer()
            HStack {
                if step > 0 && step < 3 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 {
                    Button(step == 2 ? "Install & continue" : "Continue") { next() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                } else {
                    Button("Finish") { model.finishOnboarding() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 520)
        .onAppear { chosen = Set(Agent.allCases.filter { model.installer.isDetected($0) }) }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.shield").font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Welcome to \(Brand.appName)").font(.largeTitle.weight(.semibold))
            Text(Brand.tagline).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Stops clear threats: secret reads, wipes, download-and-run, data leaving your Mac.", systemImage: "hand.raised")
                Label("Pauses judgment calls and asks you, right where you work.", systemImage: "questionmark.bubble")
                Label("Keeps a searchable record of everything your agents did.", systemImage: "list.bullet.rectangle")
                Label("Runs locally. No account, no telemetry, works offline.", systemImage: "lock")
            }.padding(.top, 8)
        }
    }

    var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which agents should \(Brand.appName) watch?").font(.title2.weight(.semibold))
            Text("We found these on your Mac. Each gets a hook in its own config file; a backup is saved first.").foregroundStyle(.secondary)
            ForEach(Agent.allCases) { a in
                let found = model.installer.isDetected(a)
                Toggle(isOn: Binding(get: { chosen.contains(a) }, set: { if $0 { chosen.insert(a) } else { chosen.remove(a) } })) {
                    HStack {
                        Text("Ask before \(a.displayName) acts")
                        Text(found ? "found" : "not found").font(.caption).foregroundStyle(found ? Theme.ok : .secondary)
                    }
                }
                .disabled(!found && model.states[a] != .installed)
            }
        }
    }

    var policy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How strict?").font(.title2.weight(.semibold))
            Picker("", selection: $preset) { ForEach(Preset.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text(preset.blurb).foregroundStyle(.secondary)
            Toggle("Start by recording a baseline (observe only)", isOn: $observeFirst)
            Text("Recommended. For the first while nothing is stopped; \(Brand.appName) logs what it would have done. Switch to enforcing from Home when you're happy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You're set up").font(.title2.weight(.semibold))
            ForEach(Array(chosen).sorted { $0.rawValue < $1.rawValue }) { a in
                if model.states[a] == .installed, let f = model.installer.followUp(a) {
                    Label("\(a.displayName): \(f)", systemImage: a == .codex ? "exclamationmark.circle" : "checkmark.circle")
                }
            }
            ForEach(installErrors, id: \.self) { Text($0).foregroundStyle(Theme.danger) }
            HStack {
                Button("Test the hook") { testResult = model.testRun() }
                Button("Show a sample question") { model.showSampleApproval() }
            }
            if let t = testResult { Text(t).font(.callout) }
            Toggle("Open \(Brand.appName) at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        }
    }

    func next() {
        if step == 2 {
            model.update { $0.preset = preset; $0.mode = observeFirst ? .observe : .enforce }
            installErrors = []
            for a in chosen where model.states[a] != .installed {
                model.lastError = nil
                model.install(a)
                if let e = model.lastError { installErrors.append("\(a.displayName): \(e)") }
            }
            model.toast = nil
        }
        step += 1
    }
}
