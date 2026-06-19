package tech.acab.app.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.AlertMode
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone

/** Latest published firmware; bump this with each release. */
private const val LATEST = "1.0"

/** Device tab: board status, scan radios, detectors, and the alert buzzer. */
@Composable
fun DeviceScreen(ble: AcabBleManager) {
    val status by ble.status.collectAsState()
    val name by ble.deviceName.collectAsState()
    val ignored by ble.ignored.collectAsState()
    val mode by ble.alertMode.collectAsState()
    val context = LocalContext.current

    // Mirror the toggles locally so an optimistic flip sticks until the next status
    // frame, instead of snapping back to the stale value mid-write.
    var bleOn by remember { mutableStateOf(status?.ble == true) }
    var wifiOn by remember { mutableStateOf(status?.wifi == true) }
    var bodyCamOn by remember { mutableStateOf(status?.bodyCam == true) }
    var trackerOn by remember { mutableStateOf(status?.tracker == true) }

    // Re-sync the mirrors whenever a fresh status frame lands.
    LaunchedEffect(status) {
        status?.let { s ->
            bleOn = s.ble
            wifiOn = s.wifi
            bodyCamOn = s.bodyCam
            trackerOn = s.tracker
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // header
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("Device", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
            Kicker("PAIRED OVER BLE")
        }

        DeviceHero(name = name, firmware = status?.firmware, connected = status != null)
        FirmwareCard(installed = status?.version)

        // scan radios (optimistic toggles, re-synced above)
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("SCAN RADIOS")
            ToggleRow("Bluetooth LE", "ALPR · drone · trackers", checked = bleOn) {
                bleOn = it; ble.setBleScan(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("Wi-Fi", "2.4 GHz · ALPR · drone RID", checked = wifiOn) {
                wifiOn = it; ble.setWifiScan(it)
            }
        }

        // detectors (optimistic toggles, re-synced above)
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("DETECTORS")
            ToggleRow("Body cams", "Axon signature · experimental",
                checked = bodyCamOn, exp = true) {
                bodyCamOn = it; ble.setBodyCam(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("Bluetooth trackers", "AirTag · Tile · SmartTag · opt-in",
                checked = trackerOn) {
                trackerOn = it; ble.setTracker(it)
            }
        }

        BuzzerCard(
            mode = mode,
            volume = (status?.volume ?: 0),
            onMode = { ble.setAlertMode(it) },
            onVolumeCommit = { ble.setVolume(it, preview = true) },
        )

        StatsGrid(
            uptime = status?.uptime,
            detections = status?.total,
            alerts = when (mode) {
                AlertMode.BUZZER -> status?.volume?.let { "$it%" } ?: "-"
                AlertMode.VIBRATE -> "Vibrate"
                AlertMode.SILENT -> "Silent"
            },
            bleOn = bleOn,
            wifiOn = wifiOn,
        )

        if (ignored.isNotEmpty()) {
            IgnoredCard(ignored = ignored, onUnmute = { ble.unignore(it) })
        }

        DisconnectButton { ble.disconnect() }

        AboutCard(
            onColonel = { context.openUrl("https://colonelpanic.tech") },
            onSource = { context.openUrl("https://github.com/soyboi1312/all-cameras-are-beacons") },
            onPrivacy = { context.openUrl("https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html") },
            onMadeBy = { context.openUrl("https://github.com/soyboi1312") },
        )
    }
}

/** Open an external link in the browser. */
private fun Context.openUrl(url: String) =
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

/** Connected-device hero card. */
@Composable
private fun DeviceHero(name: String?, firmware: String?, connected: Boolean) {
    Row(Modifier.fillMaxWidth().panel(strong = true), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(width = 52.dp, height = 38.dp)
                .background(Acab.bg3, RoundedCornerShape(10.dp))
                .border(1.dp, Acab.line, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.TopStart,
        ) {
            Box(Modifier.padding(start = 12.dp, top = 10.dp).size(7.dp)
                .background(if (connected) Acab.accent else Acab.faint, CircleShape))
        }
        Spacer(Modifier.size(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                if (name?.contains("ACAB") == true) "All Cameras Are Beacons" else (name ?: "ESP32 board"),
                color = Acab.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 2,
            )
            Text("CONNECTED · ${firmware ?: "Beacons"}",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Box(Modifier.size(7.dp).background(if (connected) Acab.accent else Acab.faint, CircleShape))
    }
}

/** Installed vs latest firmware, nudging an update when they differ. */
@Composable
private fun FirmwareCard(installed: String?) {
    val outdated = installed != null && installed != LATEST
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("FIRMWARE")
        Row(verticalAlignment = Alignment.Top) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(installed?.let { "v$it" } ?: "(none)",
                    color = Acab.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Kicker("INSTALLED")
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("v$LATEST", color = if (outdated) Acab.warn else Acab.dim,
                    fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Kicker("LATEST")
            }
        }
        HorizontalDivider(color = Acab.line)
        Text(
            if (outdated) "Update available. Reflash your ESP32 board to v$LATEST."
            else "You're on the latest firmware.",
            color = if (outdated) Acab.warn else Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/**
 * Mute switch (checked = silenced), a master volume slider, and a UI-only PER
 * THREAT section. The firmware only knows about the master level (same as iOS),
 * so the per-threat values just live in SharedPreferences and never get sent.
 */
@Composable
private fun BuzzerCard(
    mode: AlertMode,
    volume: Int,
    onMode: (AlertMode) -> Unit,
    onVolumeCommit: (Int) -> Unit,
) {
    val muted = mode != AlertMode.BUZZER
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("acab.volume", Context.MODE_PRIVATE) }

    // Hold the master value locally so dragging just repaints the UI; write once on
    // release (onValueChangeFinished) rather than on every frame.
    var master by remember { mutableFloatStateOf(volume.toFloat()) }
    LaunchedEffect(volume) { master = volume.toFloat() }

    // Per-threat sliders: seeded from prefs, saved back locally on release.
    var flock by remember { mutableFloatStateOf(prefs.getInt("flock", 90).toFloat()) }
    var drone by remember { mutableFloatStateOf(prefs.getInt("drone", 55).toFloat()) }
    var bodyCam by remember { mutableFloatStateOf(prefs.getInt("bodyCam", 80).toFloat()) }
    var police by remember { mutableFloatStateOf(prefs.getInt("police", 70).toFloat()) }

    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Kicker("ALERTS")

        AlertModeSelector(mode = mode, onMode = onMode)
        Text(
            when (mode) {
                AlertMode.BUZZER -> "board beeps when it spots gear"
                AlertMode.VIBRATE -> "board silent, this phone buzzes on new hits"
                AlertMode.SILENT -> "board silent, no phone feedback"
            },
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
        )

        VolumeSlider("Master volume", value = master, tone = Acab.accent, bold = true, muted = muted,
            onValueChange = { master = it }, onCommit = { onVolumeCommit(master.toInt()) })

        Kicker("PER THREAT")
        ThreatSlider(DeviceType.FLOCK_CAMERA, "ALPR", value = flock, muted = muted,
            onValueChange = { flock = it }) { prefs.edit().putInt("flock", flock.toInt()).apply() }
        ThreatSlider(DeviceType.DRONE, "DRONE", value = drone, muted = muted,
            onValueChange = { drone = it }) { prefs.edit().putInt("drone", drone.toInt()).apply() }
        ThreatSlider(DeviceType.BODY_CAM, "BODY CAM", value = bodyCam, muted = muted,
            onValueChange = { bodyCam = it }) { prefs.edit().putInt("bodyCam", bodyCam.toInt()).apply() }
        ThreatSlider(DeviceType.POLICE_GEAR, "POLICE", value = police, muted = muted,
            onValueChange = { police = it }) { prefs.edit().putInt("police", police.toInt()).apply() }
    }
}

/** Three-way alert mode: a row of equal pill segments in the CatChip style. The
 *  active one fills with the accent; the rest sit on bg2 with a hairline border. */
@Composable
private fun AlertModeSelector(mode: AlertMode, onMode: (AlertMode) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        AlertModeSegment("Buzzer", mode == AlertMode.BUZZER, Modifier.weight(1f)) { onMode(AlertMode.BUZZER) }
        AlertModeSegment("Vibrate", mode == AlertMode.VIBRATE, Modifier.weight(1f)) { onMode(AlertMode.VIBRATE) }
        AlertModeSegment("Silent", mode == AlertMode.SILENT, Modifier.weight(1f)) { onMode(AlertMode.SILENT) }
    }
}

@Composable
private fun AlertModeSegment(label: String, active: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Box(
        modifier
            .background(if (active) Acab.accent else Acab.bg2, shape)
            .border(1.dp, if (active) Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .padding(vertical = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label.uppercase(),
            color = if (active) Acab.onAccent else Acab.dim,
            fontSize = 11.sp,
            letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono,
            maxLines = 1,
        )
    }
}

/** Labelled volume slider: drag repaints only, one write on release. */
@Composable
private fun VolumeSlider(
    label: String, value: Float, tone: Color, bold: Boolean, muted: Boolean,
    onValueChange: (Float) -> Unit, onCommit: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = Acab.text, fontSize = 14.sp,
                fontWeight = if (bold) FontWeight.Medium else FontWeight.Normal)
            Spacer(Modifier.weight(1f))
            Text(if (muted) "-" else "${value.toInt()}",
                color = tone, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
        }
        Slider(
            value = value, onValueChange = onValueChange, onValueChangeFinished = onCommit,
            valueRange = 0f..100f, enabled = !muted,
            colors = SliderDefaults.colors(
                thumbColor = tone, activeTrackColor = tone, inactiveTrackColor = Acab.line,
            ),
        )
    }
}

/** Compact per-threat slider with a category glyph; saves to prefs on release. */
@Composable
private fun ThreatSlider(
    type: DeviceType, label: String, value: Float, muted: Boolean,
    onValueChange: (Float) -> Unit, onCommit: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CatGlyph(type, size = 26)
        Text(label, color = Acab.text, fontSize = 11.sp, fontWeight = FontWeight.Medium,
            fontFamily = Acab.mono, modifier = Modifier.width(52.dp))
        Slider(
            value = value, onValueChange = onValueChange, onValueChangeFinished = onCommit,
            valueRange = 0f..100f, enabled = !muted, modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(
                thumbColor = type.tone(), activeTrackColor = type.tone(), inactiveTrackColor = Acab.line,
            ),
        )
        Text("${value.toInt()}", color = Acab.dim, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
            fontFamily = Acab.mono, modifier = Modifier.width(26.dp))
    }
}

/** 2x2 summary at a glance: uptime, detections, alert mode, active radios. */
@Composable
private fun StatsGrid(
    uptime: Int?, detections: Int?, alerts: String, bleOn: Boolean, wifiOn: Boolean,
) {
    val scanning = when {
        bleOn && wifiOn -> "BLE+WiFi"
        bleOn -> "BLE"
        wifiOn -> "WiFi"
        else -> "off"
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("UPTIME", uptime?.let(::uptimeText) ?: "-", Modifier.weight(1f))
            StatTile("DETECTIONS", detections?.toString() ?: "-", Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("ALERTS", alerts, Modifier.weight(1f))
            StatTile("SCANNING", scanning, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(kick: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Kicker(kick)
        Text(value, color = Acab.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Seconds to a short "1h 22m" or "22m" string. */
private fun uptimeText(seconds: Int): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

/** Muted devices, each with an UNMUTE button. */
@Composable
private fun IgnoredCard(
    ignored: List<tech.acab.app.ble.IgnoredDevice>, onUnmute: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("IGNORED")
        ignored.forEachIndexed { i, dev ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(dev.label.ifEmpty { "Unknown device" },
                        color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    Text(shortMac(dev.mac), color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
                }
                Spacer(Modifier.size(8.dp))
                Box(
                    Modifier
                        .border(1.dp, Acab.lineStrong, CircleShape)
                        .clickable { onUnmute(dev.mac) }
                        .padding(horizontal = 8.dp, vertical = 5.dp),
                ) {
                    Text("UNMUTE", color = Acab.accent, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp, fontFamily = Acab.mono)
                }
            }
            if (i != ignored.lastIndex) HorizontalDivider(color = Acab.line)
        }
    }
}

/** Last two octets of a MAC, for a compact caption. */
private fun shortMac(mac: String): String {
    val parts = mac.split(":")
    return if (parts.size >= 2) parts.takeLast(2).joinToString(":").uppercase() else mac.uppercase()
}

/** What the app is, the hardware it runs on, where the source lives, and the privacy stance. */
@Composable
private fun AboutCard(onColonel: () -> Unit, onSource: () -> Unit, onPrivacy: () -> Unit, onMadeBy: () -> Unit) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("ABOUT")
        Text("All Cameras Are Beacons is a companion app for counter-surveillance scanner firmware, built for Colonel Panic's OUI-Spy hardware.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        HorizontalDivider(color = Acab.line)
        AboutLink("Colonel Panic", "colonelpanic.tech · OUI-Spy hardware", onColonel)
        HorizontalDivider(color = Acab.line)
        AboutLink("Source on GitHub", "github.com/soyboi1312/all-cameras-are-beacons", onSource)
        HorizontalDivider(color = Acab.line)
        AboutLink("Privacy", "no data leaves your device", onPrivacy)
        Text("made by soyboi", color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono,
            modifier = Modifier.fillMaxWidth().clickable(onClick = onMadeBy).padding(top = 4.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun AboutLink(title: String, sub: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(sub, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Text("↗", color = Acab.accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Labelled switch row; checked state comes straight from the caller. */
@Composable
private fun ToggleRow(
    name: String, sub: String, checked: Boolean,
    exp: Boolean = false, tint: Color = Acab.accent, onChange: (Boolean) -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                if (exp) {
                    Spacer(Modifier.size(6.dp))
                    Box(
                        Modifier
                            .background(Acab.warn, RoundedCornerShape(4.dp))
                            .padding(horizontal = 5.dp, vertical = 2.dp),
                    ) {
                        Text("EXP", color = Acab.onAccent, fontSize = 9.sp,
                            fontWeight = FontWeight.Bold, letterSpacing = 1.sp, fontFamily = Acab.mono)
                    }
                }
            }
            Text(sub, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Switch(
            checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Acab.onAccent, checkedTrackColor = tint,
                uncheckedThumbColor = Acab.dim, uncheckedTrackColor = Acab.bg3,
                uncheckedBorderColor = Acab.line,
            ),
        )
    }
}

/** The disconnect button. */
@Composable
private fun DisconnectButton(onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radius))
            .clickable(onClick = onClick)
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text("Disconnect", color = Acab.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}
