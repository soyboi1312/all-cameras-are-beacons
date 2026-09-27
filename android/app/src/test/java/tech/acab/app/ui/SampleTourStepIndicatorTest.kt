package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** 2026-09-26 review P3-12: the tour's three-dot indicator speaks "step N of 3" (its content
 *  description, a polite live region) now that the text counter under the card is gone. FAILS IF
 *  the spoken step goes zero-based or drops the count. TWIN: iOS FirstRunTourView's page
 *  indicator accessibilityValue, the same words. */
class SampleTourStepIndicatorTest {
    @Test
    fun theIndicatorSpeaksAOneBasedStepOfTheCount() {
        assertEquals("step 1 of 3", tourStepDescription(page = 0, count = 3))
        assertEquals("step 2 of 3", tourStepDescription(page = 1, count = 3))
        assertEquals("step 3 of 3", tourStepDescription(page = 2, count = 3))
    }
}
