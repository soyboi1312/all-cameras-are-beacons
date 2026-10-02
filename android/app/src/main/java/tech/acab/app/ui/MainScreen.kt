package tech.acab.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Radar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.Stable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import tech.acab.app.MainActivity
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.renderBoardCopy
import tech.acab.app.model.Detection
import tech.acab.app.ui.theme.Acab

/** The four tabs, in bar order. The icon is filled when the tab is selected and outlined when
 *  it is not (M3 NavigationBar convention, C6). */
private enum class Tab(val label: String, val selectedIcon: ImageVector, val unselectedIcon: ImageVector) {
    STATUS("Status", Icons.Filled.Radar, Icons.Outlined.Radar),
    MAP("Map", Icons.Filled.Map, Icons.Outlined.Map),
    LOG("Log", Icons.AutoMirrored.Filled.ListAlt, Icons.AutoMirrored.Outlined.ListAlt),
    DEVICE("Beacon", Icons.Filled.Memory, Icons.Outlined.Memory),   // user-facing label; enum name stays DEVICE (identifier)
}

/** One published top bar per Tab (C7). Never nulled on dispose: the host draws only the
 *  SELECTED tab's slot, and a returning tab re-publishes. */
@Stable
internal class TabTopBarSlot {
    internal var content by mutableStateOf<(@Composable () -> Unit)?>(null)
}

/** The slot of the tab being composed. TabBody provides it around the whole tab `when`, so its
 *  scope also covers the inline dossier panes of the wide LOG and MAP branches: DetailScreen
 *  must never call [TabTopBar] (it would replace the Log search bar at 840dp and wider). */
internal val LocalTabTopBarSlot = staticCompositionLocalOf<TabTopBarSlot?> { null }

/** Publishes this tab's top bar. Call UNCONDITIONALLY at the top level of a tab ROOT screen
 *  (Status, Log, Beacon; Map makes no call): no early return before it, never inside an if, and
 *  after the values it captures. The content may vary (for example a Beacon
 *  sub-screen swaps in a back navigationIcon and its own title); the call may not. The bar
 *  composes in the HOST's scope: pass values in, never rely on CompositionLocals provided inside
 *  the screen. Capture only what the bar draws, never the detections list or a per-tick clock,
 *  or the bar recomposes at the feed rate. Use TopAppBar / SearchBar with DEFAULT colours and
 *  DEFAULT windowInsets; never add statusBarsPadding(). A SearchBar goes inline only (never the
 *  expanded full-screen mode, which would cover the banner stack), inside
 *  ProvideTextStyle(MaterialTheme.typography.bodyLarge). A screen that needs a scroll behaviour
 *  creates it and passes it to both its bar and its own list's nestedScroll. */
@Composable
internal fun TabTopBar(content: @Composable () -> Unit) {
    val slot = LocalTabTopBarSlot.current ?: return
    val latest = rememberUpdatedState(content)
    DisposableEffect(slot) {
        slot.content = @Composable { latest.value() }
        // Deliberately empty: the slot keeps the last bar (see TabTopBarSlot).
        onDispose { }
    }
}

/** Draws [slot]'s bar. [consumeStatusInset] is true when a banner above it (SampleDataBanner)
 *  already padded for the status bar: sibling consumption does not propagate, so the bar would
 *  otherwise pad for it a second time. Each tab root's bar is ONE row: the title leading (the
 *  Log: its search field) and the tab's actions trailing (the Map draws its own floating bar the
 *  same way). TWIN: iOS TabHeader
 *  (the `.tabHeader(title) { trailing }` modifier in Components.swift), which gives every iOS tab
 *  root the same one-row header at non-accessibility sizes. */
@Composable
private fun TabTopBarHost(slot: TabTopBarSlot, consumeStatusInset: Boolean) {
    val c = slot.content ?: return
    Box(if (consumeStatusInset) Modifier.consumeWindowInsets(WindowInsets.statusBars) else Modifier) { c() }
}

/** String round-trip for the nullable Log-lens seed. LogFilter is a sealed interface, not
 *  Parcelable, so rememberSaveable needs this by hand; null itself round-trips (the framework
 *  stores the null and skips restore), so only the four concrete shapes are encoded. */
private val LogFilterSeedSaver = Saver<LogFilter?, String>(
    save = { f ->
        when (f) {
            null -> null
            LogFilter.All -> "ALL"
            LogFilter.NewOnly -> "NEW"
            LogFilter.OfflineOnly -> "OFFLINE"
            is LogFilter.Category -> "CAT:${f.key}"
        }
    },
    restore = { s ->
        when {
            s == "ALL" -> LogFilter.All
            s == "NEW" -> LogFilter.NewOnly
            s == "OFFLINE" -> LogFilter.OfflineOnly
            s.startsWith("CAT:") -> LogFilter.Category(s.removePrefix("CAT:"))
            else -> null
        }
    },
)

