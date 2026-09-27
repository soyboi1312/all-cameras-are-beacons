import SwiftUI

/// App entry point. One BLEManager lives here and flows down as an environment object.
@main
struct ACABApp: App {
    @StateObject private var ble = BLEManager.shared
    @StateObject private var manifest = FirmwareManifestStore.shared
    @StateObject private var alpr = ALPRStore.shared
    @StateObject private var contrast = ContrastPreference.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(manifest)
                .environmentObject(alpr)
                .environmentObject(contrast)
                // Puts the "always use higher contrast" trait override on the window as soon as
                // the window exists; the colours themselves read the trait (see ACABTheme).
                .background(WindowTraitApplier())
                .preferredColorScheme(.dark)
                .tint(ACABTheme.tint)
                .onAppear {
                    // Non-blocking: refresh the firmware manifest in the background so the
                    // Device screen can show the live "latest" and offer OTA when eligible.
                    manifest.refreshIfNeeded()
                    // Freshen the known-ALPR map layer while it is enabled (the default;
                    // a no-op for users who explicitly turned the layer off).
                    alpr.refresh()
                    #if DEBUG
                    // Launch with `-demo` in the scheme to load canned detections.
                    let args = ProcessInfo.processInfo.arguments
                    let demo = args.contains("-demo")
                    // `-boardKind ouiSpy|meshDetect` names the board kind for screenshots: a
                    // display-only remembered row, or with `-demo` the sample frame's label.
                    // Applied before the seed below, which reads it.
                    if let kind = boardKindLaunchArgument(args) {
                        ble.applyDebugBoardKind(kind, demo: demo)
                    }
                    if demo {
                        ble.seedDemoData(showTour: false)
                    }
                    // `-bluetoothIdle` (simulator startup-screen shots) is not parsed here: it has
                    // to act before the manager would create its CBCentralManager, so BLEManager
                    // reads it when it is built (BLEManager.debugBluetoothIdleAtLaunch).
                    #endif
                    // Cold launch: reconcile here too, not only from the scenePhase change below.
                    // This is the launch that has to RESUME Drive mode after a force-quit, and
                    // onChange fires only on a transition, so leaning on it alone would make the
                    // resume depend on SwiftUI delivering .inactive before .active. Harmless
                    // twice over: startDriveMode adopts an already-running activity rather than
                    // opening a second one, and if this call is too early for iOS to permit a
                    // start, the .active pass below retries.
                    ble.reconcileDriveMode()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Back to the foreground: re-sync Drive mode with the system (the Control
                    // Center toggle or the Live Activity End button may have changed it), and
                    // resume it if the user never turned it off (see DriveModeState).
                    if phase == .active { ble.reconcileDriveMode() }
                }
        }
    }
}
