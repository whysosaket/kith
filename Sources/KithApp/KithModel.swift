import AppKit
import Combine
import Foundation
import KithCore
import UserNotifications

enum FinishAction: String {
    case sleep
    case shutdown
}

enum FinishActionPhase {
    case waitingForWork
    case watchingWork
    case countdown(Int)
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case settings = "Settings"

    var id: String { rawValue }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case monitoring = "Monitoring"
    case notifications = "Notifications"
    case power = "Power"

    var id: String { rawValue }
}

@MainActor
final class KithModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var unavailable: Set<AgentSurface> = []
    @Published private(set) var hooksInstalled = false
    @Published private(set) var helperEnabled = false
    @Published private(set) var accessibilityEnabled = false
    @Published private(set) var idleHoldActive = false
    @Published private(set) var closedLidReady = false
    @Published private(set) var externalWakeOwner = false
    @Published private(set) var notificationIssue: String?
    @Published private(set) var message: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var armedAction: FinishAction?
    @Published var workspacePage: WorkspacePage = .sessions
    @Published var settingsPane: SettingsPane = .monitoring
    @Published var keepAwake: Bool {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }
    @Published var closedLid: Bool {
        didSet { UserDefaults.standard.set(closedLid, forKey: "closedLid") }
    }
    @Published var postRunMinutes: Int {
        didSet { UserDefaults.standard.set(postRunMinutes, forKey: "postRunMinutes") }
    }
    @Published var attentionSound: Bool {
        didSet { UserDefaults.standard.set(attentionSound, forKey: "attentionSound") }
    }
    @Published var completionSound: Bool {
        didSet { UserDefaults.standard.set(completionSound, forKey: "completionSound") }
    }
    @Published var automationValidated: Bool {
        didSet {
            UserDefaults.standard.set(automationValidated, forKey: "automationValidated")
            if !automationValidated { cancelAction() }
        }
    }

    private var store = SessionStore.load(from: KithPaths.sessionState)
    private let power = PowerClient()
    private var timer: Timer?
    private var scanning = false
    private var bootstrapComplete = false
    private var previousWork = false
    private var lastWorkEnded: Date?
    private var armedAt: Date?
    private var armedID: UUID?
    private var sawWorkWhileArmed = false
    private var countdownEnd: Date?
    private var lastNotificationCheck = Date.distantPast
    private var finalizing = false
    private var notifiedIDs: Set<String> = []
    private var eventSocket: EventSocket?
    private var notificationRouter: NotificationRouter?
    private let notifier = UNUserNotificationCenter.current()

    init() {
        let defaults = UserDefaults.standard
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        closedLid = defaults.bool(forKey: "closedLid")
        postRunMinutes = defaults.object(forKey: "postRunMinutes") as? Int ?? 5
        attentionSound = defaults.object(forKey: "attentionSound") as? Bool ?? true
        completionSound = defaults.object(forKey: "completionSound") as? Bool ?? true
        automationValidated = defaults.bool(forKey: "automationValidated")
        hooksInstalled = HookInstaller.isInstalled(executable: eventExecutable)
        helperEnabled = power.helperEnabled
        accessibilityEnabled = CodexAXProbe.trusted
        if let data = try? Data(contentsOf: KithPaths.state),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            notifiedIDs = ids
        }
        notificationRouter = NotificationRouter { [weak self] key in
            Task { @MainActor in
                if let session = self?.store.sessions[key] { self?.open(session) }
            }
        }
        notifier.delegate = notificationRouter
        notifier.setNotificationCategories(KithNotification.categories)
        notifier.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
        eventSocket = try? EventSocket.listen { [weak self] event in
            Task { @MainActor in self?.accept(event) }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var eventExecutable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("kith-event")
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var needsInputCount: Int { sessions.filter { $0.status == .needsInput }.count }
    var failedCount: Int { sessions.filter { $0.status == .failed }.count }
    var attentionCount: Int { needsInputCount + failedCount }
    var monitoringReady: Bool { bootstrapComplete }
    var hasMonitoringIssue: Bool { !hooksInstalled || !unavailable.isEmpty }
    var powerSummary: String {
        if closedLidReady {
            return externalWakeOwner ? "External closed-lid hold detected" : "Closed-lid hold active"
        }
        if idleHoldActive {
            return closedLid ? "Keeping awake · preparing lid hold" : "Keeping Mac awake"
        }
        if keepAwake || closedLid { return "Ready when agents work" }
        return "Awake protection is off"
    }

    var attentionSessions: [AgentSession] {
        sessions.filter { $0.status == .needsInput || $0.status == .failed }
            .sorted {
                if $0.status != $1.status { return $0.status == .needsInput }
                if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
                return $0.id < $1.id
            }
    }

    var workingSessions: [AgentSession] {
        sessions.filter { $0.status == .running }
    }

    var unconfirmedSessions: [AgentSession] {
        sessions.filter { $0.status == .unavailable }
    }

    var recentSessions: [AgentSession] {
        sessions.filter {
            let age = Date().timeIntervalSince($0.lastActivity)
            return $0.status == .ready && age >= 0 && age < 3_600
        }
    }

    var finishActionBlockReason: String? {
        if !automationValidated { return "Finish actions are locked until live validation is completed." }
        if !bootstrapComplete || !hooksInstalled || !unavailable.isEmpty {
            return "All four session monitors must be healthy before arming."
        }
        if !helperEnabled { return "Enable the power helper before arming a finish action." }
        return nil
    }

    var finishActionPhase: FinishActionPhase? {
        guard armedAction != nil else { return nil }
        if let countdown { return .countdown(countdown) }
        return sawWorkWhileArmed ? .watchingWork : .waitingForWork
    }

    func installHooks() {
        do {
            try HookInstaller.install(executable: eventExecutable)
            hooksInstalled = true
            message = "Hooks installed. Trust the new Codex hooks with /hooks."
        } catch { message = error.localizedDescription }
    }

    func removeHooks() {
        do {
            try HookInstaller.uninstall(executable: eventExecutable)
            hooksInstalled = false
            message = "Kith hooks removed."
        } catch { message = error.localizedDescription }
    }

    func enableHelper() {
        do {
            try power.registerHelper()
            helperEnabled = power.helperEnabled
            message = helperEnabled ? "Power helper enabled" :
                "Approve Kith in System Settings → General → Login Items & Extensions."
        } catch { message = error.localizedDescription }
    }

    func requestAccessibility() {
        CodexAXProbe.requestTrust()
        accessibilityEnabled = CodexAXProbe.trusted
        if accessibilityEnabled {
            message = "Accessibility enabled"
        } else {
            message = "Turn Kith off and back on under System Settings → Privacy & Security → Accessibility."
            showAccessibilitySettings()
        }
    }

    func showAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func disableHelper() {
        closedLid = false
        power.unregisterHelper { [weak self] error in
            guard let self else { return }
            helperEnabled = power.helperEnabled
            message = error?.localizedDescription ?? "Power helper disabled"
        }
    }

    func arm(_ action: FinishAction) {
        if let reason = finishActionBlockReason {
            message = reason
            return
        }
        armedAction = action
        armedAt = Date()
        let id = UUID()
        armedID = id
        sawWorkWhileArmed = sessions.contains { $0.status == .running || $0.status == .needsInput }
        countdownEnd = nil
        countdown = nil
        power.checkHelper { [weak self] success, response in
            guard let self, self.armedID == id, !success else { return }
            self.cancelAction()
            self.message = response
            self.notify(title: "Kith could not arm \(action.rawValue)", body: response,
                        sound: true, id: "action-error-\(UUID().uuidString)")
        }
    }

    func cancelAction() {
        armedAction = nil
        armedAt = nil
        armedID = nil
        sawWorkWhileArmed = false
        countdownEnd = nil
        countdown = nil
    }

    func clearMessage() { message = nil }

    func open(_ session: AgentSession) {
        switch session.surface {
        case .codexDesktop:
            let threadID = session.sessionID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            guard let url = threadID.flatMap({ URL(string: "codex://threads/\($0)") }) else {
                message = "Could not open Codex thread"
                return
            }
            NSWorkspace.shared.open(url)
        case .claudeDesktop:
            activateApplication("com.anthropic.claudefordesktop")
        case .claudeCLI, .codexCLI:
            if let bundleID = session.terminalBundleID {
                activateApplication(bundleID)
            } else {
                activateApplication("com.apple.Terminal")
                message = "Owning terminal could not be identified; opened Terminal."
            }
        }
    }

    private func activateApplication(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            message = "Application \(bundleID) was not found"
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.message = error.localizedDescription } }
        }
    }

    func testNotification() {
        if let notificationIssue {
            message = notificationIssue
            return
        }
        notify(title: "Kith test", body: "Notifications are working", sound: true, id: UUID().uuidString)
    }

    private func tick() {
        let installed = HookInstaller.isInstalled(executable: eventExecutable)
        if hooksInstalled != installed { hooksInstalled = installed }
        accessibilityEnabled = CodexAXProbe.trusted
        closedLidReady = power.closedLidReady
        externalWakeOwner = power.externalWakeOwner
        if Date().timeIntervalSince(lastNotificationCheck) >= 30 {
            lastNotificationCheck = Date()
            refreshNotificationStatus()
        }
        EventSpool.drain { event in accept(event) }
        if !scanning {
            scanning = true
            DispatchQueue.global(qos: .utility).async {
                let result = LocalReconciler.scan()
                Task { @MainActor in
                    self.scanning = false
                    self.applyScan(result)
                }
            }
        }
        updatePowerAndAction()
    }

    private func refreshNotificationStatus() {
        notifier.getNotificationSettings { [weak self] settings in
            let issue: String?
            if settings.authorizationStatus != .authorized {
                issue = "Enable Kith in System Settings → Notifications."
            } else if settings.soundSetting != .enabled {
                issue = "Enable notification sounds for Kith in System Settings → Notifications."
            } else {
                issue = nil
            }
            Task { @MainActor in self?.notificationIssue = issue }
        }
    }

    private func accept(_ event: AgentEvent) {
        let surface = surfaceForEvent(event)
        if let status = store.apply(event, surface: surface), bootstrapComplete {
            emitNotification(for: event, status: status)
        }
        sessions = store.sessions.values.sorted { $0.lastActivity > $1.lastActivity }
        try? store.save(to: KithPaths.sessionState)
        updatePowerAndAction()
    }

    private func applyScan(_ result: ReconcileResult) {
        unavailable = result.unavailable
        if !hooksInstalled { unavailable.formUnion(AgentSurface.allCases) }
        for observed in result.sessions {
            guard let status = store.reconcile(observed) else { continue }
            let session = store.sessions[observed.id] ?? observed
            switch status {
            case .ready where bootstrapComplete: notifyReady(session)
            case .needsInput:
                notify(session, status: status,
                       id: "attention-\(observed.sessionID)-\(observed.turnID ?? "")-\(observed.attentionID ?? "prompt")")
            case .failed:
                notify(session, status: status, id: "failed-\(observed.sessionID)-\(observed.turnID ?? "")")
            case .running: clearDeliveredNotifications(for: session.id)
            default: break
            }
        }
        store.markMissing(seenIDs: Set(result.sessions.map(\.id)),
                          olderThan: Date().addingTimeInterval(-10))
        unavailable.formUnion(store.sessions.values.filter { $0.status == .unavailable }.map(\.surface))
        if armedAction != nil && !unavailable.isEmpty {
            cancelAction()
            message = "A session monitor became unavailable"
            notify(title: "Kith canceled power action", body: "A session monitor became unavailable",
                   sound: true, id: "action-error-\(UUID().uuidString)")
        }
        sessions = store.sessions.values.sorted { $0.lastActivity > $1.lastActivity }
        try? store.save(to: KithPaths.sessionState)
        bootstrapComplete = true
        updatePowerAndAction()
    }

    private func surfaceForEvent(_ event: AgentEvent) -> AgentSurface {
        if let existing = store.sessions["\(event.source.rawValue):\(event.sessionID)"] {
            return existing.surface
        }
        return event.source == .claude ? .claudeCLI : .codexCLI
    }

    private func emitNotification(for event: AgentEvent, status: SessionStatus) {
        guard let session = store.sessions["\(event.source.rawValue):\(event.sessionID)"] else { return }
        switch status {
        case .needsInput:
            notify(session, status: status, detail: event.detail,
                   id: "attention-\(event.sessionID)-\(event.turnID ?? "")-\(event.attentionID ?? "prompt")")
        case .failed:
            notify(session, status: status, detail: event.detail,
                   id: "failed-\(event.sessionID)-\(event.turnID ?? "")")
        case .ready: notifyReady(session)
        case .running: clearDeliveredNotifications(for: session.id)
        case .unavailable: break
        }
    }

    private func notifyReady(_ session: AgentSession) {
        notify(session, status: .ready, id: "ready-\(session.sessionID)-\(session.turnID ?? "")")
    }

    /// Session alerts lead with the state and session name, then say why and where it opens.
    private func notify(_ session: AgentSession, status: SessionStatus, detail: String? = nil, id: String) {
        var context = [detail ?? status.notificationDetail, session.surface.title]
        if session.title != nil, let projectName = session.projectName { context.append(projectName) }
        notify(title: "\(status.notificationHeadline) · \(session.notificationName)",
               body: context.joined(separator: " · "),
               sound: status == .ready ? completionSound : attentionSound,
               id: id, session: session)
    }

    /// Keeps one notification per session so resolved prompts don't linger in Notification Center.
    private func clearDeliveredNotifications(for sessionKey: String, keeping id: String? = nil) {
        notifier.getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request)
                .filter { $0.content.threadIdentifier == sessionKey && $0.identifier != id }
                .map(\.identifier)
            if stale.isEmpty { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    private func notify(title: String, body: String, sound: Bool, id: String,
                        session: AgentSession? = nil) {
        guard notifiedIDs.insert(id).inserted else { return }
        if notifiedIDs.count > 2_000 { notifiedIDs = [id] }
        if (try? KithPaths.prepare()) != nil,
           let data = try? JSONEncoder().encode(notifiedIDs) {
            try? data.write(to: KithPaths.state, options: .atomic)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let session {
            clearDeliveredNotifications(for: session.id, keeping: id)
            content.userInfo = ["sessionKey": session.id]
            content.threadIdentifier = session.id
            content.categoryIdentifier = KithNotification.category(for: session.surface)
        }
        if sound { content.sound = .default }
        notifier.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            let description = error.localizedDescription
            Task { @MainActor in self?.message = "Notification delivery failed: \(description)" }
        }
    }

    private func updatePowerAndAction() {
        let now = Date()
        let work = sessions.contains { $0.status == .running || $0.status == .needsInput }
        if work {
            lastWorkEnded = nil
            if armedAction != nil { sawWorkWhileArmed = true }
            countdownEnd = nil
            countdown = nil
        } else if previousWork {
            lastWorkEnded = now
        }
        previousWork = work
        if let armedAt, now.timeIntervalSince(armedAt) >= 86_400 { cancelAction() }

        let extraHold = lastWorkEnded.map { now.timeIntervalSince($0) < Double(postRunMinutes * 60) } ?? false
        let shouldHold = (keepAwake || closedLid) && (work || extraHold)
        if !power.holdIdleSleep(shouldHold) {
            message = "Could not keep the Mac awake"
            cancelAction()
            notify(title: "Kith wake hold failed", body: "Could not keep the Mac awake",
                   sound: true, id: "power-error-idle")
        }
        idleHoldActive = power.idleHoldActive
        power.holdClosedLid(shouldHold && closedLid) { [weak self] error in
            if let error {
                self?.message = error
                self?.cancelAction()
                self?.notify(title: "Kith closed-lid hold failed", body: error,
                             sound: true, id: "power-error-\(error)")
            }
        }

        guard let action = armedAction, sawWorkWhileArmed, !work,
              automationValidated, hooksInstalled, helperEnabled, bootstrapComplete, unavailable.isEmpty,
              !sessions.isEmpty, store.allSafeToFinish,
              !finalizing else {
            countdownEnd = nil
            countdown = nil
            return
        }
        if countdownEnd == nil {
            countdownEnd = now.addingTimeInterval(60)
            notify(title: "Kith will \(action.rawValue) in 60 seconds",
                   body: "Open Kith to cancel", sound: true, id: "action-countdown")
        }
        countdown = max(0, Int(ceil(countdownEnd!.timeIntervalSince(now))))
        guard countdown == 0 else { return }
        guard !scanning else { return }
        let actionID = armedID
        finalizing = true
        countdownEnd = nil
        countdown = nil
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let finalScan = LocalReconciler.scan()
            Task { @MainActor in
                self.applyScan(finalScan)
                self.scanning = false
                self.finalizing = false
                guard self.armedID == actionID, self.armedAction == action else { return }
                if self.sessions.contains(where: { $0.status == .running || $0.status == .needsInput }) {
                    self.countdownEnd = nil
                    self.countdown = nil
                    return
                }
                guard self.automationValidated, self.hooksInstalled, self.helperEnabled,
                      self.unavailable.isEmpty, self.store.allSafeToFinish,
                      !self.sessions.isEmpty else {
                    self.cancelAction()
                    self.message = "Final monitor check blocked the power action"
                    self.notify(title: "Kith canceled \(action.rawValue)",
                                body: "Final monitor check failed", sound: true,
                                id: "action-error-\(UUID().uuidString)")
                    return
                }
                self.cancelAction()
                self.power.perform(action.rawValue) { [weak self] success, response in
                    if !success {
                        self?.message = response
                        self?.notify(title: "Kith could not \(action.rawValue)",
                                     body: response, sound: true,
                                     id: "action-error-\(UUID().uuidString)")
                    }
                }
            }
        }
    }
}