/** Four-tab shell: bottom nav swaps the body between screens. Internal because
 *  [initialBeaconSegment]'s type is internal; AcabApp is its only caller. [openNotifyToken] and
 *  [openLiveModeToken] are the checklist sheet's bridges into Beacon > Notifications and
 *  Beacon > Live Mode: AcabApp owns them (the sheet lives outside this shell) and bumps one; this
 *  shell then switches to the Beacon tab and hands DeviceScreen a token of its own, which pushes
 *  that page. [initialBeaconSegment] is the Beacon tab's
 *  first segment (the store-screenshot launch hook), a plain seed. */
@Composable
internal fun MainScreen(
    ble: AcabBleManager,
    reconnecting: Boolean = false,
    locationGranted: Boolean = false,
    onRequestLocation: () -> Unit = {},
    modifier: Modifier = Modifier,
    openNotifyToken: Int = 0,
    openLiveModeToken: Int = 0,
    initialBeaconSegment: BeaconSegment = BeaconSegment.BOARD,
) {
    val demoMode by ble.demoMode.collectAsState()
    // Read through its delegate inside the movable content below, so the improve-detection gate
    // stays live; the link state changes a handful of times a session, not at the feed rate.
    val connState by ble.state.collectAsState()
    // movableContentOf below is remembered once (no keys, and a remember calculation cannot call
    // composables), so every PLAIN value captured in it freezes at its first composition; the
    // state-backed vars are read through their delegates and stay live. Carry the changing plain
    // params through State holders instead. The permission flags matter most: MainActivity
    // refreshes them from onResume (syncPermissionState), which is exactly when a runtime grant
    // lands, and a grant does not recreate the activity - frozen, the map's allow-location banner
    // would never clear and the readiness rows would keep reporting a permission off after the
    // user turned it on. onRequestLocation is a bound reference to the activity and behaves the
    // same whenever it was captured, so it needs no holder.
    val reconnectingState = rememberUpdatedState(reconnecting)
    val locationGrantedState = rememberUpdatedState(locationGranted)
    // Saveable: no configChanges are declared, so a dark-theme flip or multi-window resize
    // recreates the activity; without this the shell would snap back to the Status tab
    // (iOS SwiftUI state survives the equivalent).
    var tab by rememberSaveable { mutableIntStateOf(0) }
    // The open dossier: a Detection SNAPSHOT, frozen at tap (MapScreen re-resolves the live row
    // on tap; the ~3 Hz feed must not recompose the whole dossier).
    var selected by remember { mutableStateOf<Detection?>(null) }
    // Rotation survival for the dossier: Detection is not Parcelable and its live fields would
    // be stale by restore anyway, so the SAVEABLE footprint is the ID STRING only. The first
    // detections pass after recreation re-resolves it against the log (dropped silently when
    // the row is gone - the same rule the vanish effect below applies to a live dossier).
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // One-shot restore latch: holds the restored id only between recreation and the first
    // detections pass. A plain holder, not Compose state.
    val selectedIdToRestore = remember { arrayOf(selectedId) }
    // The ONLY way to open/close the dossier: writes the snapshot and its saveable id together.
    // A SideEffect mirror was tried first and zombie-restored closed dossiers: it lived in a
    // recompose scope that never READS `selected`, so with a quiet detections StateFlow (board
    // disconnected, nothing new heard) a manual close never cleared selectedId, and rotation
    // resurrected the dossier. Paired writes cannot desynchronize.
    val setSelected: (Detection?) -> Unit = { d ->
        selected = d
        selectedId = d?.id
    }
    // Filter seed handed to LogScreen; cleared on the next manual tab tap so a consumed
    // deep link doesn't keep re-applying the NEW lens forever. Saveable (with logScreenKey):
    // rotation right after a deep link must restore the same lens, not silently reset it.
    var logFilterSeed by rememberSaveable(stateSaver = LogFilterSeedSaver) { mutableStateOf<LogFilter?>(null) }
    var logScreenKey by rememberSaveable { mutableIntStateOf(0) }
    var openDetectorsToken by rememberSaveable { mutableIntStateOf(0) }
    // Help + support opened from the Status toolbar: a full-screen overlay OVER the current tab,
    // like the dossier, so the tab stays selected and Back returns to it (J6). It used to switch to
    // the Beacon tab and push Help there, so Back left the owner on Beacon > THIS PHONE. TWIN: iOS
    // DashboardView pushes Help on the Status stack and Status stays selected. Saveable, so a
    // rotation keeps it open. Every deep link that switches tabs closes it (they run while it is
    // up only from outside the shell: a notification, the checklist sheet).
    var helpOpen by rememberSaveable { mutableStateOf(false) }
    var openContributeToken by rememberSaveable { mutableIntStateOf(0) }

    // The paused-Log feed lives in an activity-scoped ViewModel keyed by a FIXED string (see
    // LogScreen pauseStateKey = "main"), so it survives tab switches but is NOT reset by the
    // key(logScreenKey) re-seed a deep link uses. Resume it on every deep-link re-seed below, or
    // arriving at the Log via the offline-sync banner, a Live-Activity NEW link, or a Status
    // category tile lands on a stale frozen snapshot instead of the live rows those exist to show.
    val logPauseVm: LogViewModel = viewModel(key = "log-pause:main")

    // Per-tab UI state (Log lens, Map camera, Device drawer) parks here while a tab is off
    // screen, so switching tabs stops silently resetting filters, pause state and camera
    // position. The screens themselves use rememberSaveable, which this holder also routes
    // through onSaveInstanceState, so rotation and recreation restore the same state.
    val tabStateHolder = rememberSaveableStateHolder()
    // One top-bar slot per tab (C7); remembered once, so the body allocates nothing per publish.
    val topBarSlots = remember { Tab.entries.associateWith { TabTopBarSlot() } }

    // Status category tiles deep-link into the Log with that category's lens applied. Reuses
    // the deep-link seed + key bump so an already-composed LogScreen re-seeds too.
    val openLogCategory: (String) -> Unit = { key ->
        logFilterSeed = LogFilter.Category(key)
        logScreenKey++
        if (logPauseVm.paused) logPauseVm.resume()   // show the tile's live rows, not a frozen list
        setSelected(null)
        helpOpen = false
        tab = Tab.LOG.ordinal
    }
    val openDetectorSettings: () -> Unit = {
        openDetectorsToken++
        setSelected(null)
        helpOpen = false
        tab = Tab.DEVICE.ordinal
    }
    val openHelp: () -> Unit = {
        setSelected(null)
        helpOpen = true
    }
    // Help's "Improve detection" route (the dossier's Related help, and the Status Help overlay):
    // the Beacon tab opens the contribute flow on THIS PHONE. Offered only while
    // improveDetectionAvailable holds (below).
    val openImproveDetection: () -> Unit = {
        setSelected(null)
        helpOpen = false
        openContributeToken++
        tab = Tab.DEVICE.ordinal
    }
    // Beacon > This phone > Saved log: the Log's ALL lens, live. The same seed + key bump the
    // category deep link uses, so an already-composed LogScreen re-seeds too.
    val openSavedLog: () -> Unit = {
        logFilterSeed = LogFilter.All
        logScreenKey++
        logPauseVm.resume()
        setSelected(null)
        helpOpen = false
        tab = Tab.LOG.ordinal
    }

    // The checklist sheet's two chevrons (AcabApp): when a token passes its own saveable
    // watermark, switch to the Beacon tab and bump this shell's own token for DeviceScreen, which
    // pushes the page with its own watermark. The watermarks are seeded with the token as it
    // stands when this shell is created: AcabApp's counters outlive the shell (a disconnect
    // disposes it, a reconnect builds a new one), and an old bump must not switch tabs again on
    // the next connect. The shell-owned tokens start at 0 with the shell, as DeviceScreen's
    // watermarks do, so the two can never disagree about which bumps are new. Saveable, so a
    // rotation neither switches tabs again nor re-pushes the page.
    var shellNotifyToken by rememberSaveable { mutableIntStateOf(0) }
    OnOpenToken(openNotifyToken, seed = openNotifyToken) {
        shellNotifyToken++; setSelected(null); helpOpen = false; tab = Tab.DEVICE.ordinal
    }
    var shellLiveModeToken by rememberSaveable { mutableIntStateOf(0) }
    OnOpenToken(openLiveModeToken, seed = openLiveModeToken) {
        shellLiveModeToken++; setSelected(null); helpOpen = false; tab = Tab.DEVICE.ordinal
    }

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
        setSelected(null)          // close the dossier (overlay or inline pane alike)
        helpOpen = false
        tab = Tab.MAP.ordinal      // no-op when the dossier was opened from the map itself
    }

    // The board the reconnect banner names. The drop cleared the status, so the connect target's
    // kind (kept through the drop by AcabBleManager.targetKind) is the only fw-derived source. The
    // offline-sync banner names the same board: it is raised on the replay of a READY link, whose
    // every Status frame refreshed targetKind, and it can outlive a later drop.
    val reconnectKind by ble.targetKind.collectAsState()

    // Offline-buffer replay count banner (raised at replay-complete when n > 0). Shown over the
    // tabs so it's seen on reconnect regardless of the active tab; cleared only by its own
    // view/dismiss buttons, so a tab switch can't silently discard the one-shot count (iOS parity).
    val offlineBanner by ble.offlineSyncBanner.collectAsState()
    // Board-side replay shortfall (begin.n promised vs end.n sent): rides the same banner as an
    // attempt-level disclosure. The blocked row remains uncommitted in the ring for a later sync.
    val offlineUnreplayed by ble.offlineSyncUnreplayed.collectAsState()

    // Drive-mode notification tap (F27): land on the Log tab with the NEW filter active.
    // The signal lives on MainActivity because AcabApp sits between the activity and this
    // shell; it stays pending until this shell is composed (READY link) to consume it.
    val openLogNew by MainActivity.openLogNew
    LaunchedEffect(openLogNew) {
        if (openLogNew) {
            MainActivity.openLogNew.value = false
            logFilterSeed = LogFilter.NewOnly
            logScreenKey++   // re-seed LogScreen even if the Log tab is already showing
            if (logPauseVm.paused) logPauseVm.resume()   // surface the just-synced/NEW rows, not a frozen list
            tab = Tab.LOG.ordinal
            setSelected(null)  // an open dossier would cover the log
            helpOpen = false   // and so would Help
        }
    }

    // R8: if a dossier is open in the two-pane and its detection vanishes (clear log / bulk-ignore),
    // drop the selection so the pane returns to the placeholder instead of a stale dossier.
    // Selection belongs to the evidence log, not the active nearby projection. Muting a device
    // removes it from Status/Map but must not make an open dossier vanish or break rotation restore.
    val detections by ble.logDetections.collectAsState()
    LaunchedEffect(detections) {
        // Restore leg first: re-resolve a rotation-restored dossier id once, against the first
        // log pass after recreation. A missing row restores to "no dossier", never an error.
        selectedIdToRestore[0]?.let { id ->
            selectedIdToRestore[0] = null
            // setSelected on purpose: a missing row must also CLEAR the saveable id, or the
            // stale id would zombie-restore on the next rotation.
            setSelected(detections.firstOrNull { it.id == id })
        }
        // sid hoisted out of the closure so this ~3 Hz membership scan compares against a local
        // rather than re-reading through the optional on every compared row. Detection.id is a
        // plain stored val (see the id initializer in Models.kt), so nothing is allocated either
        // way: the hoist saves a field load, not string churn.
        selected?.let { s ->
            val sid = s.id
            if (detections.none { it.id == sid }) setSelected(null)
        }
    }

    // One MOVABLE instance of the tab content: the wide (NavigationRail) and compact (bottom
    // bar) shells below are two different call sites, and composing TabBody directly in each
    // meant crossing the 840dp width class (rotating a big phone, changing a foldable's
    // posture) destroyed and rebuilt the whole tab subtree - every per-tab rememberSaveable
    // (Log lens, Map camera, Device drawer) died in the same frame the SaveableStateHolder was
    // reparking it, because the leaving provider saves AFTER the entering one has already
    // restored-empty. movableContentOf MOVES the live composition between the call sites
    // instead, so nothing is recreated and nothing needs to save at all. Width-dependent
    // values ride as parameters (a captured `wide` would freeze at its first value); the
    // state-backed vars (tab, selected, seeds) are captured and recompose normally.
    val tabBody = remember {
        movableContentOf<Boolean, Dp, Modifier> { wide, detailWidth, modifier ->
            TabBody(
                ble = ble,
                tab = tab,
                selected = selected,
                wide = wide,
                detailWidth = detailWidth,
                stateHolder = tabStateHolder,
                topBarSlots = topBarSlots,
                logScreenKey = logScreenKey,
                logFilterSeed = logFilterSeed,
                mapFocus = mapFocus,
                onMapFocusConsumed = { mapFocus = null },
                onOpenInMap = openInMap,
                onOpenLogCategory = openLogCategory,
                onOpenDetectorSettings = openDetectorSettings,
                onOpenHelp = openHelp,
                onOpenSavedLog = openSavedLog,
                onImproveDetection = if (improveDetectionAvailable(connState, demoMode)) openImproveDetection else null,
                openDetectorsToken = openDetectorsToken,
                openContributeToken = openContributeToken,
                openNotifyToken = shellNotifyToken,
                openLiveModeToken = shellLiveModeToken,
                initialBeaconSegment = initialBeaconSegment,
                reconnecting = reconnectingState.value,
                demoMode = demoMode,
                locationGranted = locationGrantedState.value,
                onRequestLocation = onRequestLocation,
                onSelect = { setSelected(it) },
                modifier = modifier,
            )
        }
    }

    // T4/T3/T5: layouts split on the viewport width class. Phone and small-tablet widths
    // (< 840.dp) keep the single column: Scaffold + bottom bar, each screen full width. The
    // Log/Map two-pane used to unlock at 600.dp, where reserving 380-420.dp for the detail
    // column left the OTHER pane unusably narrow; both panes only get a workable minimum at
    // >= 840.dp, so `wide` and the NavigationRail (`expanded`) now split together there.
    BoxWithConstraints(modifier.fillMaxSize()) {
        val wide = maxWidth >= 840.dp
        val expanded = maxWidth >= 840.dp
        val fullScreenDetailOpen = selected != null && (!wide || Tab.entries[tab] == Tab.STATUS)
        // A full-screen overlay (the dossier, or Help from Status) covers the shell, its top bar
        // and the SampleDataBanner in it.
        val overlayOpen = fullScreenDetailOpen || helpOpen
        val baseSemanticsModifier = if (overlayOpen) {
            Modifier.clearAndSetSemantics { }
        } else Modifier
        // The inline detail pane's width: 380.dp keeps the companion pane >= ~380.dp at the
        // 840 breakpoint (minus the rail); the roomier 420 only where there is width to spare.
        val detailWidth: Dp = if (maxWidth >= 1100.dp) 420.dp else 380.dp
        // The sample escape hatch sits above the tab's own bar in both shells, so every banner
        // stacks above the bar (as iOS RootView's topBanners sit above the tab shell). While an
        // overlay covers the shell, the banner moves up into the banner stack ABOVE the overlay
        // instead ([sampleAboveOverlay]), so a sample dossier never looks like real evidence: the
        // banner stays on every screen, as on iOS (J2 / CON-16).
        val showSample = demoMode && !overlayOpen
        val sampleAboveOverlay = demoMode && overlayOpen
        val topBarSlot = topBarSlots.getValue(Tab.entries[tab])

        // Reconnect and replay banners take REAL layout space above the shell AND above the
        // full-screen dossier, so nothing they can cover is drawn underneath them. They used to
        // be an overlay Column aligned TopCenter, composed AFTER the dossier: with a dossier open
        // a link drop put the reconnect banner straight over the dossier's own top bar (same
        // status-bar inset, same height) and swallowed its back control, leaving no visible way
        // out of a detection. Suppressing the banner there (what the offline one below does)
        // would have hidden a real transient status exactly where "your work stays open" is the
        // most reassuring, so the layout gives way instead of the message.
        // The banners STACK rather than replace each other: a reconnect must not swallow "N
        // detections replayed while you were away", and on a board that keeps dropping the link
        // that suppression would last indefinitely. Only the TOP banner carries the status-bar
        // inset, and the content below CONSUMES it, so Scaffold's topBar, the wide Row and the
        // dossier each apply zero there rather than double-padding.
        // TWIN: iOS RootView.swift's `topBanners`, real layout space in a VStack above the tab
        // shell (NOT the .safeAreaInset it used to be), changed for the same class of bug.
        // "View" reuses the Live-Activity deep-link path (openLogNew) to land on the Log/NEW lens.
        val offlineBannerShown = !fullScreenDetailOpen && !demoMode && offlineBanner != null
        Column(Modifier.fillMaxSize()) {
            if (reconnecting) {
                ReconnectingBanner(kind = reconnectKind)
            }
            if (sampleAboveOverlay) {
                SampleDataBanner(onExit = { ble.exitDemo() }, includeStatusInset = !reconnecting)
            }
            if (offlineBannerShown) offlineBanner?.let { n ->
                OfflineSyncBanner(
                    n = n,
                    unreplayed = offlineUnreplayed,
                    kind = reconnectKind,
                    onView = {
                        ble.clearOfflineSyncBanner()
                        setSelected(null)             // an open dossier would cover the log
                        MainActivity.openLogNew.value = true
                    },
                    onDismiss = { ble.clearOfflineSyncBanner() },
                    includeStatusInset = !reconnecting,
                )
            }
            Box(
                Modifier.weight(1f).fillMaxSize().then(
                    // A drawn banner already occupies the status-bar strip and pads for it, so
                    // consume that inset for everything below; without this the shell and the
                    // dossier would each push themselves down a second status bar's worth.
                    if (reconnecting || offlineBannerShown || sampleAboveOverlay) {
                        Modifier.consumeWindowInsets(WindowInsets.statusBars)
                    } else Modifier,
                ),
            ) {
                if (expanded) {
                    // targetSdk 36 enforces edge-to-edge, and unlike the compact branch (whose Scaffold
                    // insets its content) this Row had no inset handling at all: landscape content drew
                    // under the status bar, gesture bar and display cutout. background BEFORE the inset
                    // padding so bg still paints to the physical edges; windowInsetsPadding consumes
                    // what it applies, so the rail (which handles its own safe-drawing insets
                    // internally) doesn't double-pad.
                    Row(
                        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)
                            .then(baseSemanticsModifier)
                            .windowInsetsPadding(WindowInsets.safeDrawing),
                    ) {
                        // M3 defaults from the scheme (C6): no colour overrides.
                        NavigationRail {
                            Tab.entries.forEachIndexed { i, t ->
                                NavigationRailItem(
                                    selected = tab == i,
                                    onClick = { logFilterSeed = null; tab = i },
                                    // The adjacent NavigationRailItem label names the destination; a
                                    // second description on the glyph makes TalkBack announce it twice.
                                    icon = { Icon(if (tab == i) t.selectedIcon else t.unselectedIcon, contentDescription = null) },
                                    label = { Text(t.label) },
                                )
                            }
                        }
                        Column(Modifier.weight(1f).fillMaxSize()) {
                            // Reserve real layout space for the sample escape hatch. The former overlay
                            // sat directly on top of every screen's title and first controls.
                            if (showSample) {
                                SampleDataBanner(onExit = { ble.exitDemo() }, includeStatusInset = false)
                            }
                            // The Row's safeDrawing padding already consumed the status inset.
                            TabTopBarHost(topBarSlot, consumeStatusInset = false)
                            tabBody(wide, detailWidth, Modifier.weight(1f).fillMaxSize())
                        }
                    }
                } else {
                    Scaffold(
                        modifier = baseSemanticsModifier,
                        topBar = {
                            // Nothing emitted (Map, or a tab's first frame): Scaffold still pads the
                            // content by the status inset.
                            if (showSample || topBarSlot.content != null) {
                                Column {
                                    if (showSample) SampleDataBanner(onExit = { ble.exitDemo() })
                                    TabTopBarHost(topBarSlot, consumeStatusInset = showSample)
                                }
                            }
                        },
                        bottomBar = {
                            // M3 defaults from the scheme (C6): no colour overrides.
                            NavigationBar {
                                Tab.entries.forEachIndexed { i, t ->
                                    NavigationBarItem(
                                        selected = tab == i,
                                        onClick = { logFilterSeed = null; tab = i },
                                        icon = { Icon(if (tab == i) t.selectedIcon else t.unselectedIcon, contentDescription = null) },
                                        label = { Text(t.label) },
                                    )
                                }
                            }
                        },
                    ) { inner ->
                        tabBody(wide, detailWidth, Modifier.fillMaxSize().padding(inner))
                    }
                }

                // dossier fills the shell area over the tabs (the banner stack above stays
                // visible, the sample banner included: sampleAboveOverlay); system back closes it
                // (not the app). At `wide` on LOG/MAP the dossier
                // is already inline (drawn by TabBody), so the overlay only fires in compact, or
                // on STATUS where there's no inline pane.
                BackHandler(enabled = selected != null) { setSelected(null) }
                if (fullScreenDetailOpen) {
                    selected?.let { d ->
                        DetailScreen(
                            detection = d,
                            ble = ble,
                            onBack = { setSelected(null) },
                            onOpenInMap = openInMap,
                            locationGranted = locationGranted,
                            onRequestLocation = onRequestLocation,
                            onImproveDetection = if (improveDetectionAvailable(connState, demoMode)) openImproveDetection else null,
                            // Full screen over the shell: the dossier announces itself as a pane.
                            overlay = true,
                        )
                    }
                }
                // Help from Status, over the current tab (J6). Composed after the dossier's
                // handler, so Back closes Help first; the two are never open together (openHelp
                // closes the dossier).
                BackHandler(enabled = helpOpen) { helpOpen = false }
                if (helpOpen) {
                    HelpOverTabOverlay(
                        onClose = { helpOpen = false },
                        onImproveDetection = if (improveDetectionAvailable(connState, demoMode)) openImproveDetection else null,
                    )
                }
            }
        }
    }
}

