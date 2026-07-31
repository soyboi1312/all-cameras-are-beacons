package tech.acab.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.MainActivity
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.ui.theme.Acab

private enum class Tab(val label: String, val icon: ImageVector) {
    STATUS("Status", Icons.Filled.Radar),
    MAP("Map", Icons.Filled.Map),
    LOG("Log", Icons.AutoMirrored.Outlined.ListAlt),
    DEVICE("Device", Icons.Filled.Memory),
}

/** Four-tab shell: bottom nav swaps the body between screens. */
@Composable
fun MainScreen(
    ble: AcabBleManager,
    initialTab: Int = 0,
    initialLogFilter: LogFilter? = null,
) {
    // Saveable: no configChanges are declared, so a dark-theme flip or multi-window resize
    // recreates the activity; without this the shell would snap back to the Status tab
    // (iOS SwiftUI state survives the equivalent).
    var tab by rememberSaveable { mutableIntStateOf(initialTab) }
    var selected by remember { mutableStateOf<Detection?>(null) }
    // Filter seed handed to LogScreen; cleared on the next manual tab tap so a consumed
    // deep link doesn't keep re-applying the NEW lens forever.
    var logFilterSeed by remember { mutableStateOf(initialLogFilter) }
    var logScreenKey by remember { mutableIntStateOf(0) }

    // "Open in map" jump from a dossier's location thumbnail. The coordinate is stashed here
    // so the request survives the Map tab not being composed yet; MapScreen consumes it
    // exactly once and clears it back through onMapFocusConsumed. Saveable so an activity
    // recreation between the tap and the consume replays the jump instead of dropping it.
    var mapFocus by rememberSaveable(
        stateSaver = listSaver<Pair<Double, Double>?, Double>(
            save = { it?.let { (lat, lon) -> listOf(lat, lon) } ?: emptyList() },
            restore = { if (it.size == 2) it[0] to it[1] else null },
        ),
    ) { mutableStateOf<Pair<Double, Double>?>(null) }
    val openInMap: (Double, Double) -> Unit = { lat, lon ->
        mapFocus = lat to lon
        selected = null            // close the dossier (overlay or inline pane alike)
        tab = Tab.MAP.ordinal      // no-op when the dossier was opened from the map itself
    }

    // Offline-buffer replay count banner (raised at replay-complete when n > 0). Shown over the
    // tabs so it's seen on reconnect regardless of the active tab; cleared only by its own
    // view/dismiss buttons, so a tab switch can't silently discard the one-shot count (iOS parity).
    val offlineBanner by ble.offlineSyncBanner.collectAsState()

    // Drive-mode notification tap (F27): land on the Log tab with the NEW filter active.
    // The signal lives on MainActivity because AcabApp sits between the activity and this
    // shell; it stays pending until this shell is composed (READY link) to consume it.
    val openLogNew by MainActivity.openLogNew
    LaunchedEffect(openLogNew) {
        if (openLogNew) {
            MainActivity.openLogNew.value = false
            logFilterSeed = LogFilter.NewOnly
            logScreenKey++   // re-seed LogScreen even if the Log tab is already showing
            tab = Tab.LOG.ordinal
            selected = null  // an open dossier would cover the log
        }
    }

    // R8: if a dossier is open in the two-pane and its detection vanishes (clear log / bulk-ignore),
    // drop the selection so the pane returns to the placeholder instead of a stale dossier.
    val detections by ble.detections.collectAsState()
    LaunchedEffect(detections) {
        // sid hoisted: Detection.id is a computed getter, and rebuilding it per compared row
        // doubled this ~3 Hz scan's string churn while a dossier is open
        selected?.let { s ->
            val sid = s.id
            if (detections.none { it.id == sid }) selected = null
        }
    }

    // T4/T3/T5: layouts split on the viewport width class. Phone-portrait (compact, < 600.dp)
    // is untouched: Scaffold + bottom bar, and each screen fills the single column. `wide`
    // (medium+, >= 600.dp) unlocks the Log/Map two-pane; `expanded` (>= 840.dp) swaps the
    // bottom bar for a side NavigationRail.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 600.dp
        val expanded = maxWidth >= 840.dp

        if (expanded) {
            Row(Modifier.fillMaxSize().background(Acab.bg)) {
                NavigationRail(containerColor = Acab.bg2) {
                    Tab.entries.forEachIndexed { i, t ->
                        NavigationRailItem(
                            selected = tab == i,
                            onClick = { logFilterSeed = initialLogFilter; tab = i },
                            icon = { Icon(t.icon, contentDescription = t.label) },
                            label = { Text(t.label) },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = Acab.accent,
                                selectedTextColor = Acab.accent,
                                indicatorColor = Acab.bg3,
                                unselectedIconColor = Acab.faint,
                                unselectedTextColor = Acab.faint,
                            ),
                        )
                    }
                }
                TabBody(
                    ble = ble,
                    tab = tab,
                    selected = selected,
                    wide = wide,
                    logScreenKey = logScreenKey,
                    logFilterSeed = logFilterSeed,
                    mapFocus = mapFocus,
                    onMapFocusConsumed = { mapFocus = null },
                    onOpenInMap = openInMap,
                    onSelect = { selected = it },
                    modifier = Modifier.weight(1f).fillMaxSize(),
                )
            }
        } else {
            Scaffold(
                containerColor = Acab.bg,
                bottomBar = {
                    NavigationBar(containerColor = Acab.bg2) {
                        Tab.entries.forEachIndexed { i, t ->
                            NavigationBarItem(
                                selected = tab == i,
                                onClick = { logFilterSeed = initialLogFilter; tab = i },
                                icon = { Icon(t.icon, contentDescription = t.label) },
                                label = { Text(t.label) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = Acab.accent,
                                    selectedTextColor = Acab.accent,
                                    indicatorColor = Acab.bg3,
                                    unselectedIconColor = Acab.faint,
                                    unselectedTextColor = Acab.faint,
                                ),
                            )
                        }
                    }
                },
            ) { inner ->
                TabBody(
                    ble = ble,
                    tab = tab,
                    selected = selected,
                    wide = wide,
                    logScreenKey = logScreenKey,
                    logFilterSeed = logFilterSeed,
                    mapFocus = mapFocus,
                    onMapFocusConsumed = { mapFocus = null },
                    onOpenInMap = openInMap,
                    onSelect = { selected = it },
                    modifier = Modifier.fillMaxSize().padding(inner),
                )
            }
        }

        // dossier sits full-screen over the tabs; system back closes it (not the app).
        // At `wide` on LOG/MAP the dossier is already inline (drawn by TabBody), so the
        // overlay only fires in compact, or on STATUS where there's no inline pane.
        BackHandler(enabled = selected != null) { selected = null }
        if (!wide || Tab.entries[tab] == Tab.STATUS) {
            selected?.let { d ->
                DetailScreen(d, ble, onBack = { selected = null }, onOpenInMap = openInMap)
            }
        }

        // Reconnect count banner, pinned near the top over whatever tab is showing. "view"
        // reuses the Live-Activity deep-link path (openLogNew) to land on the Log/NEW lens.
        offlineBanner?.let { n ->
            OfflineSyncBanner(
                n = n,
                onView = {
                    ble.clearOfflineSyncBanner()
                    selected = null              // an open dossier would cover the log
                    MainActivity.openLogNew.value = true
                },
                onDismiss = { ble.clearOfflineSyncBanner() },
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }
    }
}

