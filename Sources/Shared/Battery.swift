import Foundation
import IOKit

public struct BatterySnapshot: Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var voltageMV: Int
    /// Positive while charging, negative while discharging.
    public var amperageMA: Int
    public var designCapacity: Int
    public var fullChargeCapacity: Int
    public var cycleCount: Int
    public var adapterName: String?

    public init(
        percent: Int, isCharging: Bool, isPluggedIn: Bool, isFullyCharged: Bool,
        voltageMV: Int, amperageMA: Int, designCapacity: Int, fullChargeCapacity: Int,
        cycleCount: Int, adapterName: String?
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.cycleCount = cycleCount
        self.adapterName = adapterName
    }

    /// Current capacity compared with new, as System Information reports it.
    public var healthPercent: Int? {
        guard designCapacity > 0, fullChargeCapacity > 0 else { return nil }
        return Int((Double(fullChargeCapacity) / Double(designCapacity) * 100).rounded())
    }

    /// Reads the battery's registry entry. Needs no special permissions.
    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(dictionary)
    }

    static func parse(_ values: [String: Any]) -> BatterySnapshot? {
        func int(_ value: Any?) -> Int? { (value as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) } }
        func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }

        guard let percent = int(values["CurrentCapacity"]) else { return nil }
        let batteryData = values["BatteryData"] as? [String: Any] ?? [:]
        let adapter = values["AdapterDetails"] as? [String: Any]
        let isPluggedIn = bool(values["ExternalConnected"])

        return BatterySnapshot(
            percent: percent,
            isCharging: bool(values["IsCharging"]),
            isPluggedIn: isPluggedIn,
            isFullyCharged: bool(values["FullyCharged"]),
            voltageMV: int(values["Voltage"]) ?? 0,
            amperageMA: int(values["InstantAmperage"]) ?? int(values["Amperage"]) ?? 0,
            designCapacity: int(batteryData["DesignCapacity"]) ?? int(values["DesignCapacity"]) ?? 0,
            fullChargeCapacity: int(batteryData["FullChargeCapacity"]) ?? 0,
            cycleCount: int(values["CycleCount"]) ?? 0,
            adapterName: isPluggedIn ? adapter?["Name"] as? String : nil
        )
    }
}

public struct PowerFlow: Equatable {
    public var chargerWatts: Double
    /// Positive while charging, negative while discharging.
    public var batteryWatts: Double
    public var systemWatts: Double

    /// The battery's current reading lags by up to a minute, so the live sensors are preferred:
    /// whatever the charger supplies beyond what the Mac uses goes into the battery.
    public init(chargerSensorWatts: Double?, systemSensorWatts: Double?, voltageMV: Int, amperageMA: Int) {
        chargerWatts = max(chargerSensorWatts ?? 0, 0)
        if let systemSensorWatts {
            systemWatts = max(systemSensorWatts, 0)
            batteryWatts = chargerWatts - systemWatts
        } else {
            batteryWatts = Double(voltageMV) * Double(amperageMA) / 1_000_000
            systemWatts = max(chargerWatts - batteryWatts, 0)
        }
    }
}

/// Reads sensor values from the SMC. It can only read.
public final class SensorReader {
    private let smc: SMCConnection

    public init?() {
        guard let smc = SMCConnection() else { return nil }
        self.smc = smc
    }

    private func float(_ key: String) -> Double? {
        guard let value = smc.read(key), value.type == "flt ", value.bytes.count == 4 else { return nil }
        let number = value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        return number.isFinite ? Double(number) : nil
    }

    /// The hottest of the battery's temperature sensors, in °C.
    public func batteryTemperature() -> Double? {
        ["TB0T", "TB1T", "TB2T"].compactMap(float).filter { $0 > 0 }.max()
    }

    /// Power arriving from the charger, in watts.
    public func chargerWatts() -> Double? {
        float("PDTR")
    }

    /// Power the Mac itself is using, not counting what goes into the battery, in watts.
    public func systemWatts() -> Double? {
        float("PSTR")
    }
}
