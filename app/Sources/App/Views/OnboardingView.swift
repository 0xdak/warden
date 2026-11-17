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
    @State private var touchedAgents = false
    @State private var confirmSkip = false
    /// Why "Install & continue" stayed on the policy step (nothing chosen).
    @State private var problem: String?

    /// The policy step couldn't protect anything yet: offer Retry / Skip instead of moving on silently.
    var stuck: Bool { problem != nil || !installErrors.isEmpty }

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
                if step > 0 && (step < 3 || !model.protection.hasProtection) { Button(step == 3 ? "Back to agents" : "Back") { step = step == 3 ? 1 : step - 1 } }
                Spacer()
                if step == 2 && stuck && model.protection.anyDetected {
                    Button("Skip for now") { confirmSkip = true }
                }
                if step < 3 {
                    Button(step == 2 ? installLabel : "Continue") { next() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                } else {
                    // Reaching here unprotected means no agent was found, or the user confirmed skipping.
                    Button("Finish") { model.finishOnboarding() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 520)
        .onAppear { model.refreshStates(); preselect() }
        .onChange(of: step) { _, new in if new == 1 { model.refreshStates(); preselect() } }
        .onChange(of: chosen) { problem = nil }
        .confirmationDialog("Continue without protection?", isPresented: $confirmSkip) {
            Button("Continue without protection", role: .destructive) { step = 3 }
            Button("Go back", role: .cancel) {}
        } message: { Text("No agent will send actions to \(Brand.appName), so nothing is checked or recorded. You can install it later from Agents.") }
    }

    /// Pre-selects detected agents until the user changes the list. Re-run on entry to the agents step,
    /// so a late detection (or an agent installed meanwhile) is still picked up.
    func preselect() {
        guard !touchedAgents else { return }
        chosen = Set(Agent.allCases.filter { model.installer.isDetected($0) || model.states[$0] == .installed })
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
                Toggle(isOn: Binding(get: { chosen.contains(a) }, set: { touchedAgents = true; if $0 { chosen.insert(a) } else { chosen.remove(a) } })) {
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
            if !model.protection.anyDetected {
                Label("No supported agent found on this Mac, so there's nothing to install yet.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.caution)
            }
            Toggle("Start by recording a baseline (observe only)", isOn: $observeFirst)
            Text("Recommended. For the first while nothing is stopped; \(Brand.appName) logs what it would have done. Switch to enforcing from Home when you're happy.")
                .font(.caption).foregroundStyle(.secondary)
            if let p = problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            }
            ForEach(installErrors, id: \.self) { e in errorRow(e) }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.protection.hasProtection {
                Text("You're set up").font(.title2.weight(.semibold))
            } else {
                Label("Nothing is protected yet", systemImage: "exclamationmark.triangle.fill").font(.title2.weight(.semibold)).foregroundStyle(Theme.caution)
                Text("No agent has the hook installed, so \(Brand.appName) can't see or stop anything. "
                     + (model.protection.anyDetected ? "When you're ready, open Agents \u{25B8} Install." : model.protection.warningBody))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(chosen).sorted { $0.rawValue < $1.rawValue }) { a in
                if model.states[a] == .installed, let f = model.installer.followUp(a) {
                    Label("\(a.displayName): \(f)", systemImage: a == .codex ? "exclamationmark.circle" : "checkmark.circle")
                }
            }
            ForEach(installErrors, id: \.self) { e in errorRow(e) }
            HStack {
                Button("Test the hook") { testResult = model.testRun() }
                Button("Show a sample question") { model.showSampleApproval() }
            }
            if let t = testResult { Text(t).font(.callout) }
            Toggle("Open \(Brand.appName) at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        }
    }

    var installLabel: String {
        if !installErrors.isEmpty { return "Retry" }
        return model.protection.anyDetected ? "Install & continue" : "Continue"
    }

    func errorRow(_ e: String) -> some View {
        Label("Couldn't install \u{2014} \(e)", systemImage: "xmark.octagon.fill")
            .foregroundStyle(Theme.danger).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    func next() {
        if step == 2 {
            model.update { $0.preset = preset; $0.mode = observeFirst ? .observe : .enforce }
            installErrors = []
            problem = nil
            model.refreshStates()
            // Nothing on this Mac to protect: let them finish; the last step says how to fix it.
            guard model.protection.anyDetected else { step = 3; return }
            if chosen.isEmpty && !model.protection.hasProtection {
                problem = "Pick at least one agent to protect. Go Back to choose one."
                return
            }
            for a in chosen.sorted(by: { $0.rawValue < $1.rawValue }) where model.states[a] != .installed {
                model.install(a)
                if let e = model.lastError { installErrors.append("\(a.displayName): \(e)"); model.lastError = nil }
                if case .disabled(let why)? = model.states[a] { installErrors.append("\(a.displayName): hooks are turned off there (\(why)).") }
            }
            model.toast = nil
            // Never move on with zero protected agents: stay here with the errors and a Retry.
            guard model.protection.hasProtection else {
                if installErrors.isEmpty { installErrors = ["the hook didn't take effect in any agent."] }
                return
            }
        }
        step += 1
    }
}
