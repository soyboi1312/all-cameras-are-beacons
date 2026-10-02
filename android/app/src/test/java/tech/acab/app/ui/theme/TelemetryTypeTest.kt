package tech.acab.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontListFontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.ResourceFont
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.R
import tech.acab.app.ui.WORDMARK_MIN_FIT
import tech.acab.app.ui.wordmarkFit

/**
 * Pins the instrument layer (decision R16): JetBrains Mono for short instrument text only, at
 * [TELEMETRY_SCALE] of the M3 role's size, [TELEMETRY_TRACKING] on uppercase labels only, and the
 * system face (Roboto) on every M3 role. Also pins the connect wordmark's Space Grotesk Bold and
 * its one-line shrink floor. iOS twin: TelemetryTypeTests.
 */
class TelemetryTypeTest {
    /** (resource, weight) of each font in a family built from bundled resources. */
    private fun cuts(family: FontFamily): List<Pair<Int, FontWeight>> =
        (family as FontListFontFamily).fonts.map { (it as ResourceFont).resId to it.weight }

    // ---- the shared constants (drift rows "telemetry scale" and "telemetry tracking") ----

    @Test
    fun scaleAndTrackingAreTheSharedValues() {
        assertEquals(0.9f, TELEMETRY_SCALE)
        assertEquals(0.8.sp, TELEMETRY_TRACKING)
    }

    // ---- the face ----

    @Test
    fun jetBrainsMonoIsTheFourBundledCuts() {
        assertEquals(
            listOf(
                R.font.jetbrains_mono_regular to FontWeight.Normal,
                R.font.jetbrains_mono_medium to FontWeight.Medium,
                R.font.jetbrains_mono_semibold to FontWeight.SemiBold,
                R.font.jetbrains_mono_bold to FontWeight.Bold,
            ),
            cuts(JetBrainsMono),
        )
    }

    @Test
    fun telemetryIsJetBrainsMonoAtNineTenthsOfTheRole() {
        val t = AcabTypography
        // (role, its M3 1.3.1 size): the expected size is written out, never read back from the
        // role, so a changed factor fails here rather than cancelling out.
        val cases = listOf(
            "bodyLarge" to (t.bodyLarge to 14.4f),     // 16 x 0.9
            "bodyMedium" to (t.bodyMedium to 12.6f),   // 14 x 0.9
            "labelMedium" to (t.labelMedium to 10.8f), // 12 x 0.9
            "labelSmall" to (t.labelSmall to 9.9f),    // 11 x 0.9
            "headlineMedium" to (t.headlineMedium to 25.2f), // 28 x 0.9
        )
        for ((name, pair) in cases) {
            val (role, size) = pair
            val s = role.telemetry()
            assertEquals(name, JetBrainsMono, s.fontFamily)
            assertTrue("$name is in sp, so it follows the font scale", s.fontSize.isSp)
            assertEquals(name, size, s.fontSize.value, 1e-4f)
            assertEquals("$name keeps the role's line height", role.lineHeight, s.lineHeight)
            assertEquals("$name keeps the role's weight", role.fontWeight, s.fontWeight)
            assertEquals("$name is untracked", 0.sp, s.letterSpacing)
        }
    }

    @Test
    fun trackingAndWeightApplyOnlyWhenAsked() {
        val label = AcabTypography.bodyMedium.telemetry(weight = FontWeight.Medium, tracked = true)
        assertEquals(TELEMETRY_TRACKING, label.letterSpacing)
        assertEquals(FontWeight.Medium, label.fontWeight)
        // A role that carries its own tracking (labelSmall 0.5sp) loses it on a telemetry LINE.
        assertEquals(0.sp, AcabTypography.labelSmall.telemetry().letterSpacing)
    }

    /** L1 holds outside the instrument layer: every M3 role (titles, body, buttons, labels) stays
     *  the system face. */
    @Test
    fun everyM3RoleStaysTheSystemFace() {
        val m3 = Typography()
        val roles: List<Pair<String, Pair<TextStyle, TextStyle>>> = listOf(
            "displayLarge" to (AcabTypography.displayLarge to m3.displayLarge),
            "headlineSmall" to (AcabTypography.headlineSmall to m3.headlineSmall),
            "titleLarge" to (AcabTypography.titleLarge to m3.titleLarge),
            "titleMedium" to (AcabTypography.titleMedium to m3.titleMedium),
            "titleSmall" to (AcabTypography.titleSmall to m3.titleSmall),
            "bodyLarge" to (AcabTypography.bodyLarge to m3.bodyLarge),
            "bodyMedium" to (AcabTypography.bodyMedium to m3.bodyMedium),
            "bodySmall" to (AcabTypography.bodySmall to m3.bodySmall),
            "labelLarge" to (AcabTypography.labelLarge to m3.labelLarge),
        )
        for ((name, pair) in roles) {
            val (ours, stock) = pair
            assertEquals(name, stock.fontFamily, ours.fontFamily)
            assertNotEquals(name, JetBrainsMono, ours.fontFamily)
            assertNotEquals(name, WordmarkFace, ours.fontFamily)
        }
    }

    // ---- the wordmark ----

    @Test
    fun wordmarkIsSpaceGroteskBold() {
        assertEquals(listOf(R.font.space_grotesk_bold to FontWeight.Bold), cuts(WordmarkFace))
    }

    /** One line that shrinks to fit, never below 0.4: iOS ACABWordmark minimumScaleFactor(0.4). */
    @Test
    fun wordmarkShrinksToFitAndStopsAtFourTenths() {
        assertEquals(0.4f, WORDMARK_MIN_FIT)
        assertEquals("fits: full size", 1f, wordmarkFit(availablePx = 400, fullWidthPx = 300))
        assertEquals("not measured yet: full size", 1f, wordmarkFit(availablePx = 400, fullWidthPx = 0))
        assertEquals("half the room: half the size", 0.5f, wordmarkFit(availablePx = 150, fullWidthPx = 300), 1e-6f)
        assertEquals("the floor", 0.4f, wordmarkFit(availablePx = 30, fullWidthPx = 300))
    }

    // ---- which labels are instrument labels (C2) ----

    /** Twin cases: iOS TelemetryTypeTests.testInstrumentLabelRule. */
    @Test
    fun instrumentLabelRule() {
        assertTrue(isInstrumentLabel("SIGHTINGS"))
        assertTrue(isInstrumentLabel("6 ON · 1 EXP"))
        assertTrue(isInstrumentLabel("WI-FI ECO"))
        assertFalse(isInstrumentLabel("radios, detectors, desert mode"))
        assertFalse("one lowercase letter is copy", isInstrumentLabel("v2.0.9 · LATEST KNOWN"))
        assertFalse("a bare number is not a label", isInstrumentLabel("-54"))
        assertFalse(isInstrumentLabel(""))
    }
}
