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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.automirrored.filled.PlaylistAddCheck
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.outlined.Circle
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
import tech.acab.app.model.displayName
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import java.io.File

/** The Log's top-level lens: everything, only-new-since-the-watermark, or one category. */
private sealed interface LogFilter {
    data object All : LogFilter
    data object NewOnly : LogFilter
    data class Category(val key: String) : LogFilter
}

/** Logbook: detection history with category tiles that double as filters, a new/all
 *  segmented filter, select-mode for batch-ignoring, and a "mark all seen" watermark. */
@Composable
fun LogScreen(ble: AcabBleManager, onSelect: (Detection) -> Unit) {
    val detections by ble.detections.collectAsState()
    val watermark by ble.seenWatermark.collectAsState()   // recomposes "New only" when it moves
    val context = LocalContext.current
    var filter by remember { mutableStateOf<LogFilter>(LogFilter.All) }

    // Select mode: a set of selected detection ids (empty set = not in select mode).
    var selectMode by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }

    fun count(cat: String) = detections.count { it.type.category == cat }
    val newCount = detections.count { ble.isNewSinceWatermark(it) }

    val shown = when (val f = filter) {
        LogFilter.All -> detections
        LogFilter.NewOnly -> detections.filter { ble.isNewSinceWatermark(it) }
        is LogFilter.Category -> detections.filter { it.type.category == f.key }
    }

    fun exitSelect() { selectMode = false; selected = emptySet() }

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
                    Kicker("${detections.size} DETECTED · $newCount NEW")
                }
                // Export, mark-all-seen, select, clear — like the iOS header; hidden until there's data.
                if (detections.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        IconAction(Icons.Filled.IosShare, "Export detections as CSV", ::exportCsv)
                        IconAction(Icons.Filled.DoneAll, "Mark all seen") { ble.markAllSeen() }
                        IconAction(Icons.AutoMirrored.Filled.PlaylistAddCheck, "Select devices") {
                            selectMode = true; selected = emptySet()
                        }
                        IconAction(Icons.Outlined.DeleteOutline, "Clear log") { ble.clearLog() }
                    }
                }
            }
        }

        // All / New-only segmented filter
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SegChip("ALL", detections.size, filter is LogFilter.All) { filter = LogFilter.All }
                SegChip("NEW ONLY", newCount, filter is LogFilter.NewOnly) { filter = LogFilter.NewOnly }
            }
        }

        // 2x2 category tiles that toggle the list filter
        item {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CategoryTile(DeviceType.FLOCK_CAMERA, "ALPR", count("ALPR"), filter, Modifier.weight(1f)) { filter = it }
                    CategoryTile(DeviceType.DRONE, "DRONE", count("DRONE"), filter, Modifier.weight(1f)) { filter = it }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CategoryTile(DeviceType.BODY_CAM, "BODY CAM", count("BODY CAM"), filter, Modifier.weight(1f)) { filter = it }
                    CategoryTile(DeviceType.TRACKER, "TRACKER", count("TRACKER"), filter, Modifier.weight(1f)) { filter = it }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CategoryTile(DeviceType.POLICE_GEAR, "POLICE", count("POLICE"), filter, Modifier.weight(1f)) { filter = it }
                    Spacer(Modifier.weight(1f))
                }
            }
        }

        if (detections.isEmpty()) {
            item { EmptyState() }
        } else {
            item {
                val label = when (val f = filter) {
                    LogFilter.All -> "ALL DETECTIONS"
                    LogFilter.NewOnly -> "NEW DETECTIONS"
                    is LogFilter.Category -> "${f.key} DETECTIONS"
                }
                Kicker(label)
            }
            // one card of divider-separated rows, like the iOS log card
            item {
                Column(Modifier.fillMaxWidth().panel()) {
                    shown.forEachIndexed { i, d ->
                        DetectionRow(
                            d = d,
                            isNew = ble.isNewSinceWatermark(d),
                            selectMode = selectMode,
                            checked = d.id in selected,
                            onClick = {
                                if (selectMode) {
                                    selected = if (d.id in selected) selected - d.id else selected + d.id
                                } else onSelect(d)
                            },
                        )
                        if (i < shown.lastIndex) HorizontalDivider(color = Acab.line)
                    }
                }
            }
        }
    }

    // Select-mode action bar, floating over the bottom of the list.
    if (selectMode) {
        SelectBar(
            count = selected.size,
            onCancel = ::exitSelect,
            onIgnore = {
                val toIgnore = detections.filter { it.id in selected }
                ble.ignoreDevices(toIgnore)
                exitSelect()
            },
        )
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

/** All / New-only segmented chip. */
@Composable
private fun SegChip(label: String, n: Int, active: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .background(if (active) Acab.accent else Acab.bg2, shape)
            .border(1.dp, if (active) androidx.compose.ui.graphics.Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(label, color = if (active) Acab.onAccent else Acab.dim, fontSize = 10.5.sp,
            letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text("$n", color = if (active) Acab.onAccent.copy(alpha = 0.7f) else Acab.faint,
            fontSize = 10.sp, fontFamily = Acab.mono)
    }
}

/** Category tile; highlighted when its filter is on. Toggles the LogFilter to/from this category. */
@Composable
private fun CategoryTile(
    type: DeviceType, label: String, n: Int, filter: LogFilter,
    modifier: Modifier = Modifier, onFilter: (LogFilter) -> Unit,
) {
    val active = filter is LogFilter.Category && filter.key == label
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        modifier
            .background(if (active) type.tone().copy(alpha = 0.12f) else Acab.bg2, shape)
            .border(1.dp, if (active) type.tone().copy(alpha = 0.4f) else Acab.line, shape)
            .clickable { onFilter(if (active) LogFilter.All else LogFilter.Category(label)) }
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

/** One log row: glyph, name, source/method, RSSI + bars. Tap opens the dossier, or toggles
 *  the checkbox in select mode. */
@Composable
private fun DetectionRow(
    d: Detection,
    isNew: Boolean,
    selectMode: Boolean,
    checked: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selectMode) {
            Icon(
                if (checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                contentDescription = if (checked) "Selected" else "Not selected",
                tint = if (checked) Acab.accent else Acab.faint,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.size(12.dp))
        }
        CatGlyph(d.type, size = 40)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // the advertised name when present, else the type + last-4 label
                Text(d.displayName, color = Acab.text, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold, maxLines = 1)
                if (d.type.isExperimental) ExpTag()
                if (isNew) NewDot()
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // how it was seen, like the iOS row: "BLE / OUI match"
                Text("${d.sourceLabel} · ${d.methodLabel}",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
                // offline / Desert mode: the coordinate came from a stale phone fix
                d.locationAgeText?.let { GpsAgeBadge(it) }
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("${d.rssi}", color = d.type.tone(), fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
            SignalBars(rssiBars(d.rssi), tint = d.type.tone())
        }
    }
}

/** Small crimson dot marking a detection first heard after the "mark all seen" watermark. */
@Composable
private fun NewDot() {
    Box(Modifier.size(7.dp).background(Acab.accent, CircleShape))
}

/** Amber clock pill for an offline-stamped location, with the fix age. */
@Composable
private fun GpsAgeBadge(age: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .background(Acab.warn.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
            .border(1.dp, Acab.warn.copy(alpha = 0.35f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    ) {
        Icon(Icons.Filled.Schedule, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(9.dp))
        Text(age, color = Acab.warn, fontSize = 9.sp,
            fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
    }
}

/** Floating action bar shown in select mode: cancel, count, and ignore-selected. */
@Composable
private fun SelectBar(count: Int, onCancel: () -> Unit, onIgnore: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier
                .padding(Acab.pad)
                .fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radius))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(32.dp).clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, contentDescription = "Cancel selection",
                    tint = Acab.dim, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.size(10.dp))
            Text("$count selected", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
            Spacer(Modifier.weight(1f))
            val enabled = count > 0
            Row(
                Modifier
                    .background(if (enabled) Acab.accent else Acab.bg3, RoundedCornerShape(50))
                    .clickable(enabled = enabled, onClick = onIgnore)
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                    tint = if (enabled) Acab.onAccent else Acab.faint, modifier = Modifier.size(14.dp))
                Text("IGNORE", color = if (enabled) Acab.onAccent else Acab.faint,
                    fontSize = 11.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
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
