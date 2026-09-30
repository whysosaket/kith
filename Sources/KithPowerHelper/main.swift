import CryptoKit
import Foundation
import KithCore
import Security
import SystemConfiguration

private struct SavedLease: Codable {
    var leaseID: String
    var previousDisabled: Bool
    var changedByKith: Bool
    var expiresAt: Date
}

private struct XPCReply: @unchecked Sendable {
    let call: (Bool, String) -> Void
}

private final class PowerController: NSObject, PowerServiceProtocol, @unchecked Sendable {
    private let stateURL = URL(fileURLWithPath: "/var/db/kith-power-state.json")
    private let queue = DispatchQueue(label: "\(PowerService.name).state")
    private var lease: SavedLease?

    override init() {
        super.init()
        recoverAfterRestart()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.expireIfNeeded() }
        timer.resume()
        self.timer = timer
    }

    private var timer: DispatchSourceTimer?

    func status(withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        queue.async {
            guard let disabled = self.sleepDisabled() else { response.call(false, "Cannot read SleepDisabled"); return }
            response.call(true, "SleepDisabled=\(disabled ? 1 : 0); lease=\(self.lease == nil ? "none" : "active")")
        }
    }

    func acquire(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        queue.async {
            guard UUID(uuidString: leaseID) != nil else { response.call(false, "Invalid lease ID"); return }
            if var existing = self.lease {
                guard existing.leaseID == leaseID else { response.call(false, "Another Kith lease is active"); return }
                existing.expiresAt = Date().addingTimeInterval(45)
                self.lease = existing
                response.call(self.save(existing), existing.changedByKith ? "Kith owns wake hold" : "External wake hold")
                return
            }
            guard let previous = self.sleepDisabled() else { response.call(false, "Cannot read SleepDisabled"); return }
            let changed = !previous
            let saved = SavedLease(leaseID: leaseID, previousDisabled: previous,
                changedByKith: changed, expiresAt: Date().addingTimeInterval(45))
            guard self.save(saved) else { response.call(false, "Cannot save wake lease"); return }
            self.lease = saved
            if changed && (!self.pmset(disableSleep: true) || self.sleepDisabled() != true) {
                _ = self.restore(saved)
                response.call(false, "Could not enable closed-lid wake")
                return
            }
            response.call(true, changed ? "Kith owns wake hold" : "External wake hold")
        }
    }

    func renew(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        queue.async {
            guard var lease = self.lease, lease.leaseID == leaseID else {
                response.call(false, "Lease not active"); return
            }
            lease.expiresAt = Date().addingTimeInterval(45)
            self.lease = lease
            response.call(self.save(lease), "Renewed")
        }
    }

    func release(leaseID: String, withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        queue.async {
            guard let lease = self.lease, lease.leaseID == leaseID else {
                response.call(false, "Lease not active"); return
            }
            response.call(self.restore(lease), "Released")
        }
    }

    func perform(action: String, withReply reply: @escaping (Bool, String) -> Void) {
        let response = XPCReply(call: reply)
        queue.async {
            guard action == "sleep" || action == "shutdown" else {
                response.call(false, "Unsupported action"); return
            }
            if let lease = self.lease, !self.restore(lease) {
                response.call(false, "Could not restore sleep setting"); return
            }
            let executable = action == "sleep" ? "/usr/bin/pmset" : "/sbin/shutdown"
            let arguments = action == "sleep" ? ["sleepnow"] : ["-h", "now"]
            let launched = self.launch(executable, arguments)
            response.call(launched, launched ? "Requested \(action)" : "Could not launch \(action)")
        }
    }

    private func expireIfNeeded() {
        guard let lease, Date() >= lease.expiresAt else { return }
        _ = restore(lease)
    }

    @discardableResult
    private func restore(_ lease: SavedLease) -> Bool {
        if lease.changedByKith {
            guard pmset(disableSleep: lease.previousDisabled),
                  sleepDisabled() == lease.previousDisabled else { return false }
        }
        self.lease = nil
        try? FileManager.default.removeItem(at: stateURL)
        return true
    }

    private func recoverAfterRestart() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(SavedLease.self, from: data) else { return }
        lease = saved
        _ = restore(saved)
    }

    @discardableResult
    private func save(_ lease: SavedLease) -> Bool {
        do {
            let data = try JSONEncoder().encode(lease)
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path)
            return true
        } catch { return false }
    }

    private func sleepDisabled() -> Bool? {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            if line.split(whereSeparator: \.isWhitespace).last == "1" { return true }
            if line.split(whereSeparator: \.isWhitespace).last == "0" { return false }
        }
        return nil
    }

    private func pmset(disableSleep: Bool) -> Bool {
        run("/usr/bin/pmset", ["-a", "disablesleep", disableSleep ? "1" : "0"]) != nil
    }

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    private func launch(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true }
        catch { return false }
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
        connection.exportedObject = controller
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
