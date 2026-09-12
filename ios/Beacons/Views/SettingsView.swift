import SwiftUI
import UIKit

/// A retained/key-mismatched log must remain erasable even when offline capture is switched off.
func shouldOfferBufferClear(isDemoMode: Bool, bufferOn: Bool, bufferedCount: Int,
                            keyMismatch: Bool, wiping: Bool) -> Bool {
    !isDemoMode && (bufferOn || bufferedCount > 0 || keyMismatch || wiping)
}

struct BufferClearConfirmationCopy: Equatable {
    let title: String
    let message: String
}

func bufferClearConfirmationCopy(bufferedCount: Int,
                                 keyMismatch: Bool) -> BufferClearConfirmationCopy {
    if keyMismatch {
        return BufferClearConfirmationCopy(
            title: "Erase the board’s retained offline history and transfer future buffering to this phone?",
            message: "This permanently erases the board’s preserved offline history. Any history only readable by the originating phone will be permanently lost. The app will then install this phone’s buffer key for future offline transfers.")
    }
    return BufferClearConfirmationCopy(
        title: "Erase \(bufferedCount) buffered detection\(bufferedCount == 1 ? "" : "s") on the board?",
        message: "This permanently wipes the board's offline log and can't be undone. Detections already synced to this phone stay in your log; anything not yet synced is lost.")
}

/// The Desert card's still-silent notice, byte-identical to the Android twin
/// (DESERT_SILENCE_NOTICE in DeviceScreen.kt). Named so a test can pin the bytes.
let desertSilenceNotice =
    "alerts are still silent after desert mode. they stay that way until you turn sound back on in alerts."

/// The offer that replaces that notice when the app is holding a mode to give back, byte-identical
/// to the Android twin (DESERT_RESTORE_OFFER in DeviceScreen.kt). Named so a test can pin the bytes.
///
/// It says "your alert mode is still silent", not "the board is quiet", on purpose. The mode is a
/// fact this app owns and can always assert truthfully. Whether the BOARD is actually quiet is a
/// different question, and reconcileBuzzer has a terminal state where the answer is no: the board
/// refuses the mute and keeps beeping while the mode reads Silent. A sentence about the mode stays
/// true there; a sentence about sound would not.
let desertRestoreOffer =
    "desert mode ended on the beacon, so your alert mode is still silent. the app does not change it on its own. restore alerts puts back the mode you had before desert mode."

/// The label on the control that sentence names. Uppercase pill, same anatomy as ERASE.
let desertRestoreOfferAction = "RESTORE ALERTS"

/// Show the still-silent notice when Desert mode has ended and alerts stayed silent, so silence
/// does not read as a broken detector.
///
/// `sawDesertOn` is "the BOARD reported Desert on at least once this app run"
/// (BLEManager.desertRanThisRun), NOT the saved restore token. The token answers a DIFFERENT
/// question - "did this app capture a mode it owes back" - and the two come apart in both
/// directions, so it cannot stand in for this one. THE THREE STATES, so no reading of this is left
/// to inference:
///  1. A phone that never enabled Desert itself (first pair with a board already in Desert, or a
///     second paired phone) has no token and is exactly the owner who needs the notice; its alert
///     mode reads Silent because reconcileBuzzer followed the muted board down.
///  2. A phone that enabled Desert AND saw the board end it gets a restore or an offer, both of
///     which the slot below carries instead of this sentence. Both halves of that token persist,
///     so a relaunch does not lose the offer.
///  3. A phone that captured a mode but whose run NEVER saw the board report Desert on gets
///     nothing here, which the earlier wording of this paragraph denied. It is reachable: quit the
///     app while Desert is running and come back to a board that is off, gone, or already out of
///     Desert - reconcileDesert's off-branch is guarded by desertSeenOn, so it arms no offer, and
///     this flag never goes true either. The token is still held and still spends correctly later
///     (the next user-ended Desert restores it, the next board-ended one offers it back), but this
///     run says nothing, and the honest reason is that the app cannot tell that silence apart from
///     a Silent the user chose: it has no in-run evidence of a Desert run at all.
/// Gating on "saw Desert on this run" is also what keeps the notice away from a user who chose
/// silence deliberately and never used Desert.
///
/// `isMeshDetect` is a narrowing of that rule, not part of it: the Alerts row is not rendered on a
/// mesh-detect board (hardwareConfigPanel skips it, and reconcileBuzzer bails on that board type
/// because it has no buzzer hardware), so "turn sound back on in alerts" would name a control its
/// owner cannot reach. The case is reachable rather than dead: mesh-detect runs the shared BLE
/// service and persists its own Desert default (acabBleBegin + desertRestoreEnabled(false) in
/// firmware/src/mesh-detect/main.cpp), and the Desert row is NOT gated on the board type.
///
/// Android twin: shouldShowDesertSilenceNotice in DeviceScreen.kt, same four inputs.
func shouldShowDesertSilenceNotice(sawDesertOn: Bool, desertOn: Bool,
                                   alertsSilent: Bool, isMeshDetect: Bool) -> Bool {
    sawDesertOn && !desertOn && alertsSilent && !isMeshDetect
}

/// What the Desert card draws in its one silence slot.
/// Android twin: DesertSilenceSlot in DeviceScreen.kt.
enum DesertSilenceSlot: Equatable {
    case none
    case notice   // alerts are silent and the app is holding nothing for you
    case offer    // alerts are silent and the app has a mode to give back, one tap away
}

/// Pick the slot: PRECEDENCE ONLY, which is why it takes `noticeApplies` already decided rather
/// than re-deciding it. The OFFER OUTRANKS THE NOTICE and they never both draw: they are the same
/// message about the same silence, and the offer is the one with a way out of it.
///
/// That `noticeApplies` is a separate input is also where the mesh asymmetry lives. The notice's own
/// gate suppresses it on a mesh board because it names an Alerts row that board does not draw; the
/// offer never consults that gate, because it carries its own control right here on the Desert card,
/// and a mesh board is the one place the offer is the ONLY way back to a mode, since its owner
/// cannot open Alerts and pick one by hand at all.
///
/// WHICH STATES STILL REACH `.notice` once a hand-picked Silent clears the saved mode: (1) a phone
/// that never enabled Desert itself and followed the muted board down to Silent, which is the report
/// the notice was built for and where it is plainly true; (2) the user chose Silent themselves,
/// before Desert, during it, or after declining the offer. In (2) the sentence is still true in
/// every clause, but "after desert mode" reads as a cause when the cause was the user. That was true
/// before this change too; what this change does is take the one state where the app owes something
/// out of the notice's hands entirely. The wording is deliberately left alone: on a detector,
/// over-reporting silence is the safe direction to err, and rewording a sentence that is true in
/// every state it can still reach would be churn.
///
/// AFTER A RELAUNCH the offer comes back (it is persisted) and this function's `sawDesertOn` does
/// not (it is per-run, see BLEManager.desertRanThisRun for why that asymmetry is deliberate). The
/// card is coherent anyway, because `.offer` never consults `noticeApplies`: the offer's own
/// sentence names the cause and carries the way out, so it explains itself with nothing under it.
/// The one visible difference is arm (2) above, and only the decline half of it: hand-picking
/// Silent to turn the offer down shows the notice in the run the board ended Desert in, and shows
/// nothing after a relaunch. That is the arm this comment already calls the weaker one.
func desertSilenceSlot(restoreOffered: Bool, noticeApplies: Bool) -> DesertSilenceSlot {
    if restoreOffered { return .offer }
    return noticeApplies ? .notice : .none
}

/// Does the offer need a home OUTSIDE the board-gated hardware panel right now?
///
/// Both of its usual homes (the Desert card's silence slot and the Alerts card) live inside that
/// panel, and the panel goes unusable as one unit when the board is away: iOS `.disabled`s it, and
/// a SwiftUI disable propagates down with no way for a child to opt out, while Android's fold rows
/// COLLAPSE, so the offer is not merely untappable there, it stops drawing. A board reboot or a
/// factory reset is exactly what arms the offer, so that is the wrong moment to take the way back
/// away, and nothing about taking it needs the board: the alert mode is a phone preference, and the
/// board write it also does is the same one any offline mode pick makes.
///
/// The result is the NEGATION of the panel's own gate, so the detached copy and a usable in-panel
/// copy can never draw at the same time. Android twin: desertRestoreNeedsDetachedSurface in
/// DeviceScreen.kt.
func desertRestoreNeedsDetachedSurface(restoreOffered: Bool, boardControlsAvailable: Bool) -> Bool {
    restoreOffered && !boardControlsAvailable
}

/// Does the PRE-CONNECT screen have to carry the offer?
///
/// `desertRestoreNeedsDetachedSurface` above covers the board going away while the Beacon screen
/// is still on the phone. This covers the case UNDER that one: with no usable session and no
/// reconnect running over a shell that already mounted, RootView draws ConnectView OVER the tab
/// shell, and either never mounts that shell at all or keeps it mounted with its opacity at zero,
/// its hit testing off and its accessibility hidden, so DeviceView is not reachable and every other
/// home of the offer is off screen.
/// That is the exact state the durability work was built for, because the board ending Desert is
/// usually a reboot or a factory reset, and the next thing the owner does is relaunch to a board
/// that is off or gone. Before this surface existed that owner saw nothing, and alerts stayed
/// silent with no way back on screen.
///
/// `mainShellVisible` is RootView's own `mainIsUsable`, so this is the NEGATION of the condition
/// that draws the tab shell, exactly as the detached gate is the negation of the hardware panel's.
/// The two surfaces therefore never draw together: the pre-connect copy needs the shell gone, and
/// the detached copy needs it there. It is decided in RootView rather than inside ConnectView
/// because RootView is the one view that is composed in BOTH states, so `mainShellVisible` is a
/// real input here and not a constant.
///
/// Android twin: desertRestoreNeedsPreConnectSurface in DeviceScreen.kt, called from AcabApp.
func desertRestoreNeedsPreConnectSurface(restoreOffered: Bool, mainShellVisible: Bool) -> Bool {
    restoreOffered && !mainShellVisible
}

/// Is the app holding a mode to give back right now? NEVER during the sample tour: the offer
/// reports a real board's Desert run, and its control writes real alert state, while every
/// phone-owned setting in the tour is a preview. reconcileDesert only runs off real status frames,
/// so the tour cannot arm it either; this keeps an offer armed BEFORE the tour started from
/// appearing inside it. NO BOARD GATE, deliberately: the offer survives a relaunch and the board
/// being away, and the state that arms it is a board reboot or a factory reset.
///
/// ONE definition, because there are now two screens asking (DeviceView and the pre-connect
/// screen, through RootView). Written as a free function rather than a second computed property so
/// the sample-tour gate cannot be spelled two ways.
/// Android twin: alertRestoreIsOffered in DeviceScreen.kt.
func alertRestoreIsOffered(isDemoMode: Bool, pending: AlertMode?) -> Bool {
    !isDemoMode && pending != nil
}

/// The one-tap way out of a silence the app imposed and never asked about. Rendered in FOUR places
/// (the Desert card's silence slot, the Alerts card, the panel that leads the Beacon screen while
/// the board is away, and the panel that leads the pre-connect screen when there is no Beacon
/// screen at all) from this single definition, so no surface can word or wire the offer
/// differently. All four reach takePendingAlertModeRestore() through the one call below, which is
/// the only thing that takes it.
///
/// FOUR HERE, FIVE ON ANDROID, and the extra one is not drift: this shell stays mounted and visible
/// through an OTA reboot (RootView's mainIsUsable takes isRebootingForUpdate), so the third surface
/// covers that window here, while AcabApp hands the reboot a locked screen of its own and has to
/// carry the offer onto it.
///
/// faint text, like the notice it replaces: this is a state report with a control attached, not an
/// alarm. The control is accent-toned and pill-shaped, the same anatomy as ERASE.
///
/// It reads the manager from the environment rather than taking a closure so that the take stays a
/// single call site no matter how many surfaces draw it. Android passes the action in instead,
/// because its two screens live in different files.
/// Android twin: AlertRestoreOffer in DeviceScreen.kt.
struct AlertRestoreOffer: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(desertRestoreOffer)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.takePendingAlertModeRestore() } label: {
                Text(desertRestoreOfferAction)
                    .font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                    .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Puts back the alert mode you had before desert mode")
        }
    }
}

/// The offer as a card of its own, for the two surfaces that are not inside another card: the
/// panel that LEADS the Beacon screen while the board is away, and the panel that LEADS the
/// pre-connect screen when there is no Beacon screen. Same panel + ALERTS kicker on both, so the
/// owner meets the same card wherever the app has to hand it to them.
///
/// It leads both pages on purpose. A silence this app imposed is the one thing on either screen
/// that the app owes the user, so it outranks stats, readiness and the scan panel; and the offer
/// arms in states where the rest of the page is mostly greyed out or still searching.
/// Android twin: AlertRestorePanel in DeviceScreen.kt, which has THREE callers: its tab shell is
/// parked behind a locked wait screen during an OTA reboot, so AcabApp draws the panel there too.
struct AlertRestorePanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("ALERTS")
            AlertRestoreOffer()
        }
        .panel()
    }
}

