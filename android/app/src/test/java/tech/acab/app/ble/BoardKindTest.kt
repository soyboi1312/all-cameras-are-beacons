package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The board-kind model (BoardKind.kt) and the manager-side rules that carry it: detection from the
 * fw label and the advert name, the precedence, the screen rule, the remembered record's load /
 * READY / stamp, and the manager's own per-kind copy. Every rendering below is the Android column
 * of the OUI-Spy naming table, byte for byte; a template reworded on one side only fails here.
 * iOS twin: ios/BeaconsTests/BoardKindTests.swift.
 */
class BoardKindTest {

    private val a = "E8:3D:C1:00:00:01"
    private val b = "E8:3D:C1:00:00:02"
    private val all = listOf(null, BoardKind.BEACON, BoardKind.OUI_SPY, BoardKind.MESH_DETECT)

    // ---- detection ----

    @Test fun firmwareLabelIsAuthoritative() {
        assertEquals(BoardKind.BEACON, BoardKind.fromFirmwareLabel("beacon board"))
        assertEquals(BoardKind.BEACON, BoardKind.fromFirmwareLabel("beacon board rev-B"))
        assertEquals(BoardKind.BEACON, BoardKind.fromFirmwareLabel("beacon c5"))
        assertEquals(BoardKind.OUI_SPY, BoardKind.fromFirmwareLabel("ACAB-ouispy"))
        assertEquals(BoardKind.MESH_DETECT, BoardKind.fromFirmwareLabel("mesh-detect-ACAB"))
        assertEquals(BoardKind.MESH_DETECT, BoardKind.fromFirmwareLabel("mesh-detect-ACAB-ch1"))
        assertNull(BoardKind.fromFirmwareLabel(""))
        assertNull(BoardKind.fromFirmwareLabel("odid-sim"))
        assertNull(BoardKind.fromFirmwareLabel(null))
    }

    @Test fun advertNameIsOnlyAHint() {
        assertEquals(BoardKind.BEACON, BoardKind.fromAdvertName("beacon"))
        assertEquals(BoardKind.OUI_SPY, BoardKind.fromAdvertName("ACAB"))
        assertEquals(BoardKind.MESH_DETECT, BoardKind.fromAdvertName("ACAB-mesh"))
        assertEquals(BoardKind.MESH_DETECT, BoardKind.fromAdvertName("ACAB-mes"))
        // No name (the stealth advert, a nameless frame) is unknown, never the "ACAB" fallback.
        assertNull(BoardKind.fromAdvertName(null))
        assertNull(BoardKind.fromAdvertName(""))
        assertNull(BoardKind.fromAdvertName("ACAB-01"))
        assertNull(BoardKind.fromAdvertName("AdaDFU"))
    }

    @Test fun rawValuesRoundTripAndUnknownIsNull() {
        assertEquals(listOf("beacon", "ouiSpy", "meshDetect"), BoardKind.entries.map { it.raw })
        for (k in BoardKind.entries) assertEquals(k, BoardKind.fromRaw(k.raw))
        assertNull(BoardKind.fromRaw(null))
        assertNull(BoardKind.fromRaw(""))
        assertNull(BoardKind.fromRaw("OUI_SPY"))
        assertNull(BoardKind.fromRaw("mesh"))
    }

    @Test fun nounTable() {
        assertEquals(listOf("beacon", "OUI-Spy", "Mesh-Detect"), BoardKind.entries.map { it.noun })
        assertEquals(listOf("a beacon", "an OUI-Spy", "a Mesh-Detect"), BoardKind.entries.map { it.aNoun })
        assertEquals(listOf("beacons", "OUI-Spy", "Mesh-Detect"), BoardKind.entries.map { it.plural })
        assertEquals(listOf("BEACON", "OUI-SPY", "MESH-DETECT"), BoardKind.entries.map { it.nounUpper })
        assertEquals(listOf("All Cameras Are Beacons", "OUI-Spy", "Mesh-Detect"),
            BoardKind.entries.map { it.heroTitle })
    }

    @Test fun renderFillsEveryTokenAndNullReadsAsBeacon() {
        val t = "{noun}|{a_noun}|{plural}|{NOUN}|{os_pairing_request}"
        assertEquals("beacon|a beacon|beacons|BEACON|Android's pairing request", renderBoardCopy(t, null))
        assertEquals(renderBoardCopy(t, BoardKind.BEACON), renderBoardCopy(t, null))
        assertEquals("OUI-Spy|an OUI-Spy|OUI-Spy|OUI-SPY|Android's pairing request",
            renderBoardCopy(t, BoardKind.OUI_SPY))
        assertEquals("Mesh-Detect|a Mesh-Detect|Mesh-Detect|MESH-DETECT|Android's pairing request",
            renderBoardCopy(t, BoardKind.MESH_DETECT))
    }

