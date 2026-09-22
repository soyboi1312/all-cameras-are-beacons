package tech.acab.app.ble

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The remembered board: the app half of "Level 1" privacy. A later firmware stops advertising its
 * name and service UUID to a bonded owner, so the picker must list the owner's board from memory.
 * These pin the three pure rules the manager and picker run through (rememberedBoardAfterReady,
 * rememberedBoardLookup, mergeRememberedRow). No prefs, no BluetoothDevice instances: the merge is
 * generic over its row type for exactly this reason. iOS twin rules: ios/Beacons/BLE/RememberedBoard.swift.
 */
class RememberedBoardTest {

    private val a = "E8:3D:C1:00:00:01"
    private val b = "E8:3D:C1:00:00:02"

    // ---- REMEMBER ----

    @Test fun firstBondedReadyIsRemembered() {
        assertEquals(RememberedBoard(a, "ACAB-01"),
            rememberedBoardAfterReady(null, a, "ACAB-01", bonded = true, demoMode = false))
    }

    @Test fun demoNeverRemembersOrReplaces() {
        assertNull(rememberedBoardAfterReady(null, a, "ACAB-01", bonded = true, demoMode = true))
        val held = RememberedBoard(a, "ACAB-01")
        assertSame(held, rememberedBoardAfterReady(held, b, "ACAB-02", bonded = true, demoMode = true))
    }

    @Test fun unbondedOrAddresslessReadyKeepsWhatWasHeld() {
        assertNull(rememberedBoardAfterReady(null, a, "ACAB-01", bonded = false, demoMode = false))
        val held = RememberedBoard(a, "ACAB-01")
        assertSame(held, rememberedBoardAfterReady(held, b, "ACAB-02", bonded = false, demoMode = false))
        assertSame(held, rememberedBoardAfterReady(held, null, "ACAB-02", bonded = true, demoMode = false))
        assertSame(held, rememberedBoardAfterReady(held, "  ", "ACAB-02", bonded = true, demoMode = false))
    }

    @Test fun sameBoardReconnectIsNoWrite() {
        // Identity, not just equality: the caller skips the prefs write on `next === held`, so an
        // auto-reconnect or OTA reboot-reconnect to the same board must not look like a change.
        val held = RememberedBoard(a, "ACAB-01")
        assertSame(held, rememberedBoardAfterReady(held, a, "ACAB-01", bonded = true, demoMode = false))
        assertSame(held, rememberedBoardAfterReady(held, a.lowercase(), "ACAB-01", bonded = true, demoMode = false))
        // A nameless link to the same board keeps the remembered name rather than blanking it.
        assertSame(held, rememberedBoardAfterReady(held, a, null, bonded = true, demoMode = false))
        assertSame(held, rememberedBoardAfterReady(held, a, "", bonded = true, demoMode = false))
    }

    @Test fun sameBoardRenamedUpdatesTheName() {
        val held = RememberedBoard(a, "ACAB-01")
        assertEquals(RememberedBoard(a, "ACAB-99"),
            rememberedBoardAfterReady(held, a, "ACAB-99", bonded = true, demoMode = false))
    }

    @Test fun aDifferentBoardReplacesAndDoesNotInheritTheOldName() {
        val held = RememberedBoard(a, "ACAB-01")
        assertEquals(RememberedBoard(b, "ACAB-02"),
            rememberedBoardAfterReady(held, b, "ACAB-02", bonded = true, demoMode = false))
        assertEquals(RememberedBoard(b, REMEMBERED_BOARD_FALLBACK_NAME),
            rememberedBoardAfterReady(held, b, null, bonded = true, demoMode = false))
    }

    // ---- FORGET / SHOW lookup ----

    @Test fun bondedIsShown() {
        assertEquals(RememberedBoardLookup.SHOW,
            rememberedBoardLookup(true, true, BluetoothDevice.BOND_BONDED, true))
    }

    @Test fun bondRemovedInSettingsIsForgotten() {
        assertEquals(RememberedBoardLookup.FORGET,
            rememberedBoardLookup(true, true, BluetoothDevice.BOND_NONE, false))
    }

