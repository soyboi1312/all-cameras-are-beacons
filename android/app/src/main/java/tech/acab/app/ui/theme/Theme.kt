package tech.acab.app.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.compose.ui.unit.sp
import tech.acab.app.R
import tech.acab.app.model.DeviceType

/** Alpha of a category glyph's tonal container ([tech.acab.app.ui.CatGlyph]). Low enough that
 *  every category glyph keeps 3:1 over its own container (pinned by AcabPaletteTest). */
const val CAT_GLYPH_FILL_ALPHA = 0.16f

/** The M3 1.3.1 default type scale on the system face (Roboto). C4 (no bundled face) holds for
 *  every role here; R16 amends it for the instrument layer only ([telemetry]), and the connect
 *  wordmark draws [WordmarkFace]. */
internal val AcabTypography = Typography()

// ---- Instrument layer (JetBrains Mono), decision R16 (2026-09-26) ----
// The ONE place the bundled mono face is chosen. It is for SHORT instrument text only: uppercase
// identifier labels (section headers, kickers, ring words, tile labels), telemetry lines (a
// sighting's lines under its name, the Beacon rows' state lines, the hero status line), trailing
// values and numbers and identifiers (dBm, MAC, uptime, counts, coordinates). Titles, row titles,
// buttons, body copy, help text and the sample banner stay on the M3 roles above (Roboto); the
// wordmark and the Status motto keep their own Space Grotesk faces.
// TWIN: iOS ACABTheme.telemetry / telemetryFixed / telemetryTracking / isInstrumentLabel in
// Views/Theme.swift, the same rule on iOS's own text styles.

/** JetBrains Mono, all four bundled cuts, so a role's own weight resolves to a real cut. */
val JetBrainsMono = FontFamily(
    Font(R.font.jetbrains_mono_regular, FontWeight.Normal),
    Font(R.font.jetbrains_mono_medium, FontWeight.Medium),
    Font(R.font.jetbrains_mono_semibold, FontWeight.SemiBold),
    Font(R.font.jetbrains_mono_bold, FontWeight.Bold),
)

/** Mono reads optically larger than Roboto at the same size (a taller x-height and a 0.6em
 *  advance on every glyph), so a telemetry style is its role's size times this. The same factor
 *  as iOS ACABTheme.telemetryScale. */
const val TELEMETRY_SCALE = 0.9f

/** Letter spacing for uppercase instrument labels only, the spaced capitals of iOS
 *  ACABTheme.telemetryTracking (0.8pt). In sp, so it grows with the font scale like the glyphs it
 *  spaces. Telemetry lines and values take none. */
val TELEMETRY_TRACKING: TextUnit = 0.8.sp

/** Pure: whether a label is an instrument identifier (the C2 rule: uppercase identifiers are
 *  chrome, anything with a lowercase letter is copy). "6 ON · 1 EXP" is; "radios, detectors,
 *  desert mode" is not. A string with no letters at all (a bare count) is not a label.
 *  TWIN: iOS ACABTheme.isInstrumentLabel, the same two tests. Runs per Kicker composition: one
 *  pass over a short string, no allocation. */
fun isInstrumentLabel(text: String): Boolean =
    text.any { it.isLetter() } && text.none { it.isLowerCase() }

/** This role in the instrument face: JetBrains Mono at [TELEMETRY_SCALE] of the role's size, in
 *  sp, so it scales with the font scale (Android 14's nonlinear curve included). The line height
 *  is the role's own, left as it is, so a row or a plate keeps the height it had in Roboto.
 *  [weight] null keeps the role's own weight; [tracked] adds [TELEMETRY_TRACKING] (uppercase
 *  labels only), otherwise tracking is zero, as every telegram style here already had it.
 *  Allocates a style: on a publish-rate path hoist the result to a file-level val, or remember it
 *  on its inputs (Kicker does). */
