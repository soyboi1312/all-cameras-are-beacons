package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A phone with no stored alert mode must never change whether the board makes sound on its own.
 *
 * THE DEFECT (security review 2026-09-29). With nothing stored, the in-memory mode defaulted to
 * BUZZER and finishReady pushed it, so a reinstall (allowBackup=false makes every reinstall one),
 * cleared data or a second phone un-muted a board the user had muted elsewhere, Desert included,
 * and the board saved that to its flash. The re-review found a second way in: Desert's APP-origin
 * mute and restore stored a mode on such a phone, and a mesh board left the BUZZER placeholder
 * unmirrored for Desert to capture.
 *
 * WHAT THIS SUITE DOES NOT COVER. AcabBleManager needs a Context, so this side pins the pure rules
 * the manager calls (connectBuzzerWrite, mirroredAlertMode, desertEnableConfig, desertDisableConfig,
 * alertModeKeptFromLegacyStore), not the manager itself. In particular the init-time upgrade's key
 * removal and flag write, the per-link hold's clears, and the Config object setDesert actually
 * sends are not covered here. The iOS twin,
 * ConnectBuzzerPolicyTests.swift, drives those through the real manager; the vectors below are its
 * pure-rule vectors, one for one.
 */
class ConnectBuzzerPolicyTest {

    /** No stored mode writes nothing, whatever mode is on screen; a stored mode writes exactly its
     *  own buzzer state. Reverting to "write mode == BUZZER" fails the first two lines. */
    @Test
    fun connectWritesOnlyAStoredMode() {
        assertNull(connectBuzzerWrite(false, AlertMode.BUZZER))
        assertNull(connectBuzzerWrite(false, AlertMode.SILENT))
        assertEquals(true, connectBuzzerWrite(true, AlertMode.BUZZER))
        assertEquals(false, connectBuzzerWrite(true, AlertMode.VIBRATE))
        assertEquals(false, connectBuzzerWrite(true, AlertMode.SILENT))
    }

    /** A phone with no mode mirrors: sound on reads BUZZER, muted reads SILENT (never VIBRATE).
     *  A stored mode or an app-held mode on this link turns the mirror off. */
    @Test
    fun mirrorRule() {
        assertEquals(AlertMode.BUZZER, mirroredAlertMode(false, false, true))
        assertEquals(AlertMode.SILENT, mirroredAlertMode(false, false, false))
        assertNull(mirroredAlertMode(true, false, true))
        assertNull(mirroredAlertMode(false, true, true))
    }

    /** Desert on and Desert off each go out as ONE Config object, so a link lost between two writes
     *  can neither leave the board in Desert and audible nor drop the restore. */
    @Test
    fun desertWritesCarryTheirBuzzerStateInOneWrite() {
        val muted = desertEnableConfig(true)
        assertTrue(muted.getBoolean("desert"))
        assertFalse(muted.getBoolean("buzzer"))
        assertEquals(2, muted.length())
        val plain = desertEnableConfig(false)
        assertTrue(plain.getBoolean("desert"))
        assertFalse(plain.has("buzzer"))

        val restoreSound = desertDisableConfig(AlertMode.BUZZER)
        assertFalse(restoreSound.getBoolean("desert"))
        assertTrue(restoreSound.getBoolean("buzzer"))
        assertFalse(desertDisableConfig(AlertMode.VIBRATE).getBoolean("buzzer"))
        val noRestore = desertDisableConfig(null)
        assertFalse(noRestore.getBoolean("desert"))
        assertFalse(noRestore.has("buzzer"))
    }

    /** 2.1.0 stored Desert's modes as if they were picks, and only BUZZER can be unpicked. A legacy
     *  BUZZER is dropped once (the phone then mirrors), and so is Desert's forced SILENT beside a
     *  saved BUZZER. Beside a saved VIBRATE, always a hand pick, the SILENT stays so Desert-off
     *  stores the pick. Otherwise legacy SILENT and VIBRATE only ever mute, so they stay. */
    @Test
    fun legacyStoreRule() {
        assertNull(alertModeKeptFromLegacyStore(AlertMode.BUZZER, null))
        assertEquals(AlertMode.VIBRATE, alertModeKeptFromLegacyStore(AlertMode.VIBRATE, null))
        assertEquals(AlertMode.SILENT, alertModeKeptFromLegacyStore(AlertMode.SILENT, null))
        assertNull(alertModeKeptFromLegacyStore(null, null))
        assertNull(alertModeKeptFromLegacyStore(AlertMode.SILENT, AlertMode.BUZZER))
        assertEquals(AlertMode.SILENT, alertModeKeptFromLegacyStore(AlertMode.SILENT, AlertMode.VIBRATE))
    }
}
