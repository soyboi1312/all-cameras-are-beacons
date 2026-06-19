package tech.acab.app.ui

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.FoundBoard
import tech.acab.app.model.Detection
import tech.acab.app.ui.theme.Acab

/**
 * The pre-connection screen: scan, connect (which starts bonding), then stream
 * detections. Once the link is up, the four-tab MainScreen takes over.
 */
@Composable
fun AcabApp(
    ble: AcabBleManager,
    permissionsGranted: Boolean,
    onRequestPermissions: () -> Unit,
) {
    val state by ble.state.collectAsState()
    val found by ble.found.collectAsState()
    val detections by ble.detections.collectAsState()
    val status by ble.status.collectAsState()
    val name by ble.deviceName.collectAsState()

    // Once linked, hand off to the four-tab shell.
    if (state == ConnState.READY) {
        MainScreen(ble)
        return
    }

    Surface(modifier = Modifier.fillMaxSize(), color = Acab.bg) {
        Column(Modifier.fillMaxSize().padding(Acab.pad)) {
            Header(connected = state == ConnState.READY, name = name, version = status?.version)
            Spacer(Modifier.height(16.dp))

            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    !permissionsGranted ->
                        PrimaryButton("Grant Bluetooth permission", onRequestPermissions)
                    state == ConnState.READY ->
                        DetectionList(detections, onDisconnect = { ble.disconnect() })
                    state == ConnState.CONNECTING ->
                        Centered("Connecting…")
                    state == ConnState.BONDING ->
                        Centered("Pairing…")
                    else ->
                        ScanSection(
                            scanning = state == ConnState.SCANNING,
                            found = found,
                            onScan = { ble.startScan() },
                            onConnect = { ble.connect(it) },
                        )
                }
            }

            // Let a user (or App Review) explore the app with sample data, no board needed.
            if (permissionsGranted && state != ConnState.READY &&
                state != ConnState.CONNECTING && state != ConnState.BONDING) {
                DemoButton(onClick = { ble.seedDemoData() })
                Spacer(Modifier.height(12.dp))
            }
            ScopeFootnote()
        }
    }
}

@Composable
private fun Header(connected: Boolean, name: String?, version: String?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Beacons", color = Acab.text, fontSize = 22.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono)
        Spacer(Modifier.weight(1f))
        val label = when {
            connected && version != null -> "LINKED v$version"
            connected -> "LINKED"
            else -> "OFFLINE"
        }
        Kicker(label, color = if (connected) Acab.accent else Acab.dim)
    }
    if (connected && name != null) {
        Text(name, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

@Composable
private fun ScanSection(
    scanning: Boolean,
    found: List<FoundBoard>,
    onScan: () -> Unit,
    onConnect: (FoundBoard) -> Unit,
) {
    Column {
        PrimaryButton(if (scanning) "Scanning…" else "Scan for boards", onScan)
        Spacer(Modifier.height(12.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(found) { board ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onConnect(board) }
                        .panel(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(board.name, color = Acab.text, fontSize = 15.sp)
                        Text(board.device.address, color = Acab.dim, fontSize = 11.sp,
                            fontFamily = Acab.mono)
                    }
                    Text("${board.rssi}", color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono)
                }
            }
        }
    }
}

@Composable
private fun DetectionList(detections: List<Detection>, onDisconnect: () -> Unit) {
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Kicker("${detections.size} DETECTED", color = Acab.dim)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDisconnect) { Text("Disconnect", color = Acab.accent) }
        }
        Spacer(Modifier.height(8.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(detections) { d ->
                Row(Modifier.fillMaxWidth().panel(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(d.type.label, color = Acab.text, fontSize = 15.sp)
                        Text("${d.mac}  ·  ${d.type.category}", color = Acab.dim,
                            fontSize = 11.sp, fontFamily = Acab.mono)
                    }
                    Text("${d.rssi}", color = Acab.accent, fontSize = 13.sp, fontFamily = Acab.mono)
                }
            }
        }
    }
}

@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(containerColor = Acab.accent, contentColor = Acab.onAccent),
    ) { Text(label, fontWeight = FontWeight.Bold) }
}

/** Outlined button that seeds sample data so you can poke around without a board. */
@Composable
private fun DemoButton(onClick: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .clickable { onClick() }
            .padding(vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text("Continue without pairing", color = Acab.text, fontSize = 13.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text("explore the app with sample data", color = Acab.dim, fontSize = 10.sp,
            fontFamily = Acab.mono)
    }
}

@Composable
private fun ScopeFootnote() {
    Text(
        "Passive detection only. Beacons never jams, spoofs, or interferes.",
        color = Acab.dim,
        fontSize = 9.sp,
        fontFamily = Acab.mono,
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
    )
}

@Composable
private fun Centered(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = Acab.dim, fontFamily = Acab.mono)
    }
}
