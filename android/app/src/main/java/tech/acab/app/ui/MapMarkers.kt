package tech.acab.app.ui

import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone

/** Map marker icons, one per detection type, like the iOS pins: a filled dot in the
 *  category tone, with a dark ring and the category glyph. Built once per type and
 *  reused across all of that type's markers. */
@Composable
fun rememberCategoryMarkers(): Map<DeviceType, BitmapDrawable> = mapOf(
    DeviceType.FLOCK_CAMERA to rememberCategoryMarker(DeviceType.FLOCK_CAMERA),
    DeviceType.FLOCK_RAVEN to rememberCategoryMarker(DeviceType.FLOCK_RAVEN),
    DeviceType.BODY_CAM to rememberCategoryMarker(DeviceType.BODY_CAM),
    DeviceType.DRONE to rememberCategoryMarker(DeviceType.DRONE),
    DeviceType.TRACKER to rememberCategoryMarker(DeviceType.TRACKER),
    DeviceType.POLICE_GEAR to rememberCategoryMarker(DeviceType.POLICE_GEAR),
    DeviceType.UNKNOWN to rememberCategoryMarker(DeviceType.UNKNOWN),
)

/** A muted person marker for a drone's operator, so it reads apart from the
 *  bright category dots. */
@Composable
fun rememberOperatorMarker(): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(Icons.Filled.Person)
    return remember(density) {
        with(density) {
            val dotR = 12.dp.toPx()
            val border = 2.dp.toPx()
            val full = (dotR + border) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 14.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                drawCircle(Acab.bg, radius = dotR + border, center = center)
                drawCircle(Acab.bg3, radius = dotR, center = center)
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Acab.text))
                    }
                }
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

@Composable
private fun rememberCategoryMarker(type: DeviceType): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(type.icon())
    val tone = type.tone()
    return remember(type, density) {
        with(density) {
            val dotR = 15.dp.toPx()
            val border = 2.dp.toPx()
            val ringReach = 5.dp.toPx()
            val full = (dotR + border + ringReach) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 16.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                // faint static ring (the iOS pin's pulse, frozen)
                drawCircle(tone, radius = dotR + border + ringReach * 0.55f, center = center,
                    alpha = 0.4f, style = Stroke(width = 1.5.dp.toPx()))
                // dark border ring, then the colored dot
                drawCircle(Acab.bg, radius = dotR + border, center = center)
                drawCircle(tone, radius = dotR, center = center)
                // category glyph, dark, centered
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Color(0xFF14100F)))
                    }
                }
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

/** A clustered-detections bubble: a tone-colored disc with a dark ring and the count,
 *  growing with the cluster size so a dense Desert-mode log reads at a glance. Built on
 *  demand from the map's update pass (the count varies), so it's a plain function rather
 *  than a @Composable. Caches per (count, tone) so repeated rebuilds are cheap. */
class ClusterMarkerFactory(
    private val resources: android.content.res.Resources,
    private val densityPx: Float,
) {
    private val cache = HashMap<Long, BitmapDrawable>()

    private fun dp(v: Float) = v * densityPx

    fun marker(count: Int, tone: Color): BitmapDrawable {
        val key = (count.toLong() shl 32) or (tone.toArgb().toLong() and 0xFFFFFFFFL)
        cache[key]?.let { return it }

        // Radius scales gently with the log of the count so big clusters don't dwarf the map.
        val baseR = dp(16f) + dp(7f) * Math.log10((count + 1).toDouble()).toFloat()
        val border = dp(2f)
        val full = (baseR + border) * 2f
        val side = full.toInt().coerceAtLeast(1)
        val cx = full / 2f

        val image = ImageBitmap(side, side)
        val androidBitmap = image.asAndroidBitmap()
        val canvas = android.graphics.Canvas(androidBitmap)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)

        // dark border ring, then the colored disc
        fill.color = Acab.bg.toArgb()
        canvas.drawCircle(cx, cx, baseR + border, fill)
        fill.color = tone.toArgb()
        canvas.drawCircle(cx, cx, baseR, fill)

        // count, dark and centered
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF14100F.toInt()
            textAlign = Paint.Align.CENTER
            textSize = dp(13f)
            isFakeBoldText = true
        }
        val label = if (count > 999) "999+" else count.toString()
        val textY = cx - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(label, cx, textY, textPaint)

        return BitmapDrawable(resources, androidBitmap).also { cache[key] = it }
    }
}

/** Build a cluster-marker factory bound to the current resources + density. */
@Composable
fun rememberClusterMarkerFactory(): ClusterMarkerFactory {
    val context = LocalContext.current
    val density = LocalDensity.current
    return remember(density) { ClusterMarkerFactory(context.resources, density.density) }
}
