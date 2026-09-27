package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins GroupedValueRow's fit rule (valueRowStacks): the value trails the title while title, gap
 *  and value fit the row, and stacks under the title otherwise. Never a clamp. Units are px. */
class GroupedValueRowLayoutTest {
    @Test
    fun sideBySideWhenTitleGapAndValueFitExactly() {
        assertFalse(valueRowStacks(availablePx = 100, titlePx = 60, valuePx = 24, gapPx = 16))
    }

    @Test
    fun stacksOnePixelPastTheFit() {
        assertTrue(valueRowStacks(availablePx = 100, titlePx = 61, valuePx = 24, gapPx = 16))
    }

    /** A runtime value wider than the whole row stacks at full width; it is never shrunk to fit
     *  beside the title. */
    @Test
    fun aRuntimeValueWiderThanTheRowStacksAndIsNeverClamped() {
        assertTrue(valueRowStacks(availablePx = 100, titlePx = 10, valuePx = 120, gapPx = 16))
    }
}

/** Pins AcabBanner's fit rule (bannerActionsStack): the actions trail the message while the
 *  actions and the message's readable minimum fit beside the icon, and move to their own line
 *  under the message otherwise. Units are px. */
class AcabBannerLayoutTest {
    @Test
    fun actionsTrailWhenActionsAndMessageMinimumFitExactly() {
        assertFalse(bannerActionsStack(availablePx = 300, actionsPx = 180, messageMinPx = 120))
    }

    @Test
    fun actionsStackOnePixelPastTheFit() {
        assertTrue(bannerActionsStack(availablePx = 300, actionsPx = 181, messageMinPx = 120))
    }

    /** A banner with no actions keeps the message full width; it never grows an empty line. */
    @Test
    fun aBannerWithoutActionsNeverStacks() {
        assertFalse(bannerActionsStack(availablePx = 50, actionsPx = 0, messageMinPx = 120))
    }
}
