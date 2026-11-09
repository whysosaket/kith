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

private struct HelperCallback: @unchecked Sendable { let call: (Bool, String) -> Void }

@MainActor
final class PowerClient {
    private var assertionID: IOPMAssertionID?
    private var connection: NSXPCConnection?
    private var activeLeaseID: String?
    private var desiredLeaseID: String?
    private var desiredRequest: PowerLeaseRequest?
    private var lastRequest: PowerLeaseRequest?
    private var requestInFlight = false
    private var lastRenewal = Date.distantPast
    private var displayAssertionID: IOPMAssertionID?
    private var simulatedIdle = false
    private var simulatedDisplay = false
    private(set) var helperStatus = PowerHelperStatus()
    var onError: ((String) -> Void)?
    var externalWakeOwner: Bool { helperStatus.externalWakeOwner }

    var helperEnabled: Bool {
        !KithTesting.enabled && SMAppService.daemon(plistName: PowerService.plistName).status == .enabled
    }
    var idleHoldActive: Bool { KithTesting.enabled ? simulatedIdle : assertionID != nil }
    var closedLidReady: Bool { helperEnabled && helperStatus.leaseActive && desiredRequest?.closedLid == true }
    var displayHoldActive: Bool { KithTesting.enabled ? simulatedDisplay : displayAssertionID != nil }

    func registerHelper() throws {
        let service = SMAppService.daemon(plistName: PowerService.plistName)
        if service.status != .enabled { try service.register() }
    }

