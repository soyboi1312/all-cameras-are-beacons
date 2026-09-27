package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Map's large-text layout rules (V-A5, M1-C, A11Y-1), all in px as the screen measures them. The
 *  floating legend button, card and controls are in MapFloatingControlsTest. */
class MapLayoutTest {

    /** M1-C: a short window (a phone in landscape) takes the fewest chrome rows whose pieces fit at
     * their natural widths; a window at least MAP_CHROME_COMPACT_HEIGHT_DP tall (a portrait phone,
     * a tablet either way) keeps the stacked chrome whatever the width. The bar holds only the
     * "Map" title now (Map options and Center on my location float at the lower right, decisions
     * R17). Illustrative px at density 2.75: a 411dp-tall landscape window with a 2,508px (912dp)
     * row fits all three pieces (ONE_ROW); a narrower row drops the chips to their own row
     * (SCOPE_BESIDE_TITLE); where even the title and the segments overflow the row (a large font
     * scale on a narrower phone), the segments and the chips share one sideways-scrolling row
     * under the bar (SCOPE_WITH_CHIPS, AND-V210-3) rather than squeezing the segment labels or
     * stacking three rows. FAILS IF the height gate is dropped (a tablet or a portrait phone goes
     * compact), the chips are folded in without room for them, an overflowing title row is kept
     * (clipped segments at font scale 2.0), or a short window falls back to the three STACKED
     * rows. */
    @Test
    fun compactChromeTakesTheFewestRowsThatFit() {
        assertEquals(480, MAP_CHROME_COMPACT_HEIGHT_DP)
        // Landscape phone, font scale 1.0: title 130, segments 1,100, chips min 300.
        assertEquals(MapChromeArrangement.ONE_ROW, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 2_508, titlePx = 130, segmentsPx = 1_100, chipsMinPx = 300))
        // Exactly full still fits; one px short drops the chips under the bar.
        assertEquals(MapChromeArrangement.ONE_ROW, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 1_530, titlePx = 130, segmentsPx = 1_100, chipsMinPx = 300))
        assertEquals(MapChromeArrangement.SCOPE_BESIDE_TITLE, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 1_529, titlePx = 130, segmentsPx = 1_100, chipsMinPx = 300))
        // Font scale 2.0: the title and the segments exactly fill the row and keep it; one px
        // less and the segments and the chips share the row under the bar.
        assertEquals(MapChromeArrangement.SCOPE_BESIDE_TITLE, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 2_320, titlePx = 220, segmentsPx = 2_100, chipsMinPx = 540))
        assertEquals(MapChromeArrangement.SCOPE_WITH_CHIPS, mapChromeArrangement(
            windowHeightDp = 411, rowPx = 2_319, titlePx = 220, segmentsPx = 2_100, chipsMinPx = 540))
        // Portrait phone and tablets: unchanged, even with room to spare.
        assertEquals(MapChromeArrangement.STACKED, mapChromeArrangement(
            windowHeightDp = 891, rowPx = 1_000, titlePx = 130, segmentsPx = 500, chipsMinPx = 150))
        assertEquals(MapChromeArrangement.STACKED, mapChromeArrangement(
            windowHeightDp = 480, rowPx = 4_000, titlePx = 130, segmentsPx = 1_100, chipsMinPx = 300))
        assertEquals(MapChromeArrangement.ONE_ROW, mapChromeArrangement(
            windowHeightDp = 479, rowPx = 4_000, titlePx = 130, segmentsPx = 1_100, chipsMinPx = 300))
    }

    /** A11Y-1: the headline row's TalkBack companion says "detection" for one. FAILS IF the
     * plural is fixed ("1 visible map detections"). */
    @Test
    fun visibleDetectionsPhraseIsSingularForOne() {
        assertEquals("1 visible map detection", mapVisibleDetectionsPhrase(1))
        assertEquals("5 visible map detections", mapVisibleDetectionsPhrase(5))
        assertEquals("0 visible map detections", mapVisibleDetectionsPhrase(0))
    }

    /** V-A5: the first fit is inset by the chrome's measured height, capped at half of the
     * bordered map height so a chrome taller than the map still leaves an area to frame. FAILS IF
     * the fit goes back to a flat border (inset 0) or the cap is dropped. */
    @Test
    fun firstFitIsInsetByTheChromeUpToHalfTheMap() {
        assertEquals(560, mapFitTopInsetPx(mapHeightPx = 2000, chromePx = 560, borderPx = 64))
        assertEquals(936, mapFitTopInsetPx(mapHeightPx = 2000, chromePx = 1500, borderPx = 64))
        assertEquals(0, mapFitTopInsetPx(mapHeightPx = 2000, chromePx = 0, borderPx = 64))
        assertEquals(0, mapFitTopInsetPx(mapHeightPx = 100, chromePx = 560, borderPx = 64))
    }
}
