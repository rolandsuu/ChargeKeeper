import ServiceManagement
import Shared
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var ui = ViewState()

    var body: some View {
        Form {
            batterySection
            warningsSection
            limitSection
            heatSection
            magSafeSection
            powerSection
            healthSection
            serviceSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, maxWidth: 520, minHeight: 500, maxHeight: .infinity)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(model.$service) { service in
            guard let service, !ui.isDraggingLimit, !model.isSending else { return }
            ui.draftLimit = Double(service.settings.limit)
        }
    }

    // MARK: Battery

    /// macOS doesn't list the limit while unplugged, so the bar shows your saved one then.
    private var limitForDisplay: Int? {
        if model.battery?.isPluggedIn == false, let target = model.service?.targetLimit {
            return ChargeLimit.expectedLive(for: target)
        }
        return model.liveLimit
    }

    private var batterySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.battery.map { "\($0.percent)%" } ?? "–")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let battery = model.battery {
                    Text(statusLine(for: battery))
                        .foregroundStyle(.secondary)
                    BatteryBar(percent: battery.percent, limit: limitForDisplay)
                        .padding(.top, 4)
                } else {
                    Text("Battery information isn't available.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusLine(for battery: BatterySnapshot) -> String {
        let settings = model.service?.settings
        return StatusText.describe(
            battery: battery,
            limit: model.liveLimit,
            heatPauseLimit: model.service?.runtime.heatPauseLimit,
            chargingToFull: model.service?.runtime.chargingToFull ?? false,
            temperature: model.temperature,
            resumeTemperature: settings.map { Double($0.heatThreshold) - Policy.resumeMargin },
            batteryWatts: model.power?.batteryWatts
        )
    }

    // MARK: Warnings

    private var warnings: [String] {
        var result: [String] = []
        if let message = model.errorMessage { result.append(message) }
        if let message = model.service?.lastError, message != model.errorMessage { result.append(message) }
        if let battery = model.battery,
           StatusText.isChargingAboveLimit(battery: battery, limit: model.liveLimit, batteryWatts: model.power?.batteryWatts) {
            result.append("The battery is charging above the limit. macOS may be doing its occasional charge to 100%.")
        }
        return result
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Limit

    private var limitSection: some View {
        Section("Charge limit") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stop charging at")
                    Spacer()
                    Text(ui.draftLimit >= 100 ? "No limit" : "\(Int(ui.draftLimit))%")
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                // Rounding here rather than passing `step`, which would draw 90 tick marks.
                Slider(value: Binding(get: { ui.draftLimit }, set: { ui.draftLimit = $0.rounded() }), in: 10...100) { editing in
                    ui.isDraggingLimit = editing
                    if !editing { model.setLimit(Int(ui.draftLimit)) }
                }
                .labelsHidden()
                .disabled(!model.serviceIsAvailable || model.isSending)
                .accessibilityLabel("Charge limit")

                if let battery = model.battery, Int(ui.draftLimit) < battery.percent {
                    Text("Above this limit, the Mac runs on battery until it drains down to \(Int(ui.draftLimit))%, even when plugged in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if model.isApplyingLimit || model.isSending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Applying. macOS can take a minute or two.")
                        .foregroundStyle(.secondary)
                }
            }

            let chargingToFull = model.service?.runtime.chargingToFull ?? false
            Button(chargingToFull ? "Cancel charge to 100%" : "Charge to 100% once") {
                model.setChargeToFull(!chargingToFull)
            }
            .disabled(!model.serviceIsAvailable || model.isSending)
        }
    }

    // MARK: Heat

    private var heatSection: some View {
        Section("Heat protection") {
            let settings = model.service?.settings ?? ServiceSettings()
            Toggle("Pause charging when hot", isOn: Binding(
                get: { settings.heatEnabled },
                set: { model.setHeatProtection(enabled: $0, threshold: settings.heatThreshold) }
            ))
            .disabled(!model.serviceIsAvailable || model.isSending)

            Stepper(value: Binding(
                get: { settings.heatThreshold },
                set: { model.setHeatProtection(enabled: settings.heatEnabled, threshold: $0) }
            ), in: ServiceSettings.heatThresholdRange) {
                LabeledContent("Pause at", value: "\(settings.heatThreshold)°C")
            }
            .disabled(!model.serviceIsAvailable || model.isSending || !settings.heatEnabled)
        }
    }

    // MARK: MagSafe light

    @ViewBuilder
    private var magSafeSection: some View {
        if model.hasMagSafeLight {
            Section {
                let settings = model.service?.settings ?? ServiceSettings()
                Toggle("Show the MagSafe light", isOn: Binding(
                    get: { settings.showMagSafeLight },
                    set: { model.setMagSafeLight(visible: $0) }
                ))
                .disabled(!model.serviceIsAvailable || model.isSending)
            } header: {
                Text("MagSafe light")
            } footer: {
                Text("Off by default. When you plug in, the light may come on for a moment before it goes off.")
            }
        }
    }

    // MARK: Power

    private var powerSection: some View {
        Section("Power right now") {
            if let power = model.power {
                LabeledContent("From charger", value: Self.watts(power.chargerWatts))
                LabeledContent("Used by this Mac", value: Self.watts(power.systemWatts))
                LabeledContent("Battery", value: Self.batteryFlow(power.batteryWatts))
                if let adapter = model.battery?.adapterName {
                    LabeledContent("Charger", value: adapter)
                }
            } else {
                Text("Not available").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    private static func watts(_ value: Double) -> String {
        String(format: "%.1f W", value)
    }

    private static func batteryFlow(_ value: Double) -> String {
        if value > 0.5 { return "Charging at " + watts(value) }
        if value < -0.5 { return "Supplying " + watts(-value) }
        return "Idle"
    }

    // MARK: Health

    private var healthSection: some View {
        Section("Battery health") {
            if let battery = model.battery {
                LabeledContent("Capacity compared with new", value: battery.healthPercent.map { "\($0)%" } ?? "–")
                LabeledContent("Charge cycles", value: "\(battery.cycleCount)")
            }
            LabeledContent("Temperature", value: model.temperature.map { String(format: "%.1f°C", $0) } ?? "–")
        }
        .monospacedDigit()
    }

    // MARK: Service

    private var serviceSection: some View {
        Section("Background service") {
            switch model.registration {
            case .enabled where model.serviceIsAvailable:
                LabeledContent("Status", value: "Running")
                Button("Remove background service…", role: .destructive) {
                    ui.confirmingRemoval = true
                }
                .disabled(model.isSending)
                .confirmationDialog(
                    "Remove the background service?",
                    isPresented: $ui.confirmingRemoval
                ) {
                    Button("Remove", role: .destructive) { model.removeService() }
                } message: {
                    Text("Your charge limit stays in macOS, but heat protection stops. You can reinstall it from this window.")
                }
            case .enabled:
                LabeledContent("Status", value: "Not responding")
                Text("Your charge limit stays in place, but heat protection isn't running.")
                    .foregroundStyle(.secondary)
                Button("Restart background service") { model.restartService() }
                    .disabled(model.isSending)
            case .requiresApproval:
                LabeledContent("Status", value: "Waiting for your approval")
                Button("Open System Settings") { model.openApprovalSettings() }
            default:
                LabeledContent("Status", value: "Not installed")
                Text("Needed to change the limit and for heat protection. It runs in the background, whether this window is open or not.")
                    .foregroundStyle(.secondary)
                Button("Install background service") { model.installService() }
            }
        }
    }
}

/// The window's own state. It's kept in an object rather than in `@State` properties, because
/// `@State` is a macro in the macOS 27 SDK and only Xcode, not the Command Line Tools, can expand it.
private final class ViewState: ObservableObject {
    @Published var draftLimit: Double = 80
    @Published var isDraggingLimit = false
    @Published var confirmingRemoval = false
}

/// The charge level, with a marker where the limit sits.
private struct BatteryBar: View {
    let percent: Int
    let limit: Int?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.green)
                    .frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                if let limit {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: 16)
                        .offset(x: geometry.size.width * CGFloat(limit) / 100 - 1)
                }
            }
        }
        .frame(height: 10)
        .padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}
