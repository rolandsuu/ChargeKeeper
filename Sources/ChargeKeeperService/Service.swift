import Foundation
import Shared

/// The root service: keeps Apple's limit where it should be, pauses charging when hot, and keeps
/// the MagSafe light off if you've chosen that. It never touches anything else, and the app can
/// only reach it through the commands below.
final class Service: NSObject, ChargeKeeperServiceProtocol {
    private static let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/ChargeKeeper")
    private static let stateFile = stateDirectory.appendingPathComponent("state.json")
    private static let cycle: TimeInterval = 30
    /// macOS can sit on a lowered limit for minutes, but tends to act soon after it's written again.
    private static let rewriteInterval: TimeInterval = 90
    /// Only after this long is a limit reported as not applied.
    private static let applyTimeout: TimeInterval = 270

    private let work = DispatchQueue(label: "chargekeeper.service.work")
    private let lock = NSLock()
    private var state: ServiceState
    private var pendingSince: Date?
    private var lastWrite: Date?
    /// The limit macOS last confirmed while on the charger.
    private var confirmedLimit: Int?
    /// A limit sent while on battery, where macOS can't confirm it.
    private var sentOnBattery: Int?
    private var removed = false
    private var timer: DispatchSourceTimer?
    private let sensors = SensorReader()
    /// Nil on a Mac without a MagSafe light. Only used on the work queue.
    private let light = MagSafeLight()
    private let launchedBinaryDate = Service.binaryModificationDate()

