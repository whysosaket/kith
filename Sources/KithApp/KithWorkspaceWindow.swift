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

struct KithWorkspaceWindow: View {
    @EnvironmentObject private var model: KithModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                KithPageHeader(
                    title: model.workspacePage.rawValue,
                    subtitle: model.workspacePage == .sessions ?
                        "Find the work that needs you, or return to an agent." :
                        "See how Kith protects your Mac while agents work."
                )
                Spacer(minLength: 12)
                Picker("View", selection: $model.workspacePage) {
                    ForEach(WorkspacePage.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            if model.armedAction != nil { KithArmedBanner() }
            KithHealthView()
            KithMessageView()
            Divider()

            if model.workspacePage == .sessions {
                KithSessionsPage()
            } else {
                KithPowerPage()
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 400)
    }
}

private struct KithSessionsPage: View {
    @EnvironmentObject private var model: KithModel
    @State private var searchText = ""
    @State private var selectedFilter: SessionFilter = .all
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title, project, or source", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
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

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(group.title) (\(group.sessions.count))")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(group.sessions) { session in
                                    KithSessionRow(session: session, showActionTitle: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Search") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
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
            Image(systemName: model.hasMonitoringIssue ? "exclamationmark.triangle" : "checkmark.circle")
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
