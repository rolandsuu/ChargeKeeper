import Foundation

/// Decides what the service should do on each cycle. Pure, so every case can be tested
/// without touching the Mac.
public enum Policy {
    /// Charging resumes this far below the heat threshold, so it doesn't flip on and off.
    public static let resumeMargin = 2.0
    /// No new heat pause below this level, so a hot Mac can't sit nearly empty.
    public static let minimumPausePercent = 20
    /// A pause is set this far above the current charge. A limit takes up to a minute to apply and
    /// the battery can gain 1% in that time. If the limit ended up below the charge, macOS would
    /// run the Mac on battery to drain down to it, which is the opposite of what a pause is for.
    public static let pauseMargin = 1

    /// Returns the updated runtime state. Read `ServiceState.targetLimit` for the resulting limit.
    public static func next(
        settings: ServiceSettings,
        runtime: RuntimeState,
        percent: Int?,
        isFullyCharged: Bool,
        temperature: Double?,
        isPluggedIn: Bool
    ) -> RuntimeState {
        var result = runtime

        if result.chargingToFull, isFullyCharged || (percent ?? 0) >= 100 {
            result.chargingToFull = false
        }
        let baseLimit = result.chargingToFull ? ChargeLimit.noLimit : settings.limit

        // If the temperature can't be read, don't hold charging on a guess.
        guard settings.heatEnabled, let temperature else {
            result.heatPauseLimit = nil
            return result
        }

        if let paused = result.heatPauseLimit {
            let cooled = temperature <= Double(settings.heatThreshold) - resumeMargin
            if cooled || paused >= baseLimit {
                result.heatPauseLimit = nil
            }
        } else if let percent,
                  isPluggedIn,
                  temperature >= Double(settings.heatThreshold),
                  percent >= minimumPausePercent,
                  percent + pauseMargin < baseLimit {
            result.heatPauseLimit = percent + pauseMargin
        }
        return result
    }
}
