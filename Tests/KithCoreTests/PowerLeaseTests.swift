import Darwin
import Foundation
import Testing
@testable import KithCore

final class PowerTestClock: @unchecked Sendable {
    var date = Date()
}

final class FakePowerHardware: PowerHardware, @unchecked Sendable {
    var disabled = false
    var modes = ["b": false, "c": true]
    var failWrites = false
    var writes = 0
    var stateURL: URL?
    func sleepDisabled() throws -> Bool { disabled }
    func lowPowerSettings() throws -> [String: Bool] { modes }
    func setSleepDisabled(_ value: Bool, lock: FileHandle) throws {
        #expect(stateURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        if failWrites { throw PowerError.unavailable("Simulated write failure") }
        writes += 1; disabled = value
    }
    func setLowPower(_ value: Bool, source: String, lock: FileHandle) throws {
        #expect(stateURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        if failWrites { throw PowerError.unavailable("Simulated write failure") }
        writes += 1; modes[source] = value
    }
}

struct PowerLeaseTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kith-power-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func leaseExpiresAndRestoresOnlyOwnedPreferences() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = PowerTestClock()
        let hardware = FakePowerHardware()
        hardware.stateURL = dir.appendingPathComponent("state.json")
        let controller = PowerLeaseController(stateURL: hardware.stateURL!, lockURL: dir.appendingPathComponent("lock"),
            hardware: hardware, now: { clock.date })
        let id = UUID().uuidString
        try controller.configure(id: id, uid: 501,
            request: PowerLeaseRequest(deadline: clock.date.addingTimeInterval(600), closedLid: true, lowPower: true))
        #expect(hardware.disabled)
        #expect(controller.status.leaseID == id)
        #expect(hardware.modes == ["b": true, "c": true])
        clock.date.addTimeInterval(46)
        controller.expireIfNeeded()
        #expect(!hardware.disabled)
        #expect(hardware.modes == ["b": false, "c": true])
        #expect(controller.status.recovery == .restored)
        #expect(controller.status.leaseID == nil)
        #expect(!FileManager.default.fileExists(atPath: hardware.stateURL!.path))
    }

    @Test func deadlineCannotBeBypassedByLateRenewal() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = PowerTestClock()
        let hardware = FakePowerHardware()
        let controller = PowerLeaseController(stateURL: dir.appendingPathComponent("state"),
            lockURL: dir.appendingPathComponent("lock"), hardware: hardware, now: { clock.date })
        let id = UUID().uuidString
        let request = PowerLeaseRequest(deadline: clock.date.addingTimeInterval(5), closedLid: true, lowPower: false)
        try controller.configure(id: id, uid: 501, request: request)
        clock.date.addTimeInterval(6)
        #expect(throws: PowerError.self) { try controller.configure(id: id, uid: 501, request: request) }
        controller.expireIfNeeded()
        #expect(!hardware.disabled)
    }

    @Test func restartRecoversRecordedIntentAfterFailedMutation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let hardware = FakePowerHardware()
        hardware.failWrites = true
        let state = dir.appendingPathComponent("state")
        let lock = dir.appendingPathComponent("lock")
        let controller = PowerLeaseController(stateURL: state, lockURL: lock, hardware: hardware)
        #expect(throws: PowerError.self) {
            try controller.configure(id: UUID().uuidString, uid: 501,
                request: PowerLeaseRequest(deadline: Date().addingTimeInterval(600), closedLid: true, lowPower: true))
        }
        #expect(FileManager.default.fileExists(atPath: state.path))
        #expect(controller.status.recovery == .pending)
        hardware.failWrites = false
        let restarted = PowerLeaseController(stateURL: state, lockURL: lock, hardware: hardware)
        restarted.recoverAfterRestart()
        #expect(!hardware.disabled)
        #expect(hardware.modes["b"] == false)
        #expect(restarted.status.recovery == .restored)
    }

    @Test func externalWakeHoldAndUserPowerChangesAreRespected() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let hardware = FakePowerHardware(); hardware.disabled = true
        let controller = PowerLeaseController(stateURL: dir.appendingPathComponent("state"),
            lockURL: dir.appendingPathComponent("lock"), hardware: hardware)
        let id = UUID().uuidString
        let request = PowerLeaseRequest(deadline: Date().addingTimeInterval(600), closedLid: true, lowPower: true)
        try controller.configure(id: id, uid: 501, request: request)
        #expect(controller.status.externalWakeOwner)
        hardware.modes["b"] = false // The user turned it off during the wake period.
        try controller.configure(id: id, uid: 501, request: request)
        #expect(hardware.modes["b"] == false)
        hardware.modes["b"] = true // A later user choice must survive release as well.
        try controller.release(id: id, uid: 501)
        #expect(hardware.disabled)
        #expect(hardware.modes["b"] == true)
    }

    @Test func anotherAccountCannotReleaseOrReplaceLease() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let hardware = FakePowerHardware()
        let controller = PowerLeaseController(stateURL: dir.appendingPathComponent("state"),
            lockURL: dir.appendingPathComponent("lock"), hardware: hardware)
        let id = UUID().uuidString
        let request = PowerLeaseRequest(deadline: Date().addingTimeInterval(600), closedLid: true, lowPower: false)
        try controller.configure(id: id, uid: 501, request: request)
        #expect(throws: PowerError.self) { try controller.release(id: id, uid: 502) }
        #expect(throws: PowerError.self) { try controller.configure(id: id, uid: 502, request: request) }
        #expect(controller.status.recovery == .restored)
        #expect(hardware.disabled)
    }

    @Test func unreadableStateIsPreservedAndBlocksFinishActions() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        try Data("broken".utf8).write(to: state)
        let hardware = FakePowerHardware()
        let controller = PowerLeaseController(stateURL: state, lockURL: dir.appendingPathComponent("lock"), hardware: hardware)
        controller.recoverAfterRestart()
        #expect(controller.status.recovery == .needsAttention)
        #expect(throws: PowerError.self) { try controller.prepareForFinishAction(uid: 501) }
        #expect(try String(contentsOf: state, encoding: .utf8) == "broken")
        #expect(hardware.writes == 0)
    }

    @Test func recoveryWaitsForLockThenRetries() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let hardware = FakePowerHardware()
        let clock = PowerTestClock()
        let lockURL = dir.appendingPathComponent("lock")
        let controller = PowerLeaseController(stateURL: dir.appendingPathComponent("state"), lockURL: lockURL,
            hardware: hardware, now: { clock.date })
        try controller.configure(id: UUID().uuidString, uid: 501,
            request: PowerLeaseRequest(deadline: clock.date.addingTimeInterval(600), closedLid: true, lowPower: false))
        let lock = try PowerStorage.lock(at: lockURL)
        clock.date.addTimeInterval(46)
        controller.expireIfNeeded()
        #expect(controller.status.recovery == .pending)
        #expect(hardware.disabled)
        try lock.close()
        controller.expireIfNeeded()
        #expect(!hardware.disabled)
        #expect(controller.status.recovery == .restored)
    }

    @Test func legacyLeaseCanStillBeRecovered() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        let data: [String: Any] = ["leaseID": UUID().uuidString, "previousDisabled": false,
            "changedByKith": true, "expiresAt": Date().timeIntervalSinceReferenceDate + 45]
        try JSONSerialization.data(withJSONObject: data).write(to: state)
        let hardware = FakePowerHardware(); hardware.disabled = true
        let controller = PowerLeaseController(stateURL: state, lockURL: dir.appendingPathComponent("lock"), hardware: hardware)
        controller.recoverAfterRestart()
        #expect(!hardware.disabled)
        #expect(controller.status.recovery == .restored)
    }

    @Test func malformedRecoveryFieldsArePreservedWithoutPartialRestoration() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("state")
        let data: [String: Any] = ["leaseID": UUID().uuidString, "previousDisabled": false,
            "changedByKith": true, "expiresAt": Date().timeIntervalSinceReferenceDate + 45,
            "previousLowPower": ["unexpected-source": false]]
        let bytes = try JSONSerialization.data(withJSONObject: data)
        try bytes.write(to: state)
        let hardware = FakePowerHardware(); hardware.disabled = true
        let controller = PowerLeaseController(stateURL: state, lockURL: dir.appendingPathComponent("lock"), hardware: hardware)
        controller.recoverAfterRestart()
        #expect(controller.status.recovery == .needsAttention)
        #expect(hardware.writes == 0)
        #expect(try Data(contentsOf: state) == bytes)
    }
}