fun TextStyle.telemetry(weight: FontWeight? = null, tracked: Boolean = false): TextStyle = copy(
    fontFamily = JetBrainsMono,
    fontWeight = weight ?: fontWeight,
    fontSize = if (fontSize.isSpecified) fontSize * TELEMETRY_SCALE else fontSize,
    letterSpacing = if (tracked) TELEMETRY_TRACKING else 0.sp,
)

/** The connect screen's wordmark face: Space Grotesk Bold, the pre-redesign wordmark's face (its
 *  WordmarkHero drew Acab.display, then Space Grotesk, at FontWeight.Bold). Only AcabApp's
 *  ConnectWordmark reads it. */
val WordmarkFace = FontFamily(Font(R.font.space_grotesk_bold, FontWeight.Bold))

/** The M3 1.3.1 default shapes: small 8dp, medium 12dp (Android's card radius), large 16dp. */
internal val AcabShapes = Shapes()

/** Fixed-width digits. Stock Roboto figures are already tabular; OEM faces that replace
 *  FontFamily.Default may not be. */
const val TABULAR_FIGURES = "tnum"

/** Use on a number that updates in place while visible (counts, dBm, battery %, ages) or that is
 *  compared down a column (timestamps, MAC, coordinates); never inside prose. On a publish-rate
 *  path hoist the result to a file-level val instead of calling this per composition. */
fun TextStyle.tabular(): TextStyle = copy(fontFeatureSettings = TABULAR_FIGURES)

/** The complete colour token set for ONE contrast level, named by Material 3 role. Two instances
 *  exist: [Normal] and [High]. [Acab] exposes whichever is in force, and [toColorScheme] feeds the
 *  same values to MaterialTheme.
 *
 *  - [Normal] is the M3 dark scheme from the crimson seed, as the Route A brief gives it
 *    (surface #1A1112, surfaceContainer #271D1E, primary #FFB4AB, ...). The roles the brief does
 *    not give are hand-derived from the same palette, so no second hue enters.
 *  - [High] is hand-derived on the SAME surfaces (the surface ladder and every cache keyed on
 *    [Acab.highContrast] stay valid). Every ink is raised, never lowered.
 *  - Inks (onSurface, onSurfaceVariant, primary, [warn]) clear 7:1 on all six text surfaces at
 *    both levels; that is why surfaceContainerHighest is #3A2F30 (M3 filled Card and filled
 *    TextField draw text on it). Category WORDS sit only on surface, surfaceContainerLow and
 *    surfaceContainer; category GLYPHS clear 3:1 on every surface. AcabPaletteTest pins all of it.
 *  - [warn] is an app token BESIDE the scheme, never an M3 role: error == primary in this seed,
 *    so amber must not become M3 error.
 *
 *  Cross-platform: since 2026-09-23 the surfaces, inks and the accent are Android's own
 *  derivation. They do NOT twin iOS ACABPalette (Theme.swift) or the soyboi.tech css any more.
 *  Android folds the old `faint` step into onSurfaceVariant, so iOS `faint` and the site's
 *  `--text-faint` no longer twin this file either. `onAccent` is an ink (an alias of onPrimary
 *  here) and does not twin iOS. What STAYS byte-identical with iOS ACABPalette.normal / .high is
 *  the category hues: the seven tones and sand below (AcabPaletteTest
 *  categoryHuesMatchIosAndTheWidgets; iOS twin ContrastPaletteTests). The iOS widget's
 *  WidgetTheme repeats the six detection hues; the Android widget draws none.
 *
 *  The legacy names (bg, text, dim, accent, ...) are alias properties over the roles, so every
 *  reader that has not moved to MaterialTheme.colorScheme keeps compiling.
 *
 *  The four radar* tokens are the Status radar's own instrument colours and nothing else reads
 *  them: the pre-redesign disc, rings, edge and sweep, which the owner kept on 2026-09-25 over
 *  the Route A grey disc and low-alpha primary sweep. They are no M3 role and map to none in
 *  [toColorScheme]. TWIN: iOS ACABPalette.radarDisc / radarRing / radarEdge / radarSweep in
 *  Theme.swift, same names and the same disc, ring and edge values; the sweep is each
 *  platform's OWN old sweep (see [radarSweep]). AcabPaletteTest radarKeepsThePreRedesignColours. */