/** Help + support over the current tab, opened from the Status toolbar's help button. Full
 *  screen like the dossier overlay, under the banner stack; the Surface blocks touches to the tab
 *  underneath. The bar title is also the pane title TalkBack announces when the overlay opens,
 *  the pattern DeviceScreen's SubScreen set. [onImproveDetection] is non-null only while improveDetectionAvailable holds, and
 *  moves to Beacon > THIS PHONE's contribute flow (the same route the dossier's Related help
 *  takes). TWIN: iOS DashboardView's Help push on the Status stack. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HelpOverTabOverlay(onClose: () -> Unit, onImproveDetection: (() -> Unit)?) {
    Surface(
        Modifier.fillMaxSize().semantics { paneTitle = HELP_OVER_TAB_TITLE },
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            Modifier.fillMaxSize()
                // The bar pads the status bar; this pads the sides and the navigation bar.
                .windowInsetsPadding(
                    WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            TopAppBar(
                title = { Text(HELP_OVER_TAB_TITLE) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
            Box(Modifier.widthIn(max = 640.dp).fillMaxWidth().weight(1f)) {
                HelpScreen(onImproveDetection = onImproveDetection, modifier = Modifier.fillMaxSize())
            }
        }
    }
}

/** One string for the Help overlay's bar title and its pane title, so the two cannot drift. */
private const val HELP_OVER_TAB_TITLE = "Help + support"

