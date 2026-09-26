import Foundation
import IOKit.pwr_mgt
import KithCore
import ServiceManagement

@MainActor
private final class ReplyGate {
    private var finished = false
    private let completion: (Bool, String) -> Void

    init(_ completion: @escaping (Bool, String) -> Void) { self.completion = completion }

    func finish(_ success: Bool, _ message: String) {
        guard !finished else { return }
        finished = true
        completion(success, message)
    }
}

@MainActor
final class PowerClient {
    private var assertionID: IOPMAssertionID?
    private var connection: NSXPCConnection?
    private let leaseID = UUID().uuidString
    private var leaseActive = false
    private var requestInFlight = false
    private var lastRenewal = Date.distantPast
    private(set) var externalWakeOwner = false

    var helperEnabled: Bool {
        SMAppService.daemon(plistName: PowerService.plistName).status == .enabled
    }
    var closedLidReady: Bool { leaseActive }

    func registerHelper() throws {
        let service = SMAppService.daemon(plistName: PowerService.plistName)
        if service.status != .enabled { try service.register() }
    }

    func unregisterHelper(completion: @escaping (Error?) -> Void) {
        let unregister = {
            do {
                let service = SMAppService.daemon(plistName: PowerService.plistName)
                if service.status == .enabled { try service.unregister() }
                completion(nil)
            } catch { completion(error) }
        }
        if leaseActive {
            call({ proxy, reply in proxy.release(leaseID: self.leaseID, withReply: reply) }) {
                success, message in
                guard success else {
                    completion(NSError(domain: "KithPower", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]))
                    return
                }
                self.leaseActive = false
                unregister()
            }
        } else { unregister() }
    }

    @discardableResult
    func holdIdleSleep(_ shouldHold: Bool) -> Bool {
        if shouldHold && assertionID == nil {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithDescription(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                "Kith active coding agents" as CFString,
                "Monitoring local coding sessions" as CFString,
                "Coding agents are working" as CFString,
                nil, 0, nil, &id)
            if status == kIOReturnSuccess { assertionID = id }
            else { return false }
        } else if !shouldHold, let assertionID {
            IOPMAssertionRelease(assertionID)
            self.assertionID = nil
        }
        return true
    }

    func holdClosedLid(_ shouldHold: Bool, report: @escaping (String?) -> Void) {
        guard helperEnabled else {
            if shouldHold { report("Closed-lid helper is not enabled") }
            return
        }
        guard !requestInFlight else { return }
        if shouldHold {
            if leaseActive && Date().timeIntervalSince(lastRenewal) < 10 { return }
            requestInFlight = true
            call { proxy, reply in
                if self.leaseActive { proxy.renew(leaseID: self.leaseID, withReply: reply) }
                else { proxy.acquire(leaseID: self.leaseID, withReply: reply) }
            } completion: { success, message in
                self.requestInFlight = false
                self.leaseActive = success
                if success {
                    self.lastRenewal = Date()
                    self.externalWakeOwner = message == "External wake hold"
                }
                else { report(message) }
            }
        } else if leaseActive {
            requestInFlight = true
            call { proxy, reply in
                proxy.release(leaseID: self.leaseID, withReply: reply)
            } completion: { success, message in
                self.requestInFlight = false
                if success {
                    self.leaseActive = false
                    self.externalWakeOwner = false
                }
                else { report(message) }
            }
        }
    }

    func perform(_ action: String, completion: @escaping (Bool, String) -> Void) {
        holdIdleSleep(false)
        call({ proxy, reply in proxy.perform(action: action, withReply: reply) },
             completion: completion)
    }

    func checkHelper(completion: @escaping (Bool, String) -> Void) {
        call({ proxy, reply in proxy.status(withReply: reply) }, completion: completion)
    }

    private func call(
        _ invoke: @escaping (PowerServiceProtocol, @escaping (Bool, String) -> Void) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        let gate = ReplyGate(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            gate.finish(false, "Power helper timed out")
        }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: PowerService.name, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerServiceProtocol.self)
            connection.resume()
            self.connection = connection
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in gate.finish(false, error.localizedDescription) }
        }) as? PowerServiceProtocol else {
            gate.finish(false, "Power helper unavailable")
            return
        }
        invoke(proxy) { success, message in
            Task { @MainActor in gate.finish(success, message) }
        }
    }
}
