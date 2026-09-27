package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 2026-09-26 review P3-6: in the wide two-pane Log (840dp and up) a row tap only fills the pane
 *  beside the list, so the rows draw no disclosure chevron and hold no slot for one; compact rows
 *  keep the select-mode rule (no chevron, slot held so the signal column does not jump). FAILS
 *  IF a wide row promises a drill-in, or a compact select-mode row lets its signal column jump. */
class LogWideRowChevronTest {
    @Test
    fun aWideRowNeverDrawsAChevron() {
        assertFalse(logRowShowsChevron(selectMode = false, wide = true))
        assertFalse(logRowShowsChevron(selectMode = true, wide = true))
    }

    @Test
    fun aCompactRowKeepsTheSelectModeRule() {
        assertTrue(logRowShowsChevron(selectMode = false, wide = false))
        assertFalse(logRowShowsChevron(selectMode = true, wide = false))
        // The one-argument form the existing suite pins still reads compact.
        assertTrue(logRowShowsChevron(selectMode = false))
    }

    /** The empty slot is held only where a mode flip could move the signal column: compact
     *  select mode. A wide row never draws the chevron, so it never holds the slot. */
    @Test
    fun theSlotIsHeldOnlyInCompactSelectMode() {
        assertTrue(logRowKeepsChevronSlot(selectMode = true, wide = false))
        assertFalse(logRowKeepsChevronSlot(selectMode = false, wide = false))
        assertFalse(logRowKeepsChevronSlot(selectMode = true, wide = true))
        assertFalse(logRowKeepsChevronSlot(selectMode = false, wide = true))
    }
}
