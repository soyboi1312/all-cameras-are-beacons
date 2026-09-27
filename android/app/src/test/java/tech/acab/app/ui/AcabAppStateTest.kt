package tech.acab.app.ui

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.AlertMode
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.ConnState
import tech.acab.app.beaconSegmentExtra
import tech.acab.app.model.DeviceStatus

class AcabAppStateTest {
    @Test
    fun keyMismatchKeepsBoardClearActionAvailableWhenBufferingIsOff() {
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 0,
            keyMismatch = true, wiping = false,
        ))
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 3,
            keyMismatch = false, wiping = false,
        ))
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 0,
            keyMismatch = false, wiping = true,
        ))
        assertFalse(shouldOfferBufferClear(
            isDemoMode = true, bufferOn = true, bufferedCount = 3,
            keyMismatch = true, wiping = true,
        ))
    }

    @Test
    fun keyMismatchClearConfirmationNeverClaimsZeroMeansNothingIsRetained() {
        val mismatch = bufferClearConfirmationCopy(bufferedCount = 0, keyMismatch = true)
        assertTrue(mismatch.title.contains("retained offline history"))
        assertFalse(mismatch.title.contains("0 buffered"))
        assertTrue(mismatch.message.contains("only readable by the originating phone"))
        assertTrue(mismatch.message.contains("permanently lost"))

        val ordinary = bufferClearConfirmationCopy(bufferedCount = 3, keyMismatch = false)
        assertEquals("Erase 3 buffered detections on the board?", ordinary.title)
        assertTrue(ordinary.message.contains("already synced to this phone stay"))
    }

    /** The still-silent notice answers "my beacon went quiet after Desert and nothing said why",
     *  so the case that must never regress is: Desert was seen on this run, Desert is off now, and
     *  the alert mode stayed SILENT. Each other case removes exactly one conjunct, so dropping any
     *  of the four from shouldShowDesertSilenceNotice flips one of these assertions. */
    @Test
    fun desertSilenceNoticeShowsOnlyAfterDesertRanAndAlertsStayedSilent() {
        assertTrue(shouldShowDesertSilenceNotice(
            sawDesertOn = true, desertOn = false, alertsSilent = true, isMeshDetect = false,
        ))
        // Desert never ran this app run: a user who chose SILENT deliberately is not nagged.
        assertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn = false, desertOn = false, alertsSilent = true, isMeshDetect = false,
        ))
        // Desert is running again: the muted-while-running line above already explains the quiet.
        assertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn = true, desertOn = true, alertsSilent = true, isMeshDetect = false,
        ))
        // Sound came back, restored or hand-picked: there is nothing left to explain.
        assertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn = true, desertOn = false, alertsSilent = false, isMeshDetect = false,
        ))
        // A mesh board draws no Alerts row, so the sentence would name a control its owner
        // cannot reach.
        assertFalse(shouldShowDesertSilenceNotice(
            sawDesertOn = true, desertOn = false, alertsSilent = true, isMeshDetect = true,
        ))
    }

    /** One cross-platform sentence, so its bytes are pinned here and against the same literal in
     *  iOS's DeviceViewRenderingTests. It also has to obey the copy rules: lowercase first, no
     *  em-dash, straight apostrophes, no exclamation. */
    @Test
    fun desertSilenceNoticeCopyIsExact() {
        assertEquals(
            "alerts are still silent after desert mode. they stay that way until you turn sound back on in alerts.",
            DESERT_SILENCE_NOTICE,
        )
        assertEquals('a', DESERT_SILENCE_NOTICE.first())
        for (banned in listOf('\u2014', '\u2013', '\u2019', '!')) {
            assertFalse("banned character $banned", DESERT_SILENCE_NOTICE.contains(banned))
        }
    }

    /** The Desert card has ONE silence slot and the offer outranks the notice in it. They are the
     *  same message about the same silence, so drawing both would say it twice and only one of them
     *  carries a way out. Dropping the precedence fails the first assertion. */
    @Test
    fun desertRestoreOfferOutranksTheStillSilentNotice() {
        assertEquals(DesertSilenceSlot.OFFER,
            desertSilenceSlot(restoreOffered = true, noticeApplies = true))
        assertEquals(DesertSilenceSlot.NOTICE,
            desertSilenceSlot(restoreOffered = false, noticeApplies = true))
        assertEquals(DesertSilenceSlot.NONE,
            desertSilenceSlot(restoreOffered = false, noticeApplies = false))
    }

    /** The one asymmetry between the two, spelled out as the composition the Desert card performs.
     *  On a mesh board the notice is suppressed because it names an Alerts row that board does not
     *  draw - but the offer still draws, because it carries its own control, and on a mesh board it
     *  is the ONLY way back to a mode, since Alerts is unreachable there. Folding the mesh narrowing
     *  into the offer fails the last assertion. */
    @Test
    fun theRestoreOfferSurvivesTheMeshNarrowingThatSuppressesTheNotice() {
        val noticeOnMesh = shouldShowDesertSilenceNotice(
            sawDesertOn = true, desertOn = false, alertsSilent = true, isMeshDetect = true,
        )
        assertFalse("the notice names a control a mesh board does not draw", noticeOnMesh)
        assertEquals(DesertSilenceSlot.NONE,
            desertSilenceSlot(restoreOffered = false, noticeApplies = noticeOnMesh))
        assertEquals(DesertSilenceSlot.OFFER,
            desertSilenceSlot(restoreOffered = true, noticeApplies = noticeOnMesh))
    }

    /** THE BOARD BEING AWAY IS WHEN THE OFFER MATTERS MOST. Both of its in-page homes are the
     *  Desert and Alerts pages, which beaconPageToDraw withholds while boardControlsAvailable is
     *  false, so the offer stops drawing entirely (iOS disables its board controls), and a board
     *  reboot or a factory reset is exactly what arms the offer. So the detached surface has to
     *  appear in precisely that window.
     *
     *  The middle assertion is also the invariant that keeps the screen from showing the offer
     *  twice: this predicate is the NEGATION of the pages' gate, so a live in-page copy and the
     *  detached one can never both draw. Dropping the `!` flips the first two assertions together.
     *  iOS twin: testTheRestoreOfferGetsItsOwnSurfaceExactlyWhileTheBoardIsAway. */
    @Test
    fun theRestoreOfferGetsItsOwnSurfaceExactlyWhileTheBoardIsAway() {
        assertTrue(desertRestoreNeedsDetachedSurface(
            restoreOffered = true, boardControlsAvailable = false))
        assertFalse("with the board there, the Desert and Alerts cards already carry it",
            desertRestoreNeedsDetachedSurface(restoreOffered = true, boardControlsAvailable = true))
        assertFalse("nothing owed, nothing to draw",
            desertRestoreNeedsDetachedSurface(restoreOffered = false, boardControlsAvailable = false))
        assertFalse(desertRestoreNeedsDetachedSurface(
            restoreOffered = false, boardControlsAvailable = true))
    }

    /** THE SCREENS UNDER THE BEACON TAB. Every other home of the offer, the detached slot included,
     *  is inside DeviceScreen, and AcabApp draws a full-screen surface of its own (the connect
     *  screen, or the locked wait screen while an update runs) whenever the link is not READY and
     *  no reconnect is running over an established shell - in that state MainScreen is either never
     *  composed or parked pointer-disabled with its semantics cleared. So a board that ended
     *  Desert and a relaunch with that board off or gone used to show the owner nothing at all,
     *  with alerts still silent. This gate is what puts the offer on whichever of those two screens
     *  is up, which is the only thing reachable in that state.
     *
     *  It is the NEGATION of the condition that hands off to the tab shell, which is what keeps the
     *  offer from appearing twice: the second assertion is the pre-connect copy standing down the
     *  moment the shell is up to carry it. Dropping the `!` flips the first two assertions
     *  together; returning a constant flips one of them whichever constant is chosen.
     *  iOS twin: testTheRestoreOfferGetsAPreConnectSurfaceExactlyWhileTheTabShellIsGone. */
    @Test
    fun theRestoreOfferGetsAPreConnectSurfaceExactlyWhileTheTabShellIsGone() {
        assertTrue(desertRestoreNeedsPreConnectSurface(
            restoreOffered = true, mainShellVisible = false))
        assertFalse("with the tabs up, DeviceScreen's own surfaces carry it",
            desertRestoreNeedsPreConnectSurface(restoreOffered = true, mainShellVisible = true))
        assertFalse("nothing owed, nothing to draw",
            desertRestoreNeedsPreConnectSurface(restoreOffered = false, mainShellVisible = false))
        assertFalse(desertRestoreNeedsPreConnectSurface(
            restoreOffered = false, mainShellVisible = true))
    }

    /** The Improve detection route (the THIS PHONE row, the Help support row and the dossier's
     *  related help) needs a READY link to a real beacon: the sample tour has no board to
     *  contribute from. Wrong input: `state != ConnState.DISCONNECTED` lets CONNECTING through
     *  and fails the last assertion. iOS twin: OnboardingPolicyTests
     *  testImproveDetectionRequiresAReadyRealBeacon. */
    @Test
    fun improveDetectionRequiresAReadyRealBeacon() {
        assertTrue(improveDetectionAvailable(ConnState.READY, demoMode = false))
        assertFalse("the sample tour has no board to contribute from",
            improveDetectionAvailable(ConnState.READY, demoMode = true))
        assertFalse("no link yet", improveDetectionAvailable(ConnState.CONNECTING, demoMode = false))
    }

    /** The store-screenshot intent extra opens THIS PHONE only on the exact word "phone"; any other
     *  value, and no extra at all, opens BOARD, the session default. Wrong input: a PHONE default
     *  fails the last two assertions. iOS twin: BeaconPresentationTests
     *  testBeaconLaunchSegmentParsesPhoneAndDefaultsToBoard. */
    @Test
    fun beaconSegmentExtraDefaultsToBoard() {
        assertEquals(BeaconSegment.PHONE, beaconSegmentExtra("phone"))
        assertEquals(BeaconSegment.BOARD, beaconSegmentExtra("garbage"))
        assertEquals(BeaconSegment.BOARD, beaconSegmentExtra(null))
    }

    /** THE RULE, as the two panel gates together: while a mode is owed, SOME surface answers for it
     *  in every state the app can be in, and never two at once.
     *
     *  Exactly one of four owners holds the offer in each row: the OTA wait screen while an update
     *  holds the link down, the pre-connect slot when the shell is gone for any other reason, the
     *  detached slot when the shell is up but the board pages are withheld, and the in-card
     *  copies when it is not. The board's availability is deliberately irrelevant once the shell is
     *  gone, because a board cannot be available without a link.
     *
     *  THE LAST TWO ARE ONE GATE READ ON OPPOSITE SIDES OF ONE EARLY RETURN, which is how they stay
     *  exclusive: AcabApp returns on READY, then on otaActive, then on the reconnect shell, and
     *  only then draws the pre-connect list. The state cube below walks that order with the real
     *  helpers, so widening either gate makes two owners draw at once.
     *
     *  OWNERSHIP, NOT PIXELS: the last column means the Desert card's silence slot and the Alerts
     *  card carry it, each on its own pushed page, with the Alerts row value saying a
     *  restore is waiting. What this asserts is that no state is left with nobody holding it, and
     *  that no state hands it to two owners at once. It CANNOT see a deleted render site - the
     *  gates keep answering either way; check-signature-drift.py's "Android pre-connect decision"
     *  side is what pins the two call sites in AcabApp.
     *  iOS twin: testWhileAModeIsOwedExactlyOneSurfaceAnswersForItInEveryState, with three owners
     *  rather than four: RootView keeps its shell visible through an OTA reboot, so iOS has no wait
     *  screen of its own and the detached copy covers that window there. */
    @Test
    fun whileAModeIsOwedExactlyOneSurfaceAnswersForItInEveryState() {
        val states = listOf(ConnState.READY, ConnState.CONNECTING, ConnState.BONDING,
            ConnState.SCANNING, ConnState.DISCONNECTED, ConnState.POWERED_OFF)
        for (state in states) {
            for (shellEstablished in listOf(true, false)) {
                for (hadLink in listOf(true, false)) {
                    for (otaActive in listOf(true, false)) {
                        for (boardControls in listOf(true, false)) {
                            val shellVisible = state == ConnState.READY || shouldUseReconnectShell(
                                shellEstablished, hadLink, state, otaActive)
                            val preConnect = desertRestoreNeedsPreConnectSurface(
                                restoreOffered = true, mainShellVisible = shellVisible)
                            // The OTA return sits above the pre-connect list, so it takes the flag
                            // first; the list gets every other state that reaches it.
                            val waitScreen = preConnect && otaActive
                            val connectList = preConnect && !otaActive
                            val detached = shellVisible && desertRestoreNeedsDetachedSurface(
                                restoreOffered = true, boardControlsAvailable = boardControls)
                            val inCards = shellVisible && boardControls
                            assertEquals(
                                "$state shell $shellVisible ota $otaActive board $boardControls",
                                1,
                                listOf(waitScreen, connectList, detached, inCards).count { it },
                            )
                        }
                    }
                }
            }
        }
        // And with nothing owed, neither panel draws anywhere.
        for (shellVisible in listOf(true, false)) {
            assertFalse(desertRestoreNeedsPreConnectSurface(
                restoreOffered = false, mainShellVisible = shellVisible))
            assertFalse(desertRestoreNeedsDetachedSurface(
                restoreOffered = false, boardControlsAvailable = shellVisible))
        }
    }

    /** THE OTA REBOOT WINDOW, which was the one state left with the offer owed and nothing drawing
     *  it. The update drops the link, so no card on the Beacon tab is reachable; AcabApp covers the
     *  parked shell with OtaWaitScreen and returns ABOVE the pre-connect list; and
     *  shouldUseReconnectShell stands the reconnect shell down for exactly this window, so the
     *  pre-connect gate is TRUE here with no other surface able to answer. The screen's own copy
     *  puts that window at up to a minute. A combined update reaches it in the S3 leg only: the nRF
     *  leg runs first and leaves the S3 engine idle, so otaActive is false for that one.
     *
     *  This is the composition, not the two halves: dropping `!otaActive` from shouldUseReconnectShell
     *  fails the first assertion, and folding otaActive into AcabApp's mainShellVisible fails the
     *  second. Neither can see a deleted render site; the drift side pins those.
     *  iOS has no twin for this: RootView's mainIsUsable takes isRebootingForUpdate, so its shell
     *  stays visible through the reboot and the Beacon screen's detached copy covers the window. */
    @Test
    fun theOtaRebootWindowOwesTheOfferASurfaceThatOnlyTheWaitScreenCanDraw() {
        val state = ConnState.CONNECTING   // the post-reboot reconnect, link down, update in flight
        val reconnectUsable = shouldUseReconnectShell(
            shellEstablished = true, hadLink = true, state = state, otaActive = true)
        assertFalse("an update in flight withholds the usable reconnect shell", reconnectUsable)
        assertTrue("so the offer is owed a surface the wait screen has to draw",
            desertRestoreNeedsPreConnectSurface(
                restoreOffered = true,
                mainShellVisible = state == ConnState.READY || reconnectUsable))
        // The same reconnect once the update is done: the shell is usable again and carries it.
        val afterUpdate = shouldUseReconnectShell(
            shellEstablished = true, hadLink = true, state = state, otaActive = false)
        assertTrue(afterUpdate)
        assertFalse("with the shell back, the Beacon tab's own surfaces answer",
            desertRestoreNeedsPreConnectSurface(
                restoreOffered = true,
                mainShellVisible = state == ConnState.READY || afterUpdate))
        // And an update running while the link is still up never reaches the wait screen at all:
        // READY hands off to the shell first, so the in-card copies are the reachable ones.
        val live: ConnState = ConnState.READY
        assertFalse("the transfer runs on a live link, where the tabs are up",
            desertRestoreNeedsPreConnectSurface(
                restoreOffered = true,
                mainShellVisible = live == ConnState.READY || shouldUseReconnectShell(
                    shellEstablished = true, hadLink = true, state = live, otaActive = true)))
    }

    /** ONE sample-tour gate, read by DeviceScreen and by AcabApp on the way to the connect screen.
     *  It was an inline expression inside DeviceScreen until the connect screen needed the same
     *  answer; spelling it twice is how one screen ends up offering a real restore inside a tour of
     *  canned data, whose alert mode is a preview. Dropping the `!demoMode` term fails the second
     *  assertion; dropping the null check fails the third.
     *  iOS twin: testTheSampleTourIsNeverOfferedARestore. */
    @Test
    fun theSampleTourIsNeverOfferedARestore() {
        assertTrue(alertRestoreIsOffered(demoMode = false, pending = AlertMode.BUZZER))
        assertFalse("the tour previews settings; it must not hand back a real mode",
            alertRestoreIsOffered(demoMode = true, pending = AlertMode.BUZZER))
        assertFalse(alertRestoreIsOffered(demoMode = false, pending = null))
        assertFalse(alertRestoreIsOffered(demoMode = true, pending = null))
    }

    /** A RELAUNCH, as the Desert card composes it. The offer is persisted and comes back; the
     *  notice's gate is per-run and does not (see AcabBleManager.desertRanThisRun for why that
     *  asymmetry is deliberate). The card must still carry the way out, not a blank slot, which is
     *  only true because OFFER never consults the notice's gate. Making the slot require
     *  `noticeApplies` fails the second assertion.
     *  iOS twin: testAfterARelaunchTheOfferStillDrawsWithTheNoticeGateFalse. */
    @Test
    fun afterARelaunchTheOfferStillDrawsWithTheNoticeGateFalse() {
        val noticeAfterRelaunch = shouldShowDesertSilenceNotice(
            sawDesertOn = false, desertOn = false, alertsSilent = true, isMeshDetect = false,
        )
        assertFalse("no in-run evidence of a Desert run on a fresh launch", noticeAfterRelaunch)
        assertEquals(DesertSilenceSlot.OFFER,
            desertSilenceSlot(restoreOffered = true, noticeApplies = noticeAfterRelaunch))
        assertEquals("and once the offer is answered the card says nothing, not a notice",
            DesertSilenceSlot.NONE,
            desertSilenceSlot(restoreOffered = false, noticeApplies = noticeAfterRelaunch))
    }

    /** Two more cross-platform strings, so their bytes are pinned here and against the same literals
     *  in iOS's DeviceViewRenderingTests. The offer sentence names the control that sits under it, so
     *  a reword on one side only would send one phone's owner looking for a button by another name. */
    @Test
    fun desertRestoreOfferCopyIsExact() {
        // The sentence is a template that names the board ({noun}, decisions R14); null reads as
        // beacon. TWIN: iOS DeviceViewRenderingTests.testDesertRestoreOfferCopyIsExact.
        assertEquals(
            "desert mode ended on the {noun}, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            DESERT_RESTORE_OFFER_TEMPLATE,
        )
        assertEquals(
            "desert mode ended on the beacon, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            desertRestoreOffer(null),
        )
        assertEquals(
            "desert mode ended on the OUI-Spy, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            desertRestoreOffer(BoardKind.OUI_SPY),
        )
        assertEquals(
            "desert mode ended on the Mesh-Detect, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            desertRestoreOffer(BoardKind.MESH_DETECT),
        )
        assertEquals("Restore Alerts", DESERT_RESTORE_OFFER_ACTION)
        assertEquals('d', DESERT_RESTORE_OFFER_TEMPLATE.first())
        for (banned in listOf('\u2014', '\u2013', '\u2019', '!')) {
            assertFalse("banned character $banned", DESERT_RESTORE_OFFER_TEMPLATE.contains(banned))
            assertFalse("banned character $banned", DESERT_RESTORE_OFFER_ACTION.contains(banned))
        }
        // It asserts the MODE, not the sound. reconcileBuzzer has a terminal state where the board
        // refuses the mute and keeps beeping while the mode reads SILENT; a claim about sound would
        // be false exactly there, on the one product where that is the worst thing to get wrong.
        assertTrue(DESERT_RESTORE_OFFER_TEMPLATE.contains("your alert mode is still silent"))
        // And it names its own control in the control's own case, so the sentence and the button
        // cannot drift apart.
        assertTrue(DESERT_RESTORE_OFFER_TEMPLATE.contains(DESERT_RESTORE_OFFER_ACTION))
    }

    @Test
    fun onlyAnEstablishedLiveSessionGetsTheUsableReconnectShell() {
        assertTrue(shouldUseReconnectShell(true, true, ConnState.CONNECTING, false))
        // Intentional disconnect then a fresh board connection: shell may stay mounted beneath
        // the opaque connect surface, but it must not be described or exposed as auto-reconnect.
        assertFalse(shouldUseReconnectShell(true, false, ConnState.CONNECTING, false))
        assertFalse(shouldUseReconnectShell(false, true, ConnState.CONNECTING, false))
        assertFalse(shouldUseReconnectShell(true, true, ConnState.BONDING, false))
        assertFalse(shouldUseReconnectShell(true, true, ConnState.CONNECTING, true))
    }

    @Test
    fun consumedNavigationTokenDoesNotReopenOnTabReentry() {
        assertTrue(shouldHandleOpenToken(token = 1, handledWatermark = 0))
        assertFalse(shouldHandleOpenToken(token = 1, handledWatermark = 1))
        assertTrue(shouldHandleOpenToken(token = 2, handledWatermark = 1))
    }

    @Test
    fun nearbyPermissionRecoveryIsImmediateAndRetained() {
        assertEquals(
            NearbyPermissionDenial.NONE,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = false, canAskAgain = false),
        )
        assertEquals(
            NearbyPermissionDenial.RETRYABLE,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = true, canAskAgain = true),
        )
        assertEquals(
            NearbyPermissionDenial.SETTINGS,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = true, canAskAgain = false),
        )
        assertEquals(
            NearbyPermissionDenial.NONE,
            resolveNearbyPermissionDenial(granted = true, requestedBefore = true, canAskAgain = false),
        )
        assertTrue(canRetryAllMissingPermissions(listOf(true, true)))
        assertFalse(canRetryAllMissingPermissions(listOf(true, false)))
        assertFalse(canRetryAllMissingPermissions(emptyList()))
    }

    /** The checklist opens only on a READY, real session whose seen flag is unset. Wrong input: a
     *  gate that ignores `seen` shows an upgrader who finished the old tour the checklist again (the
     *  fourth assertion fails); one that ignores the state opens it before the encrypted link is up
     *  (the second fails). Then automatic Live Mode waits for completion, as before.
     *  iOS twin: OnboardingPolicyTests testChecklistGateReadsBothDurableKeys. */
    @Test
    fun checklistOpensOnlyForUnseenReadyRealSessions() {
        assertTrue(shouldOpenChecklist(ConnState.READY, demoMode = false, seen = false))
        assertFalse(shouldOpenChecklist(ConnState.CONNECTING, demoMode = false, seen = false))
        assertFalse(shouldOpenChecklist(ConnState.READY, demoMode = true, seen = false))
        assertFalse("an upgrader who finished the old tour never sees it",
            shouldOpenChecklist(ConnState.READY, demoMode = false, seen = true))

        // An unfinished checklist blocks automatic Live Mode.
        assertFalse(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = false,
            promptDeferred = false,
            wanted = true,
            active = false,
            attempted = false,
            locationPromptPending = false,
        ))
        assertTrue(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = true,
            promptDeferred = false,
            wanted = true,
            active = false,
            attempted = false,
            locationPromptPending = false,
        ))
        assertFalse(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = true,
            promptDeferred = true,
            wanted = true,
            active = false,
            attempted = false,
            locationPromptPending = false,
        ))
    }

    /** The checklist's Continue asks for Location as the sheet closes, and the Live rationale must
     *  not stack with that system dialog: with every other input set to start, a pending Location
     *  prompt holds the start, and its result releases it. Wrong input: a shouldAttemptDefaultLive
     *  that ignores the new input fails the first assertion. */
    @Test
    fun defaultLiveWaitsForTheChecklistLocationPrompt() {
        assertFalse(shouldAttemptDefaultLive(
            state = ConnState.READY, demoMode = false, tourSeen = true, promptDeferred = false,
            wanted = true, active = false, attempted = false, locationPromptPending = true,
        ))
        assertTrue(shouldAttemptDefaultLive(
            state = ConnState.READY, demoMode = false, tourSeen = true, promptDeferred = false,
            wanted = true, active = false, attempted = false, locationPromptPending = false,
        ))
    }

    /** One set of scan-button words on both phones, with a neutral "Continue" before the system
     *  has asked. A running scan wins over the permission, as on iOS. Wrong input: checking the
     *  permission first fails the third assertion. iOS twin: OnboardingPolicyTests
     *  testBluetoothPrePermissionActionUsesNeutralContinueTitle. */
    @Test
    fun scanButtonTitleMatchesIos() {
        assertEquals("Continue", scanButtonTitle(isScanning = false, granted = false))
        assertEquals("Scan for Beacons", scanButtonTitle(isScanning = false, granted = true))
        assertEquals("Stop Scanning", scanButtonTitle(isScanning = true, granted = false))
        assertEquals("Stop Scanning", scanButtonTitle(isScanning = true, granted = true))
    }

    /** Authorized wins over denied, then denied over undecided. Wrong input: checking isDenied
     *  first fails the last assertion. iOS twin: OnboardingPolicyTests
     *  testLocationChoiceHasExplicitContinueAndNotNowState. */
    @Test
    fun locationChoiceHasExplicitContinueAndNotNowState() {
        assertEquals(FinishSetupLocationChoice.CONTINUE_OR_NOT_NOW,
            finishSetupLocationChoice(isAuthorized = false, isDenied = false))
        assertEquals(FinishSetupLocationChoice.OPEN_SETTINGS_OR_DONE,
            finishSetupLocationChoice(isAuthorized = false, isDenied = true))
        assertEquals(FinishSetupLocationChoice.DONE,
            finishSetupLocationChoice(isAuthorized = true, isDenied = false))
        assertEquals(FinishSetupLocationChoice.DONE,
            finishSetupLocationChoice(isAuthorized = true, isDenied = true))
    }

    /** Continue requests Location only for a checklist that was really shown, on a ready, real
     *  session. Each input on its own must be able to stop it. Wrong input: a predicate that
     *  ignores sheetWasPresented fails the fourth assertion. iOS twin: OnboardingPolicyTests
     *  testLocationPromptRequiresAVisibleCompletedFinishSetupSheet. */
    @Test
    fun locationPromptRequiresAVisibleCompletedChecklist() {
        assertTrue(shouldRequestOnboardingLocation(
            continueChosen = true, isSessionReady = true, sheetWasPresented = true, isDemoMode = false))
        assertFalse("Not Now never requests", shouldRequestOnboardingLocation(
            continueChosen = false, isSessionReady = true, sheetWasPresented = true, isDemoMode = false))
        assertFalse("the link dropped before the sheet closed", shouldRequestOnboardingLocation(
            continueChosen = true, isSessionReady = false, sheetWasPresented = true, isDemoMode = false))
        assertFalse("no sheet, no request", shouldRequestOnboardingLocation(
            continueChosen = true, isSessionReady = true, sheetWasPresented = false, isDemoMode = false))
        assertFalse("sample data never asks", shouldRequestOnboardingLocation(
            continueChosen = true, isSessionReady = true, sheetWasPresented = true, isDemoMode = true))
    }

    /** The detectors row counts the six category detectors and never the body-cam sub-toggle
     *  (moto) or the drone refinement (droui); both fixtures turn those two ON, so counting either
     *  moves 5 to 6 and 1 to 2. Wrong inputs: counting moto or droui; "1 detectors on".
     *  iOS twin: OnboardingPolicyTests testChecklistDetectorsTitleCountsEnabledDetectors. */
    @Test
    fun checklistDetectorsTitleCountsEnabledDetectors() {
        assertNull(enabledDetectorCount(null))
        // Sentence case since the 2026-09-26 review (P3-11): the uncounted title is a row title.
        assertEquals("Detectors on", checklistDetectorsTitle(null))
        val five = DeviceStatus.fromJson(JSONObject(
            """{"fw":"beacon board 2.0.9","flock":true,"drone":true,"bodycam":true,"tracker":false,"glasses":true,"ncam":true,"moto":true,"droui":true}"""))
        assertEquals(5, enabledDetectorCount(five))
        assertEquals("5 detectors on", checklistDetectorsTitle(enabledDetectorCount(five)))
        val one = DeviceStatus.fromJson(JSONObject(
            """{"fw":"beacon board 2.0.9","flock":true,"drone":false,"bodycam":false,"tracker":false,"glasses":false,"ncam":false,"moto":true,"droui":true}"""))
        assertEquals("1 detector on", checklistDetectorsTitle(enabledDetectorCount(one)))
        assertEquals("0 detectors on", checklistDetectorsTitle(0))
    }

    /** J7: the replay with no live board (sample data, or before a connect) is a preview; the
     *  replay over a real frame, and the post-connect sheet, never are. Wrong input: the old sheet
     *  drew unticked checks under "your beacon is listening" with no board at all. iOS twin:
     *  checklistIsPreview(replay:frame:) in ChecklistView.swift. */
    @Test
    fun checklistReplayWithoutABoardIsAPreview() {
        val frame = DeviceStatus.fromJson(JSONObject(
            """{"fw":"beacon board 2.0.9","flock":true,"drone":true,"bodycam":true,"tracker":false,"glasses":true,"ncam":false}"""))
        assertTrue(checklistIsPreview(replay = true, frame = null))
        assertFalse(checklistIsPreview(replay = true, frame = frame))
        assertFalse(checklistIsPreview(replay = false, frame = null))
        assertFalse(checklistIsPreview(replay = false, frame = frame))
    }

    @Test
    fun finishSetupLiveStateNeverCallsBlockedOrPendingLiveActive() {
        assertEquals(FinishSetupLiveState.OFF,
            finishSetupLiveState(wanted = false, active = false, notificationsAvailable = false))
        assertEquals(FinishSetupLiveState.BLOCKED,
            finishSetupLiveState(wanted = true, active = true, notificationsAvailable = false))
        assertEquals(FinishSetupLiveState.WAITING,
            finishSetupLiveState(wanted = true, active = false, notificationsAvailable = true))
        assertEquals(FinishSetupLiveState.ACTIVE,
            finishSetupLiveState(wanted = true, active = true, notificationsAvailable = true))
    }

    /** U2-a: the checklist rows read the iOS sentences (ChecklistRows in ChecklistView.swift),
     *  byte for byte, with Android's recorded differences (Map-only Location line, the
     *  notification-blocked Live Mode line, the unknown buffer arm). Wrong inputs, each red: a null
     *  buffer drawing "CHECK"; blocked notifications drawing the unblocked sentence; a count of 1
     *  drawing "categories"; sample data drawing the blocked sentence. */
    @Test
    fun checklistRowsReadTheIosSentences() {
        assertEquals("allowed; Map is ready", checklistLocationDetail(granted = true))
        assertEquals("optional; not decided yet", checklistLocationDetail(granted = false))

        assertEquals("off until you choose categories under Beacon",
            checklistNotificationDetail(count = 0, blockedBySystem = false, demo = false))
        assertEquals("off until you choose categories under Beacon",
            checklistNotificationDetail(count = 0, blockedBySystem = true, demo = false))
        assertEquals("3 chosen, but Android is blocking them; turn notifications on for beacons in Settings",
            checklistNotificationDetail(count = 3, blockedBySystem = true, demo = false))
        assertEquals("1 category enabled on this phone",
            checklistNotificationDetail(count = 1, blockedBySystem = false, demo = false))
        assertEquals("3 categories enabled on this phone",
            checklistNotificationDetail(count = 3, blockedBySystem = false, demo = false))
        // Sample data never reads "blocked" (TWIN: iOS ChecklistRows.notificationDetail gates the
        // arm on !ble.demoMode). Wrong input, red: the blocked arm not gated on demo.
        assertEquals("3 categories enabled on this phone",
            checklistNotificationDetail(count = 3, blockedBySystem = true, demo = true))
        assertEquals("1 category enabled on this phone",
            checklistNotificationDetail(count = 1, blockedBySystem = true, demo = true))
        assertEquals("off until you choose categories under Beacon",
            checklistNotificationDetail(count = 0, blockedBySystem = true, demo = true))

        assertEquals("active on supported system surfaces",
            checklistLiveModeDetail(FinishSetupLiveState.ACTIVE))
        assertEquals("off by choice; change it later under Beacon",
            checklistLiveModeDetail(FinishSetupLiveState.OFF))
        assertEquals("on by default, but its notification is blocked by Android",
            checklistLiveModeDetail(FinishSetupLiveState.BLOCKED))
        assertEquals("ready to start with this beacon",
            checklistLiveModeDetail(FinishSetupLiveState.WAITING))
        assertEquals("ready to start with this OUI-Spy",
            checklistLiveModeDetail(FinishSetupLiveState.WAITING, BoardKind.OUI_SPY))
        assertEquals("ready to start with this Mesh-Detect",
            checklistLiveModeDetail(FinishSetupLiveState.WAITING, BoardKind.MESH_DETECT))

        assertEquals("on; the beacon retains hits while this phone is away", checklistBufferDetail(true))
        assertEquals("off; turn it on under Beacon if you want away-time hits retained", checklistBufferDetail(false))
        assertEquals("not known until your beacon reports it", checklistBufferDetail(null))
        assertEquals("on; the OUI-Spy retains hits while this phone is away",
            checklistBufferDetail(true, BoardKind.OUI_SPY))
        assertEquals("not known until your Mesh-Detect reports it",
            checklistBufferDetail(null, BoardKind.MESH_DETECT))
        assertEquals("the off arm names no board", "off; turn it on under Beacon if you want away-time hits retained",
            checklistBufferDetail(false, BoardKind.OUI_SPY))
    }
}
