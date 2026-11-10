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
    case general = "General"
    case monitoring = "Monitoring"
    case notifications = "Notifications"
    case power = "Power"
    case afterWork = "After work"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .monitoring: "waveform.path.ecg"
        case .notifications: "bell"
        case .power: "bolt"
        case .afterWork: "moon"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Make Kith at home on your Mac."
        case .monitoring: "Connect your agents and check their status."
        case .notifications: "Choose when Kith gets your attention."
        case .power: "Keep your Mac ready while agents work."
        case .afterWork: "Choose what happens when every agent is done."
        }
    }
}

@MainActor
final class KithModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var unavailable: Set<AgentSurface> = []
    @Published private(set) var hooksInstalled = false
    @Published private(set) var helperEnabled = false
    @Published private(set) var accessibilityEnabled = false
    @Published private(set) var idleHoldActive = false
    @Published private(set) var legacyPowerRecoveryPending = false
    @Published private(set) var systemSleepDisabled = false
    @Published private(set) var notificationIssue: String?
    @Published private(set) var message: String?
    @Published private(set) var countdown: Int?
    @Published private(set) var armedAction: FinishAction?
    @Published var powerPreferences = PowerPreferences() {
        didSet {
            do {
                try PowerStorage.write(powerPreferences.validated(), to: KithPaths.powerPreferences)
                if powerInbox != nil { controlIssue = nil }
            }
            catch { message = error.localizedDescription }
        }
    }
    @Published private(set) var powerStatus = PowerHelperStatus()
    @Published private(set) var conditions = PowerConditions()
    @Published private(set) var wakeDeadline: Date?
    @Published private(set) var wakeStopped: WakeStop?
    @Published private(set) var manualWakeActive = false
    @Published private(set) var displayHoldActive = false
    @Published private(set) var networkWarning = false
    @Published private(set) var audioPending: [SavedAudioMute] = []
    @Published private(set) var audioIssue: String?
    @Published private(set) var controlIssue: String?
    let workflow = WorkflowSettings()
    @Published var workspacePage: WorkspacePage = .sessions
    @Published var settingsPane: SettingsPane = .monitoring
    @Published var keepAwake: Bool {
        didSet { KithTesting.defaults.set(keepAwake, forKey: "keepAwake") }
    }
    @Published var postRunMinutes: Int {
        didSet { KithTesting.defaults.set(postRunMinutes, forKey: "postRunMinutes") }
    }
    @Published var attentionSound: Bool {
        didSet { KithTesting.defaults.set(attentionSound, forKey: "attentionSound") }
    }
    @Published var completionSound: Bool {
        didSet { KithTesting.defaults.set(completionSound, forKey: "completionSound") }
    }
    @Published var automationValidated: Bool {
        didSet {
            KithTesting.defaults.set(automationValidated, forKey: "automationValidated")
            if !automationValidated { cancelAction() }
        }
    }

    private var store = SessionStore.load(from: KithPaths.sessionState)
    private let power = PowerClient()
    private let powerSession = PowerSession(stateURL: KithPaths.powerState)
    private let powerMonitor = PowerSystemMonitor()
    private let audioRecovery = AudioRecovery(hardware: MacAudioHardware(),
        stateURL: KithPaths.support.appendingPathComponent("audio-recovery.json"))
    private let diagnostics = PowerDiagnostics(url: KithPaths.support.appendingPathComponent("power-diagnostics.json"))
    private var powerInbox: PowerCommandInbox?
    private var connectivity = ConnectivityState()
    private var batteryChanged = false
    private var lastPowerWarning: String?
    private var lastHelperCheck = Date.distantPast
    private var audioRestoreRequired = true
    #if DEBUG
    private var lastFixtureRevision: Int?
    private var fixtureNetwork: Bool?
    #endif
    private var timer: Timer?
    private var scanning = false
    private var bootstrapComplete = false
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
    private let persistenceQueue = DispatchQueue(label: "app.trykith.kith.persistence", qos: .utility)
    private var persistenceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var publishedStoreRevision: UInt64?
    private var savedStoreRevision: UInt64?
    private var notificationRevision: UInt64 = 0
    private var savedNotificationRevision: UInt64 = 0
    private var pendingSpoolFiles: Set<URL> = []
    private var terminationObserver: AnyCancellable?

    init() {
        let defaults = KithTesting.defaults
        do { powerPreferences = try PowerStorage.read(PowerPreferences.self, from: KithPaths.powerPreferences)?.validated() ?? PowerPreferences() }
        catch { controlIssue = "Power settings could not be read. Review and save them in Settings → Power." }
        do { powerInbox = try PowerCommandInbox(directory: KithPaths.powerCommands) }
        catch { controlIssue = error.localizedDescription }
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
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
        if !KithTesting.enabled && powerInbox != nil {
            notifier.delegate = notificationRouter
            notifier.setNotificationCategories(KithNotification.categories)
            notifier.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshNotificationStatus() }
            }
            eventSocket = try? EventSocket.listen { [weak self] event in
                Task { @MainActor in self?.accept(event) }
            }
        }
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.powerInbox != nil { self?.flushState() }
                    self?.powerMonitor.stop()
                    self?.power.holdIdleSleep(false)
                    _ = self?.power.holdDisplay(until: nil)
                    if !KithTesting.enabled && self?.powerInbox != nil { self?.audioRecovery.restore() }
                    KithTesting.cleanUp()
                }
            }
        power.onError = { [weak self] error in
            guard let self else { return }
            self.message = error
            self.cancelAction()
            self.diagnostics.record("Power helper: " + error)
        }
        powerMonitor.onChange = { [weak self] conditions, batteryChanged in
            guard let self else { return }
            self.conditions = conditions
            self.batteryChanged = self.batteryChanged || batteryChanged
            self.updatePowerAndAction()
        }
        powerMonitor.onNetworkChange = { [weak self] in self?.updateConnectivity() }
        if !KithTesting.enabled && powerInbox != nil {
            audioRecovery.restore()
            workflow.refreshLogin()
            powerMonitor.start()
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
    private var hasWork: Bool {
        store.sessions.values.contains { $0.status == .running || $0.status == .needsInput }
    }
    var powerSummary: String {
        if let controlIssue { return controlIssue }
        if let wakeStopped { return wakeStopped.message }
        if powerRecoveryPending { return "Power recovery needs attention" }
        if systemSleepDisabled { return "macOS sleep is disabled system-wide" }
        if idleHoldActive { return "Keeping Mac awake" }
        if keepAwake { return "Ready when agents work" }
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
        if let controlIssue { return controlIssue }
        if manualWakeActive { return "End the manual wake period before arming a finish action." }
        if let wakeStopped { return wakeStopped.message + ". Resume awake protection before arming." }
        if powerRecoveryPending || audioIssue != nil || audioRecoveryPending || (!hasWork && !audioPending.isEmpty) {
            return "Resolve pending power recovery before arming."
        }
        if !automationValidated { return "Finish actions are locked until live validation is completed." }
        if !bootstrapComplete || !hooksInstalled || !unavailable.isEmpty {
            return "All four session monitors must be healthy before arming."
        }
        if !helperEnabled { return "Enable the power helper before arming a finish action." }
        return nil
    }

    var powerRecoveryPending: Bool { legacyPowerRecoveryPending || powerStatus.recovery != .restored }

    var audioRecoveryPending: Bool { audioRestoreRequired && !audioPending.isEmpty }

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
        sawWorkWhileArmed = hasWork
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
                focusTerminal(bundleID, tty: session.terminalTTY)
            } else {
                activateApplication("com.apple.Terminal")
                message = "Owning terminal could not be identified; opened Terminal."
            }
        }
    }

    /// Selects the session's own tab first where the terminal can be scripted, so activating shows it.
    private func focusTerminal(_ bundleID: String, tty: String?) {
        guard let tty, let script = TerminalTabScript.byBundleID[bundleID] else {
            activateApplication(bundleID)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, tty]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let selected = process.terminationStatus == 0
            Task { @MainActor in
                self.activateApplication(bundleID)
                if !selected {
                    self.message = "Could not select the session's tab. Allow Kith under System Settings → Privacy & Security → Automation."
                }
            }
        }
        do { try process.run() } catch { activateApplication(bundleID) }
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

    func startManualWake(seconds: TimeInterval) { _ = handlePowerCommand(PowerCommand(kind: .start, seconds: seconds)) }
    func extendWake(seconds: TimeInterval = 3600) { _ = handlePowerCommand(PowerCommand(kind: .extend, seconds: seconds)) }
    func endWake() { _ = handlePowerCommand(PowerCommand(kind: .end)) }
    func resumeWake() { _ = handlePowerCommand(PowerCommand(kind: .resume)) }

    func retryPowerRecovery() {
        power.retryRecovery()
        audioRecovery.restore()
        publishPowerState()
    }

    func stopWaitingForAudio(_ id: UUID) {
        do { try audioRecovery.stopWaiting(id: id); publishPowerState() }
        catch { message = error.localizedDescription }
    }

    func copyPowerDiagnostics() {
        NSPasteboard.general.clearContents()
        let text = [powerStatus.recovery.title, powerStatus.detail, powerSession.issue, audioIssue, diagnostics.text]
            .compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.setString(text, forType: .string)
        message = "Power diagnostics copied. Review them before sharing."
    }

    private func handlePowerCommand(_ command: PowerCommand) -> PowerCommandReply {
        do {
            if command.kind != .status {
                guard controlIssue == nil else { throw PowerError.unavailable(controlIssue!) }
                try powerSession.apply(command, now: Date(), conditions: conditions, preferences: powerPreferences)
                if command.kind == .start || command.kind == .end { cancelAction() }
                if command.kind == .resume { keepAwake = true }
                diagnostics.record("Power control: " + command.kind.rawValue)
            }
            updatePowerAndAction()
            let status = PowerControlStatus(requested: power.idleHoldActive,
                manual: manualWakeActive, deadline: wakeDeadline, stopped: wakeStopped,
                conditions: conditions, helper: powerStatus, idleHoldActive: power.idleHoldActive,
                displayHoldActive: power.displayHoldActive, networkWarning: networkWarning,
                finishActionArmed: armedAction != nil)
            return PowerCommandReply(ok: true, message: command.kind == .status ? powerSummary : "Wake request acknowledged", status: status)
        } catch {
            message = error.localizedDescription
            return PowerCommandReply(ok: false, message: error.localizedDescription)
        }
    }

    private func publishPowerState() {
        let period = powerSession.policy.period
        if wakeDeadline != period?.deadline { wakeDeadline = period?.deadline }
        if wakeStopped != powerSession.policy.stopped { wakeStopped = powerSession.policy.stopped }
        let manual = period?.manual == true && wakeStopped == nil
        if manualWakeActive != manual { manualWakeActive = manual }
        if idleHoldActive != power.idleHoldActive { idleHoldActive = power.idleHoldActive }
        if displayHoldActive != power.displayHoldActive { displayHoldActive = power.displayHoldActive }
        if powerStatus != power.helperStatus { powerStatus = power.helperStatus }
        if audioPending != audioRecovery.pending { audioPending = audioRecovery.pending }
        if audioIssue != audioRecovery.issue { audioIssue = audioRecovery.issue }
        if let issue = powerSession.issue { message = issue }
    }

    private func updateConnectivity() {
        let active = powerPreferences.networkAlerts && (hasWork || manualWakeActive)
        var available = powerMonitor.networkAvailable
        #if DEBUG
        if KithTesting.enabled { available = fixtureNetwork }
        #endif
        if let event = connectivity.update(available: available, active: active, now: Date()) {
            switch event {
            case .lost:
                notify(title: "Kith network unavailable", body: "Active work may need connectivity. Open the session to check.",
                       sound: true, id: "power-network")
                diagnostics.record("Network unavailable during active work")
            case .restored(let seconds):
                notify(title: "Kith network available", body: "Network availability returned after \(seconds) seconds. Check the agent's state.",
                       sound: false, id: "power-network")
                diagnostics.record("Network availability restored")
            }
        }
        if networkWarning != connectivity.warning { networkWarning = connectivity.warning }
    }

    private func updatePowerWarnings(active: Bool) {
        var warning: String?
        if active && conditions.heat == .serious { warning = "The Mac is reporting serious heat. Critical heat will stop awake protection." }
        if active, !conditions.onAC, case .percent(let percent) = conditions.battery, percent <= powerPreferences.batteryWarning {
            warning = "Battery is below \(powerPreferences.batteryWarning)%. Awake protection stops at \(powerPreferences.batteryFloor)%."
        }
        if warning != lastPowerWarning, let warning {
            notify(title: "Kith power warning", body: warning, sound: true, id: "power-condition-warning")
        }
        lastPowerWarning = warning
    }

    private func tick() {
        #if DEBUG
        if KithTesting.enabled { integrationTick(); return }
        #endif
        guard powerInbox != nil else { return }
        if helperEnabled != power.helperEnabled {
            helperEnabled = power.helperEnabled
            cancelAction()
            if helperEnabled { power.refreshHelper() }
        }
        powerInbox?.drain { [weak self] command in
            self?.handlePowerCommand(command) ?? PowerCommandReply(ok: false, message: "Kith is closing")
        }
        powerMonitor.refreshLid()
        let pendingRecovery = FileManager.default.fileExists(atPath: PowerService.recoveryStateURL.path)
        if legacyPowerRecoveryPending != pendingRecovery { legacyPowerRecoveryPending = pendingRecovery }
        if systemSleepDisabled != powerMonitor.systemSleepDisabled { systemSleepDisabled = powerMonitor.systemSleepDisabled }
        if Date().timeIntervalSince(lastHelperCheck) >= 30 {
            lastHelperCheck = Date()
            power.refreshHelper()
            workflow.refreshLogin()
        }
        let installed = HookInstaller.isInstalled(executable: eventExecutable)
        if hooksInstalled != installed { hooksInstalled = installed }
        let trusted = CodexAXProbe.trusted
        if accessibilityEnabled != trusted { accessibilityEnabled = trusted }
        if Date().timeIntervalSince(lastNotificationCheck) >= 30 {
            lastNotificationCheck = Date()
            refreshNotificationStatus()
        }
        if !scanning {
            scanning = true
            DispatchQueue.global(qos: .utility).async {
                let pending = EventSpool.pending()
                let result = LocalReconciler.scan()
                Task { @MainActor in
                    self.pendingSpoolFiles.formUnion(pending.map { $0.file })
                    self.applyEvents(pending.map { $0.event })
                    self.scanning = false
                    self.applyScan(result)
                }
            }
        }
        updatePowerAndAction()
    }

    #if DEBUG
    private func integrationTick() {
        if let fixture = try? PowerStorage.read(PowerTestFixture.self,
            from: KithPaths.support.appendingPathComponent("fixture.json")) {
            conditions = fixture.conditions
            fixtureNetwork = fixture.networkAvailable
            batteryChanged = fixture.revision != lastFixtureRevision
            if batteryChanged && fixture.armFinishAction == true { armedAction = .sleep; armedAt = Date() }
            lastFixtureRevision = fixture.revision
            let status = SessionStatus(rawValue: fixture.status) ?? .unavailable
            let observed = AgentSession(source: .codex, surface: .codexCLI, sessionID: "e2e",
                                        status: status, lastActivity: Date())
            _ = store.reconcile(observed)
            sessions = Array(store.sessions.values)
            hooksInstalled = true
            bootstrapComplete = true
            unavailable = status == .unavailable ? [.codexCLI] : []
        }
        updatePowerAndAction()
        powerInbox?.drain { handlePowerCommand($0) }
    }
    #endif

    private func refreshNotificationStatus() {
        if KithTesting.enabled { return }
        notifier.getNotificationSettings { [weak self] settings in
            let issue: String?
            if settings.authorizationStatus != .authorized {
                issue = "Enable Kith in System Settings → Notifications."
            } else if settings.soundSetting != .enabled {
                issue = "Enable notification sounds for Kith in System Settings → Notifications."
            } else {
                issue = nil
            }
            Task { @MainActor in
                if self?.notificationIssue != issue { self?.notificationIssue = issue }
            }
        }
    }

    private func accept(_ event: AgentEvent) {
        applyEvents([event])
        guard refreshTask == nil else { return }
        // Apply safety state immediately, then publish a socket burst together on the next frame.
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refreshSessions()
            self.updatePowerAndAction()
        }
    }

    private func applyEvents(_ events: [AgentEvent]) {
        for event in events {
            let status = store.apply(event, surface: surfaceForEvent(event))
            let session = store.sessions["\(event.source.rawValue):\(event.sessionID)"]
            if session?.status == .running || session?.status == .needsInput { recordWork() }
            if let status, bootstrapComplete { emitNotification(for: event, status: status) }
        }
    }

    private func applyScan(_ result: ReconcileResult) {
        var unavailable = result.unavailable
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
        if self.unavailable != unavailable { self.unavailable = unavailable }
        if armedAction != nil && !unavailable.isEmpty {
            cancelAction()
            message = "A session monitor became unavailable"
            notify(title: "Kith canceled power action", body: "A session monitor became unavailable",
                   sound: true, id: "action-error-\(UUID().uuidString)")
        }
        refreshSessions()
        bootstrapComplete = true
        updatePowerAndAction()
    }

    private func refreshSessions() {
        store.pruneCompleted(olderThan: Date().addingTimeInterval(-86_400))
        if publishedStoreRevision != store.revision {
            let updated = store.sessions.values.sorted { $0.lastActivity > $1.lastActivity }
            if sessions != updated { sessions = updated }
            publishedStoreRevision = store.revision
        }
        schedulePersistence()
    }

    private func schedulePersistence() {
        guard persistenceTask == nil,
              savedStoreRevision != store.revision || savedNotificationRevision != notificationRevision ||
                !pendingSpoolFiles.isEmpty else { return }
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.store
            let ids = self.notifiedIDs
            let notificationRevision = self.notificationRevision
            let spoolFiles = self.pendingSpoolFiles
            let saveSessions = self.savedStoreRevision != snapshot.revision
            let saveNotifications = self.savedNotificationRevision != notificationRevision
            let saved = await withCheckedContinuation { continuation in
                self.persistenceQueue.async {
                    continuation.resume(returning: Self.writeState(snapshot, notifiedIDs: ids,
                        saveSessions: saveSessions, saveNotifications: saveNotifications, spoolFiles: spoolFiles))
                }
            }
            if saved {
                self.savedStoreRevision = snapshot.revision
                self.savedNotificationRevision = notificationRevision
                self.pendingSpoolFiles.subtract(spoolFiles)
            }
            self.persistenceTask = nil
            // A change during the write gets a new snapshot; failed writes retry on the next refresh.
            if self.store.revision != snapshot.revision || self.notificationRevision != notificationRevision ||
                !self.pendingSpoolFiles.isSubset(of: spoolFiles) {
                self.schedulePersistence()
            }
        }
    }

    private func flushState() {
        let pending = EventSpool.pending()
        pendingSpoolFiles.formUnion(pending.map { $0.file })
        applyEvents(pending.map { $0.event })
        persistenceTask?.cancel()
        refreshTask?.cancel()
        let snapshot = store
        let ids = notifiedIDs
        let spoolFiles = pendingSpoolFiles
        let saveSessions = savedStoreRevision != snapshot.revision
        let saveNotifications = savedNotificationRevision != notificationRevision
        persistenceQueue.sync {
            _ = Self.writeState(snapshot, notifiedIDs: ids,
                                saveSessions: saveSessions, saveNotifications: saveNotifications, spoolFiles: spoolFiles)
        }
    }

    private nonisolated static func writeState(_ store: SessionStore, notifiedIDs: Set<String>,
                                              saveSessions: Bool, saveNotifications: Bool,
                                              spoolFiles: Set<URL>) -> Bool {
        do {
            if saveSessions { try store.save(to: KithPaths.sessionState) }
            if saveNotifications {
                if !saveSessions { try KithPaths.prepare() }
                try JSONEncoder().encode(notifiedIDs).write(to: KithPaths.state, options: .atomic)
            }
            // Keep queued events replayable until their state has reached disk.
            for file in spoolFiles { try? FileManager.default.removeItem(at: file) }
            return true
        } catch { return false }
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
        if KithTesting.enabled { return }
        guard notifiedIDs.insert(id).inserted else { return }
        if notifiedIDs.count > 2_000 { notifiedIDs = [id] }
        notificationRevision &+= 1
        schedulePersistence()
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

    private func recordWork() {
        if armedAction != nil { sawWorkWhileArmed = true }
        countdownEnd = nil
        if countdown != nil { countdown = nil }
    }

    private func updatePowerAndAction() {
        guard powerInbox != nil else { return }
        let now = Date()
        let work = hasWork
        if work { recordWork() }
        if let armedAt, now.timeIntervalSince(armedAt) >= 86_400 { cancelAction() }
        var decision = powerSession.update(now: now, work: work, monitoringReady: bootstrapComplete,
            automaticEnabled: keepAwake, graceSeconds: Double(postRunMinutes * 60),
            conditions: conditions, preferences: powerPreferences, batteryChanged: batteryChanged)
        batteryChanged = false
        if controlIssue != nil {
            decision.hold = false
            decision.display = false
        }
        if let stop = decision.stop, wakeStopped != stop {
            diagnostics.record(stop.message)
            if stop != .user {
                notify(title: "Kith awake protection stopped", body: stop.message,
                       sound: true, id: "power-stop-" + (powerSession.policy.period?.id.uuidString ?? "state"))
            }
        }
        if decision.stop != nil { cancelAction() }
        if decision.reminder, let deadline = powerSession.policy.period?.deadline {
            notify(title: "Kith awake protection ends soon",
                   body: "Protection ends at \(deadline.formatted(date: .omitted, time: .shortened)). Extend it in Power.",
                   sound: true, id: "power-deadline-reminder")
        }
        let deadline = powerSession.policy.period?.deadline
        let idleApplied = power.holdIdleSleep(decision.hold, until: deadline)
        let displayApplied = power.holdDisplay(until: decision.display ? deadline : nil)
        if !idleApplied || !displayApplied {
            message = "Could not apply awake protection"
            diagnostics.record("Could not apply system or display wake assertion")
            cancelAction()
        }
        let shouldMute = decision.hold && powerPreferences.muteWithLidClosed && conditions.lidClosed && (armedAction == nil || work)
        audioRestoreRequired = !shouldMute
        if !KithTesting.enabled && shouldMute {
            audioRecovery.muteDefaultOutput()
        } else if !KithTesting.enabled { audioRecovery.restore() }
        publishPowerState()
        updateConnectivity()
        updatePowerWarnings(active: decision.hold)
        if !KithTesting.enabled { workflow.refreshBrowsers(enabled: decision.hold && powerPreferences.browserDiagnostics) }
        if decision.stop != nil || controlIssue != nil || manualWakeActive || powerRecoveryPending ||
            audioIssue != nil || audioRecoveryPending {
            if armedAction != nil {
                cancelAction()
                message = "Kith canceled the finish action because power recovery or awake protection needs attention"
            }
            return
        }

        guard let action = armedAction, sawWorkWhileArmed, !work,
              automationValidated, hooksInstalled, helperEnabled, bootstrapComplete, unavailable.isEmpty,
              !store.sessions.isEmpty, store.allSafeToFinish,
              !finalizing else {
            countdownEnd = nil
            if countdown != nil { countdown = nil }
            return
        }
        if countdownEnd == nil {
            countdownEnd = now.addingTimeInterval(60)
            notify(title: "Kith will \(action.rawValue) in 60 seconds",
                   body: "Open Kith to cancel", sound: true, id: "action-countdown")
        }
        let remaining = max(0, Int(ceil(countdownEnd!.timeIntervalSince(now))))
        if countdown != remaining { countdown = remaining }
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
                if self.hasWork {
                    self.countdownEnd = nil
                    self.countdown = nil
                    return
                }
                guard self.automationValidated, self.hooksInstalled, self.helperEnabled,
                      self.unavailable.isEmpty, self.store.allSafeToFinish,
                      !self.store.sessions.isEmpty, !self.manualWakeActive,
                      self.wakeStopped == nil, self.controlIssue == nil,
                      !self.powerRecoveryPending, self.audioIssue == nil,
                      self.audioPending.isEmpty else {
                    self.cancelAction()
                    self.message = "Final monitor check blocked the power action"
                    self.notify(title: "Kith canceled \(action.rawValue)",
                                body: "Final monitor check failed", sound: true,
                                id: "action-error-\(UUID().uuidString)")
                    return
                }
                self.cancelAction()
                self.power.perform(action.rawValue) { [weak self = self] success, response in
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
