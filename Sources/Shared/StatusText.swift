import Foundation

/// The plain-language status line at the top of the window.
public enum StatusText {
    public static func describe(
        battery: BatterySnapshot,
        limit: Int?,
        heatPauseLimit: Int?,
        chargingToFull: Bool,
        temperature: Double?,
        resumeTemperature: Double?,
        batteryWatts: Double? = nil
    ) -> String {
        guard battery.isPluggedIn else { return "On battery" }

        if heatPauseLimit != nil {
            var text = "Paused: too hot"
            if let temperature { text += " (\(Int(temperature.rounded()))°C)" }
            if let resumeTemperature { text += ", resumes at \(Int(resumeTemperature.rounded()))°C" }
            return text
        }
        let isFull = battery.isFullyCharged || battery.percent >= 100
        if chargingToFull, !isFull { return "Charging to 100%" }

        // The battery's charging flag lags by up to a minute, so the comparison with the limit
        // comes first and the live power reading can correct the flag.
        let isCharging = battery.isCharging || (batteryWatts ?? 0) > 1
        if let limit {
            if battery.percent > limit { return "Draining to \(limit)%" }
            if battery.percent == limit { return "Holding at \(limit)%" }
            if isCharging { return "Charging to \(limit)%" }
            return "Plugged in, charging resumes after a small drop"
        }
        if isFull { return "Fully charged" }
        return isCharging ? "Charging" : "Plugged in, not charging"
    }

    /// True when the battery is charging past the limit, which means the limit isn't working.
    /// The live power reading has to agree, because the charging flag lags after a limit is lowered.
    public static func isChargingAboveLimit(battery: BatterySnapshot, limit: Int?, batteryWatts: Double? = nil) -> Bool {
        guard let limit, battery.isCharging, (batteryWatts ?? 1) > 0.5 else { return false }
        return battery.percent > limit + 1
    }
}
