package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 2026-09-26 review P3-7: a Beacon card's header kicker is dropped when it only repeats the
 *  pushed page's title, case aside, and kept where a page holds more than one card or the kicker
 *  says more than the title. FAILS IF the comparison becomes case-sensitive (SCAN RADIOS would
 *  draw under "Scan radios" again), or a null page title (the root list, the pre-connect
 *  AlertRestorePanel) is read as a repeat and hides every kicker there. */
class BeaconCardKickerTest {
    @Test
    fun aKickerThatRepeatsThePageTitleIsSkipped() {
        assertTrue(kickerRepeatsPageTitle("SCAN RADIOS", "Scan radios"))
        assertTrue(kickerRepeatsPageTitle("ALERTS", "Alerts"))
        assertTrue(kickerRepeatsPageTitle("BOARD LED", "Board LED"))
        assertTrue(kickerRepeatsPageTitle("FIRMWARE", "Firmware"))
        assertTrue(kickerRepeatsPageTitle("DISPLAY", "Display"))
        assertTrue(kickerRepeatsPageTitle("ABOUT", "About"))
        assertTrue(kickerRepeatsPageTitle("LIVE MODE", "Live Mode"))
    }

    /** Two cards under one title (Desert mode + buffer), or a kicker that says more than the
     *  title (PHONE NOTIFICATIONS under "Notifications"), keep their kickers. */
    @Test
    fun aKickerThatSaysMoreThanTheTitleStays() {
        assertFalse(kickerRepeatsPageTitle("DESERT MODE", "Desert mode + buffer"))
        assertFalse(kickerRepeatsPageTitle("OFFLINE BUFFER", "Desert mode + buffer"))
        assertFalse(kickerRepeatsPageTitle("PHONE NOTIFICATIONS", "Notifications"))
    }

    /** Off a pushed page there is no title to repeat, so the kicker always draws. */
    @Test
    fun offAPushedPageTheKickerAlwaysDraws() {
        assertFalse(kickerRepeatsPageTitle("ALERTS", null))
    }
}
