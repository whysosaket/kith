import AppKit
import SwiftUI
import KithCore

@main
struct KithApp: App {
    @StateObject private var model = KithModel()

    var body: some Scene {
        MenuBarExtra {
            KithMenu().environmentObject(model)
        } label: {
            Image(nsImage: KithMenuBarIcon.image)
                .accessibilityLabel(model.needsInputCount > 0 ? "Kith needs input" :
                    model.runningCount > 0 ? "Kith has running sessions" : "Kith")
        }
        .menuBarExtraStyle(.window)

        Settings {
            KithSettings().environmentObject(model)
        }
    }
}

@MainActor
private enum KithMenuBarIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "KithMenuBarTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Kith") ?? NSImage()
    }()
}

private struct KithMenu: View {
    private enum Tab: String {
        case overview = "Overview"
        case sessions = "Sessions"
    }

    @EnvironmentObject var model: KithModel
    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: Tab = .overview

    private var runningSessions: [AgentSession] {
        model.sessions.filter { $0.status == .running }
    }

    private var needsInputSessions: [AgentSession] {
        model.sessions.filter { $0.status == .needsInput }
    }

    private var otherSessions: [AgentSession] {
        model.sessions.filter { $0.status != .running && $0.status != .needsInput }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Kith").font(.headline)
                Spacer()
                Text("\(model.runningCount) running · \(model.needsInputCount) need input")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(model.readyCount) ready")
                Text("\(model.failedCount) failed")
                Text("\(model.unavailable.count) unavailable")
                if let battery = model.batteryPercent { Text("Battery \(battery)%") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !model.unavailable.isEmpty {
                Label("Monitor unavailable: \(model.unavailable.map(\.title).sorted().joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                if model.unavailable.contains(.codexDesktop) && !model.accessibilityEnabled {
                    Text("Kith cannot use Accessibility yet. Turn Kith off and back on in System Settings after an app update.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") { model.showAccessibilitySettings() }
                        .font(.caption)
                }
            }
            if let issue = model.notificationIssue {
                Label(issue, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            Picker("View", selection: $selectedTab) {
                Text("Overview").tag(Tab.overview)
                Text("Sessions").tag(Tab.sessions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedTab == .overview {
                overviewContent
            } else {
                sessionsContent
            }

            if let action = model.armedAction {
                HStack {
                    Text("\(action.rawValue.capitalized) armed")
                    if let countdown = model.countdown { Text("\(countdown)s") }
                    Spacer()
                    Button("Cancel") { model.cancelAction() }
                }
                .font(.caption)
                if action == .shutdown {
                    Text("Shutdown may discard unsaved work in other apps.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Settings") { openSettings() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 390)
        .frame(minHeight: 390, alignment: .top)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            let attentionSessions = model.sessions.filter {
                $0.status == .needsInput || $0.status == .failed
            }
            if !attentionSessions.isEmpty {
                Text("Needs attention").font(.subheadline.weight(.semibold))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(attentionSessions) { session in sessionRow(session) }
                    }
                }
                .frame(maxHeight: 150)
            }
            Divider()
            Toggle("Keep awake while working", isOn: $model.keepAwake)
            Toggle("Allow closed-lid work", isOn: $model.closedLid)
                .disabled(!model.helperEnabled)
            if model.closedLid && model.runningCount > 0 {
                Text(model.closedLidReady ?
                     (model.externalWakeOwner ? "External closed-lid hold detected" : "Closed-lid hold active") :
                    "Preparing closed-lid hold")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.armedAction == nil {
                HStack {
                    Button("Sleep when done") { model.arm(.sleep) }
                        .disabled(!model.automationValidated)
                    Button("Shut down when done") { model.arm(.shutdown) }
                        .disabled(!model.automationValidated)
                }
                .font(.caption)
            }
        }
    }

    private var sessionsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if runningSessions.isEmpty && needsInputSessions.isEmpty {
                    Text(model.unavailable.isEmpty ? "No sessions are running." :
                         "No active sessions confirmed while a monitor is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !runningSessions.isEmpty {
                    sessionSection("Running", sessions: runningSessions)
                }
                if !needsInputSessions.isEmpty {
                    sessionSection("Needs input", sessions: needsInputSessions)
                }
                if !otherSessions.isEmpty {
                    sessionSection("Other sessions", sessions: otherSessions)
                }
            }
        }
        .frame(maxHeight: 400)
    }

    private func sessionSection(_ title: String, sessions: [AgentSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(sessions.count))").font(.subheadline.weight(.semibold))
            ForEach(sessions) { session in sessionRow(session) }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let projectName = session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let details = [session.surface.title, projectName,
                       session.status == .needsInput ? "needs input" : session.status.rawValue]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack {
            Image(systemName: icon(for: session.status))
                .foregroundStyle(color(for: session.status))
            VStack(alignment: .leading) {
                Text(session.title ?? projectName ?? session.surface.title)
                    .lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(session.lastActivity, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Open") { model.open(session) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private func icon(for status: SessionStatus) -> String {
        switch status {
        case .running: "bolt.fill"
        case .needsInput: "exclamationmark.bubble.fill"
        case .ready: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .running: .blue
        case .needsInput: .orange
        case .ready: .green
        case .failed: .red
        case .unavailable: .gray
        }
    }
}

private struct KithSettings: View {
    @EnvironmentObject var model: KithModel

    var body: some View {
        Form {
            Section("Integrations") {
                LabeledContent("Agent hooks", value: model.hooksInstalled ? "Installed" : "Not installed")
                HStack {
                    Button("Install hooks") { model.installHooks() }
                    Button("Remove hooks") { model.removeHooks() }
                }
                LabeledContent("Closed-lid helper", value: model.helperEnabled ? "Enabled" : "Not enabled")
                LabeledContent("Codex Desktop Accessibility", value: model.accessibilityEnabled ? "Enabled" : "Not enabled")
                Button("Grant Accessibility") { model.requestAccessibility() }
                Button("Enable power helper") { model.enableHelper() }
                if model.helperEnabled {
                    Button("Disable power helper") { model.disableHelper() }
                }
                Text("Codex asks you to trust the installed hooks with /hooks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                if let issue = model.notificationIssue {
                    Text(issue).foregroundStyle(.orange)
                }
                Toggle("Sound for attention and failures", isOn: $model.attentionSound)
                Toggle("Sound for completed turns", isOn: $model.completionSound)
                Button("Send test notification") { model.testNotification() }
            }
            Section("Power") {
                Toggle("Keep awake while working", isOn: $model.keepAwake)
                Toggle("Allow closed-lid work", isOn: $model.closedLid)
                    .disabled(!model.helperEnabled)
                Picker("Extra awake time", selection: $model.postRunMinutes) {
                    ForEach([0, 5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Text("Closed-lid mode uses an undocumented system setting. Avoid another closed-lid utility at the same time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Finish actions") {
                Toggle("Enable after live validation", isOn: $model.automationValidated)
                Text("Validate all four clients and closed-lid work on AC and battery before enabling sleep or shutdown.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Shutdown can discard unsaved work in other apps.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 540)
    }
}
