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
/// to the Android twin (DESERT_RESTORE_OFFER_TEMPLATE in DeviceScreen.kt). Named so a test can pin the bytes.
///
/// It says "your alert mode is still silent", not "the board is quiet", on purpose. The mode is a
/// fact this app owns and can always assert truthfully. Whether the BOARD is actually quiet is a
/// different question, and reconcileBuzzer has a terminal state where the answer is no: the board
/// refuses the mute and keeps beeping while the mode reads Silent. A sentence about the mode stays
/// true there; a sentence about sound would not.
///
/// A TEMPLATE naming the board's kind: AlertRestoreOffer renders it with renderBoardCopy and the
/// kind its surface names (RestoreOfferKind).
let desertRestoreOffer =
    "desert mode ended on the {noun}, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode."

/// Which board the restore offer names. The Beacon screen's surfaces name the connected board
/// (BLEManager.connectedKind, the default); the connect screen sets `.screen` with its own screen
/// kind (resolveScreenKind) through the environment, so every AlertRestoreOffer / AlertRestorePanel
/// call site stays the bare call check-signature-drift.py's placement needles pin.
enum RestoreOfferKind: Equatable {
    case connectedBoard
    case screen(BoardKind?)
}

private struct RestoreOfferKindKey: EnvironmentKey {
    static let defaultValue = RestoreOfferKind.connectedBoard
}

extension EnvironmentValues {
    var restoreOfferKind: RestoreOfferKind {
        get { self[RestoreOfferKindKey.self] }
        set { self[RestoreOfferKindKey.self] = newValue }
    }
}

/// The page title a pushed Beacon sub-screen (`subScreen`, `aboutScreen`) hands the card it holds,
/// so `CardKicker` can drop a kicker that only repeats it. Empty everywhere else, so a card drawn
/// away from its page (the firmware card under the update banner) keeps its kicker.
private struct SubScreenTitleKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var subScreenTitle: String {
        get { self[SubScreenTitleKey.self] }
        set { self[SubScreenTitleKey.self] = newValue }
    }
}

/// Does a card's kicker only repeat the page title above it (P3-7 of the 2026-09-26 UI review)?
/// Case-insensitive, so "SCAN RADIOS" under "Scan radios" is a repeat and "DESERT MODE" under
/// "Desert mode + buffer" or "PHONE NOTIFICATIONS" under "Notifications" is not. No page title
/// (a card drawn outside a sub-screen) is never a repeat. Pure so a test can pin it. TWIN:
/// android DeviceScreen.kt `kickerRepeatsPageTitle`, the same case-insensitive comparison.
func cardKickerRepeatsPageTitle(_ kicker: String, pageTitle: String) -> Bool {
    !pageTitle.isEmpty && kicker.caseInsensitiveCompare(pageTitle) == .orderedSame
}

/// A sub-screen card's header kicker: the Kicker, unless it only repeats the page's navigation
/// title (`cardKickerRepeatsPageTitle`, the title from `subScreenTitle`). Single-card pages
/// ("Scan radios", "Alerts", "Board LED", "Firmware", "Display", "About", ...) said their name
/// twice; the kicker stays where it carries a word the title does not (DESERT MODE and OFFLINE
/// BUFFER on the two-card page, PHONE NOTIFICATIONS) and inside a card (INSTALLED, WI-FI ECO stay
/// plain Kickers). Nothing in the VStack spacing changes: an absent kicker adds no gap. TWIN:
/// android DeviceScreen.kt CardKicker, which reads LocalBeaconPageTitle the same way.
private struct CardKicker: View {
    let text: String
    @Environment(\.subScreenTitle) private var pageTitle

    init(_ text: String) { self.text = text }

    var body: some View {
        if !cardKickerRepeatsPageTitle(text, pageTitle: pageTitle) { Kicker(text) }
    }
}

/// The label on the control that sentence names, in the same Title Case the sentence quotes. A
/// tint pill, same anatomy as Erase. TWIN: Android DESERT_RESTORE_OFFER_ACTION in DeviceScreen.kt.
let desertRestoreOfferAction = "Restore Alerts"

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
/// mesh-detect board (beaconRows drops the Alerts row on a mesh board, and reconcileBuzzer bails on
/// that board type because it has no buzzer hardware), so "turn sound back on in alerts" would name
/// a control its owner cannot reach. The case is reachable rather than dead: mesh-detect runs the shared BLE
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
/// That decline is still ONE tap on Silent while Silent is already selected: the Alerts mode
/// picker is built by hand so a tap on the selected segment still runs setAlertMode with origin
/// .user (owner decision D2, see alertModePicker), which is what clears the offer.
func desertSilenceSlot(restoreOffered: Bool, noticeApplies: Bool) -> DesertSilenceSlot {
    if restoreOffered { return .offer }
    return noticeApplies ? .notice : .none
}

/// Does the offer need a home OUTSIDE the board-gated Desert and Alerts sub-screens right now?
///
/// Both of its usual homes (the Desert card's silence slot and the Alerts card) live on the Desert
/// and Alerts sub-screens, whose rows and content DeviceView disables as one set while the board is
/// away (boardLink and subScreen), and a SwiftUI disable propagates down with no way for a child to
/// opt out, while Android withholds those pages outright, so the offer is not merely untappable
/// there, it stops drawing. A board reboot or a
/// factory reset is exactly what arms the offer, so that is the wrong moment to take the way back
/// away, and nothing about taking it needs the board: the alert mode is a phone preference, and the
/// board write it also does is the same one any offline mode pick makes.
///
/// The result is the NEGATION of that board-control gate (hardwareControlsEnabled), so the detached
/// copy and a usable in-card copy can never draw at the same time. So the detached copy draws at
/// the top of the Beacon root page (compact and regular width) and, because a pushed board
/// sub-screen covers that page, under the read-only note of a locked board sub-screen (subScreen).
/// Android twin: desertRestoreNeedsDetachedSurface in DeviceScreen.kt.
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
/// that draws the tab shell, exactly as the detached gate is the negation of the board controls'.
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
/// (the Desert card's silence slot, the Alerts card, the panel that leads the Beacon screen, or
/// heads a locked board sub-screen, while the board is away, and the panel that leads the
/// pre-connect screen when there is no Beacon screen at all) from this single definition, so no surface can word or wire the offer
/// differently. All four reach takePendingAlertModeRestore() through the one call below, which is
/// the only thing that takes it.
///
/// FOUR HERE, FIVE ON ANDROID, and the extra one is not drift: this shell stays mounted and visible
/// through an OTA reboot (RootView's mainIsUsable takes isRebootingForUpdate), so the third surface
/// covers that window here, while AcabApp hands the reboot a locked screen of its own and has to
/// carry the offer onto it.
///
/// dim footnote text, like the notice it replaces: this is a state report with a control attached,
/// not an alarm. The control is a tint pill (tint words on an 18 % tint capsule), the same anatomy
/// as Erase.
///
/// It reads the manager from the environment rather than taking a closure so that the take stays a
/// single call site no matter how many surfaces draw it. Android passes the action in instead,
/// because its two screens live in different files.
/// Android twin: AlertRestoreOffer in DeviceScreen.kt.
struct AlertRestoreOffer: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.restoreOfferKind) private var kindSource

    private var kind: BoardKind? {
        switch kindSource {
        case .connectedBoard: return ble.connectedKind
        case .screen(let kind): return kind
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(renderBoardCopy(desertRestoreOffer, kind))
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.takePendingAlertModeRestore() } label: {
                Text(desertRestoreOfferAction)
                    .font(ACABTheme.font(.footnote, weight: .bold))
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
                    .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Puts back the alert mode you had before desert mode")
        }
    }
}

/// The offer as a card of its own, for the two surfaces that are not inside another card: the
/// panel that LEADS the Beacon screen (and heads a locked board sub-screen) while the board is
/// away, and the panel that LEADS the pre-connect screen when there is no Beacon screen. Same
/// panel + ALERTS kicker on both, so the owner meets the same card wherever the app has to hand
/// it to them.
///
/// It leads both pages on purpose. A silence this app imposed is the one thing on either screen
/// that the app owes the user, so it outranks every other card on either page; and the offer
/// arms in states where the rest of the page is mostly greyed out or still searching.
/// Android twin: AlertRestorePanel in DeviceScreen.kt, which has THREE callers: its tab shell is
/// parked behind a locked wait screen during an OTA reboot, so AcabApp draws the panel there too.
struct AlertRestorePanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("ALERTS")
            AlertRestoreOffer()
        }
        .groupedCell()
    }
}

/// The Beacon tab's two segments: the board's own settings and this phone's. Session state with
/// `.board` as the default; it is never written to defaults, so a relaunch starts on `.board`.
/// TWIN: Android BeaconSegment in DeviceScreen.kt (BOARD, PHONE).
enum BeaconSegment {
    case board, phone
}

/// One-shot handoff from the setup checklist to a This-phone row on the Beacon tab. Same
/// static-slot + notification pattern as LogFocus: the sender sets `pending` and posts
/// `notification`; the receiver consumes `pending` exactly once. Session-only by design, like
/// LogFocus, so a stale request can never hijack a later launch.
/// No Android twin type: Android hands the same request over as plain counter tokens.
enum BeaconFocus {
    case notifications, liveMode
    static var pending: BeaconFocus?
    static let notification = Notification.Name("acabFocusBeaconRow")
}

/// Every row the Beacon tab draws, in both segments. TWIN: android DeviceScreen.kt BeaconRowId
/// (without disconnect / powerOff, which are Android overflow items).
enum BeaconRowID: Hashable {
    case hero, uptime, detections, detectionHeader, scanRadios, detectors, desert, onBoardHeader,
         alerts, boardLED, firmware, managedDevices, disconnect, powerOff
    case preferencesHeader, notifications, liveMode, display,
         supportHeader, systemReadiness, improveDetection, helpSupport, about, savedLog
}

/// The Beacon partition, both segments, with every render gate the rows have (mesh board,
/// promoted firmware, demo, improve gate, saved log, rev-B power off), so no renderer needs its
/// own `if`. TWIN: android DeviceScreen.kt beaconRows, same order; iOS alone carries disconnect
/// and powerOff (Android draws them in the overflow menu).
func beaconRows(segment: BeaconSegment, meshBoard: Bool, firmwareVisible: Bool, demo: Bool,
                improveAvailable: Bool, hasSavedLog: Bool, showPowerOff: Bool) -> [BeaconRowID] {
    switch segment {
    case .board:
        var rows: [BeaconRowID] = [.hero, .uptime, .detections, .detectionHeader, .scanRadios,
                                   .detectors, .desert, .onBoardHeader]
        if !meshBoard { rows.append(.alerts) }
        rows.append(.boardLED)
        if firmwareVisible { rows.append(.firmware) }
        rows += [.managedDevices, .disconnect]
        if showPowerOff { rows.append(.powerOff) }
        return rows
    case .phone:
        // PREFERENCES and SUPPORT head this device's two groups the way DETECTION and ON THE
        // BOARD head the board's, at both widths.
        var rows: [BeaconRowID] = [.preferencesHeader, .notifications, .liveMode, .display,
                                   .supportHeader]
        if !demo { rows.append(.systemReadiness) }
        if improveAvailable { rows.append(.improveDetection) }
        rows += [.helpSupport, .about]
        if !demo && hasSavedLog { rows.append(.savedLog) }
        return rows
    }
}

