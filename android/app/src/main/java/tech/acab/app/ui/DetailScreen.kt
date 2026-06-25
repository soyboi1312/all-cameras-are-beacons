package tech.acab.app.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.isOuiMatch
import tech.acab.app.model.methodLabel
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone

/** Detection dossier: top bar, title block, live RSSI sparkline, a 2x2 stat grid,
 *  and an identity panel with first/last seen. Mirrors the iOS detail sheet. */
@Composable
fun DetailScreen(d: Detection, ble: AcabBleManager, onBack: () -> Unit) {
    val tone = d.type.tone()
    val trend = ble.rssiTrend(d.id)
    val stale = ble.isStale(d.id)

    Box(Modifier.fillMaxSize().background(Acab.bg)) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Acab.pad)
                .padding(top = 64.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // ---- title: glyph, label, last 4 of the MAC ----
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                CatGlyph(d.type, size = 54)
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    BadgePill("${d.type.category} · ${d.type.classLabel}", tone)
                    Text("NODE ${nodeName(d.mac)}", color = Acab.text,
                        fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    Text(d.type.label, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                }
            }

            // ---- heads-up that body-cam signatures aren't field-verified ----
            if (d.type.isExperimental) ExperimentalNote()

            // ---- signal: big RSSI + sparkline, dimmed if stale ----
            Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Kicker(if (stale) "SIGNAL · STALE" else "SIGNAL · LIVE",
                        color = if (stale) Acab.dim else Acab.faint)
                    Spacer(Modifier.weight(1f))
                    SignalBars(rssiBars(d.rssi), tint = tone)
                }
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("${d.rssi}", color = Acab.text, fontSize = 30.sp,
                        fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
                    Text("dBm", color = Acab.dim, fontSize = 11.sp,
                        fontFamily = Acab.mono, modifier = Modifier.padding(bottom = 4.dp))
                }
                Sparkline(trend, tone, stale, Modifier.fillMaxWidth().height(46.dp))
            }

            // ---- 2x2 stat grid ----
            StatGrid(
                listOf(
                    "MATCHED ON" to d.methodLabel,
                    "SOURCE" to d.sourceLabel,
                    "CONFIDENCE" to "${d.confidence}%",
                    "SIGHTINGS" to "${d.count}",
                ),
                confColor = confColor(d.confidence),
            )

            if (d.isOuiMatch) FalsePositiveNote()

            // ---- identity ----
            Column(Modifier.fillMaxWidth().panel()) {
                Kicker("IDENTITY")
                Spacer(Modifier.size(4.dp))
                IdRow("Vendor", d.ouiVendor ?: d.type.label)
                d.type.brand?.let { IdRow("Brand", it) }
                IdRow("MAC", d.mac)
                d.name?.takeIf { it.isNotEmpty() }?.let { IdRow("Name", it) }
                d.rid?.takeIf { it.isNotEmpty() }?.let { IdRow("UAS ID", it) }
                d.ridManufacturer?.let { IdRow("Manufacturer", it) }
                d.detail?.takeIf { it.isNotEmpty() }?.let { IdRow("Detail", it) }
                d.altitude?.let { IdRow("Altitude", "$it m") }
                d.speedH?.let { IdRow("Speed", "$it m/s") }
                d.speedV?.takeIf { it != 0 }?.let { IdRow("Vert. speed", "$it m/s") }
                d.heading?.let { IdRow("Heading", "$it°") }
                d.heightAGL?.let { IdRow("Height AGL", "$it m") }
                d.pilotAlt?.let { IdRow("Operator alt", "$it m") }
                d.ridStatusLabel?.let { IdRow("Status", it) }
                IdRow("First seen", relativeAgo(ble.firstSeen(d.id)))
                IdRow("Last seen", relativeAgo(ble.lastSeen(d.id)), last = true)
                WhyFlagged(d, tone)
            }

            // ---- location: static map thumbnail centered on the sighting ----
            ble.mapCoord(d)?.let { (lat, lon) -> LocationPanel(d, lat, lon) }

            // ---- actions ----
            CopyMacButton(d.mac)
            IgnoreButton { ble.ignoreDevice(d); onBack() }
        }

        // ---- top bar: back arrow + centered kicker ----
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Acab.pad).padding(top = 8.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(36.dp)
                    .background(Acab.bg2, RoundedCornerShape(50))
                    .border(1.dp, Acab.line, RoundedCornerShape(50))
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back",
                    tint = Acab.text, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.weight(1f))
            Kicker("DETECTION")
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(36.dp))   // dummy right item so the kicker stays centered
        }
    }
}

