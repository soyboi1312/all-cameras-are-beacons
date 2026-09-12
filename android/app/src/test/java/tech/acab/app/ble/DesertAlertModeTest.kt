package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ui.alertRestoreIsOffered
import tech.acab.app.ui.desertRestoreNeedsPreConnectSurface

/**
 * The one rule this suite exists for: ONLY THE USER CHANGES WHETHER THE DETECTOR MAKES SOUND.
 *
 * WHY IT EXISTS. Until now nothing in either suite touched Desert or the alert mode, so the rule
 * was enforced by comments alone, and two defects had been living underneath them:
 *
 *  A. a hand-picked Silent was discarded. The saved pre-Desert mode was cleared only for a
 *     NON-silent pick, so a user who chose Silent while Desert ran was indistinguishable from
 *     Desert's own mute, and leaving Desert overrode them and made the board audible. Two shipped
 *     FAQ sentences promise the opposite.
 *  B. the app un-muted with nobody in the loop. reconcileDesert restored the prior mode whenever a
 *     status frame reported Desert off, which happens after a factory reset, on an older field
 *     board, and when a second paired phone ends Desert. Nothing on screen said so.
 *
 * Both live in [desertAlertModeTransition], the pure function BOTH platforms run, so these
 * assertions are the rule itself rather than a model of it. iOS twin: DesertAlertModeTests.swift,
 * case for case.
 *
 * WHAT THIS SUITE DOES NOT COVER, so nobody reads more assurance into it than it gives.
 * AcabBleManager needs a Context, so this side cannot drive setDesert / setAlertMode /
 * reconcileDesert end to end: the CALLS into the transition are unpinned here, and a manager that
 * stopped calling it, or labelled a user tap as APP_SET_MODE, would still pass. The relaunch cases
 * at the bottom are the same shape: they run the real storage pair the manager's write path and
 * constructor call, so the round trip is the app's own, but no prefs file and no constructor are in
 * the picture. iOS covers the
 * setAlertMode and setDesert halves against a real manager with an injected defaults suite. The
 * Compose surfaces (which control is wired to takePendingAlertModeRestore, and where the offer
 * draws) are view-only on both platforms; [desertSilenceSlot],
 * [desertRestoreNeedsDetachedSurface] and [desertRestoreNeedsPreConnectSurface] in AcabAppStateTest
 * pin the decisions they render, not the rendering. That the detached slot LEADS the Beacon tab is
 * held by firmware/tools/check-signature-drift.py; that AcabApp draws the same panel first on the
 * connect screen is held by nothing automated, because the drift script cannot read AcabApp.kt
 * without that path being added to firmware-ci.yml's two lists.
 */
class DesertAlertModeTest {

    private val desertCaptured = DesertAlertModeState(saved = AlertMode.BUZZER)

    /** DEFECT A, the headline. Desert captured BUZZER on the way in; the user then picks SILENT by
     *  hand while Desert runs. That pick has to outrank the capture, so Desert ending leaves them
     *  silent. Reverting the fix (clearing only for a non-SILENT pick) leaves saved = BUZZER here,
     *  and the USER_ENDED_DESERT assertion below flips to RESTORE. */
    @Test
    fun handPickedSilentDuringDesertSurvivesDesertEnding() {
        val afterPick = desertAlertModeTransition(
            desertCaptured, DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeState.EMPTY, afterPick.state)

        val ended = desertAlertModeTransition(
            afterPick.state, DesertAlertModeEvent.USER_ENDED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, ended.effect)
        assertNull(ended.restoreTo)
    }

    /** The same pick, the other ending: the board reports Desert off by itself. Nothing is owed, so
     *  there is nothing to offer either. */
    @Test
    fun handPickedSilentSurvivesABoardReportedDesertEnding() {
        val afterPick = desertAlertModeTransition(
            desertCaptured, DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.SILENT,
        )
        val ended = desertAlertModeTransition(
            afterPick.state, DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, ended.effect)
        assertNull(ended.state.offered)
    }

