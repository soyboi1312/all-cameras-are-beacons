import XCTest
@testable import Beacons

/// The one rule this suite exists for: ONLY THE USER CHANGES WHETHER THE DETECTOR MAKES SOUND.
///
/// WHY IT EXISTS. Until now nothing in either suite touched Desert or the alert mode, so the rule
/// was enforced by comments alone, and two defects had been living underneath them:
///
///  A. a hand-picked Silent was discarded. The saved pre-Desert mode was cleared only for a
///     NON-silent pick, so a user who chose Silent while Desert ran was indistinguishable from
///     Desert's own mute, and leaving Desert overrode them and made the board audible. Two shipped
///     FAQ sentences promise the opposite.
///  B. the app un-muted with nobody in the loop. reconcileDesert restored the prior mode whenever a
///     status frame reported Desert off, which happens after a factory reset, on an older field
///     board, and when a second paired phone ends Desert. Nothing on screen said so.
///
/// Both live in `desertAlertModeTransition`, the pure function BOTH platforms run, so these
/// assertions are the rule itself rather than a model of it. Android twin: DesertAlertModeTest.kt,
/// case for case; the manager cases at the bottom have no Android twin, because AcabBleManager
/// needs a Context that a plain JUnit test does not have.
///
/// WHAT THIS SUITE DOES NOT COVER. The SwiftUI surfaces are view-only: which control is wired to
/// takePendingAlertModeRestore, and where on the four surfaces the offer draws, are not asserted
/// anywhere, here or in any suite. `desertSilenceSlot`, `desertRestoreNeedsDetachedSurface` and
/// `desertRestoreNeedsPreConnectSurface` in DeviceViewRenderingTests pin the decisions those
/// surfaces render, not the rendering. That AlertRestorePanel is what the detached gate draws, and
/// that it sits immediately above statsGrid in the compact stack and above the two-column split in
/// the regular one, is held by the "desert restore offer" row of
/// firmware/tools/check-signature-drift.py. NOTHING holds the pre-connect call site: that
/// RootView hands ConnectView its answer, and that ConnectView draws AlertRestorePanel first, are
/// checked by eye only, because the drift script cannot read either file without both being added
/// to firmware-ci.yml's two path lists. Nothing here runs `ingestStatus`, so its CALL to
/// reconcileDesert is unpinned too.
final class DesertAlertModeTests: XCTestCase {

    private let desertCaptured = DesertAlertModeState(saved: .buzzer, offered: nil)

    // MARK: - the rule, as the pure transition both platforms run

    /// DEFECT A, the headline. Desert captured Buzzer on the way in; the user then picks Silent by
    /// hand while Desert runs. That pick has to outrank the capture, so Desert ending leaves them
    /// silent. Reverting the fix (clearing only for a non-Silent pick) leaves saved == .buzzer here,
    /// and the userEndedDesert assertion below flips to .restore.
    func testHandPickedSilentDuringDesertSurvivesDesertEnding() {
        let afterPick = desertAlertModeTransition(state: desertCaptured,
                                                  event: .userPickedMode, current: .silent)
        XCTAssertEqual(afterPick.state, .empty)

        let ended = desertAlertModeTransition(state: afterPick.state,
                                              event: .userEndedDesert, current: .silent)
        XCTAssertEqual(ended.effect, .keepMode)
        XCTAssertNil(ended.restoreTo)
    }

    /// The same pick, the other ending: the board reports Desert off by itself. Nothing is owed, so
    /// there is nothing to offer either.
    func testHandPickedSilentSurvivesABoardReportedDesertEnding() {
        let afterPick = desertAlertModeTransition(state: desertCaptured,
                                                  event: .userPickedMode, current: .silent)
        let ended = desertAlertModeTransition(state: afterPick.state,
                                              event: .boardEndedDesert, current: .silent)
        XCTAssertEqual(ended.effect, .keepMode)
        XCTAssertNil(ended.state.offered)
    }

