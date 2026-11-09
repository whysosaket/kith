import Darwin
import Foundation

public enum PowerCommandKind: String, Codable, Sendable {
    case status, start, extend, end, resume
}

public struct PowerCommand: Codable, Sendable {
    public var id: UUID
    public var kind: PowerCommandKind
    public var seconds: TimeInterval?
    public var expiresAt: Date

    public init(kind: PowerCommandKind, seconds: TimeInterval? = nil, now: Date = Date()) {
        id = UUID(); self.kind = kind; self.seconds = seconds
        expiresAt = now.addingTimeInterval(8)
    }
}

public struct PowerControlStatus: Codable, Sendable {
    public var requested: Bool
    public var manual: Bool
    public var deadline: Date?
    public var stopped: WakeStop?
    public var conditions: PowerConditions
    public var helper: PowerHelperStatus
    public var idleHoldActive: Bool
    public var displayHoldActive: Bool
    public var networkWarning: Bool
    public var finishActionArmed: Bool

    public init(requested: Bool, manual: Bool, deadline: Date?, stopped: WakeStop?,
                conditions: PowerConditions, helper: PowerHelperStatus = PowerHelperStatus(),
                idleHoldActive: Bool = false, displayHoldActive: Bool = false,
                networkWarning: Bool = false, finishActionArmed: Bool = false) {
        self.requested = requested; self.manual = manual; self.deadline = deadline; self.stopped = stopped
        self.conditions = conditions; self.helper = helper
        self.idleHoldActive = idleHoldActive; self.displayHoldActive = displayHoldActive
        self.networkWarning = networkWarning; self.finishActionArmed = finishActionArmed
    }
}

public struct PowerCommandReply: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public var status: PowerControlStatus?

    public init(ok: Bool, message: String, status: PowerControlStatus? = nil) {
        self.ok = ok; self.message = message; self.status = status
    }
}

public enum PowerDuration {
    public static func parse(_ text: String) -> TimeInterval? {
        guard let suffix = text.last else { return nil }
        let multiplier: Double
        switch suffix {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        default: return nil
        }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Double(digits) else { return nil }
        let seconds = value * multiplier
        return seconds.isFinite && (1...86_400).contains(seconds) ? seconds : nil
    }
}

/// Only one app owns the inbox. Requests and acknowledgments have independent
/// names; a stale request is never executed after its caller has timed out.
public final class PowerCommandInbox {
    public let directory: URL
    private let ownership: FileHandle

    public init(directory: URL) throws {
        self.directory = directory
        try Self.prepare(directory)
        ownership = try PowerStorage.lock(at: directory.appendingPathComponent("server.lock"))
    }

    public func drain(now: Date = Date(), handle: (PowerCommand) -> PowerCommandReply) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.pathExtension == "request" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: id) else { continue }
            let claimed = directory.appendingPathComponent("\(id).claimed")
            guard rename(file.path, claimed.path) == 0 else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard let request = try? PowerStorage.read(PowerCommand.self, from: claimed),
                  request.id == uuid, request.expiresAt > now,
                  request.expiresAt <= now.addingTimeInterval(10) else { continue }
            let reply = handle(request)
            try? PowerStorage.write(reply, to: directory.appendingPathComponent("\(id).reply"))
        }
        for file in files where ["reply", "claimed"].contains(file.pathExtension) {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(date) > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    public static func send(_ command: PowerCommand, directory: URL) throws -> PowerCommandReply {
        try prepare(directory)
        let id = command.id.uuidString
        let request = directory.appendingPathComponent("\(id).request")
        let reply = directory.appendingPathComponent("\(id).reply")
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: reply) }
        try PowerStorage.write(command, to: request)
        while Date() < command.expiresAt {
            if let response = try PowerStorage.read(PowerCommandReply.self, from: reply) { return response }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw PowerError.unavailable("Kith did not acknowledge the request. Open Kith and check power status before retrying.")
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw PowerError.unavailable("The power control directory must be owned by your account") }
        guard chmod(directory.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
    }
}

public final class PowerSession {
    public private(set) var policy: PowerPolicy
    public private(set) var issue: String?
    private let stateURL: URL
    private var unreadableState = false

    public init(stateURL: URL) {
        self.stateURL = stateURL
        do { policy = try PowerStorage.read(PowerPolicy.self, from: stateURL) ?? PowerPolicy() }
        catch {
            policy = PowerPolicy(); policy.stop(.persistence)
            issue = "Awake state could not be read. Resume will archive it and start a new period."
            unreadableState = true
        }
    }

    public func update(now: Date, work: Bool, monitoringReady: Bool, automaticEnabled: Bool,
                       graceSeconds: TimeInterval, conditions: PowerConditions,
                       preferences: PowerPreferences, batteryChanged: Bool = false) -> PowerDecision {
        var next = policy
        if batteryChanged { next.observeBattery(conditions.battery) }
        let decision = next.evaluate(now: now, work: work, monitoringReady: monitoringReady,
            automaticEnabled: automaticEnabled, graceSeconds: graceSeconds, conditions: conditions, preferences: preferences)
        do {
            try commit(next)
            return decision
        } catch {
            policy.stop(.persistence)
            issue = error.localizedDescription
            var stopped = PowerDecision(); stopped.stop = .persistence
            return stopped
        }
    }

    public func apply(_ command: PowerCommand, now: Date, conditions: PowerConditions,
                      preferences: PowerPreferences) throws {
        guard command.expiresAt > now else { throw PowerError.invalid("Request expired") }
        var next = policy
        var archived: URL?
        switch command.kind {
        case .status: return
        case .start, .resume:
            if unreadableState {
                let archive = stateURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
                next = PowerPolicy()
                archived = archive
            }
            try next.start(seconds: command.seconds ?? preferences.maximumSeconds,
                           manual: command.kind == .start, now: now, conditions: conditions, preferences: preferences)
        case .extend:
            guard let seconds = command.seconds else { throw PowerError.invalid("Provide an extension duration") }
            if let reason = next.safetyStop(conditions: conditions, preferences: preferences) { throw PowerError.unavailable(reason.message) }
            try next.extend(seconds: seconds, now: now)
        case .end: next.stop(.user)
        }
        if let archived {
            try FileManager.default.moveItem(at: stateURL, to: archived)
            unreadableState = false
        }
        do { try commit(next) }
        catch {
            if let archived {
                try? FileManager.default.moveItem(at: archived, to: stateURL)
                unreadableState = true
            }
            throw error
        }
        issue = nil
    }

    private func commit(_ next: PowerPolicy) throws {
        guard next != policy || issue != nil else { return }
        guard !unreadableState else { throw PowerError.unavailable(issue ?? "Awake state is unreadable") }
        try PowerStorage.write(next, to: stateURL)
        policy = next
    }
}