data class AcabPalette(
    val surfaceContainerLowest: Color, val surface: Color, val surfaceContainerLow: Color,
    val surfaceContainer: Color, val surfaceContainerHigh: Color, val surfaceContainerHighest: Color,
    val surfaceBright: Color,
    val onSurface: Color, val onSurfaceVariant: Color, val outline: Color, val outlineVariant: Color,
    val primary: Color, val onPrimary: Color, val primaryContainer: Color, val onPrimaryContainer: Color,
    val secondaryContainer: Color, val onSecondaryContainer: Color,
    val warn: Color,
    val flockTone: Color, val droneTone: Color, val bodyCamTone: Color, val trackerTone: Color,
    val glassesTone: Color, val watchTone: Color, val netcamTone: Color, val sandTone: Color,
    /** Radar fill and the dots' knockout ring: the old page colour, a warm near-black. The old
     *  radar had no fill of its own. The ring-word and TOTAL NEARBY plates went with R18. */
    val radarDisc: Color,
    /** Radar inner and middle rings: the old hairline `line`, rgb(236,150,140) at low alpha. */
    val radarRing: Color,
    /** Radar outer ring (ring 3, the disc edge): the old `lineStrong`, a crimson hairline. */
    val radarEdge: Color,
    /** Radar sweep's leading edge: Android's old `accentGlow`, plain SrcOver. iOS keeps its own
     *  old sweep (the accent at 0.40 with a screen blend), so this value does not twin iOS. */
    val radarSweep: Color,
    /** The vivid crimson ink, iOS's tint, where Android must read as crimson rather than as the
     *  M3 [primary] (a paler tonal salmon). Two readers, both the owner's 2026-09-25 calls:
     *  - the motto's "watch back." (Status PunkLine), the pre-redesign crimson text ink of the
     *    owner's reference screenshot;
     *  - the Beacon hero card (DeviceScreen.kt DeviceHero, R13 candidate A): its 1dp edge at 35%,
     *    the board mark's glyph at full strength on a tile of this ink at 16%, and the battery
     *    gauge's charging fill (HeroBattery), the alphas and uses of iOS BeaconCard / heroBadge /
     *    heroBattery.
     *  No M3 role maps to it. TWIN: iOS ACABPalette.tint (ACABTheme.tint, and accentText, its
     *  alias) in Theme.swift, the same values at both levels. AcabPaletteTest
     *  crimsonInkTwinsTheIosTint. */
    val crimsonInk: Color,
) {
    // LEGACY aliases: every reader outside a composition (mapInfoColors, MapMarkers, dimTone) and
    // every screen not yet moved to scheme roles keeps compiling through these.
    val bg: Color get() = surface
    val bg2: Color get() = surfaceContainer
    val bg3: Color get() = surfaceContainerHigh
    val line: Color get() = outlineVariant
    val lineStrong: Color get() = outline
    val text: Color get() = onSurface
    val dim: Color get() = onSurfaceVariant
    /** The three-step ink is retired: faint IS dim now. A dim-vs-faint ternary carries no cue. */
    val faint: Color get() = onSurfaceVariant
    val accent: Color get() = primary
    /** On Android the tint is already the text-safe crimson, so the fill and text cuts are one. */
    val accentText: Color get() = primary
    val onAccent: Color get() = onPrimary

    companion object {
        val Normal = AcabPalette(
            surfaceContainerLowest = Color(0xFF140C0D),
            surface = Color(0xFF1A1112),
            surfaceContainerLow = Color(0xFF22191A),
            surfaceContainer = Color(0xFF271D1E),
            surfaceContainerHigh = Color(0xFF352A2B),
            surfaceContainerHighest = Color(0xFF3A2F30),
            surfaceBright = Color(0xFF423738),      // holds no text
            onSurface = Color(0xFFF1DEDE),
            onSurfaceVariant = Color(0xFFD8C2BF),
            outline = Color(0xFFA08C8A),            // control edges; never text
            outlineVariant = Color(0xFF534341),     // decorative dividers
            primary = Color(0xFFFFB4AB),
            onPrimary = Color(0xFF690005),
            primaryContainer = Color(0xFF93000A),
            onPrimaryContainer = Color(0xFFFFDAD6),
            secondaryContainer = Color(0xFF5D3F3B),
            onSecondaryContainer = Color(0xFFFFDAD6),
            warn = Color(0xFFF2B53C),               // amber
            flockTone = Color(0xFFEE4034),
            droneTone = Color(0xFFF2B53C),
            bodyCamTone = Color(0xFFCDC1C3),
            trackerTone = Color(0xFF49C5B1),
            glassesTone = Color(0xFFB07CFF),        // violet
            watchTone = Color(0xFFE0A84B),          // gold, user-starred (watched) devices
            netcamTone = Color(0xFF3D8BFF),         // blue, network cameras on wifi
            sandTone = Color(0xFFD1AB66),           // desert sand, nearby devices
            // pre-redesign radar, kept by the owner 2026-09-25
            radarDisc = Color(0xFF0C0A0B),          // the old page, warm near-black
            radarRing = Color(0x1CEC968C),          // rgb(236,150,140) @ 11%
            radarEdge = Color(0x4DEE4034),          // crimson @ 30%
            radarSweep = Color(0x8CEE4034),         // crimson @ 55%
            crimsonInk = Color(0xFFFF6A5E),         // iOS tint, normal
        )

        /** Same surfaces as [Normal]; every ink, outline and "on container" ink raised. onPrimary
         *  stays #690005 and reads higher on the raised primary. */
        val High = AcabPalette(
            surfaceContainerLowest = Color(0xFF140C0D),
            surface = Color(0xFF1A1112),
            surfaceContainerLow = Color(0xFF22191A),
            surfaceContainer = Color(0xFF271D1E),
            surfaceContainerHigh = Color(0xFF352A2B),
            surfaceContainerHighest = Color(0xFF3A2F30),
            surfaceBright = Color(0xFF423738),
            onSurface = Color(0xFFFFFFFF),
            onSurfaceVariant = Color(0xFFEDDAD7),
            outline = Color(0xFFC4B0AD),
            outlineVariant = Color(0xFF7A6664),
            primary = Color(0xFFFFCFC9),
            onPrimary = Color(0xFF690005),
            primaryContainer = Color(0xFF93000A),
            onPrimaryContainer = Color(0xFFFFFFFF),
            secondaryContainer = Color(0xFF5D3F3B),
            onSecondaryContainer = Color(0xFFFFFFFF),
            warn = Color(0xFFF7C24E),
            flockTone = Color(0xFFFF5A4E),
            droneTone = Color(0xFFF7C24E),
            bodyCamTone = Color(0xFFE4DADC),
            trackerTone = Color(0xFF6FE0CE),
            glassesTone = Color(0xFFC9A6FF),
            watchTone = Color(0xFFF0BE5E),
            netcamTone = Color(0xFF74ACFF),
            sandTone = Color(0xFFE0BE7A),
            // pre-redesign radar at the old high level, kept by the owner 2026-09-25
            radarDisc = Color(0xFF0C0A0B),
            radarRing = Color(0x4DEC968C),          // rgb(236,150,140) @ 30%
            radarEdge = Color(0xB8FF5A4E),          // lighter crimson @ 72%
            radarSweep = Color(0xA6FF5A4E),         // lighter crimson @ 65%
            crimsonInk = Color(0xFFFF8C82),         // iOS tint, high
        )
    }
}