    /// A hand-picked Buzzer during Desert survives too. This half passed before the fix (the old
    /// `m != .silent` clear covered it) and is here so a future simplification cannot trade one
    /// direction for the other.
    func testHandPickedBuzzerDuringDesertSurvivesDesertEnding() {
        let afterPick = desertAlertModeTransition(
            state: DesertAlertModeState(saved: .vibrate, offered: nil),
            event: .userPickedMode, current: .buzzer)
        XCTAssertEqual(afterPick.state, .empty)

        let ended = desertAlertModeTransition(state: afterPick.state,
                                              event: .userEndedDesert, current: .buzzer)
        XCTAssertEqual(ended.effect, .keepMode)
    }

    /// The ending that DOES restore, and the reason the saved mode exists at all: the user turned
    /// Desert off with their own tap. Deleting the `.restore` arm fails on the effect.
    func testUserEndedDesertRestoresThePriorMode() {
        let enabled = desertAlertModeTransition(state: .empty,
                                                event: .userEnabledDesert, current: .buzzer)
        XCTAssertEqual(enabled.effect, .muteToSilent)
        XCTAssertEqual(enabled.state.saved, .buzzer)

        let ended = desertAlertModeTransition(state: enabled.state,
                                              event: .userEndedDesert, current: .silent)
        XCTAssertEqual(ended.effect, .restore)
        XCTAssertEqual(ended.restoreTo, .buzzer)
        XCTAssertEqual(ended.state, .empty)
    }

    /// DEFECT B. The board says Desert is off and nobody here asked for that. The mode MUST NOT
    /// move; the saved mode becomes an offer instead. Reverting to the old behaviour makes this
    /// event return `.restore`, which the effect assertion catches, and leaves `offered` nil, which
    /// the offer assertion catches.
    func testBoardEndedDesertChangesNoModeAndArmsTheOffer() {
        let ended = desertAlertModeTransition(
            state: DesertAlertModeState(saved: .vibrate, offered: nil),
            event: .boardEndedDesert, current: .silent)
        XCTAssertEqual(ended.effect, .keepMode)
        XCTAssertNil(ended.restoreTo)
        XCTAssertEqual(ended.state.offered, .vibrate)
        // The value MOVES rather than being copied, so exactly one holder has it.
        XCTAssertNil(ended.state.saved)
    }

    /// Taking the offer is a user pick, which both restores (the manager passes `offered` as the
    /// mode) and clears the state. Both halves are covered: the clearing here, the restoring in
    /// testTakingTheOfferRestoresTheModeAndClearsTheOffer below.
    func testTakingTheOfferClearsIt() {
        let offered = DesertAlertModeState(saved: nil, offered: .buzzer)
        let taken = desertAlertModeTransition(state: offered,
                                              event: .userPickedMode, current: .buzzer)
        XCTAssertEqual(taken.state, .empty)
    }

    /// Declining it by picking something else by hand clears it too, Silent included.
    func testPickingAnyModeByHandClearsThePendingOffer() {
        let offered = DesertAlertModeState(saved: nil, offered: .buzzer)
        for picked in AlertMode.allCases {
            let after = desertAlertModeTransition(state: offered,
                                                  event: .userPickedMode, current: picked)
            XCTAssertEqual(after.state, .empty,
                           "picking \(picked.rawValue) by hand must close the offer")
        }
    }

    /// Desert coming back on answers the offer: the board is muted again either way. The saved mode
    /// is deliberately NOT touched, because this run's own Desert-off still owes it back.
    func testDesertComingBackOnClearsTheOfferAndKeepsTheSavedMode() {
        let mixed = DesertAlertModeState(saved: .buzzer, offered: .vibrate)
        let after = desertAlertModeTransition(state: mixed,
                                              event: .boardReportsDesertOn, current: .silent)
        XCTAssertNil(after.state.offered)
        XCTAssertEqual(after.state.saved, .buzzer)
        XCTAssertEqual(after.effect, .keepMode)
    }

