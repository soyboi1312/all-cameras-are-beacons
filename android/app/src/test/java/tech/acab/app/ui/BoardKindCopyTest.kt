package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.RememberedBoardCopy
import tech.acab.app.ble.renderBoardCopy
import tech.acab.app.ble.resolveScreenKind
import tech.acab.app.debugBoardKindExtra

/**
 * The startup screen, the checklist and the Beacon tab name the board the owner holds: every
 * templated surface renders the OUI-Spy naming table's Android column byte for byte, per kind,
 * with null (unknown) reading exactly as beacon. The buttons that name no device, and the ones
 * that name the product line ("Scan for Beacons"), do not move. Also the picker row rules, the
 * hero title, the checklist's kind, the THIS PHONE group labels and the DEBUG extra parse.
 * iOS twin: ios/BeaconsTests/BoardKindTests.swift (the ConnectCopy renderings).
 */
class BoardKindCopyTest {

    private val spy = BoardKind.OUI_SPY
    private val mesh = BoardKind.MESH_DETECT
    private val all = listOf(null, BoardKind.BEACON, spy, mesh)

    private fun r(t: String, k: BoardKind?) = renderBoardCopy(t, k)

    @Test fun connectScreenBeaconRenderings() {
        val k: BoardKind? = null
        assertEquals("power on your beacon and keep it nearby.", r(CONNECT_SETUP_TEMPLATE, k))
        assertEquals("connects your phone to your beacon. the beacon does the listening, not your phone.",
            r(CONNECT_RATIONALE_REST_TEMPLATE, k))
        assertEquals("turn on Bluetooth to find your beacon.", r(CONNECT_BLUETOOTH_OFF_TEMPLATE, k))
        assertEquals("allow Nearby devices for beacons in Settings. it is used only to find and connect to your beacon.",
            r(NEARBY_DENIED_SETTINGS_TEMPLATE, k))
        assertEquals("Nearby devices permission was not allowed. it is used only to find and connect to your beacon. the beacon does the listening.",
            r(NEARBY_DENIED_RETRY_TEMPLATE, k))
        assertEquals("looking for your beacon…", r(CONNECT_LOOKING_TEMPLATE, k))
        assertEquals("no beacons found. make sure your beacon is powered on and nearby, then scan again.",
            r(CONNECT_NONE_FOUND_TEMPLATE, k))
        assertEquals("tap your beacon, then accept Android's pairing request if it appears. pairing encrypts the detection link to this phone.",
            r(CONNECT_SECURE_PAIRING_NOTE_TEMPLATE, k))
        assertEquals("keep your beacon powered on and nearby. approve Android's pairing request if it appears.",
            r(CONNECTING_BODY_TEMPLATE, k))
        assertEquals("reconnecting to your beacon…", r(RECONNECT_PANEL_TITLE_TEMPLATE, k))
        assertEquals("it reconnects on its own when the beacon is back in range, even in the background. keep waiting, or stop to scan for a different beacon.",
            r(RECONNECT_PANEL_BODY_TEMPLATE, k))
        assertEquals("What your beacon can hear", r(CONNECT_HEARS_TEMPLATE, k))
        assertEquals("show what your beacon can hear", r(CONNECT_HEARS_SHOW_TEMPLATE, k))
        assertEquals("hide what your beacon can hear", r(CONNECT_HEARS_HIDE_TEMPLATE, k))
        assertEquals("history on this phone · browse and export, no beacon needed", r(CONNECT_SAVED_LOG_KICKER_TEMPLATE, k))
        assertEquals("passive detection only. the beacon never jams, spoofs, or interferes.", r(CONNECT_SCOPE_FOOTNOTE_TEMPLATE, k))
        assertEquals("the beacon is rebooting into the new firmware. keep the app open, it reconnects on its own.",
            r(OTA_WAIT_REBOOTING_TEMPLATE, k))
        assertEquals("this can take up to a minute. don't unplug the beacon.", r(OTA_WAIT_NOTE_TEMPLATE, k))
        assertEquals("Live Mode keeps a private counter in the status bar and on the lock screen while your beacon is connected. Android may ask to allow notifications next.",
            r(LIVE_PERMISSION_BODY_TEMPLATE, k))
        assertEquals("reconnecting to your beacon", r(RECONNECT_BANNER_TITLE_TEMPLATE, k))
        assertEquals("your open screen and capture are preserved.", RECONNECT_BANNER_BODY)
        assertEquals("connection did not finish", CONNECTION_HINT_TITLE)
        // The help row's line names no board, and is the one settled string on both apps.
        assertEquals("offline help for power, permissions, pairing, and connection recovery",
            CONNECT_SETUP_HELP_SUBTITLE)
    }

