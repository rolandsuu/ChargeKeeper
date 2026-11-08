import Foundation
import ServiceManagement
import Shared

/// Reads the battery directly, so the display keeps working even if the service is down.
private final class Reader: @unchecked Sendable {
    struct Fast {
        var battery: BatterySnapshot?
        var temperature: Double?
        var power: PowerFlow?
    }

    private let sensors = SensorReader()
    private let queue = DispatchQueue(label: "chargekeeper.app.reader")

    func readFast(_ completion: @escaping @Sendable (Fast) -> Void) {
        queue.async { [sensors] in
            let battery = BatterySnapshot.read()
            let power = battery.map {
                PowerFlow(
                    chargerSensorWatts: sensors?.chargerWatts(),
                    systemSensorWatts: sensors?.systemWatts(),
                    voltageMV: $0.voltageMV,
                    amperageMA: $0.amperageMA
                )
            }
            completion(Fast(battery: battery, temperature: sensors?.batteryTemperature(), power: power))
        }
    }

    func readLimit(_ completion: @escaping @Sendable (Int?) -> Void) {
        queue.async { completion(ChargeLimit.live()) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var battery: BatterySnapshot?
    @Published private(set) var temperature: Double?
    @Published private(set) var power: PowerFlow?
    /// What macOS itself reports. Nil means no limit is in force.
    @Published private(set) var liveLimit: Int?
    @Published private(set) var service: ServiceState?
    @Published private(set) var registration: SMAppService.Status = .notRegistered
    /// A command is on its way to the service.
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?

    private let client = ServiceClient()
    private let reader = Reader()
    private var timer: Timer?
    private var ticks = 0

    /// Whether this Mac has a MagSafe light that can be controlled.
    let hasMagSafeLight = MagSafeLight() != nil

    var serviceIsAvailable: Bool { service != nil }
    /// A new limit has been requested and macOS isn't reporting it yet.
    var isApplyingLimit: Bool { service?.pendingLimit != nil }

    func start() {
        guard timer == nil else { return }
        refreshFast()
        refreshSlow()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticks += 1
        refreshFast()
        if ticks % 3 == 0 { refreshSlow() }
    }

    private func refreshFast() {
        reader.readFast { result in
            Task { @MainActor [weak self] in
                self?.battery = result.battery
                self?.temperature = result.temperature
                self?.power = result.power
            }
        }
    }

    private func refreshSlow() {
        registration = client.registrationStatus
        reader.readLimit { limit in
            Task { @MainActor [weak self] in
                self?.liveLimit = limit
            }
        }
        guard registration == .enabled else {
            service = nil
            return
        }
        client.getState { result in
            Task { @MainActor [weak self] in
                self?.service = try? result.get()
            }
        }
    }

    // MARK: Commands

    private func perform(_ send: (@escaping (Error?) -> Void) -> Void) {
        isSending = true
        errorMessage = nil
        send { error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.isSending = false
                self?.errorMessage = message
                self?.refreshSlow()
            }
        }
    }

    func setLimit(_ percent: Int) {
        perform { client.setLimit(percent, $0) }
    }

    func setHeatProtection(enabled: Bool, threshold: Int) {
        perform { client.setHeatProtection(enabled: enabled, threshold: threshold, $0) }
    }

    func setChargeToFull(_ on: Bool) {
        perform { client.setChargeToFull(on, $0) }
    }

    func setMagSafeLight(visible: Bool) {
        perform { client.setMagSafeLight(visible: visible, $0) }
    }

    func installService() {
        errorMessage = nil
        do {
            try client.register()
        } catch {
            // macOS reports an error here while it waits for your approval, which isn't a failure.
            if client.registrationStatus != .requiresApproval {
                errorMessage = "Couldn't install the background service: \(error.localizedDescription)"
            }
        }
        if client.registrationStatus == .requiresApproval {
            client.openApprovalSettings()
        }
        refreshSlow()
    }

    func openApprovalSettings() {
        client.openApprovalSettings()
    }

    /// Replaces the service's launchd job, which clears a job launchd has given up starting.
    /// macOS refuses to register again straight after unregistering, so this waits in between.
    func restartService() {
        isSending = true
        errorMessage = nil
        do {
            try client.unregister()
        } catch {
            isSending = false
            errorMessage = "Couldn't restart the background service: \(error.localizedDescription)"
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            self?.isSending = false
            self?.installService()
        }
    }

    func removeService() {
        perform { [client] finished in
            client.prepareForRemoval { error in
                if let error {
                    finished(error)
                    return
                }
                do {
                    try client.unregister()
                    finished(nil)
                } catch {
                    finished(error)
                }
            }
        }
    }
}
