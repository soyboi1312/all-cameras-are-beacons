import SwiftUI
import CoreBluetooth
import UIKit
import Accessibility

/// Spoken word for a scan row's signal, derived from the same banding that drives the
/// visual SignalBars (Detection.signalBars) so the two can never disagree. Android's
/// BoardRow maps rssiBars the same way.
func beaconSignalDescription(rssi: Int) -> String {
    switch Detection.signalBars(rssi: rssi) {
    case ...1: return "weak"
    case 2:    return "fair"
    case 3:    return "good"
    default:   return "strong"
    }
}

/// A pre-permission action opens the system alert; only that alert can grant Bluetooth access.
/// Keep the first-use title neutral so the app never appears to make the permission decision.
func bluetoothScanButtonTitle(isScanning: Bool, bluetoothGranted: Bool) -> String {
    if isScanning { return "Stop Scanning" }
    return bluetoothGranted ? "Scan for Beacons" : "Continue"
}

/// The connect screen's per-kind copy, one TEMPLATE literal per surface (holes filled by
/// renderBoardCopy; nil kind reads as beacon, byte for byte today's beacon wording). Each is
/// shared with Android (AcabApp.kt's connect list and MainScreen.kt's reconnect banner) and
/// compared by check-signature-drift.py, so a template changes on both apps in one change.
///
/// Which kind fills them: `screenKind` (resolveScreenKind) for the copy that is not about one
/// row; the target's kind (BLEManager.targetKind) for the connecting and reconnecting copy and
/// the reconnect banner. The scan button ("Scan for Beacons"), the wordmark, the tagline, the scan
/// announcement and "Get a beacon" name the product line or the shop and never take a kind.
enum ConnectCopy {
    /// The one setup line under the wordmark. The pairing-request step is not repeated here: the
    /// connecting body, the secure pairing note over the heard boards and Setup + pairing help
    /// (q-setup) each carry it at the moment it applies. TWIN: Android CONNECT_SETUP_TEMPLATE.
    static let setupSentence = "power on your {noun} and keep it nearby."
    /// The Bluetooth rationale after its bold "Bluetooth" lead.
    static let bluetoothRationale = "connects your phone to your {noun}. the {noun} does the listening, not your phone."
    static let bluetoothOff = "turn on Bluetooth to find your {noun}."
    static let bluetoothRestricted = "Bluetooth is restricted by device policy, so the app cannot scan for {a_noun}."
    static let bluetoothDenied = "Bluetooth access is off for beacons. turn it on in Settings to scan for your {noun}."
    static let looking = "looking for your {noun}\u{2026}"
    static let noneFound = "no {plural} found. make sure your {noun} is powered on and nearby, then scan again."
    static let securePairingNote = "tap your {noun}, then accept {os_pairing_request} if it appears. pairing encrypts the detection link to this phone."
    /// The connecting panel's body under the "securing connection..." status line.
    static let connectingBody = "keep your {noun} powered on and nearby. approve {os_pairing_request} if it appears."
    static let reconnectingTitle = "reconnecting to your {noun}\u{2026}"
    static let reconnectingBody = "it reconnects on its own when the {noun} is back in range, even in the background. keep waiting, or stop to scan for a different {noun}."
    /// The reconnect banner over the tab shell (RootView's LinkRecoveryBannerView).
    static let reconnectBannerTitle = "reconnecting to your {noun}"
    static let reconnectBannerSubtitle = "your open screen and capture are preserved."
    /// The hears row's title and its two spoken actions (the row expands in place). TWIN:
    /// Android CONNECT_HEARS_TEMPLATE, CONNECT_HEARS_SHOW_TEMPLATE, CONNECT_HEARS_HIDE_TEMPLATE.
    static let hearsRow = "What your {noun} can hear"
    static let hearsShow = "show what your {noun} can hear"
    static let hearsHide = "hide what your {noun} can hear"
    static let savedLogKicker = "history on this phone \u{00B7} browse and export, no {noun} needed"
    /// Lowercase-first like every other sentence on this screen (it used to open "Passive ...
    /// The"). TWIN: Android CONNECT_SCOPE_FOOTNOTE_TEMPLATE.
    static let scopeFootnote = "passive detection only. the {noun} never jams, spoofs, or interferes."
    static let locationOff = "{noun} scanning still works. most pins showing where your phone heard a detection will be absent, while drones with Remote ID coordinates can still appear."
    static let locationRestricted = "a device policy prevents the app from recording where your phone heard detections. {noun} scanning still works, and drones with Remote ID coordinates can still appear on the map."
    /// The "Setup + pairing help" row's subtitle. It names no board, so it is one literal, not a
    /// template. TWIN: Android AcabApp.kt CONNECT_SETUP_HELP_SUBTITLE, byte-identical (settled
    /// 2026-09-25 to the clearer of the two old lines; iOS read "power, secure pairing, and
    /// recovery \u{00B7} works offline").
    static let setupHelpSubtitle = "offline help for power, permissions, pairing, and connection recovery"
}

