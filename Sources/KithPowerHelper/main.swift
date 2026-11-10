import CryptoKit
import Foundation
import KithCore
import Security

private final class MacPowerHardware: PowerRecoveryHardware {
    let commands = BoundedCommand()

    private func sleepDisabled() throws -> Bool {
        let text = try run(["-g"])
        guard text.contains("Currently in use:") || text.contains("System-wide power settings:") else {
            throw PowerError.unavailable("Cannot read system-wide power settings")
        }
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.first == "SleepDisabled" else { continue }
            if words.last == "1" { return true }
            if words.last == "0" { return false }
            throw PowerError.unavailable("Cannot read SleepDisabled")
        }
        // pmset omits this preference when macOS uses the default.
        return false
    }

    private func lowPowerEnabled(source: String) throws -> Bool {
        let text = try run(["-g", "custom"])
        let heading = source == "b" ? "Battery Power:" : "AC Power:"
        var readingSource = false
        for line in text.split(separator: "\n") {
            if line.hasSuffix("Power:") { readingSource = line == heading }
            guard readingSource else { continue }
            let words = line.split(whereSeparator: \.isWhitespace)
            if words.first == "lowpowermode" || words.first == "powermode",
               words.count == 2, let mode = Int(words[1]), mode >= 0 {
                return mode == 1
            }
        }
        throw PowerError.unavailable("Cannot read the saved Low Power Mode setting")
    }

    func restoreSleep(lock: FileHandle) throws {
        guard try sleepDisabled() else { return }
        _ = try run(["-a", "disablesleep", "0"], lock: lock)
        guard try !sleepDisabled() else { throw PowerError.unavailable("Sleep restoration could not be verified") }
    }

    func restoreLowPower(source: String, lock: FileHandle) throws {
        guard try lowPowerEnabled(source: source) else { return }
        _ = try run(["-" + source, "lowpowermode", "0"], lock: lock)
        guard try !lowPowerEnabled(source: source) else { throw PowerError.unavailable("Low Power Mode restoration could not be verified") }
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
    let recovery = PowerPreferenceRecovery(stateURL: PowerService.recoveryStateURL,
        lockURL: URL(fileURLWithPath: "/var/db/kith-power.lock"), hardware: MacPowerHardware())
    private var timer: DispatchSourceTimer?

    init() {
        queue.async { try? self.recovery.restore() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.recovery.status.recovery != .restored else { return }
            try? self.recovery.restore()
        }
        timer.resume()
        self.timer = timer
    }
}

private final class PowerConnection: NSObject, PowerServiceProtocol, @unchecked Sendable {
    let controller: PowerController
    init(controller: PowerController) { self.controller = controller }

    func status(withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        controller.queue.async {
            let status = self.controller.recovery.status
            response.call(status.recovery == .restored, status.detail ?? "Power helper ready")
        }
    }

    func readStatus(withReply reply: @escaping (Data) -> Void) {
        let response = XPCDataReply(call: reply)
        controller.queue.async { response.call((try? JSONEncoder().encode(self.controller.recovery.status)) ?? Data()) }
    }

    func configure(leaseID: String, request: Data, withReply reply: @escaping (Bool, String) -> Void) {
        acquire(leaseID: leaseID, withReply: reply)
    }

    // Keep these selectors for older apps, but reject requests to change preferences.
    func acquire(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        reply(false, "Update Kith. This power helper only restores settings from older versions.")
    }
    func renew(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) { acquire(leaseID: leaseID, withReply: reply) }
    func release(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        retryRecovery(withReply: reply)
    }
    func retryRecovery(withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) { try self.controller.recovery.restore() }
    }
    func perform(action: String, withReply reply: @escaping (Bool, String) -> Void) {
        operation(reply) {
            guard ["sleep", "shutdown"].contains(action) else { throw PowerError.invalid("Unsupported action") }
            try self.controller.recovery.restore()
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
        connection.exportedObject = PowerConnection(controller: controller)
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
