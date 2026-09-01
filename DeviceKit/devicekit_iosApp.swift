import SwiftUI
import UIKit
import AVFoundation

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 1. Prevent screen from dimming/sleeping during testing
        UIApplication.shared.isIdleTimerDisabled = true

        // 2. Start silent audio loop to guarantee continuous background runtime (0% CPU)
        SilentAudioQueue.sharedInstance().start()

        // 3. Start WebSocket RPC & Fake WDA server on 0.0.0.0:8100 with TCP_NODELAY
        AgentWebSocketServer.sharedInstance().startServer(onPort: 8100)

        return true
    }
}

@main
struct DeviceKitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