/** Every one of the 36 M3 roles, set explicitly: darkColorScheme() falls back to the baseline
 *  purple for any role left out. Secondary and tertiary alias existing roles (no second hue),
 *  error IS the primary set (the seed's error palette is its primary palette), and [warn] maps to
 *  no role. Pure, not @Composable: AcabPaletteTest runs it on the plain JVM. */
fun AcabPalette.toColorScheme(): ColorScheme = darkColorScheme(
    primary = primary, onPrimary = onPrimary, primaryContainer = primaryContainer,
    onPrimaryContainer = onPrimaryContainer, inversePrimary = primaryContainer,
    secondary = onSurfaceVariant, onSecondary = surface, secondaryContainer = secondaryContainer,
    onSecondaryContainer = onSecondaryContainer,
    tertiary = onSurfaceVariant, onTertiary = surface, tertiaryContainer = secondaryContainer,
    onTertiaryContainer = onSecondaryContainer,
    background = surface, onBackground = onSurface, surface = surface, onSurface = onSurface,
    surfaceVariant = surfaceContainerHighest, onSurfaceVariant = onSurfaceVariant, surfaceTint = primary,
    inverseSurface = onSurface, inverseOnSurface = surfaceContainerHigh,
    error = primary, onError = onPrimary, errorContainer = primaryContainer, onErrorContainer = onPrimaryContainer,
    outline = outline, outlineVariant = outlineVariant, scrim = Color.Black,
    surfaceBright = surfaceBright, surfaceDim = surface, surfaceContainer = surfaceContainer,
    surfaceContainerHigh = surfaceContainerHigh, surfaceContainerHighest = surfaceContainerHighest,
    surfaceContainerLow = surfaceContainerLow, surfaceContainerLowest = surfaceContainerLowest,
)

