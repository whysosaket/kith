import SwiftUI
import KithCore

private enum SessionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case attention = "Needs attention"
    case working = "Working"
    case recent = "Recent"

    var id: String { rawValue }
}

private struct SessionGroup: Identifiable {
    let title: String
    let sessions: [AgentSession]
    var id: String { title }
}

private enum WorkspaceDestination: Hashable {
    case sessions
    case settings(SettingsPane)
}

struct KithWorkspaceWindow: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text("Kith").font(.title3.weight(.semibold))
                } icon: {
                    Image(nsImage: KithMenuBarIcon.image)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)

                List(selection: destination) {
                    Label("Sessions", systemImage: "square.stack")
                        .badge(model.attentionCount)
                        .tag(WorkspaceDestination.sessions)

                    Section("Settings") {
                        ForEach(SettingsPane.allCases) { pane in
                            HStack {
                                Label(pane.rawValue, systemImage: pane.symbol)
                                Spacer(minLength: 0)
                                if needsAttention(pane) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Needs attention")
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(pane.rawValue + (needsAttention(pane) ? ", needs attention" : ""))
                            .tag(WorkspaceDestination.settings(pane))
                        }
                    }
                }
                .listStyle(.sidebar)

                Label("On your Mac", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                KithPageHeader(
                    title: model.workspacePage == .sessions ? "Sessions" : model.settingsPane.rawValue,
                    subtitle: model.workspacePage == .sessions ?
                        "Your agents, at a glance." : model.settingsPane.subtitle
                )
                .padding(.horizontal, 28)
                .padding(.vertical, 20)

                if model.armedAction != nil {
                    KithArmedBanner().padding(.horizontal, 28).padding(.bottom, 16)
                }
                if model.workspacePage == .sessions {
                    KithHealthView().padding(.horizontal, 28)
                }
                if model.workspacePage == .sessions || model.settingsPane != .power {
                    KithPowerHealthView().padding(.horizontal, 28)
                }
                KithMessageView().padding(.horizontal, 28)
                Divider()

                if model.workspacePage == .sessions {
                    KithSessionsPage().padding(28)
                } else {
                    KithSettingsPage()
                        .id(model.settingsPane)
                }
            }
            .frame(minWidth: 490)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, minHeight: 520)
    }

    private var destination: Binding<WorkspaceDestination?> {
        Binding {
            model.workspacePage == .sessions ? .sessions : .settings(model.settingsPane)
        } set: { selection in
            guard let selection else { return }
            switch selection {
            case .sessions: model.workspacePage = .sessions
            case .settings(let pane):
                model.settingsPane = pane
                model.workspacePage = .settings
            }
        }
    }

    private func needsAttention(_ pane: SettingsPane) -> Bool {
        switch pane {
        case .monitoring: model.hasMonitoringIssue
        case .notifications: model.notificationIssue != nil
        case .power: model.wakeStopped != nil || model.powerStatus.recovery != .restored ||
            model.audioIssue != nil || model.audioRecoveryPending || model.networkWarning || model.controlIssue != nil
        case .general, .afterWork: false
        }
    }
}

private struct KithSessionsPage: View {
    @EnvironmentObject private var model: KithModel
    @State private var searchText = ""
    @State private var selectedFilter: SessionFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, project, or source", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search sessions")
            }
            .padding(9)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            Picker("Show", selection: $selectedFilter) {
                ForEach(SessionFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(group.title)
                                    Text("\(group.sessions.count)").foregroundStyle(.secondary)
                                }
                                .font(.subheadline.weight(.semibold))
                                ForEach(group.sessions) { session in
                                    KithSessionRow(session: session, showActionTitle: true)
                                }
                            }
                            .padding(14)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var groups: [SessionGroup] {
        let attention = model.attentionSessions.filter { $0.matches(searchText) }
        let working = model.workingSessions.filter { $0.matches(searchText) }
        let unconfirmed = model.unconfirmedSessions.filter { $0.matches(searchText) }
        let recent = model.recentSessions.filter { $0.matches(searchText) }
        var result: [SessionGroup] = []
        if (selectedFilter == .all || selectedFilter == .attention) && !attention.isEmpty {
            result.append(SessionGroup(title: "Needs attention", sessions: attention))
        }
        if (selectedFilter == .all || selectedFilter == .working) && !working.isEmpty {
            result.append(SessionGroup(title: "Working", sessions: working))
        }
        if (selectedFilter == .all || selectedFilter == .attention) && !unconfirmed.isEmpty {
            result.append(SessionGroup(title: "Status unconfirmed", sessions: unconfirmed))
        }
        if (selectedFilter == .all || selectedFilter == .recent) && !recent.isEmpty {
            result.append(SessionGroup(title: "Turn finished in the past hour", sessions: recent))
        }
        return result
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: !searchText.isEmpty ? "magnifyingglass" :
                    model.hasMonitoringIssue ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.subheadline.weight(.medium))
            if !searchText.isEmpty {
                Text("Try a different title, project, or source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "No matching sessions" }
        if model.hasMonitoringIssue { return "Session status can't be confirmed yet" }
        if !model.monitoringReady { return "Checking session status" }
        switch selectedFilter {
        case .all: return "No active or recently finished sessions"
        case .attention: return "Nothing needs attention"
        case .working: return "No sessions are working"
        case .recent: return "No turns finished in the past hour"
        }
    }
}
