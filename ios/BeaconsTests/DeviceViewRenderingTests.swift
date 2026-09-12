import SwiftUI
import UIKit
import XCTest
@testable import Beacons

@MainActor
final class DeviceViewRenderingTests: XCTestCase {
    func testKeyMismatchKeepsBoardClearActionAvailableWhenBufferingIsOff() {
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 0,
            keyMismatch: true, wiping: false))
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 3,
            keyMismatch: false, wiping: false))
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 0,
            keyMismatch: false, wiping: true))
        XCTAssertFalse(shouldOfferBufferClear(
            isDemoMode: true, bufferOn: true, bufferedCount: 3,
            keyMismatch: true, wiping: true))
    }

    func testKeyMismatchClearConfirmationNeverClaimsZeroMeansNothingIsRetained() {
        let mismatch = bufferClearConfirmationCopy(bufferedCount: 0, keyMismatch: true)
        XCTAssertTrue(mismatch.title.contains("retained offline history"))
        XCTAssertFalse(mismatch.title.contains("0 buffered"))
        XCTAssertTrue(mismatch.message.contains("only readable by the originating phone"))
        XCTAssertTrue(mismatch.message.contains("permanently lost"))

        let ordinary = bufferClearConfirmationCopy(bufferedCount: 3, keyMismatch: false)
        XCTAssertEqual(ordinary.title, "Erase 3 buffered detections on the board?")
        XCTAssertTrue(ordinary.message.contains("already synced to this phone stay"))
    }

    /// The still-silent notice answers "my beacon went quiet after Desert and nothing said why",
    /// so the case that must never regress is: Desert was seen on this run, Desert is off now, and
    /// the alert mode stayed Silent. Each other case removes exactly one conjunct, so dropping any
    /// of the four from shouldShowDesertSilenceNotice flips one of these assertions.
    func testDesertSilenceNoticeShowsOnlyAfterDesertRanAndAlertsStayedSilent() {
        XCTAssertTrue(shouldShowDesertSilenceNotice(
            sawDesertOn: true, desertOn: false, alertsSilent: true, isMeshDetect: false))
        // Desert never ran this app run: a user who chose Silent deliberately is not nagged.
        XCTAssertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn: false, desertOn: false, alertsSilent: true, isMeshDetect: false))
        // Desert is running again: the muted-while-running line above already explains the quiet.
        XCTAssertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn: true, desertOn: true, alertsSilent: true, isMeshDetect: false))
        // Sound came back, restored or hand-picked: there is nothing left to explain.
        XCTAssertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn: true, desertOn: false, alertsSilent: false, isMeshDetect: false))
        // A mesh board draws no Alerts row, so the sentence would name a control its owner
        // cannot reach.
        XCTAssertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn: true, desertOn: false, alertsSilent: true, isMeshDetect: true))
    }

    /// One cross-platform sentence, so its bytes are pinned here and against the same literal in
    /// Android's AcabAppStateTest. It also has to obey the copy rules: lowercase first, no
    /// em-dash, straight apostrophes, no exclamation.
    func testDesertSilenceNoticeCopyIsExact() {
        XCTAssertEqual(desertSilenceNotice,
                       "alerts are still silent after desert mode. they stay that way until you turn sound back on in alerts.")
        XCTAssertEqual(desertSilenceNotice.first, "a")
        for banned in ["\u{2014}", "\u{2013}", "\u{2019}", "!"] {
            XCTAssertFalse(desertSilenceNotice.contains(banned), "banned character \(banned)")
        }
    }

    /// The Desert card has ONE silence slot and the offer outranks the notice in it. They are the
    /// same message about the same silence, so drawing both would say it twice and only one of them
    /// carries a way out. Dropping the precedence fails the first assertion.
    func testDesertRestoreOfferOutranksTheStillSilentNotice() {
        XCTAssertEqual(desertSilenceSlot(restoreOffered: true, noticeApplies: true), .offer)
        XCTAssertEqual(desertSilenceSlot(restoreOffered: false, noticeApplies: true), .notice)
        XCTAssertEqual(desertSilenceSlot(restoreOffered: false, noticeApplies: false), .none)
    }

    /// The one asymmetry between the two, spelled out as the composition the Desert card performs.
    /// On a mesh board the notice is suppressed because it names an Alerts row that board does not
    /// draw - but the offer still draws, because it carries its own control, and on a mesh board it
    /// is the ONLY way back to a mode, since Alerts is unreachable there. Folding the mesh narrowing
    /// into the offer fails the last assertion.
    func testTheRestoreOfferSurvivesTheMeshNarrowingThatSuppressesTheNotice() {
        let noticeOnMesh = shouldShowDesertSilenceNotice(sawDesertOn: true, desertOn: false,
                                                         alertsSilent: true, isMeshDetect: true)
        XCTAssertFalse(noticeOnMesh, "the notice names a control a mesh board does not draw")
        XCTAssertEqual(desertSilenceSlot(restoreOffered: false, noticeApplies: noticeOnMesh), .none)
        XCTAssertEqual(desertSilenceSlot(restoreOffered: true, noticeApplies: noticeOnMesh), .offer)
    }

    /// THE BOARD BEING AWAY IS WHEN THE OFFER MATTERS MOST. Both of its in-panel homes sit inside
    /// hardwareConfigPanel, which is `.disabled` as one unit when the link or the status frame is
    /// gone (Android collapses the same rows outright), and a board reboot or a factory reset is
    /// exactly what arms the offer. So the detached surface has to appear in precisely that window.
    ///
    /// The middle assertion is also the invariant that keeps the screen from showing the offer
    /// twice: this predicate is the NEGATION of the panel's gate, so a live in-panel copy and the
    /// detached one can never both draw. Dropping the `!` flips the first two assertions together.
    func testTheRestoreOfferGetsItsOwnSurfaceExactlyWhileTheBoardIsAway() {
        XCTAssertTrue(desertRestoreNeedsDetachedSurface(restoreOffered: true,
                                                        boardControlsAvailable: false))
        XCTAssertFalse(desertRestoreNeedsDetachedSurface(restoreOffered: true,
                                                         boardControlsAvailable: true),
                       "with the board there, the Desert and Alerts cards already carry it")
        XCTAssertFalse(desertRestoreNeedsDetachedSurface(restoreOffered: false,
                                                         boardControlsAvailable: false),
                       "nothing owed, nothing to draw")
        XCTAssertFalse(desertRestoreNeedsDetachedSurface(restoreOffered: false,
                                                         boardControlsAvailable: true))
    }

    /// THE SCREEN UNDER THE BEACON SCREEN. Every other home of the offer, the detached panel
    /// included, is inside DeviceView, and RootView draws ConnectView OVER the tab shell whenever
    /// `mainIsUsable` is false: no usable session, and no reconnect or update reboot over a shell
    /// that already mounted. The shell underneath is then either not mounted yet or mounted at zero
    /// opacity with its hit testing off and its accessibility hidden, so DeviceView is not
    /// reachable. A board that ended Desert and a relaunch with that board off or gone used to show
    /// the owner nothing at all, with alerts still silent. This gate is what puts the offer on the
    /// only screen that is reachable in that state.
    ///
    /// It is the NEGATION of the condition that draws the shell, which is what keeps the offer from
    /// appearing twice: the second assertion is the pre-connect copy standing down the moment the
    /// tab shell is up to carry it. Dropping the `!` flips the first two assertions together;
    /// returning a constant flips one of them whichever constant is chosen.
    func testTheRestoreOfferGetsAPreConnectSurfaceExactlyWhileTheTabShellIsGone() {
        XCTAssertTrue(desertRestoreNeedsPreConnectSurface(restoreOffered: true,
                                                          mainShellVisible: false))
        XCTAssertFalse(desertRestoreNeedsPreConnectSurface(restoreOffered: true,
                                                           mainShellVisible: true),
                       "with the tabs up, DeviceView's own surfaces carry it")
        XCTAssertFalse(desertRestoreNeedsPreConnectSurface(restoreOffered: false,
                                                           mainShellVisible: false),
                       "nothing owed, nothing to draw")
        XCTAssertFalse(desertRestoreNeedsPreConnectSurface(restoreOffered: false,
                                                           mainShellVisible: true))
    }

    /// THE RULE, as the two panel gates together: while a mode is owed, SOME surface answers for it
    /// in every state the app can be in, and never two at once.
    ///
    /// Exactly one of three owners holds the offer in each row: the pre-connect panel when the
    /// shell is gone, the detached panel when the shell is up but the hardware panel is disabled,
    /// and the in-card copies when it is not. The board's availability is deliberately irrelevant
    /// once the shell is gone, because a board cannot be available without a session.
    ///
    /// THREE OWNERS HERE, FOUR ON ANDROID, and the extra one is not drift: `mainIsUsable` stays
    /// true through an OTA reboot (isRebootingForUpdate), so the shell keeps carrying the offer for
    /// that whole window and the detached panel is the owner. AcabApp covers its parked shell with
    /// a locked wait screen instead, so it splits the pre-connect owner in two, one on each side of
    /// that early return. Android twin:
    /// whileAModeIsOwedExactlyOneSurfaceAnswersForItInEveryState in AcabAppStateTest.kt.
    ///
    /// OWNERSHIP, NOT PIXELS: the third column means the Desert card's silence slot and the Alerts
    /// card carry it, each behind its own fold row, with the collapsed alerts kicker saying a
    /// restore is waiting. What this asserts is that no state is left with nobody holding it, and
    /// that no state hands it to two owners at once.
    ///
    /// Deleting either panel leaves a state with no surface and fails the coverage assertion;
    /// widening either gate makes two draw at once and fails the exclusivity assertion.
    func testWhileAModeIsOwedExactlyOneSurfaceAnswersForItInEveryState() {
        for shellVisible in [true, false] {
            for boardControls in [true, false] {
                let preConnect = desertRestoreNeedsPreConnectSurface(restoreOffered: true,
                                                                     mainShellVisible: shellVisible)
                let detached = shellVisible && desertRestoreNeedsDetachedSurface(
                    restoreOffered: true, boardControlsAvailable: boardControls)
                let inCards = shellVisible && boardControls
                let answering = [preConnect, detached, inCards].filter { $0 }.count
                XCTAssertEqual(answering, 1,
                               "shell \(shellVisible), board \(boardControls): exactly one surface")
            }
        }
        // And with nothing owed, neither panel draws anywhere.
        for shellVisible in [true, false] {
            XCTAssertFalse(desertRestoreNeedsPreConnectSurface(restoreOffered: false,
                                                               mainShellVisible: shellVisible))
            XCTAssertFalse(desertRestoreNeedsDetachedSurface(restoreOffered: false,
                                                             boardControlsAvailable: shellVisible))
        }
    }

    /// ONE sample-tour gate, read by DeviceView and by RootView on the way to the connect screen.
    /// It was a computed property inside DeviceView until the connect screen needed the same
    /// answer; spelling it twice is how one screen ends up offering a real restore inside a tour of
    /// canned data, whose alert mode is a preview. Dropping the `!isDemoMode` term fails the second
    /// assertion; dropping the nil check fails the third.
    func testTheSampleTourIsNeverOfferedARestore() {
        XCTAssertTrue(alertRestoreIsOffered(isDemoMode: false, pending: .buzzer))
        XCTAssertFalse(alertRestoreIsOffered(isDemoMode: true, pending: .buzzer),
                       "the tour previews settings; it must not hand back a real mode")
        XCTAssertFalse(alertRestoreIsOffered(isDemoMode: false, pending: nil))
        XCTAssertFalse(alertRestoreIsOffered(isDemoMode: true, pending: nil))
    }

    /// A RELAUNCH, as the Desert card composes it. The offer is persisted and comes back; the
    /// notice's gate is per-run and does not (see BLEManager.desertRanThisRun for why that
    /// asymmetry is deliberate). The card must still carry the way out, not a blank slot, which is
    /// only true because `.offer` never consults the notice's gate. Making the slot require
    /// `noticeApplies` fails the first assertion.
    func testAfterARelaunchTheOfferStillDrawsWithTheNoticeGateFalse() {
        let noticeAfterRelaunch = shouldShowDesertSilenceNotice(
            sawDesertOn: false, desertOn: false, alertsSilent: true, isMeshDetect: false)
        XCTAssertFalse(noticeAfterRelaunch, "no in-run evidence of a Desert run on a fresh launch")
        XCTAssertEqual(desertSilenceSlot(restoreOffered: true, noticeApplies: noticeAfterRelaunch),
                       .offer)
        XCTAssertEqual(desertSilenceSlot(restoreOffered: false, noticeApplies: noticeAfterRelaunch),
                       .none, "and once the offer is answered the card says nothing, not a notice")
    }

    /// Two more cross-platform strings, so their bytes are pinned here and against the same literals
    /// in Android's AcabAppStateTest. The offer sentence names the control that sits under it, so a
    /// reword on one side only would send one phone's owner looking for a button by another name.
    func testDesertRestoreOfferCopyIsExact() {
        XCTAssertEqual(desertRestoreOffer,
                       "desert mode ended on the beacon, so your alert mode is still silent. the app does not change it on its own. restore alerts puts back the mode you had before desert mode.")
        XCTAssertEqual(desertRestoreOfferAction, "RESTORE ALERTS")
        XCTAssertEqual(desertRestoreOffer.first, "d")
        for banned in ["\u{2014}", "\u{2013}", "\u{2019}", "!"] {
            XCTAssertFalse(desertRestoreOffer.contains(banned), "banned character \(banned)")
            XCTAssertFalse(desertRestoreOfferAction.contains(banned), "banned character \(banned)")
        }
        // It asserts the MODE, not the sound. reconcileBuzzer has a terminal state where the board
        // refuses the mute and keeps beeping while the mode reads Silent; a claim about sound would
        // be false exactly there, on the one product where that is the worst thing to get wrong.
        XCTAssertTrue(desertRestoreOffer.contains("your alert mode is still silent"))
        // And it names its own control, so the sentence and the button cannot drift apart.
        XCTAssertTrue(desertRestoreOffer.contains(desertRestoreOfferAction.lowercased()))
    }

    /// DeviceView previously crashed while Swift resolved the concrete metadata for its combined
    /// disclosure panel. Mounting the view is the regression assertion because that failure occurs
    /// before the first frame is drawn or any disclosure row is opened.
    func testDeviceViewMaterializesWithoutMetadataCrash() {
        let root = DeviceView()
            .environmentObject(BLEManager.shared)
            .environmentObject(FirmwareManifestStore.shared)

        let host = UIHostingController(rootView: root)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        XCTAssertEqual(host.view.bounds.size, CGSize(width: 390, height: 844))
    }
}