// Built once per process; Acab.colorScheme hands out one of these two, never a fresh scheme.
private val NormalScheme = AcabPalette.Normal.toColorScheme()
private val HighScheme = AcabPalette.High.toColorScheme()

/** The palette in force, plus type and shape tokens.
 *
 *  Every colour is a getter over [palette], a Compose snapshot state, so a composable that reads
 *  one recomposes when ContrastMode swaps the palette. Two rules for new code:
 *  - Composable code reads MaterialTheme.colorScheme / MaterialTheme.typography (CompositionLocal
 *    reads, installed once by [AcabTheme]).
 *  - Code outside a composition reads `Acab.palette.<role>`, [tint], [warn] or the tones. Anything
 *    that CACHES a rendered colour (map marker bitmaps) keys its cache on [highContrast]; see
 *    MapMarkers.kt.
 *  The legacy getters below (bg ... onAccent) are aliases kept for the screens that have not moved
 *  to scheme roles. `text` and `accentText` are permanent. */
object Acab {
    /** Set only by ContrastMode. */
    var palette: AcabPalette by mutableStateOf(AcabPalette.Normal)
        internal set

    /** True while the higher-contrast palette is in force. Use as a remember() key. */
    val highContrast: Boolean get() = palette === AcabPalette.High

    /** The M3 scheme for the palette in force. Cached: never rebuilt per read. */
    val colorScheme: ColorScheme get() = if (highContrast) HighScheme else NormalScheme

    /** The crimson (primary) for readers outside a composition. */
    val tint: Color get() = palette.primary

    // LEGACY aliases (see AcabPalette).
    val bg: Color get() = palette.bg
    val bg2: Color get() = palette.bg2
    val bg3: Color get() = palette.bg3
    val line: Color get() = palette.line
    val lineStrong: Color get() = palette.lineStrong

    val text: Color get() = palette.text
    val dim: Color get() = palette.dim
    val faint: Color get() = palette.faint

    val accent: Color get() = palette.accent
    /** Crimson for TEXT. On Android this is the same colour as [accent]: the tint is text-safe. */
    val accentText: Color get() = palette.accentText
    val onAccent: Color get() = palette.onAccent
    val warn: Color get() = palette.warn

    val flockTone: Color get() = palette.flockTone
    val droneTone: Color get() = palette.droneTone
    val bodyCamTone: Color get() = palette.bodyCamTone
    val trackerTone: Color get() = palette.trackerTone
    val glassesTone: Color get() = palette.glassesTone
    val watchTone: Color get() = palette.watchTone
    val netcamTone: Color get() = palette.netcamTone
    val sandTone: Color get() = palette.sandTone

