import Foundation
import Testing
@testable import Shared

struct BatteryTests {
    private func battery(
        percent: Int = 50, charging: Bool = false, pluggedIn: Bool = true, full: Bool = false, amps: Int = 0
    ) -> BatterySnapshot {
        BatterySnapshot(
            percent: percent, isCharging: charging, isPluggedIn: pluggedIn, isFullyCharged: full,
            voltageMV: 11_500, amperageMA: amps, designCapacity: 4563, fullChargeCapacity: 4368,
            cycleCount: 83, adapterName: nil
        )
    }

    private func isClose(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.001
    }

    @Test func healthMatchesSystemInformation() {
        #expect(battery().healthPercent == 96)
    }

    @Test func powerWhileChargingUsesLiveSensors() {
        // Figures measured on the M2 Air: the stale current reading doesn't affect the result.
        let flow = PowerFlow(chargerSensorWatts: 28.4, systemSensorWatts: 13.7, voltageMV: 11_500, amperageMA: 0)
        #expect(isClose(flow.batteryWatts, 14.7))
        #expect(isClose(flow.systemWatts, 13.7))
    }

    @Test func powerWhileDrainingOnTheCharger() {
        let flow = PowerFlow(chargerSensorWatts: 0.3, systemSensorWatts: 10.8, voltageMV: 11_500, amperageMA: 1371)
        #expect(isClose(flow.batteryWatts, -10.5))
        #expect(isClose(flow.systemWatts, 10.8))
    }

    @Test func powerFallsBackToBatteryCurrentWithoutTheSystemSensor() {
        let charging = PowerFlow(chargerSensorWatts: 28, systemSensorWatts: nil, voltageMV: 11_500, amperageMA: 1000)
        #expect(isClose(charging.batteryWatts, 11.5))
        #expect(isClose(charging.systemWatts, 16.5))

        let onBattery = PowerFlow(chargerSensorWatts: 0, systemSensorWatts: nil, voltageMV: 11_500, amperageMA: -1000)
        #expect(isClose(onBattery.batteryWatts, -11.5))
        #expect(isClose(onBattery.systemWatts, 11.5))
    }

    @Test func missingOrNegativeChargerReadingCountsAsZero() {
        #expect(PowerFlow(chargerSensorWatts: nil, systemSensorWatts: 5, voltageMV: 11_500, amperageMA: 0).chargerWatts == 0)
        #expect(PowerFlow(chargerSensorWatts: -1, systemSensorWatts: 5, voltageMV: 11_500, amperageMA: 0).chargerWatts == 0)
    }

    @Test func parsesRegistryValuesIncludingNegativeCurrent() {
        let values: [String: Any] = [
            "CurrentCapacity": 47,
            "IsCharging": true,
            "ExternalConnected": true,
            "FullyCharged": false,
            "Voltage": 11_577,
            "InstantAmperage": NSNumber(value: Int64(-1014)),
            "CycleCount": 83,
            "BatteryData": ["DesignCapacity": 4563, "FullChargeCapacity": 4368],
            "AdapterDetails": ["Name": "30W USB-C Power Adapter"],
        ]
        let parsed = BatterySnapshot.parse(values)
        #expect(parsed?.percent == 47)
        #expect(parsed?.amperageMA == -1014)
        #expect(parsed?.healthPercent == 96)
        #expect(parsed?.adapterName == "30W USB-C Power Adapter")
    }

    @Test func statusLines() {
        func text(
            _ battery: BatterySnapshot, limit: Int? = 80, pause: Int? = nil, full: Bool = false, watts: Double? = nil
        ) -> String {
            StatusText.describe(
                battery: battery, limit: limit, heatPauseLimit: pause, chargingToFull: full,
                temperature: 36, resumeTemperature: 33, batteryWatts: watts
            )
        }
        #expect(text(battery(pluggedIn: false)) == "On battery")
        #expect(text(battery(), pause: 50) == "Paused: too hot (36°C), resumes at 33°C")
        #expect(text(battery(charging: true)) == "Charging to 80%")
        #expect(text(battery(charging: true), limit: nil) == "Charging")
        #expect(text(battery(charging: true), full: true) == "Charging to 100%")
        #expect(text(battery(percent: 80)) == "Holding at 80%")
        #expect(text(battery(percent: 85)) == "Draining to 80%")
        #expect(text(battery(percent: 70)) == "Plugged in, charging resumes after a small drop")
        #expect(text(battery(percent: 100, full: true), limit: nil) == "Fully charged")
        #expect(text(battery(percent: 60), limit: nil) == "Plugged in, not charging")
    }

    @Test func statusIsRightWhileTheChargingFlagIsStale() {
        func text(_ battery: BatterySnapshot, limit: Int?, full: Bool = false, watts: Double? = nil) -> String {
            StatusText.describe(
                battery: battery, limit: limit, heatPauseLimit: nil, chargingToFull: full,
                temperature: nil, resumeTemperature: nil, batteryWatts: watts
            )
        }
        // Seen on the M2 Air: just after lowering the limit, the flag still says charging.
        #expect(text(battery(percent: 81, charging: true), limit: 80, watts: -12) == "Draining to 80%")
        // Just after raising the limit, the flag still says not charging.
        #expect(text(battery(percent: 81), limit: 85, watts: 10) == "Charging to 85%")
        // Just after starting a charge to 100%.
        #expect(text(battery(percent: 81), limit: nil, full: true) == "Charging to 100%")
    }

    @Test func aboveLimitWarningIgnoresAStaleChargingFlag() {
        let stale = battery(percent: 85, charging: true)
        #expect(!StatusText.isChargingAboveLimit(battery: stale, limit: 80, batteryWatts: -12))
        #expect(StatusText.isChargingAboveLimit(battery: stale, limit: 80, batteryWatts: 12))
    }

    @Test func warnsOnlyWhenChargingPastTheLimit() {
        #expect(StatusText.isChargingAboveLimit(battery: battery(percent: 82, charging: true), limit: 80))
        #expect(!StatusText.isChargingAboveLimit(battery: battery(percent: 81, charging: true), limit: 80))
        #expect(!StatusText.isChargingAboveLimit(battery: battery(percent: 90), limit: 80))
        #expect(!StatusText.isChargingAboveLimit(battery: battery(percent: 90, charging: true), limit: nil))
    }
}
