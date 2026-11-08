import AppKit
import SwiftUI

/// Closing the window quits the app. The background service carries on regardless.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ChargeKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ChargeKeeper", id: "main") {
            ContentView()
        }
        .defaultSize(width: 440, height: 780)
        .windowResizability(.contentSize)
    }
}