/** Category badge pill in the type tone, like the iOS detail header. */
@Composable
private fun BadgePill(label: String, tone: Color) {
    val shape = RoundedCornerShape(50)
    Box(
        Modifier
            .background(tone.copy(alpha = 0.13f), shape)
            .border(1.dp, tone.copy(alpha = 0.35f), shape)
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Text(label, color = tone, fontSize = 9.5.sp, letterSpacing = 1.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Heads-up for OUI-only matches: the OUI only names the chipset vendor, which Flock
 *  shares with consumer gear, so these can be false positives. */
@Composable
private fun FalsePositiveNote() {
    Column(
        Modifier.fillMaxWidth().panel(),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null,
                tint = Acab.warn, modifier = Modifier.size(13.dp))
            Kicker("POSSIBLE FALSE POSITIVE", color = Acab.warn)
        }
        Text("OUI matches flag the chipset vendor, which Flock shares with plenty of consumer devices. Worth confirming before you trust it.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Amber warning for experimental detectors: body-cam signatures are still guesswork. */
@Composable
private fun ExperimentalNote() {
    Row(
        Modifier.fillMaxWidth().panel(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(13.dp))
        Text("Experimental detector. Body-cam signatures are not field-verified yet, so treat this as a maybe.",
            color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Dim footer recapping how the node was matched. */
@Composable
private fun WhyFlagged(d: Detection, tone: Color) {
    Row(
        Modifier.fillMaxWidth().padding(top = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.GpsFixed, contentDescription = null,
            tint = tone, modifier = Modifier.size(11.dp))
        Text("Flagged by ${d.methodLabel} over ${d.sourceLabel}.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Static map thumbnail centered on the sighting, with the device pin and (for drones)
 *  a separate operator marker. Mirrors the iOS location panel. */
@Composable
private fun LocationPanel(d: Detection, lat: Double, lon: Double) {
    val context = LocalContext.current
    val markers = rememberCategoryMarkers()
    val operatorMarker = rememberOperatorMarker()

    // osmdroid needs a user agent set before its first tile fetch, or the tile server rejects it.
    remember { Configuration.getInstance().userAgentValue = context.packageName }

    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Kicker("LOCATION")
            Spacer(Modifier.weight(1f))
            Text(String.format("%.5f, %.5f", lat, lon),
                color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
        }
        // When the board stamped this from a stale phone fix (offline / Desert mode), say how
        // old the position is so it isn't read as a live "here, now". The v1.7 headline.
        d.locationAgeText?.let { age ->
            Text("location as of $age", color = Acab.warn,
                fontSize = 11.sp, fontFamily = Acab.mono)
        }
        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .height(170.dp)
                .clip(RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm)),
            factory = { ctx ->
                MapView(ctx).apply {
                    setTileSource(TileSourceFactory.MAPNIK)
                    setMultiTouchControls(false)
                    controller.setZoom(15.0)
                    controller.setCenter(GeoPoint(lat, lon))
                    overlays.add(
                        Marker(this).apply {
                            position = GeoPoint(lat, lon)
                            icon = markers.getValue(d.type)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            title = d.type.category
                        }
                    )
                    // drones broadcast the operator's position too; drop a pin for it
                    val plat = d.pilotLat
                    val plon = d.pilotLon
                    if (plat != null && plon != null) {
                        overlays.add(
                            Marker(this).apply {
                                position = GeoPoint(plat, plon)
                                icon = operatorMarker
                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                title = "Operator"
                            }
                        )
                    }
                }
            },
            onRelease = { it.onDetach() },
        )
    }
}

/** Crimson button that copies the MAC and flashes "COPIED" for a beat. */
@Composable
private fun CopyMacButton(mac: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.accent, RoundedCornerShape(Acab.radiusSm))
            .clickable {
                val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clip.setPrimaryClip(ClipData.newPlainText("MAC", mac))
                copied = true
            }
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
            contentDescription = null, tint = Acab.onAccent, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(7.dp))
        Text(if (copied) "COPIED" else "COPY MAC ADDRESS", color = Acab.onAccent,
            fontSize = 12.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Outlined button that mutes the device and pops back. */
@Composable
private fun IgnoreButton(onIgnore: () -> Unit) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClick = onIgnore)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.NotificationsOff, contentDescription = null,
            tint = Acab.dim, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(7.dp))
        Text("IGNORE THIS DEVICE", color = Acab.dim,
            fontSize = 12.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** 2x2 grid with hairline dividers; the confidence cell gets a tint. */
@Composable
private fun StatGrid(cells: List<Pair<String, String>>, confColor: Color) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius)),
    ) {
        Row(Modifier.fillMaxWidth()) {
            StatCell(cells[0], Acab.text, Modifier.weight(1f))
            VDivider()
            StatCell(cells[1], Acab.text, Modifier.weight(1f))
        }
        HorizontalDivider(color = Acab.line)
        Row(Modifier.fillMaxWidth()) {
            StatCell(cells[2], confColor, Modifier.weight(1f))
            VDivider()
            StatCell(cells[3], Acab.text, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatCell(cell: Pair<String, String>, valueColor: Color, modifier: Modifier = Modifier) {
    Column(modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Kicker(cell.first)
        Text(cell.second, color = valueColor, fontSize = 14.sp,
            fontWeight = FontWeight.Medium, fontFamily = Acab.mono, maxLines = 1)
    }
}

/** Vertical hairline between grid columns. */
@Composable
private fun VDivider() {
    Box(Modifier.size(width = 1.dp, height = 56.dp).background(Acab.line))
}

/** Identity label/value row, hairline under all but the last. */
@Composable
private fun IdRow(label: String, value: String, last: Boolean = false) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 9.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Text(label, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(16.dp))
            Text(value, color = Acab.text, fontSize = 12.sp,
                fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
        }
        if (!last) HorizontalDivider(color = Acab.line)
    }
}

/** RSSI history as a line with a faint fill; dimmed when the node is stale. */
@Composable
private fun Sparkline(values: List<Int>, tone: Color, stale: Boolean, modifier: Modifier = Modifier) {
    val alpha = if (stale) 0.35f else 1f
    Canvas(modifier) { drawSparkline(values, tone, alpha) }
}

private fun DrawScope.drawSparkline(values: List<Int>, tone: Color, alpha: Float) {
    if (values.size < 2) return
    val w = size.width
    val h = size.height
    val lo = values.min()
    val hi = values.max()
    val span = (hi - lo).coerceAtLeast(1).toFloat()
    val step = w / (values.size - 1)
    // RSSI is negative, so closer to 0 sits near the top.
    fun y(v: Int) = h - ((v - lo) / span) * h
    val line = Path().apply {
        moveTo(0f, y(values[0]))
        values.forEachIndexed { i, v -> lineTo(i * step, y(v)) }
    }
    val fill = Path().apply {
        addPath(line)
        lineTo(w, h)
        lineTo(0f, h)
        close()
    }
    drawPath(fill, tone.copy(alpha = 0.12f * alpha))
    drawPath(line, tone.copy(alpha = alpha), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()))
}

/** Confidence tint: dim under 50, amber under 80, crimson above. */
private fun confColor(pct: Int): Color = when {
    pct < 50 -> Acab.dim
    pct < 80 -> Acab.warn
    else -> Acab.accent
}

/** Last 4 hex of the MAC (colons stripped) for the NODE name. */
private fun nodeName(mac: String): String {
    val hex = mac.filter { it != ':' && it != '-' }
    return hex.takeLast(4).uppercase().ifEmpty { "????" }
}

/** Short "ago" string like "now", "12s ago", "4m ago", "1h ago", "3d ago".
 *  A dash if we don't know the time. */
private fun relativeAgo(ms: Long?): String {
    if (ms == null) return "-"
    val secs = ((System.currentTimeMillis() - ms) / 1000).coerceAtLeast(0)
    return when {
        secs < 5 -> "now"
        secs < 60 -> "${secs}s ago"
        secs < 3600 -> "${secs / 60}m ago"
        secs < 86_400 -> "${secs / 3600}h ago"
        else -> "${secs / 86_400}d ago"
    }
}
