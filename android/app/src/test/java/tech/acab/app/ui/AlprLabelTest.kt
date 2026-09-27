package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import java.util.Locale

class AlprLabelTest {

    /** Tiers 0, 1 and 2 take the iOS callout titles byte for byte (ALPRAttribution.headline);
     *  the legacy dataset format and an unknown tier keep Android's own. No title or snippet says
     *  "verified" or "confirmed": a tier describes source structure, nobody checked the camera.
     *  Wrong input: the old titles ("Flock Safety ALPR camera, manufacturer attributed", ...). */
    @Test
    fun attributionTiersDescribeStructureWithoutVerificationClaims() {
        val tier0 = alprMarkerText(0, "")
        val tier1 = alprMarkerText(1, "Flock Safety")
        val tier2 = alprMarkerText(2, "Legacy name")
        val old = alprMarkerText(ALPR_TIER_LEGACY_FORMAT, "")
        val unknown = alprMarkerText(255, "Older value")

        assertEquals("mapped ALPR · canonical OSM tag", tier0.first)
        assertEquals("Flock Safety · mapped ALPR, via DeFlock", tier1.first)
        assertEquals("Legacy name? · legacy-tag ALPR candidate", tier2.first)
        assertEquals("ALPR camera, legacy dataset format", old.first)
        assertEquals("Older value ALPR record, unknown attribution tier", unknown.first)

        for (text in listOf(tier0, tier1, tier2, old, unknown)
            .flatMap { listOf(it.first, it.second) }) {
            assertFalse(text, text.contains("verified", ignoreCase = true))
            assertFalse(text, text.contains("confirmed", ignoreCase = true))
        }
    }

    /** Every arm of the shared headline, byte-identical to iOS ALPRAttribution.headline. */
    @Test
    fun headlineArmsMatchIos() {
        assertEquals("mapped ALPR · sourced from DeFlock", alprAttributionHeadline(1, ""))
        assertEquals("Flock Safety · mapped ALPR, via DeFlock", alprAttributionHeadline(1, "Flock Safety"))
        assertEquals("ALPR candidate · legacy OSM tag", alprAttributionHeadline(2, ""))
        assertEquals("Motorola? · legacy-tag ALPR candidate", alprAttributionHeadline(2, "Motorola"))
        assertEquals("mapped ALPR · canonical OSM tag", alprAttributionHeadline(0, ""))
        assertEquals("Genetec? · canonical OSM ALPR", alprAttributionHeadline(0, "Genetec"))
    }

    /** The "lower-confidence pins" caption, both states, one and many (grouped digits). Wrong
     *  input: "1 lower-confidence pin are hidden" (the grammar iOS had). TWIN: iOS
     *  alprLowerConfidenceLine(count:showing:), same four sentences. */
    @Test
    fun lowerConfidenceLineReadsTheIosWords() {
        assertEquals("1 lower-confidence pin is hidden. some are not cameras.",
            alprLowerConfidenceLine(1, showing = false, locale = Locale.US))
        assertEquals("20,605 lower-confidence pins are hidden. some are not cameras.",
            alprLowerConfidenceLine(20605, showing = false, locale = Locale.US))
        assertEquals(
            "showing 1 pin without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras.",
            alprLowerConfidenceLine(1, showing = true, locale = Locale.US))
        assertEquals(
            "showing 20,605 pins without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras.",
            alprLowerConfidenceLine(20605, showing = true, locale = Locale.US))
    }
}