/// A picker row's title: the remembered row names the board it remembers ("your OUI-Spy"); a
/// scanned row names the product its real advert suggests ("OUI-Spy"), and a row with no or an
/// unknown name reads "beacon". The raw advertised name is no longer shown: every board of one
/// kind advertises the same one, so it never told two boards apart.
func boardPickerRowTitle(_ entry: BoardPickerEntry) -> String {
    entry.isRemembered ? RememberedBoardCopy.label(kind: entry.kind) : (entry.kind ?? .beacon).noun
}

/// A scanned row keeps its first-pair wording. The remembered row says whether an advertisement
/// is live; with no advertisement the tap still works: the connect is the same 15 s bounded
/// attempt, and CoreBluetooth completes it for a bonded board that is on and in range whether or
/// not it is advertising the service UUID.
func boardPickerRowSubtitle(_ entry: BoardPickerEntry) -> String {
    guard entry.isRemembered else { return "tap to pair securely" }
    return RememberedBoardCopy.subtitle(hasSignal: entry.rssi != nil)
}

/// A picker row's spoken name: its title, the signal band (or no live signal), then the promise.
func boardPickerRowAccessibilityLabel(_ entry: BoardPickerEntry) -> String {
    let signal = entry.rssi.map { "\(beaconSignalDescription(rssi: $0)) signal" } ?? "no live signal"
    return "\(boardPickerRowTitle(entry)), \(signal), connects securely"
        + (entry.firmware.map { ", firmware \($0)" } ?? "")
}

