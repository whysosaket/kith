import SwiftUI

struct KithPowerPage: View {
    @EnvironmentObject private var model: KithModel
    @State private var confirmingShutdown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KithSection("Awake protection") {
                    LabeledContent("Current wake hold", value: model.idleHoldActive ? "Active" : "Inactive")
                    Toggle("Keep awake while working", isOn: $model.keepAwake)
                    Picker("Extra awake time", selection: $model.postRunMinutes) {
                        ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    Text("Extra awake time starts when the last active turn ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                KithSection("Closed-lid work") {
                    LabeledContent("Current hold", value: closedLidStatus)
                    Toggle("Allow closed-lid work", isOn: $model.closedLid)
                        .disabled(!model.helperEnabled)
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
