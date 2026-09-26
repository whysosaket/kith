import SwiftUI
import KithCore

struct KithSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.settingsPane) {
                MonitoringSettings()
                    .tabItem { Label("Monitoring", systemImage: "waveform.path.ecg") }
                    .tag(SettingsPane.monitoring)
                NotificationSettings()
                    .tabItem { Label("Notifications", systemImage: "bell") }
                    .tag(SettingsPane.notifications)
                PowerSettings()
                    .tabItem { Label("Power", systemImage: "power") }
                    .tag(SettingsPane.power)
            }
            KithMessageView()
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
        .frame(width: 520, height: 500)
    }
}

private struct MonitoringSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        Form {
            Section("Agent hooks") {
                LabeledContent("Status", value: model.hooksInstalled ? "Installed" : "Not installed")
                if !model.hooksInstalled {
                    Button("Install hooks") { model.installHooks() }
                } else {
                    Button("Remove hooks") { model.removeHooks() }
                }
                Text("After installation, trust Kith's Codex hooks with /hooks in Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sources") {
                ForEach(AgentSurface.allCases, id: \.self) { surface in
                    LabeledContent(surface.title,
                                   value: !model.hooksInstalled ? "Needs setup" :
                                   !model.monitoringReady ? "Checking" :
                                   model.unavailable.contains(surface) ? "Unavailable" : "Available")
                }
                if !model.unavailable.isEmpty && model.hooksInstalled {
                    Text("Kith cannot confirm work from an unavailable source. Finish actions remain blocked.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Codex Desktop Accessibility") {
                LabeledContent("Access", value: model.accessibilityEnabled ? "Enabled" : "Not enabled")
                if !model.accessibilityEnabled {
                    Button("Grant Accessibility") { model.requestAccessibility() }
                    Button("Open Accessibility Settings") { model.showAccessibilitySettings() }
                }
                Text("If macOS rejects access after an app update, turn Kith off and back on in Accessibility Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        Form {
            Section("Delivery") {
                if let issue = model.notificationIssue {
                    Label(issue, systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Status", value: "Ready")
                }
                Button("Send test notification") { model.testNotification() }
            }
            Section("Sounds") {
                Toggle("Attention requests and failures", isOn: $model.attentionSound)
                Toggle("Finished turns", isOn: $model.completionSound)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PowerSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        Form {
            Section("Awake protection") {
                Toggle("Keep awake while working", isOn: $model.keepAwake)
                LabeledContent("Current state", value: model.idleHoldActive ? "Holding awake" : "No active hold")
                Picker("Extra awake time", selection: $model.postRunMinutes) {
                    ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
            }
            Section("Closed-lid work") {
                Toggle("Allow closed-lid work", isOn: $model.closedLid)
                    .disabled(!model.helperEnabled)
                LabeledContent("Helper", value: model.helperEnabled ? "Enabled" : "Not enabled")
                if model.helperEnabled {
                    Button("Disable power helper") { model.disableHelper() }
                } else {
                    Button("Enable power helper") { model.enableHelper() }
                    Text("Enable the helper before using closed-lid work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Closed-lid mode uses an undocumented system setting. Avoid another closed-lid utility at the same time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Finish actions") {
                Toggle("Enable after live validation", isOn: $model.automationValidated)
                Text("Validate all four clients and closed-lid work on AC and battery before enabling sleep or shutdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.armedAction != nil {
                    Button("Cancel armed action") { model.cancelAction() }
                }
                Text("Shutdown may discard unsaved work in other apps.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }
}
