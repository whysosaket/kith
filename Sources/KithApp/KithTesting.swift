import Foundation
import KithCore

/// Fault injection is compiled only into debug builds and requires an isolated
/// support directory. Release builds never consume these fixtures.
@MainActor
enum KithTesting {
    static var enabled: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["KITH_E2E"] == "1" && environment["KITH_HOME"]?.hasPrefix("/tmp/kith-e2e-") == true
        #else
        return false
        #endif
    }
    static let defaults: UserDefaults = {
        enabled ? UserDefaults(suiteName: "app.trykith.kith.e2e.\(ProcessInfo.processInfo.processIdentifier)")! : .standard
    }()
    static func cleanUp() {
        if enabled { defaults.removePersistentDomain(forName: "app.trykith.kith.e2e.\(ProcessInfo.processInfo.processIdentifier)") }
    }
}

#if DEBUG
struct PowerTestFixture: Decodable {
    var revision: Int
    var status: String
    var batteryPercent: Int?
    var batteryUnreadable: Bool
    var onAC: Bool
    var heat: Int
    var lidClosed: Bool
    var networkAvailable: Bool
    var armFinishAction: Bool?

    var conditions: PowerConditions {
        PowerConditions(battery: batteryUnreadable ? .unreadable : batteryPercent.map(BatteryReading.percent) ?? .absent,
            onAC: onAC, heat: HeatLevel(rawValue: heat) ?? .critical, lidClosed: lidClosed)
    }
}
#endif
