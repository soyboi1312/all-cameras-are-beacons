package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins AcabBanner's wide-window rule (bannerWindowIsWide, the `wideWindow` arm of
 *  bannerActionsStackAt): from BANNER_WIDE_WINDOW_DP the font-scale rule is off and the width
 *  fit alone decides. Verify step 2026-09-26 (review P3-4 + P3-5 + AND-NAV-01): at font scale
 *  2.0 in landscape the sample banner stacked Exit Sample Data under its message on an 891dp
 *  window and took about 140dp of the 411dp, a third of the Map's window, with room to spare
 *  beside the message. Units as in AcabBannerFontScaleTest (px at density 2.58). FAILS IF the
 *  boundary moves, a wide window stacks from the scale alone, or the width fit stops guarding a
 *  wide window. */
class AcabBannerWideWindowTest {
    @Test
    fun theBoundaryIsTheMediumWindowClass() {
        assertEquals(600, BANNER_WIDE_WINDOW_DP)
        assertTrue(bannerWindowIsWide(600))
        assertTrue(bannerWindowIsWide(891))
        assertFalse(bannerWindowIsWide(599))
        assertFalse(bannerWindowIsWide(411))
    }

    /** The landscape case: at 2.0 the actions (about 480px) and the message floor (310px) fit
     *  the row, so a wide window trails them; the same numbers stack in a compact window. */
    @Test
    fun aWideWindowTrailsTheActionsAtFontScaleTwoWhenTheyFit() {
        assertFalse(bannerActionsStackAt(fontScale = 2.0f, availablePx = 880, actionsPx = 480, messageMinPx = 310,
            wideWindow = true))
        assertTrue(bannerActionsStackAt(fontScale = 2.0f, availablePx = 880, actionsPx = 480, messageMinPx = 310,
            wideWindow = false))
    }

    /** The width fit still guards a wide window: actions that do not fit beside the message's
     *  readable minimum stack at any scale. */
    @Test
    fun aWideWindowStillStacksWhenTheActionsDoNotFit() {
        assertTrue(bannerActionsStackAt(fontScale = 1.0f, availablePx = 300, actionsPx = 181, messageMinPx = 120,
            wideWindow = true))
        assertTrue(bannerActionsStackAt(fontScale = 2.0f, availablePx = 300, actionsPx = 181, messageMinPx = 120,
            wideWindow = true))
        assertFalse(bannerActionsStackAt(fontScale = 2.0f, availablePx = 300, actionsPx = 180, messageMinPx = 120,
            wideWindow = true))
    }

    /** A banner without actions never stacks in a wide window either. */
    @Test
    fun aBannerWithoutActionsNeverStacks() {
        assertFalse(bannerActionsStackAt(fontScale = 2.0f, availablePx = 50, actionsPx = 0, messageMinPx = 120,
            wideWindow = true))
    }
}