    /// An app-set mode is the one call that changes nothing: Desert's own mute and the restore it
    /// carries out both land here, and neither may look like a user pick.
    func testAnAppSetModeLeavesTheSavedModeAndTheOfferAlone() {
        let mixed = DesertAlertModeState(saved: .buzzer, offered: .vibrate)
        let after = desertAlertModeTransition(state: mixed,
                                              event: .appSetMode, current: .silent)
        XCTAssertEqual(after.state, mixed)
        XCTAssertEqual(after.effect, .keepMode)
    }

    /// Turning Desert on while already Silent captures nothing, so a later ending cannot un-mute
    /// someone who chose quiet, and no arbitrarily old mode is left lying in UserDefaults.
    func testEnablingDesertWhileAlreadySilentSavesNothingToGiveBack() {
        let enabled = desertAlertModeTransition(
            state: DesertAlertModeState(saved: .buzzer, offered: nil),
            event: .userEnabledDesert, current: .silent)
        XCTAssertEqual(enabled.effect, .keepMode)
        XCTAssertEqual(enabled.state, .empty)
    }

    /// The journey the still-silent notice was built for: this phone never enabled Desert itself
    /// (first pair with a board already in Desert, or a second paired phone), so it holds nothing.
    /// Desert ending leaves it with no offer, which is what routes that user to the notice instead.
    func testAPhoneThatNeverEnabledDesertHasNothingToOffer() {
        let ended = desertAlertModeTransition(state: .empty,
                                              event: .boardEndedDesert, current: .silent)
        XCTAssertEqual(ended.effect, .keepMode)
        XCTAssertEqual(ended.state, .empty)
    }

    // MARK: - the same rule through the real manager
    //
    // These drive BLEManager itself over a throwaway UserDefaults suite, so they cover the CALLS
    // the pure cases above cannot see: that the Alerts picker's origin reaches the transition, and
    // that setDesertMode performs the effect it is handed. Vibrate is kept out of them on purpose -
    // setAlertMode(.vibrate) asks for Focus authorization, which is not a unit test's business.

    private var isolatedSuites: [(name: String, defaults: UserDefaults)] = []

    override func tearDown() {
        for suite in isolatedSuites { suite.defaults.removePersistentDomain(forName: suite.name) }
        isolatedSuites.removeAll()
        super.tearDown()
    }

    private func makeManager() throws -> BLEManager {
        let name = "tech.beacons.tests.desertalertmode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        isolatedSuites.append((name, defaults))
        return BLEManager(defaults: defaults)
    }

    /// A RELAUNCH, as faithfully as a unit test can stage one: a second manager over the SAME
    /// preference suite, with nothing carried across but what was written to disk. Every in-memory
    /// field of the first manager (the @Published offer, desertSeenOn, desertRanThisRun) is gone,
    /// which is exactly what a force-quit does and exactly what the durability fix has to survive.
    private func relaunch(_ ble: BLEManager) throws -> BLEManager {
        let suite = try XCTUnwrap(isolatedSuites.last)
        _ = ble   // named so each call site reads as "this manager's process ended"
        return BLEManager(defaults: suite.defaults)
    }

    /// A real decoded status frame, the same construction path the BLE link uses. Wire JSON rather
    /// than an initializer because DeviceStatus is decode-only, which also makes these fixtures
    /// shareable with the Android suite.
    private func status(desert: Bool) throws -> DeviceStatus {
        let json = #"{"fw":"beacon board 2.0.8","desert":"# + (desert ? "true}" : "false}")
        return try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }

    /// Arm the offer the way the board does: Desert confirmed on, then a frame saying it stopped
    /// without this phone asking. No test-only hook - this is reconcileDesert itself.
    private func boardRunsAndEndsDesert(_ ble: BLEManager) throws {
        ble.reconcileDesert(try status(desert: true))
        ble.reconcileDesert(try status(desert: false))
    }

