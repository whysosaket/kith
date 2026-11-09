import Foundation
import IOKit
import IOKit.ps
import KithCore
import Network

@MainActor
final class PowerSystemMonitor {
    private(set) var conditions = PowerConditions()
    private(set) var networkAvailable: Bool?
    var onChange: ((PowerConditions, Bool) -> Void)?
    var onNetworkChange: (() -> Void)?
    private var source: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var retryTimer: Timer?
    private let network = NWPathMonitor()

    func start() {
        refreshBattery()
        refreshLid()
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSystemMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refreshBattery() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHeat() }
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.conditions.battery == .unreadable { self?.refreshBattery() }
            }
        }
        network.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                self?.networkAvailable = available
                self?.onNetworkChange?()
            }
        }
        network.start(queue: DispatchQueue(label: "app.trykith.kith.network", qos: .utility))
        refreshHeat()
    }

    func stop() {
        network.cancel()
        retryTimer?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func refreshLid() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard let closed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
            kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool, closed != conditions.lidClosed else { return }
        conditions.lidClosed = closed
        onChange?(conditions, false)
    }

    private func refreshHeat() {
        let heat: HeatLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: heat = .nominal
        case .fair: heat = .fair
        case .serious: heat = .serious
        case .critical: heat = .critical
        @unknown default: heat = .critical
        }
        conditions.heat = heat
        onChange?(conditions, false)
    }

    private func refreshBattery() {
        let reading = Self.readBattery()
        conditions.battery = reading.0
        conditions.onAC = reading.1
        onChange?(conditions, true)
    }

    private static func readBattery() -> (BatteryReading, Bool) {
        let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        let present = batteryService != 0
        var registryAC = false
        if present {
            registryAC = IORegistryEntryCreateCFProperty(batteryService, "ExternalConnected" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
            IOObjectRelease(batteryService)
        }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return present ? (.unreadable, registryAC) : (.absent, true)
        }
        for source in sources {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onAC = data[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            guard let current = data[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0, current >= 0 else { return (.unreadable, onAC) }
            return (.percent(min(100, current * 100 / maximum)), onAC)
        }
        return present ? (.unreadable, registryAC) : (.absent, true)
    }
}
