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
    var idleHoldActive: Bool { assertionID != nil }
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
            let renewing = leaseActive
            call { proxy, reply in
                if renewing { proxy.renew(leaseID: self.leaseID, withReply: reply) }
                else { proxy.acquire(leaseID: self.leaseID, withReply: reply) }
            } completion: { success, message in
                self.requestInFlight = false
                self.leaseActive = success
                if success {
                    self.lastRenewal = Date()
                    if !renewing { self.externalWakeOwner = message == "External wake hold" }
                }
                // A lapsed lease, such as after a helper restart, is acquired again on the next tick.
                else if !renewing { report(message) }
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
            // An invalidated connection never recovers, so drop it and reconnect on the next call.
            let identity = ObjectIdentifier(connection)
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in
                    if let self, self.connection.map(ObjectIdentifier.init) == identity { self.connection = nil }
                }
            }
            connection.resume()
            self.connection = connection
        }
        // XPC runs these on its own queue, so they must not inherit main-actor isolation.
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable error in
            Task { @MainActor in gate.finish(false, error.localizedDescription) }
        }) as? PowerServiceProtocol else {
            gate.finish(false, "Power helper unavailable")
            return
        }
        invoke(proxy) { @Sendable success, message in
            Task { @MainActor in gate.finish(success, message) }
        }
    }
}
