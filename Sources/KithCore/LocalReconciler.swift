import Foundation
import SQLite3
import Darwin
import AppKit

public struct ReconcileResult: Sendable {
    public var sessions: [AgentSession]
    public var unavailable: Set<AgentSurface>

    public init(sessions: [AgentSession] = [], unavailable: Set<AgentSurface> = []) {
        self.sessions = sessions
        self.unavailable = unavailable
    }
}

public enum LocalReconciler {
    public static func scan(now: Date = Date()) -> ReconcileResult {
        var result = ReconcileResult()
        scanClaudeCLI(into: &result, now: now)
        scanClaudeDesktop(into: &result, now: now)
        scanCodex(into: &result, now: now)
        switch CodexAXProbe.hasInteractivePrompt() {
        case .none:
            result.unavailable.insert(.codexDesktop)
        case .some(true):
            for index in result.sessions.indices where
                result.sessions[index].surface == .codexDesktop &&
                result.sessions[index].status == .running {
                result.sessions[index].status = .needsInput
                result.sessions[index].attentionID = "question:ax"
            }
        case .some(false): break
        }
        return result
    }

    private static func scanClaudeCLI(into result: inout ReconcileResult, now: Date) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) else {
            result.unavailable.insert(.claudeCLI)
            return
        }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["sessionId"] as? String,
                  let status = json["status"] as? String,
                  let updated = json["updatedAt"] as? Double else {
                if now.timeIntervalSince(modified) < 3600 { result.unavailable.insert(.claudeCLI) }
                continue
            }
            let date = Date(timeIntervalSince1970: updated > 1_000_000_000_000 ? updated / 1000 : updated)
            let pid = json["pid"] as? Int ?? -1
            let processAlive = pid > 0 && (kill(Int32(pid), 0) == 0 || errno == EPERM)
            guard processAlive || now.timeIntervalSince(date) < 3600 else { continue }
            let state: SessionStatus
            if status == "busy" && !processAlive {
                state = claudeTranscriptState(sessionID: id).status == .ready ? .ready : .unavailable
            } else if status == "busy" { state = .running }
            else if status == "idle" { state = .ready }
            else if status == "shell" {
                state = claudeTranscriptState(sessionID: id).status == .ready ? .ready : .unavailable
            }
            else { state = .unavailable }
            result.sessions.append(AgentSession(source: .claude, surface: .claudeCLI,
                sessionID: id, projectPath: json["cwd"] as? String,
                title: json["name"] as? String, status: state, lastActivity: date,
                terminalBundleID: processAlive ? TerminalLocator.bundleID(startingAt: Int32(pid)) : nil))
        }
    }

    private static func scanClaudeDesktop(into result: inout ReconcileResult, now: Date) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            result.unavailable.insert(.claudeDesktop)
            return
        }
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty else { return }
        let transcripts = claudeTranscriptIndex()
        for case let file as URL in walker where file.lastPathComponent.hasPrefix("local_") &&
            file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            guard
                  let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["cliSessionId"] as? String else {
                if now.timeIntervalSince(modified) < 3600 { result.unavailable.insert(.claudeDesktop) }
                continue
            }
            guard (json["isArchived"] as? Bool) != true else { continue }
            let transcript = claudeTranscriptState(sessionID: id, index: transcripts)
            let activity = (json["lastActivityAt"] as? Double).map {
                Date(timeIntervalSince1970: $0 > 1_000_000_000_000 ? $0 / 1000 : $0)
            } ?? modified
            let latest = max(modified, activity, transcript.modifiedAt ?? modified)
            if now.timeIntervalSince(latest) >= 3600 {
                if now.timeIntervalSince(latest) < 86_400 && transcript.status == .running {
                    result.unavailable.insert(.claudeDesktop)
                }
                continue
            }
            result.sessions.append(AgentSession(source: .claude, surface: .claudeDesktop,
                sessionID: id, projectPath: json["cwd"] as? String,
                title: json["title"] as? String, status: transcript.status,
                lastActivity: latest))
        }
    }

    private static func claudeTranscriptState(sessionID: String) ->
        (status: SessionStatus, modifiedAt: Date?) {
        claudeTranscriptState(sessionID: sessionID, index: claudeTranscriptIndex())
    }

    private static func claudeTranscriptIndex() -> [String: URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: URL] = [:]
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            result[file.deletingPathExtension().lastPathComponent] = file
        }
        return result
    }

    private static func claudeTranscriptState(sessionID: String, index: [String: URL]) ->
        (status: SessionStatus, modifiedAt: Date?) {
        if let file = index[sessionID] {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let handle = try? FileHandle(forReadingFrom: file) else { return (.unavailable, modified) }
            defer { try? handle.close() }
            let length = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: length > 131_072 ? length - 131_072 : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            for line in tail.split(separator: 10).reversed() {
                guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let type = json["type"] as? String else { continue }
                if type == "assistant" {
                    let message = json["message"] as? [String: Any]
                    return ((message?["stop_reason"] as? String) == "end_turn" ? .ready : .running, modified)
                }
                if type == "user" { return (.running, modified) }
            }
        }
        return (.unavailable, nil)
    }

    private static func scanCodex(into result: inout ReconcileResult, now: Date) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/thread_history_1.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            result.unavailable.formUnion([.codexCLI, .codexDesktop])
            return
        }
        defer { sqlite3_close(database) }
        let query = """
            SELECT t.thread_id,t.turn_id,t.status,t.started_at,t.completed_at
            FROM thread_turns t JOIN (
                SELECT thread_id, MAX(rollout_ordinal) AS latest FROM thread_turns GROUP BY thread_id
            ) x ON t.thread_id=x.thread_id AND t.rollout_ordinal=x.latest
            WHERE t.started_at > ? OR t.completed_at > ? OR t.status='inProgress'
            ORDER BY (t.status='inProgress') DESC, COALESCE(t.completed_at,t.started_at) DESC
            LIMIT 200
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            result.unavailable.formUnion([.codexCLI, .codexDesktop])
            return
        }
        defer { sqlite3_finalize(statement) }
        let threshold = Int64(now.timeIntervalSince1970 - 3600)
        sqlite3_bind_int64(statement, 1, threshold)
        sqlite3_bind_int64(statement, 2, threshold)
        let desktopRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex").isEmpty
        let cliRunning = codexCLIProcessExists()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let turnText = sqlite3_column_text(statement, 1),
                  let statusText = sqlite3_column_text(statement, 2) else { continue }
            let id = String(cString: idText)
            let status = String(cString: statusText)
            let started = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)))
            let ended = sqlite3_column_type(statement, 4) == SQLITE_NULL ? started :
                Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)))
            let metadata = codexMetadata(id: id)
            var processMissing = false
            if status == "inProgress" {
                let processRunning = metadata?.surface == .codexDesktop ? desktopRunning : cliRunning
                if !processRunning {
                    if now.timeIntervalSince(started) >= 3600 { continue }
                    result.unavailable.insert(metadata?.surface ?? .codexCLI)
                    processMissing = true
                } else if now.timeIntervalSince(started) >= 3600 {
                    let lastWrite = codexTranscriptURL(id: id).flatMap {
                        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    } ?? .distantPast
                    if now.timeIntervalSince(lastWrite) >= 86_400 { continue }
                    if now.timeIntervalSince(lastWrite) >= 3600 {
                        result.unavailable.insert(metadata?.surface ?? .codexCLI)
                        continue
                    }
                }
            }
            let pendingQuestion = status == "inProgress" ?
                codexPendingQuestion(id: id, since: started.addingTimeInterval(-2)) : nil
            let state: SessionStatus
            switch status {
            case "inProgress": state = processMissing ? .unavailable :
                (pendingQuestion == nil ? .running : .needsInput)
            case "completed", "interrupted": state = .ready
            case "failed": state = .failed
            default: state = .unavailable
            }
            if metadata == nil && status == "inProgress" {
                result.unavailable.formUnion([.codexCLI, .codexDesktop])
            }
            result.sessions.append(AgentSession(source: .codex, surface: metadata?.surface ?? .codexCLI,
                sessionID: id, turnID: String(cString: turnText),
                projectPath: metadata?.projectPath, title: metadata?.title,
                status: state, lastActivity: ended,
                attentionID: pendingQuestion.map { "question:\($0)" }))
        }
        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
            result.unavailable.formUnion([.codexCLI, .codexDesktop])
        }
    }

    private static func codexMetadata(id: String) ->
        (surface: AgentSurface, projectPath: String?, title: String?)? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sqlite/codex-dev.db").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT source_kind,cwd,display_title FROM local_thread_catalog WHERE thread_id=? LIMIT 1", -1,
            &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        let surface: AgentSurface
        switch String(cString: value) {
        case "chatgpt", "vscode": surface = .codexDesktop
        case "cli": surface = .codexCLI
        default: return nil
        }
        let project = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        let title = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        return (surface, project, title)
    }

    private static func codexPendingQuestion(id: String, since: Date) -> String? {
        if let file = codexTranscriptURL(id: id) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            let length = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            var pending = Set<String>()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for line in tail.split(separator: 10) {
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      (record["type"] as? String) == "response_item",
                      let timestamp = record["timestamp"] as? String,
                      let date = formatter.date(from: timestamp), date >= since,
                      let payload = record["payload"] as? [String: Any],
                      let callID = payload["call_id"] as? String else { continue }
                switch payload["type"] as? String {
                case "function_call" where (payload["name"] as? String) == "request_user_input":
                    pending.insert(callID)
                case "function_call_output": pending.remove(callID)
                default: break
                }
            }
            return pending.first
        }
        return nil
    }

    private static func codexTranscriptURL(id: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        for case let file as URL in walker where file.lastPathComponent.hasSuffix("-\(id).jsonl") {
            return file
        }
        return nil
    }

    private static func codexCLIProcessExists() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-x", "codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
}