    @Test fun connectScreenOuiSpyAndMeshDetectRenderings() {
        assertEquals("power on your OUI-Spy and keep it nearby.", r(CONNECT_SETUP_TEMPLATE, spy))
        assertEquals("power on your Mesh-Detect and keep it nearby.", r(CONNECT_SETUP_TEMPLATE, mesh))
        assertEquals("looking for your OUI-Spy…", r(CONNECT_LOOKING_TEMPLATE, spy))
        assertEquals("no OUI-Spy found. make sure your OUI-Spy is powered on and nearby, then scan again.",
            r(CONNECT_NONE_FOUND_TEMPLATE, spy))
        assertEquals("no Mesh-Detect found. make sure your Mesh-Detect is powered on and nearby, then scan again.",
            r(CONNECT_NONE_FOUND_TEMPLATE, mesh))
        assertEquals("passive detection only. the OUI-Spy never jams, spoofs, or interferes.",
            r(CONNECT_SCOPE_FOOTNOTE_TEMPLATE, spy))
        assertEquals("passive detection only. the Mesh-Detect never jams, spoofs, or interferes.",
            r(CONNECT_SCOPE_FOOTNOTE_TEMPLATE, mesh))
        assertEquals("What your Mesh-Detect can hear", r(CONNECT_HEARS_TEMPLATE, mesh))
        assertEquals("show what your OUI-Spy can hear", r(CONNECT_HEARS_SHOW_TEMPLATE, spy))
        assertEquals("hide what your OUI-Spy can hear", r(CONNECT_HEARS_HIDE_TEMPLATE, spy))
        assertEquals("show what your Mesh-Detect can hear", r(CONNECT_HEARS_SHOW_TEMPLATE, mesh))
        assertEquals("hide what your Mesh-Detect can hear", r(CONNECT_HEARS_HIDE_TEMPLATE, mesh))
        assertEquals("history on this phone · browse and export, no OUI-Spy needed",
            r(CONNECT_SAVED_LOG_KICKER_TEMPLATE, spy))
        assertEquals("keep your Mesh-Detect powered on and nearby. approve Android's pairing request if it appears.",
            r(CONNECTING_BODY_TEMPLATE, mesh))
        assertEquals("it reconnects on its own when the OUI-Spy is back in range, even in the background. keep waiting, or stop to scan for a different OUI-Spy.",
            r(RECONNECT_PANEL_BODY_TEMPLATE, spy))
        assertEquals("reconnecting to your OUI-Spy", r(RECONNECT_BANNER_TITLE_TEMPLATE, spy))
        assertEquals("this can take up to a minute. don't unplug the Mesh-Detect.", r(OTA_WAIT_NOTE_TEMPLATE, mesh))
        assertEquals("Nearby devices permission was not allowed. it is used only to find and connect to your OUI-Spy. the OUI-Spy does the listening.",
            r(NEARBY_DENIED_RETRY_TEMPLATE, spy))
        assertEquals("desert mode ended on the OUI-Spy, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            desertRestoreOffer(spy))
        assertEquals("desert mode ended on the beacon, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode.",
            desertRestoreOffer(null))
    }

    @Test fun everyTemplateRendersCleanForEveryKind() {
        val templates = listOf(
            CONNECT_SETUP_TEMPLATE, CONNECT_RATIONALE_REST_TEMPLATE, CONNECT_BLUETOOTH_OFF_TEMPLATE,
            NEARBY_DENIED_SETTINGS_TEMPLATE, NEARBY_DENIED_RETRY_TEMPLATE, CONNECT_LOOKING_TEMPLATE,
            CONNECT_NONE_FOUND_TEMPLATE, CONNECT_SECURE_PAIRING_NOTE_TEMPLATE, CONNECTING_BODY_TEMPLATE,
            RECONNECT_PANEL_TITLE_TEMPLATE, RECONNECT_PANEL_BODY_TEMPLATE, CONNECT_HEARS_TEMPLATE,
            CONNECT_HEARS_SHOW_TEMPLATE, CONNECT_HEARS_HIDE_TEMPLATE, CONNECT_SAVED_LOG_KICKER_TEMPLATE,
            CONNECT_SCOPE_FOOTNOTE_TEMPLATE, OTA_WAIT_REBOOTING_TEMPLATE, OTA_WAIT_NOTE_TEMPLATE,
            LIVE_PERMISSION_BODY_TEMPLATE, RECONNECT_BANNER_TITLE_TEMPLATE, DESERT_RESTORE_OFFER_TEMPLATE,
            FirstRunTour.CHECKLIST_TITLE_TEMPLATE, FirstRunTour.CHECKLIST_SUBTITLE_TEMPLATE,
            FirstRunTour.CHECKLIST_PREVIEW_NOTE_TEMPLATE, FirstRunTour.LOCATION_RATIONALE_TEMPLATE,
        )
        for (t in templates) {
            // Each template names the board at least once, so a kind can move it.
            assertFalse("template names no board: $t", r(t, spy) == r(t, null))
            assertEquals(r(t, BoardKind.BEACON), r(t, null))
            for (k in all) {
                val out = r(t, k)
                assertFalse("unfilled token in $out", out.contains('{'))
                assertFalse("dash in $out", out.contains('—') || out.contains('–'))
            }
        }
    }

    @Test fun buttonsDoNotMove() {
        // The scan button names the product line for everyone (owner decision), and it takes no kind.
        assertEquals("Scan for Beacons", scanButtonTitle(isScanning = false, granted = true))
        assertEquals("Continue", scanButtonTitle(isScanning = false, granted = false))
        assertEquals("Stop Scanning", scanButtonTitle(isScanning = true, granted = true))
    }

    @Test fun pickerRowsNameTheirOwnBoard() {
        // The remembered row reads its live hint before its stored kind (a reflashed board reads
        // by what it advertises now), and its stored kind when it advertises no name (stealth) or
        // was not heard; a scanned row reads only its hint; no hint reads beacon.
        assertEquals(BoardKind.BEACON, pickerRowKind(owned = true, kindHint = BoardKind.BEACON, rememberedKind = spy))
        assertEquals(spy, pickerRowKind(owned = true, kindHint = spy, rememberedKind = BoardKind.BEACON))
        assertEquals(spy, pickerRowKind(owned = true, kindHint = null, rememberedKind = spy))
        assertEquals(mesh, pickerRowKind(owned = true, kindHint = mesh, rememberedKind = null))
        assertEquals(mesh, pickerRowKind(owned = false, kindHint = mesh, rememberedKind = spy))
        assertNull(pickerRowKind(owned = false, kindHint = null, rememberedKind = spy))
        assertEquals("beacon", scannedRowTitle(null))
        assertEquals("beacon", scannedRowTitle(BoardKind.BEACON))
        assertEquals("OUI-Spy", scannedRowTitle(spy))
        assertEquals("Mesh-Detect", scannedRowTitle(mesh))
    }

    @Test fun pickerRowDrawsEveryFactoryAddress() {
        // One address per value of the first octet's top two bits (00, 01, 10, 11). The board's
        // address is public, so those bits carry no meaning and every one draws. 01 is the bucket
        // an earlier rule hid as "resolvable private".
        for (address in listOf("1c:9d:c2:00:00:01", "48:27:e2:00:00:01", "a0:76:4e:00:00:01", "e8:3d:c1:00:00:01")) {
            assertEquals(address, pickerAddressLine(address))
        }
        // The DEBUG stand-in's placeholder address is the one value that draws no line.
        assertNull(pickerAddressLine(AcabBleManager.DEBUG_REMEMBERED_ADDRESS))
    }

    @Test fun heroTitlePerKind() {
        assertEquals("All Cameras Are Beacons", boardHeroTitle(null))
        assertEquals("All Cameras Are Beacons", boardHeroTitle(BoardKind.BEACON))
        assertEquals("OUI-Spy", boardHeroTitle(spy))
        assertEquals("Mesh-Detect", boardHeroTitle(mesh))
    }

    @Test fun checklistNamesTheConnectedBoard() {
        // Sample data reads only its own canned label ("beacon board" in release), never a real
        // board's target or remembered kind.
        assertEquals(BoardKind.BEACON,
            checklistBoardKind(demo = true, firmwareLabel = "beacon board", targetKind = spy, rememberedKind = spy))
        assertNull(checklistBoardKind(demo = true, firmwareLabel = null, targetKind = spy, rememberedKind = spy))
        assertEquals(spy, checklistBoardKind(false, "ACAB-ouispy", BoardKind.BEACON, null))
        // No frame yet: the connect target's kind, then (a replay with no link) the remembered one.
        assertEquals(mesh, checklistBoardKind(false, null, mesh, spy))
        assertEquals(spy, checklistBoardKind(false, null, null, spy))
        assertNull(checklistBoardKind(false, null, null, null))

        assertEquals("your OUI-Spy is listening", r(FirstRunTour.CHECKLIST_TITLE_TEMPLATE, spy))
        assertEquals("your beacon is listening", r(FirstRunTour.CHECKLIST_TITLE_TEMPLATE, null))
        assertEquals("detection is already active. these optional phone and Mesh-Detect features can be changed later under Beacon.",
            r(FirstRunTour.CHECKLIST_SUBTITLE_TEMPLATE, mesh))
        assertEquals("preview: this is what you see after your OUI-Spy connects.",
            r(FirstRunTour.CHECKLIST_PREVIEW_NOTE_TEMPLATE, spy))
        assertEquals("ready to start with this OUI-Spy", checklistLiveModeDetail(FinishSetupLiveState.WAITING, spy))
        assertEquals("ready to start with this beacon", checklistLiveModeDetail(FinishSetupLiveState.WAITING, null))
        assertEquals("on; the Mesh-Detect retains hits while this phone is away", checklistBufferDetail(true, mesh))
        assertEquals("not known until your OUI-Spy reports it", checklistBufferDetail(null, spy))
        // The arms that name the tab, not the board, never move.
        assertEquals(checklistBufferDetail(false, null), checklistBufferDetail(false, spy))
        assertEquals(checklistLiveModeDetail(FinishSetupLiveState.OFF, null),
            checklistLiveModeDetail(FinishSetupLiveState.OFF, spy))
    }

    @Test fun thisPhoneGroupsCarryTheirLabels() {
        val board = beaconRowGroups(beaconRows(BeaconSegment.BOARD, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(listOf(null, null, "DETECTION", "ON THE BOARD"), board.map(::beaconGroupHeaderLabel))
        val phone = beaconRowGroups(beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(listOf("PREFERENCES", "SUPPORT", null), phone.map(::beaconGroupHeaderLabel))
        // The sample tour drops rows, not the labels.
        val demoPhone = beaconRowGroups(beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
            demo = true, improveAvailable = false, hasSavedLog = false))
        assertEquals(listOf("PREFERENCES", "SUPPORT"), demoPhone.map(::beaconGroupHeaderLabel))
    }

    @Test fun reflashedRememberedBoardReadsByItsLiveAdvertBeforeConnect() {
        // The screen's remembered kind is the owned row's kind (pickerRowKind), so a live advert
        // that names another image moves the whole startup screen, in either direction.
        fun screen(hint: BoardKind?, stored: BoardKind?) = resolveScreenKind(
            targetActive = false, targetKind = null,
            rememberedKind = pickerRowKind(owned = true, kindHint = hint, rememberedKind = stored),
            rowKinds = listOf(pickerRowKind(owned = true, kindHint = hint, rememberedKind = stored)),
        )
        // Stored beacon, now advertising as an OUI-Spy.
        assertEquals(spy, screen(hint = spy, stored = BoardKind.BEACON))
        assertEquals("your OUI-Spy",
            RememberedBoardCopy.label(pickerRowKind(true, spy, BoardKind.BEACON)))
        // Stored OUI-Spy, now advertising as a beacon.
        assertEquals(BoardKind.BEACON, screen(hint = BoardKind.BEACON, stored = spy))
        assertEquals("your beacon",
            RememberedBoardCopy.label(pickerRowKind(true, BoardKind.BEACON, spy)))
        // The stealth advert (no name) and an unheard board keep the stored kind.
        assertEquals(mesh, screen(hint = null, stored = mesh))
        // A connect in flight reads its target, whatever the rows say.
        assertEquals(mesh, resolveScreenKind(true, mesh, spy, listOf(spy)))
    }

    @Test fun locationRationaleNamesTheChecklistBoard() {
        assertEquals("Location is optional. it shows where your phone heard detections on Map, and lets the beacon label buffered hits with the last location your phone shared over encrypted Bluetooth. choose Not Now and detection still works. nothing is uploaded automatically.",
            r(FirstRunTour.LOCATION_RATIONALE_TEMPLATE, null))
        assertEquals("Location is optional. it shows where your phone heard detections on Map, and lets the OUI-Spy label buffered hits with the last location your phone shared over encrypted Bluetooth. choose Not Now and detection still works. nothing is uploaded automatically.",
            r(FirstRunTour.LOCATION_RATIONALE_TEMPLATE, spy))
    }

    @Test fun offlineSyncBannerNamesTheBoard() {
        assertEquals("1 buffered detection couldn't be replayed from the beacon", offlineSyncMessage(0, 1, null))
        assertEquals("3 buffered detections couldn't be replayed from the OUI-Spy", offlineSyncMessage(0, 3, spy))
        assertEquals("1 buffered detection couldn't be replayed from the Mesh-Detect", offlineSyncMessage(0, 1, mesh))
        // The arms that name no board do not move with the kind.
        for (k in all) {
            assertEquals("1 detection recorded while you were away", offlineSyncMessage(1, 0, k))
            assertEquals("5 detections recorded while you were away", offlineSyncMessage(5, 0, k))
            assertEquals("2 detections recorded while you were away (1 more couldn't be replayed)",
                offlineSyncMessage(2, 1, k))
        }
    }

    @Test fun debugExtraAcceptsOnlyTheRawValues() {
        assertEquals(spy, debugBoardKindExtra("ouiSpy"))
        assertEquals(mesh, debugBoardKindExtra("meshDetect"))
        assertEquals(BoardKind.BEACON, debugBoardKindExtra("beacon"))
        assertNull(debugBoardKindExtra(null))
        assertNull(debugBoardKindExtra(""))
        assertNull(debugBoardKindExtra("OUI-Spy"))
        assertNull(debugBoardKindExtra("ouispy"))
    }
}
