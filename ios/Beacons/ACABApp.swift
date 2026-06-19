import SwiftUI

/// App entry point. One BLEManager lives here and flows down as an environment object.
@main
struct ACABApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
                .tint(ACABTheme.red)
                .onAppear {
                    #if DEBUG
                    // Launch with `-demo` in the scheme to load canned detections.
                    if ProcessInfo.processInfo.arguments.contains("-demo") { ble.seedDemoData() }
                    #endif
                }
        }
    }
}
