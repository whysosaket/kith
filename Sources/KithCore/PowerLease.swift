import Foundation

public struct PowerLeaseRequest: Codable, Equatable, Sendable {
    public var deadline: Date
    public var closedLid: Bool
    public var lowPower: Bool

    public init(deadline: Date, closedLid: Bool, lowPower: Bool) {
        self.deadline = deadline
        self.closedLid = closedLid
        self.lowPower = lowPower
    }
}

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

    public init(leaseActive: Bool = false, externalWakeOwner: Bool = false,
                recovery: RecoveryState = .restored, detail: String? = nil, deadline: Date? = nil) {
        self.leaseActive = leaseActive
        self.externalWakeOwner = externalWakeOwner
        self.recovery = recovery
        self.detail = detail
        self.deadline = deadline
    }
}

public protocol PowerHardware: AnyObject, Sendable {
    func sleepDisabled() throws -> Bool
    func lowPowerSettings() throws -> [String: Bool]
    func setSleepDisabled(_ value: Bool, lock: FileHandle) throws
    func setLowPower(_ value: Bool, source: String, lock: FileHandle) throws
}

private struct PowerLeaseRecord: Codable {
    var leaseID: String
    var previousDisabled: Bool
    var changedByKith: Bool
    var expiresAt: Date
    // Optional fields allow recovery of leases written by earlier app versions.
    var ownerUID: UInt32?
    var hardDeadline: Date?
    var previousLowPower: [String: Bool]?
    var lowPowerApplied: Bool?
    var lowPowerIgnored: [String]?
}

/// The helper serializes calls to this controller. The file lock also covers
/// another helper instance and any command surviving its parent process.
public final class PowerLeaseController: @unchecked Sendable {
    private let stateURL: URL
    private let lockURL: URL
    private let hardware: any PowerHardware
    private let now: @Sendable () -> Date
    private var lease: PowerLeaseRecord?
    private var issue: String?
    private var unreadable = false

    public init(stateURL: URL, lockURL: URL, hardware: any PowerHardware,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.stateURL = stateURL
        self.lockURL = lockURL
        self.hardware = hardware
        self.now = now
    }

    public var status: PowerHelperStatus {
        PowerHelperStatus(leaseActive: lease != nil && issue == nil,
                          externalWakeOwner: lease.map { $0.previousDisabled && !$0.changedByKith } ?? false,
                          recovery: unreadable ? .needsAttention : issue == nil ? .restored : .pending,
                          detail: issue, deadline: lease?.hardDeadline)
    }

    public func recoverAfterRestart() {
        perform {
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            try load()
            if lease != nil { try restore(lock: lock) }
        }
    }

    public func configure(id: String, uid: UInt32, request: PowerLeaseRequest) throws {
        try checked {
            guard UUID(uuidString: id) != nil, request.deadline > now(),
                  request.deadline <= now().addingTimeInterval(86_400) else {
                throw PowerError.invalid("Invalid wake lease or deadline")
            }
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            try load()
            if let lease, lease.leaseID != id || lease.ownerUID != uid {
                throw PowerError.invalid("Another wake lease is active; wait for its recovery")
            }
            if let lease, lease.expiresAt <= now() || (lease.hardDeadline ?? lease.expiresAt) <= now() {
                try restore(lock: lock)
                throw PowerError.unavailable("Wake lease expired; explicitly resume awake protection")
            }
            var saved = try lease ?? PowerLeaseRecord(
                leaseID: id, previousDisabled: hardware.sleepDisabled(), changedByKith: false,
                expiresAt: now(), ownerUID: uid, hardDeadline: request.deadline)
            saved.expiresAt = min(now().addingTimeInterval(45), request.deadline)
            saved.hardDeadline = request.deadline
            if request.closedLid && !saved.changedByKith {
                saved.previousDisabled = try hardware.sleepDisabled()
                saved.changedByKith = !saved.previousDisabled
            }
            if request.lowPower, saved.lowPowerApplied == true, var owned = saved.previousLowPower {
                let current = try hardware.lowPowerSettings()
                for source in owned.keys where current[source] == false {
                    owned.removeValue(forKey: source)
                    saved.lowPowerIgnored = Array(Set((saved.lowPowerIgnored ?? []) + [source]))
                }
                saved.previousLowPower = owned.isEmpty ? nil : owned
            }
            if request.lowPower && saved.lowPowerApplied != true && saved.previousLowPower == nil {
                let previous = try hardware.lowPowerSettings()
                guard !previous.isEmpty else { throw PowerError.unavailable("Low Power Mode is not available on this Mac") }
                saved.lowPowerIgnored = Array(Set((saved.lowPowerIgnored ?? []) + previous.filter(\.value).map(\.key)))
                let ignored = Set(saved.lowPowerIgnored ?? [])
                let changed = previous.filter { !$0.value && !ignored.contains($0.key) }
                if !changed.isEmpty { saved.previousLowPower = changed }
            }
            // Publish intent before either system preference can change.
            try PowerStorage.write(saved, to: stateURL)
            lease = saved
            if request.closedLid && saved.changedByKith {
                try hardware.setSleepDisabled(true, lock: lock)
                guard try hardware.sleepDisabled() else { throw PowerError.unavailable("Closed-lid wake could not be verified") }
            } else if !request.closedLid && saved.changedByKith {
                try hardware.setSleepDisabled(saved.previousDisabled, lock: lock)
                guard try hardware.sleepDisabled() == saved.previousDisabled else { throw PowerError.unavailable("Sleep restoration could not be verified") }
                saved.changedByKith = false
            }
            if request.lowPower, let previous = saved.previousLowPower {
                for source in previous.keys.sorted() {
                    try hardware.setLowPower(true, source: source, lock: lock)
                    guard try hardware.lowPowerSettings()[source] == true else { throw PowerError.unavailable("Low Power Mode could not be verified") }
                }
            } else if !request.lowPower, let previous = saved.previousLowPower {
                for (source, value) in previous {
                    try hardware.setLowPower(value, source: source, lock: lock)
                    guard try hardware.lowPowerSettings()[source] == value else { throw PowerError.unavailable("Low Power Mode restoration could not be verified") }
                }
                saved.previousLowPower = nil
            }
            saved.lowPowerApplied = request.lowPower
            try PowerStorage.write(saved, to: stateURL)
            lease = saved
        }
    }

