package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The legend card's qualifier line (mapProjectionSummary) is iOS projectionSummary's words and
 *  order, lowercase, so the line reads the same on both phones (decisions R17's open item,
 *  settled with the 2026-09-26 review's P1-2): "N displayed · N retained", then "N markers" only
 *  when the markers and the displayed rows differ or rows were merged, then "N outside display
 *  budget" for rows past the marker cap, then "simplified" when rows were merged. Wrong inputs:
 *  the old "5 DISPLAYED · 5 RETAINED · 1 SIMPLIFIED" (uppercase, no markers clause, the omitted
 *  rows folded into the simplified count). */
class MapProjectionSummaryTest {
    @Test
    fun aOneToOneProjectionNamesOnlyTheTwoCounts() {
        assertEquals("5 displayed · 5 retained",
            mapProjectionSummary(displayed = 5, retained = 5, markers = 5, simplifiedRows = 0, omittedRows = 0))
        assertEquals("3 displayed · 9 retained",
            mapProjectionSummary(displayed = 3, retained = 9, markers = 3, simplifiedRows = 0, omittedRows = 0))
    }

    @Test
    fun mergedRowsAddTheMarkersCountAndTheSimplifiedWord() {
        assertEquals("5 displayed · 5 retained · 4 markers · simplified",
            mapProjectionSummary(displayed = 5, retained = 5, markers = 4, simplifiedRows = 1, omittedRows = 0))
    }

    /** The markers clause is iOS's rule exactly (markerCount != representedRows || simplified),
     *  so 40 markers for 40 displayed rows with nothing merged names no markers clause. */
    @Test
    fun rowsPastTheMarkerCapAreNamedAsOutsideTheDisplayBudget() {
        assertEquals("40 displayed · 60 retained · 20 outside display budget",
            mapProjectionSummary(displayed = 40, retained = 60, markers = 40, simplifiedRows = 0, omittedRows = 20))
        assertEquals("40 displayed · 60 retained · 30 markers · 20 outside display budget · simplified",
            mapProjectionSummary(displayed = 40, retained = 60, markers = 30, simplifiedRows = 10, omittedRows = 20))
    }

    /** The markers clause also appears when the marker count differs without merged rows (iOS's
     *  markerCount != representedRows arm), and every word stays lowercase: the line is set in
     *  the instrument face by its Kicker, not as an uppercase label. */
    @Test
    fun aMarkerCountThatDiffersIsNamedAndTheLineStaysLowercase() {
        val line = mapProjectionSummary(displayed = 6, retained = 6, markers = 7, simplifiedRows = 0, omittedRows = 0)
        assertEquals("6 displayed · 6 retained · 7 markers", line)
        assertEquals(line.lowercase(), line)
    }
}