/** The sample banner's words, the same on both apps (TWIN: iOS sampleBannerMessage /
 *  sampleBannerExitLabel in RootView.swift, drawn by SampleDataBannerView). Tour card 3's "Exit
 *  Sample Data" names this button. */
internal const val SAMPLE_BANNER_MESSAGE = "Sample Data, Not Nearby Devices"
internal const val SAMPLE_BANNER_EXIT_LABEL = "Exit Sample Data"

/** Always-visible escape hatch while the synthetic store is active. */
@Composable
private fun SampleDataBanner(
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
    includeStatusInset: Boolean = true,
) {
    Box(
        modifier.fillMaxWidth()
            .then(if (includeStatusInset) Modifier.statusBarsPadding() else Modifier)
            .padding(Acab.pad),
        contentAlignment = Alignment.TopCenter,
    ) {
        AcabBanner(SAMPLE_BANNER_MESSAGE, Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
            TextButton(onClick = onExit) { Text(SAMPLE_BANNER_EXIT_LABEL) }
        }
    }
}

/** The reconnect banner's two lines, per kind (renderBoardCopy; null reads as beacon).
 *  TWIN: iOS LinkRecoveryBannerView's title and subtitle in RootView.swift, byte-identical. */
internal const val RECONNECT_BANNER_TITLE_TEMPLATE = "reconnecting to your {noun}"
internal const val RECONNECT_BANNER_BODY = "your open screen and capture are preserved."

