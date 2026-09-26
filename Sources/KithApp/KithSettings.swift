import SwiftUI
import KithCore

struct KithSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                KithPageHeader(
                    title: model.settingsPane.rawValue,
                    subtitle: model.settingsPane == .monitoring ?
                        "Check how Kith follows your coding sessions." :
                        "Choose how Kith alerts you when work changes."
                )
                Spacer(minLength: 12)
                Picker("Settings", selection: $model.settingsPane) {
                    ForEach(SettingsPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 245)
            }

            KithMessageView()
            Divider()

            ScrollView {
                if model.settingsPane == .monitoring {
                    MonitoringSettings()
                } else {
                    NotificationSettings()
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

private struct MonitoringSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            KithSection("Agent hooks") {
                LabeledContent("Status", value: model.hooksInstalled ? "Installed" : "Not installed")
                if model.hooksInstalled {
                    Button("Remove hooks") { model.removeHooks() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Install hooks") { model.installHooks() }
                        .buttonStyle(.bordered)
                }
                Text("After installation, trust Kith's Codex hooks with /hooks in Codex.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            KithSection("Sources") {
                ForEach(AgentSurface.allCases, id: \.self) { surface in
                    LabeledContent(surface.title, value: status(for: surface))
                }
                if !model.unavailable.isEmpty && model.hooksInstalled {
                    Text("Kith cannot confirm work from an unavailable source. Finish actions remain blocked.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            KithSection("Codex Desktop Accessibility") {
                LabeledContent("Access", value: model.accessibilityEnabled ? "Enabled" : "Not enabled")
                if !model.accessibilityEnabled {
                    HStack(spacing: 10) {
                        Button("Grant Accessibility") { model.requestAccessibility() }
                        Button("Open Accessibility Settings") { model.showAccessibilitySettings() }
                    }
                    .buttonStyle(.bordered)
                }
                Text("If macOS rejects access after an app update, turn Kith off and back on in Accessibility Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(for surface: AgentSurface) -> String {
        if !model.hooksInstalled { return "Needs setup" }
        if !model.monitoringReady { return "Checking" }
        return model.unavailable.contains(surface) ? "Unavailable" : "Available"
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            KithSection("Delivery") {
                if let issue = model.notificationIssue {
                    Label(issue, systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Status", value: "Ready")
                }
                Button("Send test notification") { model.testNotification() }
                    .buttonStyle(.bordered)
            }

            Divider()

            KithSection("Sounds") {
                Toggle("Attention requests and failures", isOn: $model.attentionSound)
                Toggle("Finished turns", isOn: $model.completionSound)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