extension BeaconRowID {
    /// The grouped section a row sits in. Consecutive rows with one key share a cell group.
    /// iOS only: Android draws its groups from the same flat list its own way.
    var sectionKey: Int {
        switch self {
        case .hero:                                                          return 0
        case .uptime, .detections:                                           return 1
        case .detectionHeader, .scanRadios, .detectors, .desert:             return 2
        case .onBoardHeader, .alerts, .boardLED, .firmware, .managedDevices: return 3
        case .disconnect, .powerOff:                                         return 4
        case .preferencesHeader, .notifications, .liveMode, .display:        return 5
        case .supportHeader, .systemReadiness, .improveDetection, .helpSupport, .about:
            return 6
        case .savedLog:                                                      return 7
        }
    }
    /// A row that is a C2 section header, drawn in its group's header slot and never as a row.
    var isSectionHeader: Bool {
        switch self {
        case .detectionHeader, .onBoardHeader, .preferencesHeader, .supportHeader: return true
        default: return false
        }
    }
}

extension BeaconRowGroup {
    /// The hero and the Uptime / Detections tiles are cards that draw their own surface
    /// (DeviceView.beaconCard), not rows in a system cell.
    var isCardGroup: Bool {
        id == BeaconRowID.hero.sectionKey || id == BeaconRowID.uptime.sectionKey
    }
}

/// One grouped section of the Beacon list: its optional header row and the rows under it.
struct BeaconRowGroup: Equatable, Identifiable {
    let id: Int
    var header: BeaconRowID?
    var rows: [BeaconRowID]
}

/// The flat partition cut into grouped sections by `sectionKey`, header rows lifted into the
/// header slot. Pure and O(n); a body pass calls it once per `rows(for:)` result.
func beaconRowGroups(_ rows: [BeaconRowID]) -> [BeaconRowGroup] {
    var groups: [BeaconRowGroup] = []
    for row in rows {
        if groups.last?.id != row.sectionKey {
            groups.append(BeaconRowGroup(id: row.sectionKey, header: nil, rows: []))
        }
        if row.isSectionHeader { groups[groups.count - 1].header = row }
        else { groups[groups.count - 1].rows.append(row) }
    }
    return groups
}

/// DEBUG `-beacon-segment phone` for the store-screenshot pipeline (C16). Anything else, or no
/// argument, is BOARD. TWIN: android MainActivity.kt beaconSegmentExtra.
func beaconLaunchSegment(_ args: [String]) -> BeaconSegment {
    guard let i = args.firstIndex(of: "-beacon-segment"), i + 1 < args.count,
          args[i + 1] == "phone" else { return .board }
    return .phone
}

/// DEBUG `-beacon-push about` for the screenshot pipeline: the Beacon tab opens on THIS <device>
/// with About already pushed, so a headless run (with `-tab 3`) can shoot the About page where
/// simulator taps are not delivered (F2). Anything else, or no argument, pushes nothing. iOS only:
/// the Android pipeline reaches About with uiautomator taps.
func beaconLaunchPush(_ args: [String]) -> BeaconRowID? {
    guard let i = args.firstIndex(of: "-beacon-push"), i + 1 < args.count,
          args[i + 1] == "about" else { return nil }
    return .about
}

/// A middle-dot list as drawn: a no-break space BEFORE each dot, so a wrap always leaves the dot
/// at the end of a line and never starts the next one with an orphan "· ". The same separator the
/// Map's projectionSummary (MapTabView.swift) joins its parts with. Applied where a Beacon row
/// draws its text rather than in the literals, so the strings the drift rows pin stay as written;
/// the spoken text is unchanged.
func keepingMiddleDotsAttached(_ text: String) -> String {
    text.replacingOccurrences(of: " \u{00B7} ", with: "\u{00A0}\u{00B7} ")
}

/// The Beacon tab's CARD surface, for the hero and the Uptime / Detections tiles: the cell
/// padding, bg2, and the corner radius of the cell groups around it, so a card and a cell group
/// read as one family. `edge` adds the hero's crimson 1pt edge, 2.0.8's "strong" panel border,
/// which the owner preferred to the plain cell (2026-09-25); it is the one border on the page.
/// iOS only: Android draws its cards with the M3 card shape.
private struct BeaconCard: ViewModifier {
    var edge: Bool
    @Environment(\.horizontalSizeClass) private var hSize

    /// Regular width draws its groups by hand with `.groupedCell`, so a card there takes the same
    /// ACABTheme.radius. Compact width is a system inset-grouped List, whose cell radius SwiftUI
    /// does not expose (the List draws its own cell shape and publishes no container shape a
    /// card beside it can read), so `listCellRadius` restates it.
    private var radius: CGFloat { hSize == .regular ? ACABTheme.radius : Self.listCellRadius }

    /// The system inset-grouped cell radius, restated because it cannot be read: 26pt on iOS 26
    /// (measured on the iPhone 18 Pro simulator, 2026-09-25) and 10pt on iOS 18, the deployment
    /// floor. Re-measure after an OS release that reshapes grouped cells, or the cards stop
    /// matching the cell groups under them.
    static var listCellRadius: CGFloat {
        if #available(iOS 26, *) { return 26 }
        return 10
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(ACABTheme.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ACABTheme.bg2, in: shape)
            .overlay {
                if edge { shape.strokeBorder(ACABTheme.tint.opacity(0.35), lineWidth: 1) }
            }
    }
}

private extension View {
    /// A Beacon tab card (BeaconCard).
    func beaconCard(edge: Bool = false) -> some View { modifier(BeaconCard(edge: edge)) }
}

