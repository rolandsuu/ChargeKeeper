import Testing
@testable import Shared

struct PolicyTests {
    private let settings = ServiceSettings(limit: 80, heatEnabled: true, heatThreshold: 35)

    private func next(
        _ runtime: RuntimeState = .init(),
        settings: ServiceSettings? = nil,
        percent: Int? = 50,
        full: Bool = false,
        temperature: Double? = 30,
        pluggedIn: Bool = true
    ) -> RuntimeState {
        Policy.next(
            settings: settings ?? self.settings, runtime: runtime, percent: percent,
            isFullyCharged: full, temperature: temperature, isPluggedIn: pluggedIn
        )
    }

    @Test func coolMacIsLeftAlone() {
        #expect(next() == RuntimeState())
    }

    @Test func pausesJustAboveCurrentChargeWhenHot() {
        #expect(next(percent: 33, temperature: 35.6).heatPauseLimit == 34)
        #expect(next(percent: 33, temperature: 35.0).heatPauseLimit == 34)
    }

    @Test func pauseKeepsItsLevelWhileHot() {
        #expect(next(RuntimeState(heatPauseLimit: 34), percent: 34, temperature: 36).heatPauseLimit == 34)
    }

    @Test func pauseStaysUntilTwoDegreesBelowThreshold() {
        let paused = RuntimeState(heatPauseLimit: 33)
        #expect(next(paused, temperature: 34).heatPauseLimit == 33)
        #expect(next(paused, temperature: 33.1).heatPauseLimit == 33)
        #expect(next(paused, temperature: 33).heatPauseLimit == nil)
    }

    @Test func noPauseBelowMinimumBattery() {
        #expect(next(percent: 19, temperature: 40).heatPauseLimit == nil)
        #expect(next(percent: 20, temperature: 40).heatPauseLimit == 21)
    }

    @Test func noPauseWithinOnePercentOfTheLimitOrAboveIt() {
        #expect(next(percent: 78, temperature: 40).heatPauseLimit == 79)
        #expect(next(percent: 79, temperature: 40).heatPauseLimit == nil)
        #expect(next(percent: 80, temperature: 40).heatPauseLimit == nil)
        #expect(next(percent: 95, temperature: 40).heatPauseLimit == nil)
    }

    @Test func noNewPauseOnBattery() {
        #expect(next(temperature: 40, pluggedIn: false).heatPauseLimit == nil)
    }

    @Test func pauseEndsWhenHeatProtectionIsTurnedOff() {
        let off = ServiceSettings(limit: 80, heatEnabled: false, heatThreshold: 35)
        #expect(next(RuntimeState(heatPauseLimit: 33), settings: off, temperature: 40).heatPauseLimit == nil)
    }

    @Test func unreadableTemperatureNeverHoldsCharging() {
        #expect(next(RuntimeState(heatPauseLimit: 33), temperature: nil).heatPauseLimit == nil)
        #expect(next(temperature: nil).heatPauseLimit == nil)
    }

    @Test func pauseEndsIfTheLimitIsLoweredBelowIt() {
        let lower = ServiceSettings(limit: 60, heatEnabled: true, heatThreshold: 35)
        #expect(next(RuntimeState(heatPauseLimit: 70), settings: lower, temperature: 40).heatPauseLimit == nil)
    }

    @Test func chargeToFullEndsAtFull() {
        let charging = RuntimeState(chargingToFull: true)
        #expect(next(charging, percent: 90).chargingToFull)
        #expect(!next(charging, percent: 100).chargingToFull)
        #expect(!next(charging, percent: 99, full: true).chargingToFull)
    }

    @Test func heatStillPausesDuringChargeToFull() {
        let charging = RuntimeState(chargingToFull: true)
        let result = next(charging, percent: 90, temperature: 36)
        #expect(result.heatPauseLimit == 91)
        #expect(result.chargingToFull)
    }

    @Test func targetLimit() {
        #expect(ServiceState(settings: settings).targetLimit == 80)
        #expect(ServiceState(settings: settings, runtime: .init(chargingToFull: true)).targetLimit == 100)
        #expect(ServiceState(settings: settings, runtime: .init(heatPauseLimit: 33)).targetLimit == 33)
        #expect(ServiceState(settings: settings, runtime: .init(heatPauseLimit: 90, chargingToFull: true)).targetLimit == 90)
    }
}
