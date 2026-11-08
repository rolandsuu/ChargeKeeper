import Foundation
import ObjectiveC

/// Reads and sets Apple's charge limit.
///
/// macOS holds the limit itself, so it stays in force when this code isn't running.
/// Apple's own setter stops at 80%, so lower values are written to the preference
/// `PowerUIAgent` reads, which needs root. All of this is undocumented, so every
/// change is confirmed against what `pmset` reports rather than assumed to have worked.
public enum ChargeLimit {
    public static let validRange = 10...100
    public static let noLimit = 100

    public enum Failure: LocalizedError {
        case outOfRange(Int)
        case needsRoot
        case frameworkUnavailable
        case notApplied(wanted: Int, actual: Int?)

        public var errorDescription: String? {
            switch self {
            case .outOfRange(let value):
                return "\(value)% is outside the allowed range of \(ChargeLimit.validRange.lowerBound)–\(ChargeLimit.validRange.upperBound)%."
            case .needsRoot:
                return "Changing the limit needs the background service."
            case .frameworkUnavailable:
                return "macOS's charge limit interface isn't available on this version."
            case .notApplied(let wanted, let actual):
                let shown = actual.map { "\($0)%" } ?? "no limit"
                return "macOS didn't apply the \(wanted)% limit. It reports \(shown)."
            }
        }
    }

    // MARK: Reading

    /// The limit macOS is enforcing right now, or nil if there is none.
    public static func live() -> Int? {
        parseBattLimit(pmsetBattLimit())
    }

    /// Pulls the manual limit out of `pmset -g battlimit` output.
    public static func parseBattLimit(_ output: String) -> Int? {
        var soc: Int?
        var isManual = false
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("{") {
                soc = nil
                isManual = false
            } else if text.hasPrefix("chargeSocLimitReason") {
                isManual = text.contains("manualChargeLimit")
            } else if text.hasPrefix("chargeSocLimitSoc") {
                soc = Int(text.drop { !$0.isNumber }.prefix { $0.isNumber })
            } else if text.hasPrefix("}"), isManual, let soc {
                return soc
            }
        }
        return nil
    }

    private static func pmsetBattLimit() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Setting

    /// What `live()` should report once `percent` has taken effect.
    public static func expectedLive(for percent: Int) -> Int? {
        percent == noLimit ? nil : percent
    }

    /// Asks macOS to use this limit. Must run as root. macOS takes a minute or so to act on it,
    /// so this returns straight away: compare `live()` with `expectedLive(for:)` to confirm it.
    public static func request(_ percent: Int) throws {
        guard validRange.contains(percent) else { throw Failure.outOfRange(percent) }
        guard geteuid() == 0 else { throw Failure.needsRoot }
        guard let client = PowerUIClient() else { throw Failure.frameworkUnavailable }

        if percent == noLimit {
            writePreference(featureOn: false, limit: nil)
            client.disable()
        } else {
            if !client.isEnabled { client.enable() }
            writePreference(featureOn: true, limit: percent)
        }
    }

    private static func writePreference(featureOn: Bool, limit: Int?) {
        let domain = "com.apple.smartcharging.topoffprotection" as CFString
        func set(_ key: String, _ value: Int) {
            CFPreferencesSetValue(key as CFString, value as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        set("MCLFeatureState", featureOn ? 1 : 0)
        if let limit { set("mclLimitValue", limit) }
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.apple.smartcharging.defaultschanged" as CFString),
            nil, nil, true
        )
    }
}

/// Thin wrapper over the private `PowerUISmartChargeClient` class. It is looked up at
/// run time, so a macOS update that removes it shows up as an error, not a crash at launch.
final class PowerUIClient {
    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject
    private typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
    private typealias ErrorFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    private typealias EnabledFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt64

    private let cls: AnyClass
    private let client: AnyObject

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let meta = object_getClass(cls),
              let allocIMP = class_getMethodImplementation(meta, NSSelectorFromString("alloc")),
              class_getInstanceMethod(cls, NSSelectorFromString("initWithClientName:")) != nil,
              let initIMP = class_getMethodImplementation(cls, NSSelectorFromString("initWithClientName:"))
        else { return nil }
        let alloc = unsafeBitCast(allocIMP, to: AllocFn.self)
        let initialize = unsafeBitCast(initIMP, to: InitFn.self)
        self.cls = cls
        self.client = initialize(alloc(cls, NSSelectorFromString("alloc")), NSSelectorFromString("initWithClientName:"), "ChargeKeeper")
    }

    var isEnabled: Bool {
        let selector = NSSelectorFromString("isMCLCurrentlyEnabled:")
        guard class_getInstanceMethod(cls, selector) != nil,
              let imp = class_getMethodImplementation(cls, selector) else { return false }
        var error: NSError?
        return unsafeBitCast(imp, to: EnabledFn.self)(client, selector, &error) != 0
    }

    func enable() { call("enableMCL:") }
    func disable() { call("disableMCL:") }

    private func call(_ name: String) {
        let selector = NSSelectorFromString(name)
        guard class_getInstanceMethod(cls, selector) != nil,
              let imp = class_getMethodImplementation(cls, selector) else { return }
        var error: NSError?
        _ = unsafeBitCast(imp, to: ErrorFn.self)(client, selector, &error)
    }
}
