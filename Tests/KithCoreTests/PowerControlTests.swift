import Darwin
import Foundation
import Testing
@testable import KithCore

struct PowerControlTests {
    func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kith-control-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func inboxAcknowledgesExactlyOnce() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = try PowerCommandInbox(directory: dir)
        let command = PowerCommand(kind: .start, seconds: 60)
        let result = Task.detached { try PowerCommandInbox.send(command, directory: dir) }
        var calls = 0
        for _ in 0..<20 {
            inbox.drain { request in
                calls += 1
                #expect(request.kind == .start)
                return PowerCommandReply(ok: true, message: "accepted")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reply = try await result.value
        #expect(reply.ok)
        #expect(calls == 1)
    }

    @Test func staleAndMismatchedRequestsNeverExecute() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = try PowerCommandInbox(directory: dir)
        var command = PowerCommand(kind: .end, now: Date().addingTimeInterval(-60))
        try PowerStorage.write(command, to: dir.appendingPathComponent(command.id.uuidString + ".request"))
        command = PowerCommand(kind: .end)
        try PowerStorage.write(command, to: dir.appendingPathComponent(UUID().uuidString + ".request"))
        var executed = false
        inbox.drain { _ in executed = true; return PowerCommandReply(ok: true, message: "unexpected") }
        #expect(!executed)
    }

    @Test func onlyOneAppOwnsPowerControl() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = try PowerCommandInbox(directory: dir)
        #expect(throws: PowerError.self) { _ = try PowerCommandInbox(directory: dir) }
        withExtendedLifetime(inbox) {}
    }

    @Test func malformedPolicyIsArchivedOnlyByExplicitResume() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("power.json")
        try Data("unreadable".utf8).write(to: file)
        let session = PowerSession(stateURL: file)
        let decision = session.update(now: Date(), work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 300, conditions: PowerConditions(), preferences: PowerPreferences())
        #expect(!decision.hold)
        #expect(try String(contentsOf: file, encoding: .utf8) == "unreadable")
        try session.apply(PowerCommand(kind: .resume), now: Date(), conditions: PowerConditions(), preferences: PowerPreferences())
        #expect(session.policy.stopped == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("power.json.unreadable-") })
    }

    @Test func policySurvivesRestartWithoutResettingDeadline() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("power.json")
        let session = PowerSession(stateURL: file)
        let now = Date()
        try session.apply(PowerCommand(kind: .start, seconds: 600), now: now,
            conditions: PowerConditions(), preferences: PowerPreferences())
        let deadline = session.policy.period?.deadline
        let restarted = PowerSession(stateURL: file)
        let decision = restarted.update(now: now.addingTimeInterval(10), work: true, monitoringReady: true,
            automaticEnabled: true, graceSeconds: 300, conditions: PowerConditions(), preferences: PowerPreferences())
        #expect(decision.hold)
        #expect(restarted.policy.period?.deadline == deadline)
        let stopped = restarted.update(now: now.addingTimeInterval(601), work: true, monitoringReady: true,
            automaticEnabled: true, graceSeconds: 300, conditions: PowerConditions(), preferences: PowerPreferences())
        #expect(stopped.stop == .deadline)
    }

    @Test func unsafeResumePreservesUnreadablePolicy() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("power.json")
        try Data("unreadable".utf8).write(to: file)
        let session = PowerSession(stateURL: file)
        #expect(throws: PowerError.self) {
            try session.apply(PowerCommand(kind: .resume), now: Date(),
                conditions: PowerConditions(heat: .critical), preferences: PowerPreferences())
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "unreadable")
    }

    @Test func failedPersistencePreventsWakeRequest() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("power")
        let session = PowerSession(stateURL: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let decision = session.update(now: Date(), work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 0, conditions: PowerConditions(), preferences: PowerPreferences())
        #expect(!decision.hold)
        #expect(session.policy.stopped == .persistence)
    }

    @Test func secureStorageRejectsSymlinksAndUsesPrivatePermissions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        let link = dir.appendingPathComponent("link")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: PowerError.self) { try PowerStorage.write(["changed"], to: link) }
        #expect(throws: PowerError.self) { _ = try PowerStorage.read([String].self, from: link) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        let file = dir.appendingPathComponent("private")
        try PowerStorage.write(PowerPreferences(), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func durationAndVersionParsingRejectAmbiguity() {
        #expect(PowerDuration.parse("2h") == 7200)
        #expect(PowerDuration.parse("1s") == 1)
        for value in ["0s", "-1h", "1.5h", "25h", "2", "nan", "999999999999999999999h"] {
            #expect(PowerDuration.parse(value) == nil)
        }
        #expect(ReleaseVersion("v1.10.0")! > ReleaseVersion("1.9.0")!)
        #expect(ReleaseVersion("1.0.0-beta") == nil)
        #expect(ReleaseVersion("1.0") == nil)
    }

    @Test func boundedCommandsCaptureOutputAndDoNotHangOnLargeOutput() throws {
        let runner = BoundedCommand()
        let output = try runner.run("/usr/bin/printf", ["hello"])
        #expect(output.output == "hello")
        #expect(output.status == 0)
        let start = Date()
        #expect(throws: PowerError.self) { _ = try runner.run("/usr/bin/yes", [], timeout: 0.1) }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
