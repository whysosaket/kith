import Foundation

public enum BatteryReading: Codable, Equatable, Sendable {
    case absent
    case percent(Int)
    case unreadable
}

public enum HeatLevel: Int, Codable, Sendable {
    case nominal, fair, serious, critical
}

public struct PowerConditions: Codable, Equatable, Sendable {
    public var battery: BatteryReading
    public var onAC: Bool
    public var heat: HeatLevel
    public var lidClosed: Bool

    public init(battery: BatteryReading = .absent, onAC: Bool = true,
                heat: HeatLevel = .nominal, lidClosed: Bool = false) {
        self.battery = battery
        self.onAC = onAC
        self.heat = heat
        self.lidClosed = lidClosed
    }
}

public struct PowerPreferences: Codable, Equatable, Sendable {
    public var maximumSeconds: TimeInterval = 14_400
    public var batteryWarning = 20
    public var batteryFloor = 10
    public var keepDisplayAwake = false
    public var muteWithLidClosed = false
    public var networkAlerts = true
    public var browserDiagnostics = true

    public init() {}

    public func validated() throws -> Self {
        guard maximumSeconds.isFinite, (60...86_400).contains(maximumSeconds),
              (1...30).contains(batteryFloor),
              (batteryFloor...100).contains(batteryWarning) else {
            throw PowerError.invalid("Power settings contain an invalid duration or battery threshold")
        }
        return self
    }
}

public enum WakeStop: String, Codable, Sendable {
    case user, deadline, battery, batteryUnreadable, heat, persistence

    public var message: String {
        switch self {
        case .user: "Awake protection ended"
        case .deadline: "Maximum awake time reached"
        case .battery: "Awake protection stopped for low battery"
        case .batteryUnreadable: "Awake protection stopped because battery level is unavailable"
        case .heat: "Awake protection stopped for critical heat"
        case .persistence: "Awake protection stopped because its state could not be saved"
        }
    }
}

public struct WakePeriod: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var deadline: Date
    public var manual: Bool
}

public struct PowerDecision: Equatable, Sendable {
    public var hold = false
    public var display = false
    public var reminder = false
    public var stop: WakeStop?
}

public enum PowerError: Error, LocalizedError {
    case invalid(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        }
    }
}

/// One wake period spans agent turns and the grace period. Only an explicit
/// start, resume or extension can move its upper limit.
public struct PowerPolicy: Codable, Equatable, Sendable {
    public private(set) var period: WakePeriod?
    public private(set) var stopped: WakeStop?
    private var previousWork = false
    private var workEndedAt: Date?
    private var remindedDeadline: Date?
    private var unreadableBatteryReads = 0

    public init() {}

    public mutating func observeBattery(_ battery: BatteryReading) {
        if battery == .unreadable { unreadableBatteryReads = min(2, unreadableBatteryReads + 1) }
        else { unreadableBatteryReads = 0 }
    }

    public func safetyStop(conditions: PowerConditions, preferences: PowerPreferences) -> WakeStop? {
        if conditions.heat == .critical { return .heat }
        if !conditions.onAC {
            if case .percent(let percent) = conditions.battery, percent <= preferences.batteryFloor { return .battery }
            if conditions.battery == .unreadable, unreadableBatteryReads >= 2 { return .batteryUnreadable }
        }
        return nil
    }

    public mutating func start(seconds: TimeInterval, manual: Bool, now: Date,
                               conditions: PowerConditions, preferences: PowerPreferences) throws {
        guard seconds.isFinite, (1...86_400).contains(seconds) else {
            throw PowerError.invalid("Duration must be between 1 second and 24 hours")
        }
        // A manual resume must not run blind even during the first failed battery read.
        if !conditions.onAC, conditions.battery == .unreadable {
            throw PowerError.unavailable(WakeStop.batteryUnreadable.message)
        }
        if let reason = safetyStop(conditions: conditions, preferences: preferences) {
            throw PowerError.unavailable(reason.message)
        }
        period = WakePeriod(id: UUID(), startedAt: now, deadline: now.addingTimeInterval(seconds), manual: manual)
        stopped = nil
        remindedDeadline = nil
    }

    public mutating func extend(seconds: TimeInterval, now: Date) throws {
        guard stopped == nil, var period, period.deadline > now else {
            throw PowerError.invalid("No active wake period; start or resume awake protection")
        }
        guard seconds.isFinite, seconds > 0, period.deadline.addingTimeInterval(seconds) <= now.addingTimeInterval(86_400) else {
            throw PowerError.invalid("An extension must leave at most 24 hours remaining")
        }
        period.deadline = period.deadline.addingTimeInterval(seconds)
        self.period = period
        remindedDeadline = nil
    }

    public mutating func stop(_ reason: WakeStop) { stopped = reason }

    public mutating func evaluate(now: Date, work: Bool, monitoringReady: Bool,
                                  automaticEnabled: Bool, graceSeconds: TimeInterval,
                                  conditions: PowerConditions, preferences: PowerPreferences) -> PowerDecision {
        if monitoringReady {
            if previousWork && !work { workEndedAt = now }
            if work { workEndedAt = nil }
            previousWork = work
        }
        let grace = workEndedAt.map { now.timeIntervalSince($0) < graceSeconds } ?? false
        let automatic = automaticEnabled && (work || grace)
        let requested = automatic || period?.manual == true
        if requested, stopped == nil, let reason = safetyStop(conditions: conditions, preferences: preferences) {
            stopped = reason
        }
        if let period, stopped == nil, now >= period.deadline { stopped = .deadline }
        if stopped == nil, period == nil, automatic {
            try? start(seconds: preferences.maximumSeconds, manual: false, now: now,
                       conditions: conditions, preferences: preferences)
        }
        if monitoringReady, !requested, stopped == nil { period = nil; remindedDeadline = nil }
        var decision = PowerDecision()
        decision.stop = stopped
        guard stopped == nil, let period, requested, now < period.deadline else { return decision }
        decision.hold = true
        decision.display = preferences.keepDisplayAwake
        if period.deadline.timeIntervalSince(now) <= 300, remindedDeadline != period.deadline {
            decision.reminder = true
            remindedDeadline = period.deadline
        }
        return decision
    }
}
