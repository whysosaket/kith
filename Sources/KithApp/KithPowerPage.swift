import SwiftUI

struct KithPowerPage: View {
    @EnvironmentObject private var model: KithModel

    private var recoveryNeedsAttention: Bool {
        model.powerStatus.recovery != .restored || model.audioIssue != nil || model.audioRecoveryPending
    }

    var body: some View {
        KithWakeTimer()

        if model.wakeStopped != nil || recoveryNeedsAttention || model.networkWarning || model.controlIssue != nil {
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
                Text("Display wake prevents idle display sleep. It does not bypass an explicit lock or guarantee that computer use works with the lid closed.")
            }
        }

        KithSettingsGroup(title: "With the lid closed") {
            KithToggleRow(title: "Allow closed-lid work", subtitle: closedLidSubtitle, isOn: $model.closedLid)
                .disabled(!model.helperEnabled && !model.closedLid)
            Divider()
            KithSettingsRow(title: "Power helper", subtitle: model.helperEnabled ? "Enabled on this Mac." : "Required for closed-lid work and energy saving.") {
                Button(model.helperEnabled ? "Disable helper" : "Set up helper") {
                    if model.helperEnabled { model.disableHelper() }
                    else { model.enableHelper() }
                }
            }
            Divider()
            KithSettingsHelp(title: "Before using closed-lid work") {
                Text("The helper temporarily changes a system sleep setting. Avoid running another closed-lid utility at the same time. Approve the helper in System Settings → General → Login Items & Extensions.")
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
            KithSettingsHelp(title: "Energy saving & audio") {
                Toggle("Enable energy saving", isOn: $model.powerPreferences.saveEnergy)
                    .disabled(!model.helperEnabled && !model.powerPreferences.saveEnergy)
                Picker("Low Power Mode below", selection: $model.powerPreferences.lowPowerFloor) {
                    ForEach([30, 40, 50], id: \.self) { value in Text("\(value)% battery").tag(value) }
                }
                .disabled(!model.powerPreferences.saveEnergy)
                Toggle("Also save energy with the lid closed", isOn: $model.powerPreferences.lowPowerWithLidClosed)
                    .disabled(!model.powerPreferences.saveEnergy)
                Text("Energy saving requires the helper and can reduce performance. Kith restores the previous AC and battery settings.")
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

    private var closedLidSubtitle: String {
        if !model.helperEnabled { return "Set up the power helper to use this option." }
        if model.externalWakeOwner { return "Another app is holding closed-lid protection." }
        return model.closedLidReady ? "Closed-lid protection is active." : "Keep working when you close your Mac."
    }

    private var recoveryDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Power recovery", value: model.powerStatus.leaseActive ? "Protection active" : model.powerStatus.recovery.title)
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
                Text("Validate all four agent clients and closed-lid work on AC and battery before enabling. This switch records your sign-off; Kith cannot verify the checks.")
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
            if model.powerStatus.recovery != .restored || model.audioIssue != nil || model.audioRecoveryPending {
                Label("Power recovery needs attention", systemImage: "exclamationmark.triangle")
            }
            if model.networkWarning {
                Label("Network unavailable during active work", systemImage: "wifi.slash")
            }
            if let issue = model.controlIssue {
                Label(issue, systemImage: "exclamationmark.circle")
            }
            if showAction && (model.wakeStopped != nil || model.powerStatus.recovery != .restored ||
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
