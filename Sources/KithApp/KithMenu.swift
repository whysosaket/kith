import AppKit
import SwiftUI
import KithCore

struct KithMenu: View {
    @EnvironmentObject private var model: KithModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: KithMenuBarIcon.image)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kith").font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Open Kith Settings")
            }
            .padding(.bottom, 14)

            if model.armedAction != nil {
                KithArmedBanner()
                    .padding(.bottom, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    KithHealthView()
                    KithMessageView()

                    if !model.attentionSessions.isEmpty {
                        sessionPreview("Needs attention", sessions: model.attentionSessions, limit: 4)
                    }
                    if !model.workingSessions.isEmpty {
                        sessionPreview("Working", sessions: model.workingSessions, limit: 2)
                    }
                    if model.attentionSessions.isEmpty && model.workingSessions.isEmpty &&
                        model.monitoringReady && !model.hasMonitoringIssue &&
                        model.notificationIssue == nil {
                        Label("All caught up", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }

                    Divider()
                    KithPowerDisclosure()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: model.armedAction == nil ? 420 : 330)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.top, 12)
            HStack {
                Button("View all sessions") { showSessions() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Quit Kith") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 380)
    }

    private var summary: String {
        if model.countdown != nil { return "Power action pending" }
        if model.attentionCount > 0 {
            return "\(model.attentionCount) \(model.attentionCount == 1 ? "session needs" : "sessions need") attention"
        }
        if model.hasMonitoringIssue { return "Session status can't be confirmed" }
        if !model.monitoringReady { return "Checking session status" }
        if model.notificationIssue != nil { return "Notifications need attention" }
        if model.runningCount > 0 {
            return "\(model.runningCount) \(model.runningCount == 1 ? "session" : "sessions") working"
        }
        return "Ready for your next session"
    }

    private func sessionPreview(_ title: String, sessions: [AgentSession], limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 2)
            ForEach(Array(sessions.prefix(limit))) { session in
                KithSessionRow(session: session)
            }
            if sessions.count > limit {
                Button("View \(sessions.count - limit) more") { showSessions() }
                    .font(.caption)
                    .padding(.leading, 8)
            }
        }
    }

    private func showSessions() {
        openWindow(id: "sessions")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct KithArmedBanner: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        if let action = model.armedAction, let phase = model.finishActionPhase {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "clock")
                    .foregroundStyle(phaseIsCountdown(phase) ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: action, phase: phase))
                        .font(.subheadline.weight(.semibold))
                    if action == .shutdown {
                        Text("Unsaved work in other apps may be lost.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button("Cancel") { model.cancelAction() }
                    .font(.caption.weight(.medium))
            }
            .padding(12)
            .background(Color.orange.opacity(phaseIsCountdown(phase) ? 0.12 : 0.07),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func phaseIsCountdown(_ phase: FinishActionPhase) -> Bool {
        if case .countdown = phase { return true }
        return false
    }

    private func title(for action: FinishAction, phase: FinishActionPhase) -> String {
        let verb = action == .sleep ? "Sleep" : "Shut down"
        switch phase {
        case .waitingForWork: return "\(verb) after the next work session"
        case .watchingWork: return "\(verb) when work ends"
        case .countdown(let seconds): return "\(verb) in \(seconds) seconds"
        }
    }
}

private struct KithPowerDisclosure: View {
    @EnvironmentObject private var model: KithModel
    @Environment(\.openSettings) private var openSettings
    @State private var expanded = false
    @State private var confirmingShutdown = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Keep awake while working", isOn: $model.keepAwake)
                Toggle("Allow closed-lid work", isOn: $model.closedLid)
                    .disabled(!model.helperEnabled)
                if !model.helperEnabled {
                    Button("Enable closed-lid helper in Settings") { showSettings(.power) }
                        .font(.caption)
                }
                if model.armedAction == nil {
                    Menu("After work…") {
                        Button("Sleep when work ends") { model.arm(.sleep) }
                        Button("Shut down when work ends") { confirmingShutdown = true }
                    }
                    .disabled(model.finishActionBlockReason != nil)
                    if let reason = model.finishActionBlockReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Review requirements") {
                            showSettings(model.hasMonitoringIssue ? .monitoring : .power)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Power").font(.subheadline.weight(.medium))
                Text(powerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Shut down when work ends?", isPresented: $confirmingShutdown) {
            Button("Arm Shutdown", role: .destructive) { model.arm(.shutdown) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kith will give you a 60-second countdown after work ends. Shutdown may discard unsaved work in other apps.")
        }
    }

    private var powerSummary: String {
        if model.closedLidReady {
            return model.externalWakeOwner ? "External closed-lid hold detected" : "Closed-lid hold active"
        }
        if model.idleHoldActive {
            return model.closedLid ? "Keeping awake · preparing lid hold" : "Keeping Mac awake"
        }
        if model.keepAwake || model.closedLid { return "Ready when agents work" }
        return "Awake protection is off"
    }

    private func showSettings(_ pane: SettingsPane) {
        model.settingsPane = pane
        openSettings()
    }
}
