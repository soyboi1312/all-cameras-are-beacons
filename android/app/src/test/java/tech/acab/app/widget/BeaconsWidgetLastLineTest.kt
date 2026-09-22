package tech.acab.app.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.R

/** The widget's bottom line is read with the app closed, so no state without a hit may look like
 *  an all-clear. Until 2026-09-20 a connected empty store, a real disconnect and the cold-process
 *  face (the one most people see after a reboot) all drew a green check shield with green text.
 *  The view tints `isHit` lines in the accent and everything else in the dim ink, so these pin the
 *  inputs that decide it. Marking any empty case as a hit, or giving an unknown category the old
 *  check-mark fallback, fails here. iOS twin: WidgetEmptyStateTests. */
class BeaconsWidgetLastLineTest {
    private val now = 1_780_000_000_000L

    @Test
    fun connectedWithNoHitIsNeutralNotAllClear() {
        val line = widgetLastLine("", 0L, connected = true, nowMs = now)
        assertEquals(R.drawable.ic_w_shield, line.icon)
        assertFalse("an empty store is not a hit and must not take the accent", line.isHit)
        assertEquals("no detections", line.text)
    }

    @Test
    fun coldProcessAndRealDisconnectAreNeutral() {
        // Summary.read's fallback when no manager is in the process: ("", 0L, connected = false).
        val line = widgetLastLine("", 0L, connected = false, nowMs = now)
        assertEquals(R.drawable.ic_w_shield, line.icon)
        assertFalse(line.isHit)
        assertEquals("open the app to connect", line.text)
    }

    @Test
    fun aCategoryWithNoDateableTimeStaysNeutral() {
        // lastAt 0 is how the writer marks a row whose only time is a pseudo stamp.
        val line = widgetLastLine("ALPR", 0L, connected = true, nowMs = now)
        assertFalse(line.isHit)
        assertEquals("no detections", line.text)
    }

    @Test
    fun aRealHitShowsItsCategoryAndAge() {
        val line = widgetLastLine("ALPR", now - 5 * 60_000L, connected = true, nowMs = now)
        assertEquals(R.drawable.ic_w_alpr, line.icon)
        assertTrue(line.isHit)
        assertEquals("alpr · 5m ago", line.text)
    }

    @Test
    fun anUnknownCategoryHitGetsTheShieldNeverACheckMark() {
        val line = widgetLastLine("NEARBY", now - 30_000L, connected = true, nowMs = now)
        assertEquals(R.drawable.ic_w_shield, line.icon)
        assertTrue("it is still a hit, so it keeps the accent", line.isHit)
    }
}
