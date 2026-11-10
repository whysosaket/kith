import KithCore
import SwiftUI

struct KithPowerPage: View {
    @EnvironmentObject private var model: KithModel

    private var recoveryNeedsAttention: Bool {
        model.powerRecoveryPending || model.audioIssue != nil || model.audioRecoveryPending
    }

    var body: some View {
        KithWakeTimer()

        if model.wakeStopped != nil || recoveryNeedsAttention || model.systemSleepDisabled || model.networkWarning || model.controlIssue != nil {
            KithPowerHealthView(showAction: false)
            if model.wakeStopped != nil {
                Button("Resume awake protection") { model.resumeWake() }
                    .disabled(model.controlIssue != nil)
            }
        }
        if recoveryNeedsAttention { recoverySection }

        KithSettingsGroup(title: "While agents work") {
            KithToggleRow(title: "Keep Mac awake", subtitle: model.idleHoldActive ? "Awake protection is active." : "Prevent idle sleep during agent work.", isOn: $model.keepAwake)
            Divider()
            KithSettingsRow(title: "Extra time after work") {
                Picker("Extra time after work", selection: $model.postRunMinutes) {
                    ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes == 0 ? "None" : "\(minutes) minutes").tag(minutes)
                    }
                }
                .labelsHidden().frame(width: 140)
            }
            Divider()
            KithSettingsRow(title: "Maximum awake time") {
                Picker("Maximum awake time", selection: $model.powerPreferences.maximumSeconds) {
                    ForEach([1, 2, 4, 8, 24], id: \.self) { hours in
                        Text("\(hours) \(hours == 1 ? "hour" : "hours")").tag(TimeInterval(hours * 3600))
                    }
                }
                .labelsHidden().frame(width: 140)
            }
            Divider()
            KithToggleRow(title: "Keep display awake", subtitle: "For computer use. Can leave the screen unlocked.", isOn: $model.powerPreferences.keepDisplayAwake)
            Divider()
            KithSettingsHelp(title: "How awake periods work") {
                Text("Extra time starts when the last active turn ends. It cannot extend the current deadline. Maximum-time changes apply to the next period.")
                Text("Display wake prevents idle display sleep. An explicit lock still applies.")
                Text("macOS controls sleep when you close the lid. For closed-lid work, use a supported external display setup.")
            }
        }

        KithSettingsGroup(title: "Power helper") {
            KithSettingsRow(title: "Helper status", subtitle: model.helperEnabled ? "Enabled on this Mac." : "Runs finish actions and restores saved power settings.") {
                Button(model.helperEnabled ? "Disable helper" : "Set up helper") {
                    if model.helperEnabled { model.disableHelper() }
                    else { model.enableHelper() }
                }
            }
            Divider()
            KithSettingsHelp(title: "Helper approval") {
                Text("Approve the helper in System Settings → General → Login Items & Extensions.")
            }
        }

        KithSettingsGroup(title: "Battery & heat") {
            KithSettingsRow(title: "Stop protection at", subtitle: "Currently using \(model.conditions.onAC ? "AC power" : "battery power").") {
                Picker("Stop awake protection at", selection: $model.powerPreferences.batteryFloor) {
                    ForEach([5, 10, 15], id: \.self) { value in Text("\(value)% battery").tag(value) }
                }
                .labelsHidden().frame(width: 140)
            }
            Divider()
            Text("Critical heat always stops protection. Resume explicitly when conditions are safe.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
            Divider()
            KithSettingsHelp(title: "Battery warnings & audio") {
                Toggle("Mute audio with the lid closed", isOn: $model.powerPreferences.muteWithLidClosed)
                Text("Low-battery warnings start at \(model.powerPreferences.batteryWarning)%.")
            }
        }

        KithSettingsGroup(title: "Connectivity") {
            KithToggleRow(title: "Warn about network loss", subtitle: "Only during active work.", isOn: $model.powerPreferences.networkAlerts)
            Divider()
            KithSettingsHelp(title: "Browser checks & network details") {
                Toggle("Check browsers for background throttling", isOn: $model.powerPreferences.browserDiagnostics)
                BrowserPowerWarnings(workflow: model.workflow)
                Text("Network availability does not confirm an agent service is reachable or that a task finished.")
            }
        }

        if !recoveryNeedsAttention { recoverySection }
    }

    private var recoverySection: some View {
        KithSettingsGroup(title: "Recovery & diagnostics") {
            if recoveryNeedsAttention {
                recoveryDetails
            } else {
                KithSettingsHelp(title: "Power recovery & saved audio") { recoveryDetails }
            }
        }
    }

    private var recoveryDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            let recovery = model.powerStatus.recovery
            LabeledContent("Power recovery", value: model.legacyPowerRecoveryPending && recovery == .restored
                ? RecoveryState.pending.title : recovery.title)
            if model.legacyPowerRecoveryPending && !model.helperEnabled {
                Text("Set up the power helper to restore settings saved by an earlier version of Kith.")
                    .foregroundStyle(.orange)
            }
            if let detail = model.powerStatus.detail { Text(detail).foregroundStyle(.secondary) }
            if let issue = model.audioIssue { Text(issue).foregroundStyle(.orange) }
            ForEach(model.audioPending) { output in
                HStack {
                    Text("Saved audio: \(output.name)")
                    Spacer()
                    Button("Stop waiting") { model.stopWaitingForAudio(output.id) }
                }
            }
            HStack {
                Button("Retry recovery") { model.retryPowerRecovery() }
                Button("Copy diagnostics") { model.copyPowerDiagnostics() }
            }
            Text("Disconnected audio outputs are restored when they reconnect while Kith is open. Stop waiting leaves that output unchanged.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(recoveryNeedsAttention ? 14 : 0)
    }
}

