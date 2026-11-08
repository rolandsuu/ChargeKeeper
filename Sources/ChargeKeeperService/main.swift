import Foundation
import IOKit.ps
import Shared

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: Service

    init(service: Service) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ChargeKeeperServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let service = Service()
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: Identity.serviceIdentifier)
// Connections from anything other than ChargeKeeper signed with your certificate are refused.
listener.setConnectionCodeSigningRequirement(Identity.clientRequirement)
listener.delegate = delegate
listener.resume()
service.start()

// Hear about plugging in and charging changes straight away, rather than at the next cycle.
if let source = IOPSNotificationCreateRunLoopSource({ _ in service.powerSourceChanged() }, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}
RunLoop.main.run()