    func unregisterHelper(completion: @escaping (Error?) -> Void) {
        desiredRequest = nil
        desiredLeaseID = nil
        guard !requestInFlight else {
            completion(NSError(domain: "KithPower", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Wait for the current power request, then disable the helper again"]))
            return
        }
        let unregister = {
            self.readStatus { success, message in
                guard success, !self.helperStatus.leaseActive, self.helperStatus.recovery == .restored else {
                    completion(NSError(domain: "KithPower", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                    return
                }
                do { try SMAppService.daemon(plistName: PowerService.plistName).unregister(); completion(nil) }
                catch { completion(error) }
            }
        }
        if let id = activeLeaseID {
            call({ proxy, reply in proxy.release(leaseID: id, withReply: reply) }) { success, message in
                guard success else {
                    completion(NSError(domain: "KithPower", code: 1, userInfo: [NSLocalizedDescriptionKey: message])); return
                }
                self.activeLeaseID = nil
                unregister()
            }
        } else { unregister() }
    }

    @discardableResult
    func holdIdleSleep(_ shouldHold: Bool, until deadline: Date? = nil) -> Bool {
        if KithTesting.enabled { simulatedIdle = shouldHold; return true }
        if shouldHold && assertionID == nil {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithDescription(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                "Kith active coding agents" as CFString,
                "Monitoring local coding sessions" as CFString,
                "Coding agents are working" as CFString,
                nil, deadline.map { max(1, $0.timeIntervalSinceNow) } ?? 45,
                kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
            if status == kIOReturnSuccess { assertionID = id }
            else { return false }
        } else if !shouldHold, let assertionID {
            guard IOPMAssertionRelease(assertionID) == kIOReturnSuccess else { return false }
            self.assertionID = nil
        }
        if shouldHold, let id = assertionID, let deadline {
            return IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString,
                max(1, ceil(deadline.timeIntervalSinceNow)) as CFNumber) == kIOReturnSuccess
        }
        return true
    }

    func holdDisplay(until deadline: Date?) -> Bool {
        if KithTesting.enabled { simulatedDisplay = deadline.map { $0 > Date() } ?? false; return true }
        guard let deadline, deadline > Date() else {
            if let id = displayAssertionID {
                guard IOPMAssertionRelease(id) == kIOReturnSuccess else { return false }
                displayAssertionID = nil
            }
            return true
        }
        let timeout = max(1, ceil(deadline.timeIntervalSinceNow)) as CFNumber
        if let id = displayAssertionID {
            return IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, timeout) == kIOReturnSuccess
        }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionNameKey: "Kith computer-use display hold",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: timeout,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff,
        ]
        var id = IOPMAssertionID(0)
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess else { return false }
        displayAssertionID = id
        return true
    }

    func applyLease(_ request: PowerLeaseRequest?, id: UUID?) {
        desiredRequest = request
        desiredLeaseID = id?.uuidString
        if !helperEnabled {
            helperStatus.leaseActive = false
            lastRequest = nil
            if activeLeaseID != nil {
                helperStatus.recovery = .needsAttention
                helperStatus.detail = "Enable the power helper to confirm restoration of its previous settings"
            }
            return
        }
        driveLease()
    }

    private func driveLease() {
        guard helperEnabled, !requestInFlight else { return }
        if let activeLeaseID, desiredRequest == nil || desiredLeaseID != activeLeaseID {
            requestInFlight = true
            call({ proxy, reply in proxy.release(leaseID: activeLeaseID, withReply: reply) }) { success, message in
                self.requestInFlight = false
                if success { self.activeLeaseID = nil; self.lastRequest = nil }
                else { self.report(message) }
                self.readStatus { _, _ in }
                if success { self.driveLease() }
            }
            return
        }
        guard let desiredRequest, let id = desiredLeaseID else { return }
        guard desiredRequest != lastRequest || Date().timeIntervalSince(lastRenewal) >= 10 else { return }
        guard let data = try? JSONEncoder().encode(desiredRequest) else { return }
        requestInFlight = true
        activeLeaseID = id
        call({ proxy, reply in proxy.configure(leaseID: id, request: data, withReply: reply) }) { success, message in
            self.requestInFlight = false
            if success { self.lastRequest = desiredRequest; self.lastRenewal = Date() }
            else { self.report(message) }
            self.readStatus { _, _ in }
            if self.desiredRequest != desiredRequest || self.desiredLeaseID != id { self.driveLease() }
        }
    }

    func refreshHelper() {
        guard helperEnabled else { return }
        readStatus { success, message in if !success { self.report(message) } }
    }

    func retryRecovery() {
        guard helperEnabled else { return }
        call({ proxy, reply in proxy.retryRecovery(withReply: reply) }) { success, message in
            if !success { self.report(message) }
            self.readStatus { _, _ in }
        }
    }

    private func report(_ message: String) {
        helperStatus.recovery = .pending
        helperStatus.detail = message
        onError?(message)
    }

    func perform(_ action: String, completion: @escaping (Bool, String) -> Void) {
        holdIdleSleep(false)
        _ = holdDisplay(until: nil)
        call({ proxy, reply in proxy.perform(action: action, withReply: reply) },
             completion: completion)
    }

    func checkHelper(completion: @escaping (Bool, String) -> Void) { readStatus(completion: completion) }

    private func readStatus(completion: @escaping (Bool, String) -> Void) {
        let gate = ReplyGate(completion)
        call({ proxy, reply in
            let response = HelperCallback(call: reply)
            proxy.readStatus { @Sendable data in
                Task { @MainActor in
                    guard let status = try? JSONDecoder().decode(PowerHelperStatus.self, from: data), status.protocolVersion == 2 else {
                        gate.finish(false, "Update or re-enable the power helper to use this version of Kith")
                        response.call(false, "Power helper version mismatch")
                        return
                    }
                    self.helperStatus = status
                    gate.finish(status.recovery == .restored, status.detail ?? "Power helper ready")
                    response.call(true, "Status received")
                }
            }
        }) { success, message in if !success { gate.finish(false, message) } }
    }

    private func call(
        _ invoke: @escaping (PowerServiceProtocol, @escaping (Bool, String) -> Void) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        let gate = ReplyGate(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            gate.finish(false, "Power helper timed out")
        }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: PowerService.name, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PowerServiceProtocol.self)
            // An invalidated connection never recovers, so drop it and reconnect on the next call.
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil }
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
