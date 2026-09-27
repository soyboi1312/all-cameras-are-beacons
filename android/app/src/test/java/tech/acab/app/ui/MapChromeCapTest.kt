package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Owner decision 2026-09-26 (review P3-4 + P3-5 + AND-NAV-01 as one design): from font scale
 *  1.5, or in a compact window, the Map chrome is capped: it takes the compact arrangement (the
 *  scope segments and the category chips share one sideways-scrolling row when the title row
 *  cannot hold the segments) and draws its own type, the "Map" title and the OSM credit, at no
 *  more than 1.5x. Widths below are px at density 2.0, modelled from the 411 x 891dp phone:
 *  the row inside the bar's insets (355dp), the title at the capped scale ("Map" plus its 12dp
 *  gap, about 57dp), three segments at font scale 2.0 measured at three digits (about 711dp)
 *  and the ALL chip plus the minimum carousel (about 200dp). FAILS IF the cap moves, a portrait
 *  phone at 2.0 stacks three rows again, the type cap scales above the system scale, or the
 *  stacked labels keep the dot on their second line. */
class MapChromeCapTest {
    @Test
    fun theCapIsOneAndAHalf() {
        assertEquals(1.5f, MAP_CHROME_CAP_FONT_SCALE)
    }

    @Test
    fun theChromeIsCappedFromTheScaleOrInACompactWindow() {
        assertFalse(mapChromeCapped(fontScale = 1f, windowHeightDp = 891))
        assertFalse(mapChromeCapped(fontScale = 1.49f, windowHeightDp = 891))
        assertTrue(mapChromeCapped(fontScale = 1.5f, windowHeightDp = 891))
        assertTrue(mapChromeCapped(fontScale = 2f, windowHeightDp = 891))
        // A phone in landscape is capped at any scale (M1-C's compact height, unchanged).
        assertTrue(mapChromeCapped(fontScale = 1f, windowHeightDp = 411))
    }

    /** The chrome's own type never draws above the cap, and never above the system scale. */
    @Test
    fun theTypeScaleIsTheSystemScaleUpToTheCap() {
        assertEquals(1f, mapChromeTypeScale(1f))
        assertEquals(1.3f, mapChromeTypeScale(1.3f))
        assertEquals(1.5f, mapChromeTypeScale(1.5f))
        assertEquals(1.5f, mapChromeTypeScale(2f))
    }

    /** A portrait phone at font scale 2.0: the title row cannot hold the segments, so they share
     *  a scrolling row with the chips under the title-only bar (two rows, not three). */
    @Test
    fun aPortraitPhoneAtTwoTakesTheScrollingRow() {
        assertEquals(MapChromeArrangement.SCOPE_WITH_CHIPS, mapChromeArrangement(
            windowHeightDp = 891, rowPx = 710, titlePx = 114, segmentsPx = 1_422, chipsMinPx = 400,
            fontScale = 2f))
    }

    /** Under the cap the portrait phone keeps the stacked chrome (MapLayoutTest's cases pass
     *  the default scale of 1.0; this is the scale just under the cap). */
    @Test
    fun aPortraitPhoneUnderTheCapStaysStacked() {
        assertEquals(MapChromeArrangement.STACKED, mapChromeArrangement(
            windowHeightDp = 891, rowPx = 710, titlePx = 114, segmentsPx = 1_422, chipsMinPx = 400,
            fontScale = 1.49f))
    }

    /** The compact arms are unchanged by the cap, only reached from the scale as well as the
     *  height: a compact-height window (411dp tall, 891 wide: the row inside the insets is
     *  835dp) given segments measured at the full 2.0 scale holds the title and the segments in
     *  the bar and the chips under it. */
    @Test
    fun aLandscapePhoneAtTwoKeepsTheCompactArms() {
        assertEquals(MapChromeArrangement.SCOPE_BESIDE_TITLE, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 1_670, titlePx = 114, segmentsPx = 1_422, chipsMinPx = 400,
            fontScale = 2f))
    }

    /** The segment and chip labels take the cap only in a compact-height window (verify step
     *  2026-09-26: at 2.0 in landscape the full-scale labels ran the chrome past its bound and
     *  the chip row was cut above the OSM credit); a tall window scales them in full and
     *  scrolls the row. Under the cap the scale is the system's, in either window. */
    @Test
    fun theLabelsAreCappedOnlyInACompactWindow() {
        assertEquals(2f, mapChromeLabelScale(fontScale = 2f, windowHeightDp = 891))
        assertEquals(1.5f, mapChromeLabelScale(fontScale = 2f, windowHeightDp = 411))
        assertEquals(1.5f, mapChromeLabelScale(fontScale = 1.5f, windowHeightDp = 411))
        assertEquals(1.3f, mapChromeLabelScale(fontScale = 1.3f, windowHeightDp = 411))
        assertEquals(1f, mapChromeLabelScale(fontScale = 1f, windowHeightDp = 411))
        assertEquals(1.3f, mapChromeLabelScale(fontScale = 1.3f, windowHeightDp = 891))
    }

    /** A landscape phone at font scale 2.0 measures its segments and chips at the capped 1.5
     *  (three quarters of the 2.0 widths above: about 1,067px and 300px), so the title, the
     *  segments and the chips all fit the 835dp row: ONE_ROW, one pill over the map. FAILS IF a
     *  landscape phone at 2.0 goes back to two rows. */
    @Test
    fun aLandscapePhoneAtTwoWithCappedLabelsTakesOneRow() {
        assertEquals(MapChromeArrangement.ONE_ROW, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 1_670, titlePx = 114, segmentsPx = 1_067, chipsMinPx = 300,
            fontScale = 2f))
    }

    /** Stacked segments draw "recent" over "5" (no dot) only when their one-line width AS DRAWN
     *  (the real counts, MapChromeWidths.segmentsDrawnPx, not the three-digit width) exceeds the
     *  row they are given: at the default scale "active · 5" fits and stays one line. */
    @Test
    fun stackedLabelsDropTheDotOnlyWhenTheRowIsTooNarrow() {
        assertTrue(mapScopeLabelsStack(segmentsPx = 1_032, rowPx = 758))
        assertFalse(mapScopeLabelsStack(segmentsPx = 700, rowPx = 758))
        assertFalse(mapScopeLabelsStack(segmentsPx = 758, rowPx = 758))
        assertEquals("recent\n5", segmentLabelStacked("recent · 5"))
        assertEquals("all", segmentLabelStacked("all"))
        // The one-line form keeps the dot, attached to the count.
        assertEquals("recent · 5", segmentLabelForDisplay("recent · 5"))
    }
}
