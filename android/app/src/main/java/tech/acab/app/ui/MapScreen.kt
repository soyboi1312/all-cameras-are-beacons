package tech.acab.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polygon
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.mylocation.GpsMyLocationProvider
import org.osmdroid.views.overlay.mylocation.MyLocationNewOverlay
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab

/** Rough RSSI -> distance (metres) for a no-GPS proximity ring. Log-distance
 *  path-loss model — a ballpark, not a measurement. */
private fun rssiRadiusMeters(rssi: Int): Double =
    Math.pow(10.0, (-50.0 - rssi) / 25.0).coerceIn(5.0, 600.0)   // TxPower -50 dBm, n ~ 2.5

/** Located detections dropped on a dark map, filterable by category. Fixed installs
 *  use the phone's position when first heard; drones use their own broadcast coords. */
@Composable
fun MapScreen(ble: AcabBleManager, onSelect: (Detection) -> Unit) {
    val context = LocalContext.current
    val detections by ble.detections.collectAsState()
    var filter by remember { mutableStateOf<String?>(null) }   // category key (null = all)
    val myLocation = remember { mutableStateOf<MyLocationNewOverlay?>(null) }
    val markers = rememberCategoryMarkers()   // category pins, built once
    val operatorMarker = rememberOperatorMarker()

    // osmdroid needs a user agent set before its first tile fetch, or the CDN 403s.
    remember { Configuration.getInstance().userAgentValue = context.packageName }

    val located = detections.filter { ble.mapCoord(it) != null }
    val shown = filter?.let { f -> located.filter { it.type.category == f } } ?: located
    fun count(cat: String) = located.count { it.type.category == cat }

    Box(Modifier.fillMaxSize()) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                MapView(ctx).apply {
                    setTileSource(TileSourceFactory.MAPNIK)
                    setMultiTouchControls(true)
                    controller.setZoom(15.0)
                    // "you are here" dot; centers and follows once a fix lands.
                    // osmdroid no-ops without permission, so this is safe even
                    // before location is granted.
                    val self = MyLocationNewOverlay(GpsMyLocationProvider(ctx), this).apply {
                        enableMyLocation()
                        enableFollowLocation()
                    }
                    overlays.add(self)
                    myLocation.value = self
                }
            },
            update = { map ->
                // rebuild just the detection markers; leave the location dot alone
                map.overlays.removeAll { it is Marker || it is Polyline || it is Polygon }
                // drone overlays, under the markers: flight path, tether, launch, no-GPS ring
                shown.filter { it.type == DeviceType.DRONE }.forEach { d ->
                    val path = ble.track(d.id)
                    if (path.size >= 2) {
                        map.overlays.add(Polyline(map).apply {
                            setPoints(path.map { GeoPoint(it.first, it.second) })
                            outlinePaint.color = Acab.droneTone.toArgb()
                            outlinePaint.strokeWidth = 5f
                        })
                        map.overlays.add(Marker(map).apply {
                            position = GeoPoint(path.first().first, path.first().second)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            title = "Launch"
                        })
                    }
                    val plat = d.pilotLat; val plon = d.pilotLon
                    val dla = d.lat; val dlo = d.lon
                    if (dla != null && dlo != null && plat != null && plon != null) {
                        map.overlays.add(Polyline(map).apply {
                            setPoints(listOf(GeoPoint(dla, dlo), GeoPoint(plat, plon)))
                            outlinePaint.color = Acab.droneTone.copy(alpha = 0.5f).toArgb()
                            outlinePaint.strokeWidth = 3f
                        })
                    }
                    if (d.lat == null) {   // no broadcast GPS: draw an RSSI ring around us
                        ble.mapCoord(d)?.let { (lat, lon) ->
                            map.overlays.add(Polygon(map).apply {
                                points = Polygon.pointsAsCircle(GeoPoint(lat, lon), rssiRadiusMeters(d.rssi))
                                fillPaint.color = Acab.droneTone.copy(alpha = 0.08f).toArgb()
                                outlinePaint.color = Acab.droneTone.copy(alpha = 0.5f).toArgb()
                                outlinePaint.strokeWidth = 3f
                            })
                        }
                    }
                }
                shown.forEach { d ->
                    val (lat, lon) = ble.mapCoord(d) ?: return@forEach
                    val marker = Marker(map).apply {
                        position = GeoPoint(lat, lon)
                        icon = markers.getValue(d.type)
                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                        title = d.type.category
                        setOnMarkerClickListener { _, _ -> onSelect(d); true }
                    }
                    map.overlays.add(marker)
                }
                // drone operator pins: the muted person marker, distinct from the dots
                shown.forEach { d ->
                    val plat = d.pilotLat; val plon = d.pilotLon
                    if (plat != null && plon != null) {
                        map.overlays.add(Marker(map).apply {
                            position = GeoPoint(plat, plon)
                            icon = operatorMarker
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            title = "Operator"
                            setOnMarkerClickListener { _, _ -> onSelect(d); true }
                        })
                    }
                }
                // before the first fix, frame the freshest pin so it isn't lost;
                // after that, follow-location keeps the map on the operator.
                if (myLocation.value?.myLocation == null) {
                    shown.firstOrNull()?.let { d ->
                        ble.mapCoord(d)?.let { (lat, lon) -> map.controller.setCenter(GeoPoint(lat, lon)) }
                    }
                }
                map.invalidate()
            },
            onRelease = { map ->
                myLocation.value?.disableMyLocation()
                map.onDetach()
            },
        )

        // header + filter chips float over the map
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = Acab.pad)
                .padding(top = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("Map", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                Kicker("${located.size} SIGHTING${if (located.size == 1) "" else "S"}")
            }
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CatChip(null, "ALL", located.size, filter == null) { filter = null }
                CatChip("ALPR", "ALPR", count("ALPR"), filter == "ALPR") { filter = "ALPR" }
                CatChip("DRONE", "DRONE", count("DRONE"), filter == "DRONE") { filter = "DRONE" }
                CatChip("BODY CAM", "BODY CAM", count("BODY CAM"), filter == "BODY CAM") { filter = "BODY CAM" }
                CatChip("TRACKER", "TRACKER", count("TRACKER"), filter == "TRACKER") { filter = "TRACKER" }
                CatChip("POLICE", "POLICE", count("POLICE"), filter == "POLICE") { filter = "POLICE" }
            }
        }

        // bottom-left legend
        Column(
            Modifier.align(Alignment.BottomStart).padding(Acab.pad)
                .background(Acab.bg2.copy(alpha = 0.85f), RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
                .padding(11.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            LegendRow(Acab.flockTone, "ALPR")
            LegendRow(Acab.droneTone, "Drone")
            LegendRow(Acab.bodyCamTone, "Body cam")
            LegendRow(Acab.trackerTone, "Tracker")
            LegendRow(Acab.policeTone, "Police")
        }

        // empty state until something has a location
        if (located.isEmpty()) {
            Column(
                Modifier.align(Alignment.Center).padding(Acab.pad)
                    .background(Acab.bg2.copy(alpha = 0.92f), RoundedCornerShape(Acab.radius))
                    .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
                    .padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("No located detections yet", color = Acab.dim,
                    fontSize = 14.sp, fontWeight = FontWeight.Medium)
                Text("ALPR, body-cam and tracker hits use your phone position; drones report their own.",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                    textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 250.dp))
            }
        }
    }
}

/** One legend row: colored dot + label. */
@Composable
private fun LegendRow(color: Color, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(Modifier.size(8.dp).background(color, RoundedCornerShape(50)))
        Text(label, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Tint for a filter key; ALL falls back to the crimson accent. */
private fun catTone(cat: String?): Color = when (cat) {
    "ALPR" -> Acab.flockTone
    "DRONE" -> Acab.droneTone
    "BODY CAM" -> Acab.bodyCamTone
    "TRACKER" -> Acab.trackerTone
    "POLICE" -> Acab.policeTone
    else -> Acab.accent
}

/** Pill chip that filters the pins to one category; active fills with its tone. */
@Composable
private fun CatChip(cat: String?, label: String, n: Int, active: Boolean, onClick: () -> Unit) {
    val tone = catTone(cat)
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .background(if (active) tone else Acab.bg2, shape)
            .border(1.dp, if (active) Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            label,
            color = if (active) Acab.onAccent else Acab.dim,
            fontSize = 10.5.sp,
            letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono,
        )
        Text(
            "$n",
            color = if (active) Acab.onAccent.copy(alpha = 0.7f) else Acab.faint,
            fontSize = 10.sp,
            fontFamily = Acab.mono,
        )
    }
}