    override init() {
        state = Service.loadState()
        super.init()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now(), repeating: Service.cycle)
        timer.setEventHandler { [weak self] in _ = self?.cycleOnce() }
        timer.resume()
        self.timer = timer
    }

    // MARK: Commands from the app

    func getState(reply: @escaping (Data) -> Void) {
        reply((try? JSONEncoder().encode(locked { state })) ?? Data())
    }

    func setLimit(_ percent: Int, reply: @escaping (String?) -> Void) {
        guard ChargeLimit.validRange.contains(percent) else {
            reply(ChargeLimit.Failure.outOfRange(percent).localizedDescription)
            return
        }
        change(reply: reply) { $0.settings.limit = percent }
    }

    func setHeatProtection(enabled: Bool, threshold: Int, reply: @escaping (String?) -> Void) {
        guard ServiceSettings.heatThresholdRange.contains(threshold) else {
            reply("\(threshold)°C is outside the allowed range.")
            return
        }
        change(reply: reply) {
            $0.settings.heatEnabled = enabled
            $0.settings.heatThreshold = threshold
        }
    }

    func setChargeToFull(_ on: Bool, reply: @escaping (String?) -> Void) {
        change(reply: reply) { $0.runtime.chargingToFull = on }
    }

    func setMagSafeLight(visible: Bool, reply: @escaping (String?) -> Void) {
        guard light != nil else {
            reply("This Mac doesn't have a MagSafe light ChargeKeeper can control.")
            return
        }
        change(reply: reply) { $0.settings.showMagSafeLight = visible }
    }

    /// Plugging in makes macOS light the MagSafe light again, and it's also when the limit can be
    /// confirmed again, so a cycle runs at once instead of waiting for the timer.
    func powerSourceChanged() {
        work.async { [self] in _ = cycleOnce() }
    }

    func prepareForRemoval(reply: @escaping (String?) -> Void) {
        work.async { [self] in
            timer?.cancel()
            let limit: Int = locked {
                removed = true
                return state.settings.limit
            }
            // Hand the light back to macOS. A failure here shouldn't block removal.
            if let light, light.current() == MagSafeLight.Mode.off.rawValue {
                do { try light.set(.system) } catch { NSLog("ChargeKeeper: \(error.localizedDescription)") }
            }
            let wanted = ChargeLimit.expectedLive(for: limit)
            do {
                if ChargeLimit.live() != wanted {
                    try ChargeLimit.request(limit)
                    let deadline = Date().addingTimeInterval(Service.applyTimeout)
                    var written = Date()
                    while ChargeLimit.live() != wanted, Date() < deadline {
                        Thread.sleep(forTimeInterval: 2)
                        if Date().timeIntervalSince(written) >= Service.rewriteInterval {
                            try ChargeLimit.request(limit)
                            written = Date()
                        }
                    }
                    guard ChargeLimit.live() == wanted else {
                        throw ChargeLimit.Failure.notApplied(wanted: limit, actual: ChargeLimit.live())
                    }
                }
                try? FileManager.default.removeItem(at: Service.stateDirectory)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    private func change(reply: @escaping (String?) -> Void, _ update: @escaping (inout ServiceState) -> Void) {
        work.async { [self] in
            locked {
                update(&state)
                saveState()
            }
            reply(cycleOnce())
        }
    }

    // MARK: The cycle

    /// Runs one cycle on the work queue. Returns an error message if the limit couldn't be requested
    /// or the MagSafe light couldn't be changed.
    private func cycleOnce() -> String? {
        if locked({ removed }) { return nil }
        exitIfUpdated()

        let battery = BatterySnapshot.read()
        let lightError = applyMagSafeLight(isPluggedIn: battery?.isPluggedIn ?? false)
        return applyLimit(battery: battery) ?? lightError
    }

    /// Call on the work queue. Writes only when the light doesn't already match the setting.
    private func applyMagSafeLight(isPluggedIn: Bool) -> String? {
        guard let light, let current = light.current() else { return nil }
        let showLight = locked { state.settings.showMagSafeLight }
        guard let mode = MagSafeLight.change(showLight: showLight, current: current, isPluggedIn: isPluggedIn) else {
            return nil
        }
        do {
            try light.set(mode)
            return nil
        } catch {
            NSLog("ChargeKeeper: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    private func applyLimit(battery: BatterySnapshot?) -> String? {
        let temperature = sensors?.batteryTemperature()

        let target: Int = locked {
            let next = Policy.next(
                settings: state.settings,
                runtime: state.runtime,
                percent: battery?.percent,
                isFullyCharged: battery?.isFullyCharged ?? false,
                temperature: temperature,
                isPluggedIn: battery?.isPluggedIn ?? false
            )
            if next != state.runtime {
                state.runtime = next
                saveState()
            }
            return state.targetLimit
        }

        // macOS only lists a limit while the charger is attached, so on battery there's nothing to
        // confirm. A changed limit is still sent once, so it's in place before you plug in.
        if battery?.isPluggedIn == false {
            let needsSending: Bool = locked {
                state.pendingLimit = nil
                state.lastError = nil
                pendingSince = nil
                lastWrite = nil
                return target != confirmedLimit && target != sentOnBattery
            }
            guard needsSending else { return nil }
            do {
                try ChargeLimit.request(target)
                locked { sentOnBattery = target }
                return nil
            } catch {
                let message = error.localizedDescription
                locked { state.lastError = message }
                return message
            }
        }

        let live = ChargeLimit.live()
        if live == ChargeLimit.expectedLive(for: target) {
            locked {
                state.pendingLimit = nil
                state.lastError = nil
                pendingSince = nil
                lastWrite = nil
                confirmedLimit = target
                sentOnBattery = nil
            }
            return nil
        }

        // A recent write for this same limit may still take effect, so leave it alone for now.
        let now = Date()
        let (pending, since, written): (Int?, Date?, Date?) = locked { (state.pendingLimit, pendingSince, lastWrite) }
        let isSameLimit = pending == target
        if isSameLimit, let written, now.timeIntervalSince(written) < Service.rewriteInterval {
            return nil
        }

        do {
            try ChargeLimit.request(target)
            locked {
                let timedOut = isSameLimit && since.map { now.timeIntervalSince($0) >= Service.applyTimeout } ?? false
                state.lastError = timedOut
                    ? ChargeLimit.Failure.notApplied(wanted: target, actual: live).localizedDescription
                    : nil
                state.pendingLimit = target
                pendingSince = isSameLimit ? since : now
                lastWrite = now
            }
            return nil
        } catch {
            let message = error.localizedDescription
            locked { state.lastError = message }
            return message
        }
    }

    /// After an update replaces the app, exit so launchd restarts the service on the new version.
    private func exitIfUpdated() {
        guard let launched = launchedBinaryDate, let current = Service.binaryModificationDate(), current != launched else { return }
        exit(0)
    }

    private static func binaryModificationDate() -> Date? {
        guard let path = Bundle.main.executablePath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: Saved state

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func loadState() -> ServiceState {
        guard let data = try? Data(contentsOf: stateFile),
              var saved = try? JSONDecoder().decode(ServiceState.self, from: data) else {
            // A fresh install adopts the limit already in macOS, so installing never changes it.
            var fresh = ServiceState()
            if let live = ChargeLimit.live() { fresh.settings.limit = live }
            return fresh
        }
        saved.pendingLimit = nil
        saved.lastError = nil
        return saved
    }

    /// Call while holding the lock. The file is root-owned and readable, but only root can change it.
    private func saveState() {
        guard !removed else { return }
        do {
            try FileManager.default.createDirectory(
                at: Service.stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            var saved = state
            saved.pendingLimit = nil
            saved.lastError = nil
            let data = try JSONEncoder().encode(saved)
            try data.write(to: Service.stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Service.stateFile.path)
        } catch {
            NSLog("ChargeKeeper: couldn't save state: \(error.localizedDescription)")
        }
    }
}