/** Transient, dismissible banner raised when the beacon reconnects and replays records it
 *  buffered while the phone was away. "view" jumps to the Log's NEW lens; the x dismisses it.
 *  Copy voice: all-lowercase, a comma, no em-dash. Singular "1 detection" when n == 1. */
@Composable
private fun OfflineSyncBanner(n: Int, onView: () -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    // R9: match the iOS OfflineSyncBannerView anatomy (1e button/radius rules) - radiusSm corners,
    // a tray glyph in accent, mono 11.5 message, and a filled-capsule "view". Copy is unchanged.
    val shape = RoundedCornerShape(Acab.radiusSm)
    Box(modifier.fillMaxWidth().statusBarsPadding().padding(Acab.pad)) {
        Row(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .background(Acab.bg2, shape)
                .border(1.dp, Acab.lineStrong, shape)
                .padding(start = 14.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Inventory2, contentDescription = null,
                tint = Acab.accent, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                if (n == 1) "1 detection recorded while you were away"
                else "$n detections recorded while you were away",
                color = Acab.text, fontSize = 11.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Box(
                Modifier
                    .height(30.dp)
                    .background(Acab.accent, RoundedCornerShape(50))
                    .clickable(onClick = onView)
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("view", color = Acab.onAccent, fontSize = 11.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 0.5.sp)
            }
            Box(
                Modifier.size(30.dp).clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, contentDescription = "Dismiss",
                    tint = Acab.faint, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/** The tab content, shared by the bottom-bar (compact/medium) and nav-rail (expanded)
 *  shells. In compact (`wide` false) each screen fills the single column exactly as before.
 *  When `wide`, Log and Map split into a list/map pane plus an inline detail pane. */
@Composable
private fun TabBody(
    ble: AcabBleManager,
    tab: Int,
    selected: Detection?,
    wide: Boolean,
    logScreenKey: Int,
    logFilterSeed: LogFilter?,
    mapFocus: Pair<Double, Double>?,
    onMapFocusConsumed: () -> Unit,
    onOpenInMap: (Double, Double) -> Unit,
    onSelect: (Detection?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier) {
        when (Tab.entries[tab]) {
            Tab.STATUS -> StatusScreen(ble, onSelect = { onSelect(it) })
            Tab.MAP -> {
                // T5: keep the pin visible by parking the dossier in a right rail; the map
                // stays full-width until something is selected.
                if (wide && selected != null) {
                    Row(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f).fillMaxSize()) {
                            MapScreen(ble, onSelect = { onSelect(it) },
                                focus = mapFocus, onFocusConsumed = onMapFocusConsumed)
                        }
                        Box(Modifier.width(420.dp).fillMaxSize()) {
                            DetailScreen(selected, ble, onBack = { onSelect(null) },
                                onOpenInMap = onOpenInMap)
                        }
                    }
                } else {
                    MapScreen(ble, onSelect = { onSelect(it) },
                        focus = mapFocus, onFocusConsumed = onMapFocusConsumed)
                }
            }
            Tab.LOG -> {
                // T3: a fixed list column beside an inline detail pane; tapping a row fills
                // the pane instead of pushing a full-screen dossier.
                if (wide) {
                    Row(Modifier.fillMaxSize()) {
                        Box(Modifier.width(380.dp).fillMaxSize()) {
                            key(logScreenKey) {
                                LogScreen(
                                    ble,
                                    onSelect = { onSelect(it) },
                                    initialFilter = logFilterSeed,
                                    selectedId = selected?.id,
                                )
                            }
                        }
                        VerticalDivider(color = Acab.line)
                        Box(Modifier.weight(1f).fillMaxSize()) {
                            selected?.let {
                                DetailScreen(it, ble, onBack = { onSelect(null) },
                                    onOpenInMap = onOpenInMap)
                            } ?: EmptyDetailPlaceholder()
                        }
                    }
                } else {
                    key(logScreenKey) {
                        LogScreen(ble, onSelect = { onSelect(it) }, initialFilter = logFilterSeed)
                    }
                }
            }
            Tab.DEVICE -> DeviceScreen(ble)
        }
    }
}

/** Resting state of the two-pane detail column: nothing is open yet. */
@Composable
private fun EmptyDetailPlaceholder() {
    Box(
        Modifier.fillMaxSize().background(Acab.bg),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ListAlt,
                contentDescription = null,
                tint = Acab.line,
                modifier = Modifier.size(40.dp),
            )
            Text("Select a detection", color = Acab.dim, fontSize = 14.sp,
                fontWeight = FontWeight.Medium)
            Text("Pick a row to open its full dossier here.", color = Acab.faint,
                fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }
}
