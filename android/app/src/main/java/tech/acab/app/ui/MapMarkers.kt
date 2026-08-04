package tech.acab.app.ui

import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.PathEffect
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
    DeviceType.GLASSES to rememberCategoryMarker(DeviceType.GLASSES),
    // Network cameras grid-cluster with the other high-volume types, but a lone member still
    // renders as an individual pin via markers.getValue(d.type); without this entry a located
    // NETWORK_CAMERA would throw NoSuchElementException the moment that pin is drawn.
    DeviceType.NETWORK_CAMERA to rememberCategoryMarker(DeviceType.NETWORK_CAMERA),
    DeviceType.NEARBY_DEVICE to rememberCategoryMarker(DeviceType.NEARBY_DEVICE),
    DeviceType.WATCHED to rememberCategoryMarker(DeviceType.WATCHED),
    DeviceType.UNKNOWN to rememberCategoryMarker(DeviceType.UNKNOWN),
)

/** A quiet hollow ring for a known/mapped ALPR camera (the opt-in reference layer). Un-animated
 *  and low-contrast on purpose, so a mapped location never reads as a live detection. */
@Composable
fun rememberAlprMarker(confirmed: Boolean = true): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    // Confirmed rings stay the established red; unverified ones go amber AND DASHED. Colour alone
    // is not a distinction for a red/green-deficient viewer, and telling the two tiers apart is the
    // entire point of the second one. Mirrors iOS ALPRDot.
    val tone = if (confirmed) Acab.flockTone else Acab.warn
    return remember(density, confirmed) {
        with(density) {
            // Bolder 2026-07-29 (rings washed out on the map); keep in lockstep with iOS ALPRDot.
            val r = 7.0.dp.toPx()
            val stroke = 2.2.dp.toPx()
            val full = (r + stroke) * 2f + 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                drawCircle(tone, radius = r, center = center, alpha = if (confirmed) 0.20f else 0.10f)
                drawCircle(tone, radius = r, center = center, alpha = 0.95f,
                           style = if (confirmed) Stroke(width = stroke)
                                   else Stroke(width = stroke,
                                               pathEffect = PathEffect.dashPathEffect(
                                                   floatArrayOf(2.6.dp.toPx(), 2.2.dp.toPx()), 0f)))
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

/** The drone flight path's launch point, in both flavors: a plain small glyph and a
 *  "LAUNCH"-captioned variant for the "icon labels" map setting. [labeledAnchorV] keeps the
 *  glyph (not the taller glyph+caption box) centered on the launch coordinate. */
class LaunchMarker(
    val plain: BitmapDrawable,
    val labeled: BitmapDrawable,
    val labeledAnchorV: Float,
)

/** A small up-arrow disc for a drone track's launch point, mirroring the iOS 13pt
 *  arrow.up.circle.fill: droneTone disc, dark arrow, half-dark backing so it reads over
 *  the tiles. Deliberately about half the category-pin size so the launch point can never
 *  be mistaken for a second live drone pin. */
@Composable
fun rememberLaunchMarker(): LaunchMarker {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(Icons.Filled.ArrowUpward)
    val tone = Acab.droneTone
    return remember(density) {
        with(density) {
            val discR = 6.5.dp.toPx()
            val backing = 1.5.dp.toPx()
            val full = (discR + backing) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 8.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                // dark backing halo (iOS: black-at-50% circle behind the glyph)
                drawCircle(Color.Black, radius = discR + backing, center = center, alpha = 0.5f)
                // droneTone disc with a dark up arrow = arrow.up.circle.fill in droneTone
                drawCircle(tone, radius = discR, center = center)
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Color(0xFF14100F)))
                    }
                }
            }
            val plain = BitmapDrawable(context.resources, image.asAndroidBitmap())
            val (labeled, anchorV) = buildLabeledMarker(
                context.resources, density.density, plain, "LAUNCH")
            LaunchMarker(plain, labeled, anchorV)
        }
    }
}

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

/** The category pins from [rememberCategoryMarkers], each with a short type tag drawn in a
 *  pill beneath the icon, for the map's "icon labels" setting. [anchorV] is the vertical
 *  anchor that keeps the ICON (not the label) centered on the geo point; it is the same for
 *  every type because all category pins share one bitmap size. */
class LabeledMarkers(
    val icons: Map<DeviceType, BitmapDrawable>,
    val anchorV: Float,
)

/** Build labeled variants of the category pins once. Keyed on density only: the base pins are
 *  stable instances (each is remembered per type), so the labels never need rebuilding on a
 *  plain recomposition even though [base] is a fresh map wrapper each time. */
@Composable
fun rememberLabeledCategoryMarkers(base: Map<DeviceType, BitmapDrawable>): LabeledMarkers {
    val context = LocalContext.current
    val density = LocalDensity.current
    return remember(density) {
        var anchorV = 0.5f
        val icons = base.mapValues { (type, drawable) ->
            val (labeled, av) = buildLabeledMarker(
                context.resources, density.density, drawable, type.category)
            anchorV = av
            labeled
        }
        LabeledMarkers(icons, anchorV)
    }
}

/** Compose the base pin bitmap with a short label pill under it. Returns the drawable plus the
 *  vertical anchor ratio that lands the icon's center (not the taller icon+label box) on the
 *  point. */
private fun buildLabeledMarker(
    resources: android.content.res.Resources,
    densityPx: Float,
    base: BitmapDrawable,
    label: String,
): Pair<BitmapDrawable, Float> {
    fun dp(v: Float) = v * densityPx
    val icon = base.bitmap
    val iconW = icon.width.toFloat()
    val iconH = icon.height.toFloat()

    val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Acab.text.toArgb()
        textAlign = Paint.Align.CENTER
        textSize = dp(8.5f)
        isFakeBoldText = true
    }
    val fm = textPaint.fontMetrics
    val padH = dp(5f)
    val padV = dp(2.5f)
    val gap = dp(1f)
    val bandW = textPaint.measureText(label) + padH * 2f
    val bandH = (fm.descent - fm.ascent) + padV * 2f
    val fullW = maxOf(iconW, bandW)
    val fullH = iconH + gap + bandH

    val bmp = android.graphics.Bitmap.createBitmap(
        fullW.toInt().coerceAtLeast(1), fullH.toInt().coerceAtLeast(1),
        android.graphics.Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bmp)
    val cx = fullW / 2f
    // icon, centered horizontally at the top
    canvas.drawBitmap(icon, cx - iconW / 2f, 0f, null)
    // label pill: dark, faint border, matching the chip styling
    val bandTop = iconH + gap
    val rect = android.graphics.RectF(cx - bandW / 2f, bandTop, cx + bandW / 2f, bandTop + bandH)
    canvas.drawRoundRect(rect, dp(4f), dp(4f),
        Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Acab.bg2.toArgb(); alpha = 235 })
    canvas.drawRoundRect(rect, dp(4f), dp(4f),
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            color = Acab.line.toArgb()
        })
    canvas.drawText(label, cx, bandTop + padV - fm.ascent, textPaint)

    return BitmapDrawable(resources, bmp) to (iconH / 2f) / fullH
}
