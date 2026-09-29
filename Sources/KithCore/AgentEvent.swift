import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

public enum AgentSurface: String, Codable, CaseIterable, Sendable {
    case claudeDesktop
    case claudeCLI
    case codexDesktop
    case codexCLI

    public var title: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCLI: "Claude CLI"
        case .codexDesktop: "Codex Desktop"
        case .codexCLI: "Codex CLI"
        }
    }

    public var source: AgentSource {
        switch self {
        case .claudeDesktop, .claudeCLI: .claude
        case .codexDesktop, .codexCLI: .codex
        }
    }
}

public enum AgentEventKind: String, Codable, Sendable {
    case sessionStarted
    case turnStarted
    case attentionOpened
    case attentionResolved
    case stopCandidate
    case turnFailed
    case interrupted
    case sessionEnded
}

public struct AgentEvent: Codable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let source: AgentSource
    public let sessionID: String
    public let turnID: String?
    public let kind: AgentEventKind
    public let timestamp: Date
    public let projectPath: String?
    public let attentionID: String?
    public let hasBackgroundWork: Bool
    public let terminalBundleID: String?
    public let terminalTTY: String?
    /// Short, content-free reason shown in notifications, such as "Approve Bash".
    public let detail: String?

    public init(
        id: UUID = UUID(), source: AgentSource, sessionID: String,
        turnID: String? = nil, kind: AgentEventKind,
        timestamp: Date = Date(), projectPath: String? = nil,
        attentionID: String? = nil, hasBackgroundWork: Bool = false,
        terminalBundleID: String? = nil, terminalTTY: String? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = 1
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.timestamp = timestamp
        self.projectPath = projectPath
        self.attentionID = attentionID
        self.hasBackgroundWork = hasBackgroundWork
        self.terminalBundleID = terminalBundleID
        self.terminalTTY = terminalTTY
        self.detail = detail
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case needsInput
    case ready
    case failed
    case unavailable
}

public struct AgentSession: Codable, Sendable, Identifiable {
    public var source: AgentSource
    public var surface: AgentSurface
    public var sessionID: String
    public var turnID: String?
    public var projectPath: String?
    public var title: String?
    public var status: SessionStatus
    public var lastActivity: Date
    public var attentionID: String?
    public var stopCandidate: Bool
    public var hasBackgroundWork: Bool
    public var terminalBundleID: String?
    public var terminalTTY: String?

    public var id: String { "\(source.rawValue):\(sessionID)" }

    public init(source: AgentSource, surface: AgentSurface, sessionID: String,
                turnID: String? = nil, projectPath: String? = nil,
                title: String? = nil, status: SessionStatus = .ready,
                lastActivity: Date = Date(), attentionID: String? = nil,
                stopCandidate: Bool = false, hasBackgroundWork: Bool = false,
                terminalBundleID: String? = nil, terminalTTY: String? = nil) {
        self.source = source
        self.surface = surface
        self.sessionID = sessionID
        self.turnID = turnID
        self.projectPath = projectPath
        self.title = title
        self.status = status
        self.lastActivity = lastActivity
        self.attentionID = attentionID
        self.stopCandidate = stopCandidate
        self.hasBackgroundWork = hasBackgroundWork
        self.terminalBundleID = terminalBundleID
        self.terminalTTY = terminalTTY
    }
}
