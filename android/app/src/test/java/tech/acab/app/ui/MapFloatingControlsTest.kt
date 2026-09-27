package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Map's floating legend button, legend card and lower-right stack (owner decision
 *  2026-09-26), in px as the screen measures them. */
class MapFloatingControlsTest {

    /** The legend button's spoken state, the same four strings as iOS
     *  mapLegendAccessibilityValue. FAILS IF the downloading branch is dropped (a first ALPR
     *  download says nothing now that it no longer opens the card) or the words drift. */
    @Test
    fun legendStateDescriptionMatchesIos() {
        assertEquals("loading camera data", MAP_LEGEND_LOADING_STATE)
        assertEquals("collapsed", mapLegendStateDescription(open = false, downloading = false))
        assertEquals("expanded", mapLegendStateDescription(open = true, downloading = false))
        assertEquals("collapsed, loading camera data", mapLegendStateDescription(open = false, downloading = true))
        assertEquals("expanded, loading camera data", mapLegendStateDescription(open = true, downloading = true))
    }

    /** The card takes 55% of the whole map slot (the chrome included, the twin of iOS
     *  regionHeight), less when that would run it up into the chrome, and never less than the
     *  header row plus one key row. An unmeasured slot or room does not cap. FAILS IF the share is
     *  taken of the room instead of the slot (1100 becomes 825: on a phone at font scale 1.0 the
     *  last key line sits under the card's edge), the room clamp is dropped (380 becomes 1100:
     *  the card covers the chips) or the floor is dropped (200 becomes 30: the honesty headline is
     *  capped away). */
    @Test
    fun legendCardCapKeepsTheMapAndTheHeadline() {
        assertEquals(0.55f, MAP_LEGEND_CARD_MAX_SHARE, 0f)
        assertEquals(Int.MAX_VALUE, mapLegendCardMaxPx(slotPx = 0, roomPx = 1500, bottomReservePx = 300, floorPx = 200, gapPx = 20))
        assertEquals(Int.MAX_VALUE, mapLegendCardMaxPx(slotPx = 2000, roomPx = -1, bottomReservePx = 300, floorPx = 200, gapPx = 20))
        // A tall room: the share of the slot binds.
        assertEquals(1100, mapLegendCardMaxPx(slotPx = 2000, roomPx = 1500, bottomReservePx = 300, floorPx = 200, gapPx = 20))
        // A short room: the card stops the gap under the chrome.
        assertEquals(380, mapLegendCardMaxPx(slotPx = 2000, roomPx = 1000, bottomReservePx = 600, floorPx = 200, gapPx = 20))
        // No room left above the credit: the floor keeps the headline and one key row.
        assertEquals(200, mapLegendCardMaxPx(slotPx = 1000, roomPx = 500, bottomReservePx = 450, floorPx = 200, gapPx = 20))
    }

    /** The lower-right buttons stack while the room holds the stack and the credit's clearance,
     *  and sit side by side one px short of that. An unmeasured room stacks. FAILS IF the credit's
     *  clearance is ignored (499 stacks the upper button onto the chrome) or the comparison flips. */
    @Test
    fun floatingStackGoesSidewaysWhenTheRoomIsShort() {
        assertTrue(mapFloatingStackVertical(roomPx = -1, stackPx = 400, creditClearancePx = 100))
        assertTrue(mapFloatingStackVertical(roomPx = 500, stackPx = 400, creditClearancePx = 100))
        assertFalse(mapFloatingStackVertical(roomPx = 499, stackPx = 400, creditClearancePx = 100))
        assertFalse(mapFloatingStackVertical(roomPx = 450, stackPx = 400, creditClearancePx = 100))
    }

    /** AND-V210-3 with the floating controls: the chrome is drawn no taller than the slot minus
     *  the controls band (the controls row, the OSM credit and its gap), so its bottom never
     *  covers a button or the credit. FAILS IF the reserve is ignored (the chrome is drawn the
     *  whole slot tall) or an unmeasured slot caps the chrome at 0. */
    @Test
    fun chromeNeverRunsUnderTheFloatingControls() {
        assertEquals(Int.MAX_VALUE, mapChromeMaxPx(slotPx = 0, bottomReservePx = 300))
        assertEquals(700, mapChromeMaxPx(slotPx = 1000, bottomReservePx = 300))
        // A reserve taller than the slot leaves no room rather than a negative one.
        assertEquals(0, mapChromeMaxPx(slotPx = 200, bottomReservePx = 300))
    }

    /** The open card's header row scrolls with the keys only when the header plus the least the
     *  body needs for its first key row do not fit the card's ceiling; an uncapped card or an
     *  unmeasured header keeps the header fixed. FAILS IF the comparison is dropped (a header that
     *  fits scrolls too, or one that does not stays fixed over a scroll window too short for one
     *  key row: the font scale 2.0 cut line) or the unmeasured guard goes (a 0 header against a
     *  short ceiling scrolls before anything is known). */
    @Test
    fun legendHeaderScrollsOnlyWhenNoKeyRowFitsUnderIt() {
        assertFalse(mapLegendHeaderScrolls(cardMaxPx = Int.MAX_VALUE, headerPx = 300, restPx = 500))
        assertFalse(mapLegendHeaderScrolls(cardMaxPx = 100, headerPx = 0, restPx = 500))
        // Exactly full still fits; one px over scrolls the header with the keys.
        assertFalse(mapLegendHeaderScrolls(cardMaxPx = 800, headerPx = 300, restPx = 500))
        assertTrue(mapLegendHeaderScrolls(cardMaxPx = 799, headerPx = 300, restPx = 500))
        // The reference phone at font scale 2.0: the room clamp binds at 568 px.
        assertTrue(mapLegendHeaderScrolls(cardMaxPx = 568, headerPx = 294, restPx = 474))
    }

    /** A confirmed map tap always closes the legend card: a bare-map tap closes the callout with
     *  it, and a known-ALPR ring tap hands the ring's words to the callout, which only shows while
     *  the card is closed. FAILS IF the ring path leaves the card as it was (a ring tapped under
     *  the open card sets a callout nothing displays) or the bare tap keeps the callout. */
    @Test
    fun mapTapClosesTheLegendCardAndTheRingTapShowsItsCallout() {
        val ring = "Flock Safety ALPR" to "a mapped location"
        assertEquals(MapTapState(legendOpen = false, alprCallout = ring),
            MapTapState(legendOpen = true, alprCallout = null).afterTap(ring = ring))
        assertEquals(MapTapState(legendOpen = false, alprCallout = ring),
            MapTapState(legendOpen = false, alprCallout = null).afterTap(ring = ring))
        assertEquals(MapTapState(legendOpen = false, alprCallout = null),
            MapTapState(legendOpen = true, alprCallout = ring).afterTap(ring = null))
        assertEquals(MapTapState(legendOpen = false, alprCallout = null),
            MapTapState(legendOpen = false, alprCallout = ring).afterTap(ring = null))
    }
}
