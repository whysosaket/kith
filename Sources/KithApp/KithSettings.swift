import SwiftUI
import KithCore

struct KithSettingsPage: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch model.settingsPane {
                case .general: GeneralSettings(workflow: model.workflow)
                case .monitoring: MonitoringSettings()
                case .notifications: NotificationSettings()
                case .power: KithPowerPage()
                case .afterWork: KithAfterWorkPage()
                }
            }
            .frame(maxWidth: 680)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct KithSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
        }
    }
}

struct KithSettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 46)
    }
}

struct KithToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        KithSettingsRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

struct KithSettingsHelp<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            Text(title).font(.caption)
        }
        .padding(14)
    }
}

private struct MonitoringSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        KithSettingsGroup(title: "Agent hooks") {
            KithSettingsRow(title: model.hooksInstalled ? "Hooks installed" : "Connect your agents",
                            subtitle: "Receive session updates from Claude Code and Codex.") {
                Button(model.hooksInstalled ? "Remove hooks" : "Install hooks") {
                    if model.hooksInstalled { model.removeHooks() }
                    else { model.installHooks() }
                }
            }
            Divider()
            KithSettingsHelp(title: "Setup instructions") {
                Text("After installation, run /hooks in Codex and trust Kith's entries. Install Kith in Applications first; moving the app means reinstalling hooks.")
            }
        }

        KithSettingsGroup(title: "Sources") {
            ForEach(AgentSurface.allCases, id: \.self) { surface in
                if surface != AgentSurface.allCases.first { Divider() }
                KithSettingsRow(title: surface.title) {
                    Label(status(for: surface), systemImage: available(surface) ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(available(surface) ? Color.secondary : Color.orange)
                }
            }
            if model.hasMonitoringIssue {
                Divider()
                Text("Finish actions stay paused until Kith can confirm all four sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
        }

        KithSettingsGroup(title: "Codex Desktop") {
            KithSettingsRow(title: "Accessibility access",
                            subtitle: model.accessibilityEnabled ? "Kith can detect requests for input." : "Needed to detect approval requests in Codex Desktop.") {
                if model.accessibilityEnabled {
                    Label("Enabled", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Grant access") { model.requestAccessibility() }
                }
            }
            Divider()
            KithSettingsHelp(title: "What Kith reads & troubleshooting") {
                Text("Kith reads button titles in Codex Desktop to detect approval requests. It does not read other apps through Accessibility.")
                Text("If access stops working after an update, remove Kith from Accessibility Settings and add it again.")
                Button("Open Accessibility Settings") { model.showAccessibilitySettings() }
            }
        }
    }

    private func available(_ surface: AgentSurface) -> Bool {
        model.hooksInstalled && model.monitoringReady && !model.unavailable.contains(surface)
    }

    private func status(for surface: AgentSurface) -> String {
        if !model.hooksInstalled { return "Needs setup" }
        if !model.monitoringReady { return "Checking…" }
        guard model.unavailable.contains(surface) else { return "Available" }
        return surface == .codexDesktop && !model.accessibilityEnabled ? "Needs access" : "Unavailable"
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        KithSettingsGroup(title: "Delivery") {
            KithSettingsRow(title: model.notificationIssue == nil ? "Notifications are ready" : "Notifications need attention",
                            subtitle: model.notificationIssue ?? "Jump back to the session from any alert.") {
                Button("Send test") { model.testNotification() }
                    .accessibilityLabel("Send test notification")
            }
        }

        KithSettingsGroup(title: "Sounds") {
            KithToggleRow(title: "Needs input or failed", subtitle: "Hear when an agent needs you.", isOn: $model.attentionSound)
            Divider()
            KithToggleRow(title: "Turn finished", subtitle: "Hear when an agent is ready for your next message.", isOn: $model.completionSound)
        }

        KithSettingsHelp(title: "Notification privacy") {
            Text("Alerts include session titles and project folder names. Adjust Kith's lock-screen previews in System Settings → Notifications.")
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var workflow: WorkflowSettings

    var body: some View {
        KithSettingsGroup(title: "Startup") {
            KithToggleRow(title: "Launch Kith at login", subtitle: "Keep your agents in view from the start.",
                          isOn: Binding(get: { workflow.launchAtLogin }, set: { workflow.setLaunchAtLogin($0) }))
            if let message = workflow.loginMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 14)
            }
        }
        .onAppear { workflow.refreshLogin() }

        KithSettingsGroup(title: "Updates") {
            KithSettingsRow(title: "Kith \(workflow.version)", subtitle: workflow.updateMessage) {
                Button(workflow.checkingUpdates ? "Checking…" : "Check for updates") { workflow.checkUpdates() }
                    .disabled(workflow.checkingUpdates)
            }
            if let url = workflow.releaseURL {
                Link("View release", destination: url).padding([.horizontal, .bottom], 14)
            }
            Divider()
            KithSettingsHelp(title: "How updates work") {
                Text("Checks run only when you ask and send a request to GitHub. Kith does not download or install updates.")
            }
        }

        Label("Session monitoring and power controls stay on your Mac.", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }
}