    // Both legacy faces are the system face (Roboto), C4: their readers are prose and buttons in
    // sub-screens, so they did NOT move to the instrument face. The two bundled faces that app
    // screens draw are named on their own: [JetBrainsMono] through [telemetry] (R16) and
    // [WordmarkFace]. The TTFs in res/font also serve the home-screen widget layouts.
    val display: FontFamily = FontFamily.Default
    val mono: FontFamily = FontFamily.Default

    val radius = 12.dp      // = AcabShapes.medium, the M3 card radius (Android's own, C5)
    val radiusSm = 8.dp     // = AcabShapes.small
    val pad = 16.dp         // screen gutter, Android's own derivation (M3)
    val padCard = 16.dp     // card interiors
}

/** The app's one MaterialTheme. Install it ONLY at the Compose root (MainActivity.setContent),
 *  never inside AcabApp or MainScreen, which recompose per BLE publish. Its scope reads only
 *  Acab.palette, so it recomposes only on a contrast switch. */
@Composable
fun AcabTheme(content: @Composable () -> Unit) {
    val scheme = Acab.colorScheme
    // PERMANENT guard, captured OUTSIDE MaterialTheme on purpose: MaterialTheme provides bodyLarge
    // (24sp line, 0.5sp tracking) as LocalTextStyle, and the many un-migrated `fontSize =` Text
    // sites would reflow silently, the inherit-only screens included. Most M3 components set
    // their own type roles, but the text inputs do NOT: SearchBarDefaults.InputField has no
    // textStyle parameter and reads LocalTextStyle, and TextField / OutlinedTextField default
    // textStyle to LocalTextStyle.current. Under this guard they draw TextStyle.Default. So wrap a
    // SearchBar in ProvideTextStyle(MaterialTheme.typography.bodyLarge), and pass
    // textStyle = bodyLarge to a new TextField. Other new code passes
    // style = MaterialTheme.typography.<role>.
    val base = LocalTextStyle.current
    MaterialTheme(colorScheme = scheme, typography = AcabTypography, shapes = AcabShapes) {
        CompositionLocalProvider(
            LocalTextStyle provides base,
            // A bare Text / Icon outside a Surface draws onSurface, not the library's black.
            LocalContentColor provides scheme.onSurface,
            content = content,
        )
    }
}

/** The tone for a detection type in palette [p]: fills, pins, bars, icons. */
internal fun DeviceType.tone(p: AcabPalette): Color = when (this) {
    DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> p.flockTone
    DeviceType.DRONE -> p.droneTone
    DeviceType.BODY_CAM -> p.bodyCamTone
    DeviceType.TRACKER -> p.trackerTone
    DeviceType.GLASSES -> p.glassesTone
    DeviceType.NEARBY_DEVICE -> p.sandTone          // desert sand
    DeviceType.WATCHED -> p.watchTone               // gold star, the user's own rule
    DeviceType.NETWORK_CAMERA -> p.netcamTone       // blue, IP camera on wifi
    DeviceType.UNKNOWN -> p.onSurfaceVariant
}

/** The tone color for a detection type in the palette in force. */
fun DeviceType.tone(): Color = tone(Acab.palette)

/** A category WORD in palette [p]. ALPR words take the tint: the ALPR hue is under AA as text on
 *  surfaceContainer, the tint is well over it (AcabPaletteTest
 *  alprWordsTakeTheTintBecauseTheAlprHueIsNotTextSafe). On Android the tint IS the text-safe cut.
 *  Words sit only on surface / surfaceContainerLow / surfaceContainer. iOS twin:
 *  DeviceType.textTint. */
internal fun DeviceType.textTone(p: AcabPalette): Color = when (this) {
    DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> p.primary
    else -> tone(p)
}

/** [textTone] in the palette in force. */
fun DeviceType.textTone(): Color = textTone(Acab.palette)