/// The Beacon tab: rows for the board and for this phone (a BOARD / THIS <IDIOM> segmented list
/// in compact width, two columns in regular width); each row pushes one of the cards below as a
/// sub-screen.
struct DeviceView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var manifest: FirmwareManifestStore
    // Deep-link tokens from MainTabView: 0 is every token's initial value, never a request.
    private let openDetectorsToken: Int
    private let openNotifyToken: Int
    private let openLiveModeToken: Int
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
    /// BOARD or THIS <IDIOM>. Session state: it survives tab switches, not a relaunch (C13).
    @State private var segment: BeaconSegment
    /// The pushed sub-screen, if any. A deep link replaces it with the one row it opens.
    @State private var path: [BeaconRowID] = []
    // The last value of each deep-link token this view acted on. beaconRoot leaves and comes back
    // on every push, pop and tab switch, and `onChange(initial: true)` can run its action again
    // when it comes back; without these, Back from a deep-linked row would push the same row
    // again. Twin of Android DeviceScreen's handled*Token watermarks (shouldHandleOpenToken).
    @State private var handledDetectorsToken = 0
    @State private var handledNotifyToken = 0
    @State private var handledLiveModeToken = 0
    /// The promoted firmware banner's inline disclosure, the one fold left on this tab.
    @State private var firmwareBannerOpen = false
    // Regular width lays the rows out in two columns (BOARD, THIS <IDIOM>); compact is one
    // segmented list.
    @Environment(\.horizontalSizeClass) private var hSize
    // Accessibility text sizes stack the hero and pad the bottom of the ScrollView pages; the
    // default layout is untouched.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(openDetectorsToken: Int = 0, openNotifyToken: Int = 0, openLiveModeToken: Int = 0,
         initialSegment: BeaconSegment? = nil) {
        self.openDetectorsToken = openDetectorsToken
        self.openNotifyToken = openNotifyToken
        self.openLiveModeToken = openLiveModeToken
        // A DEBUG launch push opens About, a THIS <device> row, so it picks that segment too.
        _segment = State(initialValue: initialSegment
            ?? (DeviceView.launchPath.isEmpty ? DeviceView.launchSegment : .phone))
        _path = State(initialValue: DeviceView.launchPath)
    }

    /// Parsed once per process: MainTabView rebuilds DeviceView on every RootView body pass (~3 Hz),
    /// the same reason as MainTabView.launchTab.
    private static let launchSegment: BeaconSegment = {
        #if DEBUG
        return beaconLaunchSegment(ProcessInfo.processInfo.arguments)
        #else
        return .board
        #endif
    }()

    /// The DEBUG `-beacon-push` stack, parsed once per process for the same reason.
    private static let launchPath: [BeaconRowID] = {
        #if DEBUG
        return beaconLaunchPush(ProcessInfo.processInfo.arguments).map { [$0] } ?? []
        #else
        return []
        #endif
    }()

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

    // STAGED, AND EVERY onChange CLOSURE IS TYPED, ON PURPOSE. Xcode 26.6 (the gating CI lane) gave
    // up on RootView's shell when one expression held five overloaded onChange calls with untyped
    // closures (85e32cf). This body had the same shape, so it is three stages (beaconRoot,
    // beaconDeepLinks, body), none with more than three onChange calls, and every onChange closure
    // names its parameter types. Do not fold the stages back into one chain.
    var body: some View {
        NavigationStack(path: $path) { beaconDeepLinks }
            .onAppear(perform: sync)
            .onChange(of: ble.status) { (_: DeviceStatus?, _: DeviceStatus?) in sync() }
            // "moto" lives outside DeviceStatus, so a frame that changed only the Motorola sub-toggle
            // (the board echoing our write back) wouldn't move `status` and wouldn't clear the pending
            // hold. Watch it directly.
            .onChange(of: ble.motorolaOn) { (_: Bool, _: Bool) in sync() }
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

    /// Stage two: the root page plus the three deep-link tokens (exactly three onChange calls).
    private var beaconDeepLinks: some View {
        beaconRoot
            .onChange(of: openDetectorsToken, initial: true) { (_: Int, token: Int) in
                openRow(token, handled: $handledDetectorsToken, segment: .board, row: .detectors)
            }
            .onChange(of: openNotifyToken, initial: true) { (_: Int, token: Int) in
                openRow(token, handled: $handledNotifyToken, segment: .phone, row: .notifications)
            }
            .onChange(of: openLiveModeToken, initial: true) { (_: Int, token: Int) in
                openRow(token, handled: $handledLiveModeToken, segment: .phone, row: .liveMode)
            }
    }

    /// Stage one: the layout for this size class, its title, the refresh item and the push
    /// destinations. No onChange here.
    private var beaconRoot: some View {
        Group {
            // This read is what makes the foreground permission bump repaint the view: SwiftUI
            // never invalidates for a @State the body does not read, and the blocked warnings
            // render off notifier.mutedBySystem / liveActivitiesEnabled, plain cached vars
            // with no publisher of their own.
            let _ = systemPermissionRevision
            if hSize == .regular { regularLayout } else { compactList }
        }
        // One header row: "Beacon" leading, refresh trailing (TabHeader, M2).
        .tabHeader("Beacon") { refreshButton }
        .navigationDestination(for: BeaconRowID.self) { (id: BeaconRowID) in destination(id) }
    }

    /// A deep link: pick the segment, push the row, once per token value. 0 is every token's
    /// initial value and every watermark's start, so it is never a request.
    private func openRow(_ token: Int, handled: Binding<Int>, segment target: BeaconSegment,
                         row: BeaconRowID) {
        guard Self.shouldHandleOpenToken(token, handledWatermark: handled.wrappedValue) else { return }
        handled.wrappedValue = token
        segment = target
        path = [row]
    }

    /// The watermark rule, the same as Android's shouldHandleOpenToken: act only on a token newer
    /// than the last one handled, so a re-run of the onChange action for the same value is a no-op.
    static func shouldHandleOpenToken(_ token: Int, handledWatermark: Int) -> Bool {
        token > handledWatermark
    }

    /// Ask the board for a fresh status frame right now, instead of waiting for the next periodic
    /// notify. Same gate, action, label and hints the old header button had.
    private var refreshButton: some View {
        Button { ble.otaRereadStatus() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .disabled(!canRefreshBoardStatus)
        .accessibilityLabel("Refresh device status")
        .accessibilityHint(canRefreshBoardStatus
            ? "Requests a current status frame from the beacon."
            : "Available after the secure beacon link is ready.")
    }

    // MARK: layouts
    // Both layouts are AnyView on purpose: an iPad size-class change flips this branch, which is
    // the flip class of the documented firmwareCard crash (see the note on firmwareCard).

    /// Compact: the top matter (restore panel, cross-cutting banners, segmented control) in ONE
    /// clear row, then the chosen segment's rows as system inset-grouped sections.
    private var compactList: AnyView {
        AnyView(List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // THE ONE CARD THAT OUTRANKS THE PAGE. Both of the offer's in-card homes are
                    // board-control sub-screens (Desert, Alerts), which are disabled as a set with
                    // their rows while the board is away, and a SwiftUI disable propagates down with
                    // no way for a child to opt out; so while that gate is shut this panel is the
                    // only reachable copy. It LEADS, above the cross-cutting banners and the
                    // segmented control, so it shows in both segments, because a silence this app
                    // imposed is the one thing on the page the app owes the user. While a board
                    // sub-screen covers this page, subScreen draws the same panel there. The two
                    // platforms place it identically on the root page, at both widths (see
                    // regularLayout for the shared order).
                    //
                    // Nothing about taking it needs the board: the alert mode is a phone preference.
                    // The board write it also makes is dropped while there is no link; the next
                    // connect re-sends the wanted mode, and reconcileBuzzer re-asserts it from the
                    // first status frame if the board still disagrees. That is the same path as any
                    // other mode picked while offline.
                    if desertRestoreNeedsDetachedSurface(restoreOffered: alertRestoreOffered,
                                                         boardControlsAvailable: hardwareControlsEnabled) {
                        AlertRestorePanel()
                    }
                    crossCuttingBanners
                    segmentPicker
                }
                // One row, so the row modifiers bind to all of it. Every Button and Link that can
                // draw in it carries .buttonStyle(.plain): a List row with default-style buttons
                // fires every button in the row on one tap.
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(beaconRowGroups(rows(for: segment))) { listSection($0) }
        }
        .listStyle(.insetGrouped)
        // Compact spacing and a small top margin: the default first-section inset left an empty
        // band about 56pt tall between the title row and the segmented control, the "unfinished"
        // gap the owner pointed at on 2026-09-25.
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(ACABTheme.bg))
    }

    /// One grouped section of the compact List. The hero and the stat tiles are CARDS (each draws
    /// its own surface, see beaconCard), so their section has no system cell background and no
    /// insets; every other group is a system cell group under its intro header. Boxed like
    /// rowView, so the ForEach above holds one plain type.
    private func listSection(_ group: BeaconRowGroup) -> AnyView {
        if group.isCardGroup {
            return AnyView(Section {
                cardGroup(group)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            })
        }
        return AnyView(Section {
            ForEach(group.rows, id: \.self) { rowView($0) }
                // Pinned to the measured surface at both contrast levels: the system
                // grouped cell colour changes under Increase Contrast.
                .listRowBackground(ACABTheme.bg2)
                .listRowSeparatorTint(ACABTheme.line)
        } header: {
            groupIntro(group)
        })
    }

    /// A card group's rows side by side (the Uptime and Detections tiles, as 2.0.8 drew them),
    /// or one above the other at accessibility sizes, where a half-width tile would shrink its
    /// number past legibility. The hero group is one card, so either layout draws it alone.
    private func cardGroup(_ group: BeaconRowGroup) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(group.rows, id: \.self) { rowView($0) }
        }
    }

    /// A group's header: its C2 identifier (when the group has a header row) over a one-line
    /// description of what the group holds, the shape of 2.0.8's "BEACON HARDWARE" block. A group
    /// with neither draws nothing.
    @ViewBuilder
    private func groupIntro(_ group: BeaconRowGroup) -> some View {
        let intro = groupIntroText(group.id)
        if group.header != nil || intro != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let header = group.header { rowView(header) }
                if let intro {
                    Text(intro)
                        .font(ACABTheme.font(.footnote))
                        .foregroundStyle(ACABTheme.dim)
                        // A List header slot upper-cases its content; this is a sentence.
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        // The hand-built header's insets, as SectionHeader carries them.
                        .padding(.leading, hSize == .regular ? 16 : 0)
                        .padding(.bottom, hSize == .regular ? 6 : 0)
                }
            }
        }
    }

    /// The one-line description under each group's header, keyed by BeaconRowID.sectionKey. The
    /// cards (hero, stats), the Disconnect group and the saved-log group have none. The ON THE
    /// BOARD line drops "alerts" on a mesh board, which has no buzzer and so no Alerts row; the
    /// help line drops "setup checks" in the sample tour, which has no System readiness row.
    /// Body copy, so lowercase-first (repo CLAUDE.md, Copy rules); "desert mode" is lowercase as
    /// the app's other sentences write it, and "Live Mode" keeps its capitals as everywhere else.
    /// Mesh-ness reads the same `isMeshDetect` gate as `rows(for:)`, so the line and the rows
    /// under it never disagree about the Alerts row.
    /// TWIN: android DeviceScreen.kt beaconGroupIntro (the same sentences, byte for byte).
    private func groupIntroText(_ key: Int) -> String? {
        switch key {
        case BeaconRowID.scanRadios.sectionKey:
            return "radios, detectors, desert mode, and the offline buffer."
        case BeaconRowID.boardLED.sectionKey:
            return ble.status?.isMeshDetect == true
                ? "the board light, firmware, and managed devices."
                : "alerts, the board light, firmware, and managed devices."
        case BeaconRowID.notifications.sectionKey:
            return "notifications, Live Mode, and display for this \(thisDeviceName)."
        case BeaconRowID.helpSupport.sectionKey:
            return ble.demoMode ? "help, support, and about this app."
                : "setup checks, help, support, and about this app."
        default:
            return nil
        }
    }

    /// Regular width (C16): the restore panel, the cross-cutting surfaces and the hero span the
    /// full width, in that order, then the board and this device get one column each, so scope is
    /// visible without making a user infer it from what a toggle happens to do.
    ///
    /// The order both apps share: compact = the restore panel, the cross-cutting banners, then
    /// the segmented control; regular = the restore panel, the cross-cutting banners, the hero,
    /// then the two columns. TWIN: Android DeviceScreen's twoCol branch (and the
    /// AlertRestorePanel call above it) in DeviceScreen.kt.
    private var regularLayout: AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // LEADS the page, full width and above the split, as it leads the compact page.
                // Putting it in the hardware column instead would make a silence the app imposed
                // half a page wide beside the board rows, and it is not board hardware anyway: the
                // alert mode is a phone preference.
                if desertRestoreNeedsDetachedSurface(
                    restoreOffered: alertRestoreOffered,
                    boardControlsAvailable: hardwareControlsEnabled) {
                    AlertRestorePanel()
                }
                crossCuttingBanners
                rowView(.hero)
                HStack(alignment: .top, spacing: 14) {
                    regularColumn("BOARD", beaconRowGroups(rows(for: .board).filter { $0 != .hero }))
                    regularColumn("THIS \(thisDeviceName.uppercased())", beaconRowGroups(rows(for: .phone)))
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: 1000).frame(maxWidth: .infinity)
            .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
        }
        // Extra bottom margin only at accessibility sizes, so grown content never ends under the
        // tab bar; zero at default sizes (layout untouched).
        .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
        .background(ACABTheme.bg))
    }

    /// One regular-width column: its C2 identifier header (BOARD / THIS <IDIOM>), then its groups
    /// 14pt apart. The header opens the FIRST group the way a group's own header opens its intro
    /// in groupIntro (SectionHeader's 6pt bottom padding, then 3pt), so the first content of
    /// either column, the Uptime / Detections tiles or the PREFERENCES header, starts 9pt under
    /// its header at the same height, the rhythm DETECTION and ON THE BOARD keep above their
    /// intros. With the header one column spacing above the first group, this device's first
    /// group floated 20pt under THIS IPAD while DETECTION's intro sat 9pt under its header. TWIN:
    /// Android DeviceScreen's twoCol columns (SectionLabel, then groupView with leadsColumn).
    private func regularColumn(_ title: String, _ groups: [BeaconRowGroup]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                SectionHeader(title)
                if let first = groups.first { handBuiltGroup(first) }
            }
            ForEach(Array(groups.dropFirst())) { handBuiltGroup($0) }
        }
        .frame(maxWidth: .infinity, alignment: .top))
    }

    /// One grouped section drawn by hand for the regular-width ScrollView: its intro (a
    /// SectionHeader via rowView, then the description line) over one cell with line separators
    /// between the rows. A card group draws its cards as the compact List does.
    private func handBuiltGroup(_ group: BeaconRowGroup) -> AnyView {
        if group.isCardGroup { return AnyView(cardGroup(group)) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            groupIntro(group)
            VStack(spacing: 0) {
                ForEach(group.rows, id: \.self) { id in
                    if id != group.rows.first {
                        Divider().overlay(ACABTheme.line).padding(.leading, ACABTheme.pad)
                    }
                    rowView(id).padding(.horizontal, ACABTheme.pad).padding(.vertical, 6)
                }
            }
            .groupedCell(padding: 0)
        })
    }

    /// The surfaces that concern the whole tab, drawn above the segmented control in compact width
    /// (so they show in both segments) and at full width in regular width.
    @ViewBuilder
    private var crossCuttingBanners: some View {
        if coprocFault { coprocFaultBanner }        // dual-radio nRF fault
        else if nrfUpdating { nrfUpdatingBanner }   // same slot, but the nRF is down on purpose
        if let promotion = firmwarePromotion { firmwareBanner(promotion) }
        if !hardwareControlsEnabled { hardwareControlsUnavailable }
    }

    /// BOARD / THIS <IDIOM>: the system segmented control in a 44pt-tall row. The labels are C2
    /// uppercase identifiers; "Beacon settings" is the spoken name of the control.
    private var segmentPicker: some View {
        Picker("Beacon settings", selection: $segment) {
            Text("BOARD").tag(BeaconSegment.board)
            Text("THIS \(thisDeviceName.uppercased())").tag(BeaconSegment.phone)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
    }

    // MARK: rows

    /// The ONE beaconRows call in this file: the segment's rows with this screen's live gates. Its
    /// `meshBoard:` line is a drift needle that must match exactly once, which is why the regular
    /// width layout calls this wrapper twice instead of spelling the call again.
    private func rows(for segment: BeaconSegment) -> [BeaconRowID] {
        beaconRows(segment: segment,
                   meshBoard: ble.status?.isMeshDetect == true,
                   firmwareVisible: !updateExists,
                   demo: ble.demoMode,
                   improveAvailable: improveDetectionAvailable(isSessionReady: ble.sessionReady,
                                                               isDemoMode: ble.demoMode),
                   hasSavedLog: !ble.logDetections.isEmpty,
                   showPowerOff: showPowerOff)
    }

    /// The row renderer. EVERY arm returns its own AnyView, on purpose: a ForEach over a switch of
    /// 22 cases would otherwise build one deeply nested _ConditionalContent type, the type
    /// class of the documented firmwareCard crash. Never turn this into a @ViewBuilder switch.
    private func rowView(_ id: BeaconRowID) -> AnyView {
        switch id {
        case .hero:
            // Deferred: the hero is the heaviest arm (two ViewThatFits candidates, the drawn
            // board mark, the battery gauge), and this renderer runs inside the List's ForEach
            // under a long modifier chain (repo CLAUDE.md, iOS Debug stack).
            return AnyView(DeferredView { deviceHero })
        case .uptime:
            return AnyView(statTile("Uptime",
                                    hasCurrentBoardStatus ? (ble.status.map(uptimeText) ?? "-") : "-"))
        case .detections:
            // Detections is the PHONE-SIDE LOG count, including retained evidence hidden by
            // active mutes.
            //
            // It used to read the board's since-boot session total (status "total"), and the
            // comment even claimed that was "the same source as Android" - it was not: Android
            // has always shown the phone log. The board total is a different number that Clear
            // cannot lower (it only resets on a power cycle) and that Desert mode inflates into
            // the tens of thousands, so it read as a runaway counter the user could not reconcile
            // with a log they had just cleared. The phone log responds to Clear, matches what the
            // Log tab holds, and now agrees across both platforms.
            return AnyView(statTile("Detections", "\(ble.logDetections.count)"))
        case .detectionHeader:
            return sectionHeaderRow("DETECTION")
        case .onBoardHeader:
            return sectionHeaderRow("ON THE BOARD")
        case .preferencesHeader:
            return sectionHeaderRow("PREFERENCES")
        case .supportHeader:
            return sectionHeaderRow("SUPPORT")
        case .scanRadios:
            return boardLink(id, "Scan radios", radiosKicker, "antenna.radiowaves.left.and.right")
        case .detectors:
            // switch.2, not "scope": scope is the Status tab's glyph (RootView tabItem), and one
            // glyph for "which detectors run" and "the Status tab" made them read as related
            // (BEA-8). TWIN: android DeviceScreen.kt's DETECTORS row icon (Icons.Filled.ToggleOn,
            // the same toggle idea).
            return boardLink(id, "Detectors", detectorsKicker, "switch.2")
        case .desert:
            return boardLink(id, "Desert mode + buffer", desertKicker, "mountain.2")
        case .alerts:
            return boardLink(id, "Alerts", alertsKicker, "bell")
        case .boardLED:
            return boardLink(id, "Board LED", ledKicker, "lightbulb")
        case .firmware:
            // Firmware is maintenance, not an everyday scan control. It stays last when healthy;
            // any available/running/terminal state is promoted to the banner above the rows instead.
            // Board-gated like every board row (boardLink): while the board is away the row is
            // dimmed and does not open. TWIN: Android DeviceScreen's BeaconRowId.FIRMWARE row,
            // whose onClick is null unless boardControlsAvailable. Only the PAGE is ungated, on
            // both platforms (see `destination`).
            return boardLink(id, "Firmware", firmwareRowKicker, "memorychip")
        case .managedDevices:
            return pushLink(id, "Managed devices", managedKicker,
                            tile: GlyphTile(symbol: "star.fill", glyph: ACABTheme.watchTone))
        case .notifications:
            // Phone notifications work even on a mesh board with no buzzer.
            return pushLink(id, "Notifications", notifyKicker, tile: GlyphTile(symbol: "app.badge"))
        case .liveMode:
            return pushLink(id, "Live Mode", driveKicker,
                            tile: GlyphTile(symbol: "dot.radiowaves.left.and.right"))
        case .display:
            return pushLink(id, "Display", displayKicker, tile: GlyphTile(symbol: "circle.lefthalf.filled"))
        case .systemReadiness:
            return pushLink(id, "System readiness", nil, tile: GlyphTile(symbol: "checklist"))
        case .improveDetection:
            // Field research: contribute a capture of a device the beacon did not identify. Manual
            // export only (see ContributeView) - nothing leaves the phone without the user. Mirrors
            // Android's "Help improve detection" row.
            return pushLink(id, "Improve detection", "CONTRIBUTE A FIELD OBSERVATION",
                            tile: GlyphTile(symbol: "flask"))
        case .helpSupport:
            // The bundled FAQ and support routes: a reference surface, not a control.
            return pushLink(id, "Help + support", "FAQ · TROUBLESHOOTING · CONTACT",
                            tile: GlyphTile(symbol: "questionmark.circle"))
        case .about:
            return pushLink(id, "About", nil, tile: GlyphTile(symbol: "info.circle"))
        case .savedLog:
            return AnyView(savedLogButton)
        case .disconnect:
            return AnyView(disconnectButton)
        case .powerOff:
            return AnyView(powerOffButton)
        }
    }

    /// A C2 identifier header: a Kicker in the List header slot (compact), a SectionHeader over a
    /// hand-built cell (regular width).
    private func sectionHeaderRow(_ title: String) -> AnyView {
        hSize == .regular ? AnyView(SectionHeader(title)) : AnyView(Kicker(title))
    }

    /// A row that pushes its sub-screen. In the List the system draws the disclosure chevron; the
    /// hand-built regular-width cell draws its own. At accessibility sizes the List row is a
    /// button that pushes onto `path` and GroupedRow draws the chevron on its value line: the
    /// system disclosure holds a trailing column beside the WHOLE row, which left the title too
    /// narrow for one word ("Notifica-" / "tions" on This iPhone).
    private func pushLink(_ id: BeaconRowID, _ title: String, _ value: String?, tile: GlyphTile) -> AnyView {
        let handBuilt = hSize == .regular
        let ownChevron = handBuilt || dynamicTypeSize.isAccessibilitySize
        // The row's state is a telemetry line UNDER the title (2.0.8's shape), not a trailing
        // value: a trailing value squeezed the title ("Detectors" beside "6 ON \u{00B7} 1 EXP
        // \u{00B7} TRACKERS ON") and read as a bare settings table. At accessibility sizes it
        // goes in as the VALUE instead, which GroupedRow's stacked form draws on the same line
        // under the title but with the chevron at its end, so the title keeps the full width.
        let state = value.map(keepingMiddleDotsAttached)
        let big = dynamicTypeSize.isAccessibilitySize
        let row = GroupedRow(title: title, subtitle: big ? nil : state, value: big ? state : nil,
                             chevron: ownChevron, telemetrySubtitle: true) {
            tile.accessibilityHidden(true)
        }
        // A .plain link hit-tests only the drawn glyph, words and chevron, so the Spacer across a
        // wide iPad row was dead. contentShape gives the whole row the tap, as savedLogButton does.
        if handBuilt {
            return AnyView(NavigationLink(value: id) { row.contentShape(Rectangle()) }.buttonStyle(.plain))
        }
        if ownChevron { return AnyView(Button { path.append(id) } label: { row }) }
        return AnyView(NavigationLink(value: id) { row })
    }

    /// Board controls are read-only as a set while the board is away: the rows here and the
    /// sub-screen content (subScreen). desertRestoreNeedsDetachedSurface is the negation of this gate.
    private func boardLink(_ id: BeaconRowID, _ title: String, _ value: String, _ symbol: String) -> AnyView {
        AnyView(pushLink(id, title, value, tile: GlyphTile(symbol: symbol))
            .disabled(!hardwareControlsEnabled)
            .opacity(hardwareControlsEnabled ? 1 : 0.62))
    }

    /// "View saved log (N)", the connect screen's wording: opens the Log tab on All with no
    /// category (LogFocus.pendingAll; MainTabView switches the tab on the notification).
    private var savedLogButton: some View {
        Button {
            LogFocus.pendingAll = true
            NotificationCenter.default.post(name: LogFocus.notification, object: nil)
        } label: {
            GroupedRow(title: "View saved log (\(ble.logDetections.count))", chevron: true) {
                GlyphTile(symbol: "list.bullet.rectangle").accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The pushed page for a row. Every arm is boxed, like rowView.
    private func destination(_ id: BeaconRowID) -> AnyView {
        switch id {
        case .scanRadios:
            return AnyView(subScreen("Scan radios", boardControl: true) { radiosCard })
        case .detectors:
            return AnyView(subScreen("Detectors", boardControl: true) { detectorsCard })
        case .desert:
            // The buffer-erase dialog lives HERE, on the page that holds Erase: a dialog attached
            // to the covered root page never presents (the same finding as the rename alert on
            // managedDevicesScreen).
            return AnyView(subScreen("Desert mode + buffer", boardControl: true) {
                VStack(spacing: 12) { desertModeCard; offlineBufferCard }
            }
            .confirmationDialog(
                clearBufferConfirmationCopy.title,
                isPresented: $confirmEraseBuffer, titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive) { ble.clearBufferLog() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearBufferConfirmationCopy.message)
            })
        case .alerts:
            return AnyView(subScreen("Alerts", boardControl: true) { buzzerCard })
        case .boardLED:
            return AnyView(subScreen("Board LED", boardControl: true) { lightsOutCard })
        case .firmware:
            // NOT board-gated: starting an update here makes hardwareControlsEnabled false while
            // this page stays pushed, and a gated page would disable Cancel. The card's own buttons
            // gate themselves (combinedUpdateButton on hardwareControlsEnabled). The ROW is gated.
            return AnyView(subScreen("Firmware", boardControl: false) { firmwareCard })
        case .managedDevices:
            return AnyView(managedDevicesScreen)
        case .notifications:
            return AnyView(subScreen("Notifications", boardControl: false) { notifyCard })
        case .liveMode:
            return AnyView(subScreen("Live Mode", boardControl: false) { driveModeCard })
        case .display:
            return AnyView(subScreen("Display", boardControl: false) { displayCard })
        case .systemReadiness:
            // ReadinessView sets its own inline "System readiness" title.
            return AnyView(ReadinessView())
        case .improveDetection:
            return AnyView(ContributeView())
        case .helpSupport:
            return AnyView(HelpView(canImproveDetection: improveDetectionAvailable(
                isSessionReady: ble.sessionReady,
                isDemoMode: ble.demoMode)))
        case .about:
            return AnyView(aboutScreen)
        case .hero, .uptime, .detections, .detectionHeader, .onBoardHeader, .preferencesHeader,
             .supportHeader, .disconnect, .powerOff, .savedLog:
            // never pushed: rowView builds no NavigationLink(value:) for these rows
            return AnyView(EmptyView())
        }
    }

    /// One pushed Beacon sub-screen: today's card on the page background, an inline title, and for a
    /// board control the same read-only gate the rows use, with the note that explains it and, when a
    /// mode is owed, the restore offer the covered root page would otherwise be the only one to carry.
    private func subScreen<Content: View>(_ title: String, boardControl: Bool,
                                          @ViewBuilder content: () -> Content) -> some View {
        let locked = boardControl && !hardwareControlsEnabled
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if locked { hardwareControlsUnavailable }
                // The root page, which leads with AlertRestorePanel while the board is away, is covered
                // here, and the card below (with the Desert slot's and the Alerts card's own copy of the
                // offer) is disabled as a set. So a locked board page draws the same panel, outside the
                // disable. ONE line on purpose: neither S5 placement needle may match this third call.
                if locked && desertRestoreNeedsDetachedSurface(restoreOffered: alertRestoreOffered, boardControlsAvailable: hardwareControlsEnabled) { AlertRestorePanel() }
                content()
                    .disabled(locked)
                    .opacity(locked ? 0.62 : 1)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
            .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
        }
        .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
        .background(ACABTheme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // The card's CardKicker reads this to skip a kicker that only repeats the title (P3-7).
        .environment(\.subScreenTitle, title)
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

    /// Presenter tone as a FILL. Only the hero badge dot reads this, an 8 pt disc: the fill form
    /// of the presenter tone. Words drawn from the same presenter take `radioPresentationTextColor`.
    private var radioPresentationColor: Color {
        switch radioPresentation.tone {
        case .accent:  return ACABTheme.tint
        case .neutral: return ACABTheme.dim
        case .warning: return ACABTheme.warn
        }
    }

    /// Presenter tone as TEXT, for heroStatusText. The same mapping DashboardView's
    /// scanKickerColor gives the same presenter: a healthy `.accent` reads as quiet chrome in
    /// `dim`, not crimson, and only `.warning` colours the words. The reason is design, not
    /// contrast: `tint` is text-safe on every surface (ContrastPaletteTests testFlockHueIsNeverTextAndTintIs).
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
    // state can reach. firmwarePromotion is a computed property: one body pass builds it once for
    // crossCuttingBanners and once per `rows(for:)` call through `updateExists` (once in compact
    // width, twice in regular width). Every read sees the same published state, so the values
    // agree; threading one value through would save those builds and was not worth the parameter.
    // The banner's detail is full-strength onAccent on the tint fill: at the old 0.82 opacity it
    // measured under the 7:1 secondary-ink principle, so the smaller style tells it apart instead.
    private func firmwareBanner(_ presentation: BeaconFirmwareBannerPresentation) -> some View {
        let open = firmwareBannerOpen
        let fill: Color
        let titleTone: Color
        let detailTone: Color
        switch presentation.tone {
        case .accent:
            fill = ACABTheme.tint
            titleTone = ACABTheme.onAccent
            detailTone = ACABTheme.onAccent
        case .warning:
            fill = ACABTheme.warn.opacity(0.12)
            titleTone = ACABTheme.warn
            detailTone = ACABTheme.text
        case .neutral:
            fill = ACABTheme.bg2
            titleTone = ACABTheme.text
            detailTone = ACABTheme.dim
        }
        return VStack(spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { firmwareBannerOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    if ble.combinedState.isRunning {
                        ProgressView().controlSize(.small).tint(titleTone).frame(width: 20)
                    } else {
                        Image(systemName: presentation.tone == .warning
                              ? "exclamationmark.triangle.fill"
                              : (ble.combinedState == .done
                                 ? "checkmark.seal.fill" : "arrow.down.circle.fill"))
                            .font(ACABTheme.font(.subheadline, weight: .semibold))
                            .foregroundStyle(titleTone).frame(width: 20)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.title)
                            .font(ACABTheme.font(.body, weight: .semibold)).foregroundStyle(titleTone)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(presentation.detail)
                            .font(ACABTheme.font(.footnote))
                            .foregroundStyle(detailTone)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(titleTone)
                }
                .padding(16)
                .background(fill, in: RoundedRectangle(cornerRadius: ACABTheme.radius,
                                                       style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.title). \(presentation.detail)")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { firmwareCard }
        }
    }

    /// "iPhone" or "iPad", by idiom. This screen splits into the board's settings and the
    /// settings of the device in your hand, so the segment and the column header name that
    /// device - and it said "THIS IPHONE" on an iPad, which shipped into the store screenshots.
    /// The project targets device family "1,2", so there are only two answers. TWIN: android
    /// DeviceScreen.kt names THIS PHONE or THIS TABLET by smallestScreenWidthDp >= 600.
    private var thisDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    /// Drawn with the cross-cutting banners (above the segmented control in compact width, at full
    /// width in regular width) and on top of a locked board sub-screen (subScreen) while
    /// hardwareControlsEnabled is false: the board's own controls are read-only and this says so. It does not carry the restore offer: that is AlertRestorePanel, drawn beside it on
    /// both pages. Its last sentence tells the owner that this phone's preferences, and the
    /// restore offer, above it or on this page, stay available.
    private var hardwareControlsUnavailable: some View {
        let updating = ble.combinedState.isRunning || (hasCurrentBoardStatus && ble.status?.nrfUpdating == true)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: updating
                      ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right.slash")
                    .font(ACABTheme.font(.footnote, weight: .semibold))
                    .foregroundStyle(radioPresentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim)
                    .frame(width: 18)
                Text(updating
                     ? "Board controls pause while the firmware update is running. This \(thisDeviceName)'s preferences remain available."
                     : "Board controls are read-only until the secure link and a current status frame return. This \(thisDeviceName)'s preferences remain available.")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Combine the sentence and its glyph into one spoken element, which is now the whole
            // card: nothing tappable is left in it.
            .accessibilityElement(children: .combine)
        }
        .groupedCell(padding: 12)
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
                                    .font(ACABTheme.font(.footnote, weight: .bold))
                                    .foregroundStyle(ACABTheme.warn)
                                Text("Your latest watch or mute change is active for this session, but protected storage rejected it.")
                                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Retry Save") { ble.retryManagedListPersistence() }
                                    .font(ACABTheme.font(.footnote, weight: .bold))
                                    .foregroundStyle(ACABTheme.accentText)
                                    .padding(.top, 3)
                            }
                        }
                        .groupedCell()
                    }
                    if !ble.watched.isEmpty { watchedCard }
                    if !ble.ignored.isEmpty || ble.boardOnlyMuteCount > 0 { ignoredCard }
                    // Both lists empty: say so, or the pushed screen reads as a loading failure.
                    if ble.watched.isEmpty && ble.ignored.isEmpty && ble.boardOnlyMuteCount == 0 {
                        Text("No watched or muted devices yet.")
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
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
        // Not a subScreen (no board gate), so the page title is handed to the card here (P3-7).
        .environment(\.subScreenTitle, "About")
    }

    // MARK: row values (all live state, terse ALL-CAPS; each is a GroupedRow value)
    /// TWIN: android DeviceScreen.kt, the Firmware row's `firmwareRowKicker` `when` - the five arms below
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
        // Same string Android's Firmware row uses, and ahead of the healthy arm: a listing we refuse
        // to flash from is not "latest known".
        if !revisionMatchesManifest { return "UPDATE BLOCKED \u{00B7} REVISION MISMATCH" }
        // No UPDATE READY arm, matching Android's Firmware row: this row is only listed when
        // `updateExists` is false (beaconRows' firmwareVisible), and any available, running or
        // terminal update makes that true and promotes the banner in its place, so such an arm
        // could never draw.
        return "v\(installed) \u{00B7} LATEST KNOWN"
    }

    /// The Scan radios row's value. Sample data reads the sample frame's echoed radio switches in
    /// the live arm's words (`sampleRadiosRowValue`) instead of the presenter's "SAMPLE DATA"
    /// (P3-8 of the 2026-09-26 UI review): the banner, the pill, the dot and the hero already say
    /// sample on this page, and this row exists to show radio state. Real sessions print the
    /// presenter's scanLabel as before. Status keeps the presenter's sample label
    /// (dashboardScanKicker).
    private var radiosKicker: String {
        if ble.demoMode {
            return sampleRadiosRowValue(bleOn: ble.status?.ble == true, wifiOn: ble.status?.wifi == true)
        }
        return radioPresentation.scanLabel
    }

    private var detectorsKicker: String {
        let onCount = [flockOn, droneOn, bodyCamOn, trackerOn, glassesOn, netcamOn].filter { $0 }.count
        let expOn = [glassesOn].filter { $0 }.count
        return "\(onCount) ON \u{00B7} \(expOn) EXP \u{00B7} TRACKERS \(trackerOn ? "ON" : "OFF")"
    }

    /// The Alerts row's value. The Silent arm grows a second segment while the app is holding a
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
    /// Its "Blocked by iOS" arm (never in sample data) reads "BLOCKED BY IOS · COUNTS ..." on the
    /// Live Mode row through driveKicker. TWIN: android DeviceScreen.kt `beaconLiveRowValue`,
    /// whose blocked arm reads "LIVE BLOCKED BY ANDROID · COUNTS ..." (Android's own row shape).
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

    // MARK: device hero
    /// The BOARD hero CARD: the board mark, the name and the live status line, then a divider
    /// and a footer with the LinkChip leading and the battery gauge trailing. It draws its own
    /// surface with a crimson edge (beaconCard), 2.0.8's defined hero the owner asked back for on
    /// 2026-09-25 over Route A's plain cell. The LinkChip stays card content: a toolbar would put
    /// it on shared glass, where its measured contrast does not hold (see LinkChip: its ratios are
    /// measured on bg and bg2 only; the card is bg2).
    /// The top line stacks (mark above the text) at accessibility text sizes, and whenever the
    /// inline line does not fit the offered width (ViewThatFits); the battery lives in the footer
    /// now, so it no longer competes with the name. The footer stacks at accessibility sizes.
    /// TWIN: Android `DeviceHero` in DeviceScreen.kt, which stacks its top line at font scale 1.5
    /// and up, or when the name, measured on one line in its own style, does not fit beside the
    /// mark; its footer stacks at font scale 1.5 and up.
    private var deviceHero: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            Divider().overlay(ACABTheme.line)
            heroFooter
        }
        .beaconCard(edge: true)
    }

    private var heroInline: some View {
        HStack(spacing: 14) {
            heroBadge
            heroText
            Spacer(minLength: 8)
        }
    }

    private var heroStacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            heroBadge
            heroText
        }
    }

    /// The link pill leading, the battery gauge trailing; one above the other at accessibility
    /// sizes, where the two no longer share a line.
    @ViewBuilder
    private var heroFooter: some View {
        let chip = LinkChip(
            connected: ble.connectionState == .connected && ble.sessionReady
                && !ble.isReconnecting,
            demo: ble.demoMode,
            stateLabel: radioPresentation.chipLabel)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                chip
                heroBattery
            }
        } else {
            HStack(spacing: 12) {
                chip
                Spacer(minLength: 8)
                heroBattery
            }
        }
    }

    /// The board mark: the Beacon tab's own glyph (cpu.fill, RootView's tabItem) in crimson on a
    /// crimson-tinted tile, so the card names the device the way the tab bar does instead of
    /// showing an empty grey tile. The status dot sits on the tile's corner as a badge, ringed in
    /// the card colour, and carries the link state as colour without motion: amber in the sample
    /// tour, the presenter tone while a current status frame is in, faint otherwise.
    private var heroBadge: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(ACABTheme.tint.opacity(0.16))
            .frame(width: 56, height: 56)
            .overlay(
                Image(systemName: "cpu.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(ACABTheme.tint)
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(ble.demoMode ? ACABTheme.warn
                          : (hasCurrentBoardStatus ? radioPresentationColor : ACABTheme.faint))
                    .frame(width: 12, height: 12)
                    .padding(3)
                    .background(ACABTheme.bg2, in: Circle())
                    .offset(x: 6, y: -6)
            }
            .accessibilityHidden(true)
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Named by the board's kind (BLEManager.connectedKind: its fw label, else its stored
            // kind, else its advert hint), no longer by a substring of its advertised name:
            // "All Cameras Are Beacons" for a beacon or an unknown board, "OUI-Spy" and
            // "Mesh-Detect" for the Colonel Panic builds. TWIN: Android DeviceScreen.kt boardHeroTitle.
            Text(boardHeroTitle(ble.connectedKind))
                .font(ACABTheme.font(.title3, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
            // Coloured by the presenter's TEXT tone, so a warning state still reads amber here.
            // The board's telemetry line (state, firmware): the instrument face.
            Text(keepingMiddleDotsAttached(heroStatusText))
                .font(ACABTheme.telemetry(.subheadline, weight: .regular)).foregroundStyle(radioPresentationTextColor)
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

    /// A drawn battery gauge (outline, cap, a fill as wide as the charge) and "NN%": a level you
    /// read at a glance where the SF battery glyphs step in quarters. The fill is crimson while
    /// charging, amber at 15% or less, the text ink otherwise; the charging bolt rides on the
    /// gauge. Spoken as one element, "battery 82 percent" ("charging, battery 82 percent" while
    /// it charges). TWIN: android DeviceScreen.kt HeroBattery, which draws the same gauge in the
    /// same three tones and whose contentDescription is the same text byte for byte.
    @ViewBuilder
    private var heroBattery: some View {
        if hasCurrentBoardStatus, let status = ble.status, let bat = status.battery {
            let charging = status.charging
            let tone: Color = charging ? ACABTheme.tint : (bat <= 15 ? ACABTheme.warn : ACABTheme.text)
            let level = CGFloat(min(max(bat, 0), 100)) / 100
            HStack(spacing: 8) {
                HStack(spacing: 1.5) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(ACABTheme.dim, lineWidth: 1.5)
                        .frame(width: 34, height: 16)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(tone)
                                .frame(width: max(2, 28 * level), height: 10)
                                .padding(.leading, 3)
                        }
                        .overlay {
                            if charging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(ACABTheme.bg2)
                            }
                        }
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(ACABTheme.dim)
                        .frame(width: 2.5, height: 6)
                }
                Text("\(bat)%")
                    .font(ACABTheme.telemetry(.subheadline, weight: .semibold))
                    .foregroundStyle(bat <= 15 && !charging ? ACABTheme.warn : ACABTheme.text)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(charging ? "charging, battery \(bat) percent" : "battery \(bat) percent")
        }
    }

    /// One stat tile: the name in secondary subheadline over the tile's number in the instrument
    /// face (R16), the 2.0.8 Uptime / Detections tiles. The number is telemetry(.title2), 22pt x
    /// 0.9 = 20pt semibold: the point size of heroText's .title3 name, so its digits stand at the
    /// hero title's cap height, within 2px of it (measured 2026-09-27 at 3x: 44 to 45px digits,
    /// 43px hero cap; R22: at .title, 28pt x 0.9 = 25pt, the numbers were the biggest things on
    /// the page, 55px against the same 43px cap). Spoken as one element ("Uptime, 1h 22m").
    /// TWIN: android DeviceScreen.kt's BeaconRowId.UPTIME and BeaconRowId.DETECTIONS arms
    /// (StatTile, StatTileValueStyle = titleLarge in the instrument face, semibold).
    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ACABTheme.font(.subheadline))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(ACABTheme.telemetry(.title2, weight: .semibold))
                .foregroundStyle(ACABTheme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .beaconCard()
        .accessibilityElement(children: .combine)
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
                    .font(ACABTheme.font(.body, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(nrfUpdateDetail)
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .groupedCell()
    }

    private var coprocFaultBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("nRF radio fault - bluetooth detection offline")
                    .font(ACABTheme.font(.body, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(coprocFaultDetail)
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
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
    /// enough that flipping the branch - which is exactly what tapping "Update" does - made
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
            CardKicker("FIRMWARE")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.map { "v\($0)" } ?? "-")
                        .font(ACABTheme.font(.title3, weight: .semibold)).foregroundStyle(ACABTheme.text)
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
                    // of, not proof of global currency. Both platforms' Firmware ROWS
                    // (`firmwareRowKicker` here) already say "LATEST KNOWN".
                    Text(revisionMatchesManifest ? "v\(latestVersion)" : "-")
                        .font(ACABTheme.font(.title3, weight: .semibold))
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
        .groupedCell())
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
                // The firmware card's status glyphs, and the watched and muted rows' glyphs, ride
                // the footnote style (13pt at the default size, so nothing moves there) instead of
                // a fixed point size, so they grow with the text beside them: HIG Typography,
                // "Increase the size of meaningful interface icons as font size increases." The
                // ones that were 12pt add .imageScale(.small) to stay a step quieter.
                Image(systemName: "arrow.down.circle.fill")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.tint)
                // Name what is ACTUALLY behind. When only the co-processor is stale the board is
                // already on latestVersion, and the old unconditional wording read as a
                // contradiction next to the "vX INSTALLED / vX LATEST" row directly above it.
                Text(s3Stale
                     ? "Update available: v\(latestVersion). You can install it here, over Bluetooth."
                     : "Co-processor update available. The board firmware is already current; this updates the second radio, over Bluetooth.")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            combinedUpdateButton(title: "Update")
            Text("Installs over Bluetooth and usually takes about 2-3 minutes. The board restarts on its own partway through. Keep this phone next to the beacon with the app open until it finishes.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func combinedUpdateButton(title: String) -> some View {
        Button { if let e = fwEntry { ble.startCombinedUpdate(entry: e, fwLabel: fwLabel, latest: latestVersion) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                Text(title).font(ACABTheme.font(.body, weight: .semibold))
            }
            .foregroundStyle(ACABTheme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(ACABTheme.tint, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
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
                    .font(ACABTheme.font(.footnote)).foregroundStyle(combinedStatusTone)
                Text(combinedStatusLabel)
                    .font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                Spacer(minLength: 0)
                if ble.combinedState.isRunning {
                    Text("\(Int((ble.combinedProgress * 100).rounded()))%")
                        .font(ACABTheme.font(.subheadline, weight: .semibold, tabular: true))
                        .foregroundStyle(combinedStatusTone)
                }
            }
            if ble.combinedState.isRunning {
                ProgressView(value: min(max(ble.combinedProgress, 0), 1), total: 1).tint(ACABTheme.tint)
                Text(combinedElapsedText)
                    .font(ACABTheme.font(.footnote, tabular: true)).foregroundStyle(ACABTheme.dim)
            }
            if let detail = combinedDetailText {
                Text(detail).font(ACABTheme.font(.footnote)).foregroundStyle(combinedStatusTone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ble.combinedState.isRunning {
                Text("Keep this phone next to the beacon with the app open. Don't lock it or leave this screen.")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            combinedControlButtons
        }
    }

    /// Boxed for the same reason as `firmwareCard`: three arms, each a Button carrying a
    /// `.background(_:in:)` (they also carried an `.overlay(strokeBorder:)` until Route A),
    /// sitting inside the progress arm of the card's own branch. This was the single biggest
    /// contributor to the nesting depth that overflowed the demangler's stack.
    private var combinedControlButtons: AnyView {
        if ble.combinedCanCancel {
            return AnyView(secondaryButton("Cancel", tone: ACABTheme.tint, role: .destructive) {
                ble.combinedCancel()
            })
        }
        if ble.combinedState.isRunning {
            return AnyView(Text("The board has committed this update and is finishing safely.")
                .font(ACABTheme.font(.footnote))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true))
        }
        if case .partial = ble.combinedState {
            // S3 took; the second radio didn't finish. The same primary button re-offers just the
            // nRF leg (the S3 is current now, so a fresh run does the co-processor only).
            // Spacing 12 matches what the enclosing VStack gave these when they were loose
            // siblings in a ViewBuilder tuple, so the box does not change the layout.
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                combinedUpdateButton(title: "Finish Second Radio")
                secondaryButton("Not Now") { ble.dismissCombinedUpdate() }
            })
        }
        return AnyView(secondaryButton("Done") { ble.dismissCombinedUpdate() })
    }

    /// The card's flat secondary button. Factored out because all three control arms drew the same
    /// stack of modifiers inline, and every repetition of it deepened the composed view type that
    /// overflowed the demangler (see `firmwareCard`).
    private func secondaryButton(_ title: String,
                                 tone: Color = ACABTheme.dim,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(ACABTheme.font(.body, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(tone)
                .background(ACABTheme.bg3, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
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
    /// and the detail line ("Your beacon is up to date."). The crimson arm is `accentText`, which
    /// Theme.swift makes the same colour as `tint` since Route A, so it is text-safe.
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
        // The healthy `.accent` arm reads as quiet chrome in `dim`, not crimson, the colour Android
        // draws its "latest known firmware" line in (DeviceScreen.kt), and only `.warning` colours
        // the line. This is design, not contrast: since Route A `accent` is `tint`, which is text-safe.
        let tone = presentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: presentation.symbol)
                    .font(ACABTheme.font(.footnote)).foregroundStyle(tone)
                Text(presentation.detail)
                    .font(ACABTheme.font(.footnote)).foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if presentation.offersBrowserFlasher {
                Link(destination: flasherURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").font(ACABTheme.font(.footnote))
                        Text("Open the Browser Flasher")
                            .font(ACABTheme.font(.body, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(ACABTheme.font(.footnote, weight: .semibold)).imageScale(.small)
                    }
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.vertical, 11).padding(.horizontal, 13)
                    .background(ACABTheme.bg3, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
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
                        .font(ACABTheme.font(.footnote, weight: .semibold)).imageScale(.small)
                }
                // A failed network request deliberately keeps the last-good/bundled catalog. Since
                // the store does not discard that useful baseline, completion cannot prove that the
                // catalog itself was refreshed; only claim that the check finished.
                Text(checkingForUpdate ? "Checking\u{2026}" : (justChecked ? "Check Finished" : "Check for Updates"))
                    .font(ACABTheme.font(.footnote, weight: .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ACABTheme.dim)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(ACABTheme.bg3, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(checkingForUpdate)
    }

    // MARK: scan radios
    private var radiosCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("SCAN RADIOS")
            radioToggle("Bluetooth", "ALPR \u{00B7} drone \u{00B7} trackers", isOn: Binding(
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
            // runtime; Bluetooth is untouched. Honest about the tradeoff right below the control.
            if wifiOn, ble.status?.battery != nil {
                Divider().overlay(ACABTheme.line)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Kicker("WI-FI ECO")
                        Spacer()
                        Text(wifiEco == 0 ? "always on" : "sleeps \(wifiEco)s / sweep")
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    }
                    // System segmented control in a 44pt-tall row. It reports changes only, so a
                    // tap on the step already selected writes nothing (the old pills re-sent it).
                    Picker("Wi-Fi eco mode", selection: Binding(
                        get: { wifiEco },
                        set: { v in
                            wifiEco = v; pendingWifiEco = true
                            awaitConfirmation(.wifiEco); ble.setWifiEco(v)
                        })) {
                        Text("MAX").tag(0)
                        Text("3s").tag(3)
                        Text("7s").tag(7)
                        Text("15s").tag(15)
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    Text("stretches battery by sweeping Wi-Fi less often. you may miss a Wi-Fi-only camera between sweeps; Bluetooth detection is unaffected.")
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .groupedCell()
    }

    // MARK: detectors
    private var detectorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("DETECTORS")
            // "ALPR" stays uppercase inside the lowercase-first title, as everywhere else on the
            // tab (the acronym rule). TWIN: android DeviceScreen.kt's detectors row, byte-identical.
            radioToggle("ALPR radio signals", "flock over bluetooth or 2.4 GHz wifi \u{00B7} raven over bluetooth \u{00B7} many installs now stay silent", isOn: Binding(
                get: { flockOn }, set: {
                    flockOn = $0; pendingFlock = true; awaitConfirmation(.flock); ble.setFlockEnabled($0)
                }))
            Divider().overlay(ACABTheme.line)
            radioToggle("Drones (remote ID)", "FAA remote ID \u{00B7} operator location", isOn: Binding(
                get: { droneOn }, set: {
                    droneOn = $0; pendingDrone = true; awaitConfirmation(.drone); ble.setDroneEnabled($0)
                }))
            // Sub-option of the drone detector: the vendor-OUI fallback. Inset + disabled while the
            // parent drone detector is off, to read as subordinate to the toggle above it. Off by
            // default because an OUI match alone can't tell a stationary Parrot gadget from a drone.
            radioToggle("Non-broadcasting drones", "OUI match only, off by default, may false-positive", isOn: Binding(
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
            radioToggle("Body cams", "Axon \u{00B7} Utility BodyWorn \u{00B7} Motorola vendor match", isOn: Binding(
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
                radioToggle("Motorola Solutions", "vendor match only \u{00B7} their radios and docks too", isOn: Binding(
                    get: { motorolaOn }, set: {
                        motorolaOn = $0; pendingMotorola = true
                        awaitConfirmation(.motorola); ble.setMotorolaEnabled($0)
                    }))
                    .padding(.leading, 22)
                    .disabled(!bodyCamOn)
                    .opacity(bodyCamOn ? 1 : 0.4)
            }
            Divider().overlay(ACABTheme.line)
            radioToggle("Bluetooth trackers", "AirTag \u{00B7} Tile \u{00B7} SmartTag \u{00B7} opt-in", isOn: Binding(
                get: { trackerOn }, set: {
                    trackerOn = $0; pendingTracker = true
                    awaitConfirmation(.tracker); ble.setTrackerEnabled($0)
                }))
            Divider().overlay(ACABTheme.line)
            radioToggle("Recording glasses", "Ray-Ban / Oakley Meta \u{00B7} Snap \u{00B7} Vuzix \u{00B7} experimental", isOn: Binding(
                get: { glassesOn }, set: {
                    glassesOn = $0; pendingGlasses = true
                    awaitConfirmation(.glasses); ble.setGlassesEnabled($0)
                }), exp: true)
            Divider().overlay(ACABTheme.line)
            // Opt-in, off by default: enabling it turns on the board's 802.11 DATA-frame
            // source-MAC path (added CPU + 2.4GHz load), which is why it is gated. Honest copy:
            // it matches known IP-camera BRANDS on the host WiFi and cannot find every camera.
            radioToggle("Network cameras", "known IP-camera brands on wifi, opt-in, cannot find every camera", isOn: Binding(
                get: { netcamOn }, set: {
                    netcamOn = $0; pendingNetcam = true
                    awaitConfirmation(.netcam); ble.setNetcamEnabled($0)
                }))
        }
        .groupedCell()
    }

    // MARK: offline buffer
    // Board-side flash buffer: record while the phone is away, replay on reconnect.
    private var offlineBufferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("OFFLINE BUFFER")
            // A buffer control must not look trustworthy while firmware says evidence was lost
            // or a privacy/lifecycle write is still retrying. The Log shows the same notices.
            ForEach(ble.status?.bufferHealthNotices ?? [], id: \.self) {
                BufferHealthBanner(notice: $0)
            }
            radioToggle("Store detections offline", "board buffers while away \u{00B7} replays on reconnect", isOn: Binding(
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
                        Text("Buffered log").font(ACABTheme.font(.body, weight: .medium))
                            .foregroundStyle(ACABTheme.text)
                        // While the board is still sweeping a deferred erase, say so rather than
                        // inviting another erase against an about-to-be-zero count.
                        Text(ble.bufferWiping ? "clearing buffer\u{2026}" : "erase what the board stored while away")
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if ble.bufferWiping {
                        Text("CLEARING").font(ACABTheme.font(.footnote, weight: .bold))
                            .foregroundStyle(ACABTheme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    } else {
                        Button { confirmEraseBuffer = true } label: {
                            Text("Erase").font(ACABTheme.font(.footnote, weight: .bold))
                                .foregroundStyle(ACABTheme.accentText)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
                                .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .groupedCell()
    }

    // Board LED: on by default (a slow idle heartbeat + detection flashes, so it visibly runs);
    // "lights out" takes it fully dark for covert or stationary deploys. Persists on the board.
    private var lightsOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardKicker("BOARD LED")
            radioToggle("Lights out", "no LEDs \u{00B7} for covert or stationary deploys", isOn: Binding(
                get: { lightsOut }, set: {
                    lightsOut = $0; pendingLed = true
                    awaitConfirmation(.led); ble.setLedEnabled(!$0)
                }))
            Text("On by default the board LED gives a slow heartbeat so you can see it's alive, and flashes on a hit. Lights out keeps it completely dark.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .groupedCell()
    }

    // MARK: Live Mode (Live Activity)
    private var driveModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardKicker("LIVE MODE")

            HStack(spacing: 9) {
                Circle()
                    .fill((liveModeState == "Active" || liveModeState == "Preview on") ? ACABTheme.tint
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
            radioToggle("Live Activity counter",
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
            radioToggle("Hide counts on lock screen",
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
                    Button("Enable Location") { ble.requestLocationAccessIfNeeded() }
                        .font(ACABTheme.mono(10.5, weight: .bold))
                        .foregroundStyle(ACABTheme.accentText)
                        .frame(minHeight: 44)
                }
            }
        }
        .groupedCell()
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
            CardKicker("DESERT MODE")
            radioToggle("Report every device",
                        "show + log ANY device nearby \u{00B7} best out in the open",
                        isOn: Binding(get: { desertOn },
                                      set: {
                                          desertOn = $0; pendingDesert = true
                                          awaitConfirmation(.desert); ble.setDesertMode($0)
                                      }))
            Text("Off the grid, anything new on the air means something arrived. Each device is tagged hardware or randomized (phone) MAC, or OUI unknown when the radio cannot tell.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
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
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Desert is over and the alert mode stayed Silent. Nothing above says so, and a user
            // who left Desert expecting their beeps back reads the silence as a dead detector.
            // dim, the same tone as the secondary line above, NEVER warn: this reports a state
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
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            case .offer:
                AlertRestoreOffer()
            case .none:
                EmptyView()
            }
        }
        .groupedCell()
    }

    /// This screen's read of the one sample-tour gate. The expression itself lives at file scope
    /// (alertRestoreIsOffered) because the pre-connect screen asks the same question through
    /// RootView, and a gate spelled twice is a gate that can drift on one screen.
    private var alertRestoreOffered: Bool {
        alertRestoreIsOffered(isDemoMode: ble.demoMode, pending: ble.pendingAlertModeRestore)
    }

    /// A row title from a lowercase-first runtime string (P3-11): the first letter raised, the
    /// rest as written, so "body cam" reads "Body cam" and "ALPR camera" stays itself. Row titles
    /// are sentence case (owner, 2026-09-26); body copy that quotes the same name stays
    /// lowercase-first. Pure so a test can pin it.
    static func sentenceCaseRowTitle(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func radioToggle(_ name: String, _ sub: String,
                             isOn: Binding<Bool>, exp: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                    if exp { ExpTag() }
                }
                Text(keepingMiddleDotsAttached(sub)).font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
            }
        }
        .tint(ACABTheme.tint)
        .accessibilityLabel(spokenControlText(name))
        .accessibilityHint((exp ? "Experimental. " : "") + spokenControlText(sub))
    }

    /// VoiceOver should speak the domain abbreviations as concepts, not guess at strings such as
    /// ALPR, OUI, RID, and MAC. Visible copy stays compact; only the spoken surface expands it.
    /// Memoised per process: every radioToggle label and hint runs through here on each body pass
    /// while its page is pushed, and the inputs are a closed set (the toggle literals plus the
    /// DeviceType labels and notifySubtitle values), so the cache stays small. Main-thread only,
    /// like every View body that calls it.
    private func spokenControlText(_ text: String) -> String {
        if let cached = DeviceView.spokenCache[text] { return cached }
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
        DeviceView.spokenCache[text] = spoken
        return spoken
    }
    private static var spokenCache: [String: String] = [:]

    // MARK: alerts
    private var buzzerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("ALERTS")

            alertModePicker

            Text(alertModeCaption)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            // The SAME offer the Desert card carries, so whichever of the two rows the user opens
            // has the way back in it. No gate of its own beyond "a mode is pending": the Alerts row
            // does not exist on a mesh board (beaconRows), and the pending mode is cleared
            // the moment Desert comes back on or the user picks anything by hand.
            if alertRestoreOffered { AlertRestoreOffer() }

            // LIVE IN ALL THREE MODES. Vibrate and Silent turn detection beeps off, so the only
            // thing this level still governs there is the shutdown cue the caption above names -
            // and volume 0 is the ONLY thing that silences it (firmware alerts.cpp buzzerTone: a
            // PowerState cue bypasses the alert mute, a zero volume does not). Greying the slider
            // out in those two modes made the remedy their own copy names unreachable from them.
            // Android twin: the same rule on VolumeSlider in DeviceScreen.kt's BuzzerCard.
            VStack(spacing: 14) {
                slider("Master volume", value: $master, tone: ACABTheme.tint, bold: true,
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
        .groupedCell()
    }

    // MARK: phone notifications
    //
    // A SEPARATE card from ALERTS on purpose. ALERTS picks how the BOARD behaves (buzzer / vibrate
    // / silent); this picks which categories are worth interrupting you for on the PHONE. Folding
    // them together implied a dependency that does not exist: a silent board with notifications on
    // is a perfectly normal setup, and arguably the main one for a device you keep in a bag.
    private var notifyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("PHONE NOTIFICATIONS")

            if !ble.demoMode, ble.notifier.mutedBySystem {
                // A green toggle over a dead feature is the worst outcome here: the user believes
                // they are covered. Say it plainly instead.
                Text("iOS is blocking these. Turn notifications on for beacons in Settings, or nothing here will arrive.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                openSettingsButton
            }

            // TWIN: android DeviceScreen.kt `notifyCardExplainer`, the same two sentences with
            // "Android" in the platform hole.
            Text(ble.demoMode
                 ? "Preview which categories you could enable. Nothing is saved and iOS won't ask permission."
                 : "Pick what's worth a notification. Every category is off until you turn it on, and iOS asks permission the first time you do.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(DetectionNotifier.notifiableTypes, id: \.self) { t in
                    let on = ble.phoneNotificationEnabled(t)
                    VStack(alignment: .leading, spacing: 4) {
                        // The row title is DeviceType.inlineLabel ("ALPR camera", "body cam",
                        // "watched device") with its first letter raised, sentence case like
                        // every other row title on the tab (P3-11: "Body cam", "Drone", the
                        // acronym "ALPR camera" unchanged); `label` mixed "ALPR Camera" and
                        // "Body Camera" with "Network camera" in one list of seven. The body
                        // sentence below keeps the bare inlineLabel. TWIN: android
                        // DeviceScreen.kt's notification rows, the same choice (drift
                        // 'inlineLabel').
                        radioToggle(Self.sentenceCaseRowTitle(t.inlineLabel), notifySubtitle(t), isOn: Binding(
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
        .groupedCell()
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

    // The three-way alert mode control. Owner decision D2 (2026-09-24): it LOOKS like the system
    // segmented control (system type, a tertiary-fill capsule track, a grey selected thumb, the
    // selected label a cut heavier, no hairline, at least 44pt tall) but is built by hand so a tap
    // on the ALREADY-selected segment still runs setAlertMode with origin .user, exactly as the
    // hand-rolled control before it did. That re-tap is how an owner turns a restore offer down:
    // tapping Silent while Silent is selected clears the offer. A system Picker reports changes
    // only, so it would write nothing there. Each segment is its own tap target, a button with
    // the selected trait. Labels wrap at large text sizes and the row grows (fixedSize below keeps
    // the three cells one height). TWIN: android DeviceScreen.kt AlertModePicker, same decision.
    private var alertModePicker: some View {
        HStack(spacing: 0) {
            alertModeSegment("Buzzer",  .buzzer)
            alertModeSegment("Vibrate", .vibrate)
            alertModeSegment("Silent",  .silent)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(2)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alert mode")
    }

    /// One cell of alertModePicker: the whole cell (40pt inside the 2pt track inset, so the row
    /// is at least 44pt) is the tap target, and the thumb fills it when selected.
    private func alertModeSegment(_ label: String, _ mode: AlertMode) -> some View {
        let active = ble.alertMode == mode
        return Button { ble.setAlertMode(mode, origin: .user) } label: {
            Text(label)
                .font(ACABTheme.font(.subheadline, weight: active ? .semibold : .regular))
                .foregroundStyle(ACABTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                .background(active ? DeviceView.alertModeThumb : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The selected thumb: the system dark segmented thumb (systemGray2, #636366) at the default
    /// contrast, and systemGray3 (#6C6C70) under higher contrast, where systemGray2 lightens to
    /// #7C7C80 and white text on it drops to 4.16:1. White label on the thumb: 5.99 / 5.23; thumb
    /// against the tertiary-fill track over the grouped cell: about 2.1 / 2.2 (the native pair).
    private static let alertModeThumb = Color(uiColor: UIColor { traits in
        traits.accessibilityContrast == .high
            ? UIColor.systemGray3.resolvedColor(with: traits)
            : UIColor.systemGray2.resolvedColor(with: traits)
    })

    /// "3 ON" / "OFF", so the Notifications row's value says whether anything will interrupt you,
    /// and "3 ON · BLOCKED BY IOS" while iOS blocks them (never in sample data). TWIN: android
    /// DeviceScreen.kt `beaconNotifyRowValue` ("3 ON · BLOCKED BY ANDROID").
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
            Text("Open Settings")
                .font(ACABTheme.mono(11, weight: .bold))
                .foregroundStyle(ACABTheme.accentText)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha),
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
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
    /// foreground service keeps ingest alive - so the qualifier would be wrong there. Only the
    /// iOS half is in the user docs: the "choose alerts" section of docs/app-guide.md and the
    /// q-sounds answer in both faq-content.json copies say iPhone haptics play while the app is
    /// open. Neither doc says Android's haptic also fires with the screen locked under Live Mode.
    /// Sync the other two strings freely; do not converge this one without changing the
    /// behaviour first.
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

    /// Uptime tile value. TWIN: android uptimeText(seconds:), format "Xh Ym" / "Ym".
    private func uptimeText(_ s: DeviceStatus) -> String {
        let h = s.uptime / 3600, m = (s.uptime % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var disconnectButton: some View {
        // Block Disconnect while an update is running: a mid-reboot teardown races the OTA reconnect
        // (and can drop into a pending-connect cancel that fires no callback), so keep the link put
        // until the flow reaches a terminal state. Sample data isn't an update, so it stays tappable.
        // A tinted, centered row with NO role: leaving is not destructive (C13). The system dims
        // the disabled label.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button { ble.demoMode ? ble.exitDemo() : ble.disconnect() } label: {
            Text(ble.demoMode ? "Exit Sample Data" : "Disconnect")
                .font(ACABTheme.font(.body))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .tint(ACABTheme.tint)
        .disabled(otaRunning)
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
        // System red (role .destructive), centered; the system dims the disabled label.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button(role: .destructive) { confirmPowerOff = true } label: {
            Text("Power Off Beacon")
                .font(ACABTheme.font(.body))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(otaRunning || !hardwareControlsEnabled)
        // Anchored to the BUTTON, not stacked on the NavigationStack next to the buffer-erase dialog:
        // two .confirmationDialog modifiers on the same view fight over the presentation anchor, which
        // is why the sheet pointed at the wrong (top) row. On its own trigger view it anchors here.
        .confirmationDialog(
            "Power off the beacon?",
            isPresented: $confirmPowerOff, titleVisibility: .visible
        ) {
            Button("Power Off", role: .destructive) { ble.powerOffBeacon() }
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
                    Image(systemName: "star.fill").font(ACABTheme.font(.footnote)).imageScale(.small)
                        .foregroundStyle(ACABTheme.watchTone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased())
                            .font(ACABTheme.font(.footnote, design: .monospaced)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                    Button {
                        renameText = dev.label
                        renameIsIgnored = false
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(ACABTheme.font(.footnote, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(minWidth: 44, minHeight: 44)   // 44pt hit target floor; the glyph rides Dynamic Type
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unwatch(dev.mac) } label: {
                        Text("Unstar").font(ACABTheme.font(.footnote, weight: .bold))
                            .foregroundStyle(ACABTheme.watchTone)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(ACABTheme.watchTone.opacity(ACABPalette.pillFillAlpha), in: Capsule())
                            .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.watched.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .groupedCell()
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
                    Image(systemName: "bell.slash").font(ACABTheme.font(.footnote)).imageScale(.small)
                        .foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased())
                            .font(ACABTheme.font(.footnote, design: .monospaced)).foregroundStyle(ACABTheme.dim)
                        Text(dev.scopeLabel.uppercased())
                            .font(ACABTheme.font(.caption2, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                    // Naming a muted device matters as much as naming a starred one: six weeks on,
                    // "my own AirTag" is the difference between trusting the mute and undoing it.
                    Button {
                        renameText = dev.label
                        renameIsIgnored = true
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(ACABTheme.font(.footnote, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(minWidth: 44, minHeight: 44)   // 44pt hit target floor; the glyph rides Dynamic Type
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unignore(dev.mac) } label: {
                        Text("Unmute").font(ACABTheme.font(.footnote, weight: .bold))
                            .foregroundStyle(ACABTheme.accentText)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
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
                        .font(ACABTheme.font(.footnote, weight: .semibold)).foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(ble.boardOnlyMuteCount) board-only mute\(ble.boardOnlyMuteCount == 1 ? "" : "s")")
                            .font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                        Text("Created from another phone. This beacon reports only the count, so this phone cannot show or remove those devices individually.")
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .groupedCell()
    }

    // MARK: display
    //
    // "always use higher contrast": OFF follows the iOS Increase Contrast setting, ON forces the
    // higher-contrast palette. Named that way, rather than "higher contrast", so a user whose
    // iOS setting is on understands why turning this off changes nothing. The palette itself
    // lives in ACABTheme; this card only flips the window trait (ContrastPreference). The trait
    // also reaches type: TypePrefs.highContrast bumps every themed font one cut heavier, which
    // is iOS-only (Android's platform restyles text itself).
    // Android twin: DisplayCard in DeviceScreen.kt.
    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardKicker("DISPLAY")
            radioToggle("Always use higher contrast",
                        "brighter secondary text, heavier type and clearer control edges \u{00B7} off follows the system contrast settings",
                        isOn: $contrast.alwaysHigher)
            Text(contrast.systemIncreased
                 ? "iOS increase contrast is on, so higher contrast stays on while this switch is off."
                 : "text size follows the iOS settings, and iOS bold text adds weight on top of this.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .groupedCell()
    }

    private var displayKicker: String {
        if contrast.alwaysHigher { return "HIGHER CONTRAST \u{00B7} ALWAYS" }
        if contrast.systemIncreased { return "HIGHER CONTRAST \u{00B7} FROM IOS" }
        return "DEFAULT CONTRAST"
    }

    // MARK: about
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardKicker("ABOUT")
            Text("built for the beacon. also works on the Colonel Panic hardware.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
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
            // Any board that is not known to be a beacon, an unknown one included, as the old
            // "fw label is not beacon board" rule read. TWIN: Android DeviceScreen.kt's About card.
            if ble.connectedKind != .beacon {
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
                Text("Made by soyboi")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .groupedCell()
    }

    private func linkRow(_ title: String, _ sub: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ACABTheme.font(.body, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Text(keepingMiddleDotsAttached(sub)).font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ACABTheme.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