    /// DEFECT A end to end. Buzzer, Desert on (forced to Silent), the user picks Silent BY HAND,
    /// Desert off. Before the fix the hand-picked Silent left the token in place and this ended on
    /// .buzzer - an audible board for someone who had just asked for silence.
    func testHandPickedSilentIsNotOverriddenWhenTheUserEndsDesert() throws {
        let ble = try makeManager()
        ble.setAlertMode(.buzzer, origin: .user)
        ble.setDesertMode(true)
        XCTAssertEqual(ble.alertMode, .silent, "Desert mutes on the way in")

        ble.setAlertMode(.silent, origin: .user)   // the same mode, but chosen
        ble.setDesertMode(false)

        XCTAssertEqual(ble.alertMode, .silent,
                       "a Silent the user picked by hand must survive Desert ending")
    }

    /// The restore that must keep working: nothing was hand-picked, so the user's own Desert-off
    /// puts Buzzer back. This is the assertion that fails if the fix over-corrects into never
    /// restoring at all.
    func testUserEndedDesertStillRestoresTheModeItMuted() throws {
        let ble = try makeManager()
        ble.setAlertMode(.buzzer, origin: .user)
        ble.setDesertMode(true)
        XCTAssertEqual(ble.alertMode, .silent)

        ble.setDesertMode(false)

        XCTAssertEqual(ble.alertMode, .buzzer, "the user ended Desert, so their mode comes back")
    }

    /// Taking the offer restores the mode and clears the offer, and it is a user pick, so nothing
    /// stays saved behind it. The offer is armed here through the manager's own Desert path rather
    /// than by reaching into its state.
    func testTakingTheOfferRestoresTheModeAndClearsTheOffer() throws {
        let ble = try makeManager()
        ble.setAlertMode(.buzzer, origin: .user)
        ble.setDesertMode(true)
        try boardRunsAndEndsDesert(ble)
        XCTAssertEqual(ble.pendingAlertModeRestore, .buzzer,
                       "a board-reported Desert-off offers the mode back")
        XCTAssertEqual(ble.alertMode, .silent, "and changes no mode by itself")

        ble.takePendingAlertModeRestore()

        XCTAssertEqual(ble.alertMode, .buzzer)
        XCTAssertNil(ble.pendingAlertModeRestore)
    }

    /// Picking a mode by hand closes the offer without it being taken.
    func testPickingAModeByHandClearsTheOfferOnTheManager() throws {
        let ble = try makeManager()
        ble.setAlertMode(.buzzer, origin: .user)
        ble.setDesertMode(true)
        try boardRunsAndEndsDesert(ble)
        XCTAssertNotNil(ble.pendingAlertModeRestore)

        ble.setAlertMode(.silent, origin: .user)

        XCTAssertNil(ble.pendingAlertModeRestore)
        XCTAssertEqual(ble.alertMode, .silent)
    }

    // MARK: - the offer outliving the process that armed it
    //
    // THE DEFECT THESE EXIST FOR. Both of the offer's surfaces, and the notice's gate, were
    // per-run and in memory, and arming the offer CONSUMES the persisted pre-Desert mode. So: the
    // board ends Desert, the offer arms, the user force-quits, and on relaunch there was no offer,
    // no notice, and no saved mode either - alerts silent, nothing on screen saying why, and no way
    // back except knowing which mode to re-pick. A silence this app imposed with no way out of it.
    //
    // `relaunch` is the whole fixture: a second manager over the same suite, carrying only what
    // reached disk. Reverting the persistence leaves `pendingAlertModeRestore` nil after every one
    // of these, which is the first assertion in each.

