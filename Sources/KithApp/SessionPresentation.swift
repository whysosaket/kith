import AppKit
import SwiftUI
import KithCore

extension SessionStatus {
    var displayName: String {
        switch self {
        case .running: "Working"
        case .needsInput: "Needs input"
        case .ready: "Turn finished"
        case .failed: "Failed"
        case .unavailable: "Status unconfirmed"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "bolt.fill"
        case .needsInput: "exclamationmark.bubble.fill"
        case .ready: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: .blue
        case .needsInput: .orange
        case .ready: .green
        case .failed: .red
        case .unavailable: .secondary
        }
    }
}

extension AgentSession {
    var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    var displayTitle: String { title ?? projectName ?? surface.title }

    var openActionTitle: String {
        switch surface {
        case .codexDesktop: "Open Codex thread"
        case .claudeDesktop: "Open Claude"
        case .claudeCLI, .codexCLI: "Open terminal"
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [title, projectPath, surface.title].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct KithSessionRow: View {
    @EnvironmentObject private var model: KithModel
    @State private var hovered = false

    let session: AgentSession
    var showActionTitle = false

    var body: some View {
        Button {
            model.open(session)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: session.status.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(session.status.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.status.displayName)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                        Text(session.surface.title)
                        if let projectName = session.projectName {
                            Text("·")
                            Text(projectName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                if showActionTitle {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(session.openActionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if session.lastActivity != .distantPast {
                            Text(session.lastActivity, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if session.lastActivity != .distantPast {
                    Text(session.lastActivity, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help([session.openActionTitle, session.projectPath].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel("\(session.displayTitle), \(session.status.displayName), \(session.surface.title)" +
                            (session.projectName.map { ", \($0)" } ?? ""))
        .accessibilityHint(session.openActionTitle)
    }
}

struct KithHealthView: View {
    @EnvironmentObject private var model: KithModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.hasMonitoringIssue {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.hooksInstalled ? "Monitoring needs attention" : "Finish monitoring setup",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(monitoringDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review monitoring") { showSettings(.monitoring) }
                    .font(.caption.weight(.medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
        if let notificationIssue = model.notificationIssue {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(.orange)
                Text(notificationIssue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Review") { showSettings(.notifications) }
                    .font(.caption)
            }
        }
    }

    private var monitoringDetail: String {
        if !model.hooksInstalled { return "Install agent hooks to start confirming session status." }
        let names = model.unavailable.map(\.title).sorted().joined(separator: ", ")
        return "Kith can't confirm: \(names). Finish actions remain blocked."
    }

    private func showSettings(_ pane: SettingsPane) {
        model.settingsPane = pane
        model.workspacePage = .settings
        openWindow(id: "workspace")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct KithMessageView: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        if let message = model.message {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.clearMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss message")
        if model.unavailable.contains(.codexDesktop) && !model.accessibilityEnabled {
            return "Kith can't confirm: \(names). Codex Desktop needs Accessibility access. Finish actions remain blocked."
        }
            }
        }
    }
}

struct KithPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct KithSection<Content: View>: View {
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
