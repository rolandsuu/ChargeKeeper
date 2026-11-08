import Foundation
import ServiceManagement
import Shared

/// Registers the background service and talks to it over XPC.
final class ServiceClient {
    enum Failure: LocalizedError {
        case unreachable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason): return "Couldn't reach the background service: \(reason)"
            case .refused(let reason): return reason
            }
        }
    }

    private var service: SMAppService { SMAppService.daemon(plistName: Identity.servicePlistName) }

    var registrationStatus: SMAppService.Status { service.status }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: Identity.serviceIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ChargeKeeperServiceProtocol.self)
        connection.setCodeSigningRequirement(Identity.serviceRequirement)
        connection.resume()
        return connection
    }

    /// Lets exactly one of a reply, an error or a timeout finish a request.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Runs one request. If launchd can't start the service, a message to it waits forever without
    /// an error, so every request has a timeout. `body` must call `claim` when its reply arrives,
    /// and carry on only if that returns true.
    private func request(
        timeout: TimeInterval,
        failed: @escaping (Error) -> Void,
        _ body: @escaping (ChargeKeeperServiceProtocol, @escaping () -> Bool) -> Void
    ) {
        let connection = connect()
        let once = Once()
        let claim = { () -> Bool in
            guard once.claim() else { return false }
            connection.invalidate()
            return true
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            if claim() { failed(Failure.unreachable(error.localizedDescription)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if claim() { failed(Failure.unreachable("it isn't responding.")) }
        }
        guard let service = proxy as? ChargeKeeperServiceProtocol else {
            if claim() { failed(Failure.unreachable("unexpected interface.")) }
            return
        }
        body(service, claim)
    }

    /// Runs a command whose reply is an error message or nil.
    private func command(
        timeout: TimeInterval = 15,
        _ completion: @escaping (Error?) -> Void,
        _ send: @escaping (ChargeKeeperServiceProtocol, @escaping (String?) -> Void) -> Void
    ) {
        request(timeout: timeout, failed: { completion($0) }) { service, claim in
            send(service) { message in
                guard claim() else { return }
                completion(message.map(Failure.refused))
            }
        }
    }

    func getState(_ completion: @escaping (Result<ServiceState, Error>) -> Void) {
        request(timeout: 5, failed: { completion(.failure($0)) }) { service, claim in
            service.getState { data in
                guard claim() else { return }
                if let state = try? JSONDecoder().decode(ServiceState.self, from: data) {
                    completion(.success(state))
                } else {
                    completion(.failure(Failure.unreachable("unreadable reply.")))
                }
            }
        }
    }

    func setLimit(_ percent: Int, _ completion: @escaping (Error?) -> Void) {
        command(completion) { $0.setLimit(percent, reply: $1) }
    }

    func setHeatProtection(enabled: Bool, threshold: Int, _ completion: @escaping (Error?) -> Void) {
        command(completion) { $0.setHeatProtection(enabled: enabled, threshold: threshold, reply: $1) }
    }

    func setChargeToFull(_ on: Bool, _ completion: @escaping (Error?) -> Void) {
        command(completion) { $0.setChargeToFull(on, reply: $1) }
    }

    func setMagSafeLight(visible: Bool, _ completion: @escaping (Error?) -> Void) {
        command(completion) { $0.setMagSafeLight(visible: visible, reply: $1) }
    }

    /// This waits for macOS to confirm your limit, so it's allowed much longer than other commands.
    func prepareForRemoval(_ completion: @escaping (Error?) -> Void) {
        command(timeout: 200, completion) { $0.prepareForRemoval(reply: $1) }
    }
}
