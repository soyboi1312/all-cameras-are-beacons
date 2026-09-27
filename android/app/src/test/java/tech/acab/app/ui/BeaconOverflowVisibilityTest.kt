package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 2026-09-26 review P3-9: the Beacon top bar hides its overflow button while the menu would hold
 *  only Exit Sample Data, which the sample banner directly above already carries. FAILS IF the
 *  kebab shows over a one-item sample menu, or hides while it holds Disconnect, Power Off Beacon
 *  or the refresh action folded in at large type. */
class BeaconOverflowVisibilityTest {
    private val sampleItems = beaconOverflowItems(demo = true, connected = false, hasStatus = true,
        boardRev = null, combinedRunning = false, boardControlsAvailable = true)

    @Test
    fun sampleDataHoldsOnlyExitSampleData() {
        assertTrue(sampleItems.size == 1 && sampleItems.single().id == "disconnect")
    }

    @Test
    fun theKebabIsHiddenOverAOneItemSampleMenu() {
        assertFalse(beaconOverflowVisible(sampleItems, refreshFolded = false, demo = true))
    }

    /** At large type the refresh action folds into the menu, so the menu has two items and the
     *  kebab returns, sample data or not. */
    @Test
    fun theFoldedRefreshBringsTheKebabBack() {
        assertTrue(beaconOverflowVisible(sampleItems, refreshFolded = true, demo = true))
    }

    /** A live session's menu holds Disconnect (and Power Off Beacon on a rev-B board); the kebab
     *  is never hidden there, one item or two. */
    @Test
    fun aLiveSessionKeepsTheKebab() {
        val revA = beaconOverflowItems(demo = false, connected = true, hasStatus = true,
            boardRev = "A", combinedRunning = false, boardControlsAvailable = true)
        val revB = beaconOverflowItems(demo = false, connected = true, hasStatus = true,
            boardRev = "B", combinedRunning = false, boardControlsAvailable = true)
        assertTrue(beaconOverflowVisible(revA, refreshFolded = false, demo = false))
        assertTrue(beaconOverflowVisible(revB, refreshFolded = false, demo = false))
        assertTrue(revB.any { it.id == "poweroff" })
    }
}
