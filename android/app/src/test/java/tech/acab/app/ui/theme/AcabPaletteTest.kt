package tech.acab.app.ui.theme

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ui.mapInfoColors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Locks the palette to the contrast it claims. Every ratio is measured the way the screen shows
 * it: a translucent tint is composited onto the surface it sits on, then compared against that
 * same surface (WCAG 2.x relative luminance). iOS twin: ContrastPaletteTests.
 */
class AcabPaletteTest {
    private fun channel(c: Float): Double =
        if (c <= 0.03928f) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)

    private fun luminance(c: Color): Double =
        0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)

    private fun over(fg: Color, bg: Color): Color = Color(
        red = fg.red * fg.alpha + bg.red * (1 - fg.alpha),
        green = fg.green * fg.alpha + bg.green * (1 - fg.alpha),
        blue = fg.blue * fg.alpha + bg.blue * (1 - fg.alpha),
    )

    /** Contrast of [fg] drawn on opaque [bg], with fg's alpha composited first. */
    private fun ratio(fg: Color, bg: Color): Double {
        val f = luminance(over(fg, bg))
        val b = luminance(bg)
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }

    private fun surfaces(p: AcabPalette) = listOf("bg" to p.bg, "bg2" to p.bg2, "bg3" to p.bg3)
    private fun textTokens(p: AcabPalette) = listOf(
        "text" to p.text, "dim" to p.dim, "faint" to p.faint, "accentText" to p.accentText,
        "warn" to p.warn, "droneTone" to p.droneTone, "bodyCamTone" to p.bodyCamTone,
        "trackerTone" to p.trackerTone, "glassesTone" to p.glassesTone, "watchTone" to p.watchTone,
        "netcamTone" to p.netcamTone, "sandTone" to p.sandTone,
    )

    @Test
    fun wcagMathMatchesKnownAnchors() {
        assertEquals(21.0, ratio(Color.White, Color.Black), 0.01)
        assertEquals(4.54, ratio(Color(0xFF767676), Color.White), 0.01)
        assertEquals(0.5f, over(Color(0x80FFFFFF), Color.Black).red, 0.01f)
    }

    @Test
    fun normalPaletteTextTokensClearAAOnEverySurface() {
        val p = AcabPalette.Normal
        for ((sn, s) in surfaces(p)) for ((tn, t) in textTokens(p)) {
            assertTrue("$tn on $sn = ${ratio(t, s)}", ratio(t, s) >= 4.5)
        }
    }

    /** The reason accentText exists: the fill accent is NOT text-safe on the raised surface. */
    @Test
    fun normalFillAccentIsUnderAAOnRaisedSurface() {
        val p = AcabPalette.Normal
        assertTrue(ratio(p.accent, p.bg3) < 4.5)
        assertTrue("still fine as a glyph / fill", ratio(p.accent, p.bg3) >= 3.0)
    }

    @Test
    fun onAccentReadsOnAccentFillInBothPalettes() {
        for (p in listOf(AcabPalette.Normal, AcabPalette.High)) {
            assertTrue(ratio(p.onAccent, p.accent) >= 4.5)
        }
    }

    @Test
    fun faintStaysQuieterThanDimWhichStaysQuieterThanText() {
        for (p in listOf(AcabPalette.Normal, AcabPalette.High)) for ((_, s) in surfaces(p)) {
            assertTrue(ratio(p.faint, s) < ratio(p.dim, s))
            assertTrue(ratio(p.dim, s) < ratio(p.text, s))
        }
    }

    @Test
    fun highPaletteSecondaryTextClearsAAA() {
        val p = AcabPalette.High
        for ((sn, s) in surfaces(p)) {
            for ((tn, t) in listOf("text" to p.text, "dim" to p.dim, "faint" to p.faint, "accentText" to p.accentText)) {
                assertTrue("$tn on $sn = ${ratio(t, s)}", ratio(t, s) >= 7.0)
            }
            for ((tn, t) in textTokens(p)) assertTrue("$tn on $sn", ratio(t, s) >= 4.5)
        }
    }

    @Test
    fun highPaletteStrongLineClearsNonTextMinimum() {
        val p = AcabPalette.High
        for ((sn, s) in surfaces(p)) {
            assertTrue("lineStrong on $sn = ${ratio(p.lineStrong, s)}", ratio(p.lineStrong, s) >= 3.0)
            assertTrue("accent on $sn", ratio(p.accent, s) >= 3.0)
        }
    }

    @Test
    fun highPaletteIsNeverLowerContrastThanNormal() {
        val n = AcabPalette.Normal
        val h = AcabPalette.High
        for ((sN, sH) in surfaces(n).zip(surfaces(h))) {
            for ((tN, tH) in textTokens(n).zip(textTokens(h))) {
                assertTrue("${tN.first} on ${sN.first}", ratio(tH.second, sH.second) >= ratio(tN.second, sN.second))
            }
            assertTrue("line on ${sN.first}", ratio(h.line, sH.second) > ratio(n.line, sN.second))
        }
    }

    @Test
    fun highPaletteKeepsSurfaceHierarchy() {
        val p = AcabPalette.High
        assertTrue(luminance(p.bg) < luminance(p.bg2))
        assertTrue(luminance(p.bg2) < luminance(p.bg3))
    }

    /**
     * Map callouts float over arbitrary tiles. What keeps them readable is that the info surface
     * is OPAQUE: an opaque layer screens the tile off, so the composited backdrop IS the surface
     * and one measurement covers every tile. The two inks are therefore measured once, not
     * re-measured per tile for the same number.
     *
     * The opacity assertion is also the only reliable detector of a surface going translucent,
     * which is why it is asserted directly: a DARK tile bleeding through a sheer surface RAISES
     * contrast against pale ink, so a tile sweep alone could miss it.
     *
     * The sweep instead runs a deliberately sheer cut of the same surface, the one arrangement in
     * which a tile reaches the ink, and asserts every tile MOVES the measurement. That is the
     * compositing path this whole file rests on, kept live. It deliberately does not assert how
     * far the bleed hurts: that number is a fact about this palette being dark, not about the
     * invariant, and it would fire spuriously if the callout were ever restyled light-on-dark.
     * iOS twin: `testMapInformationStaysOpaqueAndReadableOverAnyMapTile`.
     */
    @Test
    fun mapInformationSurfaceIsOpaqueAndItsTextStaysReadableOverAnyTile() {
        val pale = Color.White
        val mid = Color(0xFF888888)
        val dark = Color.Black
        for (p in listOf(AcabPalette.Normal, AcabPalette.High)) {
            val info = mapInfoColors(p)
            assertEquals(1f, info.surface.alpha, 0f)
            val primaryOnSurface = ratio(info.primaryText, info.surface)
            assertTrue("map primary = $primaryOnSurface", primaryOnSurface >= 7.0)
            assertTrue("map secondary = ${ratio(info.secondaryText, info.surface)}",
                ratio(info.secondaryText, info.surface) >= 4.5)

            val sheer = info.surface.copy(alpha = 0.5f)
            for (tile in listOf(pale, mid, dark)) {
                assertNotEquals("a sheer surface must let $tile through",
                    primaryOnSurface, ratio(info.primaryText, over(sheer, tile)), 0.01)
            }
        }
    }

    @Test
    fun sharedHexValuesMatchIos() {
        // Cross-platform drift guard for the values the two palettes are documented to share.
        assertEquals(Color(0xFFFF6A5E), AcabPalette.Normal.accentText)
        assertEquals(Color(0xFFFF8C82), AcabPalette.High.accentText)
        assertEquals(Color(0xFFFF5A4E), AcabPalette.High.accent)
        assertEquals(Color(0xFFFFFFFF), AcabPalette.High.text)
    }

    @Test
    fun acabGettersFollowThePaletteInForce() {
        val before = Acab.palette
        try {
            Acab.palette = AcabPalette.High
            assertTrue(Acab.highContrast)
            assertEquals(AcabPalette.High.faint, Acab.faint)
            Acab.palette = AcabPalette.Normal
            assertFalse(Acab.highContrast)
            assertEquals(AcabPalette.Normal.faint, Acab.faint)
            assertNotEquals(AcabPalette.High.faint, AcabPalette.Normal.faint)
        } finally {
            Acab.palette = before
        }
    }

    @Test
    fun effectiveContrastIsSwitchOrSystem() {
        assertFalse(effectiveHighContrast(forced = false, systemContrast = 0f, systemHighContrastText = false))
        assertTrue(effectiveHighContrast(forced = true, systemContrast = 0f, systemHighContrastText = false))
        assertTrue(effectiveHighContrast(forced = false, systemContrast = 1f, systemHighContrastText = false))
        assertTrue(effectiveHighContrast(forced = false, systemContrast = 0f, systemHighContrastText = true))
        // The medium detent counts; the default (0) and a negative value do not.
        assertTrue(systemAsksForHigherContrast(0.5f, false))
        assertFalse(systemAsksForHigherContrast(0.2f, false))
        assertFalse(systemAsksForHigherContrast(-1f, false))
    }
}
