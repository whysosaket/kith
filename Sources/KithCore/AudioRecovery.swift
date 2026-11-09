import Foundation

public struct AudioOutput: Equatable, Sendable {
    public var uid: String
    public var name: String
    public init(uid: String, name: String) { self.uid = uid; self.name = name }
}

public struct SavedAudioMute: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var uid: String
    public var name: String
}

public protocol AudioHardware: AnyObject {
    func outputs() throws -> [AudioOutput]
    func defaultOutput() throws -> AudioOutput?
    func isMuted(uid: String) throws -> Bool
    func setMuted(_ muted: Bool, uid: String) throws
}

public final class AudioRecovery {
    public private(set) var pending: [SavedAudioMute] = []
    public private(set) var issue: String?
    private let hardware: any AudioHardware
    private let stateURL: URL
    private var unreadable = false

    public init(hardware: any AudioHardware, stateURL: URL) {
        self.hardware = hardware; self.stateURL = stateURL
        do { pending = try PowerStorage.read([SavedAudioMute].self, from: stateURL) ?? [] }
        catch { unreadable = true; issue = "Audio recovery state is unreadable; the file has been preserved" }
    }

    public func muteDefaultOutput() {
        guard !unreadable else { return }
        do {
            guard let output = try hardware.defaultOutput(), !pending.contains(where: { $0.uid == output.uid }),
                  try !hardware.isMuted(uid: output.uid) else { return }
            let saved = SavedAudioMute(id: UUID(), uid: output.uid, name: output.name)
            let next = pending + [saved]
            try PowerStorage.write(next, to: stateURL)
            pending = next
            try hardware.setMuted(true, uid: output.uid)
            guard try hardware.isMuted(uid: output.uid) else { throw PowerError.unavailable("Audio mute could not be verified") }
            issue = nil
        } catch { issue = error.localizedDescription }
    }

    public func restore() {
        guard !unreadable else { return }
        guard !pending.isEmpty else { issue = nil; return }
        do {
            let connected = Set(try hardware.outputs().map(\.uid))
            var remaining = pending
            var failures: [String] = []
            for saved in pending where connected.contains(saved.uid) {
                do {
                    if try hardware.isMuted(uid: saved.uid) { try hardware.setMuted(false, uid: saved.uid) }
                    guard try !hardware.isMuted(uid: saved.uid) else { throw PowerError.unavailable("Audio is still muted") }
                    remaining.removeAll { $0.id == saved.id }
                } catch { failures.append("Could not restore \(saved.name)") }
            }
            if remaining != pending {
                try PowerStorage.write(remaining, to: stateURL)
                pending = remaining
            }
            issue = failures.isEmpty ? nil : failures.joined(separator: "; ")
        } catch { issue = error.localizedDescription }
    }

    public func stopWaiting(id: UUID) throws {
        let connected = Set(try hardware.outputs().map(\.uid))
        guard let saved = pending.first(where: { $0.id == id }), !connected.contains(saved.uid) else {
            throw PowerError.invalid("Only a disconnected output can be removed from recovery")
        }
        let next = pending.filter { $0.id != id }
        try PowerStorage.write(next, to: stateURL)
        pending = next
    }
}
