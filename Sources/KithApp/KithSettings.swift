import SwiftUI
import KithCore

struct KithSettingsPage: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        if #available(macOS 26.0, *) {
            content
                .padding(16)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Settings section", selection: $model.settingsPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")

            Divider()

            if model.settingsPane == .power {
                KithPowerPage()
            } else {
                ScrollView {
                    if model.settingsPane == .monitoring {
                        MonitoringSettings()
                    } else {
                        NotificationSettings()
                    }
                }
            }
        }
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
        guard model.unavailable.contains(surface) else { return "Available" }
        return surface == .codexDesktop && !model.accessibilityEnabled ? "Needs Accessibility" : "Unavailable"
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
