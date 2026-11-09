import Foundation
import Testing
@testable import KithCore

final class FakeAudioHardware: AudioHardware {
    var connected = [AudioOutput(uid: "speaker", name: "Speakers"), AudioOutput(uid: "headset", name: "Headphones")]
    var current = "speaker"
    var muted = ["speaker": false, "headset": false]
    var failure = false
    var unreadable = false
    var onSet: ((Bool, String) throws -> Void)?
    func outputs() throws -> [AudioOutput] { connected }
    func defaultOutput() throws -> AudioOutput? { connected.first { $0.uid == current } }
    func isMuted(uid: String) throws -> Bool {
        if unreadable { throw PowerError.unavailable("Output has no software mute control") }
        return muted[uid] ?? false
    }
    func setMuted(_ muted: Bool, uid: String) throws {
        if failure { throw PowerError.unavailable("Output refused mute") }
        self.muted[uid] = muted
        try onSet?(muted, uid)
    }
}

struct PowerWorkflowTests {
    @Test func failedJournalClearDoesNotOverwriteLaterUserMute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state")
        let hardware = FakeAudioHardware()
        let audio = AudioRecovery(hardware: hardware, stateURL: file)
        audio.muteDefaultOutput()
        let saved = audio.pending
        hardware.onSet = { muted, _ in
            if !muted {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
        }
        audio.restore()
        #expect(hardware.muted["speaker"] == false)
        #expect(audio.issue != nil && !audio.pending.isEmpty)
        hardware.onSet = nil
        try FileManager.default.removeItem(at: file)
        try PowerStorage.write(saved, to: file)
        hardware.muted["speaker"] = true
        audio.restore()
        #expect(hardware.muted["speaker"] == true)
        #expect(audio.pending.isEmpty)
        #expect(audio.issue == nil)
    }

    @Test func unsupportedAudioDoesNotLeaveFalseRecoveryWork() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hardware = FakeAudioHardware()
        hardware.unreadable = true
        let audio = AudioRecovery(hardware: hardware, stateURL: directory.appendingPathComponent("state"))
        audio.muteDefaultOutput()
        #expect(audio.issue != nil)
        #expect(audio.pending.isEmpty)
        audio.restore()
        #expect(audio.issue == nil)
        #expect(hardware.muted["speaker"] == false)
    }

    @Test func networkWarningsDebounceAndNeverClaimAgentCompletion() {
        var state = ConnectivityState()
        let now = Date()
        #expect(state.update(available: false, active: true, now: now) == nil)
        #expect(state.update(available: true, active: true, now: now.addingTimeInterval(3)) == nil)
        #expect(!state.warning)
        #expect(state.update(available: false, active: true, now: now.addingTimeInterval(4)) == nil)
        #expect(state.update(available: false, active: true, now: now.addingTimeInterval(10)) == .lost)
        #expect(state.warning)
        #expect(state.update(available: false, active: true, now: now.addingTimeInterval(11)) == nil)
        #expect(state.update(available: true, active: true, now: now.addingTimeInterval(14)) == .restored(seconds: 10))
        #expect(!state.warning)
        #expect(state.update(available: false, active: false, now: now.addingTimeInterval(20)) == nil)
        #expect(state.update(available: false, active: true, now: now.addingTimeInterval(21)) == nil)
    }

    @Test func audioRestoresOriginalDevicesAcrossSwitchAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let hardware = FakeAudioHardware()
        let audio = AudioRecovery(hardware: hardware, stateURL: file)
        audio.muteDefaultOutput()
        hardware.current = "headset"
        audio.muteDefaultOutput()
        #expect(hardware.muted.values.allSatisfy { $0 })
        hardware.connected.removeAll { $0.uid == "headset" }
        let restarted = AudioRecovery(hardware: hardware, stateURL: file)
        restarted.restore()
        #expect(hardware.muted["speaker"] == false)
        #expect(restarted.pending.map(\.uid) == ["headset"])
        hardware.connected.append(AudioOutput(uid: "headset", name: "Headphones"))
        restarted.restore()
        #expect(hardware.muted["headset"] == false)
        #expect(restarted.pending.isEmpty)
    }

    @Test func audioRespectsUserUnmuteAndRequiresDisconnectedDeviceToForget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hardware = FakeAudioHardware()
        let audio = AudioRecovery(hardware: hardware, stateURL: directory.appendingPathComponent("state"))
        audio.muteDefaultOutput()
        let saved = try #require(audio.pending.first)
        #expect(throws: PowerError.self) { try audio.stopWaiting(id: saved.id) }
        hardware.muted["speaker"] = false
        audio.muteDefaultOutput()
        #expect(hardware.muted["speaker"] == false)
        audio.restore()
        #expect(audio.pending.isEmpty)
        hardware.current = "headset"
        audio.muteDefaultOutput()
        let headset = try #require(audio.pending.first)
        hardware.connected.removeAll { $0.uid == "headset" }
        try audio.stopWaiting(id: headset.id)
        #expect(audio.pending.isEmpty)
        #expect(hardware.muted["headset"] == true)
    }

    @Test func failedAudioRestorationKeepsJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kith-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hardware = FakeAudioHardware()
        let audio = AudioRecovery(hardware: hardware, stateURL: directory.appendingPathComponent("state"))
        audio.muteDefaultOutput()
        hardware.failure = true
        audio.restore()
        #expect(audio.issue != nil)
        #expect(audio.pending.count == 1)
        hardware.failure = false
        audio.restore()
        #expect(audio.pending.isEmpty)
        #expect(audio.issue == nil)
    }
}
