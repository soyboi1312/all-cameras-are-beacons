package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The SAMPLE pill leads with a filled amber dot, not the warning triangle (2026-09-26 review,
 *  P2-18): sample mode is a state the user chose, amber is its state colour, and iOS LinkChip
 *  draws the same 8pt dot before SAMPLE. The triangle stays for a real fault or transition
 *  (RECONNECTING, UPDATING, RADIO FAULT), so a user switching phones sees a status light on both
 *  and a fault icon only for a fault. FAILS IF sample data goes back to the triangle, or a fault
 *  takes the dot. */
class LinkChipSampleDotTest {
    @Test
    fun sampleDataWearsTheDotOverAnyLinkState() {
        assertEquals(
            LinkChipLook("SAMPLE", LinkChipTone.ATTENTION, LinkChipMark.DOT),
            linkChipAppearance("2.0.9", demo = true, connected = true, stateLabel = "RADIO FAULT"),
        )
        assertEquals(
            LinkChipLook("SAMPLE", LinkChipTone.ATTENTION, LinkChipMark.DOT),
            linkChipAppearance(null, demo = true, connected = null, stateLabel = null),
        )
    }

    @Test
    fun aFaultOrTransitionKeepsTheWarningTriangle() {
        for (word in listOf("RECONNECTING", "UPDATING", "RADIO FAULT")) {
            assertEquals(word,
                LinkChipLook(word, LinkChipTone.ATTENTION, LinkChipMark.WARNING),
                linkChipAppearance(null, demo = false, connected = true, stateLabel = word))
        }
    }
}
