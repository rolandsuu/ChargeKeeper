import Foundation

public enum Identity {
    public static let teamID = "24239H44M8"
    public static let appIdentifier = "com.rolandsu.chargekeeper"
    public static let serviceIdentifier = "com.rolandsu.chargekeeper.service"
    public static let servicePlistName = "com.rolandsu.chargekeeper.service.plist"

    /// Code-signing rule the service applies to anything connecting to it.
    public static var clientRequirement: String { requirement(for: appIdentifier) }
    /// Code-signing rule the app applies to the service it connects to.
    public static var serviceRequirement: String { requirement(for: serviceIdentifier) }

    private static func requirement(for identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// Everything the app can ask the root service to do. Keep this list narrow:
/// there is deliberately no general way to run commands or write settings.
/// Replies carrying `String?` give an error message, or nil on success.
@objc public protocol ChargeKeeperServiceProtocol {
    /// Replies with a JSON-encoded `ServiceState`.
    func getState(reply: @escaping (Data) -> Void)
    /// `percent` is 10...100, where 100 means no limit.
    func setLimit(_ percent: Int, reply: @escaping (String?) -> Void)
    /// `threshold` is in °C, within `ServiceSettings.heatThresholdRange`.
    func setHeatProtection(enabled: Bool, threshold: Int, reply: @escaping (String?) -> Void)
    /// Lifts the limit until the battery reaches 100%, or cancels that.
    func setChargeToFull(_ on: Bool, reply: @escaping (String?) -> Void)
    /// Turns the MagSafe charging light on (macOS controls it) or off.
    func setMagSafeLight(visible: Bool, reply: @escaping (String?) -> Void)
    /// Restores your saved limit and the MagSafe light, and deletes the service's files, ready to be unregistered.
    func prepareForRemoval(reply: @escaping (String?) -> Void)
}

/// What you've chosen. Survives restarts.
public struct ServiceSettings: Codable, Equatable {
    public static let heatThresholdRange = 30...50

    public var limit: Int
    public var heatEnabled: Bool
    public var heatThreshold: Int
    /// The MagSafe light is off unless you turn it on.
    public var showMagSafeLight: Bool

    public init(limit: Int = 80, heatEnabled: Bool = true, heatThreshold: Int = 35, showMagSafeLight: Bool = false) {
        self.limit = limit
        self.heatEnabled = heatEnabled
        self.heatThreshold = heatThreshold
        self.showMagSafeLight = showMagSafeLight
    }

    private enum CodingKeys: String, CodingKey {
        case limit, heatEnabled, heatThreshold, showMagSafeLight
    }

    /// Settings saved before the MagSafe light option existed still load, with the light off.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limit = try container.decode(Int.self, forKey: .limit)
        heatEnabled = try container.decode(Bool.self, forKey: .heatEnabled)
        heatThreshold = try container.decode(Int.self, forKey: .heatThreshold)
        showMagSafeLight = try container.decodeIfPresent(Bool.self, forKey: .showMagSafeLight) ?? false
    }
}

/// What's in progress. Survives restarts so a crash can't lose track of a pause.
public struct RuntimeState: Codable, Equatable {
    /// The battery level charging is paused at because of heat, if any.
    public var heatPauseLimit: Int?
    public var chargingToFull: Bool

    public init(heatPauseLimit: Int? = nil, chargingToFull: Bool = false) {
        self.heatPauseLimit = heatPauseLimit
        self.chargingToFull = chargingToFull
    }
}

public struct ServiceState: Codable, Equatable {
    public var settings: ServiceSettings
    public var runtime: RuntimeState
    /// A limit that's been requested but that macOS isn't reporting yet.
    public var pendingLimit: Int?
    public var lastError: String?

    public init(
        settings: ServiceSettings = .init(),
        runtime: RuntimeState = .init(),
        pendingLimit: Int? = nil,
        lastError: String? = nil
    ) {
        self.settings = settings
        self.runtime = runtime
        self.pendingLimit = pendingLimit
        self.lastError = lastError
    }

    /// The limit macOS should be enforcing given this state.
    public var targetLimit: Int {
        runtime.heatPauseLimit ?? (runtime.chargingToFull ? ChargeLimit.noLimit : settings.limit)
    }
}
