package tech.acab.app.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import tech.acab.app.R
import tech.acab.app.model.DeviceType

/** Display face (Space Grotesk) and data face (JetBrains Mono) — the same TTFs the
 *  iOS app bundles. Space Grotesk only ships three weights, so SemiBold reuses Bold. */
val SpaceGrotesk = FontFamily(
    Font(R.font.space_grotesk_regular, FontWeight.Normal),
    Font(R.font.space_grotesk_medium, FontWeight.Medium),
    Font(R.font.space_grotesk_bold, FontWeight.SemiBold),
    Font(R.font.space_grotesk_bold, FontWeight.Bold),
)
val JetBrainsMono = FontFamily(
    Font(R.font.jetbrains_mono_regular, FontWeight.Normal),
    Font(R.font.jetbrains_mono_medium, FontWeight.Medium),
    Font(R.font.jetbrains_mono_semibold, FontWeight.SemiBold),
    Font(R.font.jetbrains_mono_bold, FontWeight.Bold),
)

/** The "Crimson" palette, ported from the iOS ACABTheme: dark surfaces, one crimson
 *  accent, amber for drones, teal for trackers. */
object Acab {
    val bg = Color(0xFF0C0A0B)
    val bg2 = Color(0xFF161214)
    val bg3 = Color(0xFF201A1D)
    val line = Color(0x1FEC968C)        // rgb(236,150,140) @ ~11%
    val lineStrong = Color(0x4DEE4034)  // crimson @ 30%

    val text = Color(0xFFF4EEF0)
    val dim = Color(0x99F0E0E2)         // @ 60%
    val faint = Color(0x54F0E0E2)       // @ 33%

    val accent = Color(0xFFEE4034)      // crimson
    val accentGlow = Color(0x8CEE4034)  // @ 55%
    val onAccent = Color(0xFF120A0A)
    val warn = Color(0xFFF2B53C)        // amber

    val flockTone = Color(0xFFEE4034)
    val droneTone = Color(0xFFF2B53C)
    val bodyCamTone = Color(0xFFCDC1C3)
    val trackerTone = Color(0xFF49C5B1)
    val policeTone = Color(0xFF4F7FFF)

    val display = SpaceGrotesk          // default non-mono face
    val mono = JetBrainsMono            // data and label face

    val radius = 18.dp
    val radiusSm = 12.dp
    val pad = 16.dp
}

/** The tone color for a detection type. */
fun DeviceType.tone(): Color = when (this) {
    DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> Acab.flockTone
    DeviceType.DRONE -> Acab.droneTone
    DeviceType.BODY_CAM -> Acab.bodyCamTone
    DeviceType.TRACKER -> Acab.trackerTone
    DeviceType.POLICE_GEAR -> Acab.policeTone
    DeviceType.NEARBY_DEVICE -> Color(0xFFD1AB66)   // desert sand
    DeviceType.UNKNOWN -> Acab.dim
}
