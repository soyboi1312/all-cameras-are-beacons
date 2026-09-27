package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The stacked Map chrome caps its scope segments at MAP_SCOPE_SEGMENTS_MAX_WIDTH (Large screen
 *  app quality LS-U2: buttons are not full width on large screens), the cap
 *  LocationContextBanner already uses in the same chrome (2026-09-26 review, P2-17). Units are
 *  px at density 2.0. FAILS IF the cap is dropped (a 1600dp tablet row keeps 600dp segments), or
 *  a phone row is narrowed below its own width. */
class MapScopeSegmentsWidthTest {
    private val capPx = 520 * 2

    @Test
    fun theCapIsTheBannerCap() {
        assertEquals(520f, MAP_SCOPE_SEGMENTS_MAX_WIDTH.value)
    }

    /** A 1600dp expanded row inside its 16dp gutters (1,568dp = 3,136px) is capped. */
    @Test
    fun anExpandedRowIsCappedAtTheBannerWidth() {
        assertEquals(capPx, mapScopeSegmentsWidthPx(rowPx = 3_136, capPx = capPx))
    }

    /** A 411dp phone row inside its gutters (379dp = 758px) is under the cap and keeps its width;
     *  exactly the cap keeps it too. */
    @Test
    fun aPhoneRowKeepsItsOwnWidth() {
        assertEquals(758, mapScopeSegmentsWidthPx(rowPx = 758, capPx = capPx))
        assertEquals(capPx, mapScopeSegmentsWidthPx(rowPx = capPx, capPx = capPx))
    }

    /** Unmeasured (a zero or negative row before layout) never goes below zero. */
    @Test
    fun anUnmeasuredRowClampsAtZero() {
        assertEquals(0, mapScopeSegmentsWidthPx(rowPx = -32, capPx = capPx))
    }
}
