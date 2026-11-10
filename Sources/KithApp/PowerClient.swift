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
    private var displayAssertionID: IOPMAssertionID?
    private var simulatedIdle = false
    private var simulatedDisplay = false
    private(set) var helperStatus = PowerHelperStatus()
    var onError: ((String) -> Void)?

    var helperEnabled: Bool {
        !KithTesting.enabled && SMAppService.daemon(plistName: PowerService.plistName).status == .enabled
    }
    var idleHoldActive: Bool { KithTesting.enabled ? simulatedIdle : assertionID != nil }
    var displayHoldActive: Bool { KithTesting.enabled ? simulatedDisplay : displayAssertionID != nil }

    func registerHelper() throws {
        let service = SMAppService.daemon(plistName: PowerService.plistName)
        if service.status != .enabled { try service.register() }
    }

    func unregisterHelper(completion: @escaping (Error?) -> Void) {
        readStatus { success, message in
            guard success, !self.helperStatus.leaseActive,
                  !FileManager.default.fileExists(atPath: PowerService.recoveryStateURL.path) else {
                let reason = success ? "Wait for legacy power recovery before disabling the helper" : message
                completion(PowerError.unavailable(reason))
                return
            }
            do { try SMAppService.daemon(plistName: PowerService.plistName).unregister(); completion(nil) }
            catch { completion(error) }
        }
    }

    // Renew through the model's periodic update. macOS can release a hold
    // even when the app hangs before the period's deadline.
    private func assertionTimeout(until deadline: Date?) -> TimeInterval {
        min(45, max(1, deadline.map { ceil($0.timeIntervalSinceNow) } ?? 45))
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
                nil, assertionTimeout(until: deadline),
                kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
            if status == kIOReturnSuccess { assertionID = id }
            else { return false }
        } else if !shouldHold, let assertionID {
            guard IOPMAssertionRelease(assertionID) == kIOReturnSuccess else { return false }
            self.assertionID = nil
        }
        if shouldHold, let id = assertionID, let deadline {
            return IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString,
                assertionTimeout(until: deadline) as CFNumber) == kIOReturnSuccess
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
        let timeout = assertionTimeout(until: deadline) as CFNumber
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