    /** A hand-picked BUZZER during Desert survives too. This half passed before the fix (the old
     *  `mode != SILENT` clear covered it) and is here so a future simplification cannot trade one
     *  direction for the other. */
    @Test
    fun handPickedBuzzerDuringDesertSurvivesDesertEnding() {
        val afterPick = desertAlertModeTransition(
            DesertAlertModeState(saved = AlertMode.VIBRATE),
            DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.BUZZER,
        )
        assertEquals(DesertAlertModeState.EMPTY, afterPick.state)

        val ended = desertAlertModeTransition(
            afterPick.state, DesertAlertModeEvent.USER_ENDED_DESERT, AlertMode.BUZZER,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, ended.effect)
    }

    /** The ending that DOES restore, and the reason the saved mode exists at all: the user turned
     *  Desert off with their own tap. Deleting the RESTORE arm fails on the effect. */
    @Test
    fun userEndedDesertRestoresThePriorMode() {
        val enabled = desertAlertModeTransition(
            DesertAlertModeState.EMPTY, DesertAlertModeEvent.USER_ENABLED_DESERT, AlertMode.BUZZER,
        )
        assertEquals(DesertAlertModeEffect.MUTE_TO_SILENT, enabled.effect)
        assertEquals(AlertMode.BUZZER, enabled.state.saved)

        val ended = desertAlertModeTransition(
            enabled.state, DesertAlertModeEvent.USER_ENDED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.RESTORE, ended.effect)
        assertEquals(AlertMode.BUZZER, ended.restoreTo)
        assertEquals(DesertAlertModeState.EMPTY, ended.state)
    }

    /** DEFECT B. The board says Desert is off and nobody here asked for that. The mode MUST NOT
     *  move; the saved mode becomes an offer instead. Reverting to the old behaviour makes this
     *  event return RESTORE, which the effect assertion catches, and leaves `offered` null, which
     *  the offer assertion catches. */
    @Test
    fun boardEndedDesertChangesNoModeAndArmsTheOffer() {
        val ended = desertAlertModeTransition(
            DesertAlertModeState(saved = AlertMode.VIBRATE),
            DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, ended.effect)
        assertNull(ended.restoreTo)
        assertEquals(AlertMode.VIBRATE, ended.state.offered)
        // The value MOVES rather than being copied, so exactly one holder has it.
        assertNull(ended.state.saved)
    }

    /** Taking the offer is a user pick, which both restores (the manager passes `offered` as the
     *  mode) and clears the state. The clearing half is the assertion here; the restoring half is
     *  AcabBleManager.takePendingAlertModeRestore, which iOS covers against a real manager. */
    @Test
    fun takingTheOfferClearsIt() {
        val offered = DesertAlertModeState(offered = AlertMode.BUZZER)
        val taken = desertAlertModeTransition(
            offered, DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.BUZZER,
        )
        assertEquals(DesertAlertModeState.EMPTY, taken.state)
    }

    /** Declining it by picking something else by hand clears it too, SILENT included. */
    @Test
    fun pickingAnyModeByHandClearsThePendingOffer() {
        val offered = DesertAlertModeState(offered = AlertMode.BUZZER)
        for (picked in AlertMode.entries) {
            val after = desertAlertModeTransition(
                offered, DesertAlertModeEvent.USER_PICKED_MODE, picked,
            )
            assertEquals("picking $picked by hand must close the offer",
                DesertAlertModeState.EMPTY, after.state)
        }
    }

    /** Desert coming back on answers the offer: the board is muted again either way. The saved mode
     *  is deliberately NOT touched, because this run's own Desert-off still owes it back. */
    @Test
    fun desertComingBackOnClearsTheOfferAndKeepsTheSavedMode() {
        val mixed = DesertAlertModeState(saved = AlertMode.BUZZER, offered = AlertMode.VIBRATE)
        val after = desertAlertModeTransition(
            mixed, DesertAlertModeEvent.BOARD_REPORTS_DESERT_ON, AlertMode.SILENT,
        )
        assertNull(after.state.offered)
        assertEquals(AlertMode.BUZZER, after.state.saved)
        assertEquals(DesertAlertModeEffect.KEEP_MODE, after.effect)
    }

