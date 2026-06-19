package tech.acab.app.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** Status / home: the at-a-glance "how many eyes are on me" view. */
@Composable
fun StatusScreen(ble: AcabBleManager) {
    val detections by ble.detections.collectAsState()
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()

    fun count(type: DeviceType) = detections.count { it.type == type }
    val nearest = detections.maxByOrNull { it.rssi }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        // header: wordmark + link chip
        Row(verticalAlignment = Alignment.CenterVertically) {
            BrandMark(size = 21)
            Spacer(Modifier.weight(1f))
            LinkChip(version = status?.version, demo = demo)
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(7.dp).background(Acab.accent, CircleShape))
            Spacer(Modifier.size(8.dp))
            Kicker("SCANNING · BLE · WI-FI", color = Acab.dim)
        }

        RadarScope(count = detections.size, detections = detections)

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { PunkLine() }

        // 2x2 per-category counts
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CountTile(DeviceType.FLOCK_CAMERA, "ALPR",
                count(DeviceType.FLOCK_CAMERA) + count(DeviceType.FLOCK_RAVEN), Modifier.weight(1f))
            CountTile(DeviceType.DRONE, "DRONE", count(DeviceType.DRONE), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CountTile(DeviceType.BODY_CAM, "BODY CAM", count(DeviceType.BODY_CAM), Modifier.weight(1f))
            CountTile(DeviceType.TRACKER, "TRACKER", count(DeviceType.TRACKER), Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CountTile(DeviceType.POLICE_GEAR, "POLICE", count(DeviceType.POLICE_GEAR), Modifier.weight(1f))
            Spacer(Modifier.weight(1f))
        }

        if (nearest != null) NearestCard(nearest)
    }
}

/** The "Beacons" wordmark. */
@Composable
private fun BrandMark(size: Int) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text("Beacons", color = Acab.text, fontSize = size.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono)
    }
}

/** Status pill: amber DEMO in sample-data mode, crimson LINKED + version when
 *  connected, or faint OFFLINE otherwise. */
@Composable
private fun LinkChip(version: String?, demo: Boolean = false) {
    val connected = version != null
    val tone = when {
        demo -> Acab.warn
        connected -> Acab.accent
        else -> Acab.faint
    }
    val label = when {
        demo -> "DEMO"
        connected -> "LINKED v$version"
        else -> "OFFLINE"
    }
    val labelTone = when {
        demo -> Acab.warn
        connected -> Acab.dim
        else -> Acab.faint
    }
    Row(
        Modifier
            .background(Acab.bg2, CircleShape)
            .border(1.dp, if (demo) Acab.warn.copy(alpha = 0.4f) else Acab.line, CircleShape)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(tone, CircleShape))
        Spacer(Modifier.size(6.dp))
        Kicker(label, color = labelTone)
    }
}

/** Radar: concentric rings, crosshairs, a rotating sweep, and a dot per detection. */
@Composable
private fun RadarScope(count: Int, detections: List<Detection>) {
    val sweep by rememberInfiniteTransition(label = "sweep").animateFloat(
        initialValue = 0f, targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(4500, easing = LinearEasing), RepeatMode.Restart),
        label = "sweepAngle",
    )
    // Cap at 14 so the scope stays readable when there's a lot around.
    val dots = detections.take(14)

    Box(
        Modifier.fillMaxWidth().aspectRatio(1f).padding(top = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            val c = Offset(size.width / 2f, size.height / 2f)

            // three rings, the outer one stronger
            for (i in 1..3) {
                drawCircle(
                    color = if (i == 3) Acab.lineStrong else Acab.line,
                    radius = r * i / 3f, center = c, style = Stroke(1.dp.toPx()),
                )
            }
            // crosshairs
            drawLine(Acab.line, Offset(c.x, c.y - r), Offset(c.x, c.y + r), 1.dp.toPx())
            drawLine(Acab.line, Offset(c.x - r, c.y), Offset(c.x + r, c.y), 1.dp.toPx())

            // rotating sweep — a soft crimson wedge
            rotate(sweep, c) {
                drawArc(
                    brush = Brush.sweepGradient(
                        0.72f to Color.Transparent,
                        0.99f to Acab.accentGlow,
                        1.0f to Color.Transparent,
                        center = c,
                    ),
                    startAngle = 0f, sweepAngle = 360f, useCenter = true,
                    topLeft = Offset(c.x - r, c.y - r), size = Size(r * 2, r * 2),
                )
            }

            // one blip per detection: angle from the MAC (stable), radius from RSSI
            for (d in dots) {
                val angle = (abs(d.mac.hashCode()) % 360) * (PI / 180.0)
                val norm = (((-d.rssi).toFloat() - 30f) / 70f).coerceIn(0f, 1f)
                val rad = (0.12f + norm * 0.8f) * r
                val pos = Offset(c.x + (cos(angle) * rad).toFloat(), c.y + (sin(angle) * rad).toFloat())
                drawCircle(d.type.tone().copy(alpha = 0.35f), 7.dp.toPx(), pos)
                drawCircle(d.type.tone(), 4.dp.toPx(), pos)
            }
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("$count", color = Acab.text, fontSize = 62.sp, fontWeight = FontWeight.Bold)
            Kicker("DEVICES NEARBY")
        }
    }
}

/** One count tile in the 2x2 grid. */
@Composable
private fun CountTile(type: DeviceType, label: String, n: Int, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CatGlyph(type, size = 30)
        Text("$n", color = if (n == 0) Acab.faint else Acab.text,
            fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
        Kicker(label, color = if (n == 0) Acab.faint else type.tone())
    }
}

/** Hero card for the closest device (highest RSSI). */
@Composable
private fun NearestCard(d: Detection) {
    Row(Modifier.fillMaxWidth().panel(strong = true), verticalAlignment = Alignment.CenterVertically) {
        CatGlyph(d.type, size = 40)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(d.type.category.lowercase().replaceFirstChar { it.uppercase() },
                    color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.size(6.dp))
                Text("NODE ${nodeName(d.mac)}", color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
            }
            Text("${d.sourceLabel} · seen ${d.count}x", color = Acab.faint, fontSize = 11.sp,
                fontFamily = Acab.mono)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("${d.rssi}", color = Acab.accent, fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
            SignalBars(rssiBars(d.rssi), tint = d.type.tone())
        }
    }
}

/** "they're watching. watch back." */
@Composable
private fun PunkLine() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("they're watching. ", color = Acab.dim, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Text("watch back.", color = Acab.accent, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

/** Last 4 hex of the MAC, uppercased — a short node handle. */
private fun nodeName(mac: String): String = mac.replace(":", "").takeLast(4).uppercase()