struct KithAfterWorkPage: View {
    @EnvironmentObject private var model: KithModel
    @State private var confirmingShutdown = false

    var body: some View {
        KithSettingsGroup(title: "Finish actions") {
            KithToggleRow(title: "Allow finish actions", subtitle: "Enable only after completing the live checks on your Mac.", isOn: $model.automationValidated)
            Divider()
            KithSettingsHelp(title: "Live validation checklist") {
                Text("Validate all four agent clients before enabling finish actions. This switch records your sign-off.")
                Link("Open acceptance checklist", destination: URL(string: "https://github.com/whysosaket/kith/blob/main/docs/ACCEPTANCE.md")!)
            }
        }

        KithSettingsGroup(title: "When every agent is done") {
            VStack(alignment: .leading, spacing: 14) {
                Label("A 60-second countdown gives you time to cancel.", systemImage: "clock")
                    .font(.subheadline)
                Text("A new turn cancels the countdown. Each action runs once.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.armedAction == nil {
                    HStack(spacing: 10) {
                        Button("Sleep when done") { model.arm(.sleep) }
                        Button("Shut down when done") { confirmingShutdown = true }
                    }
                    .disabled(model.finishActionBlockReason != nil)
                    if let reason = model.finishActionBlockReason {
                        Label(reason, systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.hasMonitoringIssue {
                            Button("Review monitoring") { model.settingsPane = .monitoring }
                        } else if !model.helperEnabled && model.automationValidated {
                            Button("Set up power helper") { model.settingsPane = .power }
                        }
                    }
                } else {
                    Text("Your action is armed. You can cancel it above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        Text("Shutdown may discard unsaved work in other apps. Save your work before arming it.")
            .font(.caption).foregroundStyle(.secondary)
        .alert("Shut down when work ends?", isPresented: $confirmingShutdown) {
            Button("Arm Shutdown", role: .destructive) { model.arm(.shutdown) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kith will give you a 60-second countdown after work ends. Shutdown may discard unsaved work in other apps.")
        }
    }
}

private struct BrowserPowerWarnings: View {
    @ObservedObject var workflow: WorkflowSettings

    var body: some View {
        ForEach(workflow.browserWarnings, id: \.self) { warning in
            Text(warning)
        }
        Text("Browser checks never quit or relaunch an app. Save browser work before changing its launch options.")
    }
}

struct KithPowerHealthView: View {
    @EnvironmentObject private var model: KithModel
    @Environment(\.openWindow) private var openWindow
    var showAction = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stop = model.wakeStopped {
                Label(stop.message, systemImage: "pause.circle")
            }
            if model.powerRecoveryPending || model.audioIssue != nil || model.audioRecoveryPending {
                Label("Power recovery needs attention", systemImage: "exclamationmark.triangle")
            }
            if model.systemSleepDisabled {
                Label("macOS sleep is disabled system-wide", systemImage: "exclamationmark.triangle")
            }
            if model.networkWarning {
                Label("Network unavailable during active work", systemImage: "wifi.slash")
            }
            if let issue = model.controlIssue {
                Label(issue, systemImage: "exclamationmark.circle")
            }
            if showAction && (model.wakeStopped != nil || model.powerRecoveryPending || model.systemSleepDisabled ||
                model.audioIssue != nil || model.audioRecoveryPending || model.networkWarning || model.controlIssue != nil) {
                Button("Review power") {
                    model.settingsPane = .power
                    model.workspacePage = .settings
                    openWindow(id: "workspace")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .font(.caption)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}
