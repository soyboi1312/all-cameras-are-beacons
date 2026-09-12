import Foundation

/// Semantic emphasis for Beacon/Status copy. Views map this to their own palette so the pure
/// presenter stays reusable and testable without importing SwiftUI.
enum BeaconPresentationTone: Equatable {
    case accent
    case neutral
    case warning
}

/// One truthful interpretation of the phone link and the board's two detection radios.
///
/// `connectionLabel` names the phone-to-beacon link. `scanLabel` names detection coverage. They are
/// deliberately separate: a healthy encrypted BLE control link can coexist with both detection
/// radios switched off, while an nRF fault can leave Wi-Fi detection running.
///
/// `scanLabel` fills BOTH the Status hero and the Beacon tab's "Scan radios" fold row, and it is
/// the SHARED wording: android StatusScreen.kt `statusScanPresentation` and DeviceScreen.kt
/// `beaconRadioStatusLabel` return the same strings for the same connected board state and in
/// sample mode, apart from the one exception named on `beaconRadioPresentation` below. All three
/// move together, sample mode included. BOTH tours echo their sample radio switches into the
/// synthetic status (here through `demoStatusKeyByConfigKey` in BLEManager.swift, which maps
/// "ble"/"wifi" writes into the canned frame; Android through previewDemoStatusToggle), and BOTH
/// presenters now read that echo the same way, printing the same four labels ("SAMPLE DATA",
/// "SAMPLE DATA · BLUETOOTH ONLY", "SAMPLE DATA · WI-FI ONLY", "SAMPLE DATA · RADIOS OFF") and
/// sweeping the radar whenever either sample radio is on. Sample mode was the last deliberate
/// wording split in this file; do not reintroduce it.
struct BeaconRadioPresentation: Equatable {
    let connectionLabel: String
    let scanLabel: String
    let detail: String
    let isScanning: Bool
    let tone: BeaconPresentationTone

    /// Compact wording for the shared header pill. The longer connection and scan labels retain
    /// the full explanation beside the hero; this stays short enough for narrow phones and large
    /// Dynamic Type without collapsing the page title. TWIN: android StatusScreen.kt
    /// `statusLinkChipLabel`, which ranks the same facts in the same order for every state its
    /// Status screen shows uncovered (DEMO, RECONNECTING, WAITING, UPDATING, RADIO FAULT,
    /// CONNECTED). DashboardPresentationTests and StatusBeaconPresentationTest pin the order.
    var chipLabel: String {
        switch connectionLabel {
        case "SAMPLE DATA":                       return "DEMO"
        case "CONNECTED OVER BLE":                return "CONNECTED"
        case "CONNECTED · UPDATING", "UPDATING FIRMWARE":
            return "UPDATING"
        case "RECONNECTING":                      return "RECONNECTING"
        case "CONNECTED · SECURING LINK":         return "SECURING"
        case "CONNECTED · WAITING FOR STATUS":    return "WAITING"
        case "CONNECTED · RADIO FAULT":           return "RADIO FAULT"
        case "IPHONE BLUETOOTH OFF":              return "BT OFF"
        case "BLUETOOTH PERMISSION NEEDED":       return "BT PERMISSION"
        case "CONNECTING":                        return "CONNECTING"
        case "LOOKING FOR BEACON":                return "SEARCHING"
        case "CHECKING BLUETOOTH":                return "CHECKING"
        default:                                   return "OFFLINE"
        }
    }
}

