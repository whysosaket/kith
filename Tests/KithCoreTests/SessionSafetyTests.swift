import XCTest
@testable import KithCore

final class SessionSafetyTests: XCTestCase {
    func testInteractivePromptBlocksCompletionUntilResolved() {
        var store = SessionStore()
        let id = "session-test"
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .turnStarted), surface: .claudeCLI)
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .attentionOpened), surface: .claudeCLI)
        XCTAssertFalse(store.allSafeToFinish)
        _ = store.apply(AgentEvent(source: .claude, sessionID: id, kind: .attentionResolved), surface: .claudeCLI)
        XCTAssertFalse(store.allSafeToFinish)
    }

    func testFailedAndUnavailableSessionsBlockFinish() {
        for status: SessionStatus in [.failed, .unavailable] {
            var store = SessionStore()
            _ = store.reconcile(AgentSession(source: .codex, surface: .codexCLI,
                                             sessionID: "test", status: status))
            XCTAssertFalse(store.allSafeToFinish)
        }
    }

    func testStopHookAloneDoesNotMarkReady() {
        var store = SessionStore()
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .turnStarted),
                        surface: .codexCLI)
        _ = store.apply(AgentEvent(source: .codex, sessionID: "test", kind: .stopCandidate),
                        surface: .codexCLI)
        XCTAssertEqual(store.sessions["codex:test"]?.status, .running)
        XCTAssertFalse(store.allSafeToFinish)
    }
}