    @Test fun unknownStatesKeepTheMemoryButListNothing() {
        // Radio off: some stacks report BOND_NONE for every device, which must not erase the owner.
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(true, false, BluetoothDevice.BOND_NONE, false))
        // No permission: nothing can be asked, nothing is decided.
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(false, true, BluetoothDevice.BOND_NONE, false))
        // A failed query on either side.
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(true, true, null, false))
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(true, true, BluetoothDevice.BOND_NONE, null))
        // The two answers disagree: never forget on one flaky answer.
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(true, true, BluetoothDevice.BOND_NONE, true))
        // Mid-bond is neither shown nor forgotten.
        assertEquals(RememberedBoardLookup.HIDE_KEEP,
            rememberedBoardLookup(true, true, BluetoothDevice.BOND_BONDING, true))
    }

    @Test fun rememberForgetRememberTransition() {
        var held: RememberedBoard? = rememberedBoardAfterReady(null, a, "ACAB-01", true, false)
        assertEquals(a, held?.address)
        if (rememberedBoardLookup(true, true, BluetoothDevice.BOND_NONE, false) ==
            RememberedBoardLookup.FORGET) held = null
        assertNull(held)
        held = rememberedBoardAfterReady(held, b, "ACAB-02", true, false)
        assertEquals(RememberedBoard(b, "ACAB-02"), held)
    }

    // ---- SHOW merge ----

    private data class Row(val address: String, val name: String, val rssi: Int,
                           val owned: Boolean = false, val seen: Boolean = true)

    private fun merge(scanned: List<Row>, remembered: Row?) = mergeRememberedRow(
        scanned = scanned,
        remembered = remembered,
        rememberedAddress = remembered?.address,
        addressOf = { it.address },
        asOwned = { it.copy(owned = true) },
    )

    private val mine = Row(a, "my board", Int.MIN_VALUE, owned = true, seen = false)

    @Test fun nothingRememberedLeavesTheScanAlone() {
        val scanned = listOf(Row(b, "ACAB-02", -60))
        assertSame(scanned, merge(scanned, null))
    }

    @Test fun unseenRememberedBoardLeadsTheList() {
        val scanned = listOf(Row(b, "ACAB-02", -60))
        assertEquals(listOf(mine) + scanned, merge(scanned, mine))
        assertEquals(listOf(mine), merge(emptyList(), mine))
    }

    @Test fun scannedRememberedBoardMergesIntoOneLeadingRow() {
        val other = Row(b, "ACAB-02", -50)
        val third = Row("E8:3D:C1:00:00:03", "ACAB-03", -80)
        val heard = Row(a, "ACAB-01", -70)
        val out = merge(listOf(other, heard, third), mine)
        assertEquals(3, out.size)
        assertEquals(1, out.count { it.address.equals(a, ignoreCase = true) })
        // It leads (as on iOS) with its live name and RSSI and the owned mark; the rest keep order.
        assertEquals(Row(a, "ACAB-01", -70, owned = true, seen = true), out[0])
        assertEquals(listOf(other, third), out.drop(1))
    }

    @Test fun mergeMatchesAddressesCaseInsensitively() {
        val heard = Row(a.lowercase(), "ACAB-01", -70)
        val out = merge(listOf(heard), mine)
        assertEquals(1, out.size)
        assertTrue(out[0].owned && out[0].seen)
    }

    @Test fun blankRememberedAddressMergesNothing() {
        val scanned = listOf(Row(a, "ACAB-01", -70))
        val out = mergeRememberedRow(scanned, mine, " ", { it.address }, { it.copy(owned = true) })
        assertSame(scanned, out)
    }

    @Test fun sharedCopyMatchesIos() {
        // ios/Beacons/BLE/RememberedBoard.swift RememberedBoardCopy pins the same literals; a drift
        // here is cross-platform drift.
        assertEquals("your beacon", RememberedBoardCopy.LABEL)
        assertEquals("no live signal \u00B7 tap to connect", RememberedBoardCopy.NO_SIGNAL)
        assertEquals("tap to connect", RememberedBoardCopy.SEEN)
        assertEquals("ACAB-01 \u00B7 no live signal \u00B7 tap to connect",
            RememberedBoardCopy.subtitle("ACAB-01", advertSeen = false))
        assertEquals("tap to connect", RememberedBoardCopy.subtitle(" ", advertSeen = true))
    }
}
