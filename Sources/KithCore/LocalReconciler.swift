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
    public static func scan(now: Date = Date(),
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ReconcileResult {
        var result = ReconcileResult()
        scanClaudeCLI(into: &result, now: now, home: home)
        scanClaudeDesktop(into: &result, now: now, home: home)
        scanCodex(into: &result, now: now, home: home)
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

    private static func scanClaudeCLI(into result: inout ReconcileResult, now: Date, home: URL) {
        let root = home.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let directory = root.appendingPathComponent("sessions")
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
            var attentionID: String?
            if (status == "busy" || status == "waiting") && !processAlive {
                state = claudeTranscriptState(sessionID: id, home: home).status == .ready ? .ready : .unavailable
            } else if status == "busy" { state = .running }
            else if status == "waiting" {
                // Claude is blocked on the user; the question: prefix lets a later busy scan clear it,
                // and updatedAt, set when the wait began, gives each wait its own alert.
                state = .needsInput
                attentionID = "question:waiting:\(Int(updated))"
            }
            else if status == "idle" { state = .ready }
            else if status == "shell" {
                state = claudeTranscriptState(sessionID: id, home: home).status == .ready ? .ready : .unavailable
            }
            else { state = .unavailable }
            let terminal = processAlive ? TerminalLocator.locate(startingAt: Int32(pid)) : nil
            result.sessions.append(AgentSession(source: .claude, surface: .claudeCLI,
                sessionID: id, projectPath: json["cwd"] as? String,
                title: json["name"] as? String, status: state, lastActivity: date,
                attentionID: attentionID,
                terminalBundleID: terminal?.bundleID, terminalTTY: terminal?.tty))
        }
    }

    private static func scanClaudeDesktop(into result: inout ReconcileResult, now: Date, home: URL) {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            result.unavailable.insert(.claudeDesktop)
            return
        }
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty else { return }
        let transcripts = claudeTranscriptIndex(home: home)
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

    private static func claudeTranscriptState(sessionID: String, home: URL) ->
        (status: SessionStatus, modifiedAt: Date?) {
        claudeTranscriptState(sessionID: sessionID, index: claudeTranscriptIndex(home: home))
    }

    private static func claudeTranscriptIndex(home: URL) -> [String: URL] {
        let root = home.appendingPathComponent(".claude/projects")
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

    private static func scanCodex(into result: inout ReconcileResult, now: Date, home: URL) {
        let root = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let database = openCodexDatabase(root.appendingPathComponent("thread_history_1.sqlite")),
              let threads = openCodexDatabase(root.appendingPathComponent("state_5.sqlite")) else {
            result.unavailable.formUnion([.codexCLI, .codexDesktop])
            return
        }
        defer { sqlite3_close(database); sqlite3_close(threads) }
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
        var sessions: [AgentSession] = []
        var parentsWithActiveSubagents = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let turnText = sqlite3_column_text(statement, 1),
                  let statusText = sqlite3_column_text(statement, 2) else { continue }
            let id = String(cString: idText)
            let status = String(cString: statusText)
            let started = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)))
            let ended = sqlite3_column_type(statement, 4) == SQLITE_NULL ? started :
                Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)))
            let metadata = codexMetadata(id: id, in: threads)
            let rolloutWrite = {
                metadata?.transcript.flatMap {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                } ?? .distantPast
            }
            // Subagent work belongs to the thread that spawned it; count it there instead of listing it.
            if let parent = metadata?.parentID {
                if status == "inProgress" && (now.timeIntervalSince(started) < 3600 ||
                                              now.timeIntervalSince(rolloutWrite()) < 3600) {
                    parentsWithActiveSubagents.insert(parent)
                }
                continue
            }
            var processMissing = false
            if status == "inProgress" {
                let processRunning = metadata?.surface == .codexDesktop ? desktopRunning : cliRunning
                if !processRunning {
                    if now.timeIntervalSince(started) >= 3600 { continue }
                    result.unavailable.insert(metadata?.surface ?? .codexCLI)
                    processMissing = true
                } else if now.timeIntervalSince(started) >= 3600 {
                    let lastWrite = rolloutWrite()
                    if now.timeIntervalSince(lastWrite) >= 86_400 { continue }
                    if now.timeIntervalSince(lastWrite) >= 3600 {
                        result.unavailable.insert(metadata?.surface ?? .codexCLI)
                        continue
                    }
                }
            }
            let pendingQuestion = status == "inProgress" ? metadata?.transcript.flatMap {
                codexPendingQuestion(in: $0, since: started.addingTimeInterval(-2))
            } : nil
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
            sessions.append(AgentSession(source: .codex, surface: metadata?.surface ?? .codexCLI,
                sessionID: id, turnID: String(cString: turnText),
                projectPath: metadata?.projectPath, title: metadata?.title,
                status: state, lastActivity: ended,
                attentionID: pendingQuestion.map { "question:\($0)" }))
        }
        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE {
            result.unavailable.formUnion([.codexCLI, .codexDesktop])
        }
        for index in sessions.indices where sessions[index].status == .ready &&
            parentsWithActiveSubagents.contains(sessions[index].sessionID) {
            sessions[index].status = .running
        }
        result.sessions += sessions
    }

    /// Codex deletes a database's -wal and -shm files when it closes it, and a read-only
    /// connection cannot recreate them. Without a -wal every commit is in the main file,
    /// so it is read as immutable instead.
    private static func openCodexDatabase(_ url: URL) -> OpaquePointer? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        if !FileManager.default.fileExists(atPath: url.path + "-wal") {
            components.queryItems?.append(URLQueryItem(name: "immutable", value: "1"))
        }
        var database: OpaquePointer?
        guard let uri = components.string,
              sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func codexMetadata(id: String, in database: OpaquePointer) ->
        (surface: AgentSurface, projectPath: String?, title: String?, transcript: URL?, parentID: String?)? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT source,cwd,name,rollout_path FROM threads WHERE id=? LIMIT 1", -1,
            &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        let source = String(cString: value)
        let surface: AgentSurface
        var parentID: String?
        switch source {
        case "vscode", "chatgpt": surface = .codexDesktop
        case "cli", "exec": surface = .codexCLI
        default:
            // Subagents record their origin as {"subagent":{"thread_spawn":{"parent_thread_id":…}}}.
            let json = (try? JSONSerialization.jsonObject(with: Data(source.utf8))) as? [String: Any]
            let spawn = (json?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
            guard let parent = spawn?["parent_thread_id"] as? String else { return nil }
            surface = .codexCLI
            parentID = parent
        }
        let project = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        let title = sqlite3_column_text(statement, 2).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let transcript = sqlite3_column_text(statement, 3).map { URL(fileURLWithPath: String(cString: $0)) }
        return (surface, project, title, transcript, parentID)
    }

    private static func codexPendingQuestion(in file: URL, since: Date) -> String? {
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

    /// The Codex Desktop app bundles its own `codex` binary, so only one outside an app bundle is the CLI.
    private static func codexCLIProcessExists() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-x", "-o", "comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { path in
            (path == "codex" || path.hasSuffix("/codex")) && !path.contains(".app/")
        }
    }
}
