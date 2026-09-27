package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins AcabBanner's whole stack decision (bannerActionsStackAt): from font scale
 *  BANNER_STACK_FONT_SCALE the actions always move under the message, and below it the width fit
 *  (bannerActionsStack) decides. The pinned sample banner once wrapped "Sample Data, Not Nearby
 *  Devices" one word per line beside Exit Sample Data at font scale 2.0 on every tab, because the
 *  fit compared against a floor that never grew with the font. Units are px at density 2.58 (a
 *  411dp window is 1,060px; the row beside the 20dp icon and its 16dp gap is about 880px). */
class AcabBannerFontScaleTest {
    /** The review's case: font scale 2.0 on a 411dp window with the sample strings. The actions
     *  (Exit Sample Data at 2.0, about 480px) plus the 120dp floor (310px) still fit the 880px
     *  row, so the width fit alone said "trail"; the scale rule stacks. FAILS IF the scale rule is
     *  dropped or its threshold rises above 2.0. */
    @Test
    fun theSampleBannerStacksAtFontScaleTwoEvenThoughTheWidthFitSaysTrail() {
        assertFalse(bannerActionsStack(availablePx = 880, actionsPx = 480, messageMinPx = 310))
        assertTrue(bannerActionsStackAt(fontScale = 2.0f, availablePx = 880, actionsPx = 480, messageMinPx = 310))
    }

    /** The threshold is the iOS twin's accessibility boundary as this app maps it (1.3, the
     *  DeviceScreen large-text bar's scale): exactly 1.3 stacks, a hair under does not. */
    @Test
    fun theScaleRuleStartsAtOnePointThree() {
        assertEquals(1.3f, BANNER_STACK_FONT_SCALE)
        assertTrue(bannerActionsStackAt(fontScale = 1.3f, availablePx = 880, actionsPx = 300, messageMinPx = 310))
        assertFalse(bannerActionsStackAt(fontScale = 1.29f, availablePx = 880, actionsPx = 300, messageMinPx = 310))
    }

    /** Below the threshold the width fit still governs, both ways. FAILS IF the scale rule
     *  replaced the fit instead of joining it. */
    @Test
    fun belowTheThresholdTheWidthFitStillDecides() {
        assertTrue(bannerActionsStackAt(fontScale = 1.0f, availablePx = 300, actionsPx = 181, messageMinPx = 120))
        assertFalse(bannerActionsStackAt(fontScale = 1.0f, availablePx = 300, actionsPx = 180, messageMinPx = 120))
    }

    /** A banner without actions never stacks, at any scale: there is nothing to move under the
     *  message and an empty line would only grow the banner. */
    @Test
    fun aBannerWithoutActionsNeverStacksAtAnyScale() {
        assertFalse(bannerActionsStackAt(fontScale = 2.0f, availablePx = 50, actionsPx = 0, messageMinPx = 120))
        assertFalse(bannerActionsStackAt(fontScale = 1.0f, availablePx = 50, actionsPx = 0, messageMinPx = 120))
    }
}
