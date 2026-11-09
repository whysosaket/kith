import SwiftUI

struct KithPowerPage: View {
    @EnvironmentObject private var model: KithModel
    @State private var confirmingShutdown = false
    @State private var manualSeconds: TimeInterval = 3600

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KithSection("Current awake period") {
                    Text(model.powerSummary)
                    if let deadline = model.wakeDeadline, model.wakeStopped == nil {
                        LabeledContent("Protection ends") { Text(deadline, style: .time) }
                        HStack {
                            Button("Extend 1 hour") { model.extendWake() }
                            Button("End awake protection") { model.endWake() }
                        }
                        .buttonStyle(.bordered)
                    }
                    if model.wakeStopped != nil {
                        Button("Resume awake protection") { model.resumeWake() }
                            .buttonStyle(.bordered)
                    }
                    Picker("Manual duration", selection: $manualSeconds) {
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("1 hour").tag(TimeInterval(3600))
                        Text("2 hours").tag(TimeInterval(7200))
                        Text("4 hours").tag(TimeInterval(14400))
                    }
                    Button("Start manual wake period") { model.startManualWake(seconds: manualSeconds) }
                        .buttonStyle(.bordered)
                    Text("Manual wake periods cover tasks Kith does not monitor and cancel armed sleep or shutdown actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                KithSection("Awake protection") {
                    LabeledContent("Current wake hold", value: model.idleHoldActive ? "Active" : "Inactive")
                    Toggle("Keep awake while working", isOn: $model.keepAwake)
                    Picker("Extra awake time", selection: $model.postRunMinutes) {
                        ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    Picker("Maximum awake time", selection: $model.powerPreferences.maximumSeconds) {
                        ForEach([1, 2, 4, 8, 24], id: \.self) { hours in
                            Text("\(hours) hours").tag(TimeInterval(hours * 3600))
                        }
                    }
                    Toggle("Keep display awake for computer use", isOn: $model.powerPreferences.keepDisplayAwake)
                    Text("Display wake prevents idle display sleep and can leave the screen unlocked. It does not bypass an explicit lock.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Extra awake time starts when the last active turn ends and cannot extend the current period's deadline. Maximum-time changes apply to the next period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                KithSection("Closed-lid work") {
                    LabeledContent("Current hold", value: closedLidStatus)
                    Toggle("Allow closed-lid work", isOn: $model.closedLid)
                        .disabled(!model.helperEnabled && !model.closedLid)
                    LabeledContent("Power helper", value: model.helperEnabled ? "Enabled" : "Not enabled")
                    if model.helperEnabled {
                        Button("Disable power helper") { model.disableHelper() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Enable power helper") { model.enableHelper() }
                            .buttonStyle(.bordered)
                    }
                    Text("Closed-lid mode uses an undocumented system setting. Avoid another closed-lid utility at the same time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                KithSection("Battery and heat") {
                    LabeledContent("Power source", value: model.conditions.onAC ? "AC power" : "Battery")
                    Picker("Stop awake protection at", selection: $model.powerPreferences.batteryFloor) {
                        ForEach([5, 10, 15], id: \.self) { value in Text("\(value)% battery").tag(value) }
                    }
                    Text("Low-battery warnings start at \(model.powerPreferences.batteryWarning)%. Critical heat always stops awake protection. Resume explicitly once conditions are safe.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Enable energy saving", isOn: $model.powerPreferences.saveEnergy)
                        .disabled(!model.helperEnabled && !model.powerPreferences.saveEnergy)
                    Picker("Low Power Mode below", selection: $model.powerPreferences.lowPowerFloor) {
                        ForEach([30, 40, 50], id: \.self) { value in Text("\(value)% battery").tag(value) }
                    }
                    .disabled(!model.powerPreferences.saveEnergy)
                    Toggle("Also save energy while the lid is closed", isOn: $model.powerPreferences.lowPowerWithLidClosed)
                        .disabled(!model.powerPreferences.saveEnergy)
                    Text("Energy saving requires the power helper and can reduce performance. Kith restores the previous AC and battery settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Mute audio while the lid is closed", isOn: $model.powerPreferences.muteWithLidClosed)
                }

                Divider()

                KithSection("Recovery") {
                    LabeledContent("Power recovery", value: model.powerStatus.leaseActive ? "Protection active" : model.powerStatus.recovery.title)
                    if let detail = model.powerStatus.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let issue = model.audioIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    ForEach(model.audioPending) { output in
                        HStack {
                            Text("Saved audio: \(output.name)").font(.caption)
                            Spacer()
                            Button("Stop waiting") { model.stopWaitingForAudio(output.id) }
                        }
                    }
                    HStack {
                        Button("Retry recovery") { model.retryPowerRecovery() }
                        Button("Copy diagnostics") { model.copyPowerDiagnostics() }
                    }
                    .buttonStyle(.bordered)
                    Text("Disconnected audio outputs are restored when they reconnect while Kith is open. Stop waiting leaves that output unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                KithSection("Connectivity") {
                    Toggle("Notify about network loss during work", isOn: $model.powerPreferences.networkAlerts)
                    Text("Network availability does not confirm that an agent service is reachable or that a task finished.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Check browsers for background throttling", isOn: $model.powerPreferences.browserDiagnostics)
                    BrowserPowerWarnings(workflow: model.workflow)
                }

                Divider()

                KithSection("After work") {
                    Toggle("Enable after live validation", isOn: $model.automationValidated)
                    Text("Validate all four clients and closed-lid work on AC and battery before enabling sleep or shutdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.armedAction == nil {
                        HStack(spacing: 10) {
                            Button("Sleep when done") { model.arm(.sleep) }
                            Button("Shut down when done") { confirmingShutdown = true }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.finishActionBlockReason != nil)
                        if let reason = model.finishActionBlockReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.hasMonitoringIssue {
                                Button("Review monitoring") {
                                    model.settingsPane = .monitoring
                                }
                            }
                        }
                    }
                    Text("Shutdown may discard unsaved work in other apps.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Shut down when work ends?", isPresented: $confirmingShutdown) {
            Button("Arm Shutdown", role: .destructive) { model.arm(.shutdown) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kith will give you a 60-second countdown after work ends. Shutdown may discard unsaved work in other apps.")
        }
    }

    private var closedLidStatus: String {
        guard model.closedLidReady else { return "Inactive" }
        return model.externalWakeOwner ? "External hold detected" : "Active"
    }
}

private struct BrowserPowerWarnings: View {
    @ObservedObject var workflow: WorkflowSettings
    var body: some View {
        ForEach(workflow.browserWarnings, id: \.self) { warning in
            Text(warning).font(.caption).foregroundStyle(.secondary)
        }
        Text("Browser checks never quit or relaunch an app. Save browser work before changing its launch options.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct KithPowerHealthView: View {
    @EnvironmentObject private var model: KithModel
    var body: some View {
        if let stop = model.wakeStopped {
            Label(stop.message, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
        }
        if model.powerStatus.recovery != .restored || model.audioIssue != nil || model.audioRecoveryPending {
            Label("Power recovery needs attention", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if model.networkWarning {
            Label("Network unavailable during active work", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
