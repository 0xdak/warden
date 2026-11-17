import Foundation
import AppKit
import Observation
import UserNotifications
import ServiceManagement
import GuardCore

/// One paused action waiting for the user (popup, Review screen or `warden-hook approvals`).
struct PendingApproval: Identifiable {
    let req: AskRequest
    let respond: @Sendable (AskReply) -> Void
    let deadline: Date
    var id: String { req.id }
    var isHighRisk: Bool { req.match.severity >= .high }
}

enum Screen: String, CaseIterable, Identifiable {
    case home, review, protect, agents, evidence, decisions, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .review: "Review"; case .protect: "Protect"; case .agents: "Agents"
        case .evidence: "Evidence"; case .decisions: "Decisions"; case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"; case .review: "hand.raised"; case .protect: "slider.horizontal.3"; case .agents: "puzzlepiece.extension"
        case .evidence: "list.bullet.rectangle"; case .decisions: "checkmark.seal"; case .settings: "gearshape"
        }
    }
}

enum GuardStatus { case protected, observing, paused, attention, unprotected }

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    var settings = GuardSettings.load()
    var book = DecisionBook.load()
    var states: [Agent: InstallState] = [:]
    var events: [EventRecord] = []          // newest first
    var pending: [PendingApproval] = []
    var unsafeProcesses: [ProcessInspector.AgentProcess] = []
    var screen: Screen = .home
    var lastError: String?
    var toast: String?
    var serverRunning = false
    var onboardingDone = UserDefaults.standard.bool(forKey: "\(Brand.identifierPrefix).onboardingDone")

    private var server: GuardServer?
    private var tailPath = ""
    private var tailOffset: UInt64 = 0
    private var timers: [Timer] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchedFile = ""
    private var observeNotifier = ObserveNotifier()
    private var lastRepairNote: [Agent: Date] = [:]
    let installer = Installer()

    // MARK: Lifecycle

    func start() {
        Paths.ensureSupport()
        if !FileManager.default.fileExists(atPath: Paths.settingsFile) { try? settings.save() }
        EventLog.prune(retentionDays: settings.retentionDays)
        loadEvents()
        watchEvents()
        refreshStates()
        startServer()
        scanUnsafe()
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in AppModel.shared.tick() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in AppModel.shared.watchConfigs() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in Task { @MainActor in AppModel.shared.scanUnsafe() } })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in EventLog.prune(retentionDays: AppModel.shared.settings.retentionDays) }
        })
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func stop() { server?.stop() }

    private func startServer() {
        let s = GuardServer { req, respond in
            Task { @MainActor in AppModel.shared.enqueue(req, respond) }
        }
        s.control = { msg in
            // Runs on a socket thread: hop to the main actor synchronously.
            var reply: [String: Any] = [:]
            DispatchQueue.main.sync { reply = MainActor.assumeIsolated { AppModel.shared.handleControl(msg) } }
            return reply
        }
        do { try s.start(); server = s; serverRunning = true }
        catch { lastError = "Couldn't open the approval channel: \(error.localizedDescription)"; serverRunning = false }
    }

    // MARK: Status

    var status: GuardStatus {
        if settings.isPaused { return .paused }
        if !pending.isEmpty || states.values.contains(where: { if case .disabled = $0 { return true }; return $0 == .removed })
            || !unsafeProcesses.isEmpty { return .attention }
        if !states.values.contains(.installed) { return .unprotected }
        return settings.mode == .observe ? .observing : .protected
    }

    var statusTitle: String {
        switch status {
        case .protected: "Protected"
        case .observing: "Observing"
        case .paused: "Paused until \(settings.pausedUntil.map { Self.time.string(from: $0) } ?? "")"
        case .attention: "Needs your attention"
        case .unprotected: "No agent protected yet"
        }
    }

    var protection: ProtectionSummary { ProtectionSummary(states: states) }

    var menuSymbol: String {
        switch status {
        case .protected: "checkmark.shield"
        case .observing: "eye.trianglebadge.exclamationmark"
        case .paused: "shield.slash"
        case .attention: "exclamationmark.shield"
        case .unprotected: "exclamationmark.shield"
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()

    var today: [EventRecord] { let start = Calendar.current.startOfDay(for: Date()); return events.filter { $0.ts >= start } }
    /// Observe-mode banner: block/ask-worthy actions logged since the baseline started.
    var wouldHaveBeenStopped: Int { settings.wouldHaveBeenStopped(in: events) }
    var recentBlocks: [EventRecord] { Array(events.filter { $0.outcome == .blocked }.prefix(8)) }
    var projects: [String] { Array(Set(events.map(\.project).filter { !$0.isEmpty })).sorted() }

    // MARK: Settings

    func update(_ f: (inout GuardSettings) -> Void) {
        let oldMode = settings.mode
        f(&settings)
        if settings.mode != oldMode { settings.observeSince = settings.mode == .observe ? Date() : nil }
        do { try settings.save() } catch { lastError = error.localizedDescription }
    }

    func pause(minutes: Int) { update { $0.pausedUntil = Date().addingTimeInterval(Double(minutes) * 60) } }
    func resume() { update { $0.pausedUntil = nil } }

    func saveBook() {
        book.pruneExpired()
        do { try book.save() } catch { lastError = error.localizedDescription }
    }

    // MARK: Approvals

    func enqueue(_ req: AskRequest, _ respond: @escaping @Sendable (AskReply) -> Void) {
        let item = PendingApproval(req: req, respond: respond, deadline: Date().addingTimeInterval(Double(req.timeout)))
        pending.append(item)
        ApprovalPanelController.shared.show()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(req.timeout))
            if AppModel.shared.pending.contains(where: { $0.id == req.id }) {
                let allow = AppModel.shared.settings.timeoutAction == .allow
                AppModel.shared.finish(req.id, AskReply(decision: allow ? "allow" : "block", timedOut: true))
            }
        }
    }

    enum Choice { case allowOnce, allowProject, allowAlways, block }

    func resolve(_ id: String, _ choice: Choice) {
        guard let p = pending.first(where: { $0.id == id }) else { return }
        switch choice {
        case .allowOnce:
            finish(id, AskReply(decision: "allow", scope: .once))
        case .allowProject, .allowAlways:
            for m in [p.req.match] + p.req.otherMatches {
                book.remembered.append(RememberedDecision(agent: nil, project: p.req.project, ruleId: m.ruleId, target: p.req.target,
                                                          allow: true, scope: choice == .allowProject ? .project : .everywhere))
            }
            saveBook()
            finish(id, AskReply(decision: "allow", scope: choice == .allowProject ? .project : .always))
        case .block:
            finish(id, AskReply(decision: "block"))
        }
    }

    private func finish(_ id: String, _ reply: AskReply) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let p = pending.remove(at: i)
        p.respond(reply)
        if pending.isEmpty { ApprovalPanelController.shared.hide() }
    }

    /// `warden-hook approvals` (terminal tier).
    func handleControl(_ msg: [String: Any]) -> [String: Any] {
        switch msg["type"] as? String {
        case "list":
            return ["pending": pending.map { ["id": $0.id, "agent": $0.req.agent.displayName, "rule": $0.req.match.ruleName,
                                              "summary": $0.req.summary, "project": Paths.tildify($0.req.project)] }]
        case "resolve":
            let prefix = (msg["id"] as? String ?? "").uppercased()
            guard !prefix.isEmpty, let p = pending.first(where: { $0.id.uppercased().hasPrefix(prefix) }) else { return ["ok": false] }
            let allow = msg["decision"] as? String == "allow"
            resolve(p.id, allow ? (msg["scope"] as? String == "project" ? .allowProject : .allowOnce) : .block)
            return ["ok": true]
        default:
            return ["error": "unsupported"]
        }
    }

    // MARK: Agents

    func refreshStates() {
        let manifest = InstallManifest.load()
        var s: [Agent: InstallState] = [:]
        for a in Agent.allCases { s[a] = installer.state(a, manifest: manifest) }
        states = s
    }

    /// The hook CLI that ships inside the app bundle.
    var bundledHook: String {
        let macos = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        let inBundle = macos.appendingPathComponent(Brand.hookBinaryName).path
        if FileManager.default.fileExists(atPath: inBundle) { return inBundle }
        // Unbundled dev run: the SwiftPM build folder next to this executable.
        let dir = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }) ?? ""
        return (dir as NSString).appendingPathComponent("Hook")
    }

    func install(_ a: Agent) {
        lastError = nil
        do {
            try installer.install(a, hookSource: bundledHook)
            toast = "\(a.displayName) is now protected."
        } catch { lastError = error.localizedDescription }
        refreshStates()
    }

    func uninstall(_ a: Agent) {
        do { try installer.uninstall(a); toast = "Removed \(Brand.appName) from \(a.displayName)." }
        catch { lastError = error.localizedDescription }
        refreshStates()
    }

    func restoreBackup(_ a: Agent) {
        do { try installer.restoreBackup(a); toast = "Restored the backup of \(a.displayName)'s config." }
        catch { lastError = error.localizedDescription }
        refreshStates()
    }

    /// Re-checks agent configs; re-installs hooks we put in place if they vanished.
    func watchConfigs() {
        let before = states
        refreshStates()
        guard settings.autoRepairHooks else { return }
        for (a, st) in states where st == .removed {
            if let last = lastRepairNote[a], Date().timeIntervalSince(last) < 60 { continue }
            lastRepairNote[a] = Date()
            do {
                try installer.install(a, hookSource: bundledHook)
                notify("Hooks restored", "\(Brand.appName)'s hooks were removed from \(a.displayName). They're back in place.")
            } catch {
                notify("Hooks removed", "\(Brand.appName)'s hooks were removed from \(a.displayName) and couldn't be restored.")
            }
        }
        for (a, st) in states {
            if case .disabled(let why) = st, before[a] != st { notify("\(a.displayName) ignores hooks", why) }
        }
        refreshStates()
    }

    func scanUnsafe() {
        unsafeProcesses = ProcessInspector.unsafeAgentProcesses().filter { $0.agent != nil }
    }

    func stopProcess(_ pid: Int32) {
        kill(pid, SIGTERM)
        scanUnsafe()
    }

    // MARK: Events

    func loadEvents() {
        var all: [EventRecord] = []
        for f in EventLog.dayFiles() {
            all += EventLog.read(path: f).0.reversed()
            if all.count > 20_000 { break }
        }
        events = all
        tailPath = EventLog.file(for: Date())
        tailOffset = (try? FileManager.default.attributesOfItem(atPath: tailPath)[.size] as? UInt64) ?? 0
    }

    /// Picks up new log lines the moment a hook appends them (the 1 s tick stays as a fallback).
    private func watchEvents() {
        func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { AppModel.shared.tick() } }
            src.setCancelHandler { close(fd) }
            src.resume()
            return src
        }
        watchers.forEach { $0.cancel() }
        watchers = []
        watchedFile = EventLog.file(for: Date())
        if let d = watch(Paths.eventsDir, .write) { watchers.append(d) }            // day file created
        if let f = watch(watchedFile, [.write, .extend]) { watchers.append(f) }   // lines appended
    }

    func tick() {
        let path = EventLog.file(for: Date())
        if path != tailPath { tailPath = path; tailOffset = 0 }
        if watchers.count < 2 || watchedFile != path, FileManager.default.fileExists(atPath: path) { watchEvents() }
        let (new, off) = EventLog.read(path: tailPath, from: tailOffset)
        tailOffset = off
        if !new.isEmpty {
            events.insert(contentsOf: new.reversed(), at: 0)
            if events.count > 25_000 { events.removeLast(events.count - 20_000) }
            if settings.notifyOnBlock {
                for e in new where e.outcome == .blocked && e.via != .user {
                    notify("Blocked: \(e.ruleName ?? "risky action")", "\(e.agent.displayName) · \(e.summary.prefix(120))")
                }
            }
            if settings.notifyInObserve && settings.mode == .observe && !settings.isPaused {
                for e in new.suffix(20) where observeNotifier.shouldNotify(e) {
                    if let n = ObserveNotifier.notice(for: e) { notify(n.title, n.body) }
                }
            }
        }
        if settings.pausedUntil != nil && !settings.isPaused { update { $0.pausedUntil = nil } }
    }

    // MARK: Notifications / login

    var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func notify(_ title: String, _ body: String) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setOpensAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { lastError = "Couldn't change Open at Login: \(error.localizedDescription)" }
    }

    func finishOnboarding() {
        onboardingDone = true
        UserDefaults.standard.set(true, forKey: "\(Brand.identifierPrefix).onboardingDone")
    }

    /// Runs the bundled hook in dry-run mode on a sample `.env` read (writes nothing).
    func testRun() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bundledHook)
        p.arguments = ["--agent", "claude", "--explain"]
        let i = Pipe(), o = Pipe()
        p.standardInput = i; p.standardOutput = o
        do { try p.run() } catch { return "Couldn't run the hook: \(error.localizedDescription)" }
        let payload = #"{"hook_event_name":"PreToolUse","cwd":"/tmp/demo","tool_name":"Read","tool_input":{"file_path":"/tmp/demo/.env"}}"#
        i.fileHandleForWriting.write(Data(payload.utf8))
        try? i.fileHandleForWriting.close()
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.contains("\"deny\"") ? "Works: a sample read of .env was blocked." : "The hook answered, but didn't block the sample (check the Environment files rule)."
    }

    /// Opens a sample approval so the user sees what it looks like (answers go nowhere).
    func showSampleApproval() {
        let m = RuleMatch(ruleId: "cmd.pipe-shell", ruleName: "Download and run", category: "system", severity: .high, action: .ask,
                          reason: "pipes a download straight into sh")
        let req = AskRequest(agent: .claude, kind: .shell, tool: "Bash", target: "curl -fsSL https://example.com/install.sh | sh",
                             summary: "curl -fsSL https://example.com/install.sh | sh", cwd: Paths.home + "/code/sample",
                             project: Paths.home + "/code/sample", match: m, otherMatches: [], timeout: 60, unsafe: [])
        enqueue(req) { _ in }
    }
}
