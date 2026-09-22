package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Pins the measured wrap rule both category strips use. Units are dp at density 1, measured on
 *  a 411dp emulator (a 372dp strip, 8dp gaps, 4dp tile side padding, so a 47.3dp label box six
 *  across), where the 10sp NETCAM label is 41.4dp at font scale 1.0, 47.1dp at 1.15 and 53.1dp
 *  at 1.3. The old fixed rule kept six across until font scale 1.5, so it fails the 1.3 case.
 *  iOS twin: CategoryStripLayoutTests. */
class CategoryTilesPerRowTest {
    private fun perRow(strip: Float, widest: Float, preferred: Int) =
        categoryTilesPerRow(strip, gapPx = 8f, tilePaddingPx = 4f, widestLabelPx = widest, preferred = preferred)

    @Test
    fun sixAcrossWhileTheWidestLabelFits() {
        assertEquals("NETCAM at font scale 1.0", 6, perRow(372f, 41.4f, 6))
        assertEquals("NETCAM at font scale 1.15, 0.2dp to spare", 6, perRow(372f, 47.1f, 6))
    }

    @Test
    fun wrapsAtTheFirstScaleWhereALabelWouldBeCut() {
        assertEquals("NETCAM at font scale 1.3", 3, perRow(372f, 53.1f, 6))
        assertEquals("one dp past the box", 3, perRow(372f, 48.3f, 6))
    }

    @Test
    fun narrowPhonesWrapWithoutANamedWidthThreshold() {
        // A 360dp phone leaves a ~320dp strip: a ~38.7dp label box six across.
        assertEquals(3, perRow(320f, 41.4f, 6))
    }

    @Test
    fun theLogsSevenTileLayoutKeepsFourAcrossWhenItFits() {
        assertEquals(4, perRow(372f, 41.4f, 4))
        assertEquals(3, perRow(372f, 80f, 4))
    }

    @Test
    fun aLabelTooWideForThreeDropsToTwoAndNoFurther() {
        // 372dp strip: a three-across box is ~110.7dp, a two-across box ~174dp.
        assertEquals(2, perRow(372f, 120f, 6))
        assertEquals("a three-tile Log strip also drops", 2, perRow(372f, 120f, 3))
        assertEquals("two is the floor even when it clips", 2, perRow(372f, 500f, 6))
        assertEquals(3, perRow(372f, 100f, 3))
    }

    @Test
    fun oneOrTwoTilesAreNeverRearranged() {
        assertEquals(1, perRow(372f, 500f, 1))
        assertEquals(2, perRow(372f, 500f, 2))
    }
}