    /** An app-set mode is the one call that changes nothing: Desert's own mute and the restore it
     *  carries out both land here, and neither may look like a user pick. */
    @Test
    fun anAppSetModeLeavesTheSavedModeAndTheOfferAlone() {
        val mixed = DesertAlertModeState(saved = AlertMode.BUZZER, offered = AlertMode.VIBRATE)
        val after = desertAlertModeTransition(
            mixed, DesertAlertModeEvent.APP_SET_MODE, AlertMode.SILENT,
        )
        assertEquals(mixed, after.state)
        assertEquals(DesertAlertModeEffect.KEEP_MODE, after.effect)
    }

    /** Turning Desert on while already SILENT captures nothing, so a later ending cannot un-mute
     *  someone who chose quiet, and no arbitrarily old mode is left lying in preferences. */
    @Test
    fun enablingDesertWhileAlreadySilentSavesNothingToGiveBack() {
        val enabled = desertAlertModeTransition(
            DesertAlertModeState(saved = AlertMode.BUZZER),
            DesertAlertModeEvent.USER_ENABLED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, enabled.effect)
        assertEquals(DesertAlertModeState.EMPTY, enabled.state)
    }

    /** The journey the still-silent notice was built for: this phone never enabled Desert itself
     *  (first pair with a board already in Desert, or a second paired phone), so it holds nothing.
     *  Desert ending leaves it with no offer, which is what routes that user to the notice instead.
     */
    @Test
    fun aPhoneThatNeverEnabledDesertHasNothingToOffer() {
        val ended = desertAlertModeTransition(
            DesertAlertModeState.EMPTY, DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
        )
        assertEquals(DesertAlertModeEffect.KEEP_MODE, ended.effect)
        assertEquals(DesertAlertModeState.EMPTY, ended.state)
    }

    // ---- the offer outliving the process that armed it ----
    //
    // THE DEFECT THESE EXIST FOR. Both of the offer's surfaces, and the notice's gate, were per-run
    // and in memory, and arming the offer CONSUMES the persisted pre-Desert mode. So: the board
    // ends Desert, the offer arms, the user force-quits, and on relaunch there was no offer, no
    // notice, and no saved mode either - alerts silent, nothing on screen saying why, and no way
    // back except knowing which mode to re-pick. A silence this app imposed with no way out of it.
    //
    // A RELAUNCH IS STAGED THROUGH THE STORAGE PAIR, not through the manager: AcabBleManager needs
    // a Context, so this side cannot construct one (see the suite header). desertAlertModeStorage
    // and desertAlertModeStateFromStorage are what the manager's write path and its constructor
    // actually call, so "what the prefs file would hold, read back as the state a launch
    // republishes" is the same round trip the app performs, with the store taken out of it.
    // iOS drives the identical cases against a real manager over a throwaway defaults suite
    // (DesertAlertModeTests, the relaunch group).

    /** THE HEADLINE. The board ends Desert, the offer arms, the process dies. What reaches disk has
     *  to be enough to put the offer back, and nothing else: the saved half MOVED, so it must be
     *  written away in the same breath. Reverting the persistence removes
     *  [desertAlertModeStateFromStorage]'s only caller and this stops compiling; reverting just the
     *  offered half of the storage pair leaves `offered` null on the republish. */
    @Test
    fun anArmedOfferSurvivesASimulatedRelaunch() {
        val armed = desertAlertModeTransition(
            desertCaptured, DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
        ).state
        val stored = desertAlertModeStorage(armed)
        assertNull("arming MOVES the mode, so the saved half is written away", stored.saved)
        assertEquals(AlertMode.BUZZER.name, stored.offered)

        assertEquals("a launch must see exactly what the last run left",
            armed, desertAlertModeStateFromStorage(stored))
    }

    /** Taking it after that relaunch gives back the mode this phone actually muted, and closes the
     *  question on disk as well as on screen, so the NEXT launch does not re-open it. */
    @Test
    fun takingTheOfferAfterARelaunchRestoresTheRightModeAndClearsTheStore() {
        val republished = desertAlertModeStateFromStorage(
            desertAlertModeStorage(desertAlertModeTransition(
                desertCaptured, DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
            ).state),
        )
        assertEquals("the mode the control hands to setAlertMode", AlertMode.BUZZER, republished.offered)

        val taken = desertAlertModeTransition(
            republished, DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.BUZZER,
        ).state
        assertEquals(DesertAlertModeStorage.EMPTY, desertAlertModeStorage(taken))
    }

