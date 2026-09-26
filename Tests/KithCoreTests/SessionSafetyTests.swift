import Foundation
import Testing
@testable import KithCore

struct SessionSafetyTests {
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

    @Test func stopHookAloneDoesNotMarkReady() {
        var store = SessionStore()
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .turnStarted),
                        surface: .codexCLI)
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .stopCandidate),
                        surface: .codexCLI)
        #expect(store.sessions["codex:test"]?.status == .running)
        #expect(!store.allSafeToFinish)
    }
}