    // ---- precedence ----

    @Test fun precedenceIsFirmwareThenLiveHintThenStored() {
        // The fw label beats both.
        assertEquals(BoardKind.MESH_DETECT,
            resolveBoardKind("mesh-detect-ACAB", BoardKind.OUI_SPY, BoardKind.BEACON))
        // A live hint beats the stored kind (a reflashed remembered board), in both directions.
        assertEquals(BoardKind.BEACON, resolveBoardKind(null, BoardKind.OUI_SPY, BoardKind.BEACON))
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, BoardKind.BEACON, BoardKind.OUI_SPY))
        // No live hint (the stealth advert, an unheard board): the stored kind.
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, BoardKind.OUI_SPY, null))
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, BoardKind.OUI_SPY, BoardKind.fromAdvertName(null)))
        // A label that names no kind falls through, it does not blank the stored kind.
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind("odid-sim", BoardKind.OUI_SPY, null))
        assertEquals(BoardKind.BEACON, resolveBoardKind(null, null, BoardKind.BEACON))
        assertNull(resolveBoardKind(null, null, null))
        // The app's "ACAB" fallback is never passed as a hint; a row with no real name has none.
        assertNull(resolveBoardKind(null, null, BoardKind.fromAdvertName(null)))
    }

    @Test fun advertHintCarriesForwardTheLastNamedKind() {
        // A named frame sets the hint; a later frame with no name, or with a name no kind claims,
        // keeps it (the iOS rule: the last non-nil hint wins). Only a name that names a kind
        // replaces it.
        var hint: BoardKind? = null
        hint = carriedAdvertHint("ACAB", hint)
        assertEquals(BoardKind.OUI_SPY, hint)
        hint = carriedAdvertHint(null, hint)
        assertEquals(BoardKind.OUI_SPY, hint)
        hint = carriedAdvertHint("ACAB-01", hint)
        assertEquals(BoardKind.OUI_SPY, hint)
        hint = carriedAdvertHint("", hint)
        assertEquals(BoardKind.OUI_SPY, hint)
        hint = carriedAdvertHint("ACAB-mesh", hint)
        assertEquals(BoardKind.MESH_DETECT, hint)
        hint = carriedAdvertHint("beacon", hint)
        assertEquals(BoardKind.BEACON, hint)
        // A row that never heard a name has none.
        assertNull(carriedAdvertHint(null, null))
        assertNull(carriedAdvertHint("AdaDFU", null))
    }

    @Test fun reflashedRememberedBoardReadsByItsLiveAdvertThenTheFrameRestamps() {
        // Stored beacon, reflashed to OUI-Spy. Before connect the live hint names it; the stored
        // kind is not touched by a hint.
        val beaconRecord = RememberedBoard(a, "beacon", BoardKind.BEACON)
        val hint = carriedAdvertHint("ACAB", null)
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, beaconRecord.kind, hint))
        // After connect the fw label wins over both, and the first READY frame re-stamps.
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind("ACAB-ouispy", beaconRecord.kind, BoardKind.BEACON))
        val restamped = rememberedBoardAfterStatus(beaconRecord, a, "ACAB-ouispy", demoMode = false)
        assertEquals(BoardKind.OUI_SPY, restamped?.kind)

        // The other order: stored OUI-Spy, reflashed to the beacon image.
        val spyRecord = RememberedBoard(a, "ACAB", BoardKind.OUI_SPY)
        val beaconHint = carriedAdvertHint("beacon", null)
        assertEquals(BoardKind.BEACON, resolveBoardKind(null, spyRecord.kind, beaconHint))
        assertEquals(BoardKind.BEACON, resolveBoardKind("beacon board rev-B", spyRecord.kind, BoardKind.OUI_SPY))
        assertEquals(BoardKind.BEACON,
            rememberedBoardAfterStatus(spyRecord, a, "beacon board rev-B", demoMode = false)?.kind)

        // Stealth: the reflashed board advertises no name, so the stored kind still names it
        // until the frame, and a nameless frame after a named one keeps the named hint.
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, spyRecord.kind, carriedAdvertHint(null, null)))
        assertEquals(BoardKind.BEACON, resolveBoardKind(null, spyRecord.kind, carriedAdvertHint(null, beaconHint)))
    }

    @Test fun connectedKindIsTheFrameElseTheTarget() {
        assertEquals(BoardKind.OUI_SPY, connectedBoardKind("ACAB-ouispy", BoardKind.BEACON))
        assertEquals(BoardKind.MESH_DETECT, connectedBoardKind(null, BoardKind.MESH_DETECT))
        assertNull(connectedBoardKind(null, null))
    }

    @Test fun screenKindRule() {
        val spy = BoardKind.OUI_SPY
        val beacon = BoardKind.BEACON
        // 1. The target wins while it is active, even when it is unknown.
        assertEquals(BoardKind.MESH_DETECT, resolveScreenKind(true, BoardKind.MESH_DETECT, spy, listOf(beacon)))
        assertNull(resolveScreenKind(true, null, spy, listOf(spy)))
        // 2. Otherwise the remembered board.
        assertEquals(spy, resolveScreenKind(false, beacon, spy, listOf(beacon, beacon)))
        // 3. Otherwise the kind every row agrees on.
        assertEquals(spy, resolveScreenKind(false, null, null, listOf(spy, spy)))
        // A mixed scan, a row with no hint, and an empty scan all stay beacon (null).
        assertNull(resolveScreenKind(false, null, null, listOf(beacon, spy)))
        assertNull(resolveScreenKind(false, null, null, listOf(spy, null)))
        assertNull(resolveScreenKind(false, null, null, listOf(null, null)))
        assertNull(resolveScreenKind(false, null, null, emptyList()))
    }

    // ---- the remembered record ----

    @Test fun storedRecordLoadsWithItsKindAndMigratesToUnknown() {
        assertEquals(RememberedBoard(a, "ACAB", BoardKind.OUI_SPY), rememberedBoardFromStored(a, "ACAB", "ouiSpy"))
        // A record from before the key, or a value this build does not know: unknown, not guessed
        // from the name (a stored "ACAB" is also the nameless fallback).
        assertEquals(RememberedBoard(a, "ACAB", null), rememberedBoardFromStored(a, "ACAB", null))
        assertEquals(RememberedBoard(a, "ACAB", null), rememberedBoardFromStored(a, "ACAB", "ouispy2"))
        assertEquals(RememberedBoard(a, REMEMBERED_BOARD_FALLBACK_NAME, BoardKind.BEACON),
            rememberedBoardFromStored(a, " ", "beacon"))
        assertNull(rememberedBoardFromStored(null, "ACAB", "ouiSpy"))
        assertNull(rememberedBoardFromStored(" ", "ACAB", "ouiSpy"))
        for (k in BoardKind.entries) assertEquals(k, rememberedBoardFromStored(a, "x", k.raw)?.kind)
    }

    @Test fun readyKeepsTheKindForTheSameBoardAndResetsItForAnother() {
        val held = RememberedBoard(a, "ACAB", BoardKind.OUI_SPY)
        // Same board, same name: no write at all (identity), the kind rides along.
        assertSame(held, rememberedBoardAfterReady(held, a, "ACAB", bonded = true, demoMode = false))
        // Same board renamed: the name moves, the kind stays.
        assertEquals(RememberedBoard(a, "ACAB-mesh", BoardKind.OUI_SPY),
            rememberedBoardAfterReady(held, a, "ACAB-mesh", bonded = true, demoMode = false))
        // A different board starts unknown, never inheriting the old board's kind.
        assertEquals(RememberedBoard(b, "beacon", null),
            rememberedBoardAfterReady(held, b, "beacon", bonded = true, demoMode = false))
    }

    @Test fun firstFrameStampWritesOnceAndOnlyForTheRememberedBoard() {
        val unknown = RememberedBoard(a, "ACAB")
        val stamped = rememberedBoardAfterStatus(unknown, a, "ACAB-ouispy", demoMode = false)
        assertEquals(RememberedBoard(a, "ACAB", BoardKind.OUI_SPY), stamped)
        // An unchanged kind is no write (identity), so later frames cost a compare.
        assertSame(stamped, rememberedBoardAfterStatus(stamped, a, "ACAB-ouispy", demoMode = false))
        assertSame(stamped, rememberedBoardAfterStatus(stamped, a.lowercase(), "ACAB-ouispy", demoMode = false))
        // Sample data, another board, no record, or a label that names no kind: nothing moves.
        assertSame(unknown, rememberedBoardAfterStatus(unknown, a, "beacon board 2.0.9", demoMode = true))
        assertSame(unknown, rememberedBoardAfterStatus(unknown, b, "ACAB-ouispy", demoMode = false))
        assertSame(unknown, rememberedBoardAfterStatus(unknown, null, "ACAB-ouispy", demoMode = false))
        assertSame(unknown, rememberedBoardAfterStatus(unknown, a, "odid-sim", demoMode = false))
        assertNull(rememberedBoardAfterStatus(null, a, "ACAB-ouispy", demoMode = false))
        // A reflashed board (the name follows the image) restamps.
        assertEquals(BoardKind.BEACON,
            rememberedBoardAfterStatus(stamped, a, "beacon board rev-B", demoMode = false)?.kind)
    }

    /** A ready session's kind-naming fw label retires the connected row's pre-session hint, so
     *  after a drop that stale sighting cannot outrank the kind the label just stamped. */
    @Test fun readyFrameRetiresThePreSessionHint() {
        fun retires(label: String? = "ACAB-ouispy", hint: BoardKind? = BoardKind.BEACON,
                    ready: Boolean = true, demo: Boolean = false) =
            statusFrameRetiresKindHint(label, hint, sessionReady = ready, demoMode = demo)
        assertTrue("a reflashed board's old sighting goes once the label names it", retires())
        assertTrue("a matching hint goes too: the stamp now carries it", retires(hint = BoardKind.OUI_SPY))
        assertFalse("no hint, nothing to retire", retires(hint = null))
        assertFalse("only a ready session's frame retires it", retires(ready = false))
        assertFalse("sample data never retires it", retires(demo = true))
        assertFalse("a label that names no kind keeps the hint", retires("odid-sim"))
        assertFalse("an empty label keeps the hint", retires(""))
        assertFalse("no label keeps the hint", retires(null))

        // The whole path: a stored beacon, reflashed to OUI-Spy but heard as "beacon" before the
        // reflash. Once the frame stamps OUI-Spy and retires the hint, the owned row reads OUI-Spy
        // after the drop, not the stale sighting.
        val record = RememberedBoard(a, "beacon", BoardKind.BEACON)
        val staleHint = carriedAdvertHint("beacon", null)
        val stamped = rememberedBoardAfterStatus(record, a, "ACAB-ouispy", demoMode = false)
        assertEquals(BoardKind.BEACON, resolveBoardKind(null, stamped?.kind, staleHint))
        val rowHint = staleHint.takeUnless { statusFrameRetiresKindHint("ACAB-ouispy", it, true, false) }
        assertNull(rowHint)
        assertEquals(BoardKind.OUI_SPY, resolveBoardKind(null, stamped?.kind, rowHint))
    }

    // ---- the manager's copy ----

    @Test fun rememberedRowCopyPerKind() {
        assertEquals("your beacon", RememberedBoardCopy.label(null))
        assertEquals("your beacon", RememberedBoardCopy.label(BoardKind.BEACON))
        assertEquals("your OUI-Spy", RememberedBoardCopy.label(BoardKind.OUI_SPY))
        assertEquals("your Mesh-Detect", RememberedBoardCopy.label(BoardKind.MESH_DETECT))
        // The subtitle no longer carries the advertised name.
        assertEquals("tap to connect", RememberedBoardCopy.subtitle(advertSeen = true))
        assertEquals("no live signal · tap to connect", RememberedBoardCopy.subtitle(advertSeen = false))
    }

    @Test fun pairWindowHintPerKind() {
        assertEquals("turn the beacon off and on, then connect within two minutes.",
            AcabBleManager.pairWindowHint(null))
        assertEquals("turn the OUI-Spy off and on, then connect within two minutes.",
            AcabBleManager.pairWindowHint(BoardKind.OUI_SPY))
        assertEquals("turn the Mesh-Detect off and on, then connect within two minutes.",
            AcabBleManager.pairWindowHint(BoardKind.MESH_DETECT))
    }

    @Test fun failureHintsPerKind() {
        fun hints(k: BoardKind?) = listOf(
            pairingFailureHint(PairingFailure.START_REJECTED, k),
            pairingFailureHint(PairingFailure.CANCELED_OR_FAILED, k),
            pairingFailureHint(PairingFailure.TIMED_OUT, k),
            pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY, k),
            renderBoardCopy(DETECTIONS_SUBSCRIBE_FAILED_TEMPLATE, k),
        )
        assertEquals(listOf(
            "Android could not start pairing. keep the beacon powered on and nearby, then try again.",
            "pairing was canceled or failed. keep the beacon powered on and nearby, approve Android's pairing request if it appears, then try again.",
            "pairing took too long. keep the beacon powered on and nearby, approve Android's pairing request if it appears, then try again.",
            "Android connected, but the beacon's secure link did not become ready. keep it powered on and nearby, then try again.",
            "this beacon connected but will not send detections. turn it off and on, then try again.",
        ), hints(null))
        assertEquals(listOf(
            "Android could not start pairing. keep the OUI-Spy powered on and nearby, then try again.",
            "pairing was canceled or failed. keep the OUI-Spy powered on and nearby, approve Android's pairing request if it appears, then try again.",
            "pairing took too long. keep the OUI-Spy powered on and nearby, approve Android's pairing request if it appears, then try again.",
            "Android connected, but the OUI-Spy's secure link did not become ready. keep it powered on and nearby, then try again.",
            "this OUI-Spy connected but will not send detections. turn it off and on, then try again.",
        ), hints(BoardKind.OUI_SPY))
        assertEquals(hints(null), hints(BoardKind.BEACON))
        assertEquals(
            "Android connected, but the Mesh-Detect's secure link did not become ready. keep it powered on and nearby, then try again.",
            pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY, BoardKind.MESH_DETECT))
        for (k in all) for (h in hints(k)) assertFalse(h, h.contains("board"))
    }

    @Test fun scanStartFailurePerKind() {
        assertEquals("this phone does not support the Bluetooth scan needed to find your beacon.",
            scanStartFailureHint(featureUnsupported = true, kind = null))
        assertEquals("this phone does not support the Bluetooth scan needed to find your OUI-Spy.",
            scanStartFailureHint(featureUnsupported = true, kind = BoardKind.OUI_SPY))
        // The ordinary arm names no board, so the kind cannot move it.
        assertEquals(scanStartFailureHint(false, null), scanStartFailureHint(false, BoardKind.MESH_DETECT))
        for (k in all) assertFalse(scanStartFailureHint(false, k).lowercase().contains("no beacons found"))
    }

    @Test fun otaLinesNameTheBoardBeingUpdated() {
        assertEquals("reconnect to the beacon before retrying the board update. this clears any delayed update replies from the previous attempt.",
            renderBoardCopy(OTA_RECONNECT_BEFORE_RETRY_TEMPLATE, null))
        assertEquals("reconnect to the OUI-Spy before retrying the board update. this clears any delayed update replies from the previous attempt.",
            renderBoardCopy(OTA_RECONNECT_BEFORE_RETRY_TEMPLATE, BoardKind.OUI_SPY))
        assertEquals("reconnect to the beacon before retrying the co-processor update. this clears any delayed update replies from the previous attempt.",
            renderBoardCopy(NRF_DFU_RECONNECT_BEFORE_RETRY_TEMPLATE, null))
        assertEquals("reconnect to the Mesh-Detect before retrying the co-processor update. this clears any delayed update replies from the previous attempt.",
            renderBoardCopy(NRF_DFU_RECONNECT_BEFORE_RETRY_TEMPLATE, BoardKind.MESH_DETECT))
        // The two quarantine lines are one sentence apart from the update they name.
        assertEquals(OTA_RECONNECT_BEFORE_RETRY_TEMPLATE,
            NRF_DFU_RECONNECT_BEFORE_RETRY_TEMPLATE.replace("the co-processor update", "the board update"))
        assertEquals("Sending the update to your beacon.", renderBoardCopy(AcabLinkService.OTA_HOLD_TEXT_TEMPLATE, null))
        assertEquals("Sending the update to your Mesh-Detect.",
            renderBoardCopy(AcabLinkService.OTA_HOLD_TEXT_TEMPLATE, BoardKind.MESH_DETECT))
    }

    @Test fun noRenderingCarriesAnEmDashOrAnEnDash() {
        val templates = listOf(
            PAIRING_START_REJECTED_TEMPLATE, PAIRING_CANCELED_OR_FAILED_TEMPLATE, PAIRING_TIMED_OUT_TEMPLATE,
            PAIRING_SECURE_LINK_NOT_READY_TEMPLATE, DETECTIONS_SUBSCRIBE_FAILED_TEMPLATE,
            SCAN_UNSUPPORTED_TEMPLATE, AcabBleManager.PAIR_WINDOW_HINT_TEMPLATE, RememberedBoardCopy.LABEL_TEMPLATE,
            OTA_RECONNECT_BEFORE_RETRY_TEMPLATE, NRF_DFU_RECONNECT_BEFORE_RETRY_TEMPLATE,
            AcabLinkService.OTA_HOLD_TEXT_TEMPLATE,
        )
        for (t in templates) for (k in all) {
            val r = renderBoardCopy(t, k)
            assertFalse(r, r.contains('—') || r.contains('–'))
            assertFalse("unfilled token in $r", r.contains('{'))
        }
    }
}
