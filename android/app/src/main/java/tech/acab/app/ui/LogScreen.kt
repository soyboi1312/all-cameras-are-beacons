package tech.acab.app.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.RadioButtonChecked
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import java.io.File

/** Logbook: detection history with category tiles that double as filters. */
@Composable
fun LogScreen(ble: AcabBleManager, onSelect: (Detection) -> Unit) {
    val detections by ble.detections.collectAsState()
    val context = LocalContext.current
    var filter by remember { mutableStateOf<String?>(null) }   // category key (null = all)

    fun count(cat: String) = detections.count { it.type.category == cat }
    val shown = filter?.let { f -> detections.filter { it.type.category == f } } ?: detections

    fun exportCsv() {
        val file = File(context.cacheDir, "acab-detections.csv")
        file.writeText(ble.detectionsCsv())
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Export detections"))
    }

    LazyColumn(
        Modifier
            .fillMaxSize()
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(bottom = 16.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Logbook", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    Kicker("${detections.size} DETECTED")
                }
                // Export + clear, like the iOS header; hidden until there's data.
                if (detections.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        IconAction(Icons.Filled.IosShare, "Export detections as CSV", ::exportCsv)
                        IconAction(Icons.Outlined.DeleteOutline, "Clear log") { ble.clearLog() }
                    }
                }
            }
        }

        // 2x2 tiles that toggle the list filter
        item {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FilterTile(DeviceType.FLOCK_CAMERA, "ALPR", count("ALPR"),
                        filter == "ALPR", Modifier.weight(1f)) { filter = if (filter == "ALPR") null else "ALPR" }
                    FilterTile(DeviceType.DRONE, "DRONE", count("DRONE"),
                        filter == "DRONE", Modifier.weight(1f)) { filter = if (filter == "DRONE") null else "DRONE" }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FilterTile(DeviceType.BODY_CAM, "BODY CAM", count("BODY CAM"),
                        filter == "BODY CAM", Modifier.weight(1f)) { filter = if (filter == "BODY CAM") null else "BODY CAM" }
                    FilterTile(DeviceType.TRACKER, "TRACKER", count("TRACKER"),
                        filter == "TRACKER", Modifier.weight(1f)) { filter = if (filter == "TRACKER") null else "TRACKER" }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    FilterTile(DeviceType.POLICE_GEAR, "POLICE", count("POLICE"),
                        filter == "POLICE", Modifier.weight(1f)) { filter = if (filter == "POLICE") null else "POLICE" }
                    Spacer(Modifier.weight(1f))
                }
            }
        }

        if (detections.isEmpty()) {
            item { EmptyState() }
        } else {
            item {
                Kicker(if (filter == null) "ALL DETECTIONS" else "$filter DETECTIONS")
            }
            // one card of divider-separated rows, like the iOS log card
            item {
                Column(Modifier.fillMaxWidth().panel()) {
                    shown.forEachIndexed { i, d ->
                        DetectionRow(d, onClick = { onSelect(d) })
                        if (i < shown.lastIndex) HorizontalDivider(color = Acab.line)
                    }
                }
            }
        }
    }
}

/** Round icon button in the header, like the iOS circular control. */
@Composable
private fun IconAction(icon: ImageVector, contentDescription: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(36.dp)
            .background(Acab.bg2, CircleShape)
            .border(1.dp, Acab.line, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = Acab.dim, modifier = Modifier.size(16.dp))
    }
}

/** Category tile; highlighted when its filter is on. */
@Composable
private fun FilterTile(
    type: DeviceType, label: String, n: Int, active: Boolean,
    modifier: Modifier = Modifier, onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        modifier
            .background(if (active) type.tone().copy(alpha = 0.12f) else Acab.bg2, shape)
            .border(1.dp, if (active) type.tone().copy(alpha = 0.4f) else Acab.line, shape)
            .clickable(onClick = onClick)
            .padding(11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CatGlyph(type, size = 30)
        Spacer(Modifier.size(10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text("$n", color = if (n == 0) Acab.faint else Acab.text,
                fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Kicker(label, color = if (active) type.tone() else if (n == 0) Acab.faint else Acab.dim)
        }
    }
}

/** One log row: glyph, type label, source/method, RSSI + bars. Tap to open the dossier. */
@Composable
private fun DetectionRow(d: Detection, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CatGlyph(d.type, size = 40)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // the specific label, so Flock Camera and Flock Raven stay distinct
                Text(d.type.label, color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                if (d.type.isExperimental) ExpTag()
            }
            // how it was seen, like the iOS row: "BLE / OUI match"
            Text("${d.sourceLabel} · ${d.methodLabel}",
                color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("${d.rssi}", color = d.type.tone(), fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
            SignalBars(rssiBars(d.rssi), tint = d.type.tone())
        }
    }
}

/** Amber pill for an experimental, lower-confidence class. */
@Composable
private fun ExpTag() {
    Text(
        "EXP",
        color = Acab.warn,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.warn.copy(alpha = 0.14f), RoundedCornerShape(4.dp))
            .border(1.dp, Acab.warn.copy(alpha = 0.4f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

/** Placeholder shown while nothing's been spotted yet. */
@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.RadioButtonChecked, contentDescription = null,
            tint = Acab.line, modifier = Modifier.size(38.dp))
        Text("Scanning...", color = Acab.dim, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        Text("Detections log here as Beacons spots surveillance gear nearby.",
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