    /// The round trip as the PURE pair both platforms run, with no store in the picture: what the
    /// store would hold after the offer arms, read back as the state a launch republishes. This is
    /// the Android suite's only way in (AcabBleManager needs a Context), so it is pinned here too,
    /// case for case, rather than left to the manager cases below.
    func testTheStorageRoundTripCarriesAnArmedOfferAndNothingElse() {
        let armed = desertAlertModeTransition(
            state: DesertAlertModeState(saved: .buzzer, offered: nil),
            event: .boardEndedDesert, current: .silent).state
        let stored = desertAlertModeStorage(armed)
        XCTAssertNil(stored.saved, "arming MOVES the mode, so the saved half is written away")
        XCTAssertEqual(stored.offered, AlertMode.buzzer.rawValue)

        let republished = desertAlertModeStateFromStorage(stored)
        XCTAssertEqual(republished, armed, "a launch must see exactly what the last run left")

        // Answered, from either side: nothing may be left for the launch after that.
        let taken = desertAlertModeTransition(state: republished,
                                              event: .userPickedMode, current: .buzzer).state
        XCTAssertEqual(desertAlertModeStorage(taken), .empty)
        let desertBack = desertAlertModeTransition(state: republished,
                                                   event: .boardReportsDesertOn, current: .silent).state
        XCTAssertEqual(desertAlertModeStorage(desertBack), .empty)
    }

    /// A string no mode answers to - a downgrade, a hand-edited store - reads as nothing held,
    /// never as a crash and never as a mode picked by accident.
    func testUnreadableStoredHalvesReadAsNothingHeld() {
        let state = desertAlertModeStateFromStorage(
            DesertAlertModeStorage(saved: "loud", offered: ""))
        XCTAssertEqual(state, .empty)
        XCTAssertEqual(desertAlertModeStateFromStorage(.empty), .empty)
    }

