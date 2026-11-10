import Foundation

public enum RecoveryState: String, Codable, Sendable {
    case restored, pending, needsAttention
    public var title: String {
        switch self {
        case .restored: "Restored"
        case .pending: "Recovery pending"
        case .needsAttention: "Needs attention"
        }
    }
}

public struct PowerHelperStatus: Codable, Equatable, Sendable {
    public var protocolVersion = 2
    public var leaseActive: Bool
    public var externalWakeOwner: Bool
    public var recovery: RecoveryState
    public var detail: String?
    public var deadline: Date?
    public var leaseID: String?

    public init(leaseActive: Bool = false, externalWakeOwner: Bool = false,
                recovery: RecoveryState = .restored, detail: String? = nil, deadline: Date? = nil,
                leaseID: String? = nil) {
        self.leaseActive = leaseActive
        self.externalWakeOwner = externalWakeOwner
        self.recovery = recovery
        self.detail = detail
        self.deadline = deadline
        self.leaseID = leaseID
    }
}

public protocol PowerRecoveryHardware: AnyObject, Sendable {
    func restoreSleep(lock: FileHandle) throws
    func restoreLowPower(source: String, lock: FileHandle) throws
}

private struct PowerLeaseRecord: Codable {
    var leaseID: String
    var previousDisabled: Bool
    var changedByKith: Bool
    var expiresAt: Date
    // Keep the legacy schema when checkpointing partial recovery.
    var ownerUID: UInt32?
    var hardDeadline: Date?
    var previousLowPower: [String: Bool]?
    var lowPowerApplied: Bool?
    var lowPowerIgnored: [String]?
}

/// Only rolls back settings that older helpers recorded as Kith-owned.
public final class PowerPreferenceRecovery {
    private let stateURL: URL
    private let lockURL: URL
    private let hardware: any PowerRecoveryHardware
    public private(set) var status = PowerHelperStatus()

    public init(stateURL: URL, lockURL: URL, hardware: any PowerRecoveryHardware) {
        self.stateURL = stateURL
        self.lockURL = lockURL
        self.hardware = hardware
    }

    public func restore() throws {
        do {
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            if var saved = try load() {
                var failure: Error?
                if saved.changedByKith {
                    do { try hardware.restoreSleep(lock: lock) }
                    catch { failure = error }
                    if failure == nil {
                        saved.changedByKith = false
                        try PowerStorage.write(saved, to: stateURL)
                    }
                }
                for source in (saved.previousLowPower ?? [:]).keys.sorted() {
                    do { try hardware.restoreLowPower(source: source, lock: lock) }
                    catch {
                        if failure == nil { failure = error }
                        continue
                    }
                    saved.previousLowPower?.removeValue(forKey: source)
                    try PowerStorage.write(saved, to: stateURL)
                }
                if let failure { throw failure }
                try FileManager.default.removeItem(at: stateURL)
            }
            status = PowerHelperStatus()
        } catch {
            if status.recovery != .needsAttention {
                status = PowerHelperStatus(recovery: .pending, detail: error.localizedDescription)
            }
            throw error
        }
    }

    private func load() throws -> PowerLeaseRecord? {
        do {
            let saved = try PowerStorage.read(PowerLeaseRecord.self, from: stateURL)
            if let saved {
                guard UUID(uuidString: saved.leaseID) != nil,
                      !(saved.changedByKith && saved.previousDisabled),
                      (saved.previousLowPower ?? [:]).allSatisfy({ ["b", "c"].contains($0.key) && !$0.value }) else {
                    throw PowerError.invalid("Invalid legacy power ownership")
                }
            }
            status = PowerHelperStatus()
            return saved
        } catch {
            let message = "Saved power settings could not be read. Kith preserved the recovery file."
            status = PowerHelperStatus(recovery: .needsAttention, detail: message)
            throw PowerError.unavailable(message)
        }
    }
}
