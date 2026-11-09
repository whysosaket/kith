import CryptoKit
import Foundation
import KithCore
import Security
import SystemConfiguration

private final class MacPowerHardware: PowerHardware, @unchecked Sendable {
    let commands = BoundedCommand()

    func sleepDisabled() throws -> Bool {
        let text = try run(["-g"])
        for line in text.split(separator: "\n") where line.contains("SleepDisabled") {
            if line.split(whereSeparator: \.isWhitespace).last == "1" { return true }
            if line.split(whereSeparator: \.isWhitespace).last == "0" { return false }
        }
        throw PowerError.unavailable("Cannot read SleepDisabled")
    }

    func lowPowerSettings() throws -> [String: Bool] {
        let text = try run(["-g", "custom"])
        var source: String?
        var settings: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            if line.contains("Battery Power:") { source = "b" }
            else if line.contains("AC Power:") { source = "c" }
            else if line.contains("Power:") { source = nil }
            else if let source {
                let words = line.split(whereSeparator: \.isWhitespace)
                if words.first == "lowpowermode", let value = words.last, ["0", "1"].contains(value) {
                    settings[source] = value == "1"
                }
            }
        }
        return settings
    }

    func setSleepDisabled(_ value: Bool, lock: FileHandle) throws {
        _ = try run(["-a", "disablesleep", value ? "1" : "0"], lock: lock)
    }

    func setLowPower(_ value: Bool, source: String, lock: FileHandle) throws {
        guard ["b", "c"].contains(source) else { throw PowerError.invalid("Invalid power source in recovery state") }
        _ = try run(["-" + source, "lowpowermode", value ? "1" : "0"], lock: lock)
    }

    private func run(_ arguments: [String], lock: FileHandle? = nil) throws -> String {
        let result = try commands.run("/usr/bin/pmset", arguments, inheritedLock: lock)
        guard result.status == 0 else { throw PowerError.unavailable("Power command failed (exit \(result.status))") }
        return result.output
    }
}

private struct XPCReply: @unchecked Sendable { let call: (Bool, String) -> Void }
private struct XPCDataReply: @unchecked Sendable { let call: (Data) -> Void }

private final class PowerController: @unchecked Sendable {
    let queue = DispatchQueue(label: "\(PowerService.name).state")
    let leases = PowerLeaseController(stateURL: URL(fileURLWithPath: "/var/db/kith-power-state.json"),
        lockURL: URL(fileURLWithPath: "/var/db/kith-power.lock"), hardware: MacPowerHardware())
    private var timer: DispatchSourceTimer?

    init() {
        queue.async { self.leases.recoverAfterRestart() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.leases.expireIfNeeded() }
        timer.resume()
        self.timer = timer
    }
}

private final class PowerConnection: NSObject, PowerServiceProtocol, @unchecked Sendable {
    let controller: PowerController
    let uid: UInt32
    init(controller: PowerController, uid: UInt32) { self.controller = controller; self.uid = uid }

    func status(withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        controller.queue.async {
            let status = self.controller.leases.status
            response.call(status.recovery == .restored, status.detail ?? "Power helper ready")
        }
    }

    func readStatus(withReply reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(call: reply)
        controller.queue.async { response.call((try? JSONEncoder().encode(self.controller.leases.status)) ?? Data()) }
    }

    func configure(leaseID: String, request: Data, withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) {
            guard request.count <= 4096 else { throw PowerError.invalid("Wake request is too large") }
            let configuration = try JSONDecoder().decode(PowerLeaseRequest.self, from: request)
            try self.controller.leases.configure(id: leaseID, uid: self.uid, request: configuration)
        }
    }

    // Legacy entry points retain the short lease behavior for an older app.
    func acquire(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) {
            try self.controller.leases.configure(id: leaseID, uid: self.uid,
                request: PowerLeaseRequest(deadline: Date().addingTimeInterval(45), closedLid: true, lowPower: false))
        }
    }
    func renew(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) { acquire(leaseID: leaseID, withReply: reply) }
    func release(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) { try self.controller.leases.release(id: leaseID, uid: self.uid) }
    }
    func retryRecovery(withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        controller.queue.async {
            self.controller.leases.retryRecovery()
            let status = self.controller.leases.status
            response.call(status.recovery == .restored, status.detail ?? "Recovery complete")
        }
    }
    func perform(action: String, withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) {
            guard ["sleep", "shutdown"].contains(action) else { throw PowerError.invalid("Unsupported action") }
            try self.controller.leases.prepareForFinishAction(uid: self.uid)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: action == "sleep" ? "/usr/bin/pmset" : "/sbin/shutdown")
            process.arguments = action == "sleep" ? ["sleepnow"] : ["-h", "now"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    }
    private func operation(_ reply: @escaping (Bool, String) -> Void, work: @escaping @Sendable () throws -> Void) {
        let response = XPCReply(call: reply)
        controller.queue.async {
            do { try work(); response.call(true, "Power request completed") }
            catch { response.call(false, error.localizedDescription) }
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let controller = PowerController()

    /// Only the Kith app signed like the helper may call it: by the same Apple team, or for local
    /// self-signed builds by the exact same certificate. XPC checks this against the caller's
    /// audit token, so a reused PID cannot pass. Ad hoc builds have no certificate and get no clients.
    private let clientRequirement: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              let info = signingInfo(code: code) else { return nil }
        let identifier = "identifier \"\(PowerService.clientIdentifier)\""
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return "\(identifier) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return "\(identifier) and certificate leaf = H\"\(digest.map { String(format: "%02x", $0) }.joined())\""
    }()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0, let clientRequirement else { return false }
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PowerServiceProtocol.self)
        connection.exportedObject = PowerConnection(controller: controller, uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private func signingInfo(code: SecCode) -> [String: Any]? {
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess else { return nil }
    return info as? [String: Any]
}

private let delegate = ListenerDelegate()
private let listener = NSXPCListener(machServiceName: PowerService.name)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
