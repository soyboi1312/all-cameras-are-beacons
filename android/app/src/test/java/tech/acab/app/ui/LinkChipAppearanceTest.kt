package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Pins which word and which look the status pill shows (linkChipAppearance). iOS twin: the
 *  LinkChip label and amber rule in Views/Components.swift. */
class LinkChipAppearanceTest {
    /** Sample data reads SAMPLE (U1-c; the banner and the dossier header say sample too), amber
     *  with the DOT mark (R19: a state light, the iOS pill's 8pt circle, never the fault
     *  triangle), over any link state. Wrong inputs: the old word "DEMO"; the WARNING mark. */
    @Test
    fun sampleAlwaysReadsSampleInAmber() {
        assertEquals(
            LinkChipLook("SAMPLE", LinkChipTone.ATTENTION, LinkChipMark.DOT),
            linkChipAppearance("2.0.9", demo = true, connected = true, stateLabel = "RADIO FAULT"),
        )
    }

    /** A radio fault, a reconnect or an update never reads as a healthy pill, and the word is
     *  drawn as written (uppercase). */
    @Test
    fun theThreeAttentionWordsDrawAmberAsWritten() {
        for (word in listOf("RECONNECTING", "UPDATING", "RADIO FAULT")) {
            assertEquals(word,
                LinkChipLook(word, LinkChipTone.ATTENTION, LinkChipMark.WARNING),
                linkChipAppearance(null, demo = false, connected = true, stateLabel = word))
        }
    }

    @Test
    fun onlyTheConnectedWordWearsTheCheck() {
        assertEquals(
            LinkChipLook("WAITING", LinkChipTone.LINKED, LinkChipMark.NONE),
            linkChipAppearance(null, demo = false, connected = true, stateLabel = "WAITING"),
        )
        assertEquals(
            LinkChipLook("CONNECTED", LinkChipTone.LINKED, LinkChipMark.CHECK),
            linkChipAppearance(null, demo = false, connected = true, stateLabel = null),
        )
    }

    /** An authoritative [connected] beats the inference from a version string, both ways. */
    @Test
    fun authorityBeatsVersionInference() {
        assertEquals(
            LinkChipLook("CONNECTED", LinkChipTone.LINKED, LinkChipMark.CHECK),
            linkChipAppearance("2.0.9", demo = false, connected = null, stateLabel = null),
        )
        assertEquals(
            LinkChipLook("OFFLINE", LinkChipTone.OFFLINE, LinkChipMark.NONE),
            linkChipAppearance(null, demo = false, connected = null, stateLabel = null),
        )
        assertEquals(
            LinkChipLook("OFFLINE", LinkChipTone.OFFLINE, LinkChipMark.NONE),
            linkChipAppearance("2.0.9", demo = false, connected = false, stateLabel = null),
        )
    }
}
