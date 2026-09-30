import Foundation

public struct SessionStore: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    private var seenEvents: Set<UUID> = []

    public init() {}

    private struct SavedStatus: Codable {
        var source: AgentSource
        var surface: AgentSurface
        var sessionID: String
        var turnID: String?
        var status: SessionStatus
        var lastActivity: Date
    }

    private struct Snapshot: Codable {
        var version: Int
        var sessions: [SavedStatus]
        var eventIDs: Set<UUID>
    }

    public static func load(from url: URL) -> SessionStore {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else { return SessionStore() }
        var result = SessionStore()
        result.seenEvents = snapshot.eventIDs
        for saved in snapshot.sessions where Date().timeIntervalSince(saved.lastActivity) < 86_400 {
            let session = AgentSession(source: saved.source, surface: saved.surface,
                sessionID: saved.sessionID, turnID: saved.turnID,
                status: saved.status == .ready ? .ready : .unavailable,
                lastActivity: .distantPast)
            result.sessions[session.id] = session
        }
        return result
    }

    public func save(to url: URL) throws {
        let recent = sessions.values.filter { Date().timeIntervalSince($0.lastActivity) < 86_400 }
            .map { SavedStatus(source: $0.source, surface: $0.surface,
                               sessionID: $0.sessionID, turnID: $0.turnID,
                               status: $0.status, lastActivity: $0.lastActivity) }
        let snapshot = Snapshot(version: 1, sessions: recent, eventIDs: seenEvents)
        try KithPaths.prepare()
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent, surface: AgentSurface) -> SessionStatus? {
        guard event.schemaVersion == 1, seenEvents.insert(event.id).inserted else { return nil }
        if seenEvents.count > 2_000 { seenEvents = [event.id] }
        let key = "\(event.source.rawValue):\(event.sessionID)"
        var session = sessions[key] ?? AgentSession(source: event.source, surface: surface,
                                                    sessionID: event.sessionID)
        // Senders set their own timestamp; a future one must not outrank later local scans.
        let timestamp = min(event.timestamp, Date())
        guard timestamp >= session.lastActivity.addingTimeInterval(-5) else { return nil }
        let oldStatus = session.status
        session.surface = surface
        session.lastActivity = timestamp
        session.projectPath = event.projectPath ?? session.projectPath
        session.terminalBundleID = event.terminalBundleID ?? session.terminalBundleID
        session.terminalTTY = event.terminalTTY ?? session.terminalTTY
        session.turnID = event.turnID ?? session.turnID

        switch event.kind {
        case .sessionStarted:
            break
        case .turnStarted:
            session.status = .running
            session.attentionID = nil
            session.stopCandidate = false
            session.hasBackgroundWork = false
        case .attentionResolved:
            // A scanned Claude wait replaces the hook's own ID, so any tool result ends it too.
            if let attentionID = session.attentionID,
               attentionID == event.attentionID || attentionID == "prompt" ||
                attentionID.hasPrefix("question:waiting:") {
                session.status = .running
                session.attentionID = nil
            }
        case .attentionOpened:
            session.status = .needsInput
            session.attentionID = event.attentionID ?? "prompt"
            session.stopCandidate = false
        case .stopCandidate:
            session.stopCandidate = true
            session.hasBackgroundWork = event.hasBackgroundWork
        case .turnFailed:
            session.status = .failed
            session.stopCandidate = false
        case .interrupted, .sessionEnded:
            session.status = .ready
            session.attentionID = nil
            session.stopCandidate = false
        }
        sessions[key] = session
        return session.status != oldStatus ? session.status : nil
    }

    public mutating func reconcile(_ observed: AgentSession) -> SessionStatus? {
        let old = sessions[observed.id]
        // A confirmed scan replaces an unconfirmed session even when hook events are newer:
        // most hooks refresh lastActivity without restoring the status lost on restart.
        guard old == nil || (old!.turnID != nil && old!.turnID == observed.turnID) ||
              observed.lastActivity >= old!.lastActivity ||
              (old!.status == .unavailable && observed.status != .unavailable) else { return nil }
        var result = observed
        if let old {
            result.projectPath = result.projectPath ?? old.projectPath
            result.terminalBundleID = result.terminalBundleID ?? old.terminalBundleID
            result.terminalTTY = result.terminalTTY ?? old.terminalTTY
            result.title = result.title ?? old.title
            result.attentionID = result.attentionID ?? old.attentionID
            if old.status == .needsInput &&
                observed.status == .running && old.turnID == observed.turnID {
                if !(old.attentionID?.hasPrefix("question:") ?? false) {
                    result.status = .needsInput
                }
            }
            if old.status == .failed && old.turnID == observed.turnID {
                result.status = .failed
            }
        }
        sessions[observed.id] = result
        return old?.status != result.status ? result.status : nil
    }

    public mutating func markMissing(seenIDs: Set<String>, olderThan date: Date) {
        for (key, var session) in sessions where !seenIDs.contains(key) &&
            session.status == .running && session.lastActivity <= date {
            session.status = .unavailable
            session.stopCandidate = false
            sessions[key] = session
        }
    }

    public var allSafeToFinish: Bool {
        sessions.values.allSatisfy { $0.status == .ready }
    }
}