/// Device tab: OUI-Spy hardware status, scan radios, and alert controls.
struct DeviceView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var manifest: FirmwareManifestStore
    var openDetectorsToken: Int = 0
    /// Observed directly (not injected) so this view renders in previews and tests that do not
    /// install the environment object.
    @ObservedObject private var contrast = ContrastPreference.shared

    @State private var master: Double = 72
    @State private var pendingVolume = false   // hold the slider at the user's value while dragging + until the board confirms
    @State private var flockOn = true
    @State private var droneOn = true
    // Body-cam CATEGORY. Seeded from the shipped firmware default (ON), like flock, drone and
    // glasses beside it, so the detectors kicker does not count one detector short and the switch
    // does not animate on when the first frame lands. Every target ships it on:
    // axonRestoreEnabled(true) in beacon-board/main.cpp and mesh-detect/main.cpp, and the `axon`
    // row of docs/ble-protocol.md. This is a placeholder only: sync() copies s.axon over it on
    // every status frame with nothing pending, so a board with the category genuinely off reads
    // off the moment it reports. DeviceStatus decodes an absent key as false, which is the wire
    // rule for a key the board writes on every frame (acab_ble_service.cpp doc["axon"]), so no
    // supported firmware reaches the app through that default.
    @State private var bodyCamOn = true
    @State private var trackerOn = false
    @State private var glassesOn = true
    @State private var droneOuiOn = false        // drone vendor-OUI fallback; sub-option of droneOn, off by default
    @State private var netcamOn = false          // network-camera detector; opt-in, off by default (like droneOui)
    // Broad Motorola-OUI match, sub-option of bodyCamOn. Firmware ships it OFF on every detector
    // target (policeRestoreEnabled(false) in beacon-board and mesh-detect main.cpp; the `motorola`
    // row of docs/ble-protocol.md), so the seed matches a fresh board. The seed is a placeholder
    // either way: sync() copies ble.motorolaOn over it whenever a status frame exists, and the
    // control renders only while ble.motorolaSupported is set (a frame carried "moto", or the
    // sample tour forced it).
    @State private var motorolaOn = false
    @State private var pendingFlock = false     // just flipped; hold the value until the board confirms
    @State private var pendingDrone = false
    @State private var pendingDroneOui = false
    @State private var pendingTracker = false
    @State private var pendingBodyCam = false
    @State private var pendingMotorola = false
    @State private var pendingGlasses = false
    @State private var pendingNetcam = false
    @State private var bleOn = true
    @State private var wifiOn = true
    @State private var wifiEco = 0             // WiFi eco sleep seconds (0/3/7/15); battery SKU only
    @State private var pendingWifiEco = false
    @State private var pendingBle = false      // just flipped; hold until the board confirms
    @State private var pendingWifi = false
    @State private var bufferOn = false
    @State private var pendingBuffer = false   // just flipped; hold until the board confirms
    @State private var lightsOut = false       // "lights out": board LED fully dark
    @State private var pendingLed = false
    @State private var desertOn = false
    @State private var pendingDesert = false
    @State private var confirmEraseBuffer = false   // gate the destructive board-buffer erase
    @State private var confirmPowerOff = false      // gate the rev-B app-driven power-off
    @State private var checkingForUpdate = false    // manual "check for updates" spinner
    @State private var justChecked = false          // brief "checked" confirmation state
    // Rename flow for a watched (starred) device.
    @State private var renameMac: String?
    @State private var renameText = ""
    /// Which list the pencil was tapped in. One alert serves both cards; without this the Save
    /// button would always call renameWatched and silently no-op on an ignored device.
    @State private var renameIsIgnored = false
    // A board write is optimistic, but never indefinite: each toggle gets ten seconds for the
    // status stream to echo the requested value. If that never happens, put the control back on
    // the latest board value and explain the failure instead of leaving a convincing green lie.
    @State private var pendingWriteTokens: [PendingControl: UUID] = [:]
    @State private var configError: String?
    @State private var systemPermissionRevision = 0
    // T5: regular width lays the cards out two-up; compact stays a single column.
    @Environment(\.horizontalSizeClass) private var hSize
    // Accessibility text sizes stack the hero and stat rows vertically and pad the scroll
    // bottom; the default layout is untouched.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum PendingControl: Hashable {
        case volume, flock, drone, droneOui, bodyCam, motorola, tracker, glasses, netcam
        case ble, wifi, wifiEco, buffer, led, desert

        var label: String {
            switch self {
            case .volume: return "volume"
            case .flock: return "ALPR detector"
            case .drone: return "drone detector"
            case .droneOui: return "non-broadcasting drone detector"
            case .bodyCam: return "body-camera detector"
            case .motorola: return "Motorola radio detector"
            case .tracker: return "tracker detector"
            case .glasses: return "recording-glasses detector"
            case .netcam: return "network-camera detector"
            case .ble: return "Bluetooth scanning"
            case .wifi: return "Wi-Fi scanning"
            case .wifiEco: return "Wi-Fi eco mode"
            case .buffer: return "offline buffer"
            case .led: return "board LED"
            case .desert: return "Desert mode"
            }
        }
    }

    private var clearBufferConfirmationCopy: BufferClearConfirmationCopy {
        bufferClearConfirmationCopy(
            bufferedCount: ble.status?.bufCount ?? 0,
            keyMismatch: ble.status?.bufferKeyMismatch == true)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // This read is what makes the foreground permission bump repaint the view: SwiftUI
                // never invalidates for a @State the body does not read, and the blocked warnings
                // render off notifier.mutedBySystem / liveActivitiesEnabled, plain cached vars
                // with no publisher of their own.
                let _ = systemPermissionRevision
                ACABTheme.bg.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                        if hSize == .regular {
                            // The page header, hero, and fault/firmware banners span the full width.
                            // Hardware and phone preferences then get one column each: scope is
                            // visible without making a user infer it from what a toggle happens to do.
                            VStack(alignment: .leading, spacing: 16) {
                                header
                                deviceHero
                                if coprocFault { coprocFaultBanner } else if nrfUpdating { nrfUpdatingBanner }
                                if let promotion = firmwarePromotion { firmwareBanner(promotion) }
                                // Full width and above the split, the same position Android draws
                                // it in (above its own twoCol branch). Putting it in the hardware
                                // column instead would make a silence the app imposed half a page
                                // wide beside the stats, and it is not board hardware anyway: the
                                // alert mode is a phone preference.
                                if desertRestoreNeedsDetachedSurface(
                                    restoreOffered: alertRestoreOffered,
                                    boardControlsAvailable: hardwareControlsEnabled) {
                                    AlertRestorePanel()
                                }
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        statsGrid
                                        configurationGroupHeader(
                                            "BEACON HARDWARE",
                                            "Configure board scanning, alerts, light, offline buffer, and firmware.")
                                        if !hardwareControlsEnabled { hardwareControlsUnavailable }
                                        hardwareConfigPanel
                                        managedDevicesRow
                                        // Present on iPad the same as compact: this row was
                                        // simply missing from the regular-width split, so the
                                        // whole contribute feature did not exist on iPad.
                                        if improveDetectionAvailable(isSessionReady: ble.sessionReady,
                                                                     isDemoMode: ble.demoMode) {
                                            helpImproveRow
                                        }
                                        helpSupportRow
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    VStack(alignment: .leading, spacing: 14) {
                                        configurationGroupHeader(
                                            "THIS \(thisDeviceName.uppercased())",
                                            "Notifications, Live Mode, and display preferences for this \(thisDeviceName).")
                                        phoneConfigPanel
                                        disconnectButton
                                        if showPowerOff { powerOffButton }
                                        aboutFooter
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: 1000)
                            .frame(maxWidth: .infinity)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                settingsCards
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                        }
                    }
                        .padding(.horizontal, ACABTheme.pad)
                        .padding(.top, 8)
                    }
                    // Extra bottom margin only at accessibility sizes, so grown content never ends
                    // under the tab bar; zero at default sizes (layout untouched).
                    .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
                    .onChange(of: openDetectorsToken, initial: true) { _, token in
                        guard token > 0 else { return }
                        openSection = .detectors
                        // The tab switch and disclosure expansion happen in this update. Scroll on
                        // the next run loop so the row has its final position before targeting it.
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(ConfigSection.detectors, anchor: .top)
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .confirmationDialog(
                clearBufferConfirmationCopy.title,
                isPresented: $confirmEraseBuffer, titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive) { ble.clearBufferLog() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearBufferConfirmationCopy.message)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: ble.status) { _, _ in sync() }
        // "moto" lives outside DeviceStatus, so a frame that changed only the Motorola sub-toggle
        // (the board echoing our write back) wouldn't move `status` and wouldn't clear the pending
        // hold. Watch it directly.
        .onChange(of: ble.motorolaOn) { _, _ in sync() }
        // DetectionNotifier refreshes its cached authorization on foreground, but it is not an
        // ObservableObject itself, so this view must nudge itself. Issue the refresh ourselves
        // (cheap, idempotent, and it also covers activations without a willEnterForeground, like
        // dismissing Control Center); the completion runs after the notifier's cache is written,
        // so the revision bump re-renders against real state, never a stale cache.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ble.notifier.refreshAuthorization {
                systemPermissionRevision &+= 1
            }
        }
        .alert("Couldn't apply setting", isPresented: Binding(
            get: { configError != nil },
            set: { if !$0 { configError = nil } }
        )) {
            Button("OK") { configError = nil }
        } message: {
            Text(configError ?? "The beacon did not confirm that change.")
        }
    }

    // copy board state into local UI vars; runs on appear and on every status update
    private func sync() {
        guard let s = ble.status else { return }
        // Hold the slider at the user's value while dragging + until the board echoes it back, so a
        // status frame mid-drag can't snap it to the board's stale volume (same idea as the toggles).
        if pendingVolume { if s.volume == Int(master.rounded()) { pendingVolume = false; confirm(.volume) } } else { master = Double(s.volume) }
        // Hold a just-toggled switch at the user's value until the board confirms it,
        // so the ~5s status frame can't snap it back to off before then.
        if pendingFlock { if s.flock == flockOn { pendingFlock = false; confirm(.flock) } } else { flockOn = s.flock }
        if pendingDrone { if s.drone == droneOn { pendingDrone = false; confirm(.drone) } } else { droneOn = s.drone }
        if pendingDroneOui { if s.droui == droneOuiOn { pendingDroneOui = false; confirm(.droneOui) } } else { droneOuiOn = s.droui }
        if pendingBodyCam { if s.axon == bodyCamOn { pendingBodyCam = false; confirm(.bodyCam) } } else { bodyCamOn = s.axon }
        // The Motorola sub-toggle rides "moto", which isn't part of DeviceStatus; BLEManager reads
        // it off the status frame, so mirror from there instead of `s`. Same hold-until-confirmed.
        if pendingMotorola { if ble.motorolaOn == motorolaOn { pendingMotorola = false; confirm(.motorola) } } else { motorolaOn = ble.motorolaOn }
        if pendingTracker { if s.tracker == trackerOn { pendingTracker = false; confirm(.tracker) } } else { trackerOn = s.tracker }
        if pendingGlasses { if s.glasses == glassesOn { pendingGlasses = false; confirm(.glasses) } } else { glassesOn = s.glasses }
        if pendingNetcam { if s.ncam == netcamOn { pendingNetcam = false; confirm(.netcam) } } else { netcamOn = s.ncam }
        if pendingBuffer { if s.bufferingOn == bufferOn { pendingBuffer = false; confirm(.buffer) } } else { bufferOn = s.bufferingOn }
        if pendingLed { if (!s.ledEnabled) == lightsOut { pendingLed = false; confirm(.led) } } else { lightsOut = !s.ledEnabled }
        if pendingDesert { if s.desertMode == desertOn { pendingDesert = false; confirm(.desert) } } else { desertOn = s.desertMode }
        // Scan radios get the same hold: a periodic status frame generated before the write
        // lands would otherwise snap the switch back, inviting a duplicate tap and write.
        if pendingBle { if s.ble == bleOn { pendingBle = false; confirm(.ble) } } else { bleOn = s.ble }
        if pendingWifi { if s.wifi == wifiOn { pendingWifi = false; confirm(.wifi) } } else { wifiOn = s.wifi }
        if pendingWifiEco { if s.wifiEco == wifiEco { pendingWifiEco = false; confirm(.wifiEco) } } else { wifiEco = s.wifiEco }
    }

    /// Arm a fresh deadline for one optimistic board write. The UUID makes an older deadline a
    /// no-op when the user changes the same control again before it fires.
    private func awaitConfirmation(_ control: PendingControl) {
        // Sample data never arms a deadline: demo writes echo synchronously into the canned
        // status at the writeConfig boundary, so there is nothing to wait for and no
        // connection failure to manufacture ten seconds later.
        if ble.demoMode {
            clearPendingFlag(control)
            return
        }
        let token = UUID()
        pendingWriteTokens[control] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard pendingWriteTokens[control] == token else { return }
            pendingWriteTokens.removeValue(forKey: control)
            revertPending(control)
            configError = "Couldn't apply \(control.label). The beacon didn't confirm the change within 10 seconds."
        }
    }

    private func confirm(_ control: PendingControl) {
        pendingWriteTokens.removeValue(forKey: control)
    }

    private func clearPendingFlag(_ control: PendingControl) {
        switch control {
        case .volume: pendingVolume = false
        case .flock: pendingFlock = false
        case .drone: pendingDrone = false
        case .droneOui: pendingDroneOui = false
        case .bodyCam: pendingBodyCam = false
        case .motorola: pendingMotorola = false
        case .tracker: pendingTracker = false
        case .glasses: pendingGlasses = false
        case .netcam: pendingNetcam = false
        case .ble: pendingBle = false
        case .wifi: pendingWifi = false
        case .wifiEco: pendingWifiEco = false
        case .buffer: pendingBuffer = false
        case .led: pendingLed = false
        case .desert: pendingDesert = false
        }
    }

    /// Reconcile the optimistic control with the newest status frame without sending another
    /// write. A retry is an explicit user choice, never an automatic write loop.
    private func revertPending(_ control: PendingControl) {
        let s = ble.status
        switch control {
        case .volume:    pendingVolume = false; if let s { master = Double(s.volume) }
        case .flock:     pendingFlock = false; if let s { flockOn = s.flock }
        case .drone:     pendingDrone = false; if let s { droneOn = s.drone }
        case .droneOui:  pendingDroneOui = false; if let s { droneOuiOn = s.droui }
        case .bodyCam:   pendingBodyCam = false; if let s { bodyCamOn = s.axon }
        case .motorola:  pendingMotorola = false; motorolaOn = ble.motorolaOn
        case .tracker:   pendingTracker = false; if let s { trackerOn = s.tracker }
        case .glasses:   pendingGlasses = false; if let s { glassesOn = s.glasses }
        case .netcam:    pendingNetcam = false; if let s { netcamOn = s.ncam }
        case .ble:       pendingBle = false; if let s { bleOn = s.ble }
        case .wifi:      pendingWifi = false; if let s { wifiOn = s.wifi }
        case .wifiEco:   pendingWifiEco = false; if let s { wifiEco = s.wifiEco }
        case .buffer:    pendingBuffer = false; if let s { bufferOn = s.bufferingOn }
        case .led:       pendingLed = false; if let s { lightsOut = !s.ledEnabled }
        case .desert:    pendingDesert = false; if let s { desertOn = s.desertMode }
        }
    }

    // MARK: 1g composition
    // Three content classes: glanceable state stays open (hero + trimmed stats), firmware promotes
    // when it needs attention, and configuration is explicitly split between board hardware and
    // this phone. One shared openSection still guarantees a single disclosure across both groups.
    @ViewBuilder
    private var settingsCards: some View {
        header
        deviceHero
        if coprocFault { coprocFaultBanner }        // dual-radio nRF fault, right under the hero
        else if nrfUpdating { nrfUpdatingBanner }   // same slot, but the nRF is down on purpose
        if let promotion = firmwarePromotion { firmwareBanner(promotion) }
        // THE ONE CARD THAT OUTRANKS THE PAGE. Both of the offer's in-card homes live inside
        // hardwareConfigPanel, which is `.disabled` as one unit when the board is away, and a
        // SwiftUI disable propagates down with no way for a child to opt out; so while that gate is
        // shut this panel is the only reachable copy. It LEADS, above the stats and above the
        // hardware group, because a silence this app imposed is the one thing on the page the app
        // owes the user. Android draws the same card in the same place for the same reason, and the
        // two used to disagree: this copy sat after the stats grid under a hardware heading, hung
        // off the bottom of the board-unavailable notice, while Android led its page with it.
        //
        // Nothing about taking it needs the board: the alert mode is a phone preference. The board
        // write it also makes is dropped while there is no link; the next connect re-sends the
        // wanted mode, and reconcileBuzzer re-asserts it from the first status frame if the board
        // still disagrees. That is the same path as any other mode picked while offline.
        if desertRestoreNeedsDetachedSurface(restoreOffered: alertRestoreOffered,
                                             boardControlsAvailable: hardwareControlsEnabled) {
            AlertRestorePanel()
        }
        statsGrid                            // UPTIME + DETECTIONS (2-up)
        configurationGroupHeader(
            "BEACON HARDWARE",
            "Configure board scanning, alerts, light, offline buffer, and firmware.")
        if !hardwareControlsEnabled { hardwareControlsUnavailable }
        hardwareConfigPanel
        configurationGroupHeader(
            "THIS \(thisDeviceName.uppercased())",
            "Notifications, Live Mode, and display preferences for this \(thisDeviceName).")
        phoneConfigPanel
        managedDevicesRow                    // -> watched + ignored sub-screen
        if improveDetectionAvailable(isSessionReady: ble.sessionReady,
                                     isDemoMode: ble.demoMode) {
            helpImproveRow                   // -> contribute a field observation (manual export)
        }
        helpSupportRow                       // -> bundled FAQ + support routes
        disconnectButton
        if showPowerOff { powerOffButton }   // rev-B only: shut the board down over BLE
        aboutFooter                          // -> about sub-screen
    }

    // Which config fold section is currently open. Exactly one at a time (nil = all closed).
    // The firmware row/banner shares this state under `.firmware`, so opening it also
    // collapses any open config section.
    private enum ConfigSection: Hashable { case firmware, radios, detectors, alerts, notify, display, drive, desert, led }
    @State private var openSection: ConfigSection?

    private var radioPresentation: BeaconRadioPresentation {
        beaconRadioPresentation(
            connectionState: ble.connectionState,
            sessionReady: ble.sessionReady,
            isReconnecting: ble.isReconnecting,
            isDemoMode: ble.demoMode,
            status: ble.status,
            combinedUpdateRunning: ble.combinedState.isRunning,
            isRebootingForUpdate: ble.isRebootingForUpdate)
    }

    /// Presenter tone as a FILL. Only the hero ScanDot reads this: a 7pt disc, so the crimson
    /// fill token is the right one (Theme.swift reserves `accent` for fills and gives crimson
    /// words `accentText`). Words drawn from the same presenter take `radioPresentationTextColor`.
    private var radioPresentationColor: Color {
        switch radioPresentation.tone {
        case .accent:  return ACABTheme.accent
        case .neutral: return ACABTheme.dim
        case .warning: return ACABTheme.warn
        }
    }

    /// Presenter tone as TEXT, for the header kicker. The same mapping DashboardView's
    /// scanKickerColor gives the same presenter: a healthy `.accent` reads as quiet chrome in
    /// `dim`, not crimson, and only `.warning` colours the words. The fill token is not text-safe
    /// on every surface (ContrastPaletteTests testNormalFillAccentIsUnderAAOnRaisedSurface), so
    /// it never colours words.
    private var radioPresentationTextColor: Color {
        radioPresentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim
    }

    private var hasCurrentBoardStatus: Bool {
        ble.demoMode || (ble.connectionState == .connected && ble.sessionReady
            && !ble.isReconnecting && ble.status != nil)
    }

    private var canRefreshBoardStatus: Bool {
        !ble.demoMode && ble.connectionState == .connected && ble.sessionReady
            && !ble.isReconnecting && !ble.combinedState.isRunning
    }

    /// Board writes require the authenticated config session and a current status baseline. Phone
    /// preferences remain available while this is false, which is the practical value of splitting
    /// the two groups instead of dimming the whole page during reconnect/update windows.
    private var hardwareControlsEnabled: Bool {
        ble.demoMode || (ble.connectionState == .connected && ble.sessionReady
            && !ble.isReconnecting && ble.status != nil && !ble.combinedState.isRunning
            && ble.status?.nrfUpdating != true)
    }

    private var firmwarePromotion: BeaconFirmwareBannerPresentation? {
        beaconFirmwareBannerPresentation(
            combinedState: ble.combinedState,
            phaseLabel: ble.combinedPhaseLabel,
            progress: ble.combinedProgress,
            notice: ble.combinedNotice,
            installedVersion: ble.status?.version,
            latestVersion: latestVersion,
            outdated: outdated,
            combinedStale: combinedStale,
            s3Stale: s3Stale,
            combinedS3Updated: ble.combinedS3Updated)
    }

    /// Promote every actionable or terminal update state, including an nRF-only update. Previously
    /// only an outdated S3 produced the banner, and every terminal banner still said "vX ready."
    private var updateExists: Bool { firmwarePromotion != nil }

    // MARK: firmware banner (shown for available, running, and terminal states)
    // Takes the presentation its call sites already unwrapped from firmwarePromotion. The banner
    // is only ever placed inside that `if let`, so a no-promotion fallback here would be copy no
    // state can reach. firmwarePromotion is a computed property, so one body pass still builds it
    // twice: once for this `if let`, and once more when hardwareConfigPanel reads `updateExists`
    // to decide whether the Firmware fold row draws. Both reads see the same published state, so
    // the two values always agree; threading this one value into hardwareConfigPanel would save
    // that second build and was not worth the extra parameter.
    private func firmwareBanner(_ presentation: BeaconFirmwareBannerPresentation) -> some View {
        let open = openSection == .firmware
        let fill: Color
        let titleTone: Color
        let detailTone: Color
        let border: Color
        switch presentation.tone {
        case .accent:
            fill = ACABTheme.accent
            titleTone = ACABTheme.onAccent
            detailTone = ACABTheme.onAccent.opacity(0.82)
            border = Color.clear
        case .warning:
            fill = ACABTheme.warn.opacity(0.12)
            titleTone = ACABTheme.warn
            detailTone = ACABTheme.text
            border = ACABTheme.warn.opacity(0.5)
        case .neutral:
            fill = ACABTheme.bg2
            titleTone = ACABTheme.text
            detailTone = ACABTheme.dim
            border = ACABTheme.lineStrong
        }
        return VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { openSection = open ? nil : .firmware }
            } label: {
                HStack(spacing: 12) {
                    if ble.combinedState.isRunning {
                        ProgressView().controlSize(.small).tint(titleTone).frame(width: 20)
                    } else {
                        Image(systemName: presentation.tone == .warning
                              ? "exclamationmark.triangle.fill"
                              : (ble.combinedState == .done
                                 ? "checkmark.seal.fill" : "arrow.down.circle.fill"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(titleTone).frame(width: 20)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(titleTone)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.detail)
                            .font(ACABTheme.mono(10.5)).tracking(1.0)
                            .foregroundStyle(detailTone)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(titleTone)
                }
                .padding(16)
                .background(fill, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm,
                                                       style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                    .strokeBorder(border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.title). \(presentation.detail)")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { firmwareCard }
        }
    }

    // MARK: scoped config fold panels (one open section across both)

    private func configurationGroupHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(title)
            Text(detail)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// "iPhone" or "iPad", by idiom. This screen splits into the board's settings and the
    /// settings of the device in your hand, so the second heading names that device - and it
    /// said "THIS IPHONE" on an iPad, which shipped into the store screenshots. The project
    /// targets device family "1,2", so there are only two answers. TWIN: android
    /// DeviceScreen.kt uses the generic "THIS PHONE" and needs no idiom test.
    private var thisDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// Drawn only while `hardwareControlsEnabled` is false: the board's own controls are read-only
    /// and this says so where the group header promised them.
    ///
    /// IT NO LONGER CARRIES THE RESTORE OFFER. The offer's detached copy used to hang off the
    /// bottom of this card, which put it below the stats grid and under a "BEACON HARDWARE"
    /// heading, while Android led its page with the same copy. It is now `AlertRestorePanel` at the
    /// TOP of the page on both platforms (see settingsCards), so the two apps place it identically
    /// and a silence the app imposed leads the screen instead of sitting three cards down.
    /// This card still explains the read-only panel below it, and its last sentence is still what
    /// tells the owner that phone-side preferences remain available - which now includes the offer
    /// sitting above it, whenever there is one to take.
    private var hardwareControlsUnavailable: some View {
        let updating = ble.combinedState.isRunning || (hasCurrentBoardStatus && ble.status?.nrfUpdating == true)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: updating
                      ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(radioPresentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim)
                    .frame(width: 18)
                Text(updating
                     ? "Board controls pause while the firmware update is running. This \(thisDeviceName)'s preferences remain available."
                     : "Board controls are read-only until the secure link and a current status frame return. This \(thisDeviceName)'s preferences remain available.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Combine the sentence and its glyph into one spoken element, which is now the whole
            // card: nothing tappable is left in it.
            .accessibilityElement(children: .combine)
        }
        .padding(12)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm,
                                                        style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    // Keep both panels type-erased. Combining every disclosure row into one concrete SwiftUI type
    // can overflow the runtime's metadata resolver; see the documented firmwareCard crash below.
    private var hardwareConfigPanel: AnyView {
        AnyView(VStack(spacing: 0) {
            foldRow(.radios, glyph: "antenna.radiowaves.left.and.right",
                    title: "Scan radios", kicker: radiosKicker) { AnyView(radiosCard) }
            rowDivider
            foldRow(.detectors, glyph: "scope",
                    title: "Detectors", kicker: detectorsKicker) { AnyView(detectorsCard) }
                .id(ConfigSection.detectors)
            if ble.status?.isMeshDetect != true {   // mesh board has no buzzer -> no Alerts row
                rowDivider
                foldRow(.alerts, glyph: "bell", title: "Alerts", kicker: alertsKicker) { AnyView(buzzerCard) }
            }
            rowDivider
            foldRow(.desert, glyph: "mountain.2",
                    title: "Desert mode + buffer", kicker: desertKicker) {
                AnyView(VStack(spacing: 12) { desertModeCard; offlineBufferCard })
            }
            rowDivider
            foldRow(.led, glyph: "lightbulb", title: "Board LED", kicker: ledKicker) { AnyView(lightsOutCard) }
            // Firmware is maintenance, not an everyday scan control. It stays last when healthy;
            // any available/running/terminal state is promoted above both groups instead.
            if !updateExists {
                rowDivider
                foldRow(.firmware, glyph: "memorychip", title: "Firmware",
                        kicker: firmwareRowKicker) { firmwareCard }
            }
        }
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
        .disabled(!hardwareControlsEnabled)
        .opacity(hardwareControlsEnabled ? 1 : 0.62))
    }

    private var phoneConfigPanel: AnyView {
        AnyView(VStack(spacing: 0) {
            // Phone notifications work even on a mesh board with no buzzer.
            foldRow(.notify, glyph: "app.badge", title: "Notifications",
                    kicker: notifyKicker) { AnyView(notifyCard) }
            rowDivider
            foldRow(.drive, glyph: "dot.radiowaves.left.and.right", title: "Live Mode",
                    kicker: driveKicker) { AnyView(driveModeCard) }
            rowDivider
            foldRow(.display, glyph: "circle.lefthalf.filled", title: "Display",
                    kicker: displayKicker) { AnyView(displayCard) }
        }
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1)))
    }

    private var rowDivider: some View {
        Rectangle().fill(ACABTheme.line).frame(height: 1).padding(.horizontal, 16)
    }

    // Hand-rolled disclosure row: glyph + title + live kicker + flipping chevron. Open ->
    // accent-tinted glyph, flipped chevron, faint accent wash, and today's card verbatim below.
    private func foldRow(_ section: ConfigSection, glyph: String, title: String,
                         kicker: String, content: () -> AnyView) -> AnyView {
        let open = openSection == section
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { openSection = open ? nil : section }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: glyph)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(open ? ACABTheme.accent : ACABTheme.dim)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        // fixedSize(vertical:) lets both lines GROW DOWNWARD at large Dynamic Type
                        // instead of widening the row. Without it the HStack is sized by the text's
                        // ideal width and the whole page runs off the screen edge.
                        Text(title).font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Kicker(kicker)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(open ? ACABTheme.accent : ACABTheme.faint)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Spoken disclosure state: the flipped chevron is the only visual cue, which a
            // screen reader cannot see.
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { content().padding(.bottom, 14) }
        }
        .padding(.horizontal, 16)
        .background(open ? ACABTheme.accent.opacity(0.04) : Color.clear))
    }

    // MARK: managed devices row -> watched + ignored sub-screen
    private var managedDevicesRow: some View {
        NavigationLink { managedDevicesScreen } label: {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.watchTone).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Managed devices").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker(managedKicker)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    /// Entry point for the bundled FAQ. Sits below Managed devices and above Disconnect on
    /// purpose: it is a reference surface, not a control, so it should not sit among the toggles
    /// that change what the board does.
    // Field research: contribute a capture of a device the beacon did not identify. Manual export
    // only (see ContributeView) - nothing leaves the phone without the user. Mirrors Android's
    // "Help improve detection" row.
    private var helpImproveRow: some View {
        NavigationLink { ContributeView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "flask")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Improve detection").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker("CONTRIBUTE A FIELD OBSERVATION")
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    private var helpSupportRow: some View {
        NavigationLink {
            HelpView(canImproveDetection: improveDetectionAvailable(
                isSessionReady: ble.sessionReady,
                isDemoMode: ble.demoMode))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help + support").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker("FAQ · TROUBLESHOOTING · CONTACT")
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    private var managedDevicesScreen: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if ble.managedListSavePending {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ACABTheme.warn)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("CHANGES NOT SAVED")
                                    .font(ACABTheme.mono(10, weight: .bold))
                                    .foregroundStyle(ACABTheme.warn)
                                Text("Your latest watch or mute change is active for this session, but protected storage rejected it.")
                                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("RETRY SAVE") { ble.retryManagedListPersistence() }
                                    .font(ACABTheme.mono(10, weight: .bold))
                                    .foregroundStyle(ACABTheme.accentText)
                                    .padding(.top, 3)
                            }
                        }
                        .panel()
                    }
                    if !ble.watched.isEmpty { watchedCard }
                    if !ble.ignored.isEmpty || ble.boardOnlyMuteCount > 0 { ignoredCard }
                    // Both lists empty: say so, or the pushed screen reads as a loading failure.
                    if ble.watched.isEmpty && ble.ignored.isEmpty && ble.boardOnlyMuteCount == 0 {
                        Text("No watched or muted devices yet.")
                            .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
                .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
            }
        }
        .navigationTitle("Managed devices")
        .navigationBarTitleDisplayMode(.inline)
        // The rename alert MUST live here, not on the root Device screen: the pencil is in watchedCard,
        // which only renders inside this pushed sub-screen. An alert attached to the covered root never
        // presents, so tapping the pencil silently did nothing.
        .alert("Rename device", isPresented: renameAlertBinding) {
            TextField("Label", text: $renameText)
            Button("Cancel", role: .cancel) { renameMac = nil }
            Button("Save") {
                if let mac = renameMac {
                    let t = renameText.trimmingCharacters(in: .whitespaces)
                    if renameIsIgnored { ble.renameIgnored(mac, to: t) } else { ble.renameWatched(mac, to: t) }
                }
                renameMac = nil
            }
        } message: {
            Text("Name this device so you recognize it in the log.")
        }
    }

    // MARK: about footer link -> about sub-screen
    private var aboutFooter: some View {
        NavigationLink { aboutScreen } label: {
            Text("about \u{00B7} made by soyboi")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aboutScreen: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { aboutCard }
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: fold-row kickers (all live state, terse ALL-CAPS)
    /// TWIN: android DeviceScreen.kt, the Firmware `FoldRow` kicker `when` - the five arms below
    /// are its five, byte for byte, in the same order (CHECKING FOR UPDATES / BOARD STATUS
    /// UNAVAILABLE / NOT IN CATALOG / UPDATE BLOCKED · REVISION MISMATCH / LATEST KNOWN). The
    /// third arm deliberately says UNAVAILABLE, not the scanLabel's "WAITING FOR BOARD STATUS":
    /// it also covers a reconnect and a dropped link, where nothing is being waited for.
    private var firmwareRowKicker: String {
        if checkingForUpdate { return "CHECKING FOR UPDATES" }
        guard hasCurrentBoardStatus, let installed = ble.status?.version else {
            return "BOARD STATUS UNAVAILABLE"
        }
        guard fwEntry != nil else { return "v\(installed) \u{00B7} NOT IN CATALOG" }
        // Same string Android's fold row uses, and ahead of the healthy arm: a listing we refuse
        // to flash from is not "latest known".
        if !revisionMatchesManifest { return "UPDATE BLOCKED \u{00B7} REVISION MISMATCH" }
        // No UPDATE READY arm, matching Android's fold row: this row is only built when
        // `updateExists` is false, and any available, running or terminal update makes that true
        // and promotes the banner in its place, so such an arm could never draw.
        return "v\(installed) \u{00B7} LATEST KNOWN"
    }

    private var radiosKicker: String {
        radioPresentation.scanLabel
    }

    private var detectorsKicker: String {
        let onCount = [flockOn, droneOn, bodyCamOn, trackerOn, glassesOn, netcamOn].filter { $0 }.count
        let expOn = [glassesOn].filter { $0 }.count
        return "\(onCount) ON \u{00B7} \(expOn) EXP \u{00B7} TRACKERS \(trackerOn ? "ON" : "OFF")"
    }

    /// The collapsed Alerts row. The Silent arm grows a second segment while the app is holding a
    /// mode to give back, because "SILENT" alone is what a user who CHOSE silence sees, and this is
    /// a silence the app imposed: at a glance the two read identically, and the way out is a row
    /// the user has no reason to open. Byte-identical to Android's alertsKicker SILENT arm.
    ///
    /// Only the Silent arm needs it. An offer can only exist while the mode reads Silent
    /// (.boardEndedDesert requires `current == .silent` to arm it) and every path that moves the
    /// mode off Silent goes through setAlertMode, where origin .user clears the offer and origin
    /// .app cannot reach a non-Silent mode with an offer armed (the restore arm needs `saved`, and
    /// arming the offer empties that half).
    private var alertsKicker: String {
        switch ble.alertMode {
        case .buzzer:  return "BUZZER \u{00B7} VOLUME \(Int(master))"
        case .vibrate: return "VIBRATE \u{00B7} PHONE BUZZES"
        case .silent:  return alertRestoreOffered ? "SILENT \u{00B7} RESTORE WAITING" : "SILENT"
        }
    }

    private var driveKicker: String {
        "\(liveModeState.uppercased()) \u{00B7} COUNTS \(ble.settingsRedactLockScreen ? "PRIVATE" : "VISIBLE")"
    }

    /// Report the system surface that actually exists, not just the persisted toggle intent.
    /// `driveModeOn` leads so a short end/start transition can never call a visible activity Off.
    private var liveModeState: String {
        if ble.demoMode { return ble.settingsDriveModeWanted ? "Preview on" : "Off" }
        if ble.driveModeOn { return "Active" }
        if !ble.driveModeWanted { return "Off" }
        if !ble.liveActivitiesEnabled { return "Blocked by iOS" }
        if ble.connectionState == .connected, !ble.demoMode, !ble.locationAuthorized {
            return "Location needed"
        }
        return "Waiting for beacon"
    }

    private var desertKicker: String {
        switch (desertOn, bufferOn) {
        case (false, false): return "BOTH OFF"
        case (true, true):   return "BOTH ON"
        case (true, false):  return "DESERT ON \u{00B7} BUFFER OFF"
        case (false, true):  return "BUFFER ON \u{00B7} DESERT OFF"
        }
    }

    private var ledKicker: String { lightsOut ? "LIGHTS OUT" : "HEARTBEAT ON" }

    private var managedKicker: String {
        let boardCount = hasCurrentBoardStatus
            ? "\(ble.status?.watchCount ?? 0) ON BOARD"
            : "BOARD N/A"
        return "\(ble.watched.count) WATCHED \u{00B7} \(boardCount) \u{00B7} \(ble.ignored.count) MUTED"
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Beacon").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(radioPresentation.connectionLabel, color: radioPresentationTextColor)
            }
            Spacer()
            LinkChip(
                version: ble.status?.version,
                connected: ble.connectionState == .connected && ble.sessionReady
                    && !ble.isReconnecting,
                demo: ble.demoMode,
                stateLabel: radioPresentation.chipLabel)
            // Ask the board for a fresh status frame right now, instead of waiting
            // for the next periodic notify.
            Button { ble.otaRereadStatus() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(canRefreshBoardStatus ? ACABTheme.dim : ACABTheme.faint)
                    .frame(width: 38, height: 38)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                    .frame(minWidth: 44, minHeight: 44)   // 44pt hit target; drawn circle unchanged
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRefreshBoardStatus)
            .accessibilityLabel("Refresh device status")
            .accessibilityHint(canRefreshBoardStatus
                ? "Requests a current status frame from the beacon."
                : "Available after the secure beacon link is ready.")
        }
    }

    // MARK: device hero
    /// At accessibility text sizes the one-line hero (badge · name · battery · dot) has no
    /// room left for the name, so it stacks: badge + status glyphs on top, the text below.
    /// It ALSO stacks whenever the inline row does not fit, which is what a battery read does on a
    /// narrow phone: heroBattery adds an SF Symbol plus "NN%", and the name is the only thing that
    /// can give, so "All Cameras Are Beacons" wrapped to two lines at 390pt with bat 82 (seen in
    /// the sample-data tour, whose seed carries "bat": 82). minimumScaleFactor(0.8) on the name
    /// shrinks it first but does not save it. Battery-less boards keep the single row they had.
    /// TWIN: Android `DeviceHero` in DeviceScreen.kt, which stacks on the same two conditions
    /// (accessibility-scale text, or a battery on a card under 340dp).
    @ViewBuilder
    private var deviceHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                heroStacked
            } else {
                // Spacer(minLength:) is load-bearing. ViewThatFits measures each candidate at its
                // IDEAL width, and a plain Spacer() is infinitely flexible, so the inline row would
                // always report that it fits and the fallback could never be chosen.
                ViewThatFits(in: .horizontal) {
                    heroInline
                    heroStacked
                }
            }
        }
        .panel(strong: true)
    }

    private var heroInline: some View {
        HStack(spacing: 14) {
            heroBadge
            heroText
            Spacer(minLength: 8)
            heroBattery
            heroDot
        }
    }

    private var heroStacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                heroBadge
                Spacer()
                heroBattery
                heroDot
            }
            heroText
        }
    }

    private var heroBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ACABTheme.bg3).frame(width: 52, height: 38)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ACABTheme.line, lineWidth: 1))
            Circle().fill(ACABTheme.accent).frame(width: 7, height: 7)
                .shadow(color: ACABTheme.accentGlow, radius: 4).offset(x: -14, y: -9)
        }
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((ble.connectedName?.contains("ACAB") == true || ble.connectedName?.contains("beacon") == true)
                 ? "All Cameras Are Beacons" : (ble.connectedName ?? "ESP32 board"))
                .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
            Text(heroStatusText)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroStatusText: String {
        if ble.demoMode { return "SAMPLE DATA · no live board" }
        guard hasCurrentBoardStatus, let status = ble.status,
              !ble.combinedState.isRunning else {
            return radioPresentation.scanLabel
        }
        return "\(radioPresentation.connectionLabel) · \(status.firmwareLabel)\(boardRevSuffix)"
    }

    @ViewBuilder
    private var heroBattery: some View {
        if hasCurrentBoardStatus, let status = ble.status, let bat = status.battery {
            let charging = status.charging
            HStack(spacing: 4) {
                Image(systemName: charging ? "battery.100.bolt" : batterySymbol(bat))
                Text("\(bat)%")
            }
            .font(ACABTheme.mono(11))
            .foregroundStyle(charging ? ACABTheme.accent : (bat <= 15 ? ACABTheme.warn : ACABTheme.dim))
        }
    }

    private var heroDot: some View {
        ScanDot(color: ble.demoMode ? ACABTheme.warn
                : (hasCurrentBoardStatus ? radioPresentationColor : ACABTheme.faint))
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0";   case ..<38: return "battery.25"
        case ..<63: return "battery.50";  case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    // MARK: nRF radio fault (dual-radio beacon board only)
    // The ESP32 only emits "co" when it's a dual-radio board; when it does and the value is
    // false, the nRF co-processor stopped answering over UART, so the whole BLE-detection half
    // is dark. Single-radio boards omit the key, so `coproc == nil` and this never fires.
    // Except during a BLE-DFU window: the nRF sits in its bootloader on purpose, so "co" reads
    // false for minutes at a time and the board flags that with "nrfup". Same dark radio, wholly
    // different story, so the fault defers to it rather than crying wolf over a healthy update.
    private var nrfUpdating: Bool {
        ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting
            && ble.status?.nrfUpdating == true
    }
    // App-authoritative suppression: while the one-click flow is running we KNOW the nRF is being
    // reset-pulsed / reflashed, so force the fault banner off regardless of what the firmware's
    // `nrfup`/`co` happen to report this frame. OR-in the running flag here at the source.
    private var coprocFault: Bool {
        ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting
            && ble.status?.ble == true && ble.status?.coproc == false
            && !nrfUpdating && !ble.combinedState.isRunning
    }

    /// BYTE-IDENTICAL to android DeviceScreen.kt `NrfUpdatingBanner`'s true/false sentences -
    /// reword one and reword the other. Android carries a third, frame-less arm this state cannot
    /// reach here: `nrfUpdating` above requires the board's own nrfup bit.
    private var nrfUpdateDetail: String {
        if ble.status?.wifi == true {
            return "the second radio is taking new firmware, so Bluetooth gear won't be spotted until it comes back. Wi-Fi scanning is still on. keep the board powered and stay close."
        }
        return "the second radio is taking new firmware, so Bluetooth gear won't be spotted until it comes back. Wi-Fi scanning is off. keep the board powered and stay close."
    }

    /// BYTE-IDENTICAL to android DeviceScreen.kt `NrfFaultBanner`'s body - reword one and reword
    /// the other. The both-off case is its own sentence rather than a suffix on the first: when
    /// nothing is scanning, say so outright instead of leaving the reader to add two facts up.
    private var coprocFaultDetail: String {
        if ble.status?.wifi == true {
            return "the second radio stopped answering, so Bluetooth gear won't be spotted. Wi-Fi scanning is still active. try a power cycle, and reflash if it sticks."
        }
        return "the second radio stopped answering and Wi-Fi scanning is off, so the beacon is not detecting nearby gear. try a power cycle, and reflash if it sticks."
    }

    /// The calm twin of coprocFaultBanner: same dark BLE half, on purpose and temporary.
    private var nrfUpdatingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(ACABTheme.dim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("updating co-processor")
                    .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(nrfUpdateDetail)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var coprocFaultBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(ACABTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("nRF radio fault - bluetooth detection offline")
                    .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(coprocFaultDetail)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ACABTheme.accentSoft, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.accent.opacity(0.5), lineWidth: 1))
    }

    // MARK: firmware
    // The board's fw label ("beacon board" etc.), used to look up its manifest entry.
    private var fwLabel: String { ble.status?.firmwareLabel ?? "" }
    // The manifest entry for this board, if the manifest lists it.
    private var fwEntry: FirmwareManifest.Build? { manifest.entry(forFwLabel: fwLabel) }
    // Carrier revision, shown next to the fw label so support can tell which board is in the case
    // without opening it. Silent when the board does not report it (older/single-radio firmware) -
    // an unlabelled board reads as "we were not told", not as rev-A.
    private var boardRevSuffix: String {
        guard let r = ble.status?.boardRev, r == "A" || r == "B" else { return "" }
        // The rev-B fw label already ends in "rev-B", so appending the badge there prints
        // "... rev-B · rev-B". Only add it when the label does not already name this rev
        // (rev-A's label is just "beacon board", so it still gets the badge).
        if (ble.status?.firmwareLabel ?? "").lowercased().contains("rev-\(r.lowercased())") { return "" }
        return " · rev-\(r)"
    }
    // Belt-and-braces OTA revision gate. The PRIMARY defence is that rev-B firmware reports a
    // distinct fw label ("beacon board rev-B", set in platformio.ini) and the manifest is KEYED by
    // that label (FirmwareManifest.build(forFwLabel:) is a dictionary lookup), so a rev-B board
    // cannot resolve the rev-A entry at all - and until the manifest gains a rev-B key it resolves
    // nothing and falls back to the browser flasher. Both are fail-closed.
    // This second check catches the case where someone re-unifies the labels or hand-edits the
    // manifest: if the board TELLS us its revision, the key we are about to flash from has to agree.
    // A wrong-image flash parks the unit after every boot and is USB-recovery only, so a false
    // refusal is by far the cheaper error.
    private var revisionMatchesManifest: Bool {
        guard let rev = ble.status?.boardRev, rev == "A" || rev == "B" else { return true }  // not told = do not block
        let entryIsRevB = fwLabel.lowercased().contains("rev-b")
        return entryIsRevB == (rev == "B")
    }
    // Latest version from the manifest (falls back to the shipped constant when unlisted).
    private var latestVersion: String { manifest.latestVersion(forFwLabel: fwLabel) }
    // Installed firmware older than the manifest's latest AND the listing we would flash from
    // agrees with the revision the board reports. The revision term is not decoration: without it
    // the promoted banner said "Firmware vX available" and the card handed the user an "Open the
    // browser flasher" link into the very listing this app just decided is the wrong revision.
    // Android's `fwOutdated` carries the same term for the same reason.
    private var outdated: Bool {
        revisionMatchesManifest && (ble.status?.updateAvailable(latest: latestVersion) ?? false)
    }

    /// Every condition that must hold for in-app OTA to be offered:
    /// (1) the manifest lists this board, (2) it's marked OTA-capable, (3) it carries a
    /// verifiable image (sha256 + size), (4) the connected board actually exposes the OTA
    /// characteristic, (5) the installed version is strictly older than the manifest's,
    /// (6) the manifest key matches the carrier revision the board reports (see below).
    private var otaEligible: Bool {
        guard let e = fwEntry, e.ota, e.hasVerifiableImage, ble.otaCapable, outdated,
              revisionMatchesManifest else { return false }
        return true
    }

    /// The flasher URL to send the user to when OTA isn't offered: manifest first, then the
    /// baked-in default.
    private var flasherURL: URL {
        let fromManifest = (fwEntry?.flasher).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return fromManifest ?? URL(string: "https://soyboi1312.github.io/all-cameras-are-beacons/")!
    }

    /// TYPE-ERASED ON PURPOSE - do not "clean this up" back to `some View`.
    ///
    /// This is the deepest view in the app: a three-way state branch whose arms are themselves
    /// stacks of heavily-modified buttons (`.background(_:in:)` + `.overlay(strokeBorder:)` each
    /// add another `ModifiedContent` layer), and the whole thing was once handed to a generic
    /// disclosure row as its Content. Left concrete, the composed static type nests deep
    /// enough that flipping the branch - which is exactly what tapping "update" does - made
    /// SwiftUI instantiate that type's metadata at runtime, and the Swift runtime's RECURSIVE
    /// demangler overflowed the 1 MB main-thread stack. The app died on the tap, every time.
    ///
    /// Reproduced on device 2026-08-06 (Beacons-2026-08-06-115438.ips): EXC_BAD_ACCESS /
    /// KERN_PROTECTION_FAILURE on the stack guard page, thread 0, frames
    ///   closure #1 in DeviceView.firmwareCard.getter
    ///   -> __swift_instantiateConcreteTypeFromMangledNameV2
    ///   -> swift_getTypeByMangledNameInContext2
    ///   -> decodeMangledType / decodeGenericArgs x37.
    ///
    /// `AnyView` boxes the branch so the mangled name stays shallow. The cost is that SwiftUI
    /// cannot diff across the box, which is free here: the three arms are different types and
    /// would be replaced wholesale anyway.
    ///
    /// VERIFIED on the same device that produced the crash: with this boxing (plus the matching
    /// boxing on `combinedControlButtons`) tapping the firmware card no longer terminates the app.
    private var firmwareCard: AnyView {
        let installed = ble.status?.version
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            Kicker("FIRMWARE")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.map { "v\($0)" } ?? "-")
                        .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    Kicker("INSTALLED")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // A listing we refuse to flash from has no "latest" to report, so name the
                    // refusal instead of printing a version the user cannot have.
                    //
                    // TWIN: this value/kicker pair must stay byte-identical with the firmware
                    // card in android/app/src/main/java/tech/acab/app/ui/DeviceScreen.kt. The
                    // healthy arm says "LATEST KNOWN", not "LATEST", because `latestVersion`
                    // falls back to the baked-in `DeviceStatus.latestVersion` when the manifest
                    // has no entry for this board: the number is the newest build this app knows
                    // of, not proof of global currency. Both platforms' firmware FOLD ROWS
                    // (`firmwareRowKicker` here) already say "LATEST KNOWN".
                    Text(revisionMatchesManifest ? "v\(latestVersion)" : "-")
                        .font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(outdated || !revisionMatchesManifest
                                         ? ACABTheme.warn : ACABTheme.dim)
                    Kicker(revisionMatchesManifest ? "LATEST KNOWN" : "REVISION MISMATCH")
                }
            }
            Divider().overlay(ACABTheme.line)

            // One-click combined update: ONE button that flashes the board firmware (S3) and, when
            // it applies, the co-processor (nRF) in a single determinate flow. The transfer engines
            // are unchanged; BLEManager+CombinedUpdate sequences them and merges their progress.
            firmwareCardState
            // Manual refresh stays reachable except mid-update, so a stale cached manifest can be
            // re-fetched even when an update already looks available.
            if !ble.combinedState.isRunning {
                checkForUpdatesButton
            }
        }
        .panel())
    }

    /// The three-way state branch, boxed so `firmwareCard`'s type does not carry the whole
    /// progress/offer/status subtree inside two nested `_ConditionalContent` layers. See the
    /// stack-overflow note on `firmwareCard`.
    private var firmwareCardState: AnyView {
        if ble.combinedState.isRunning || combinedTerminal {
            return AnyView(combinedProgressView)   // running, or just finished (done / failed / partial)
        }
        if combinedStale {
            return AnyView(combinedOfferView)      // either radio is behind: offer the single update
        }
        return AnyView(firmwareStatusLine)         // up to date, or outdated with browser guidance
    }

    // MARK: one-click combined update UI

    /// Either the board firmware or the co-processor is behind and self-updatable.
    ///
    /// `revisionMatchesManifest` is checked HERE because this is a live path. It was previously
    /// only inside `otaEligible`, which is defined and referenced nowhere: the rev-B safety gate
    /// was dead code on iOS while every update actually offered came through this property. So the
    /// belt-and-braces revision check that Android performs did not exist here at all, which is
    /// the reverse of what the comments on both sides claimed. `outdated` carries the same term
    /// for the browser-flasher path, matching Android's `fwOutdated`.
    ///
    /// It matters because a wrong-revision image parks the unit after every boot and is
    /// USB-recovery only, so a false refusal is by far the cheaper error.
    private var combinedStale: Bool {
        guard let e = fwEntry, revisionMatchesManifest else { return false }
        return ble.combinedUpdateStale(entry: e, fwLabel: fwLabel, latest: latestVersion)
    }
    /// The BOARD leg specifically is behind. `combinedStale` is the OR of both radios, so this is
    /// what lets the offer copy tell "board is behind" from "only the co-processor is behind".
    private var s3Stale: Bool {
        guard let e = fwEntry, revisionMatchesManifest else { return false }
        return ble.s3UpdateStale(entry: e, fwLabel: fwLabel, latest: latestVersion)
    }
    /// The combined flow is at a terminal point we keep on screen (done / failed / partial).
    private var combinedTerminal: Bool {
        switch ble.combinedState { case .done, .failed, .partial: return true; default: return false }
    }

    private var combinedOfferView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(ACABTheme.accent)
                // Name what is ACTUALLY behind. When only the co-processor is stale the board is
                // already on latestVersion, and the old unconditional wording read as a
                // contradiction next to the "vX INSTALLED / vX LATEST" row directly above it.
                Text(s3Stale
                     ? "Update available: v\(latestVersion). You can install it here, over Bluetooth."
                     : "Co-processor update available. The board firmware is already current; this updates the second radio, over Bluetooth.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            combinedUpdateButton(title: "update")
            Text("Installs over Bluetooth and usually takes about 2-3 minutes. The board restarts on its own partway through. Keep this phone next to the beacon with the app open until it finishes.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func combinedUpdateButton(title: String) -> some View {
        Button { if let e = fwEntry { ble.startCombinedUpdate(entry: e, fwLabel: fwLabel, latest: latestVersion) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                Text(title).font(ACABTheme.display(15, weight: .semibold))
            }
            .foregroundStyle(ACABTheme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!hardwareControlsEnabled)
        .opacity(hardwareControlsEnabled ? 1 : 0.55)
        .accessibilityHint(hardwareControlsEnabled
            ? "Starts the firmware update."
            : "Available after the secure beacon link and board status return.")
    }

    private var combinedProgressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: combinedStatusSymbol)
                    .font(.system(size: 13)).foregroundStyle(combinedStatusTone)
                Text(combinedStatusLabel)
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                Spacer(minLength: 0)
                if ble.combinedState.isRunning {
                    Text("\(Int((ble.combinedProgress * 100).rounded()))%")
                        .font(ACABTheme.mono(12, weight: .semibold)).foregroundStyle(combinedStatusTone)
                }
            }
            if ble.combinedState.isRunning {
                ProgressView(value: min(max(ble.combinedProgress, 0), 1), total: 1).tint(ACABTheme.accent)
                Text(combinedElapsedText)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
            if let detail = combinedDetailText {
                Text(detail).font(ACABTheme.mono(10.5)).foregroundStyle(combinedStatusTone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ble.combinedState.isRunning {
                Text("Keep this phone next to the beacon with the app open. Don't lock it or leave this screen.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            combinedControlButtons
        }
    }

    /// Boxed for the same reason as `firmwareCard`: three arms, each a Button carrying a
    /// `.background(_:in:)` and an `.overlay(strokeBorder:)`, sitting inside the progress arm of
    /// the card's own branch. This is the single biggest contributor to the nesting depth that
    /// overflowed the demangler's stack.
    private var combinedControlButtons: AnyView {
        if ble.combinedCanCancel {
            return AnyView(secondaryButton("Cancel", tone: ACABTheme.accent,
                                           border: ACABTheme.lineStrong, role: .destructive) {
                ble.combinedCancel()
            })
        }
        if ble.combinedState.isRunning {
            return AnyView(Text("The board has committed this update and is finishing safely.")
                .font(ACABTheme.mono(10.5))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true))
        }
        if case .partial = ble.combinedState {
            // S3 took; the second radio didn't finish. The same primary button re-offers just the
            // nRF leg (the S3 is current now, so a fresh run does the co-processor only).
            // Spacing 12 matches what the enclosing VStack gave these when they were loose
            // siblings in a ViewBuilder tuple, so the box does not change the layout.
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                combinedUpdateButton(title: "finish second radio")
                secondaryButton("Not now") { ble.dismissCombinedUpdate() }
            })
        }
        return AnyView(secondaryButton("Done") { ble.dismissCombinedUpdate() })
    }

    /// The card's flat secondary button. Factored out because all three control arms drew the same
    /// stack of modifiers inline, and every repetition of it deepened the composed view type that
    /// overflowed the demangler (see `firmwareCard`).
    private func secondaryButton(_ title: String,
                                 tone: Color = ACABTheme.dim,
                                 border: Color = ACABTheme.line,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(ACABTheme.display(14, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(tone)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var combinedStatusLabel: String {
        ble.combinedPhaseLabel.isEmpty ? "Updating" : ble.combinedPhaseLabel
    }
    private var combinedElapsedText: String {
        let t = max(0, Int(ble.combinedElapsed)); return String(format: "elapsed %d:%02d", t / 60, t % 60)
    }
    private var combinedDetailText: String? {
        switch ble.combinedState {
        case .failed(let r): return r
        // PARTIAL means "some leg didn't land", and which leg depends on the run. A co-processor-only
        // run that fails never touched the board, so it must not claim the board was updated.
        case .partial:
            return ble.combinedS3Updated
                ? "Board updated. Second radio update didn't finish. Tap to finish the second radio, or dismiss - the button re-offers it on its own once the co-processor reports in."
                : "Second radio update didn't finish. The board firmware is unchanged and still working. Tap to try the second radio again, or dismiss - the button re-offers it on its own once the co-processor reports in."
        case .done:          return ble.combinedNotice ?? "Your beacon is up to date."
        default:             return ble.combinedNotice
        }
    }
    private var combinedStatusSymbol: String {
        switch ble.combinedState {
        case .done:    return "checkmark.seal.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        case .partial: return "exclamationmark.circle.fill"
        default:       return "arrow.triangle.2.circlepath"
        }
    }
    /// Every reader of this tone is words or a 13pt glyph: the status symbol, the running percent
    /// and the detail line ("Your beacon is up to date."). So the crimson arm is `accentText`, the
    /// token Theme.swift gives crimson text and small glyphs; `accent` stays on the progress bar's
    /// tint, which is a fill.
    private var combinedStatusTone: Color {
        switch ble.combinedState {
        case .done:             return ACABTheme.accentText
        case .failed, .partial: return ACABTheme.warn
        default:                return ACABTheme.dim
        }
    }

    // Plain status line: on the latest, or outdated with a pointer to the browser flasher.
    private var firmwareStatusLine: some View {
        let presentation = beaconFirmwareStatusPresentation(
            hasCurrentStatus: hasCurrentBoardStatus,
            installedVersion: ble.status?.version,
            catalogHasBoard: fwEntry != nil,
            latestVersion: latestVersion,
            outdated: outdated,
            revisionCompatible: revisionMatchesManifest)
        // Words and a 13pt glyph, so the crimson FILL token is out (Theme.swift: `accent` is for
        // fills, crimson words get `accentText`). The healthy `.accent` arm reads as quiet chrome
        // in `dim`, the colour Android draws its "latest known firmware" line in (DeviceScreen.kt),
        // and only `.warning` colours the line.
        let tone = presentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 13)).foregroundStyle(tone)
                Text(presentation.detail)
                    .font(ACABTheme.mono(11)).foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if presentation.offersBrowserFlasher {
                Link(destination: flasherURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").font(.system(size: 13))
                        Text("Open the browser flasher")
                            .font(ACABTheme.display(14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.vertical, 11).padding(.horizontal, 13)
                    .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                        .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Manual "check for updates": forces a manifest refresh past the 6h TTL, then the view
    // re-evaluates update availability off the fresh manifest (updateExists / outdated are
    // computed from it). This is what lets a freshly-published version show up on demand.
    private var checkForUpdatesButton: some View {
        Button {
            guard !checkingForUpdate else { return }
            Task {
                checkingForUpdate = true
                justChecked = false
                await manifest.refreshNow()
                checkingForUpdate = false
                justChecked = true
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                justChecked = false
            }
        } label: {
            HStack(spacing: 8) {
                if checkingForUpdate {
                    ProgressView().controlSize(.mini).tint(ACABTheme.dim)
                } else {
                    Image(systemName: justChecked ? "checkmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                // A failed network request deliberately keeps the last-good/bundled catalog. Since
                // the store does not discard that useful baseline, completion cannot prove that the
                // catalog itself was refreshed; only claim that the check finished.
                Text(checkingForUpdate ? "Checking\u{2026}" : (justChecked ? "Check finished" : "Check for updates"))
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ACABTheme.dim)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(checkingForUpdate)
    }

    // MARK: scan radios
    private var radiosCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("SCAN RADIOS")
            radioToggle("bluetooth", "ALPR \u{00B7} drone \u{00B7} trackers", isOn: Binding(
                get: { bleOn }, set: {
                    bleOn = $0; pendingBle = true; awaitConfirmation(.ble); ble.setBLEScan($0)
                }))
            Divider().overlay(ACABTheme.line)
            radioToggle("Wi-Fi", "2.4 GHz \u{00B7} ALPR \u{00B7} drone RID", isOn: Binding(
                get: { wifiOn }, set: {
                    wifiOn = $0; pendingWifi = true; awaitConfirmation(.wifi); ble.setWiFiScan($0)
                }))
            // Eco: only on battery boards (the board reports "bat" only when it has the sense
            // divider), and only meaningful while Wi-Fi is on. Duty-cycles the Wi-Fi RX to stretch
            // runtime; Bluetooth is untouched. Honest about the tradeoff right below the pills.
            if wifiOn, ble.status?.battery != nil {
                Divider().overlay(ACABTheme.line)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Kicker("WI-FI ECO")
                        Spacer()
                        Text(wifiEco == 0 ? "always on" : "sleeps \(wifiEco)s / sweep")
                            .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                    }
                    HStack(spacing: 6) {
                        ForEach([(0, "MAX"), (3, "3s"), (7, "7s"), (15, "15s")], id: \.0) { v, label in
                            Button {
                                wifiEco = v; pendingWifiEco = true
                                awaitConfirmation(.wifiEco); ble.setWifiEco(v)
                            } label: {
                                Text(label)
                                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(wifiEco == v ? ACABTheme.onAccent : ACABTheme.dim)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(wifiEco == v ? ACABTheme.accent : ACABTheme.bg2, in: Capsule())
                                    .overlay(Capsule().strokeBorder(wifiEco == v ? .clear : ACABTheme.line, lineWidth: 1))
                                    // 44pt hit target; drawn pill unchanged.
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(wifiEco == v ? .isSelected : [])
                        }
                    }
                    Text("stretches battery by sweeping Wi-Fi less often. you may miss a Wi-Fi-only camera between sweeps; Bluetooth detection is unaffected.")
                        .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                }
            }
        }
        .panel()
    }

    // MARK: detectors
    private var detectorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("DETECTORS")
            radioToggle("alpr radio signals", "flock over bluetooth or 2.4 GHz wifi \u{00B7} raven over bluetooth \u{00B7} many installs now stay silent", isOn: Binding(
                get: { flockOn }, set: {
                    flockOn = $0; pendingFlock = true; awaitConfirmation(.flock); ble.setFlockEnabled($0)
                }))
            Divider().overlay(ACABTheme.line)
            radioToggle("drones (remote ID)", "FAA remote ID \u{00B7} operator location", isOn: Binding(
                get: { droneOn }, set: {
                    droneOn = $0; pendingDrone = true; awaitConfirmation(.drone); ble.setDroneEnabled($0)
                }))
            // Sub-option of the drone detector: the vendor-OUI fallback. Inset + disabled while the
            // parent drone detector is off, to read as subordinate to the toggle above it. Off by
            // default because an OUI match alone can't tell a stationary Parrot gadget from a drone.
            radioToggle("non-broadcasting drones", "OUI match only, off by default, may false-positive", isOn: Binding(
                get: { droneOuiOn }, set: {
                    droneOuiOn = $0; pendingDroneOui = true
                    awaitConfirmation(.droneOui); ble.setDroneOuiEnabled($0)
                }))
                .padding(.leading, 22)
                .disabled(!droneOn)
                .opacity(droneOn ? 1 : 0.4)
            Divider().overlay(ACABTheme.line)
            // Names the whole category, not just Axon: post-split this covers Axon (payload tag
            // + OUI), Utility BodyWorn, and the Motorola vendor proxy in the sub-row below. The
            // old "Axon signature" copy read oddly directly above a Motorola control. Matches
            // Android's DeviceScreen wording so the two platforms describe the switch the same way.
            radioToggle("body cams", "Axon \u{00B7} Utility BodyWorn \u{00B7} Motorola vendor match", isOn: Binding(
                get: { bodyCamOn }, set: {
                    bodyCamOn = $0; pendingBodyCam = true
                    awaitConfirmation(.bodyCam); ble.setBodyCamEnabled($0)
                }))
            // Sub-option of the body-cam detector, laid out like the drone-OUI one above: inset,
            // and disabled while the parent category is off (classification needs both switches).
            // The broad Motorola Solutions OUI is a vendor proxy, not a camera signature, so the
            // same blocks cover their two-way radios and docks. Turning it off is the way to quiet
            // that noise WITHOUT losing the Axon payload match, which is the whole point of the
            // split. Hidden entirely on pre-split firmware, which has no such switch to write to.
            if ble.motorolaSupported {
                // "off keeps Axon running" read as a riddle: off WHAT, and why is Axon involved.
                // Say what the switch matches and what it costs you, and let the parent row's
                // "Axon · Utility BodyWorn · Motorola vendor match" carry the rest.
                radioToggle("motorola solutions", "vendor match only \u{00B7} their radios and docks too", isOn: Binding(
                    get: { motorolaOn }, set: {
                        motorolaOn = $0; pendingMotorola = true
                        awaitConfirmation(.motorola); ble.setMotorolaEnabled($0)
                    }))
                    .padding(.leading, 22)
                    .disabled(!bodyCamOn)
                    .opacity(bodyCamOn ? 1 : 0.4)
            }
            Divider().overlay(ACABTheme.line)
            radioToggle("bluetooth trackers", "AirTag \u{00B7} Tile \u{00B7} SmartTag \u{00B7} opt-in", isOn: Binding(
                get: { trackerOn }, set: {
                    trackerOn = $0; pendingTracker = true
                    awaitConfirmation(.tracker); ble.setTrackerEnabled($0)
                }))
            Divider().overlay(ACABTheme.line)
            radioToggle("recording glasses", "Ray-Ban / Oakley Meta \u{00B7} Snap \u{00B7} Vuzix \u{00B7} Luxottica \u{00B7} experimental", isOn: Binding(
                get: { glassesOn }, set: {
                    glassesOn = $0; pendingGlasses = true
                    awaitConfirmation(.glasses); ble.setGlassesEnabled($0)
                }), exp: true)
            Divider().overlay(ACABTheme.line)
            // Opt-in, off by default: enabling it turns on the board's 802.11 DATA-frame
            // source-MAC path (added CPU + 2.4GHz load), which is why it is gated. Honest copy:
            // it matches known IP-camera BRANDS on the host WiFi and cannot find every camera.
            radioToggle("network cameras", "known IP-camera brands on wifi, opt-in, cannot find every camera", isOn: Binding(
                get: { netcamOn }, set: {
                    netcamOn = $0; pendingNetcam = true
                    awaitConfirmation(.netcam); ble.setNetcamEnabled($0)
                }))
        }
        .panel()
    }

    // MARK: offline buffer
    // Board-side flash buffer: record while the phone is away, replay on reconnect.
    private var offlineBufferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("OFFLINE BUFFER")
            // A buffer control must not look trustworthy while firmware says evidence was lost
            // or a privacy/lifecycle write is still retrying. Logbook shows the same notices.
            ForEach(ble.status?.bufferHealthNotices ?? [], id: \.self) {
                BufferHealthBanner(notice: $0)
            }
            radioToggle("store detections offline", "board buffers while away \u{00B7} replays on reconnect", isOn: Binding(
                get: { bufferOn }, set: {
                    bufferOn = $0; pendingBuffer = true
                    awaitConfirmation(.buffer); ble.setBufferingEnabled($0)
                }))
            if shouldOfferBufferClear(
                isDemoMode: ble.demoMode,
                bufferOn: bufferOn,
                bufferedCount: ble.status?.bufCount ?? 0,
                keyMismatch: ble.status?.bufferKeyMismatch == true,
                wiping: ble.bufferWiping
            ) {
                Divider().overlay(ACABTheme.line)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("buffered log").font(ACABTheme.display(14, weight: .medium))
                            .foregroundStyle(ACABTheme.text)
                        // While the board is still sweeping a deferred erase, say so rather than
                        // inviting another erase against an about-to-be-zero count.
                        Text(ble.bufferWiping ? "clearing buffer\u{2026}" : "erase what the board stored while away")
                            .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                    if ble.bufferWiping {
                        Text("CLEARING").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                    } else {
                        Button { confirmEraseBuffer = true } label: {
                            Text("ERASE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                                .foregroundStyle(ACABTheme.accentText)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                                .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .panel()
    }

    // Board LED: on by default (a slow idle heartbeat + detection flashes, so it visibly runs);
    // "lights out" takes it fully dark for covert or stationary deploys. Persists on the board.
    private var lightsOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("BOARD LED")
            radioToggle("lights out", "no LEDs \u{00B7} for covert or stationary deploys", isOn: Binding(
                get: { lightsOut }, set: {
                    lightsOut = $0; pendingLed = true
                    awaitConfirmation(.led); ble.setLedEnabled(!$0)
                }))
            Text("On by default the board LED gives a slow heartbeat so you can see it's alive, and flashes on a hit. Lights out keeps it completely dark.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    // MARK: Live Mode (Live Activity)
    private var driveModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("LIVE MODE")

            HStack(spacing: 9) {
                Circle()
                    .fill((liveModeState == "Active" || liveModeState == "Preview on") ? ACABTheme.accent
                          : ((liveModeState == "Blocked by iOS" || liveModeState == "Location needed")
                             ? ACABTheme.warn : ACABTheme.faint))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(liveModeState)
                        .font(ACABTheme.display(14, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                    Text(liveModeStatusDetail)
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live Mode status, \(liveModeState). \(liveModeStatusDetail)")

            Divider().overlay(ACABTheme.line)
            radioToggle("live activity counter",
                        "lock screen + supported system surfaces \u{00B7} nearby-now count while the beacon is connected",
                        isOn: Binding(get: { ble.settingsDriveModeWanted },
                                      set: { on in if on { ble.startDriveMode() } else { ble.endDriveMode() } }))
            Divider().overlay(ACABTheme.line)
            // SCOPE, and it is NARROWER than the Android twin on purpose. Here this switch governs
            // the Live Activity alone, which is exactly what the subtitle claims. Android's
            // same-named toggle also strips the category from a locked per-detection alert and the
            // count from the Android 16 status-bar chip (see _redactLockScreen in AcabBleManager),
            // so its subtitle names three surfaces where this one names one. Both are accurate
            // about their own platform; on this product a toggle may be quieter than advertised,
            // never louder, so the fix was to widen the Android copy, not to widen this behaviour.
            radioToggle("hide counts on lock screen",
                        "show only \u{201C}Live Mode active\u{201D} when locked \u{00B7} counts stay in the app + other supported surfaces",
                        isOn: Binding(get: { ble.settingsRedactLockScreen },
                                      set: { ble.setSettingsRedactLockScreen($0) }))
            if !ble.demoMode, !ble.liveActivitiesEnabled {
                Text("iOS is blocking Live Activities for beacons. Turn them on in Settings to show Live Mode on system surfaces.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                openSettingsButton
            } else if liveModeState == "Location needed" {
                Text("Location keeps Live Mode current when the app is in the background. Detection still works if you decline, but the system surface stays off.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                if ble.locationDenied {
                    openSettingsButton
                } else {
                    Button("ENABLE LOCATION") { ble.requestLocationAccessIfNeeded() }
                        .font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.7)
                        .foregroundStyle(ACABTheme.accentText)
                        .frame(minHeight: 44)
                }
            }
        }
        .panel()
    }

    private var liveModeStatusDetail: String {
        if ble.demoMode, liveModeState == "Off" {
            return "Sample preview only. Your saved setting and system surfaces stay unchanged."
        }
        switch liveModeState {
        case "Active": return "The Live Activity is running on supported system surfaces."
        case "Preview on": return "Sample preview only. Your saved setting and system surfaces stay unchanged."
        case "Waiting for beacon": return "Ready to start automatically when the beacon link is ready."
        case "Location needed": return "Allow Location to keep the Live Activity reliable in the background."
        case "Blocked by iOS": return "Live Activities are disabled in system settings."
        default: return "Live Mode system surfaces are disabled."
        }
    }

    // MARK: desert mode (report every device)
    private var desertModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("DESERT MODE")
            radioToggle("report every device",
                        "show + log ANY device nearby \u{00B7} best out in the open",
                        isOn: Binding(get: { desertOn },
                                      set: {
                                          desertOn = $0; pendingDesert = true
                                          awaitConfirmation(.desert); ble.setDesertMode($0)
                                      }))
            Text("Off the grid, anything new on the air means something arrived. Each device is tagged hardware or randomized (phone) MAC, or OUI unknown when the radio cannot tell.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if desertOn {
                // The startup jingle is NOT exempt from the mute (alerts.cpp, 2026-08-24: the boot
                // motif is a UserAlert, so a muted board never announces itself - an unattended
                // power restore is indistinguishable from a hand on the plug). The shutdown motif
                // is the cue that still plays muted. Said plainly here so a user who mutes the
                // board, power-cycles it and hears nothing does not read silence as a dead board.
                // Worded as the JINGLE, not as "starts silently": the rev-B hold-to-start ack is a
                // separate cue and does still chirp through the mute.
                Text("Detection alerts are muted while Desert mode runs. With every nearby device reporting in, a beep for each would never let up. The shutdown cue still plays unless volume is 0; the startup jingle is muted along with everything else.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Desert is over and the alert mode stayed Silent. Nothing above says so, and a user
            // who left Desert expecting their beeps back reads the silence as a dead detector.
            // faint, the same tone as the secondary line above, NEVER warn: this reports a state
            // the user can leave from the Alerts row, and it is not an alert.
            //
            // When the app is holding a mode to give back, THIS SAME PLACE carries the tap instead
            // of stacking a second sentence about the same silence next to the first.
            switch desertSilenceSlot(
                restoreOffered: alertRestoreOffered,
                noticeApplies: shouldShowDesertSilenceNotice(
                    sawDesertOn: ble.desertRanThisRun,
                    desertOn: desertOn,
                    alertsSilent: ble.alertMode == .silent,
                    isMeshDetect: ble.status?.isMeshDetect == true)) {
            case .notice:
                Text(desertSilenceNotice)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            case .offer:
                AlertRestoreOffer()
            case .none:
                EmptyView()
            }
        }
        .panel()
    }

    /// This screen's read of the one sample-tour gate. The expression itself lives at file scope
    /// (alertRestoreIsOffered) because the pre-connect screen asks the same question through
    /// RootView, and a gate spelled twice is a gate that can drift on one screen.
    private var alertRestoreOffered: Bool {
        alertRestoreIsOffered(isDemoMode: ble.demoMode, pending: ble.pendingAlertModeRestore)
    }

    private func radioToggle(_ name: String, _ sub: String,
                             isOn: Binding<Bool>, exp: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    if exp { ExpTag() }
                }
                Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
        }
        .tint(ACABTheme.accent)
        .accessibilityLabel(spokenControlText(name))
        .accessibilityHint((exp ? "Experimental. " : "") + spokenControlText(sub))
    }

    /// VoiceOver should speak the domain abbreviations as concepts, not guess at strings such as
    /// ALPR, OUI, RID, and MAC. Visible copy stays compact; only the spoken surface expands it.
    private func spokenControlText(_ text: String) -> String {
        var spoken = text
        let expansions = [
            (#"(?i)\bALPR\b"#, "automatic license plate reader"),
            (#"(?i)\bOUI\b"#, "vendor address prefix"),
            (#"(?i)\bremote ID\b"#, "remote identification"),
            (#"(?i)\bRID\b"#, "remote identification"),
            (#"(?i)\bMAC\b"#, "hardware address"),
            (#"(?i)\bBLE\b"#, "Bluetooth Low Energy"),
        ]
        for (pattern, replacement) in expansions {
            spoken = spoken.replacingOccurrences(of: pattern, with: replacement,
                                                  options: .regularExpression)
        }
        return spoken
    }

    // MARK: alerts
    private var buzzerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("ALERTS")

            alertModePicker

            Text(alertModeCaption)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            // The SAME offer the Desert card carries, so whichever of the two rows the user opens
            // has the way back in it. No gate of its own beyond "a mode is pending": this card is
            // already skipped on a mesh board (hardwareConfigPanel), and the pending mode is cleared
            // the moment Desert comes back on or the user picks anything by hand.
            if alertRestoreOffered { AlertRestoreOffer() }

            // LIVE IN ALL THREE MODES. Vibrate and Silent turn detection beeps off, so the only
            // thing this level still governs there is the shutdown cue the caption above names -
            // and volume 0 is the ONLY thing that silences it (firmware alerts.cpp buzzerTone: a
            // PowerState cue bypasses the alert mute, a zero volume does not). Greying the slider
            // out in those two modes made the remedy their own copy names unreachable from them.
            // Android twin: the same rule on VolumeSlider in DeviceScreen.kt's BuzzerCard.
            VStack(spacing: 14) {
                slider("Master volume", value: $master, tone: ACABTheme.accent, bold: true,
                       onEditing: { editing in if editing { pendingVolume = true } }) {
                    awaitConfirmation(.volume)
                    // Round, don't truncate: the echo check compares against Int(master.rounded()),
                    // so a truncated send (49.7 -> 49) could never match and would false-timeout.
                    // The preview chirp is a detection-alert sound, so ask for it only in Buzzer
                    // mode. The board plays it as a UserAlert and therefore already drops it while
                    // alerts are muted; asking only when it can be heard keeps the request honest.
                    ble.setVolume(Int(master.rounded()), preview: ble.alertMode == .buzzer)
                }
            }
        }
        .panel()
    }

    // MARK: phone notifications
    //
    // A SEPARATE card from ALERTS on purpose. ALERTS picks how the BOARD behaves (buzzer / vibrate
    // / silent); this picks which categories are worth interrupting you for on the PHONE. Folding
    // them together implied a dependency that does not exist: a silent board with notifications on
    // is a perfectly normal setup, and arguably the main one for a device you keep in a bag.
    private var notifyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("PHONE NOTIFICATIONS")

            if !ble.demoMode, ble.notifier.mutedBySystem {
                // A green toggle over a dead feature is the worst outcome here: the user believes
                // they are covered. Say it plainly instead.
                Text("iOS is blocking these. Turn notifications on for beacons in Settings, or nothing here will arrive.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                openSettingsButton
            }

            Text(ble.demoMode
                 ? "Preview which categories you could enable. Nothing is saved and iOS won't ask permission."
                 : "Pick what's worth a notification. Every category is off until you turn it on, and iOS asks permission the first time you do.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(DetectionNotifier.notifiableTypes, id: \.self) { t in
                    let on = ble.phoneNotificationEnabled(t)
                    VStack(alignment: .leading, spacing: 4) {
                        radioToggle(t.label, notifySubtitle(t), isOn: Binding(
                            get: { on },
                            set: { v in
                                ble.setPhoneNotificationEnabled(v, for: t)
                            }), exp: t.isExperimental)
                        // A notification for a detector the BOARD is not running can never fire.
                        // Left unsaid, that is the worst kind of dead switch: it reads as coverage.
                        // Only shown once the toggle is on, so the card is not a wall of warnings.
                        // The name is DeviceType.inlineLabel, not `label.lowercased()`, which
                        // flattened the ALPR initialism to "the alpr camera detector". Android
                        // DeviceScreen.kt notifyDetectorOffWarning writes the same sentence; keep
                        // the two in step.
                        if on, detectorIsOff(t) {
                            Text("the \(t.inlineLabel) detector is off, so this won't fire. turn it on under Detectors.")
                                .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Text("The same device won't notify again for ten minutes, so one camera can't keep buzzing you. Muted devices never notify at all.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    /// True when the board is NOT running the detector behind this notification category, so the
    /// toggle cannot ever fire. Returns false when no status has arrived (do not cry wolf) and for
    /// `.watched`, which has no detector switch: the watchlist is always live.
    private func detectorIsOff(_ t: DeviceType) -> Bool {
        guard let s = ble.status else { return false }
        switch t {
        case .flockCamera, .flockRaven: return !s.flock
        case .drone:                    return !s.drone
        case .axonBodyCam:              return !s.axon
        case .tracker:                  return !s.tracker
        case .recordingGlasses:         return !s.glasses
        case .networkCamera:            return !s.ncam
        case .watched, .nearbyDevice, .unknown: return false
        }
    }

    private func notifySubtitle(_ t: DeviceType) -> String {
        switch t {
        case .flockCamera:              return "plate readers"
        case .axonBodyCam:              return "worn cameras"
        case .recordingGlasses:         return "camera glasses"
        case .networkCamera:            return "cameras on nearby wifi"
        case .drone:                    return "remote ID broadcasts"
        case .tracker:                  return "separated AirTag \u{00B7} Tile \u{00B7} SmartTag"
        case .watched:                  return "devices you starred"
        default:                        return ""
        }
    }

    // Themed 3-way switch: one joined capsule of equal segments split by hairlines,
    // the active one filled with the accent. Rolled our own because a stock
    // .segmented Picker won't match the theme. Same anatomy as Android.
    private var alertModePicker: some View {
        HStack(spacing: 0) {
            segment("Buzzer",  .buzzer)
            segmentDivider
            segment("Vibrate", .vibrate)
            segmentDivider
            segment("Silent",  .silent)
        }
        // minHeight 44, up from a fixed 36: each third of the capsule is its own tap target, and
        // 36pt was under the minimum. minHeight (not height) because the segment labels scale
        // with Dynamic Type; a pinned capsule clipped them at accessibility sizes. Same anatomy
        // otherwise.
        .frame(minHeight: 44)
        .background(ACABTheme.bg2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var segmentDivider: some View {
        Rectangle().fill(ACABTheme.line).frame(width: 1)
    }

    private func segment(_ label: String, _ mode: AlertMode) -> some View {
        let active = ble.alertMode == mode
        return Button { ble.setAlertMode(mode, origin: .user) } label: {
            Text(label)
                .font(ACABTheme.mono(11.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? ACABTheme.accent : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// "3 ON" / "OFF", so the collapsed row says whether anything will interrupt you.
    private var notifyKicker: String {
        let n = DetectionNotifier.notifiableTypes.filter {
            ble.phoneNotificationEnabled($0)
        }.count
        if !ble.demoMode, ble.notifier.mutedBySystem, n > 0 {
            return "\(n) ON \u{00B7} BLOCKED BY IOS"
        }
        return n == 0 ? "OFF" : "\(n) ON"
    }

    private var openSettingsButton: some View {
        Button(action: openAppSettings) {
            Text("OPEN SETTINGS")
                .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                .foregroundStyle(ACABTheme.accentText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                    .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this app's iOS settings")
    }

    /// "power cues" used to cover the boot jingle too, which the board no longer plays while muted
    /// (alerts.cpp 2026-08-24: the boot motif is a UserAlert, so mute wins; see the Desert-mode
    /// note above). Two cues still bypass the mute, both PowerState: the shutdown motif and the
    /// rev-B hold-to-start ack. Only the shutdown one is named here, because it is the one every
    /// SKU plays and the one a muted user is surprised by; the ack always directly follows the
    /// user's own hold on the button, so it explains itself. Volume 0 silences both.
    /// Android twin: DeviceScreen.kt's BuzzerCard. Buzzer and Silent are byte-identical there and
    /// MUST stay so. Vibrate is NOT, deliberately: these haptics are UIKit feedback generators, so
    /// they only fire while the app is foregrounded, which is why this string adds the scope
    /// qualifier and the Live Mode pointer. Android's haptic fires in AcabBleManager.alertHaptic
    /// on the detection ingest path, and it does buzz with the screen locked while Live Mode's
    /// foreground service keeps ingest alive - so the qualifier would be wrong there. The
    /// alert-modes paragraph in README.md records the difference. Sync the other two strings
    /// freely; do not converge this one without changing the behaviour first.
    private var alertModeCaption: String {
        switch ble.alertMode {
        case .buzzer:  return "board beeps when it spots gear"
        case .vibrate: return "detection beeps off, the shutdown cue still plays unless volume is 0. This phone buzzes on new hits while the app is open. Use Live Mode for locked-screen alerts."
        case .silent:  return "detection beeps and phone feedback off, the shutdown cue still plays unless volume is 0"
        }
    }

    private func slider(_ label: String, value: Binding<Double>, tone: Color,
                        bold: Bool = false, onEditing: ((Bool) -> Void)? = nil,
                        onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(ACABTheme.display(14, weight: bold ? .medium : .regular)).foregroundStyle(ACABTheme.text)
                Spacer()
                // Always the number, in every alert mode. It used to read "-" outside Buzzer, which
                // hid the one value a Vibrate/Silent user needs to see: the caption there names
                // volume 0 as the only thing that still silences the shutdown cue, and a dash
                // cannot tell them whether they are already at it. Android twin: VolumeSlider in
                // DeviceScreen.kt, which prints value.toInt() unconditionally.
                Text("\(Int(value.wrappedValue))")
                    .font(ACABTheme.mono(12, weight: .semibold)).foregroundStyle(tone)
            }
            Slider(value: value, in: 0...100, step: 1) { editing in
                onEditing?(editing)
                if !editing { onCommit() }
            }
                .tint(tone)
        }
    }

    // MARK: stats
    /// Glanceable stats that stay open: uptime + total detections (2-up). Alert/scanning
    /// state now lives in the fold-row kickers, so those tiles are gone.
    /// DETECTIONS is the PHONE-SIDE LOG count, including retained evidence hidden by active mutes.
    ///
    /// It used to read the board's since-boot session total (status "total"), and the comment even
    /// claimed that was "the same source as Android" - it was not: Android has always shown the
    /// phone log. The board total is a different number that Clear cannot lower (it only resets on a
    /// power cycle) and that Desert mode inflates into the tens of thousands, so it read as a
    /// runaway counter the user could not reconcile with a log they had just cleared. The phone log
    /// responds to Clear, matches what the Log tab holds, and now agrees across both platforms.
    private var statsGrid: some View {
        // One column at accessibility sizes: half-width tiles truncate their values once the
        // type doubles. Two-up otherwise, unchanged.
        let cols = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            statTile("UPTIME", hasCurrentBoardStatus ? (ble.status.map(uptimeText) ?? "-") : "-")
            statTile("DETECTIONS", "\(ble.logDetections.count)")
        }
    }

    private func statTile(_ kick: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(kick)
            Text(value).font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
    }

    private func uptimeText(_ s: DeviceStatus) -> String {
        let h = s.uptime / 3600, m = (s.uptime % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var disconnectButton: some View {
        // Block Disconnect while an update is running: a mid-reboot teardown races the OTA reconnect
        // (and can drop into a pending-connect cancel that fires no callback), so keep the link put
        // until the flow reaches a terminal state. Sample data isn't an update, so it stays tappable.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button(role: .destructive) { ble.demoMode ? ble.exitDemo() : ble.disconnect() } label: {
            Text(ble.demoMode ? "Exit sample data" : "Disconnect")
                .font(ACABTheme.display(15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(ACABTheme.accentText)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius).strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .disabled(otaRunning)
        .opacity(otaRunning ? 0.5 : 1)
    }

    // Only offer the app power-off on rev-B: on a rev-A slide board the firmware would re-wake
    // instantly (the slide holds the wake line low), so the drain no-ops there. Demo mode has no
    // real board to shut down. Absent boardRev (older firmware without the poweroff handler) also
    // hides it, so the button never appears where it would do nothing.
    private var showPowerOff: Bool {
        !ble.demoMode && hasCurrentBoardStatus && ble.status?.boardRev == "B"
    }

    private var powerOffButton: some View {
        // Same block as Disconnect, and blocked during an update for the same reason (a power-off
        // mid-OTA would strand the flow). Tapping only opens the confirm; the actual shutdown is
        // irreversible from the app, so it must be deliberate.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button(role: .destructive) { confirmPowerOff = true } label: {
            Text("Power off beacon")
                .font(ACABTheme.display(15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(ACABTheme.accentText)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius).strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .disabled(otaRunning || !hardwareControlsEnabled)
        .opacity((otaRunning || !hardwareControlsEnabled) ? 0.5 : 1)
        // Anchored to the BUTTON, not stacked on the NavigationStack next to the buffer-erase dialog:
        // two .confirmationDialog modifiers on the same view fight over the presentation anchor, which
        // is why the sheet pointed at the wrong (top) row. On its own trigger view it anchors here.
        .confirmationDialog(
            "Power off the beacon?",
            isPresented: $confirmPowerOff, titleVisibility: .visible
        ) {
            Button("Power off", role: .destructive) { ble.powerOffBeacon() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The beacon shuts down and stops detecting. You'll turn it back on with the button on the device (hold it for about a second). It can't be powered back on from the app.")
        }
    }

    // MARK: watched (starred) devices

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameMac != nil }, set: { if !$0 { renameMac = nil } })
    }

    private var watchedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Kicker("WATCHING", color: ACABTheme.watchTone)
                Spacer()
                // The board echoes how many MACs it's watching at the source.
                if let n = ble.status?.watchCount, n > 0 {
                    Kicker("\(n) ON BOARD", color: ACABTheme.dim)
                }
            }
            ForEach(ble.watched) { dev in
                HStack(spacing: 10) {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(ACABTheme.watchTone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased()).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer(minLength: 8)
                    Button {
                        renameText = dev.label
                        renameIsIgnored = false
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(width: 44, height: 44)   // 44pt hit target; glyph size unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unwatch(dev.mac) } label: {
                        Text("UNSTAR").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.watchTone)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.watchTone.opacity(0.4), lineWidth: 1))
                            .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.watched.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    // MARK: muted devices
    private var ignoredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Kicker("MUTED")
                Spacer()
                // The board echoes how many MACs it's suppressing at the source.
                if let n = ble.status?.ignoreCount, n > 0 {
                    Kicker("\(n) ON BOARD", color: ACABTheme.dim)
                }
            }
            ForEach(ble.ignored) { dev in
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 12)).foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased()).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                        Text(dev.scopeLabel.uppercased()).font(ACABTheme.mono(9)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer(minLength: 8)
                    // Naming a muted device matters as much as naming a starred one: six weeks on,
                    // "my own AirTag" is the difference between trusting the mute and undoing it.
                    Button {
                        renameText = dev.label
                        renameIsIgnored = true
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(width: 44, height: 44)   // 44pt hit target; glyph size unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unignore(dev.mac) } label: {
                        Text("UNMUTE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.accentText)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                            .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.ignored.last?.id { Divider().overlay(ACABTheme.line) }
            }
            if ble.boardOnlyMuteCount > 0 {
                if !ble.ignored.isEmpty { Divider().overlay(ACABTheme.line) }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(ble.boardOnlyMuteCount) board-only mute\(ble.boardOnlyMuteCount == 1 ? "" : "s")")
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                        Text("Created from another phone. This beacon reports only the count, so this phone cannot show or remove those devices individually.")
                            .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    // MARK: display
    //
    // "always use higher contrast": OFF follows the iOS Increase Contrast setting, ON forces the
    // higher-contrast palette. Named that way, rather than "higher contrast", so a user whose
    // iOS setting is on understands why turning this off changes nothing. The palette itself
    // lives in ACABTheme; this card only flips the window trait (ContrastPreference).
    // Android twin: DisplayCard in DeviceScreen.kt.
    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("DISPLAY")
            radioToggle("always use higher contrast",
                        "brighter secondary text and clearer control edges \u{00B7} off follows the system contrast settings",
                        isOn: $contrast.alwaysHigher)
            Text(contrast.systemIncreased
                 ? "iOS increase contrast is on, so higher contrast stays on while this switch is off."
                 : "text size and bold text follow the iOS settings.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private var displayKicker: String {
        if contrast.alwaysHigher { return "HIGHER CONTRAST \u{00B7} ALWAYS" }
        if contrast.systemIncreased { return "HIGHER CONTRAST \u{00B7} FROM IOS" }
        return "DEFAULT CONTRAST"
    }

    // MARK: about
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("ABOUT")
            Text("built for the beacon. also works on the Colonel Panic hardware.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ACABTheme.line)
            linkRow("soyboi.tech", "the beacon board",
                    URL(string: "https://soyboi.tech")!)
            Divider().overlay(ACABTheme.line)
            linkRow("How it detects", "what it can and can't see",
                    URL(string: "https://soyboi.tech/how-it-detects.html")!)
            Divider().overlay(ACABTheme.line)
            linkRow("Source on GitHub", "github.com/soyboi1312/all-cameras-are-beacons",
                    URL(string: "https://github.com/soyboi1312/all-cameras-are-beacons")!)
            if !fwLabel.hasPrefix("beacon board") {
                Divider().overlay(ACABTheme.line)
                linkRow("Colonel Panic", "colonelpanic.tech \u{00B7} OUI-Spy hardware",
                        URL(string: "https://colonelpanic.tech")!)
            }
            Divider().overlay(ACABTheme.line)
            // "no data leaves your device" stopped being true the day explicit export and the
            // contribution flow shipped. Link the repository's canonical policy directly: the
            // old soyboi.tech copy drifted and falsely said the GPS fix never left the phone.
            linkRow("Privacy", "nothing is uploaded automatically",
                    URL(string: "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html")!)
            Link(destination: URL(string: "https://github.com/soyboi1312")!) {
                Text("made by soyboi")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .panel()
    }

    private func linkRow(_ title: String, _ sub: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
