package tech.acab.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.LocalPolice
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone

/** Small uppercase mono label, for section headers and data captions. */
@Composable
fun Kicker(text: String, color: androidx.compose.ui.graphics.Color = Acab.faint) {
    Text(
        text,
        color = color,
        fontSize = 10.sp,
        letterSpacing = 1.5.sp,
        fontWeight = FontWeight.Medium,
        fontFamily = Acab.mono,
    )
}

/** Card look: bg2 fill, hairline border, rounded corners. */
fun Modifier.panel(strong: Boolean = false): Modifier = this
    .background(Acab.bg2, RoundedCornerShape(Acab.radius))
    .border(1.dp, if (strong) Acab.lineStrong else Acab.line, RoundedCornerShape(Acab.radius))
    .padding(Acab.pad)

internal fun DeviceType.icon(): ImageVector = when (this) {
    DeviceType.FLOCK_CAMERA -> Icons.Filled.PhotoCamera
    DeviceType.FLOCK_RAVEN -> Icons.Filled.GraphicEq
    DeviceType.BODY_CAM -> Icons.Filled.Videocam
    DeviceType.DRONE -> Icons.Filled.Flight
    DeviceType.TRACKER -> Icons.Filled.Sensors
    DeviceType.POLICE_GEAR -> Icons.Filled.LocalPolice
    DeviceType.UNKNOWN -> Icons.AutoMirrored.Filled.HelpOutline
}

/** Category glyph sitting in a tinted rounded tile. */
@Composable
fun CatGlyph(type: DeviceType, size: Int = 34) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .background(Acab.bg3, RoundedCornerShape((size * 0.32f).dp))
            .border(1.dp, Acab.line, RoundedCornerShape((size * 0.32f).dp)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(type.icon(), contentDescription = type.label, tint = type.tone(),
            modifier = Modifier.size((size * 0.5f).dp))
    }
}

/** Four rising bars for signal strength (0..4). */
@Composable
fun SignalBars(bars: Int, tint: androidx.compose.ui.graphics.Color = Acab.accent) {
    Row(verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 4) {
            Box(
                Modifier
                    .padding(end = 2.dp)
                    .width(3.dp)
                    .height((5 + i * 3).dp)
                    .background(if (i < bars) tint else Acab.line, RoundedCornerShape(1.dp))
            )
        }
    }
}

/** RSSI to a 0..4 bar count. */
fun rssiBars(rssi: Int): Int = when {
    rssi < -90 -> 1
    rssi < -80 -> 2
    rssi < -67 -> 3
    else -> 4
}
