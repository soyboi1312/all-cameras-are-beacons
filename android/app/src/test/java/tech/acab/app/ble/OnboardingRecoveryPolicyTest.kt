package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingRecoveryPolicyTest {
    @Test
    fun scanStartFailureIsNotReportedAsAnEmptyScan() {
        val ordinary = scanStartFailureHint(featureUnsupported = false)
        val unsupported = scanStartFailureHint(featureUnsupported = true)

        assertTrue(ordinary.contains("could not start Bluetooth scanning"))
        assertTrue(unsupported.contains("does not support"))
        assertNotEquals(ordinary, unsupported)
        // Neither reads as the empty-scan panel, in any case and for any kind.
        for (kind in listOf(null) + BoardKind.entries) {
            val emptyScan = renderBoardCopy("no {plural} found", kind)
            for (hint in listOf(scanStartFailureHint(false, kind), scanStartFailureHint(true, kind))) {
                assertTrue(hint, !hint.contains(emptyScan, ignoreCase = true))
            }
        }
        // The unsupported arm names the remembered board's kind; null reads as beacon.
        assertEquals("this phone does not support the Bluetooth scan needed to find your beacon.", unsupported)
        assertEquals(unsupported, scanStartFailureHint(true, BoardKind.BEACON))
        assertEquals("this phone does not support the Bluetooth scan needed to find your OUI-Spy.",
            scanStartFailureHint(true, BoardKind.OUI_SPY))
        assertEquals("this phone does not support the Bluetooth scan needed to find your Mesh-Detect.",
            scanStartFailureHint(true, BoardKind.MESH_DETECT))
    }

    @Test
    fun eachPairingTerminalCauseHasDistinctRecoveryCopy() {
        val start = pairingFailureHint(PairingFailure.START_REJECTED)
        val failed = pairingFailureHint(PairingFailure.CANCELED_OR_FAILED)
        val timeout = pairingFailureHint(PairingFailure.TIMED_OUT)
        val secureReady = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)

        assertTrue(start.contains("could not start pairing"))
        assertTrue(failed.contains("canceled or failed"))
        assertTrue(timeout.contains("took too long"))
        assertTrue(secureReady.contains("secure link did not become ready"))
        assertTrue(failed.contains("approve Android's pairing request"))
        assertNotEquals(start, failed)
        assertNotEquals(failed, timeout)
        assertNotEquals(timeout, secureReady)

        // Per kind: every cause names the board being connected by its own noun, never another
        // kind's and never the generic "board", lowercase-first after its "Android" lead, with no
        // dash and no unfilled hole. null reads exactly as beacon (decisions R14). TWIN: iOS
        // OnboardingPolicyTests.testConnectionFailuresGiveDistinctBeaconRecovery.
        val causes = PairingFailure.entries
        assertEquals(causes.map { pairingFailureHint(it, null) }, causes.map { pairingFailureHint(it, BoardKind.BEACON) })
        for (kind in BoardKind.entries) {
            val hints = causes.map { pairingFailureHint(it, kind) } +
                renderBoardCopy(DETECTIONS_SUBSCRIBE_FAILED_TEMPLATE, kind)
            assertEquals(hints.size, hints.toSet().size)
            for (hint in hints) {
                assertTrue("$kind: $hint", hint.contains(kind.noun))
                assertTrue("$kind: $hint", !hint.contains("board"))
                assertTrue("unfilled hole: $hint", !hint.contains("{"))
                assertTrue(hint, !hint.contains('\u2013') && !hint.contains('\u2014'))
                assertTrue("lowercase-first: $hint", hint.startsWith("Android") || hint.first().isLowerCase())
                for (other in BoardKind.entries - kind) {
                    assertTrue("$kind never names $other: $hint", !hint.contains(" ${other.noun}"))
                }
            }
        }
        assertEquals("pairing took too long. keep the OUI-Spy powered on and nearby, approve Android's pairing request if it appears, then try again.",
            pairingFailureHint(PairingFailure.TIMED_OUT, BoardKind.OUI_SPY))
        assertEquals("this Mesh-Detect connected but will not send detections. turn it off and on, then try again.",
            renderBoardCopy(DETECTIONS_SUBSCRIBE_FAILED_TEMPLATE, BoardKind.MESH_DETECT))
    }

    /** The "already paired to another phone?" note shows only under a hint a second phone can
     *  explain. TWIN: iOS OnboardingPolicyTests.testPairWindowNoteShowsOnlyForLinkAndPairingStages
     *  holds the same four-row table, so a stage that flips on one phone fails that phone's suite. */
    @Test
    fun pairWindowNoteShowsOnlyForLinkAndPairingStages() {
        val expected = mapOf(
            ConnectFailureStage.LINK to true,
            ConnectFailureStage.PAIRING to true,
            ConnectFailureStage.PROFILE to false,
            ConnectFailureStage.SECURE_SETUP to false,
        )
        assertEquals("every stage has a row: a new stage must choose",
            ConnectFailureStage.entries.toSet(), expected.keys)
        for (stage in ConnectFailureStage.entries) {
            assertEquals("$stage", expected[stage], showsPairWindowNote(stage))
        }
    }

    /** Each Android failure cause lands on the stage that decides its note, and the hint carries
     *  the cause's own sentence. Every pairing terminal cause is PAIRING; a Detections
     *  subscription the board refused is PAIRING too (iOS reads a refused Detections notify as
     *  `.securePairing`), and one whose characteristic or CCCD is absent is PROFILE. TWIN: iOS
     *  OnboardingPolicyTests.testConnectHintStagesForEveryFailureCause (its own causes). */
    @Test
    fun connectHintStagesForEveryFailureCause() {
        for (kind in listOf(null) + BoardKind.entries) {
            for (failure in PairingFailure.entries) {
                val hint = pairingFailureConnectHint(failure, kind)
                assertEquals("$failure", ConnectFailureStage.PAIRING, hint.stage)
                assertEquals(pairingFailureHint(failure, kind), hint.text)
                assertTrue("$failure", showsPairWindowNote(hint.stage))
            }
            val refused = detectionsSubscribeFailedHint(missing = false, kind)
            val missing = detectionsSubscribeFailedHint(missing = true, kind)
            assertEquals(ConnectFailureStage.PAIRING, refused.stage)
            assertEquals(ConnectFailureStage.PROFILE, missing.stage)
            assertEquals(renderBoardCopy(DETECTIONS_SUBSCRIBE_FAILED_TEMPLATE, kind), refused.text)
            assertEquals(refused.text, missing.text)
            assertTrue(showsPairWindowNote(refused.stage))
            assertFalse(showsPairWindowNote(missing.stage))

            // The fresh-connect watchdog is LINK, and its sentence is the pair-window sentence
            // itself, which is why ConnectionHintPanel does not draw the note a second time.
            val link = linkWatchdogConnectHint(kind)
            assertEquals(ConnectFailureStage.LINK, link.stage)
            assertEquals(AcabBleManager.pairWindowHint(kind), link.text)
            assertTrue(showsPairWindowNote(link.stage))
        }
    }

    /** Every failure after the encrypted Detections subscription succeeded is SECURE_SETUP, so no
     *  pair-window note shows under it: the phone was already bonded, and a second phone cannot
     *  be the cause. TWIN: iOS ConnectHint.secureSetup (its call sites pass the same sentences). */
    @Test
    fun secureSetupHintsShowNoPairWindowNote() {
        val hints = SecureSetupFailure.entries.map { secureSetupConnectHint(it) }
        for ((failure, hint) in SecureSetupFailure.entries.zip(hints)) {
            assertEquals("$failure", ConnectFailureStage.SECURE_SETUP, hint.stage)
            assertFalse("$failure", showsPairWindowNote(hint.stage))
        }
        assertEquals("each cause has its own sentence", hints.size, hints.map { it.text }.toSet().size)
        assertEquals(AcabBleManager.BUFFER_KEY_UNAVAILABLE_HINT,
            secureSetupConnectHint(SecureSetupFailure.BUFFER_KEY_UNAVAILABLE).text)
        assertEquals("Offline history was not cleared. Reconnect and try again.",
            secureSetupConnectHint(SecureSetupFailure.CLEAR_LOG_REJECTED).text)
        assertEquals("Secure offline-history setup failed. Reconnect and try again before relying on replay.",
            secureSetupConnectHint(SecureSetupFailure.BUFFER_HANDSHAKE_FAILED).text)
    }

    @Test
    fun bondNoneRequiresCurrentAttemptBondingWatermarkAndStateRecheck() {
        assertTrue(shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 3L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = false,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = true,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))

        assertTrue(shouldHandleCurrentBonded(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            handledBondedGeneration = 3L,
            platformStateIsBonded = true,
        ))
        assertTrue(!shouldHandleCurrentBonded(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            handledBondedGeneration = 4L,
            platformStateIsBonded = true,
        ))
    }

    @Test
    fun demoEntryStopsOnlyAnActiveScan() {
        assertTrue(shouldStopScanBeforeDemo(ConnState.SCANNING))
        assertTrue(!shouldStopScanBeforeDemo(ConnState.DISCONNECTED))
        assertTrue(!shouldStopScanBeforeDemo(ConnState.READY))
    }

    @Test
    fun secureReadinessCoversAlreadyBondedAndFreshBondPaths() {
        assertTrue(awaitingSecureReadiness(ConnState.CONNECTING))
        assertTrue(awaitingSecureReadiness(ConnState.BONDING))
        assertTrue(!awaitingSecureReadiness(ConnState.READY))
        assertTrue(!awaitingSecureReadiness(ConnState.SCANNING))
    }
}