/// Resolve connection and scanning state without treating absent status as an all-clear.
///
/// The app can retain its tab shell while reconnecting, and `.connected` alone is only a transport
/// fact. Radio claims therefore require the encrypted session plus a current DeviceStatus frame.
/// A combined update can span download, S3 transfer, reboot, and nRF DFU, so only the board's
/// explicit `nrfUpdating` bit permits the narrower "Wi-Fi still scanning" statement.
///
/// ARM ORDER IS SHARED with android StatusScreen.kt `statusScanPresentation`, and `chipLabel`
/// follows it as `statusLinkChipLabel` does there: sample mode, then the link facts (an
/// unexpected drop's reconnect, this app's own update reboot, the connection state, the secure
/// session, the first frame), then the board's own `nrfUpdating` bit, then the coordinator's
/// running flag, then the radios. Android has no connection-state or secure-session input (its
/// Status screen is uncovered only at READY or in the reconnect shell), so its link facts are the
/// reconnect, the update reboot and the first frame, in that order. So an unexpected drop in the
/// middle of a combined update reads RECONNECTING on both phones, and the gap before the first
/// frame after it reads CONNECTED · WAITING FOR BOARD STATUS under a WAITING pill; the
/// coordinator's sentence returns once a frame is in hand.
///
/// THE UPDATE REBOOT IS A LINK FACT ON BOTH PHONES. `isRebootingForUpdate` has an Android twin in
/// the same slot: `rebootingForUpdate` in StatusScreen.kt, which is `otaPhaseIsUpdateReboot`
/// (OtaPhase REBOOTING or CONFIRMING). Both read UPDATING FIRMWARE · DETECTION MAY PAUSE under an
/// UPDATING pill until the run confirms or fails. That includes the gap between the reboot's
/// reconnect and its first frame, where this app still holds the pre-reboot frame and Android's
/// reboot drop has cleared its own. Both suites pin those combinations
/// (DashboardPresentationTests, StatusBeaconPresentationTest). `isRebootingForUpdate` defaults to
/// false so presenter tests can leave it out, which means a view call site can too: DashboardView
/// and SettingsView `radioPresentation` must pass `ble.isRebootingForUpdate`.
///
/// ONE EXCEPTION, on DeviceScreen.kt `beaconRadioStatusLabel`, the Android Beacon row: past the
/// link facts it ranks the coordinator's CHECKING, UPDATING_S3 and RECONNECTING phases above the
/// nrfup bit, so outside the update reboot it differs only for a frame that carries nrfup during
/// one of those phases. That row now has its own update-reboot arm, in the slot this presenter
/// and the Android Status header give it (above the missing frame), so the reboot's no-frame gap
/// reads UPDATING FIRMWARE · DETECTION MAY PAUSE on all three.
func beaconRadioPresentation(connectionState: BLEConnectionState,
                             sessionReady: Bool,
                             isReconnecting: Bool,
                             isDemoMode: Bool,
                             status: DeviceStatus?,
                             combinedUpdateRunning: Bool,
                             isRebootingForUpdate: Bool = false) -> BeaconRadioPresentation {
    // Sample mode READS the frame. The tour's radio switches echo into it (writeConfig ->
    // demoStatusKeyByConfigKey), so name them and let the radar sweep follow them, which is what
    // Android's statusScanPresentation has always done. This used to return a flat
    // "SAMPLE DATA · NO LIVE RADIOS" with isScanning false, which parked the beam for the whole
    // tour and made the two phones look like different apps on their first screen.
    //
    // `isScanning` here drives the radar beam and nothing about real hardware: enterDemo sets
    // demoMode and the seeded frame ("ble": true, "wifi": true) in the same synchronous block, so
    // there is no window where the tour renders RADIOS OFF before the frame lands. The screen
    // still says SAMPLE DATA in the header pill, the kicker and the banner, so a turning beam
    // cannot be mistaken for a live all-clear.
    if isDemoMode {
        let bleOn = status?.ble == true
        let wifiOn = status?.wifi == true
        let scanLabel: String
        switch (bleOn, wifiOn) {
        case (true, true):   scanLabel = "SAMPLE DATA"
        case (true, false):  scanLabel = "SAMPLE DATA · BLUETOOTH ONLY"
        case (false, true):  scanLabel = "SAMPLE DATA · WI-FI ONLY"
        case (false, false): scanLabel = "SAMPLE DATA · RADIOS OFF"
        }
        return BeaconRadioPresentation(
            connectionLabel: "SAMPLE DATA",
            scanLabel: scanLabel,
            detail: "Preview data only; these are the tour's sample radio switches, not a live beacon.",
            isScanning: bleOn || wifiOn,
            tone: .neutral)
    }

    // Link facts first, the coordinator after them. An unexpected drop while the co-processor leg
    // is past its point of no return keeps the coordinator running through the reconnect
    // (BLEManager cancelUpdatesForLinkTeardown parks it in .verifying; didDisconnectPeripheral's
    // wasReady branch arms the reconnect and clears `status`), so this combination is real, and
    // the truthful line for it is the reconnect, which is the line Android prints too.
    if isReconnecting {
        return BeaconRadioPresentation(
            connectionLabel: "RECONNECTING",
            scanLabel: "RECONNECTING · BOARD STATUS UNAVAILABLE",
            detail: "Trying to restore the encrypted beacon link.",
            isScanning: false,
            tone: .neutral)
    }

    // This app's own update reboot, a link fact of its own. isRebootingForUpdate is set from the
    // reboot command until the rebooted board confirms or the wait is abandoned, so the window
    // spans the drop, the reconnect and the confirm. The OTA engine holds the link through it:
    // didDisconnectPeripheral returns through otaHandleDisconnect before it clears `status`, and
    // nothing on that path writes `connectionState` (disconnect() notes the public state stays
    // connected during the reboot wait). So the presenter sees .connected throughout, the session
    // down until the reconnect, and the pre-reboot frame in `status` until a fresh one lands.
    // Without this arm the sessionReady guard below claimed the reboot and the header read
    // SECURING, dropping the keep-the-app-open line the rollback-disarm confirm needs. Every OTA
    // here runs under the combined coordinator (startFirmwareUpdate's only callers are in
    // BLEManager+CombinedUpdate.swift), so this arm does not also check combinedUpdateRunning.
    if isRebootingForUpdate {
        return BeaconRadioPresentation(
            connectionLabel: "UPDATING FIRMWARE",
            scanLabel: "UPDATING FIRMWARE · DETECTION MAY PAUSE",
            detail: "Keep the app open and the beacon nearby until the update finishes.",
            isScanning: false,
            tone: .neutral)
    }

    guard connectionState == .connected else {
        switch connectionState {
        case .poweredOff:
            return BeaconRadioPresentation(
                connectionLabel: "IPHONE BLUETOOTH OFF",
                scanLabel: "IPHONE BLUETOOTH OFF · BOARD STATUS UNAVAILABLE",
                detail: "Turn on Bluetooth to reconnect to the beacon.",
                isScanning: false,
                tone: .warning)
        case .unauthorized:
            return BeaconRadioPresentation(
                connectionLabel: "BLUETOOTH PERMISSION NEEDED",
                scanLabel: "BLUETOOTH PERMISSION NEEDED · BOARD STATUS UNAVAILABLE",
                detail: "Allow Bluetooth access to connect to the beacon.",
                isScanning: false,
                tone: .warning)
        case .connecting:
            return BeaconRadioPresentation(
                connectionLabel: "CONNECTING",
                scanLabel: "CONNECTING · BOARD STATUS UNAVAILABLE",
                detail: "Waiting for a secure beacon session.",
                isScanning: false,
                tone: .neutral)
        case .scanning:
            return BeaconRadioPresentation(
                connectionLabel: "LOOKING FOR BEACON",
                scanLabel: "LOOKING FOR BEACON · BOARD STATUS UNAVAILABLE",
                detail: "No board radio status is available until a beacon connects.",
                isScanning: false,
                tone: .neutral)
        case .idle:
            return BeaconRadioPresentation(
                connectionLabel: "NOT CONNECTED",
                scanLabel: "NOT CONNECTED · BOARD STATUS UNAVAILABLE",
                detail: "Connect to a beacon to read its detection radios.",
                isScanning: false,
                tone: .neutral)
        case .unknown:
            return BeaconRadioPresentation(
                connectionLabel: "CHECKING BLUETOOTH",
                scanLabel: "CHECKING BLUETOOTH · BOARD STATUS UNAVAILABLE",
                detail: "Waiting for iPhone Bluetooth status.",
                isScanning: false,
                tone: .neutral)
        case .connected:
            preconditionFailure("handled by guard")
        }
    }

    guard sessionReady else {
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED · SECURING LINK",
            scanLabel: "FINISHING SECURE SETUP · RADIO STATUS UNAVAILABLE",
            detail: "Waiting for the encrypted detection and configuration session.",
            isScanning: false,
            tone: .neutral)
    }
    guard let status else {
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED · WAITING FOR STATUS",
            scanLabel: "CONNECTED · WAITING FOR BOARD STATUS",
            detail: "The secure link is ready; waiting for the board's first status frame.",
            isScanning: false,
            tone: .neutral)
    }

    // This bit comes from a current board status frame. It is the one update state where we know
    // which detector is paused and whether the Wi-Fi detector remains enabled.
    if status.nrfUpdating == true {
        if status.wifi {
            return BeaconRadioPresentation(
                connectionLabel: "CONNECTED · UPDATING",
                scanLabel: "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR",
                detail: "Bluetooth detection is paused for the co-processor update; Wi-Fi scanning is on.",
                isScanning: true,
                tone: .neutral)
        }
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED · UPDATING",
            scanLabel: "UPDATING CO-PROCESSOR · NOT SCANNING",
            detail: "Bluetooth detection is paused for the update and Wi-Fi scanning is off.",
            isScanning: false,
            tone: .neutral)
    }

    // With a frame in hand and no nrfup bit, the coordinator's running flag is the only thing
    // saying the radio toggles below are about to be interrupted (HTTPS download, S3 transfer,
    // verification, and the fresh-frame wait after the board confirmed), so it outranks them.
    // The board's reboot never reaches here: the isRebootingForUpdate arm above claims it, and
    // the nil-frame guard could not, because that reboot keeps the pre-reboot frame. An
    // unexpected drop is claimed by the reconnect arm, and the gap before its first frame by the
    // nil-frame guard, because that teardown clears `status`.
    if combinedUpdateRunning {
        return BeaconRadioPresentation(
            connectionLabel: "UPDATING FIRMWARE",
            scanLabel: "UPDATING FIRMWARE · DETECTION MAY PAUSE",
            detail: "Keep the app open and the beacon nearby until the update finishes.",
            isScanning: false,
            tone: .neutral)
    }

    let coprocessorDown = status.coproc == false
    let bluetoothLive = status.ble && !coprocessorDown
    let wifiLive = status.wifi
    // A dark co-processor is a fault only when the user intended Bluetooth detection to run.
    let bluetoothFault = status.ble && coprocessorDown

    switch (bluetoothLive, wifiLive) {
    case (true, true):
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED OVER BLE",
            scanLabel: "SCANNING · BLE · WI-FI",
            detail: "Both beacon detection radios are active.",
            isScanning: true,
            tone: .accent)
    case (true, false):
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED OVER BLE",
            scanLabel: "SCANNING · BLE",
            detail: "Bluetooth detection is active; Wi-Fi scanning is off.",
            isScanning: true,
            tone: .accent)
    case (false, true) where bluetoothFault:
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED · RADIO FAULT",
            scanLabel: "SCANNING · WI-FI ONLY · BLE RADIO FAULT",
            detail: "The Bluetooth detection radio stopped responding; Wi-Fi scanning is still active.",
            isScanning: true,
            tone: .warning)
    case (false, true):
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED OVER BLE",
            scanLabel: "SCANNING · WI-FI",
            detail: "Wi-Fi detection is active; Bluetooth scanning is off.",
            isScanning: true,
            tone: .accent)
    case (false, false) where bluetoothFault:
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED · RADIO FAULT",
            scanLabel: "BLE RADIO FAULT · NOT SCANNING",
            detail: "The Bluetooth detection radio stopped responding and Wi-Fi scanning is off.",
            isScanning: false,
            tone: .warning)
    case (false, false):
        return BeaconRadioPresentation(
            connectionLabel: "CONNECTED OVER BLE",
            scanLabel: "RADIOS OFF · NOT SCANNING",
            detail: "Both beacon detection radios are switched off.",
            isScanning: false,
            tone: .neutral)
    }
}

