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
        try HookInstaller.install(executable: URL(fileURLWithPath: "/Applications/Kith.app/Contents/MacOS/kith-event"),
                                  home: home)
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
        let spawn = { (parent: String) in #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}"# }
        let fresh = home.appendingPathComponent("fresh.jsonl")
        let stale = home.appendingPathComponent("stale.jsonl")
        try makeCodexHome(now: now,
                          turns: [("parent", "completed"), ("child", "inProgress"),
                                  ("longParent", "completed"), ("longChild", "inProgress"),
                                  ("staleParent", "completed"), ("staleChild", "inProgress")],
                          threads: [("parent", "exec", "Parent"), ("child", spawn("parent"), ""),
                                    ("longParent", "exec", "Long"), ("longChild", spawn("longParent"), ""),
                                    ("staleParent", "exec", "Stale"), ("staleChild", spawn("staleParent"), "")],
                          startedAgo: ["longChild": 7200, "staleChild": 7200],
                          rollouts: ["longChild": fresh, "staleChild": stale])
        defer { try? FileManager.default.removeItem(at: home) }
        for url in [fresh, stale] { try Data().write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)],
                                              ofItemAtPath: stale.path)
        // Subagents only hold their parent while Codex runs, so stand in for the CLI.
        let standIn = home.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: standIn)
        let codex = try Process.run(standIn, arguments: ["60"])
        defer { codex.terminate(); codex.waitUntilExit() }
        let result = LocalReconciler.scan(now: now, home: home)
        #expect(!result.unavailable.contains(.codexCLI))
        #expect(!result.sessions.contains { $0.sessionID == "child" })
        #expect(result.sessions.first { $0.sessionID == "parent" }?.status == .running)
        // Past an hour, a subagent holds its parent only while it still writes its rollout.
        #expect(result.sessions.first { $0.sessionID == "longParent" }?.status == .running)
        #expect(result.sessions.first { $0.sessionID == "staleParent" }?.status == .ready)
    }

    private func makeCodexHome(now: Date, turns: [(id: String, status: String)],
                               threads: [(id: String, source: String, name: String)],
                               startedAgo: [String: Int] = [:], rollouts: [String: URL] = [:]) throws {
        let codex = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try execute(codex.appendingPathComponent("thread_history_1.sqlite"), [
            "PRAGMA journal_mode=WAL",
            """
            CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
                status TEXT, started_at INTEGER, completed_at INTEGER)
            """
        ] + turns.map { turn in
            let started = Int(now.timeIntervalSince1970) - (startedAgo[turn.id] ?? 60)
            let completed = turn.status == "inProgress" ? "NULL" : String(started + 30)
            return "INSERT INTO thread_turns VALUES ('\(turn.id)','turn-\(turn.id)',1," +
                "'\(turn.status)',\(started),\(completed))"
        })
        try execute(codex.appendingPathComponent("state_5.sqlite"), [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE threads (id TEXT, source TEXT, cwd TEXT, name TEXT, rollout_path TEXT)"
        ] + threads.map { thread in
            let rollout = rollouts[thread.id].map { "'\($0.path)'" } ?? "NULL"
            return "INSERT INTO threads VALUES ('\(thread.id)','\(thread.source)','/tmp/project'," +
                "'\(thread.name)',\(rollout))"
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
