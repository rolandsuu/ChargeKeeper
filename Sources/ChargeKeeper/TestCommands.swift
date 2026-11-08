#if CK_TEST_COMMANDS
import Foundation
import Shared

/// Command-line driver for test builds only (`scripts/build.sh --test`). It is compiled
/// out of the normal build so other programs can't drive the service through the app.
enum TestCommands {
    static func run(_ arguments: [String]) -> Never {
        let client = ServiceClient()
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        func finish(_ error: Error?, success: String) {
            if let error {
                print("ERROR: \(error.localizedDescription)")
                exitCode = 1
            } else {
                print(success)
            }
            done.signal()
        }

        func argument(_ index: Int) -> Int {
            guard arguments.count > index, let value = Int(arguments[index]) else {
                print("missing number")
                exit(2)
            }
            return value
        }

        switch arguments.first {
        case "register":
            do { try client.register(); print("registered") } catch { print("ERROR: \(error.localizedDescription)"); exitCode = 1 }
            print("status: \(client.registrationStatus.rawValue)")
            if client.registrationStatus == .requiresApproval { client.openApprovalSettings() }
            done.signal()
        case "unregister":
            do { try client.unregister(); print("unregistered") } catch { print("ERROR: \(error.localizedDescription)"); exitCode = 1 }
            done.signal()
        case "registration":
            print("status: \(client.registrationStatus.rawValue) (0 not registered, 1 enabled, 2 requires approval, 3 not found)")
            done.signal()
        case "state":
            client.getState { result in
                switch result {
                case .success(let state): print(String(decoding: try! JSONEncoder().encode(state), as: UTF8.self))
                case .failure(let error): print("ERROR: \(error.localizedDescription)"); exitCode = 1
                }
                done.signal()
            }
        case "set-limit":
            let value = argument(1)
            client.setLimit(value) { finish($0, success: "requested \(value)") }
        case "heat":
            let value = argument(1)
            client.setHeatProtection(enabled: true, threshold: value) { finish($0, success: "heat protection at \(value)") }
        case "heat-off":
            client.getState { result in
                let threshold = (try? result.get().settings.heatThreshold) ?? 35
                client.setHeatProtection(enabled: false, threshold: threshold) { finish($0, success: "heat protection off") }
            }
        case "full":
            client.setChargeToFull(true) { finish($0, success: "charging to full") }
        case "full-cancel":
            client.setChargeToFull(false) { finish($0, success: "cancelled") }
        case "light-on":
            client.setMagSafeLight(visible: true) { finish($0, success: "MagSafe light on") }
        case "light-off":
            client.setMagSafeLight(visible: false) { finish($0, success: "MagSafe light off") }
        case "prepare-removal":
            client.prepareForRemoval { finish($0, success: "ready for removal") }
        default:
            print("commands: register, unregister, registration, state, set-limit N, heat N, heat-off, full, full-cancel, light-on, light-off, prepare-removal")
            exit(2)
        }

        if done.wait(timeout: .now() + 200) == .timedOut {
            print("ERROR: timed out")
            exit(1)
        }
        exit(exitCode)
    }
}
#endif