/// Compact state for the promoted firmware disclosure. The expanded firmware card remains the
/// authoritative recovery/control surface; this text only prevents terminal and in-flight states
/// from masquerading as another available update.
struct BeaconFirmwareBannerPresentation: Equatable {
    let title: String
    let detail: String
    let tone: BeaconPresentationTone
}

struct BeaconFirmwareStatusPresentation: Equatable {
    let symbol: String
    let detail: String
    let tone: BeaconPresentationTone
    let offersBrowserFlasher: Bool
}

/// Healthy/idle firmware copy is deliberately catalog-relative. A cached or bundled manifest is
/// useful offline, but neither an absent status frame nor an unlisted board proves that the
/// installed firmware is globally current.
/// `revisionCompatible` is the belt-and-braces OTA revision gate reaching the copy: when the
/// listing we would flash from disagrees with the revision the board reports, this card must say
/// so and must NOT offer a flasher link, because that link goes to the disagreeing listing's own
/// page. The wording is byte-identical to android DeviceScreen.kt's `!revisionCompatible` arm -
/// one blocked state, one sentence, both phones.
func beaconFirmwareStatusPresentation(hasCurrentStatus: Bool,
                                      installedVersion: String?,
                                      catalogHasBoard: Bool,
                                      latestVersion: String,
                                      outdated: Bool,
                                      revisionCompatible: Bool = true) -> BeaconFirmwareStatusPresentation {
    guard hasCurrentStatus, let installedVersion else {
        return BeaconFirmwareStatusPresentation(
            symbol: "clock",
            detail: "Waiting for a current board firmware status.",
            tone: .neutral,
            offersBrowserFlasher: false)
    }
    guard catalogHasBoard else {
        return BeaconFirmwareStatusPresentation(
            symbol: "questionmark.circle",
            detail: "Installed v\(installedVersion). This board is not listed in the current firmware catalog.",
            tone: .neutral,
            offersBrowserFlasher: false)
    }
    // Ahead of `outdated`, and not merged into it: a blocked listing is not "up to date" either,
    // so neither the offer arm nor the healthy arm below may claim this state.
    guard revisionCompatible else {
        return BeaconFirmwareStatusPresentation(
            symbol: "exclamationmark.triangle.fill",
            detail: "Update unavailable: this firmware listing does not match the beacon's reported board revision. No update will be offered from this listing.",
            tone: .warning,
            offersBrowserFlasher: false)
    }
    if outdated {
        return BeaconFirmwareStatusPresentation(
            symbol: "exclamationmark.triangle.fill",
            detail: "Update available. Reflash your board to v\(latestVersion) in your browser.",
            tone: .warning,
            offersBrowserFlasher: true)
    }
    return BeaconFirmwareStatusPresentation(
        symbol: "checkmark.seal.fill",
        detail: "No newer board firmware is listed in this app's current catalog. Installed v\(installedVersion).",
        tone: .accent,
        offersBrowserFlasher: false)
}

