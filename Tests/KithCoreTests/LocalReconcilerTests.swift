import Foundation
import SQLite3
import Testing
@testable import KithCore

struct LocalReconcilerTests {
    private let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("kith-home-\(UUID().uuidString)")

    @Test func missingAgentsAreNotMonitoringFailures() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let result = LocalReconciler.scan(home: home)
        #expect(!result.unavailable.contains(.claudeCLI))
        #expect(!result.unavailable.contains(.codexCLI))
    }

    @Test func readsCodexDatabasesAfterCodexClosesThem() throws {
        let now = Date()
        try makeCodexHome(now: now, turns: [("desktop", "completed")],
                          threads: [("desktop", "vscode", "Desktop thread")])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!FileManager.default.fileExists(atPath: home.path + "/.codex/thread_history_1.sqlite-wal"))
        let result = LocalReconciler.scan(now: now, home: home)
        #expect(!result.unavailable.contains(.codexCLI))
        let session = result.sessions.first { $0.sessionID == "desktop" }
        #expect(session?.surface == .codexDesktop)
        #expect(session?.status == .ready)
        #expect(session?.title == "Desktop thread")
    }

    @Test func activeSubagentKeepsItsParentWorking() throws {
        let now = Date()
        let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}"#
        try makeCodexHome(now: now, turns: [("parent", "completed"), ("child", "inProgress")],
                          threads: [("parent", "exec", "Parent"), ("child", spawn, "")])
        defer { try? FileManager.default.removeItem(at: home) }
        let result = LocalReconciler.scan(now: now, home: home)
        #expect(!result.unavailable.contains(.codexCLI))
        #expect(!result.sessions.contains { $0.sessionID == "child" })
        #expect(result.sessions.first { $0.sessionID == "parent" }?.status == .running)
    }

    private func makeCodexHome(now: Date, turns: [(id: String, status: String)],
                               threads: [(id: String, source: String, name: String)]) throws {
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let started = Int(now.timeIntervalSince1970) - 60
        try execute(codex.appendingPathComponent("thread_history_1.sqlite"), [
            "PRAGMA journal_mode=WAL",
            """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
                status TEXT, started_at INTEGER, completed_at INTEGER)
            """
        ] + turns.map { turn in
            let completed = turn.status == "inProgress" ? "NULL" : String(started + 30)
            return "INSERT INTO thread_turns VALUES ('\(turn.id)','turn-\(turn.id)',1," +
                "'\(turn.status)',\(started),\(completed))"
        })
        try execute(codex.appendingPathComponent("state_5.sqlite"), [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE threads (id TEXT, source TEXT, cwd TEXT, name TEXT, rollout_path TEXT)"
        ] + threads.map { thread in
            "INSERT INTO threads VALUES ('\(thread.id)','\(thread.source)','/tmp/project'," +
                "'\(thread.name)',NULL)"
        })
    }

    private func execute(_ url: URL, _ statements: [String]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw POSIXError(.EIO) }
        for statement in statements {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(database)
                throw POSIXError(.EIO)
            }
        }
        sqlite3_close(database)
        // Apple's SQLite keeps an empty -wal after closing; Codex's removes both files, like this.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