/// Pre-connection / first-run screen: gets the beacon connected, explains permissions before the
/// OS asks, and offers a first-class sample path plus offline setup help.
struct ConnectView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The one sheet this screen opens: the saved log (read-only path into the persisted log, no
    /// beacon needed). The hears panel expands in place under its row instead (hearsExpanded).
    @State private var showSavedLog = false
    /// Is the hears row open? Closed at first so the screen reads as the setup line and two
    /// buttons; open, the six category tiles and the opt-in line sit inside the connect list.
    @State private var hearsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The leading glyph column of the connect list, scaled with the row text.
    @ScaledMetric(relativeTo: .body) private var rowGlyphColumn: CGFloat = 28
    /// Does this screen have to carry the desert restore offer? Decided by RootView through
    /// desertRestoreNeedsPreConnectSurface, which is the negation of the gate that draws the tab
    /// shell. It is passed in rather than read here because this view only exists when the shell
    /// is gone, so deciding it here would be deciding it against a constant.
    var showAlertRestore = false
    var onOpenSetupHelp: () -> Void = {}
    // Scan-outcome bookkeeping: BLEManager's 45s scan window closes by silently settling back
    // to .idle, which looked like a spinner that just gave up. Track when the window closed
    // with nothing found so the panel can say so and offer another go.
    @State private var scanStartedAt: Date?
    @State private var scanCameUpEmpty = false
    // A recovery hint stays published until another connect begins. Hide the handled instance
    // while its retry scan runs, then clear this guard when the user picks a board so a new failure
    // (even with identical copy) is surfaced again.
    @State private var handledConnectHint: ConnectHint?

    // The six things the beacon listens for, as shown in the hears panel. Network cameras
    // belong beside trackers: both are opt-in, and the copy below names them.
    private let hears: [(DeviceType, String)] = [
        (.flockCamera, "ALPR"), (.drone, "DRONES"), (.axonBodyCam, "BODY CAMS"),
        (.tracker, "TRACKERS"), (.recordingGlasses, "GLASSES"), (.networkCamera, "NET CAM"),
    ]
    // The grid keeps six columns up to XXX Large and only opens its row spacing from XX Large,
    // where the labels already lean on minimumScaleFactor. Accessibility sizes switch to the
    // adaptive grid in beaconHearsPanel (116pt minimum columns), which wraps on purpose.
    private var expandedHearsLayout: Bool { dynamicTypeSize >= .xxLarge }

    /// The kind for this screen's copy that is not about one row (resolveScreenKind). Computed
    /// once per body pass and handed down: a merge over two short lists.
    private var screenKind: BoardKind? {
        resolveScreenKind(targetActive: ble.connectionState == .connecting || failureHint != nil,
                          targetKind: ble.targetKind, rememberedKind: ble.rememberedKind,
                          rowKinds: ble.pickerEntries.map(\.kind))
    }

    /// The connect failure the scan panel is showing, if any: the same three conditions its
    /// `if` checks.
    private var failureHint: ConnectHint? {
        guard let hint = ble.connectHint, hint != handledConnectHint,
              ble.connectionState != .scanning else { return nil }
        return hint
    }

    var body: some View {
        let kind = screenKind
        return ScrollView {
            VStack(spacing: 16) {
                // The passive statement is said ONCE on this screen, in the footnote. The hero is
                // the wordmark and the tagline only, as the pre-redesign screen had it.
                hero
                    .padding(.top, 56)
                // A SILENCE THIS APP IMPOSED LEADS EVEN THIS SCREEN. Every other home of the
                // offer is on the Beacon screen, which RootView either has not mounted yet or
                // keeps mounted with its opacity at zero, its hit testing off and its
                // accessibility hidden while this one draws over it, so this is the only
                // reachable copy right now - and the state that arms the offer (a board reboot,
                // a factory reset) is exactly the state that lands the owner here. It goes
                // above setup because setup is about the next beacon; this is about the phone
                // in their hand still being silent.
                //
                // Nothing about taking it needs a board: the alert mode is a phone preference.
                // The board write it also makes is dropped while there is no link; the next
                // connect re-sends the wanted mode, and reconcileBuzzer re-asserts it from the
                // first status frame if the board still disagrees. That is the same path as any
                // other mode picked while offline. Same panel and same strings as the Beacon
                // screen's copy, from the one AlertRestorePanel definition.
                if showAlertRestore { AlertRestorePanel() }
                // Setup comes before the list below. A first-time owner needs the next physical
                // action before learning every category the beacon can recognize.
                setupIntro(kind)
                content(kind)
                // In the states with no scan panel (Bluetooth off, Bluetooth not allowed,
                // "Starting Bluetooth...", a connect in flight) the state's own panel leads and
                // the sample path follows it, as on Android's connect list: the thing that
                // blocks setup is the first instruction, not the secondary button.
                if !showsScanPanel { demoCard }
                connectRows(kind)
                scopeFootnote(kind)
            }
            .padding(.horizontal, ACABTheme.pad)
            .padding(.bottom, 8)
            // The restore offer above names this screen's kind, not the (absent) connected
            // board's; set here so its call site stays the bare call the drift needle pins.
            .environment(\.restoreOfferKind, .screen(kind))
        }
        // Timed-out-empty detection. Only a scan that ran (near) the full 45s window counts:
        // a user tapping Stop Scanning early chose to stop, and showing an empty result for it
        // would be wrong.
        .onChange(of: ble.connectionState) { old, new in
            if new == .scanning {
                scanStartedAt = Date()
                scanCameUpEmpty = false
                postAccessibilityAnnouncement("scanning for beacons. activate Stop Scanning to stop.",
                                              priority: .polite)
            }
            if old == .scanning, new != .scanning {
                let ranFull = scanStartedAt.map { Date().timeIntervalSince($0) >= 40 } ?? false
                // pickerEntries, not discovered: the remembered row stays on screen with no
                // advertisement (the later firmware drops the service UUID from its advert once
                // bonded and outside its pair window, so the filtered scan never sees it), so
                // "no beacons found" above "your beacon" would contradict the row the user can tap.
                scanCameUpEmpty = ranFull && ble.pickerEntries.isEmpty
                scanStartedAt = nil
                if scanCameUpEmpty {
                    postAccessibilityAnnouncement(renderBoardCopy(ConnectCopy.noneFound, screenKind),
                                                  priority: .assertive)
                }
            }
        }
        .onChange(of: ble.connectHint) { _, hint in
            guard let hint, hint != handledConnectHint else { return }
            postAccessibilityAnnouncement("connection did not finish. \(hint.text)",
                                          priority: .assertive)
        }
        .sheet(isPresented: $showSavedLog) {
            DetectionsView()
                .environmentObject(ble)
                // No MainTabView while disconnected, so a dossier's Open in Map handoff has no
                // receiver here: it would dead-end and park a stale MapFocus coordinate that
                // hijacks a later connect's first map open. The flag hides the affordance.
                .environment(\.mapHandoffAvailable, false)
                .preferredColorScheme(.dark)
        }
    }

    /// The wordmark and the tagline under it, in the kicker's type. The tagline names the product
    /// line, so it never takes a kind. Spoken as words, not letter by letter.
    private var hero: some View {
        VStack(spacing: 6) {
            ACABWordmark()
            Kicker("ALL CAMERAS ARE BEACONS")
                .multilineTextAlignment(.center)
                .accessibilityLabel("all cameras are beacons")
                // Brand ornament, not instructions, so its type stops at accessibility2, the cap
                // RootView puts on its pinned banners: at AX5 it grew to two large lines and
                // pushed the connect list below the fold. It still scales up to that cap; the
                // setup line, the buttons and the list under it keep the full Dynamic Type range.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: setup first

    /// True in the states where `content` draws `scanPanel` (its `default` arm). The scan button, the
    /// setup line and the pre-permission rationale belong to that panel, so they show exactly when
    /// it does: never over "Bluetooth is off", the permission message,
    /// "Starting Bluetooth..." or a connect in flight. Keep this switch in step with `content`.
    private var showsScanPanel: Bool {
        switch ble.connectionState {
        case .unknown, .poweredOff, .unauthorized, .connecting: return false
        case .idle, .scanning, .connected: return true
        }
    }

    /// The fork: the one setup line, the scan button, the sample-data button, then (only before the
    /// system has asked) the one-line Bluetooth rationale. Drawn only while
    /// `showsScanPanel` is true (nothing at all otherwise, so the stack adds no gap for it); in
    /// every other state body draws the sample-data button on its own right after `content`,
    /// below that state's panel, in the same place as Android's connect list.
    ///
    /// PLATFORM DIFFERENCE while a connect is in flight (`.connecting`, a fresh connect or an
    /// auto-reconnect): iOS keeps "See How It Works" (below the connecting panel) and "View saved
    /// log (N)" and "Get a beacon" (in connectRows). Android AcabApp's connect list hides all
    /// three while CONNECTING or BONDING (its `linking` gate). iOS keeps them because an auto-reconnect can run
    /// indefinitely, and the saved log is the evidence path this screen exists to keep reachable
    /// with no board. Every other state draws the same sections on both phones (see the order
    /// comment above AcabApp's connect LazyColumn).
    @ViewBuilder private func setupIntro(_ kind: BoardKind?) -> some View {
        if showsScanPanel {
            VStack(spacing: 12) {
                Text(renderBoardCopy(ConnectCopy.setupSentence, kind))
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                scanCTA
                // The sample path is the secondary button of the fork: it is the best answer to
                // 'what does this thing do', so it sits beside the scan action instead of below
                // the scan panel.
                demoCard
                // Before the system has asked, one line says what the alert that "Continue"
                // opens is for. Once Bluetooth is allowed it has nothing left to explain. The
                // "already paired to another phone?" line no longer rests here: it is in Setup +
                // pairing help (q-setup, q-pair-window) and under a failed connect
                // (connectionFailurePanel), where it applies.
                if !btGranted {
                    rationaleRow("antenna.radiowaves.left.and.right", "Bluetooth",
                                 renderBoardCopy(ConnectCopy.bluetoothRationale, kind))
                }
            }
        }
    }

    // MARK: what it hears

    /// The six tiles and the opt-in line, drawn inside the connect list under the open hears row.
    /// The row above is the panel's title, so the panel draws no header of its own. TWIN: Android
    /// AcabApp.kt BeaconHearsPanel (three tiles a row there; six here, as the pre-redesign card).
    private var beaconHearsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            // One row for all six tiles at normal + large type: equal flexible columns divide the
            // width so they never wrap to a second row (labels wrap to two lines instead). Only at
            // true accessibility sizes does it fall back to an adaptive grid that wraps on purpose.
            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.adaptive(minimum: 116), spacing: 8, alignment: .top)]
                    : Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top),
                            count: hears.count),
                spacing: expandedHearsLayout ? 14 : 8
            ) {
                ForEach(hears, id: \.1) { type, label in
                    let spoken = detectionCategories.first { $0.type == type }?.spoken ?? label.lowercased()
                    VStack(spacing: 7) {
                        CatGlyph(type: type, size: 30)
                        // Tiles align on their top edge so the six glyphs share one line. A
                        // one-word label keeps one line and shrinks to fit ("TRACK-ERS" broke
                        // inside the word in the list's narrower column); a two-word label
                        // wraps at its space.
                        Text(label)
                            .font(ACABTheme.font(.caption2, weight: .medium))
                            .foregroundStyle(ACABTheme.dim)
                            .lineLimit(label.contains(" ") ? 2 : 1)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken)
                }
            }
            Text("trackers and network cameras are opt-in, switch them on in Beacon settings.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    // MARK: state-driven scan / message UI

    /// `kind` is the screen kind; the connecting and reconnecting arms name the target, which
    /// resolveScreenKind already returns while a connect runs.
    @ViewBuilder private func content(_ kind: BoardKind?) -> some View {
        switch ble.connectionState {
        case .poweredOff:
            message("Bluetooth is off", renderBoardCopy(ConnectCopy.bluetoothOff, kind), "bolt.slash.fill")
        case .unauthorized:
            permissionMessage("Bluetooth not allowed",
                              renderBoardCopy(ble.bluetoothRestricted
                                                ? ConnectCopy.bluetoothRestricted
                                                : ConnectCopy.bluetoothDenied, kind),
                              "lock.fill")
        case .unknown:
            message("Starting Bluetooth\u{2026}", "", "antenna.radiowaves.left.and.right")
        case .connecting:
            // An unexpected-drop auto-reconnect is armed indefinitely (good: it resyncs the moment
            // the board is back, even backgrounded). But RootView only shows the tabs when
            // .connected, so without an escape here a board that never returns would trap the user
            // on this screen forever with no way to scan for a different one. The fresh scan-connect
            // path needs the same way out: central.connect never times out on its own, so a stale
            // row (board powered off since discovery, or claimed by another phone) would park the
            // spinner forever. BLEManager arms a 15 s watchdog for that; the button here is the
            // manual escape, and both call disconnect(), which settles the state back to the scan
            // panel.
            if ble.isReconnecting {
                reconnectingPanel(kind)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(ACABTheme.tint)
                    Text("securing connection\u{2026}")
                        .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    Text(renderBoardCopy(ConnectCopy.connectingBody, kind))
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { ble.disconnect() } label: {
                        Text("Cancel")
                            .font(ACABTheme.font(.subheadline, weight: .semibold))
                            .foregroundStyle(ACABTheme.tint)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(ACABTheme.bg2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        default:
            scanPanel(kind)
        }
    }

    /// Shown while a pending auto-reconnect is armed (beacon unplugged / power-cycled). Says the
    /// reconnect is automatic AND gives a way out: "Stop Reconnecting" calls disconnect(), which cancels
    /// the pending connect and settles the state to .idle so the scan panel returns. Without this the
    /// user is stuck on the connect screen until the board comes back, which it may never do.
    private func reconnectingPanel(_ kind: BoardKind?) -> some View {
        VStack(spacing: 14) {
            ProgressView().tint(ACABTheme.tint)
            Text(renderBoardCopy(ConnectCopy.reconnectingTitle, kind))
                .font(ACABTheme.font(.headline)).foregroundStyle(ACABTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(renderBoardCopy(ConnectCopy.reconnectingBody, kind))
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.disconnect() } label: {
                primaryLabel("Stop Reconnecting")
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .groupedCell()
    }

    /// True once Bluetooth is granted. Reads the static authorization through BLEManager (no
    /// prompt, no "access"), so the pre-permission rationale retires once the system has already
    /// asked, and the DEBUG `-bluetoothIdle` hook can present the allowed state.
    private var btGranted: Bool { ble.bluetoothGranted }

    /// The scan outcome and the discovered boards. The setup line, the scan button and the
    /// rationale are in setupIntro, which shows them in the same states (showsScanPanel).
    private func scanPanel(_ kind: BoardKind?) -> some View {
        // Computed once per render: a pure merge of two cached BLEManager properties.
        let entries = ble.pickerEntries
        return VStack(spacing: 14) {
            if let hint = failureHint {
                connectionFailurePanel(hint, kind)
            }
            // The 45s scan window closed with nothing found: name the outcome and the fix.
            // First scan outcome under the setup buttons (after a failure hint, if one is
            // showing), so it is read before the board list.
            if scanCameUpEmpty, entries.isEmpty { noBoardsPanel(kind) }

            if ble.locationDenied { locationPermissionPanel(kind) }

            if ble.discovered.isEmpty, ble.connectionState == .scanning {
                Text(renderBoardCopy(ConnectCopy.looking, kind))
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .padding(.top, 2)
                    .accessibilityLabel("scanning for beacons")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if !ble.discovered.isEmpty {
                securePairingNote(kind)
            }

            // One tappable row per board: the remembered board first (even with no advertisement),
            // then every scanned board. The merge folds a scanned sighting of the remembered board
            // into its row, so one board is never two rows.
            if !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        if entry.id != entries.first?.id {
                            Divider().overlay(ACABTheme.line).padding(.leading, 16)
                        }
                        Button {
                            handledConnectHint = nil
                            ble.connect(pickerEntryID: entry.id)
                        } label: { boardRow(entry) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(boardPickerRowAccessibilityLabel(entry))
                            .accessibilityHint("activate to connect. iOS may show a pairing request")
                    }
                }
                .groupedCell(padding: 0)
            }
        }
    }

    /// BLEManager already distinguishes an ordinary empty scan from a failed/incomplete board
    /// link. Render that diagnosis instead of silently falling back to an undifferentiated picker.
    /// `kind` is the screen kind, which names the failed target while this panel shows
    /// (resolveScreenKind counts a showing failure as an active target).
    private func connectionFailurePanel(_ hint: ConnectHint, _ kind: BoardKind?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(ACABTheme.font(.subheadline))
                    .foregroundStyle(ACABTheme.warn).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("connection did not finish")
                        .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hint.text)
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    // The second-phone rule is never guessed into the hint's sentence
                    // (BLEManager.connectHint). It left the idle screen; this is where a user who
                    // missed the window lands, so it shows under every hint whose stage a second
                    // phone can explain (showsPairWindowNote: a link or pairing failure), and not
                    // under a profile or post-encryption setup failure, where power-cycling
                    // for a second phone would be a made-up fix. It is not in the failure
                    // announcement (onChange of ble.connectHint), which reads the hint only.
                    // TWIN: Android ConnectionHintPanel draws PairWindowNote under the same test.
                    if showsPairWindowNote(for: hint.stage) {
                        pairWindowNote(kind)
                    }
                }
            }
            Divider().overlay(ACABTheme.line)
            cellAction("Scan Again") {
                handledConnectHint = hint
                ble.startScanFromUser()
            }
        }
        .groupedCell()
    }

    /// Shown after a full scan window found nothing: an actionable outcome instead of the
    /// silent settle back to the idle CTA (which read as an indefinite spinner giving up).
    private func noBoardsPanel(_ kind: BoardKind?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(ACABTheme.font(.title2)).foregroundStyle(ACABTheme.dim)
            Text(renderBoardCopy(ConnectCopy.noneFound, kind))
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            cellAction("Scan Again") { ble.startScanFromUser() }
        }
        .frame(maxWidth: .infinity)
        .groupedCell()
    }

    /// The pre-permission rationale: one footnote line under the two buttons, a tinted glyph then
    /// the bold lead and its rest, in the helper-line size of the secure pairing note.
    private func rationaleRow(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.tint)
                .accessibilityHidden(true)
            Text("\(Text(lead).font(ACABTheme.font(.footnote, weight: .semibold)).foregroundStyle(ACABTheme.text))\(Text(" \(rest)").font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim))")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// The filled primary button face: onAccent on tint, radius 12, grows with a wrapped title.
    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .font(ACABTheme.font(.body, weight: .semibold))
            .foregroundStyle(ACABTheme.onAccent)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(ACABTheme.tint,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
    }

    private var scanCTA: some View {
        Button {
            ble.connectionState == .scanning ? ble.stopScan() : ble.startScanFromUser()
        } label: {
            primaryLabel(bluetoothScanButtonTitle(
                isScanning: ble.connectionState == .scanning,
                bluetoothGranted: btGranted))
        }
        .buttonStyle(.plain)
    }

    /// One tinted action row inside a cell, in the iOS list-button form (no hairline).
    private func cellAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ACABTheme.font(.body))
                .foregroundStyle(ACABTheme.tint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Location is optional: the board scan and Remote ID coordinates still work without it.
    /// This recovery card avoids both bad extremes, a dead-looking map and a false claim that no
    /// detections can ever be mapped, while offering the system route to change the decision.
    private func locationPermissionPanel(_ kind: BoardKind?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .font(ACABTheme.font(.subheadline))
                    .foregroundStyle(ACABTheme.warn).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.locationRestricted ? "Location is restricted" : "Location is off")
                        .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(renderBoardCopy(ble.locationRestricted
                                         ? ConnectCopy.locationRestricted : ConnectCopy.locationOff, kind))
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(ACABTheme.line)
            cellAction("Open Settings", action: openAppSettings)
        }
        .groupedCell()
    }

    private func permissionMessage(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            message(title, body, symbol)
            cellAction("Open Settings", action: openAppSettings)
        }
    }

    private func securePairingNote(_ kind: BoardKind?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(ACABTheme.font(.footnote))
                .foregroundStyle(ACABTheme.tint)
            Text(renderBoardCopy(ConnectCopy.securePairingNote, kind))
                .font(ACABTheme.font(.footnote))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// The second-phone pairing note, under the hint in the connection-failure panel when
    /// showsPairWindowNote accepts the hint's stage.
    ///
    /// A board that already belongs to a phone only accepts a NEW phone in the two minutes after it
    /// powers on. That rule is invisible from the phone's side: the board hangs up before any
    /// characteristic exists to explain itself, so a user who misses the window just sees a connect
    /// that will not take. It used to rest under the two setup buttons; the owner asked for a
    /// shorter idle screen (2026-09-25), so before a failure it lives in Setup + pairing help
    /// (q-setup and q-pair-window), and after one it is here.
    ///
    /// Deliberately says "already paired to another phone", not "your beacon": on a brand new board
    /// with no bonds the rule does not apply at all (the firmware admits any phone until the board
    /// has an owner), and telling a first-time customer to power-cycle would be a made-up ritual.
    private func pairWindowNote(_ kind: BoardKind?) -> some View {
        Text("already paired to another phone? "
             + renderBoardCopy(BLEManager.pairWindowHint, kind))
            .font(ACABTheme.font(.footnote))
            .foregroundStyle(ACABTheme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One board in the picker cell. At accessibility text sizes the signal block goes under the
    /// title block instead of trailing it, so neither is squeezed.
    private func boardRow(_ entry: BoardPickerEntry) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        return HStack(alignment: stacked ? .top : .center, spacing: 12) {
            Image(systemName: "cpu")
                .font(ACABTheme.font(.body))
                .foregroundStyle(ACABTheme.tint)
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    boardTitleBlock(entry)
                    boardSignal(entry)
                }
                Spacer(minLength: 0)
            } else {
                boardTitleBlock(entry)
                Spacer(minLength: 8)
                boardSignal(entry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func boardTitleBlock(_ entry: BoardPickerEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(boardPickerRowTitle(entry))
                    .font(ACABTheme.font(.body))
                    .foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let fw = entry.firmware {
                    Text("v\(fw)")
                        .font(ACABTheme.font(.caption2, weight: .semibold))
                        .foregroundStyle(ACABTheme.tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
                }
            }
            Text(boardPickerRowSubtitle(entry))
                .font(ACABTheme.font(.subheadline))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func boardSignal(_ entry: BoardPickerEntry) -> some View {
        if let rssi = entry.rssi {
            HStack(spacing: 6) {
                SignalBars(bars: Detection.signalBars(rssi: rssi))
                Text(beaconSignalDescription(rssi: rssi))
                    .font(ACABTheme.font(.subheadline))
                    .foregroundStyle(ACABTheme.dim)
            }
        }
    }

    private func message(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(ACABTheme.font(.largeTitle)).foregroundStyle(ACABTheme.dim)
            Text(title)
                .font(ACABTheme.font(.headline)).foregroundStyle(ACABTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !body.isEmpty {
                Text(body).font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: the connect list (no board required)

    private enum RowTrailing: Equatable { case chevron, external, disclosure(expanded: Bool) }

    /// One row of the connect list: a tinted glyph in a scaled column, then GroupedRow, then an
    /// arrow.up.right for the row that leaves the app, or a chevron that turns down for the row
    /// that opens in place (the hears row; the List disclosure form). The GroupedRow fills the width, leading
    /// aligned, so a row with no chevron (the external one) is not centred in the button or
    /// Link: its glyph and text keep the column of their neighbours and the arrow sits at the
    /// trailing edge, the same edge the chevrons use.
    private func connectRow(_ symbol: String, _ title: String, _ subtitle: String?,
                            trailing: RowTrailing) -> some View {
        HStack(spacing: 8) {
            GroupedRow(title: title, subtitle: subtitle, chevron: trailing == .chevron) {
                Image(systemName: symbol)
                    .font(ACABTheme.font(.body))
                    .foregroundStyle(ACABTheme.tint)
                    // At accessibility sizes GroupedRow stacks the glyph ABOVE the text, so the
                    // glyph starts at the text's leading edge instead of centring in its column.
                    .frame(width: rowGlyphColumn,
                           alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if trailing == .external {
                Image(systemName: "arrow.up.right")
                    .font(ACABTheme.font(.footnote, weight: .semibold))
                    .foregroundStyle(ACABTheme.faint)
                    .accessibilityHidden(true)
            }
            if case .disclosure(let expanded) = trailing {
                // GroupedRow's own chevron glyph, turned a quarter down while the row is open.
                Image(systemName: "chevron.right")
                    .font(ACABTheme.font(.footnote, weight: .semibold))
                    .foregroundStyle(ACABTheme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Inset to the text column: beside the glyph at default sizes, at the row's own 16pt edge at
    /// accessibility sizes, where GroupedRow stacks the glyph above the text.
    private var rowDivider: some View {
        Divider().overlay(ACABTheme.line)
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 16 + rowGlyphColumn + 12)
    }

    /// The hears row and, while it is open, its panel: one member of the connect list, so the
    /// dividers either side stay put.
    private func hearsGroup(_ kind: BoardKind?) -> some View {
        VStack(spacing: 0) {
            hearsRow(kind)
            if hearsExpanded {
                beaconHearsPanel
                    .transition(.opacity)
            }
        }
    }

    /// Everything that is not the fork, as one grouped cell: saved log, what the beacon can hear,
    /// setup help, and the shop. Drawn in every state, a connect in flight included (see the
    /// platform difference on setupIntro).
    private func connectRows(_ kind: BoardKind?) -> some View {
        VStack(spacing: 0) {
            if !ble.demoMode && !ble.logDetections.isEmpty {
                savedLogCard(kind)
                rowDivider
            }
            hearsGroup(kind)
            rowDivider
            setupHelpCard
            rowDivider
            getBeaconCard
        }
        .groupedCell(padding: 0)
    }

    /// The history on this phone stays reachable with no board and no Bluetooth. The Log tab
    /// is normally gated behind .connected, but a log that may be evidence must never be
    /// locked behind hardware that died or a permission that was denied. Everything inside is
    /// phone-local (view, mark seen, export CSV, clear); board-config writes no-op while
    /// disconnected. Hidden in sample data so the sample store can never be exported here.
    private func savedLogCard(_ kind: BoardKind?) -> some View {
        Button { showSavedLog = true } label: {
            connectRow("list.bullet.rectangle", "View saved log (\(ble.logDetections.count))",
                       renderBoardCopy(ConnectCopy.savedLogKicker, kind),
                       trailing: .chevron)
        }
        .buttonStyle(.plain)
    }

    /// Opens and closes the hears panel in place. No sub line exists for this row, so it passes
    /// nil. Spoken as the row title with its state and the action it takes, as Android's row is
    /// (stateDescription and onClickLabel).
    private func hearsRow(_ kind: BoardKind?) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { hearsExpanded.toggle() }
        } label: {
            connectRow("ear", renderBoardCopy(ConnectCopy.hearsRow, kind), nil,
                       trailing: .disclosure(expanded: hearsExpanded))
        }
        .buttonStyle(.plain)
        .accessibilityValue(hearsExpanded ? "expanded" : "collapsed")
        .accessibilityHint(renderBoardCopy(hearsExpanded ? ConnectCopy.hearsHide : ConnectCopy.hearsShow,
                                           kind))
    }

    private var setupHelpCard: some View {
        Button(action: onOpenSetupHelp) {
            connectRow("questionmark.circle", "Setup + pairing help", ConnectCopy.setupHelpSubtitle,
                       trailing: .chevron)
        }
        .buttonStyle(.plain)
        .accessibilityHint("opens setup help included with the app")
    }

    // MARK: demo (first-class)

    /// Explore the full app with sample data, no beacon needed (also handy for App Review). The
    /// secondary button of the fork: tint words on a bg2 fill, the primary button's geometry.
    private var demoCard: some View {
        Button { ble.seedDemoData() } label: {
            Text("See How It Works")
                .font(ACABTheme.font(.body, weight: .semibold))
                .foregroundStyle(ACABTheme.tint)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(ACABTheme.bg2,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: get a beacon

    /// No hardware yet? Point straight at the shop. A row like its neighbours in the connect list,
    /// but a Link with an arrow.up.right glyph, since it leaves the app.
    private var getBeaconCard: some View {
        Link(destination: URL(string: "https://soyboi.tech")!) {
            connectRow("cart", "Get a beacon", "the beacon that does the listening \u{00B7} soyboi.tech",
                       trailing: .external)
        }
        .buttonStyle(.plain)
    }

    private func scopeFootnote(_ kind: BoardKind?) -> some View {
        Text(renderBoardCopy(ConnectCopy.scopeFootnote, kind))
            .font(ACABTheme.font(.footnote))
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }

    private enum AnnouncementPriority {
        case polite
        case assertive
    }

    private func postAccessibilityAnnouncement(_ message: String,
                                               priority: AnnouncementPriority) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let spokenPriority: UIAccessibilityPriority
        switch priority {
        case .polite: spokenPriority = .low
        case .assertive: spokenPriority = .high
        }
        let spoken = NSAttributedString(
            string: message,
            attributes: [
                .accessibilitySpeechAnnouncementPriority: spokenPriority,
            ])
        AccessibilityNotification.Announcement(spoken).post()
    }
}