/// TWIN: android DeviceScreen.kt `firmwareBannerPresentation`. EVERY arm is byte-identical to its
/// Android arm - title and detail (Android's `kicker`) - and the two test suites
/// (BeaconPresentationTests, StatusBeaconPresentationTest) pin the same literals. The shape
/// differs (Android switches on the phase and gates the banner in shouldPromoteFirmwareBanner;
/// this returns nil for a healthy idle board), the words do not. A reword is a by-hand edit on
/// both platforms; there is no deliberate platform difference in this presenter.
///
/// `notice` is the coordinator's soft DONE note (`combinedNotice` / Android `combined.notice`),
/// preferred over the generic DONE detail when it exists. The running arm shows the phase label
/// and the merged 0...1 bar as a percent, so the collapsed header still reports progress.
func beaconFirmwareBannerPresentation(combinedState: CombinedUpdatePhase,
                                      phaseLabel: String,
                                      progress: Double,
                                      notice: String? = nil,
                                      installedVersion: String?,
                                      latestVersion: String,
                                      outdated: Bool,
                                      combinedStale: Bool,
                                      s3Stale: Bool,
                                      combinedS3Updated: Bool) -> BeaconFirmwareBannerPresentation? {
    if combinedState.isRunning {
        let boundedProgress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let percent = Int((boundedProgress * 100).rounded())
        // Per-phase titles and per-phase fallback labels, Android's arm for arm.
        let title: String
        let fallback: String
        switch combinedState {
        case .checking:       title = "Checking firmware";              fallback = "finding the right update for this beacon"
        case .updatingS3:     title = "Updating board firmware";        fallback = "installing board firmware"
        case .reconnecting:   title = "Firmware update · reconnecting"; fallback = "the board is restarting"
        case .updatingCoproc: title = "Updating second radio";          fallback = "Bluetooth detection is temporarily paused"
        default:              title = "Verifying firmware update";      fallback = "confirming the installed version"
        }
        let label = phaseLabel.isEmpty ? fallback : phaseLabel
        return BeaconFirmwareBannerPresentation(
            title: title,
            detail: "\(label) · \(percent)%",
            tone: .neutral)
    }
    switch combinedState {
    case .done:
        return BeaconFirmwareBannerPresentation(
            title: "Firmware update complete",
            detail: notice ?? "this beacon is up to date",
            tone: .accent)
    case .failed(let reason):
        // A stop the USER asked for is not a failure. combinedCancel() sets phaseLabel
        // "Update cancelled" and reason "Update cancelled.", and the expanded card one tap below
        // prints that reason verbatim, so an unconditional "failed" header contradicts the
        // sentence directly under it. Same discrimination, same two inputs and the same words as
        // android DeviceScreen.kt firmwareBannerPresentation's FAILED arm; `.neutral` is the twin
        // of its CANCELLED kind's quiet tone, so a deliberate stop never draws a warning triangle.
        let cancelled = phaseLabel.range(of: "cancel", options: .caseInsensitive) != nil
            || reason.range(of: "cancel", options: .caseInsensitive) != nil
        return BeaconFirmwareBannerPresentation(
            title: cancelled ? "Firmware update cancelled" : "Firmware update failed",
            detail: cancelled ? "no further update work is running"
                              : "tap for details and recovery steps",
            tone: cancelled ? .neutral : .warning)
    case .partial:
        return BeaconFirmwareBannerPresentation(
            title: "Firmware update incomplete",
            detail: combinedS3Updated
                ? "board updated · second radio still needs attention"
                : "second radio still needs attention",
            tone: .warning)
    default:
        break
    }
    guard outdated || combinedStale else { return nil }
    // "installed version unavailable", never a made-up "v-": the one-click offer can exist on a
    // co-processor package before the board's own version has been read.
    let installed = installedVersion.map { "installed v\($0)" } ?? "installed version unavailable"
    if combinedStale, !s3Stale {
        return BeaconFirmwareBannerPresentation(
            title: "Second radio update ready",
            detail: "co-processor firmware · installs over Bluetooth",
            tone: .accent)
    }
    // The one-click path exists only while combinedStale is true. An outdated board alone
    // promotes too, and in that state the expanded card offers ONLY the browser flasher, so the
    // header may not promise Bluetooth (StatusBeaconPresentationTest pins the same split).
    return BeaconFirmwareBannerPresentation(
        title: "Firmware v\(latestVersion) ready",
        detail: combinedStale ? "\(installed) · updates over Bluetooth"
                              : "\(installed) · open for update options",
        tone: .accent)
}
