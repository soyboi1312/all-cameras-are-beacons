package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins when the Log's search field and sort chip share a row. Units are dp at density 1, from a
 *  411dp emulator: a 371dp row, a 178dp placeholder at font scale 1.0, 68dp of field chrome, an
 *  8dp gap, a ~61dp STRONGEST label and 45dp of chip chrome (360dp in all). The 178dp hint is
 *  the Space Grotesk 13sp placeholder with its tracking pinned to 0 (LogSearchPlaceholderStyle).
 *  The old rule stacked below 380dp, so it fails the first case. */
class LogSearchSortFitTest {
    private fun fits(row: Float, hint: Float, sortLabel: Float) =
        logSearchFitsBesideSort(row, hint, fieldChromePx = 68f, gapPx = 8f,
            widestSortLabelPx = sortLabel, sortChromePx = 45f)

    @Test
    fun aCommonPhoneAtDefaultTextSharesOneRow() {
        assertTrue(fits(371f, 178f, 61f))
    }

    @Test
    fun largerTextStacksBeforeTheHintWouldBeCut() {
        // font scale 1.15: hint ~205dp, STRONGEST ~70dp.
        assertFalse(fits(371f, 205f, 70f))
    }

    @Test
    fun aNarrowerPhoneStacksEvenAtDefaultText() {
        assertFalse(fits(320f, 178f, 61f))
    }

    @Test
    fun theBoundaryIsInclusiveAndCountsTheGap() {
        // 178 + 68 + 8 + 61 + 45 = 360: fits at exactly 360, not at 359. Dropping the gap, or
        // making the comparison strict, fails one of these.
        assertTrue(fits(360f, 178f, 61f))
        assertFalse(fits(359f, 178f, 61f))
    }

    @Test
    fun theFitRuleMeasuresEverySortTheChipCanShow() {
        // A fake measure: one unit per character. STRONGEST (9) is wider than NEWEST (6), and it
        // must win whichever sort is selected, so the layout cannot flip when the sort changes.
        assertEquals(9, widestSortChipLabel { it.length })
        assertEquals(setOf("NEWEST", "STRONGEST"), LogSort.entries.map(::logSortChipLabel).toSet())
    }

    @Test
    fun theWiderSortLabelDecidesSoToggleNeverFlipsTheLayout() {
        // Measured on STRONGEST: a row that only NEWEST (~41dp) would fit stays stacked.
        assertFalse(fits(345f, 178f, 61f))
        assertTrue(fits(345f, 178f, 41f))
    }
}