    /// THE HEADLINE. Arm the offer, end the process, come back: the offer is still there and the
    /// Desert card still draws it. The slot is computed through the real two functions with the
    /// real post-relaunch inputs, which also pins the deliberate asymmetry - `desertRanThisRun` is
    /// per-run and comes back false, and the offer outranks the notice anyway, so the card is not
    /// left blank by the flag that did not survive.
    func testAnArmedOfferSurvivesARelaunchAndTheDesertCardStillDrawsIt() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)
        XCTAssertEqual(first.pendingAlertModeRestore, .buzzer)

        let ble = try relaunch(first)

        XCTAssertEqual(ble.pendingAlertModeRestore, .buzzer,
                       "the offer must outlive the run that armed it")
        XCTAssertEqual(ble.alertMode, .silent, "and the silence it explains is still in force")
        XCTAssertFalse(ble.desertRanThisRun, "the notice's gate is per-run, deliberately")
        let noticeApplies = shouldShowDesertSilenceNotice(
            sawDesertOn: ble.desertRanThisRun, desertOn: false,
            alertsSilent: ble.alertMode == .silent, isMeshDetect: false)
        XCTAssertEqual(desertSilenceSlot(restoreOffered: ble.pendingAlertModeRestore != nil,
                                         noticeApplies: noticeApplies), .offer,
                       "the card must carry the way out, not a blank slot")
    }

    /// Taking it after that relaunch has to give back the mode this phone actually muted, not the
    /// default and not whatever the picker happens to show.
    func testTakingTheOfferAfterARelaunchRestoresTheRightMode() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)

        let ble = try relaunch(first)
        ble.takePendingAlertModeRestore()

        XCTAssertEqual(ble.alertMode, .buzzer)
        XCTAssertNil(ble.pendingAlertModeRestore, "taking it closes it")
        XCTAssertNil(try relaunch(ble).pendingAlertModeRestore,
                     "and it stays closed through the NEXT launch, so a taken offer cannot return")
    }

    /// Declining it by hand across a relaunch. The stored copy has to go with the in-memory one,
    /// or the offer comes back on the launch after that and re-opens a question the user answered.
    func testPickingAModeByHandAcrossARelaunchClearsThePersistedOffer() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)

        let ble = try relaunch(first)
        XCTAssertNotNil(ble.pendingAlertModeRestore)
        ble.setAlertMode(.silent, origin: .user)   // the same mode, but chosen

        XCTAssertNil(ble.pendingAlertModeRestore)
        XCTAssertNil(try relaunch(ble).pendingAlertModeRestore,
                     "a hand-picked mode must close the offer on disk, not just on screen")
    }

    /// Desert coming back on answers the offer, and that answer has to reach the store too: the
    /// board is muted again, so a control promising the mode back would be undone by the next line
    /// of the same card.
    func testDesertReturningClearsAPersistedOffer() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)

        let ble = try relaunch(first)
        XCTAssertNotNil(ble.pendingAlertModeRestore)
        ble.reconcileDesert(try status(desert: true))

        XCTAssertNil(ble.pendingAlertModeRestore)
        XCTAssertNil(try relaunch(ble).pendingAlertModeRestore)
    }

    /// THE MOMENT THE OFFER IS FOR. A board reboot or a factory reset is what arms it, so the link
    /// is usually down when the user sees it. Nothing about taking it may need the board: this
    /// manager never connected to one, and the offer is still there and still takes.
    func testTheOfferIsArmedAndTakeableWithNoBoardConnected() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)

        let ble = try relaunch(first)
        XCTAssertNotEqual(ble.connectionState, .connected, "no link in this process at all")
        XCTAssertEqual(ble.pendingAlertModeRestore, .buzzer,
                       "the offer does not wait for a board to come back")

        ble.takePendingAlertModeRestore()

        XCTAssertEqual(ble.alertMode, .buzzer, "and taking it is a phone-side preference write")
    }

    /// THE HOLE THE PRE-CONNECT SURFACE CLOSES, end to end against a real manager. The case above
    /// proves the offer is takeable with no board; this one proves a screen would have drawn it.
    /// Every other home of the offer lives inside DeviceView, and RootView mounts the tab shell
    /// only for a usable session or a reconnect over a shell that already mounted - neither of
    /// which this manager has - so before this gate existed the owner of a board that ended Desert
    /// relaunched into a connect screen with alerts silent, nothing saying why, and no way back.
    ///
    /// The decision is computed from the manager's own republished state through the same two
    /// functions RootView calls, so this is the wiring and not a model of it. Deleting the surface
    /// deletes desertRestoreNeedsPreConnectSurface and this stops compiling; inverting its gate
    /// fails the first assertion; a demo-gate that stopped excluding the tour fails the third.
    func testWithNoBoardTheConnectScreenCarriesTheOfferAndTakingItThereWorks() throws {
        let first = try makeManager()
        first.setAlertMode(.buzzer, origin: .user)
        first.setDesertMode(true)
        try boardRunsAndEndsDesert(first)

        let ble = try relaunch(first)
        XCTAssertNotEqual(ble.connectionState, .connected, "no link in this process at all")
        // mainShellVisible is RootView's mainIsUsable, and with no session and nothing mounted it
        // is false, which is exactly why ConnectView is the screen on the phone.
        XCTAssertTrue(desertRestoreNeedsPreConnectSurface(
            restoreOffered: alertRestoreIsOffered(isDemoMode: ble.demoMode,
                                                  pending: ble.pendingAlertModeRestore),
            mainShellVisible: false),
                      "the connect screen must carry the offer when it is the only screen there is")
        XCTAssertFalse(desertRestoreNeedsPreConnectSurface(
            restoreOffered: alertRestoreIsOffered(isDemoMode: ble.demoMode,
                                                  pending: ble.pendingAlertModeRestore),
            mainShellVisible: true),
                       "and stand down the moment the tab shell is up to carry it")
        XCTAssertFalse(alertRestoreIsOffered(isDemoMode: true,
                                             pending: ble.pendingAlertModeRestore),
                       "and never offer a real mode back inside the sample tour")

        ble.takePendingAlertModeRestore()

        XCTAssertEqual(ble.alertMode, .buzzer, "taking it from that screen needs no board")
        XCTAssertNil(ble.pendingAlertModeRestore)
        XCTAssertFalse(desertRestoreNeedsPreConnectSurface(
            restoreOffered: alertRestoreIsOffered(isDemoMode: ble.demoMode,
                                                  pending: ble.pendingAlertModeRestore),
            mainShellVisible: false),
                       "and the connect screen stops carrying it once it is answered")
    }
}
