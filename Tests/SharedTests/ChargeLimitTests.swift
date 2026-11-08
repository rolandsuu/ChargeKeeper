import Foundation
import Testing
@testable import Shared

struct ChargeLimitTests {
    @Test func readsManualLimitFromPmsetOutput() {
        let output = """
        Battery level limits:
        (
                {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = 29294;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 33;
            },
                {
                Terminated = 0;
                chargeSocLimitOwner = 0;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 33;
            }
        )
        """
        #expect(ChargeLimit.parseBattLimit(output) == 33)
    }

    @Test func ignoresLimitsSetForOtherReasons() {
        let output = """
        Battery level limits:
        (
                {
                chargeSocLimitReason = optimizedBatteryCharging;
                chargeSocLimitSoc = 80;
            }
        )
        """
        #expect(ChargeLimit.parseBattLimit(output) == nil)
    }

    @Test func noLimitsMeansNil() {
        #expect(ChargeLimit.parseBattLimit("Battery level limits:\n(\n)\n") == nil)
        #expect(ChargeLimit.parseBattLimit("") == nil)
    }

    @Test(.disabled(if: geteuid() == 0, "only meaningful when run as a normal user"))
    func changingTheLimitNeedsRoot() {
        let error = #expect(throws: ChargeLimit.Failure.self) { try ChargeLimit.request(80) }
        if case .needsRoot? = error {} else { Issue.record("expected needsRoot, got \(String(describing: error))") }
    }

    @Test(arguments: [9, 0, -5, 101, 150])
    func refusesOutOfRangeValuesBeforeTouchingAnything(value: Int) {
        let error = #expect(throws: ChargeLimit.Failure.self) { try ChargeLimit.request(value) }
        if case .outOfRange? = error {} else { Issue.record("expected outOfRange, got \(String(describing: error))") }
    }
}