/** A transient link drop is status, not navigation: keep the shell and its field-work state
 *  usable while the manager reconnects in the background. [kind] is the reconnect target's. */
@Composable
private fun ReconnectingBanner(kind: BoardKind?, modifier: Modifier = Modifier) {
    Box(
        modifier.fillMaxWidth().statusBarsPadding().padding(Acab.pad),
        contentAlignment = Alignment.TopCenter,
    ) {
        AcabBanner(
            RECONNECT_BANNER_BODY,
            Modifier.widthIn(max = 640.dp).fillMaxWidth(),
            title = renderBoardCopy(RECONNECT_BANNER_TITLE_TEMPLATE, kind),
            progress = true,
        )
    }
}

/** The offline-sync banner's line. [n] records were replayed, [unreplayed] the board promised but
 *  did not send; [kind] is the board that buffered them (null reads as beacon). The unreplayed
 *  clause describes THIS attempt, not permanent evidence loss: an over-MTU row remains uncommitted
 *  in the board's ring and a later sync can retry it. Copy voice: all-lowercase, a comma, no
 *  em-dash. Singular "1 detection" when n == 1. TWIN: iOS offlineSyncMessage(count:unreplayed:kind:)
 *  (RootView.swift), byte-identical. */
internal fun offlineSyncMessage(n: Int, unreplayed: Int, kind: BoardKind?): String = when {
    n == 0 && unreplayed > 0 -> renderBoardCopy(
        if (unreplayed == 1) "1 buffered detection couldn't be replayed from the {noun}"
        else "$unreplayed buffered detections couldn't be replayed from the {noun}", kind)
    unreplayed > 0 ->
        (if (n == 1) "1 detection recorded while you were away"
         else "$n detections recorded while you were away") +
            " ($unreplayed more couldn't be replayed)"
    n == 1 -> "1 detection recorded while you were away"
    else -> "$n detections recorded while you were away"
}

