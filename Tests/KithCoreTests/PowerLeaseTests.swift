import Foundation
import Testing
@testable import KithCore

private final class FakePowerHardware: PowerRecoveryHardware, @unchecked Sendable {
    var disabled = false
    var modes = ["b": false, "c": false]
    var failSource: String?
    var writes = 0

    func restoreSleep(lock: FileHandle) throws {
        if disabled { writes += 1; disabled = false }
    }

    func restoreLowPower(source: String, lock: FileHandle) throws {
        if failSource == source { throw PowerError.unavailable("Simulated write failure") }
        if modes[source] == true { writes += 1; modes[source] = false }
    }
}

struct PowerLeaseTests {
    private func withRecovery(
        _ test: (URL, URL, FakePowerHardware, PowerPreferenceRecovery) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-power-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state")
        let lock = directory.appendingPathComponent("lock")
        let hardware = FakePowerHardware()
        let recovery = PowerPreferenceRecovery(stateURL: state, lockURL: lock, hardware: hardware)
        try test(state, lock, hardware, recovery)
    }

    private func writeLegacyLease(to state: URL, previousDisabled: Bool = false, changedByKith: Bool = true,
                                  previousLowPower: [String: Bool]? = nil) throws {
        var data: [String: Any] = ["leaseID": UUID().uuidString, "previousDisabled": previousDisabled,
            "changedByKith": changedByKith, "expiresAt": Date().timeIntervalSinceReferenceDate + 45]
        data["previousLowPower"] = previousLowPower
        try JSONSerialization.data(withJSONObject: data).write(to: state)
    }

    @Test func recoversLegacySettingsWithoutWaitingForTheOldDeadline() throws {
        try withRecovery { state, _, hardware, recovery in
            try writeLegacyLease(to: state, previousLowPower: ["b": false])
            hardware.disabled = true
            hardware.modes = ["b": true, "c": true]
            try recovery.restore()
            #expect(!hardware.disabled)
            #expect(hardware.modes == ["b": false, "c": true])
            #expect(recovery.status.recovery == .restored)
            #expect(!FileManager.default.fileExists(atPath: state.path))
        }
    }

    @Test func preservesUnownedSettingsAndSkipsAlreadyRestoredModes() throws {
        try withRecovery { state, _, hardware, recovery in
            hardware.disabled = true
            hardware.modes["c"] = true
            try recovery.restore() // No journal means no ownership.
            try writeLegacyLease(to: state, previousDisabled: true, changedByKith: false, previousLowPower: ["b": false])
            try recovery.restore()
            #expect(hardware.writes == 0)
            #expect(hardware.disabled)
            #expect(hardware.modes == ["b": false, "c": true])
        }
    }

    @Test func retryAfterRestartPreservesChangesMadeAfterPartialRecovery() throws {
        try withRecovery { state, lock, hardware, recovery in
            try writeLegacyLease(to: state, previousLowPower: ["b": false, "c": false])
            hardware.disabled = true
            hardware.modes = ["b": true, "c": true]
            hardware.failSource = "b"
            #expect(throws: PowerError.self) { try recovery.restore() }
            #expect(recovery.status.recovery == .pending)
            #expect(!hardware.disabled)
            #expect(hardware.modes == ["b": true, "c": false])
            #expect(FileManager.default.fileExists(atPath: state.path))

            hardware.disabled = true
            hardware.modes["c"] = true
            hardware.failSource = nil
            let restarted = PowerPreferenceRecovery(stateURL: state, lockURL: lock, hardware: hardware)
            try restarted.restore()
            #expect(hardware.disabled)
            #expect(hardware.modes == ["b": false, "c": true])
            #expect(restarted.status.recovery == .restored)
            #expect(!FileManager.default.fileExists(atPath: state.path))
        }
    }

    @Test func recoveryWaitsForAnExistingWriterThenRetries() throws {
        try withRecovery { state, lockURL, hardware, recovery in
            try writeLegacyLease(to: state)
            hardware.disabled = true
            let lock = try PowerStorage.lock(at: lockURL)
            #expect(throws: PowerError.self) { try recovery.restore() }
            #expect(recovery.status.recovery == .pending)
            #expect(hardware.disabled)
            try lock.close()
            try recovery.restore()
            #expect(!hardware.disabled)
            #expect(recovery.status.recovery == .restored)
        }
    }

    @Test func unreadableOrInvalidOwnershipIsPreservedWithoutWritingPowerSettings() throws {
        try withRecovery { state, _, hardware, recovery in
            hardware.disabled = true
            hardware.modes["b"] = true
            try Data("broken".utf8).write(to: state)
            #expect(throws: PowerError.self) { try recovery.restore() }
            #expect(recovery.status.recovery == .needsAttention)
            #expect(try Data(contentsOf: state) == Data("broken".utf8))

            for invalid in [["unexpected-source": false], ["b": true]] {
                try writeLegacyLease(to: state, previousLowPower: invalid)
                let bytes = try Data(contentsOf: state)
                #expect(throws: PowerError.self) { try recovery.restore() }
                #expect(recovery.status.recovery == .needsAttention)
                #expect(try Data(contentsOf: state) == bytes)
            }
            #expect(hardware.writes == 0)
        }
    }
}
