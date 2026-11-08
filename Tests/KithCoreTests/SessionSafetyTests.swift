import Foundation
import Testing
@testable import KithCore

struct SessionSafetyTests {
    @Test func expiryRemovesOnlyOldCompletedSessions() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-86_400)
        var store = SessionStore()
        for status in [SessionStatus.ready, .running, .needsInput, .failed, .unavailable] {
            _ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                sessionID: status.rawValue, status: status, lastActivity: cutoff))
        }
        _ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
            sessionID: "recent", status: .ready, lastActivity: now))
        store.pruneCompleted(olderThan: cutoff)
        #expect(store.sessions["codex:ready"] == nil)
        #expect(store.sessions["codex:recent"] != nil)
        #expect(store.sessions.count == 5)
        #expect(!store.allSafeToFinish)
    }

    @Test func unchangedScansAndReplayedEventsDoNotAdvanceRevision() {
        var store = SessionStore()
        let observed = AgentSession(source: .claude, surface: .claudeCLI,
                                    sessionID: "test", title: "Original", status: .running)
        _ = store.reconcile(observed)
        let revision = store.revision
        _ = store.reconcile(observed)
        store.markMissing(seenIDs: [observed.id], olderThan: Date())
        store.pruneCompleted(olderThan: Date())
        #expect(store.revision == revision)
        var renamed = observed
        renamed.title = "Renamed"
        _ = store.reconcile(renamed)
        #expect(store.revision > revision)
        let event = AgentEvent(source: .claude, sessionID: "test", kind: .sessionStarted)
        _ = store.apply(event, surface: .claudeCLI)
        let eventRevision = store.revision
        _ = store.apply(event, surface: .claudeCLI)
        #expect(store.revision == eventRevision)
    }

    @Test func interactivePromptBlocksCompletionUntilResolved() {
        var store = SessionStore()
        let id = "session-test"
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .turnStarted), surface: .claudeCLI)
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .attentionOpened), surface: .claudeCLI)
        #expect(!store.allSafeToFinish)
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .attentionResolved), surface: .claudeCLI)
        #expect(!store.allSafeToFinish)
    }

    @Test(arguments: [SessionStatus.failed, .unavailable])
    func failedAndUnavailableSessionsBlockFinish(status: SessionStatus) {
        var store = SessionStore()
        _ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                                         sessionID: "test", status: status))
        #expect(!store.allSafeToFinish)
    }

    @Test func scanConfirmsRestoredSessionDespiteNewerHook() {
        var store = SessionStore()
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .unavailable, lastActivity: .distantPast))
        _ = store.apply(AgentEvent(source: .claude, sessionID: "test", kind: .sessionStarted),
                        surface: .claudeCLI)
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .running, lastActivity: Date().addingTimeInterval(-60)))
        #expect(store.sessions["claude:test"]?.status == .running)
    }

    @Test func waitingScanBlocksFinishUntilBusyAgain() {
        var store = SessionStore()
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .needsInput, attentionID: "question:waiting"))
        #expect(!store.allSafeToFinish)
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .running))
        #expect(store.sessions["claude:test"]?.status == .running)
    }

    @Test func stopHookAloneDoesNotMarkReady() {
        var store = SessionStore()
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .turnStarted),
                        surface: .codexCLI)
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .stopCandidate),
                        surface: .codexCLI)
        #expect(store.sessions["codex:test"]?.status == .running)
        #expect(!store.allSafeToFinish)
    }

    @Test func scanWithoutTerminalKeepsHookTab() {
        var store = SessionStore()
        _ = store.apply(AgentEvent(source: .claude, sessionID: "test", kind: .turnStarted,
                                   terminalBundleID: "com.apple.Terminal", terminalTTY: "/dev/ttys003"),
                        surface: .claudeCLI)
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .running))
        #expect(store.sessions["claude:test"]?.terminalTTY == "/dev/ttys003")
    }

    @Test func toolResultEndsScannedWait() {
        var store = SessionStore()
        _ = store.apply(AgentEvent(source: .claude, sessionID: "test", kind: .attentionOpened,
                                   attentionID: "toolu_1"), surface: .claudeCLI)
        _ = store.reconcile(AgentSession(source: .claude, surface: .claudeCLI, sessionID: "test",
                                         status: .needsInput, attentionID: "question:waiting:1"))
        _ = store.apply(AgentEvent(source: .claude, sessionID: "test", kind: .attentionResolved,
                                   attentionID: "toolu_1"), surface: .claudeCLI)
        #expect(store.sessions["claude:test"]?.status == .running)
    }
}

struct EventSpoolTests {
    @Test func pendingEventsStayReplayableUntilAcknowledged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kith-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = AgentEvent(source: .codex, sessionID: "test", kind: .turnStarted)
        let file = directory.appendingPathComponent("\(event.id.uuidString).json")
        try JSONEncoder().encode(event).write(to: file)
        try Data("invalid JSON".utf8).write(to: directory.appendingPathComponent("invalid.json"))
        let pending = EventSpool.pending(in: directory)
        #expect(pending.count == 1)
        #expect(pending.first?.event.id == event.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(EventSpool.pending(in: directory).first?.event.id == event.id)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("invalid.json").path))

        var store = SessionStore()
        _ = store.apply(event, surface: .codexCLI)
        let snapshot = directory.appendingPathComponent("snapshot")
        try store.save(to: snapshot)
        var restored = SessionStore.load(from: snapshot)
        let revision = restored.revision
        _ = restored.apply(event, surface: .codexCLI)
        #expect(restored.revision == revision)
        #expect(restored.sessions["codex:test"]?.status == .unavailable)
        try FileManager.default.removeItem(at: file)
        #expect(EventSpool.pending(in: directory).isEmpty)
    }
}