/** Transient, dismissible banner raised when the board reconnects and replays records it
 *  buffered while the phone was away. "View" jumps to the Log's NEW lens; the x dismisses it.
 *  The line is [offlineSyncMessage]; [kind] names the board. */
@Composable
private fun OfflineSyncBanner(
    n: Int,
    kind: BoardKind?,
    unreplayed: Int = 0,
    onView: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    includeStatusInset: Boolean = true,
) {
    val message = offlineSyncMessage(n, unreplayed, kind)
    // TopCenter: the banner is capped at 640dp, and the Box's default TopStart alignment left it
    // hugging the left edge on anything wider than the cap (tablet, landscape).
    Box(modifier.fillMaxWidth()
            .then(if (includeStatusInset) Modifier.statusBarsPadding() else Modifier)
            .padding(Acab.pad),
        contentAlignment = Alignment.TopCenter) {
        AcabBanner(message, Modifier.widthIn(max = 640.dp).fillMaxWidth(), icon = Icons.Filled.Inventory2) {
            FilledTonalButton(onClick = onView) { Text("View") }
            IconButton(onClick = onDismiss) {
                Icon(Icons.Filled.Close, contentDescription = "Dismiss",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
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
    detailWidth: Dp,
    stateHolder: SaveableStateHolder,
    topBarSlots: Map<Tab, TabTopBarSlot>,
    logScreenKey: Int,
    logFilterSeed: LogFilter?,
    mapFocus: Pair<Double, Double>?,
    onMapFocusConsumed: () -> Unit,
    onOpenInMap: (Double, Double) -> Unit,
    onOpenLogCategory: (String) -> Unit,
    onOpenDetectorSettings: () -> Unit,
    onOpenHelp: () -> Unit,
    onOpenSavedLog: () -> Unit,
    // Non-null only while improveDetectionAvailable holds; null hides the dossier's route.
    onImproveDetection: (() -> Unit)?,
    openDetectorsToken: Int,
    openContributeToken: Int,
    openNotifyToken: Int,
    openLiveModeToken: Int,
    // A plain launch seed: DeviceScreen reads it once, so the movable freeze is harmless.
    initialBeaconSegment: BeaconSegment,
    reconnecting: Boolean,
    demoMode: Boolean,
    locationGranted: Boolean,
    onRequestLocation: () -> Unit,
    onSelect: (Detection?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier) {
        // SaveableStateProvider keyed by tab: each tab's rememberSaveable state (Log lens,
        // Map camera, Device drawer) parks while the tab is off screen instead of being lost
        // with the composition, so a tab switch is no longer a silent reset.
        stateHolder.SaveableStateProvider(Tab.entries[tab].name) {
        // The selected tab's top-bar slot, for its screen's TabTopBar call (C7).
        CompositionLocalProvider(LocalTabTopBarSlot provides topBarSlots.getValue(Tab.entries[tab])) {
        when (Tab.entries[tab]) {
            Tab.STATUS -> StatusScreen(ble, reconnecting = reconnecting, onSelect = { onSelect(it) },
                onOpenLogCategory = onOpenLogCategory,
                onOpenDetectorSettings = onOpenDetectorSettings,
                onOpenHelp = onOpenHelp)
            Tab.MAP -> {
                // T5: keep the pin visible by parking the dossier in a right rail; the map
                // stays full-width until something is selected. ONE MapScreen call site
                // whatever the width class or selection: a Row with a single weighted child
                // renders identically to a bare full-size map, and the detail pane enters and
                // leaves BESIDE the map's slot instead of swapping it. The old shape branched
                // on `wide && selected != null` with MapScreen on both sides, so on a tablet
                // every pin tap and every dossier close tore down the MapView (camera, follow
                // mode, category lens) and snapped the map back to follow-location.
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxSize()) {
                        MapScreen(ble, onSelect = { onSelect(it) },
                            focus = mapFocus, onFocusConsumed = onMapFocusConsumed,
                            locationGranted = locationGranted, onRequestLocation = onRequestLocation)
                    }
                    if (wide && selected != null) {
                        Box(Modifier.width(detailWidth).fillMaxSize()) {
                            DetailScreen(selected, ble, onBack = { onSelect(null) },
                                onOpenInMap = onOpenInMap,
                                locationGranted = locationGranted,
                                onRequestLocation = onRequestLocation,
                                onImproveDetection = onImproveDetection,
                                inPane = true)
                        }
                    }
                }
            }
            Tab.LOG -> {
                // T3: a fixed list column beside an inline detail pane; tapping a row fills
                // the pane instead of pushing a full-screen dossier. Same single-call-site
                // rule as MAP: the list column is the constant, only its width rule and the
                // divider + detail pane flip with `wide`, so LogScreen keeps one composition
                // slot and the movable TabBody can carry the lens across the 840dp crossing
                // (two call sites would re-key every rememberSaveable inside it).
                // A New dot means "arrived since you last looked at the log": advance the
                // seen-watermark when this branch leaves composition, i.e. when the user switches
                // AWAY from the Log tab. Sits OUTSIDE key(logScreenKey) below, so a deep-link
                // re-key (openLogNew) does not dispose it and empty the NEW lens; and opening a
                // dossier keeps tab == LOG, so drilling into a row never counts as leaving.
                // Mirrors iOS MainTabView.onChange(of: tab). markAllSeen is a cheap locked read.
                // Capture the mode when this Log composition is created. exitDemo flips the
                // manager's demo flag before Compose disposes this branch; checking only inside
                // markAllSeen at disposal time would therefore let sample navigation advance the
                // genuine persisted watermark during the exit edge. Sample data never marks rows
                // seen on leave: only Mark Seen does (TWIN: iOS logTabLeaveMarksSeen in RootView).
                val openedInDemo = demoMode
                DisposableEffect(Unit) {
                    onDispose { if (!openedInDemo) ble.markAllSeen() }
                }
                Row(Modifier.fillMaxSize()) {
                    val listWidth = if (wide) Modifier.width(380.dp) else Modifier.weight(1f)
                    Box(listWidth.fillMaxSize()) {
                        key(logScreenKey) {
                            LogScreen(
                                ble,
                                onSelect = { onSelect(it) },
                                initialFilter = logFilterSeed,
                                // compact never highlights: the dossier is a full-screen
                                // overlay there, not a row selection (matches the old shape)
                                selectedId = if (wide) selected?.id else null,
                                // and its rows draw no chevron: a tap fills the pane (P3-6)
                                wide = wide,
                            )
                        }
                    }
                    if (wide) {
                        VerticalDivider()
                        Box(Modifier.weight(1f).fillMaxSize()) {
                            selected?.let {
                                DetailScreen(it, ble, onBack = { onSelect(null) },
                                    onOpenInMap = onOpenInMap,
                                    locationGranted = locationGranted,
                                    onRequestLocation = onRequestLocation,
                                    onImproveDetection = onImproveDetection,
                                    inPane = true)
                            } ?: EmptyDetailPlaceholder()
                        }
                    }
                }
            }
            Tab.DEVICE -> DeviceScreen(
                ble = ble,
                reconnecting = reconnecting,
                openDetectorsToken = openDetectorsToken,
                locationGranted = locationGranted,
                onRequestLocation = onRequestLocation,
                openContributeToken = openContributeToken,
                openNotifyToken = openNotifyToken,
                openLiveModeToken = openLiveModeToken,
                initialSegment = initialBeaconSegment,
                onOpenSavedLog = onOpenSavedLog,
            )
        }
        }
        }
    }
}

/** Optional permission request lives at the feature boundary instead of the pairing prompt. The
 * map remains usable for already-geotagged detections while this non-blocking banner is present.
 * Internal so MapScreen can compose it below its chip rows (C11). */
@Composable
internal fun LocationContextBanner(onAllow: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(Acab.pad), contentAlignment = Alignment.TopCenter) {
        AcabBanner(
            "optional: adds your position and future hit pins. detection works without it. location stays on your devices and is never uploaded automatically.",
            Modifier.widthIn(max = 520.dp).fillMaxWidth(),
            icon = Icons.Filled.LocationOn,
        ) {
            TextButton(onClick = onAllow) { Text("Allow") }
        }
    }
}

/** Resting state of the two-pane detail column: nothing is open yet. */
@Composable
private fun EmptyDetailPlaceholder() {
    Box(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ListAlt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.outlineVariant,
                modifier = Modifier.size(40.dp),
            )
            Text("Select a detection", style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Pick a row to open its full dossier here.", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