    /** Declining it by hand across a relaunch, SILENT included. The stored copy has to go with the
     *  in-memory one, or the offer returns on the launch after that and re-opens a question the
     *  user already answered. */
    @Test
    fun pickingAModeByHandAcrossARelaunchClearsThePersistedOffer() {
        val republished = desertAlertModeStateFromStorage(
            DesertAlertModeStorage(offered = AlertMode.BUZZER.name))
        for (picked in AlertMode.entries) {
            val after = desertAlertModeTransition(
                republished, DesertAlertModeEvent.USER_PICKED_MODE, picked,
            ).state
            assertEquals("picking $picked by hand must close the offer on disk",
                DesertAlertModeStorage.EMPTY, desertAlertModeStorage(after))
        }
    }

    /** Desert coming back on answers a restored offer, and that answer has to reach the store too:
     *  the board is muted again, so a control promising the mode back would be undone by the very
     *  next line of the same card. */
    @Test
    fun desertReturningClearsAPersistedOffer() {
        val republished = desertAlertModeStateFromStorage(
            DesertAlertModeStorage(offered = AlertMode.BUZZER.name))
        val after = desertAlertModeTransition(
            republished, DesertAlertModeEvent.BOARD_REPORTS_DESERT_ON, AlertMode.SILENT,
        ).state
        assertEquals(DesertAlertModeStorage.EMPTY, desertAlertModeStorage(after))
    }

    /** THE HOLE THE PRE-CONNECT SURFACE CLOSES. The board ends Desert, the process dies, and the
     *  owner comes back to a board that is off or gone: no link, so AcabApp never hands off to the
     *  tab shell, so DeviceScreen and all three of its copies of the offer are not on the phone.
     *  The republished offer therefore has to be answerable from the connect screen, and this walks
     *  that path with the real storage pair, the real gate and the real transition.
     *
     *  THE TAKE HALF IS THE TRANSITION, NOT THE MANAGER (see the suite header): what is asserted is
     *  that answering it is an ordinary USER pick, which needs no board because the alert mode is a
     *  phone preference. iOS runs the same case against a real manager that never connected, in
     *  testWithNoBoardTheConnectScreenCarriesTheOfferAndTakingItThereWorks.
     *
     *  Deleting the surface deletes [desertRestoreNeedsPreConnectSurface] and this stops compiling;
     *  inverting its gate fails the second assertion; a take that failed to clear the store fails
     *  the last one. */
    @Test
    fun withNoBoardTheConnectScreenCarriesTheRepublishedOfferUntilItIsAnswered() {
        val republished = desertAlertModeStateFromStorage(
            desertAlertModeStorage(desertAlertModeTransition(
                desertCaptured, DesertAlertModeEvent.BOARD_ENDED_DESERT, AlertMode.SILENT,
            ).state),
        )
        assertEquals(AlertMode.BUZZER, republished.offered)
        assertTrue("the connect screen must carry it when it is the only screen there is",
            desertRestoreNeedsPreConnectSurface(
                restoreOffered = alertRestoreIsOffered(false, republished.offered),
                mainShellVisible = false,
            ))

        val taken = desertAlertModeTransition(
            republished, DesertAlertModeEvent.USER_PICKED_MODE, AlertMode.BUZZER,
        ).state

        assertFalse("and stop carrying it the moment it is answered",
            desertRestoreNeedsPreConnectSurface(
                restoreOffered = alertRestoreIsOffered(false, taken.offered),
                mainShellVisible = false,
            ))
        assertEquals("answered on disk too, so the next launch does not re-open it",
            DesertAlertModeStorage.EMPTY, desertAlertModeStorage(taken))
    }

    /** A string no mode answers to - a downgrade, a hand-edited prefs file - reads as nothing held,
     *  never as a crash and never as a mode picked by accident. */
    @Test
    fun unreadableStoredHalvesReadAsNothingHeld() {
        assertEquals(DesertAlertModeState.EMPTY,
            desertAlertModeStateFromStorage(DesertAlertModeStorage(saved = "loud", offered = "")))
        assertEquals(DesertAlertModeState.EMPTY,
            desertAlertModeStateFromStorage(DesertAlertModeStorage.EMPTY))
    }
}
