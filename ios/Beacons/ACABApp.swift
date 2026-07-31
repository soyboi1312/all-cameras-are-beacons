import SwiftUI

/// App entry point. One BLEManager lives here and flows down as an environment object.
@main
struct ACABApp: App {
    @StateObject private var ble = BLEManager.shared
    @StateObject private var manifest = FirmwareManifestStore.shared
    @StateObject private var alpr = ALPRStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(manifest)
                .environmentObject(alpr)
                .preferredColorScheme(.dark)
                .tint(ACABTheme.red)
                .onAppear {
                    // Non-blocking: refresh the firmware manifest in the background so the
                    // Device screen can show the live "latest" and offer OTA when eligible.
                    manifest.refreshIfNeeded()
                    // Freshen the known-ALPR map layer only if the user opted in (no-op otherwise).
                    alpr.refresh()
                    #if DEBUG
                    // Launch with `-demo` in the scheme to load canned detections.
                    if ProcessInfo.processInfo.arguments.contains("-demo") { ble.seedDemoData() }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    // Back to the foreground: re-sync Drive mode with the system (the Control
                    // Center toggle or the Live Activity End button may have changed it).
                    if phase == .active { ble.reconcileDriveMode() }
                }
        }
    }
}
