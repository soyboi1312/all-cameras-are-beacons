package tech.acab.app.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.mapInfoColors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Locks the palette to the contrast it claims. Every ratio is measured the way the screen shows
 * it: a translucent tint is composited onto the surface it sits on, then compared against that
 * same surface (WCAG 2.x relative luminance). iOS twin: ContrastPaletteTests (since 2026-09-23 the
 * two platforms twin only the category hues; surfaces, inks and the accent are each platform's
 * own derivation).
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

    private val levels = listOf("Normal" to AcabPalette.Normal, "High" to AcabPalette.High)

    /** The six surfaces text may sit on, lowest to highest. surfaceBright holds no text. */
    private fun surfaces(p: AcabPalette) = listOf(
        "surfaceContainerLowest" to p.surfaceContainerLowest, "surface" to p.surface,
        "surfaceContainerLow" to p.surfaceContainerLow, "surfaceContainer" to p.surfaceContainer,
        "surfaceContainerHigh" to p.surfaceContainerHigh, "surfaceContainerHighest" to p.surfaceContainerHighest,
    )

    /** The surfaces a category WORD may sit on. */
    private fun wordSurfaces(p: AcabPalette) = listOf(
        "surface" to p.surface, "surfaceContainerLow" to p.surfaceContainerLow,
        "surfaceContainer" to p.surfaceContainer,
    )

    private fun inks(p: AcabPalette) = listOf(
        "onSurface" to p.onSurface, "onSurfaceVariant" to p.onSurfaceVariant,
        "primary" to p.primary, "warn" to p.warn,
    )

    private fun tones(p: AcabPalette) = listOf(
        "flockTone" to p.flockTone, "droneTone" to p.droneTone, "bodyCamTone" to p.bodyCamTone,
        "trackerTone" to p.trackerTone, "glassesTone" to p.glassesTone, "watchTone" to p.watchTone,
        "netcamTone" to p.netcamTone, "sandTone" to p.sandTone,
    )

    /** All 36 roles of the M3 1.3.1 dark scheme, scrim last. */
    private fun roles(s: ColorScheme) = listOf(
        "primary" to s.primary, "onPrimary" to s.onPrimary, "primaryContainer" to s.primaryContainer,
        "onPrimaryContainer" to s.onPrimaryContainer, "inversePrimary" to s.inversePrimary,
        "secondary" to s.secondary, "onSecondary" to s.onSecondary,
        "secondaryContainer" to s.secondaryContainer, "onSecondaryContainer" to s.onSecondaryContainer,
        "tertiary" to s.tertiary, "onTertiary" to s.onTertiary, "tertiaryContainer" to s.tertiaryContainer,
        "onTertiaryContainer" to s.onTertiaryContainer, "background" to s.background,
        "onBackground" to s.onBackground, "surface" to s.surface, "onSurface" to s.onSurface,
        "surfaceVariant" to s.surfaceVariant, "onSurfaceVariant" to s.onSurfaceVariant,
        "surfaceTint" to s.surfaceTint, "inverseSurface" to s.inverseSurface,
        "inverseOnSurface" to s.inverseOnSurface, "error" to s.error, "onError" to s.onError,
        "errorContainer" to s.errorContainer, "onErrorContainer" to s.onErrorContainer,
        "outline" to s.outline, "outlineVariant" to s.outlineVariant,
        "surfaceBright" to s.surfaceBright, "surfaceDim" to s.surfaceDim,
        "surfaceContainer" to s.surfaceContainer, "surfaceContainerHigh" to s.surfaceContainerHigh,
        "surfaceContainerHighest" to s.surfaceContainerHighest,
        "surfaceContainerLow" to s.surfaceContainerLow, "surfaceContainerLowest" to s.surfaceContainerLowest,
        "scrim" to s.scrim,
    )

    @Test
    fun wcagMathMatchesKnownAnchors() {
        assertEquals(21.0, ratio(Color.White, Color.Black), 0.01)
        assertEquals(4.54, ratio(Color(0xFF767676), Color.White), 0.01)
        assertEquals(0.5f, over(Color(0x80FFFFFF), Color.Black).red, 0.01f)
    }

    /** Every ink is AAA on every surface text can sit on, at BOTH levels. The tightest pair is
     *  warn on surfaceContainerHighest, which is why that surface is #3A2F30 and not darker-warm
     *  #3D3233: M3's filled Card and filled TextField draw text there. */
    @Test
    fun chromeInksClearAaaOnEverySurfaceAtBothLevels() {
        for ((ln, p) in levels) for ((sn, s) in surfaces(p)) for ((tn, t) in inks(p)) {
            assertTrue("$ln $tn on $sn = ${ratio(t, s)}", ratio(t, s) >= 7.0)
        }
    }

    /** A category WORD (textTone) clears AA at Normal and AAA at High on the three surfaces words
     *  sit on; every category GLYPH (tone) clears the 3:1 non-text minimum on all six surfaces.
     *  Words are kept off surfaceContainerHigh on purpose: netcam measures about 4.18 there at
     *  Normal, so adding that surface to [wordSurfaces] fails this test. */
    @Test
    fun categoryWordsClearTheirFloorWhereTheySitAndGlyphsClearNonTextEverywhere() {
        for ((ln, p) in levels) {
            val floor = if (p === AcabPalette.High) 7.0 else 4.5
            for (type in DeviceType.entries) for ((sn, s) in wordSurfaces(p)) {
                val r = ratio(type.textTone(p), s)
                assertTrue("$ln ${type.name} word on $sn = $r", r >= floor)
            }
            for ((sn, s) in surfaces(p)) for ((tn, t) in tones(p)) {
                assertTrue("$ln $tn glyph on $sn = ${ratio(t, s)}", ratio(t, s) >= 3.0)
            }
        }
    }

    /** The reason ALPR words take the tint: the ALPR hue is NOT text-safe on surfaceContainer
     *  (under AA) though it is fine as a glyph. Every other category word keeps its own hue. */
    @Test
    fun alprWordsTakeTheTintBecauseTheAlprHueIsNotTextSafe() {
        val n = AcabPalette.Normal
        assertTrue(ratio(n.flockTone, n.surfaceContainer) < 4.5)
        assertTrue("still fine as a glyph", ratio(n.flockTone, n.surfaceContainer) >= 3.0)
        for ((ln, p) in levels) {
            assertEquals(ln, p.primary, DeviceType.FLOCK_CAMERA.textTone(p))
            assertEquals(ln, p.primary, DeviceType.FLOCK_RAVEN.textTone(p))
            assertEquals(ln, p.droneTone, DeviceType.DRONE.textTone(p))
        }
    }

    /** The "on" inks read on their own containers at 7:1: onPrimary on primary (switch thumb,
     *  filled button), onPrimaryContainer on primaryContainer (the linked LinkChip), and
     *  onSecondaryContainer on secondaryContainer (nav indicator, selected FilterChip, tonal
     *  button). */
    @Test
    fun onRolesReadOnTheirContainersAtSevenToOne() {
        for ((ln, p) in levels) {
            for ((name, pair) in listOf(
                "onPrimary on primary" to (p.onPrimary to p.primary),
                "onPrimaryContainer on primaryContainer" to (p.onPrimaryContainer to p.primaryContainer),
                "onSecondaryContainer on secondaryContainer" to (p.onSecondaryContainer to p.secondaryContainer),
            )) {
                val r = ratio(pair.first, pair.second)
                assertTrue("$ln $name = $r", r >= 7.0)
            }
        }
    }

    @Test
    fun secondaryInkStaysQuieterThanPrimaryInk() {
        for ((ln, p) in levels) for ((sn, s) in surfaces(p)) {
            assertTrue("$ln on $sn", ratio(p.onSurfaceVariant, s) < ratio(p.onSurface, s))
        }
    }

    @Test
    fun outlineClearsNonTextMinimumOnEverySurface() {
        for ((ln, p) in levels) for ((sn, s) in surfaces(p)) {
            assertTrue("$ln outline on $sn = ${ratio(p.outline, s)}", ratio(p.outline, s) >= 3.0)
        }
    }

    @Test
    fun highPaletteIsNeverLowerContrastThanNormal() {
        val n = AcabPalette.Normal
        val h = AcabPalette.High
        for ((sN, sH) in surfaces(n).zip(surfaces(h))) {
            val pairs = (inks(n) + tones(n) + listOf("outline" to n.outline))
                .zip(inks(h) + tones(h) + listOf("outline" to h.outline))
            for ((tN, tH) in pairs) {
                assertTrue("${tN.first} on ${sN.first}",
                    ratio(tH.second, sH.second) >= ratio(tN.second, sN.second))
            }
            assertTrue("outlineVariant on ${sN.first}",
                ratio(h.outlineVariant, sH.second) > ratio(n.outlineVariant, sN.second))
        }
    }

    /** The M3 surface ladder rises in luminance, and both contrast levels share it, so the High
     *  level changes only what is drawn ON the surfaces (and every Acab.highContrast cache stays
     *  valid). */
    @Test
    fun surfaceLadderRisesAndIsSharedByBothLevels() {
        for ((ln, p) in levels) {
            val ladder = listOf(
                p.surfaceContainerLowest, p.surface, p.surfaceContainerLow, p.surfaceContainer,
                p.surfaceContainerHigh, p.surfaceContainerHighest, p.surfaceBright,
            )
            for (i in 1 until ladder.size) {
                assertTrue("$ln ladder step $i", luminance(ladder[i - 1]) < luminance(ladder[i]))
            }
        }
        val n = AcabPalette.Normal
        val h = AcabPalette.High
        assertEquals(surfaces(n), surfaces(h))
        assertEquals(n.surfaceBright, h.surfaceBright)
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

    /** Cross-platform drift guard for what the two palettes still share: the category hues (the
     *  iOS widget's WidgetTheme repeats the six detection hues). The accent and ink pins retired
     *  with Route A (each platform derives its own). onAccent is an ink and is deliberately NOT
     *  pinned here. iOS twin: ContrastPaletteTests. */
    @Test
    fun categoryHuesMatchIosAndTheWidgets() {
        val n = AcabPalette.Normal
        assertEquals(Color(0xFFEE4034), n.flockTone)
        assertEquals(Color(0xFFF2B53C), n.droneTone)
        assertEquals(Color(0xFFCDC1C3), n.bodyCamTone)
        assertEquals(Color(0xFF49C5B1), n.trackerTone)
        assertEquals(Color(0xFFB07CFF), n.glassesTone)
        assertEquals(Color(0xFFE0A84B), n.watchTone)
        assertEquals(Color(0xFF3D8BFF), n.netcamTone)
        assertEquals(Color(0xFFD1AB66), n.sandTone)
        val h = AcabPalette.High
        assertEquals(Color(0xFFFF5A4E), h.flockTone)
        assertEquals(Color(0xFFF7C24E), h.droneTone)
        assertEquals(Color(0xFFE4DADC), h.bodyCamTone)
        assertEquals(Color(0xFF6FE0CE), h.trackerTone)
        assertEquals(Color(0xFFC9A6FF), h.glassesTone)
        assertEquals(Color(0xFFF0BE5E), h.watchTone)
        assertEquals(Color(0xFF74ACFF), h.netcamTone)
        assertEquals(Color(0xFFE0BE7A), h.sandTone)
    }

    @Test
    fun acabGettersFollowThePaletteInForce() {
        val before = Acab.palette
        try {
            for (p in listOf(AcabPalette.High, AcabPalette.Normal)) {
                Acab.palette = p
                assertEquals(p === AcabPalette.High, Acab.highContrast)
                assertEquals(p.primary, Acab.tint)
                assertEquals(p.surfaceContainer, Acab.bg2)
                assertEquals(p.onSurfaceVariant, Acab.dim)
                assertEquals(Acab.dim, Acab.faint)
                assertEquals(Acab.accent, Acab.accentText)
                assertEquals(p.onSurface, Acab.colorScheme.onSurface)
                assertSame("the scheme is cached, never rebuilt per read", Acab.colorScheme, Acab.colorScheme)
            }
            assertNotEquals(AcabPalette.High.primary, AcabPalette.Normal.primary)
        } finally {
            Acab.palette = before
        }
    }

    /** The Status radar keeps its pre-redesign instrument colours (the owner's call, 2026-09-25):
     *  the old page colour as the disc, the old `line` rings, the old `lineStrong` edge and
     *  Android's old `accentGlow` sweep, at both levels, byte for byte from the pre-redesign
     *  Theme.kt. The ring words, the count and the dots all sit on the disc (on disc-coloured
     *  plates and knockout rings), so their floors are measured there too. iOS twin:
     *  ContrastPaletteTests (same names, same disc / ring / edge; the sweep is each platform's own). */
    @Test
    fun radarKeepsThePreRedesignColours() {
        val n = AcabPalette.Normal
        assertEquals(Color(0xFF0C0A0B), n.radarDisc)
        assertEquals(Color(0x1CEC968C), n.radarRing)
        assertEquals(Color(0x4DEE4034), n.radarEdge)
        assertEquals(Color(0x8CEE4034), n.radarSweep)
        val h = AcabPalette.High
        assertEquals(Color(0xFF0C0A0B), h.radarDisc)
        assertEquals(Color(0x4DEC968C), h.radarRing)
        assertEquals(Color(0xB8FF5A4E), h.radarEdge)
        assertEquals(Color(0xA6FF5A4E), h.radarSweep)
        for ((ln, p) in levels) {
            assertEquals("$ln disc is opaque", 1f, p.radarDisc.alpha, 0f)
            for ((kn, k) in inks(p)) {
                assertTrue("$ln $kn on the radar disc = ${ratio(k, p.radarDisc)}", ratio(k, p.radarDisc) >= 7.0)
            }
            for ((tn, t) in tones(p)) {
                assertTrue("$ln $tn dot on the radar disc = ${ratio(t, p.radarDisc)}", ratio(t, p.radarDisc) >= 3.0)
            }
        }
        // Radar-only: no M3 role carries a radar token, so no other surface picks them up.
        for ((ln, p) in levels) {
            val carried = roles(p.toColorScheme()).map { it.second }
            for (c in listOf(p.radarDisc, p.radarRing, p.radarEdge, p.radarSweep)) {
                assertFalse("$ln $c leaked into the scheme", c in carried)
            }
        }
    }

    @Test
    fun crimsonInkTwinsTheIosTint() {
        // iOS draws the motto's "watch back." and the Beacon hero's edge, board glyph and charging
        // fill in ACABPalette.tint: 0xFF6A5E normal, 0xFF8C82 high.
        assertEquals(Color(0xFFFF6A5E), AcabPalette.Normal.crimsonInk)
        assertEquals(Color(0xFFFF8C82), AcabPalette.High.crimsonInk)
        for ((ln, p) in levels) {
            val r = ratio(p.crimsonInk, p.surface)
            assertTrue("$ln motto crimson on the page = $r", r >= 4.5)
            // The hero's board glyph (a graphic, 3:1) on its tile: this ink at 16% over the card.
            val tile = over(p.crimsonInk.copy(alpha = 0.16f), p.surfaceContainer)
            val g = ratio(p.crimsonInk, tile)
            assertTrue("$ln hero glyph on its tile = $g", g >= 3.0)
        }
        // Not an M3 role: primary stays the tonal salmon, so only the named readers turn crimson.
        for ((ln, p) in levels) {
            assertFalse("$ln crimsonInk leaked into the scheme",
                p.crimsonInk in roles(p.toColorScheme()).map { it.second })
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

    /** Normal IS the M3 dark scheme from the crimson seed, as the Route A brief gives it. */
    @Test
    fun normalSchemeIsTheCrimsonSeedScheme() {
        val s = AcabPalette.Normal.toColorScheme()
        assertEquals(Color(0xFF1A1112), s.surface)
        assertEquals(Color(0xFF271D1E), s.surfaceContainer)
        assertEquals(Color(0xFF352A2B), s.surfaceContainerHigh)
        assertEquals(Color(0xFFFFB4AB), s.primary)
        assertEquals(Color(0xFF93000A), s.primaryContainer)
        assertEquals(Color(0xFFFFDAD6), s.onPrimaryContainer)
        assertEquals(Color(0xFFF1DEDE), s.onSurface)
        assertEquals(Color(0xFFD8C2BF), s.onSurfaceVariant)
        assertEquals(Color(0xFFA08C8A), s.outline)
        assertEquals(Color(0xFF534341), s.outlineVariant)
        assertEquals(Color(0xFFF2B53C), AcabPalette.Normal.warn)
    }

    /** toColorScheme sets every role from the palette. darkColorScheme() falls back to the
     *  baseline purple for any role left out, so a dropped argument must fail here. */
    @Test
    fun colorSchemeCarriesEveryRoleFromThePalette() {
        for ((ln, p) in levels) {
            val s = p.toColorScheme()
            val expected = listOf(
                "primary" to p.primary, "onPrimary" to p.onPrimary, "primaryContainer" to p.primaryContainer,
                "onPrimaryContainer" to p.onPrimaryContainer, "inversePrimary" to p.primaryContainer,
                "secondary" to p.onSurfaceVariant, "onSecondary" to p.surface,
                "secondaryContainer" to p.secondaryContainer, "onSecondaryContainer" to p.onSecondaryContainer,
                "tertiary" to p.onSurfaceVariant, "onTertiary" to p.surface,
                "tertiaryContainer" to p.secondaryContainer, "onTertiaryContainer" to p.onSecondaryContainer,
                "background" to p.surface, "onBackground" to p.onSurface, "surface" to p.surface,
                "onSurface" to p.onSurface, "surfaceVariant" to p.surfaceContainerHighest,
                "onSurfaceVariant" to p.onSurfaceVariant, "surfaceTint" to p.primary,
                "inverseSurface" to p.onSurface, "inverseOnSurface" to p.surfaceContainerHigh,
                "error" to p.primary, "onError" to p.onPrimary, "errorContainer" to p.primaryContainer,
                "onErrorContainer" to p.onPrimaryContainer, "outline" to p.outline,
                "outlineVariant" to p.outlineVariant, "surfaceBright" to p.surfaceBright,
                "surfaceDim" to p.surface, "surfaceContainer" to p.surfaceContainer,
                "surfaceContainerHigh" to p.surfaceContainerHigh,
                "surfaceContainerHighest" to p.surfaceContainerHighest,
                "surfaceContainerLow" to p.surfaceContainerLow,
                "surfaceContainerLowest" to p.surfaceContainerLowest, "scrim" to Color.Black,
            )
            assertEquals(roles(s).map { it.first }, expected.map { it.first })
            for ((actual, want) in roles(s).zip(expected)) {
                assertEquals("$ln ${actual.first}", want.second, actual.second)
            }
            // No baseline purple leaks into any role but scrim (black on both).
            val baseline = roles(darkColorScheme())
            for ((actual, base) in roles(s).zip(baseline).dropLast(1)) {
                assertNotEquals("$ln ${actual.first} is the M3 baseline", base.second, actual.second)
            }
        }
        val probe = AcabPalette.Normal.copy(surfaceContainer = Color.Magenta).toColorScheme()
        assertEquals(Color.Magenta, probe.surfaceContainer)
    }

    /** Amber is an app token BESIDE the scheme: error is the primary (this seed's error palette IS
     *  its primary palette), and no M3 role carries warn, so an M3 error state never reads amber. */
    @Test
    fun warnStaysBesideTheScheme() {
        for ((ln, p) in levels) {
            val s = p.toColorScheme()
            assertEquals(ln, p.primary, s.error)
            assertNotEquals(ln, p.primary, p.warn)
            for ((name, c) in roles(s)) assertNotEquals("$ln $name carries warn", p.warn, c)
        }
    }

    /** CatGlyph draws the tone on its own tone at CAT_GLYPH_FILL_ALPHA, over surface or
     *  surfaceContainer. Every glyph keeps the 3:1 non-text minimum there. */
    @Test
    fun categoryGlyphReadsOnItsTonalContainer() {
        for ((ln, p) in levels) for ((sn, s) in listOf("surface" to p.surface, "surfaceContainer" to p.surfaceContainer)) {
            for ((tn, t) in tones(p)) {
                val container = over(t.copy(alpha = CAT_GLYPH_FILL_ALPHA), s)
                val r = ratio(t, container)
                assertTrue("$ln $tn glyph on its container over $sn = $r", r >= 3.0)
            }
        }
    }

    /** SignalBars' default lit bar (onSurfaceVariant) separates from the unlit bar
     *  (outlineVariant) at the non-text minimum, so a bar count reads without a tone. */
    @Test
    fun defaultSignalBarsSeparateLitFromUnlit() {
        for ((ln, p) in levels) {
            val r = ratio(p.onSurfaceVariant, p.outlineVariant)
            assertTrue("$ln lit vs unlit = $r", r >= 3.0)
        }
    }
}
