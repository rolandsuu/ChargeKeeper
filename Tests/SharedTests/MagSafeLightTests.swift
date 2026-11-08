import Foundation
import Testing
@testable import Shared

struct MagSafeLightTests {
    private let green: UInt8 = 0x03
    private let off = MagSafeLight.Mode.off.rawValue

    @Test func onlyTwoValuesCanBeWritten() {
        #expect(MagSafeLight.Mode.allCases.map(\.rawValue) == [0x00, 0x01])
    }

    @Test func turnsTheLightOffWhilePluggedIn() {
        #expect(MagSafeLight.change(showLight: false, current: green, isPluggedIn: true) == .off)
    }

    @Test func leavesALightThatsAlreadyOffAlone() {
        #expect(MagSafeLight.change(showLight: false, current: off, isPluggedIn: true) == nil)
    }

    @Test func doesNothingWhileUnplugged() {
        #expect(MagSafeLight.change(showLight: false, current: 0x00, isPluggedIn: false) == nil)
    }

    @Test func handsTheLightBackToMacOSWhenTurnedOn() {
        #expect(MagSafeLight.change(showLight: true, current: off, isPluggedIn: true) == .system)
        #expect(MagSafeLight.change(showLight: true, current: off, isPluggedIn: false) == .system)
    }

    @Test func leavesMacOSInChargeWhenTheLightIsOn() {
        #expect(MagSafeLight.change(showLight: true, current: green, isPluggedIn: true) == nil)
        #expect(MagSafeLight.change(showLight: true, current: 0x00, isPluggedIn: true) == nil)
    }

    @Test func oldSavedSettingsLoadWithTheLightOff() throws {
        // The state file as the previous version saved it.
        let saved = #"{"settings":{"heatThreshold":35,"limit":80,"heatEnabled":true},"runtime":{"chargingToFull":false}}"#
        let state = try JSONDecoder().decode(ServiceState.self, from: Data(saved.utf8))
        #expect(state.settings == ServiceSettings(limit: 80, heatEnabled: true, heatThreshold: 35, showMagSafeLight: false))
    }

    @Test func theLightSettingIsSaved() throws {
        let settings = ServiceSettings(showMagSafeLight: true)
        let decoded = try JSONDecoder().decode(ServiceSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.showMagSafeLight)
    }

    @Test func changingTheLightNeedsRoot() throws {
        guard geteuid() != 0, let light = MagSafeLight() else { return }
        #expect(throws: MagSafeLight.Failure.needsRoot) { try light.set(.off) }
    }
}
