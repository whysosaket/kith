import Foundation
import Testing
@testable import KithCore

struct PowerPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func continuingWorkAndGraceCannotMoveDeadline() throws {
        var policy = PowerPolicy()
        let preferences = PowerPreferences()
        let first = policy.evaluate(now: now, work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 300, conditions: PowerConditions(), preferences: preferences)
        #expect(first.hold)
        let deadline = try #require(policy.period?.deadline)
        for offset in [10.0, 100, 1000] {
            _ = policy.evaluate(now: now.addingTimeInterval(offset), work: true, monitoringReady: true,
                automaticEnabled: true, graceSeconds: 300, conditions: PowerConditions(), preferences: preferences)
            #expect(policy.period?.deadline == deadline)
        }
        let stopped = policy.evaluate(now: deadline, work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 300, conditions: PowerConditions(), preferences: preferences)
        #expect(!stopped.hold)
        #expect(stopped.stop == .deadline)
        let again = policy.evaluate(now: deadline.addingTimeInterval(10), work: true, monitoringReady: true,
            automaticEnabled: true, graceSeconds: 300, conditions: PowerConditions(), preferences: preferences)
        #expect(!again.hold)
        let restored = try JSONDecoder().decode(PowerPolicy.self, from: JSONEncoder().encode(policy))
        #expect(restored.stopped == .deadline)
    }

    @Test func safetyStopsLatchAndRequireSafeExplicitResume() throws {
        var policy = PowerPolicy()
        var preferences = PowerPreferences()
        preferences.keepDisplayAwake = true
        try policy.start(seconds: 3600, manual: true, now: now, conditions: PowerConditions(), preferences: preferences)
        let low = PowerConditions(battery: .percent(10), onAC: false)
        let decision = policy.evaluate(now: now, work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 300, conditions: low, preferences: preferences)
        #expect(decision.stop == .battery)
        #expect(!decision.hold && !decision.display)
        #expect(throws: PowerError.self) {
            try policy.start(seconds: 3600, manual: false, now: now, conditions: low, preferences: preferences)
        }
        let cool = policy.evaluate(now: now, work: true, monitoringReady: true, automaticEnabled: true,
            graceSeconds: 300, conditions: PowerConditions(), preferences: preferences)
        #expect(!cool.hold)
        try policy.start(seconds: 3600, manual: false, now: now, conditions: PowerConditions(), preferences: preferences)
        #expect(policy.stopped == nil)
    }

    @Test func unknownBatteryIsDifferentFromNoBattery() {
        var policy = PowerPolicy()
        let preferences = PowerPreferences()
        policy.observeBattery(.unreadable)
        let unknown = PowerConditions(battery: .unreadable, onAC: false)
        #expect(policy.safetyStop(conditions: unknown, preferences: preferences) == nil)
        policy.observeBattery(.unreadable)
        #expect(policy.safetyStop(conditions: unknown, preferences: preferences) == .batteryUnreadable)
        #expect(policy.safetyStop(conditions: PowerConditions(battery: .absent, onAC: false), preferences: preferences) == nil)
        #expect(policy.safetyStop(conditions: PowerConditions(battery: .unreadable, onAC: true), preferences: preferences) == nil)
        policy.observeBattery(.percent(50))
        #expect(policy.safetyStop(conditions: unknown, preferences: preferences) == nil)
    }

    @Test func criticalHeatStopsEvenOnAC() throws {
        var policy = PowerPolicy()
        let hot = PowerConditions(onAC: true, heat: .critical)
        #expect(policy.safetyStop(conditions: hot, preferences: PowerPreferences()) == .heat)
        #expect(throws: PowerError.self) {
            try policy.start(seconds: 60, manual: true, now: now, conditions: hot, preferences: PowerPreferences())
        }
    }

    @Test func extensionsAreExplicitAndRemindersAreDeduplicated() throws {
        var policy = PowerPolicy()
        let preferences = PowerPreferences()
        try policy.start(seconds: 600, manual: true, now: now, conditions: PowerConditions(), preferences: preferences)
        func evaluate(_ date: Date, policy: inout PowerPolicy) -> PowerDecision {
            policy.evaluate(now: date, work: false, monitoringReady: true, automaticEnabled: false,
                graceSeconds: 0, conditions: PowerConditions(), preferences: preferences)
        }
        #expect(!evaluate(now, policy: &policy).reminder)
        #expect(evaluate(now.addingTimeInterval(301), policy: &policy).reminder)
        #expect(!evaluate(now.addingTimeInterval(302), policy: &policy).reminder)
        try policy.extend(seconds: 600, now: now.addingTimeInterval(302))
        #expect(policy.period?.deadline == now.addingTimeInterval(1200))
        #expect(evaluate(now.addingTimeInterval(901), policy: &policy).reminder)
        #expect(throws: PowerError.self) { try policy.extend(seconds: .infinity, now: now) }
        #expect(throws: PowerError.self) { try policy.extend(seconds: 86_400, now: now) }
    }

    @Test func naturalCompletionReleasesAfterGraceAndNextWorkGetsNewPeriod() {
        var policy = PowerPolicy()
        let preferences = PowerPreferences()
        func run(_ time: Double, work: Bool) -> PowerDecision {
            policy.evaluate(now: now.addingTimeInterval(time), work: work, monitoringReady: true,
                automaticEnabled: true, graceSeconds: 30, conditions: PowerConditions(), preferences: preferences)
        }
        #expect(run(0, work: true).hold)
        let id = policy.period?.id
        #expect(run(10, work: false).hold)
        #expect(!run(41, work: false).hold)
        #expect(policy.period == nil)
        #expect(run(50, work: true).hold)
        #expect(policy.period?.id != id)
    }

    @Test func legacyPreferencesRetainSupportedSettings() throws {
        let data = Data("""
            {"maximumSeconds":7200,"batteryWarning":20,"batteryFloor":10,"keepDisplayAwake":true,
             "saveEnergy":true,"lowPowerFloor":40,"lowPowerWithLidClosed":true,
             "muteWithLidClosed":true,"networkAlerts":true,"browserDiagnostics":false}
            """.utf8)
        let preferences = try JSONDecoder().decode(PowerPreferences.self, from: data).validated()
        #expect(preferences.maximumSeconds == 7200)
        #expect(preferences.keepDisplayAwake)
        #expect(preferences.muteWithLidClosed)
    }
}