    public func release(id: String, uid: UInt32) throws {
        try checked {
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            try load()
            guard let lease else { return }
            guard lease.leaseID == id, lease.ownerUID == uid else { throw PowerError.invalid("Wake lease is owned by another client") }
            try restore(lock: lock)
        }
    }

    public func expireIfNeeded() {
        guard issue != nil || lease.map({ $0.expiresAt <= now() || ($0.hardDeadline ?? $0.expiresAt) <= now() }) == true else { return }
        retryRecovery()
    }

    public func prepareForFinishAction(uid: UInt32) throws {
        try checked {
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            try load()
            if let lease {
                guard lease.ownerUID == uid else { throw PowerError.invalid("Another account owns the wake lease") }
                try restore(lock: lock)
            }
        }
    }

    public func retryRecovery() {
        perform {
            let lock = try PowerStorage.lock(at: lockURL)
            defer { try? lock.close() }
            try load()
            if let lease, issue != nil || lease.expiresAt <= now() || (lease.hardDeadline ?? lease.expiresAt) <= now() {
                try restore(lock: lock)
            }
        }
    }

    private func load() throws {
        do {
            lease = try PowerStorage.read(PowerLeaseRecord.self, from: stateURL)
            if let lease {
                let sources = Set(lease.previousLowPower?.keys.map { $0 } ?? [])
                guard UUID(uuidString: lease.leaseID) != nil,
                      !(lease.changedByKith && lease.previousDisabled),
                      sources.isSubset(of: Set(["b", "c"])) else {
                    throw PowerError.invalid("Recovery state has invalid ownership or power-source fields")
                }
            }
            unreadable = false
        } catch {
            unreadable = true
            throw PowerError.unavailable("Recovery state could not be read; the file has been preserved")
        }
    }

    private func restore(lock: FileHandle) throws {
        guard let saved = lease else { return }
        if saved.changedByKith {
            try hardware.setSleepDisabled(saved.previousDisabled, lock: lock)
            guard try hardware.sleepDisabled() == saved.previousDisabled else { throw PowerError.unavailable("Sleep restoration could not be verified") }
        }
        if let previous = saved.previousLowPower {
            for (source, value) in previous {
                try hardware.setLowPower(value, source: source, lock: lock)
                guard try hardware.lowPowerSettings()[source] == value else { throw PowerError.unavailable("Low Power Mode restoration could not be verified") }
            }
        }
        try FileManager.default.removeItem(at: stateURL)
        lease = nil
    }

    private func checked(_ operation: () throws -> Void) throws {
        do { try operation(); issue = nil }
        catch {
            if case PowerError.invalid = error { throw error }
            issue = error.localizedDescription
            throw error
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try checked(operation) } catch { /* Status retains the recovery failure. */ }
    }
}
