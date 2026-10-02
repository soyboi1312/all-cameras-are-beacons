package tech.acab.app.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.Hearing
import androidx.compose.material.icons.outlined.ShoppingBag
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.ConnectHint
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.FoundBoard
import tech.acab.app.ble.OtaPhase
import tech.acab.app.ble.OtaProgress
import tech.acab.app.ble.RememberedBoardCopy
import tech.acab.app.ble.connectedBoardKind
import tech.acab.app.ble.pickerRows
import tech.acab.app.ble.renderBoardCopy
import tech.acab.app.ble.resolveBoardKind
import tech.acab.app.ble.resolveScreenKind
import tech.acab.app.ble.showsPairWindowNote
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.WordmarkFace
import tech.acab.app.ui.theme.tabular

internal fun shouldUseReconnectShell(
    shellEstablished: Boolean,
    hadLink: Boolean,
    state: ConnState,
    otaActive: Boolean,
): Boolean = shellEstablished && hadLink && state == ConnState.CONNECTING && !otaActive

/** The post-connect checklist opens on a ready, real session whose seen flag is not set. READY
 *  must open it before any effect can start Live Mode. Android reads only first_run_tour_seen;
 *  the iOS twin onboardingPresentation (RootView.swift) also reads the pre-checklist build's
 *  finish-setup pending key, which only iOS armed mid-onboarding (contracts 9.1 says why Android
 *  has no such key to honour). */
internal fun shouldOpenChecklist(state: ConnState, demoMode: Boolean, seen: Boolean): Boolean =
    state == ConnState.READY && !demoMode && !seen

/** Automatic Live startup is earned only by completing the checklist ([tourSeen]), and it waits
 *  while the checklist's Location request is pending or on screen ([locationPromptPending]), so
 *  the Live rationale dialog never stacks with the system Location dialog. */
internal fun shouldAttemptDefaultLive(
    state: ConnState,
    demoMode: Boolean,
    tourSeen: Boolean,
    promptDeferred: Boolean,
    wanted: Boolean,
    active: Boolean,
    attempted: Boolean,
    locationPromptPending: Boolean,
): Boolean = state == ConnState.READY && !demoMode && tourSeen && !promptDeferred && wanted &&
    !active && !attempted && !locationPromptPending

/** The connect screen's primary button. "Continue" before the permission: the system dialog
 *  that follows is the only thing that grants it, so the button never reads as the app granting
 *  itself access. iOS twin: bluetoothScanButtonTitle in ConnectView.swift. */
internal fun scanButtonTitle(isScanning: Boolean, granted: Boolean): String = when {
    isScanning -> "Stop Scanning"
    granted -> "Scan for Beacons"
    else -> "Continue"
}

/** The opt-in line, the one copy on Android: the hears panel draws it, and so does the checklist's
 *  detectors row once the first status frame is in. */
internal const val CONNECT_OPT_IN_SENTENCE = "trackers and network cameras are opt-in, switch them on in Beacon settings."

// ---- the connect screen's per-kind copy (renderBoardCopy; null reads as beacon) ----
// Each template is one literal, byte-identical to its iOS twin in ConnectView.swift (the platform
// pairing words aside, which the {os_pairing_request} token carries), so the drift script compares
// the templates themselves. Lowercase-first sentences; row titles keep sentence case.

/** The idle arm's one setup line, under the hero. The pairing-request step is not repeated here:
 *  the connecting body, the secure pairing note over the heard boards and Setup + pairing help
 *  (q-setup) each carry it at the moment it applies. TWIN: iOS ConnectCopy.setupSentence. */
internal const val CONNECT_SETUP_TEMPLATE = "power on your {noun} and keep it nearby."
/** The pre-permission rationale after its bold lead (the platform's permission name). */
internal const val CONNECT_RATIONALE_REST_TEMPLATE =
    "connects your phone to your {noun}. the {noun} does the listening, not your phone."
/** The Bluetooth-off panel's body. */
internal const val CONNECT_BLUETOOTH_OFF_TEMPLATE = "turn on Bluetooth to find your {noun}."
/** Nearby devices denied for good (Settings) and denied once (retry), Android 12 and newer. */
internal const val NEARBY_DENIED_SETTINGS_TEMPLATE =
    "allow Nearby devices for beacons in Settings. it is used only to find and connect to your {noun}."
internal const val NEARBY_DENIED_RETRY_TEMPLATE =
    "Nearby devices permission was not allowed. it is used only to find and connect to your {noun}. the {noun} does the listening."
/** Scanning, nothing heard yet. */
internal const val CONNECT_LOOKING_TEMPLATE = "looking for your {noun}…"
/** The scan window closed with nothing heard. */
internal const val CONNECT_NONE_FOUND_TEMPLATE =
    "no {plural} found. make sure your {noun} is powered on and nearby, then scan again."
/** The connecting / pairing panel's guidance, under the platform's own status word. */
internal const val CONNECTING_BODY_TEMPLATE =
    "keep your {noun} powered on and nearby. approve {os_pairing_request} if it appears."
/** The pre-shell reconnect panel's title and body. */
internal const val RECONNECT_PANEL_TITLE_TEMPLATE = "reconnecting to your {noun}…"
internal const val RECONNECT_PANEL_BODY_TEMPLATE =
    "it reconnects on its own when the {noun} is back in range, even in the background. keep waiting, or stop to scan for a different {noun}."
/** The note above the heard boards: a tap pairs, and pairing encrypts the link. */
internal const val CONNECT_SECURE_PAIRING_NOTE_TEMPLATE =
    "tap your {noun}, then accept {os_pairing_request} if it appears. pairing encrypts the detection link to this phone."
/** The hears row's title and its two spoken actions (the row expands in place). TWIN: iOS
 *  ConnectCopy.hearsRow, hearsShow, hearsHide. */
internal const val CONNECT_HEARS_TEMPLATE = "What your {noun} can hear"
internal const val CONNECT_HEARS_SHOW_TEMPLATE = "show what your {noun} can hear"
internal const val CONNECT_HEARS_HIDE_TEMPLATE = "hide what your {noun} can hear"
/** The saved-log row's kicker. */
internal const val CONNECT_SAVED_LOG_KICKER_TEMPLATE = "history on this phone · browse and export, no {noun} needed"
/** The footnote under the list. Lowercase-first like every other sentence on this screen (it
 *  used to open "Passive ... The"). */
internal const val CONNECT_SCOPE_FOOTNOTE_TEMPLATE = "passive detection only. the {noun} never jams, spoofs, or interferes."
/** The OTA wait screen's two lines, while the updating board reboots. */
internal const val OTA_WAIT_REBOOTING_TEMPLATE =
    "the {noun} is rebooting into the new firmware. keep the app open, it reconnects on its own."
internal const val OTA_WAIT_NOTE_TEMPLATE = "this can take up to a minute. don't unplug the {noun}."
/** The Live Mode notification rationale, on the first READY. */
internal const val LIVE_PERMISSION_BODY_TEMPLATE =
    "Live Mode keeps a private counter in the status bar and on the lock screen while your {noun} is connected. Android may ask to allow notifications next."
/** The "Setup + pairing help" row's supporting line. Names no board, so it is one literal, not a
 *  template. TWIN: iOS ConnectCopy.setupHelpSubtitle (ConnectView.swift), byte-identical (settled 2026-09-25 to this, the
 *  clearer of the two old lines; iOS read "power, secure pairing, and recovery · works offline"). */
internal const val CONNECT_SETUP_HELP_SUBTITLE =
    "offline help for power, permissions, pairing, and connection recovery"
/** The failure panel's title, above the manager's hint. */
internal const val CONNECTION_HINT_TITLE = "connection did not finish"

/** One picker row's kind: the row's live advert hint, else the stored kind for the remembered
 *  board (the only row pickerRows marks owned). A remembered board reflashed with another image
 *  reads by what it advertises now; a nameless (stealth) or unheard one by its stored kind. The
 *  picker lists boards before any connect, so no fw kind applies here. [rememberedKind] is
 *  AcabBleManager.rememberedKind (the stored kind). */
internal fun pickerRowKind(owned: Boolean, kindHint: BoardKind?, rememberedKind: BoardKind?): BoardKind? =
    resolveBoardKind(firmwareLabel = null, storedKind = rememberedKind?.takeIf { owned }, advertHint = kindHint)

/** A scanned (not remembered) row's title: its kind's noun, "beacon" for an unknown or nameless
 *  advert. The raw advertised name ("ACAB", "ACAB-mesh") never reaches the title. */
internal fun scannedRowTitle(kind: BoardKind?): String = (kind ?: BoardKind.BEACON).noun

/** The address line a picker row draws: the board's advertised address, or null for the DEBUG
 *  board-kind stand-in (AcabBleManager.applyDebugBoardKind), whose address is a placeholder and
 *  not a board's.
 *
 *  Do not test the address bits here. An earlier rule hid an address whose first octet has the
 *  top bits 01, to hide the rotating Resolvable Private Address of a bench firmware build (that
 *  build option is removed, see "Peripheral address, bonding and privacy" in
 *  docs/ble-protocol.md). Those bits mean "resolvable private" only in a RANDOM address. The
 *  board advertises its fixed PUBLIC factory address, where they mean nothing, so the rule hid
 *  every board whose address starts 0x40 to 0x7F. The address type cannot gate the test either:
 *  ScanResult carries none and BluetoothDevice.getAddressType is API 35, above this app's
 *  minSdk. A bench board that still holds the old privacy build draws a rotating address here;
 *  a firmware that rotates again must revisit this rule.
 *
 *  iOS has no equivalent line: CoreBluetooth never exposes a peer MAC. */
internal fun pickerAddressLine(address: String): String? =
    address.takeIf { it != AcabBleManager.DEBUG_REMEMBERED_ADDRESS }

enum class NearbyPermissionDenial { NONE, RETRYABLE, SETTINGS }

/** Turn the platform permission result into a stable, directly renderable recovery state. */
internal fun resolveNearbyPermissionDenial(
    granted: Boolean,
    requestedBefore: Boolean,
    canAskAgain: Boolean,
): NearbyPermissionDenial = when {
    granted || !requestedBefore -> NearbyPermissionDenial.NONE
    canAskAgain -> NearbyPermissionDenial.RETRYABLE
    else -> NearbyPermissionDenial.SETTINGS
}

internal fun canRetryAllMissingPermissions(missingPermissionCanAskAgain: List<Boolean>): Boolean =
    missingPermissionCanAskAgain.isNotEmpty() && missingPermissionCanAskAgain.all { it }

/**
 * The pre-connection screen: the wordmark and what the beacon is, the scan button with its
 * pre-permission rationale, the inline scan panel, and one grouped list (saved log, what the
 * beacon can hear, setup help, the shop). A first-class button opens the full app on sample
 * data. Once the link is up, the four-tab MainScreen takes over, and the FIRST ready real
 * session opens the setup checklist over it (ChecklistSheet).
 *
 * [locationRequestOutstanding] is MainActivity's "the system Location dialog is up" fact, so the
 * Live rationale waits for its result. [initialBeaconSegment] seeds the Beacon tab's segment (the
 * store-screenshot intent extra); its type is internal, so this function is too.
 */
@Composable
internal fun AcabApp(
    ble: AcabBleManager,
    permissionsGranted: Boolean,
    locationGranted: Boolean,
    notificationsAvailable: Boolean,
    nearbyPermissionDenial: NearbyPermissionDenial,
    liveNotificationDenied: Boolean,
    locationRequestOutstanding: Boolean,
    onRequestPermissions: () -> Unit,
    onRequestLocation: () -> Unit,
    onStartDefaultLiveMode: (requestNotification: Boolean) -> Unit,
    onLiveNotificationDenialHandled: () -> Unit,
    initialBeaconSegment: BeaconSegment = BeaconSegment.BOARD,
) {
    val state by ble.state.collectAsState()
    val found by ble.found.collectAsState()
    // The remembered board (AcabBleManager.refreshRememberedBoard) merged into the scan results:
    // one row per board, and the owner's board listed even when it sent no advert. Memoized on
    // its two inputs, so recomposition does no work and no prefs read happens here.
    val rememberedRow by ble.rememberedRow.collectAsState()
    val boardRows = remember(found, rememberedRow) { pickerRows(found, rememberedRow) }
    // Lookup time for the remembered row: cold start, every connection-state edge (a failed or
    // ended connect lands back here), and a permission grant. The manager also looks it up on
    // startScan and on app foreground; this adds no connection behavior, it only re-reads bonds.
    LaunchedEffect(state, permissionsGranted) { ble.refreshRememberedBoard() }
    val connectHint by ble.connectHint.collectAsState()
    val scanHint by ble.scanHint.collectAsState()
    // WHICH BOARD THE COPY NAMES (BoardKind; null reads as beacon). Both flows change at most a few
    // times a session, and the status is mapped to its fw label before collecting, so a status
    // frame that changes nothing else does not recompose this root.
    val rememberedKind by ble.rememberedKind.collectAsState()
    val targetKind by ble.targetKind.collectAsState()
    val fwLabelSeed = remember(ble) { ble.status.value?.firmwareLabel }
    val fwLabel by remember(ble) {
        ble.status.map { it?.firmwareLabel }.distinctUntilChanged()
    }.collectAsState(initial = fwLabelSeed)
    // The connected board, for the Live Mode dialog on the first READY.
    val connectedKind = connectedBoardKind(fwLabel, targetKind)
    val ota by ble.otaProgress.collectAsState()
    // Only the saved log's SIZE is read here (the saved-log row's gate and title), so only a size
    // change recomposes this root: collecting the whole list would recompose it at the feed rate.
    // The seed reads .value inside remember, the lint-safe form.
    val savedLogCountSeed = remember(ble) { ble.logDetections.value.size }
    val savedLogCount by remember(ble) {
        ble.logDetections.map { it.size }.distinctUntilChanged()
    }.collectAsState(initial = savedLogCountSeed)
    val demoMode by ble.demoMode.collectAsState()
    val liveMode by ble.driveMode.collectAsState()
    val liveModeWanted by ble.driveModeWanted.collectAsState()
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current

    // Once the app shell has existed, keep that single composition alive for the rest of this
    // activity. A transient reconnect must not destroy an in-progress contribution capture,
    // map camera, log pause snapshot, or dossier. Opaque connect/OTA surfaces can cover it, but
    // the parked shell is both pointer-disabled and hidden from accessibility while covered.
    var shellEstablished by rememberSaveable { mutableStateOf(state == ConnState.READY) }
    LaunchedEffect(state) {
        if (state == ConnState.READY) shellEstablished = true
    }

    // AcabBleManager keeps its auto-reconnect flag internal, but the transition is visible from
    // here: a user connect enters CONNECTING from SCANNING/DISCONNECTED, while the unexpected-drop
    // auto-reconnect is the only path that arrives at CONNECTING straight from READY (the OTA
    // reboot-reconnect does too, but OtaWaitScreen owns that state below). Tracked above the
    // early returns so the READY hand-off doesn't reset it.
    var hadLink by rememberSaveable { mutableStateOf(state == ConnState.READY) }
    LaunchedEffect(state) {
        when (state) {
            ConnState.READY -> hadLink = true
            ConnState.CONNECTING -> Unit    // hold: this is the reconnect window itself
            else -> hadLink = false         // any other state ends the session for good
        }
    }

    // Read-only path into the persisted log, no board needed (mirrors the iOS savedLogCard sheet).
    var showSavedLog by remember { mutableStateOf(false) }

    // The 45s scan window (AcabBleManager.SCAN_TIMEOUT_MS) ending with nothing found used to
    // fall silently back to the resting panel: the spinner just vanished, which reads as a hang
    // or a shrug. Track the SCANNING -> DISCONNECTED edge, distinguish the user's own stop-tap
    // (no message: they asked) from the timeout (message + Scan Again), and clear on re-scan.
    var userStoppedScan by remember { mutableStateOf(false) }
    var scanEndedEmpty by remember { mutableStateOf(false) }
    var prevConnState by remember { mutableStateOf(state) }
    LaunchedEffect(state, scanHint) {
        if (state == ConnState.SCANNING || scanHint != null) scanEndedEmpty = false
        if (prevConnState == ConnState.SCANNING && state == ConnState.DISCONNECTED &&
            found.isEmpty() && !userStoppedScan && scanHint == null) {
            scanEndedEmpty = true
        }
        if (state != ConnState.SCANNING) userStoppedScan = false
        prevConnState = state
    }

    val otaActive = ota.phase != OtaPhase.IDLE && ota.phase != OtaPhase.DONE && ota.phase != OtaPhase.FAILED
    val reconnectUsable = shouldUseReconnectShell(shellEstablished, hadLink, state, otaActive)

    // THE TWO HOMES THE RESTORE OFFER WAS MISSING. Every other surface that carries it lives on the
    // Beacon tab, and while either of the two screens below draws, MainScreen is either not
    // composed at all or parked pointer-disabled with its semantics cleared, so the Beacon tab is
    // not reachable: the board ended Desert, the owner came back with the board off or gone, and
    // alerts stayed silent with nothing on screen and no way out of it.
    //
    // Decided HERE, above the early returns, because this is the one place composed in both states,
    // so `mainShellVisible` is a real input and not a constant. It is the negation of the hand-off
    // below, so this copy and the Beacon tab's detached copy can never draw together.
    //
    // ONE FLAG, TWO SCREENS, because the shell is just as unreachable during an OTA reboot: the
    // OtaWaitScreen return below is above the pre-connect list, and shouldUseReconnectShell is
    // false while otaActive, so that window used to compute this true and draw nothing. Each of
    // the two reads the flag on its own side of that early return, so they can never both draw.
    // iOS twin: connectScreenCarriesRestore in RootView.swift, which needs one screen only because
    // RootView keeps the tab shell up through the reboot.
    val pendingAlertRestore by ble.pendingAlertModeRestore.collectAsState()
    val preConnectRestoreOffer = desertRestoreNeedsPreConnectSurface(
        restoreOffered = alertRestoreIsOffered(demoMode, pendingAlertRestore),
        mainShellVisible = state == ConnState.READY || reconnectUsable,
    )
    // The checklist's seen flag (first_run_tour_seen, FirstRunTour). Hoisted so the shell can be
    // removed from the semantics tree while the checklist is up. Sample data gets its own
    // non-persisting orientation and never opens or completes the checklist.
    var tourDone by rememberSaveable { mutableStateOf(FirstRunTour.hasSeen(context)) }
    // Derive directly from the authoritative link state. shellEstablished flips in a
    // LaunchedEffect, which is one frame too late to prevent the Live-start effect from winning.
    val checklistOpen = shouldOpenChecklist(state = state, demoMode = demoMode, seen = tourDone)
    // The checklist's Continue: set as the sheet finishes hiding, read and cleared by its
    // onDismiss in the same call (contracts 9.1, "Android prompt order").
    var requestLocationPending by rememberSaveable { mutableStateOf(false) }
    // The checklist chevrons' bridges into Beacon > Notifications and Beacon > Live Mode. The sheet
    // lives outside the tab shell, so AcabApp owns them and MainScreen turns a bump into a tab
    // switch and a pushed page.
    var openNotifyToken by rememberSaveable { mutableIntStateOf(0) }
    var openLiveModeToken by rememberSaveable { mutableIntStateOf(0) }
    val completeChecklist: () -> Unit = {
        FirstRunTour.markChecklistComplete(context)
        tourDone = true
    }
    var sampleTourHandled by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(demoMode) {
        if (!demoMode) sampleTourHandled = false
    }
    val sampleTourOpen = state == ConnState.READY && demoMode && !sampleTourHandled

    // Help must remain reachable before a beacon connects, which is when setup questions happen.
    var preConnectHelpOpen by rememberSaveable { mutableStateOf(false) }

    // Live Mode defaults on, but Android 13+ needs a notification permission before its glanceable
    // surface can appear. Explain that request only after the setup checklist has completed and
    // any Location request it made has come back (shouldAttemptDefaultLive). The explanation is
    // persisted independently from the checklist: denying the OS prompt must not cause a nag on
    // every reconnect; Beacon readiness shows the recovery instead.
    val livePromptPrefs = remember { context.getSharedPreferences("acab_ui", Context.MODE_PRIVATE) }
    var livePermissionExplained by remember {
        mutableStateOf(livePromptPrefs.getBoolean(KEY_LIVE_PERMISSION_EXPLAINED, false))
    }
    var showLivePermissionPrompt by rememberSaveable { mutableStateOf(false) }
    // Scrim, Back, and Not Now defer both the rationale and automatic start for this Activity
    // session. Saveable keeps that promise across rotation and reconnects without persisting Off.
    var livePromptDeferred by rememberSaveable { mutableStateOf(false) }
    // Session-only: activity recreation while Android owns the permission dialog must retry the
    // start after the result is delivered, rather than restoring a stale "attempted" latch.
    var liveStartAttempted by remember { mutableStateOf(false) }
    LaunchedEffect(state, demoMode, tourDone, livePromptDeferred, liveModeWanted, liveMode,
        notificationsAvailable, livePermissionExplained, requestLocationPending,
        locationRequestOutstanding) {
        if (state != ConnState.READY || demoMode) {
            liveStartAttempted = false
            showLivePermissionPrompt = false
            return@LaunchedEffect
        }
        if (shouldAttemptDefaultLive(
                state = state,
                demoMode = demoMode,
                tourSeen = tourDone,
                promptDeferred = livePromptDeferred,
                wanted = liveModeWanted,
                active = liveMode,
                attempted = liveStartAttempted,
                locationPromptPending = requestLocationPending || locationRequestOutstanding,
            )) {
            liveStartAttempted = true
            // Asked here, when the effect runs, not in composition: it is a permission check.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !DetectionNotifier.hasPostPermission(context) && !livePermissionExplained) {
                showLivePermissionPrompt = true
            } else {
                onStartDefaultLiveMode(false)
            }
        }
    }
    val shellCovered = shellEstablished &&
        ((state != ConnState.READY && !reconnectUsable) || checklistOpen || sampleTourOpen)

    Box(Modifier.fillMaxSize()) {
    if (shellEstablished) {
        // Remembered on the flag, so a covered MainScreen is not handed a new Modifier on every
        // recomposition of this root.
        val shellModifier = remember(shellCovered) { if (shellCovered) {
            Modifier
                .clearAndSetSemantics { }
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                        }
                    }
                }
        } else Modifier }
        MainScreen(
            ble = ble,
            reconnecting = reconnectUsable,
            locationGranted = locationGranted,
            onRequestLocation = onRequestLocation,
            modifier = shellModifier,
            openNotifyToken = openNotifyToken,
            openLiveModeToken = openLiveModeToken,
            initialBeaconSegment = initialBeaconSegment,
        )
    }

    // Once linked, hand off to the four-tab shell, but the FIRST time a real board connects, open
    // the setup checklist over it: the "I'm connected, now what?" moment. Sample data is excluded
    // (shouldOpenChecklist): it would spend the one-time checklist on a fake board, so it gets the
    // sample tour instead (mirrors iOS RootView).
    if (state == ConnState.READY) {
        if (checklistOpen) {
            ChecklistSheet(
                ble = ble,
                replay = false,
                locationGranted = locationGranted,
                notificationsAvailable = notificationsAvailable,
                // Binding order (contracts 9.1): complete, then request (MainActivity raises
                // locationRequestOutstanding synchronously), then clear the intent, so the Live
                // effect never sees both flags false while the system dialog is due. The link
                // state is the flow's own current value, which the collected state can trail.
                onDismiss = {
                    completeChecklist()
                    if (shouldRequestOnboardingLocation(
                            continueChosen = requestLocationPending,
                            isSessionReady = ble.state.value == ConnState.READY,
                            sheetWasPresented = true,
                            isDemoMode = demoMode,
                        )) onRequestLocation()
                    requestLocationPending = false
                },
                onContinueLocation = { requestLocationPending = true },
                // A chevron completes the checklist first, then navigates.
                onOpenNotifications = { completeChecklist(); openNotifyToken++ },
                onOpenLiveMode = { completeChecklist(); openLiveModeToken++ },
            )
        } else if (sampleTourOpen) {
            FirstRunTourOverlay(
                onBack = { sampleTourHandled = true },
                onFinish = { sampleTourHandled = true },
            )
        }
        if (showLivePermissionPrompt) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = {
                    showLivePermissionPrompt = false
                    livePromptDeferred = true
                    // Back/scrim is a defer, not an explicit settings change. Persisting Off here
                    // made an accidental outside tap defeat the fresh-install default forever.
                },
                title = { Text("Keep Live Mode at a glance?") },
                text = { Text(renderBoardCopy(LIVE_PERMISSION_BODY_TEMPLATE, connectedKind)) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            livePromptPrefs.edit().putBoolean(KEY_LIVE_PERMISSION_EXPLAINED, true).apply()
                            livePermissionExplained = true
                            showLivePermissionPrompt = false
                            onStartDefaultLiveMode(true)
                        },
                    ) {
                        Text("Continue")
                    }
                },
                dismissButton = {
                    TextButton(
                        onClick = {
                            showLivePermissionPrompt = false
                            livePromptDeferred = true
                            // "Not Now" defers the one-time prompt for this session; the dedicated
                            // Live Mode toggle remains the only control that persists Off.
                        },
                    ) {
                        Text("Not Now")
                    }
                },
            )
        }
        if (liveNotificationDenied && !checklistOpen && !showLivePermissionPrompt) {
            LiveNotificationBlockedBanner(
                onDismiss = onLiveNotificationDenialHandled,
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }
        return@Box
    }

    // An OTA reboot drops the link to non-READY while the update is still in flight. Show a locked
    // "updating" screen instead of the interactive scan/connect UI, so the user can't fire a second
    // connect that would collide with the post-reboot reconnect loop.
    //
    // IT CARRIES THE RESTORE OFFER TOO, from the same flag the pre-connect list below reads. This
    // return is ABOVE that list, and shouldUseReconnectShell withholds the reconnect shell while an
    // update runs, so a state that reaches here computes preConnectRestoreOffer true whenever a
    // mode is owed, with nothing else on screen to draw it: the parked MainScreen sits under this
    // opaque screen with its pointer events consumed and its semantics cleared, so its own copy is
    // neither visible, tappable, nor readable. This screen's own copy puts that window at up to a
    // minute, which is a long time to hold a silence the app imposed with no way out of it. A
    // combined update reaches this screen in its S3 leg only: the nRF leg runs FIRST (the
    // beginFirstLeg comment in CombinedUpdateCoordinator says why) and leaves the S3 engine idle,
    // so otaActive is false there, and that leg keeps whichever ordinary surface its link state
    // selects. iOS needs no equivalent: RootView's mainIsUsable keeps the tab shell up through the
    // reboot (isRebootingForUpdate), so the Beacon screen's own detached panel carries it there.
    //
    // EXCLUSIVE WITH THE LIST BY CONSTRUCTION: the two homes sit on opposite sides of this one
    // early return, so exactly one of them draws for any state.
    if (otaActive) {
        OtaWaitScreen(ota, showAlertRestore = preConnectRestoreOffer, ble = ble)
        return@Box
    }

    // Unexpected reconnects leave the established shell fully usable. MainScreen owns the
    // compact status banner; no opaque connect surface is placed over it.
    if (reconnectUsable) {
        return@Box
    }

    if (showSavedLog) {
        SavedLogScreen(
            ble = ble,
            locationGranted = locationGranted,
            onRequestLocation = onRequestLocation,
            onClose = { showSavedLog = false },
        )
        return@Box
    }

    if (preConnectHelpOpen) {
        PreConnectHelpScreen(onClose = { preConnectHelpOpen = false })
        return@Box
    }

    val seeHowItWorks: () -> Unit = { ble.seedDemoData() }
    // THE CONNECT ORDER is fixed by contracts 9.5 ("settles 2m"): the hero (the wordmark and the
    // tagline), the restore offer, the per-state panel (in the idle arm the setup line, the scan
    // button, See How It Works and, only before Nearby devices is granted, the one-line
    // rationale), the inline scan panel (the pair-window line rests under the hint of a failed
    // connect a second phone can cause, ConnectionHintPanel), then one grouped list (saved log, what your beacon can hear, setup +
    // pairing help, get a beacon), then the footnote, the screen's one passive statement (the
    // owner's middle-ground pick, 2026-09-25: the passive idea is said once). iOS ConnectView
    // draws the same sections in the same order (in the states with no scan panel both apps draw
    // the sample button below that state's panel), with one recorded difference: while a connect is in
    // flight (CONNECTING or BONDING, the `linking` gate below, a reconnect included) this list
    // hides "See How It Works", "View saved log (N)" and "Get a beacon", where iOS keeps all three
    // through `.connecting` (TWIN: the PLATFORM DIFFERENCE note on iOS ConnectView.setupIntro).
    // ONE scrolling list, so nothing is pinned outside the scroll at large text.
    //
    // THE BOARD THIS LIST NAMES (resolveScreenKind): the target while a connect, pairing or reconnect
    // runs or its failure shows, else the remembered board, else the one kind every listed row
    // agrees on, else beacon. The rows themselves name their own board (pickerRowKind). The scan
    // button, "Get a beacon", the wordmark and the tagline stay beacon on purpose: they name the
    // product line.
    val rowKinds = remember(boardRows, rememberedKind) {
        boardRows.map { pickerRowKind(it.owned, it.kindHint, rememberedKind) }
    }
    // The remembered board's kind: the live advert hint of its listed row, else the stored kind
    // (pickerRowKind, the same rule as its row title; iOS BLEManager.rememberedKind).
    val screenRememberedKind = pickerRowKind(
        owned = true, kindHint = boardRows.firstOrNull { it.owned }?.kindHint, rememberedKind = rememberedKind)
    val targetActive = state == ConnState.CONNECTING || state == ConnState.BONDING ||
        (connectHint != null && state != ConnState.SCANNING)
    val screenKind = resolveScreenKind(targetActive, targetKind, screenRememberedKind, rowKinds)
    CompositionLocalProvider(LocalAlertRestoreKind provides screenKind) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        LazyColumn(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item { ConnectHero() }
            // A SILENCE THIS APP IMPOSED LEADS EVERY PANEL ON THIS SCREEN, directly under the
            // hero and above the scan panel: this is the only reachable copy of the offer right
            // now, and the state that arms it (a board reboot, a factory reset) is exactly the
            // state that lands the owner here. Nothing about taking it needs a board - the alert
            // mode is a phone preference. The board write it also makes is dropped while there
            // is no link (the config enqueue bails with no gatt); the next connect re-sends the
            // wanted mode, and reconcileBuzzer re-asserts it from the first status frame if the
            // board still disagrees. That is the same path as any other mode picked while
            // offline. Same panel, same strings and the same take as the Beacon tab's copy, from
            // the one AlertRestorePanel definition.
            if (preConnectRestoreOffer) item { AlertRestorePanel(ble) }
            when (state) {
                ConnState.CONNECTING ->
                    if (hadLink) item { ReconnectingPanel(kind = targetKind, onStop = { ble.stopConnectionAndScan() }) }
                    else item {
                        ConnectingRow(
                            text = "Connecting…",
                            guidance = renderBoardCopy(CONNECTING_BODY_TEMPLATE, targetKind),
                            onCancel = { ble.stopConnectionAndScan() },
                        )
                    }
                ConnState.BONDING -> item {
                    ConnectingRow(
                        text = "Pairing…",
                        guidance = renderBoardCopy(CONNECTING_BODY_TEMPLATE, targetKind),
                        onCancel = { ble.stopConnectionAndScan() },
                    )
                }
                // Each blocked state keeps the sample path, as the old demo card did: a user with
                // Bluetooth off or the permission denied can still see how the app works.
                ConnState.POWERED_OFF -> {
                    item {
                        RadioOffPanel(kind = screenKind, onOpenBluetoothSettings = {
                            runCatching {
                                context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                            }.onFailure {
                                context.startActivity(Intent(Settings.ACTION_SETTINGS))
                            }
                        })
                    }
                    item { SeeHowItWorksButton(onClick = seeHowItWorks) }
                }
                else -> {
                    when {
                        !permissionsGranted && nearbyPermissionDenial == NearbyPermissionDenial.SETTINGS -> {
                            item {
                                PermissionDeniedPanel(kind = screenKind, onOpenSettings = {
                                    context.startActivity(
                                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null))
                                    )
                                })
                            }
                            item { SeeHowItWorksButton(onClick = seeHowItWorks) }
                        }
                        !permissionsGranted && nearbyPermissionDenial == NearbyPermissionDenial.RETRYABLE -> {
                            item { PermissionRetryPanel(kind = screenKind, onTryAgain = onRequestPermissions) }
                            item { SeeHowItWorksButton(onClick = seeHowItWorks) }
                        }
                        else -> {
                        item {
                            ScanCtaPanel(
                                kind = screenKind,
                                permissionsGranted = permissionsGranted,
                                scanning = state == ConnState.SCANNING,
                                onAllowScan = {
                                    when {
                                        !permissionsGranted -> onRequestPermissions()
                                        // The CTA is an explicit stop/start toggle while a scan runs.
                                        // userStoppedScan: a deliberate stop must not raise
                                        // the none-found timeout message (NoBoardsFoundPanel).
                                        state == ConnState.SCANNING -> {
                                            userStoppedScan = true; ble.stopScan()
                                        }
                                        else -> ble.startScan()
                                    }
                                },
                                onSeeHowItWorks = seeHowItWorks,
                            )
                        }
                        if (found.isEmpty() && state == ConnState.SCANNING) {
                            item {
                                Text(
                                    renderBoardCopy(CONNECT_LOOKING_TEMPLATE, screenKind),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.semantics {
                                        liveRegion = LiveRegionMode.Polite
                                    },
                                )
                            }
                        }
                        if (state != ConnState.SCANNING) {
                            scanHint?.let { hint ->
                                item { ScanFailurePanel(hint = hint, onRetry = { ble.startScan() }) }
                            }
                        }
                        // The scan window closed with nothing heard: say so and offer the
                        // retry, instead of the spinner silently becoming a resting button.
                        if (scanHint == null && scanEndedEmpty && state != ConnState.SCANNING && found.isEmpty()) {
                            item { NoBoardsFoundPanel(kind = screenKind, onScanAgain = { ble.startScan() }) }
                        }
                        if (state != ConnState.SCANNING) {
                            connectHint?.let { hint ->
                                item {
                                    // screenKind names the failed target while this panel shows
                                    // (targetActive counts a showing failure as an active target).
                                    ConnectionHintPanel(hint = hint, kind = screenKind, onRetry = { ble.startScan() })
                                }
                            }
                        }
                        // What a tap on a heard board leads to, above the rows it explains.
                        if (found.isNotEmpty()) item { SecurePairingNote(screenKind) }
                        items(boardRows, key = { it.device.address }) { board ->
                            BoardRow(board, rememberedKind, onConnect = { ble.connect(board) })
                        }
                        }
                    }
                }
            }

            val linking = state == ConnState.CONNECTING || state == ConnState.BONDING
            item {
                ConnectRows(
                    kind = screenKind,
                    // The history on this phone stays reachable with no board and no Bluetooth: a
                    // log that may be evidence must never be locked behind hardware that died or a
                    // permission that was denied (mirrors iOS savedLogCard). Never in sample data,
                    // so the sample store can never be exported from here.
                    showSavedLog = !linking && !demoMode && savedLogCount > 0,
                    savedLogCount = savedLogCount,
                    showGetBeacon = !linking,
                    onOpenSavedLog = { showSavedLog = true },
                    onOpenHelp = { preConnectHelpOpen = true },
                    onGetBeacon = { uriHandler.openUri("https://soyboi.tech") },
                )
            }
            item { ScopeFootnote(screenKind) }
        }
    }
    }
    }
}

/** The connect screen's hero: the lowercase wordmark ([ConnectWordmark]) and the tagline under
 *  it, in the kicker's ink and, as an uppercase label, the kicker's instrument face (Kicker). The
 *  tagline names the product line, so it never takes a kind; it is spoken as words, not letter by
 *  letter. The passive statement is said ONCE on this screen, in ScopeFootnote, so the hero
 *  carries no sentence of its own, as the pre-redesign screen had it.
 *
 *  The tagline is brand ornament, not instructions, so its text size stops at
 *  CONNECT_TAGLINE_MAX_FONT_SCALE, the Android side of the accessibility2 cap iOS puts on it. It
 *  still scales up to that cap (Kicker's pin, which holds it at 1.0, is for an ornament beside a
 *  number, which this is not); the wordmark, the setup line, the buttons and the list keep the
 *  full range. TWIN: iOS ConnectView.hero. */
@Composable
private fun ConnectHero() {
    Column(
        Modifier.fillMaxWidth().padding(top = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ConnectWordmark()
        val density = LocalDensity.current
        val taglineDensity = if (density.fontScale > CONNECT_TAGLINE_MAX_FONT_SCALE) {
            Density(density.density, CONNECT_TAGLINE_MAX_FONT_SCALE)
        } else {
            density
        }
        CompositionLocalProvider(LocalDensity provides taglineDensity) {
            Box(Modifier.clearAndSetSemantics { contentDescription = "all cameras are beacons" }) {
                Kicker("ALL CAMERAS ARE BEACONS",
                    style = MaterialTheme.typography.bodySmall.copy(textAlign = TextAlign.Center))
            }
        }
    }
}

/** The wordmark as drawn: the literal the measure and the Text share. */
private const val WORDMARK = "beacons"

/** The wordmark's style: Space Grotesk Bold at 40sp, the pre-redesign wordmark (its WordmarkHero
 *  drew Acab.display, then Space Grotesk, Bold at 40sp). No line height of its own, as before: the
 *  face's own. Built once. */
private val WordmarkStyle = TextStyle(fontFamily = WordmarkFace, fontWeight = FontWeight.Bold, fontSize = 40.sp)

/** The smallest share of the wordmark's size [wordmarkFit] shrinks it to: iOS ACABWordmark's
 *  minimumScaleFactor(0.4). Below it the word clips at the edge rather than shrinking further. */
internal const val WORDMARK_MIN_FIT = 0.4f

/** Pure: the share of its full size the wordmark draws at, so its one line fits [availablePx].
 *  1 when it already fits (or nothing was measured yet), else the width ratio, never below
 *  [WORDMARK_MIN_FIT]. Glyph advances scale linearly with the size, so the ratio lands the line
 *  on the width to within hinting. */
internal fun wordmarkFit(availablePx: Int, fullWidthPx: Int): Float =
    if (fullWidthPx <= 0 || fullWidthPx <= availablePx) 1f
    else maxOf(WORDMARK_MIN_FIT, availablePx.toFloat() / fullWidthPx)

/** The lowercase "beacons" wordmark in Space Grotesk Bold, back by the owner's call of 2026-09-26
 *  (R16). It scales with the font scale (sp) and stays on ONE line, shrinking to fit instead of
 *  wrapping inside the word: the wordmark is the brand, and "beac" over "ons" is worse than
 *  smaller type. The fit is measured, not estimated: the one-line width at the full size against
 *  the width the hero gives it ([wordmarkFit]); the shrunk size is taken in px and converted back
 *  through the density, because Android 14 scales large text nonlinearly and sp x ratio would
 *  miss. A heading, spoken as the word. TWIN: iOS ACABWordmark in Views/Components.swift (one
 *  line, minimumScaleFactor 0.4). No parameters, so it skips while the connect list recomposes
 *  around it; the measure reruns only when the density (which carries the font scale) changes. */
@Composable
private fun ConnectWordmark() {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = LocalTextStyle.current.merge(WordmarkStyle)
    val fullWidthPx = remember(measurer, style, density) {
        measurer.measure(AnnotatedString(WORDMARK), style, softWrap = false, maxLines = 1).size.width
    }
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        val fit = if (constraints.hasBoundedWidth) wordmarkFit(constraints.maxWidth, fullWidthPx) else 1f
        val drawn = if (fit >= 1f) style else with(density) {
            style.copy(fontSize = (style.fontSize.toPx() * fit).toSp())
        }
        Text(WORDMARK, style = drawn, color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1, softWrap = false, modifier = Modifier.semantics { heading() })
    }
}

/** The largest fontScale the connect hero's tagline follows (ConnectHero). Android's own
 *  derivation of iOS's accessibility2 cap, not a copy of an iOS number: iOS draws the tagline as
 *  a footnote, 13 pt at the default size and 27 pt at accessibility2, about 2.1 times; Android
 *  draws it in bodySmall (12 sp), which reaches 24 dp, 2.0 times, at fontScale 2.0
 *  (FontScaleConverterFactory's 2.0 table), the largest step stock Android's font size setting
 *  offers (200%). So on stock Android the cap never shrinks the tagline below what the settings
 *  screen can ask for; it holds it there when an OEM setting or an adb font_scale goes further.
 *  At or under the cap the tagline gets the screen's own density untouched. */
private const val CONNECT_TAGLINE_MAX_FONT_SCALE = 2f

/** The six signatures the beacon listens for, in the order the panel draws them. File-level so
 *  neither list is rebuilt per composition and the tile helper's remember key stays stable. */
private val HEARS = listOf(
    DeviceType.FLOCK_CAMERA to "ALPR",
    DeviceType.DRONE to "DRONES",
    DeviceType.BODY_CAM to "BODY CAMS",
    DeviceType.TRACKER to "TRACKERS",
    DeviceType.GLASSES to "GLASSES",
    DeviceType.NETWORK_CAMERA to "NET CAM",
)
private val HEARS_LABELS = HEARS.map { it.second }

/** What the beacon can hear, drawn inside the connect list under its disclosure row. The
 *  disclosure row above is the panel's title, so the panel draws no header of its own. TWIN: iOS
 *  ConnectView.beaconHearsPanel, which also opens in place under its row now (its hears sheet is
 *  gone), and draws six tiles across where this draws three (a recorded difference). Three
 *  tiles per row while the widest label fits a third of the width on one line, otherwise two
 *  (rememberCategoryTilesPerRow measures the label in the style it is drawn in), so no label ever
 *  breaks inside a word. Six labels divide evenly by both, so no row needs a filler. */
@Composable
private fun BeaconHearsPanel() {
    Column(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val perRow = rememberCategoryTilesPerRow(HEARS_LABELS, maxWidth, preferred = 3)
            Column(verticalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                HEARS.chunked(perRow).forEach { group ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                        group.forEach { (type, label) ->
                            Column(
                                Modifier.weight(1f).minimumInteractiveComponentSize().clearAndSetSemantics {
                                    contentDescription = when (type) {
                                        DeviceType.TRACKER -> "Bluetooth tracker detector, optional"
                                        DeviceType.NETWORK_CAMERA -> "Network camera detector, optional"
                                        else -> "${type.label} detector"
                                    }
                                },
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                CatGlyph(type)
                                Text(label, style = CategoryTileLabelStyle,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    textAlign = TextAlign.Center)
                            }
                        }
                    }
                }
            }
        }
        Text(CONNECT_OPT_IN_SENTENCE, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The idle arm's fork: the one setup line, the scan button, See How It Works, then (only before
 *  the system has asked) the one-line permission rationale. TWIN: iOS ConnectView.setupIntro. */
@Composable
private fun ScanCtaPanel(
    kind: BoardKind?,
    permissionsGranted: Boolean,
    scanning: Boolean,
    onAllowScan: () -> Unit,
    onSeeHowItWorks: () -> Unit,
) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            renderBoardCopy(CONNECT_SETUP_TEMPLATE, kind),
            modifier = Modifier.fillMaxWidth(),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Button(onClick = onAllowScan, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
            Text(scanButtonTitle(isScanning = scanning, granted = permissionsGranted),
                style = MaterialTheme.typography.titleMedium)
        }
        SeeHowItWorksButton(onClick = onSeeHowItWorks)
        // Before the system has asked, one line says what the dialog that "Continue" opens is
        // for. Once the permission is granted it has nothing left to explain. The "already paired
        // to another phone?" line no longer rests here: it is in Setup + pairing help (q-setup,
        // q-pair-window) and under a failed connect (ConnectionHintPanel), where it applies.
        if (!permissionsGranted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                RationaleRow(
                    Icons.Filled.Bluetooth,
                    "Nearby devices",
                    renderBoardCopy(CONNECT_RATIONALE_REST_TEMPLATE, kind),
                )
            } else {
                RationaleRow(Icons.Filled.LocationOn, "Location",
                    "is required by this Android version to scan for Bluetooth devices. it also records where your phone heard a detection. detections and location are never uploaded automatically.")
            }
        }
    }
}

/** The sample-data path: the full app on sample data, no beacon needed. The one copy of the
 *  label, drawn in the idle fork and after each blocked state's panel. */
@Composable
private fun SeeHowItWorksButton(onClick: () -> Unit) {
    FilledTonalButton(onClick = onClick, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
        Text("See How It Works", style = MaterialTheme.typography.titleMedium)
    }
}

/** The second-phone pairing note, under the hint in the connection-failure panel.
 *
 *  A board that already belongs to a phone only accepts a NEW phone in the two minutes after it
 *  powers on. That rule is invisible from the phone's side: the board hangs up before any
 *  characteristic exists to explain itself, so a user who misses the window just sees a connect that
 *  will not take. It used to rest under the two setup buttons; the owner asked for a shorter idle
 *  screen (2026-09-25), so before a failure it lives in Setup + pairing help (q-setup and
 *  q-pair-window), and after a failure a second phone can cause it is here
 *  (ConnectionHintPanel, gated by showsPairWindowNote).
 *
 *  Deliberately says "already paired to another phone", not "your beacon": on a brand new board with
 *  no bonds the rule does not apply at all (the firmware admits any phone until the board has an
 *  owner), and telling a first-time customer to power-cycle would be a made-up ritual.
 *  Mirrors iOS ConnectView.pairWindowNote (plain dim text, leading aligned, no glyph). */
@Composable
private fun PairWindowNote(kind: BoardKind?) {
    Text(
        "already paired to another phone? " + AcabBleManager.pairWindowHint(kind),
        modifier = Modifier.fillMaxWidth(),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** The secure-pairing note, drawn while the scan has heard at least one board, above the rows.
 *  Drawn exactly as iOS draws it, not as an Android extra: TWIN iOS ConnectView.securePairingNote
 *  is the same block (a lock glyph in the tint, then the line in the dim footnote ink, 8 apart,
 *  inset 4 at each side), in the same place (under the failure, none-found and looking lines,
 *  directly above the board rows) and on the same condition (the scan heard a board). */
@Composable
private fun SecurePairingNote(kind: BoardKind?) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.Top) {
        Icon(Icons.Filled.Lock, contentDescription = null,
            tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            renderBoardCopy(CONNECT_SECURE_PAIRING_NOTE_TEMPLATE, kind),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The pre-permission rationale: one helper line under the two buttons, a tinted glyph then the
 *  bold lead and its rest, in the helper-line size and inset of SecurePairingNote. TWIN: iOS
 *  ConnectView.rationaleRow. */
@Composable
private fun RationaleRow(icon: ImageVector, lead: String, rest: String) {
    val scheme = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = scheme.primary, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = scheme.onSurface, fontWeight = FontWeight.Medium)) { append(lead) }
                withStyle(SpanStyle(color = scheme.onSurfaceVariant)) { append(" $rest") }
            },
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/** The board row's signal text: tabular digits so the dBm number does not jitter per advert. */
private val BoardRssiStyle = AcabTypography.bodySmall.tabular()

/** One discovered board: cpu glyph, its kind's title (pickerRowKind; [rememberedKind] is the
 *  remembered record's stored kind), firmware version, address, signal bars, RSSI (iOS
 *  anatomy). An advert updates rssi and seenAt many times a second, so everything derived from
 *  them is remembered on the band it produces, not rebuilt per advert. */
@Composable
private fun BoardRow(board: FoundBoard, rememberedKind: BoardKind?, onConnect: () -> Unit) {
    val bars = rssiBars(board.rssi)
    val signal = remember(bars) {
        when {
            bars >= 4 -> "strong"
            bars == 3 -> "good"
            bars == 2 -> "fair"
            else -> "weak"
        }
    }
    val stableAddress = pickerAddressLine(board.device.address)
    // The row's title names its board's kind, never the raw advertised name ("ACAB" is an OUI-Spy,
    // "ACAB-mesh" a Mesh-Detect): "your OUI-Spy" for the remembered board, "OUI-Spy" for a scanned
    // one, "beacon" while the kind is unknown. TWIN: iOS ConnectView.boardTitleBlock.
    val kind = pickerRowKind(board.owned, board.kindHint, rememberedKind)
    val title = remember(board.owned, kind) {
        if (board.owned) RememberedBoardCopy.label(kind) else scannedRowTitle(kind)
    }
    // Both labels mirror iOS boardPickerRowAccessibilityLabel (ConnectView.swift): the title, the
    // signal, that it connects securely, then the firmware; a scanned row on Android adds the
    // hardware address it draws.
    val spoken = remember(title, board.owned, board.advertSeen, signal, board.firmware, stableAddress) {
        buildString {
            append(title)
            append(", ").append(if (board.advertSeen) "$signal signal" else "no live signal")
            append(", connects securely")
            board.firmware?.let { append(", firmware ").append(it) }
            if (!board.owned) stableAddress?.let { append(", hardware address ").append(it) }
        }
    }
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .background(scheme.surfaceContainer)
            .clickable(onClickLabel = "connect to $title", role = Role.Button) { onConnect() }
            .semantics(mergeDescendants = true) { contentDescription = spoken }
            .heightIn(min = 72.dp)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Memory, contentDescription = null, tint = scheme.onSurfaceVariant,
            modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title,
                    style = MaterialTheme.typography.bodyLarge, color = scheme.onSurface,
                    modifier = Modifier.weight(1f, fill = false))
                if (board.firmware != null) {
                    Spacer(Modifier.width(8.dp))
                    Text("v${board.firmware}", style = MaterialTheme.typography.labelMedium,
                        color = scheme.onSurfaceVariant)
                }
            }
            // The board's fixed address: it tells two boards of one kind apart. pickerAddressLine
            // has the rule and why no address-bit test belongs in it.
            if (stableAddress != null) {
                Text(stableAddress, style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
            }
            // The remembered board says whether an advert is live (none is ever the case once
            // Level 1 firmware stops advertising to a bonded owner). The rssi field is a
            // placeholder until an advert merges in and is never shown.
            if (board.owned) {
                Text(RememberedBoardCopy.subtitle(board.advertSeen),
                    style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
            }
        }
        if (board.advertSeen) {
            Spacer(Modifier.width(8.dp))
            SignalBars(bars)
            Spacer(Modifier.width(8.dp))
            Text("$signal · ${board.rssi} dBm", style = BoardRssiStyle, color = scheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ConnectingRow(text: String, guidance: String, onCancel: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().padding(vertical = 44.dp).semantics {
            liveRegion = LiveRegionMode.Polite
        },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
            Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
            Text(
                guidance,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            // A stuck bond/connect (a powered-off board still in the scan list, an OS pairing
            // prompt dismissed) otherwise leaves this spinner with no way out but a cold launch.
            // disconnect() tears down the pending client, including the never-linked case.
            Spacer(Modifier.height(4.dp))
            CancelConnectButton(onCancel)
        }
    }
}

/** Quiet outlined button to bail out of a stuck Connecting / Pairing spinner (iOS copy). */
@Composable
private fun CancelConnectButton(onClick: () -> Unit) {
    OutlinedButton(onClick = onClick) { Text("Stop and Scan") }
}

/** Shown while a pending auto-reconnect is armed (board unplugged / power-cycled). Says the
 *  reconnect is automatic AND gives a way out: "Stop and Scan" calls disconnect(), which cancels
 *  the pending client and settles the state back to the scan panel. Without it a board that
 *  never returns would trap the user behind a generic "Connecting…" forever (mirrors iOS). */
@Composable
private fun ReconnectingPanel(kind: BoardKind?, onStop: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 24.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
        Text(renderBoardCopy(RECONNECT_PANEL_TITLE_TEMPLATE, kind), style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface)
        Text(
            renderBoardCopy(RECONNECT_PANEL_BODY_TEMPLATE, kind),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        PrimaryButton("Stop and Scan", onStop)
    }
}

/** The permissions were denied for good ("Don't allow" twice, or the OS auto-deny), so the
 *  prompt will never show again and the CTA would be a silent no-op. iOS .unauthorized copy,
 *  plus the deep link into the app's Settings page that Android can offer. */
@Composable
private fun PermissionDeniedPanel(kind: BoardKind?, onOpenSettings: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 24.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(32.dp))
        Text(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "Nearby devices not allowed"
            else "Location not allowed",
            style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
        Text(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                renderBoardCopy(NEARBY_DENIED_SETTINGS_TEMPLATE, kind)
            else
                "Allow Location for beacons in Settings. This Android version requires it to find Bluetooth beacons.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center)
        PrimaryButton("Open Settings", onOpenSettings)
    }
}

/** A retryable first denial. This appears as soon as Android returns the result. */
@Composable
private fun PermissionRetryPanel(kind: BoardKind?, onTryAgain: () -> Unit) {
    GroupedCard {
        Column(
            Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    renderBoardCopy(NEARBY_DENIED_RETRY_TEMPLATE, kind)
                else
                    "Location was not allowed. This Android version requires it to find Bluetooth beacons. Nothing is uploaded automatically.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            PrimaryButton("Try Again", onTryAgain)
        }
    }
}

/** Shown when the bounded scan window ends with no boards heard. Names the two overwhelmingly
 *  likely causes (power, range) and offers the retry inline, so the timeout never reads as the
 *  app giving up silently. */
@Composable
private fun NoBoardsFoundPanel(kind: BoardKind?, onScanAgain: () -> Unit) {
    GroupedCard {
        Column(
            Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(renderBoardCopy(CONNECT_NONE_FOUND_TEMPLATE, kind),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            PrimaryButton("Scan Again", onScanAgain)
        }
    }
}

/** A platform scanner failure is not the same thing as an empty scan. */
@Composable
private fun ScanFailurePanel(hint: String, onRetry: () -> Unit) {
    HintPanel(title = "Bluetooth scan did not start", hint = hint, action = "Try Again", onAction = onRetry)
}

/** Actionable recovery after a connection attempt ended before the link became usable. [kind]
 *  is the screen kind, which names the failed target while this panel shows.
 *
 *  The second-phone rule (PairWindowNote) is never guessed into the hint's sentence. It shows
 *  under every hint whose stage a second phone can explain (showsPairWindowNote: a link or
 *  pairing failure), and not under a profile or post-encryption setup failure, where
 *  power-cycling for a second phone would be a made-up fix. TWIN: iOS
 *  ConnectView.connectionFailurePanel draws pairWindowNote under the same test. One Android-only
 *  guard: the fresh-connect watchdog sets the hint to the bare pairWindowHint itself
 *  (linkWatchdogConnectHint; iOS words its timeout hint differently), so the note is left out when
 *  the hint already says it. */
@Composable
private fun ConnectionHintPanel(hint: ConnectHint, kind: BoardKind?, onRetry: () -> Unit) {
    val showNote = showsPairWindowNote(hint.stage) &&
        !hint.text.contains(AcabBleManager.pairWindowHint(kind))
    HintPanel(
        title = CONNECTION_HINT_TITLE, hint = hint.text, action = "Scan Again", onAction = onRetry,
        note = if (showNote) { { PairWindowNote(kind) } } else null,
    )
}

/** The anatomy both failure panels share: a title, the manager's hint in the warn ink, an
 *  optional [note] under the hint (the connection panel's pair-window line), a retry.
 *
 *  Only the title and the hint are the live region, Assertive because the attempt the user made
 *  just failed, so TalkBack announces "<title>. <hint>" as VoiceOver does on iOS
 *  (ConnectView.connectionFailurePanel). The note and the retry sit outside it: the note is
 *  standing guidance a user reads on their own, not part of what just happened. */
@Composable
private fun HintPanel(
    title: String,
    hint: String,
    action: String,
    onAction: () -> Unit,
    note: (@Composable () -> Unit)? = null,
) {
    GroupedCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(
                Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface)
                Text(hint, style = MaterialTheme.typography.bodyMedium, color = Acab.warn)
            }
            note?.invoke()
            PrimaryButton(action, onAction)
        }
    }
}

/** Radio-off screen, shown when the phone's Bluetooth is turned off (mirrors iOS). Recovers on
 *  its own when the radio comes back, via the adapter receiver in AcabBleManager. */
@Composable
private fun RadioOffPanel(kind: BoardKind?, onOpenBluetoothSettings: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.BluetoothDisabled, contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(32.dp))
        Text("Bluetooth is off", style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface)
        Text(renderBoardCopy(CONNECT_BLUETOOTH_OFF_TEMPLATE, kind), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        PrimaryButton("Open Bluetooth Settings", onOpenBluetoothSettings)
    }
}

/** The filled M3 button with its default shape and colours. */
@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier.fillMaxWidth()) { Text(label) }
}

/** The connect screen's one grouped list, in the contracts 9.5 order: the saved log (when this
 *  phone holds one), what the beacon can hear (an inline disclosure), setup + pairing help, and
 *  the shop (not while a connect is in flight). */
@Composable
private fun ConnectRows(
    kind: BoardKind?,
    showSavedLog: Boolean,
    savedLogCount: Int,
    showGetBeacon: Boolean,
    onOpenSavedLog: () -> Unit,
    onOpenHelp: () -> Unit,
    onGetBeacon: () -> Unit,
) {
    var hearsOpen by rememberSaveable { mutableStateOf(false) }
    val chevron: @Composable () -> Unit = {
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null)
    }
    GroupedCard {
        if (showSavedLog) {
            GroupedRow(
                "View saved log ($savedLogCount)",
                supporting = { Kicker(renderBoardCopy(CONNECT_SAVED_LOG_KICKER_TEMPLATE, kind)) },
                leading = { Icon(Icons.AutoMirrored.Outlined.ListAlt, contentDescription = null) },
                trailing = chevron,
                onClick = onOpenSavedLog,
            )
        }
        GroupedRow(
            renderBoardCopy(CONNECT_HEARS_TEMPLATE, kind),
            modifier = Modifier.semantics { stateDescription = if (hearsOpen) "expanded" else "collapsed" },
            leading = { Icon(Icons.Outlined.Hearing, contentDescription = null) },
            trailing = {
                Icon(if (hearsOpen) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, contentDescription = null)
            },
            onClick = { hearsOpen = !hearsOpen },
            onClickLabel = renderBoardCopy(
                if (hearsOpen) CONNECT_HEARS_HIDE_TEMPLATE else CONNECT_HEARS_SHOW_TEMPLATE, kind),
        )
        if (hearsOpen) BeaconHearsPanel()
        GroupedRow(
            "Setup + pairing help",
            supporting = { Kicker(CONNECT_SETUP_HELP_SUBTITLE) },
            leading = { Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = null) },
            trailing = chevron,
            onClick = onOpenHelp,
            onClickLabel = "open setup and pairing help",
        )
        if (showGetBeacon) {
            GroupedRow(
                "Get a beacon",
                supporting = { Kicker("the beacon that does the listening · soyboi.tech") },
                leading = { Icon(Icons.Outlined.ShoppingBag, contentDescription = null) },
                trailing = { Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null) },
                onClick = onGetBeacon,
            )
        }
    }
}

@Composable
private fun ScopeFootnote(kind: BoardKind?) {
    Text(
        renderBoardCopy(CONNECT_SCOPE_FOOTNOTE_TEMPLATE, kind),
        modifier = Modifier.fillMaxWidth(),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
}

/** Full-screen offline Help for a user who has not connected a beacon yet. The bar title is also
 *  the pane title TalkBack announces when the overlay opens, the pattern DeviceScreen's SubScreen
 *  set. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PreConnectHelpScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Surface(
        Modifier.fillMaxSize().semantics { paneTitle = PRE_CONNECT_HELP_TITLE },
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
        ) {
            TopAppBar(
                title = { Text(PRE_CONNECT_HELP_TITLE) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "back to beacon setup")
                    }
                },
            )
            HelpScreen(
                scrollToId = "q-setup",
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        }
    }
}

/** Immediate, dismissible recovery after Android declines the Live Mode notification request. */
@Composable
private fun LiveNotificationBlockedBanner(onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing).padding(16.dp),
        contentAlignment = Alignment.TopCenter,
    ) {
        AcabBanner(
            text = "Android blocked the Live Mode lock-screen and status-bar counter. You can allow notifications later under Beacon, System readiness.",
            modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .semantics { liveRegion = LiveRegionMode.Assertive },
            icon = Icons.Filled.WarningAmber,
            iconTint = Acab.warn,
        ) {
            Text(
                "Got It",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClickLabel = "dismiss notification help", role = Role.Button, onClick = onDismiss)
                    .padding(8.dp),
            )
        }
    }
}

/** Full-screen, board-less view of the persisted log (the Log tab is normally gated behind a
 *  READY link). Everything inside is phone-local: view, mark seen, export CSV, clear; the
 *  board-config writes no-op while disconnected. Mirrors the iOS savedLogCard sheet. LogScreen
 *  finds no top-bar slot here, so it draws its own search bar and Log tools inline, under this
 *  screen's title bar. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SavedLogScreen(
    ble: AcabBleManager,
    locationGranted: Boolean,
    onRequestLocation: () -> Unit,
    onClose: () -> Unit,
) {
    var selected by remember { mutableStateOf<Detection?>(null) }
    val uriHandler = LocalUriHandler.current
    // System back peels the dossier first, then closes the saved log (not the app).
    BackHandler { if (selected != null) selected = null else onClose() }
    // The bar title is also the pane title TalkBack announces (SubScreen's pattern). While the
    // dossier covers this screen, the whole log leaves the tree, the pane title with it.
    Surface(
        modifier = Modifier.fillMaxSize().then(
            if (selected != null) Modifier.clearAndSetSemantics { }
            else Modifier.semantics { paneTitle = SAVED_LOG_TITLE }),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
        ) {
            TopAppBar(
                title = { Text(SAVED_LOG_TITLE) },
                actions = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.Filled.Close, contentDescription = "Close saved log")
                    }
                },
            )
            // The title bar above already took the status-bar inset, and a sibling's inset use
            // does not reach this subtree, so the inline search bar would pad for it again.
            Box(Modifier.fillMaxSize().consumeWindowInsets(WindowInsets.statusBars)) {
                LogScreen(ble, onSelect = { selected = it }, pauseStateKey = "saved")
            }
        }
    }
    // Dossier over the log, like MainScreen's compact overlay. "Open in Map" has no Map tab to
    // land on with no board linked, so hand the coordinate to the system maps app instead.
    selected?.let { d ->
        DetailScreen(
            detection = d,
            ble = ble,
            onBack = { selected = null },
            onOpenInMap = { lat, lon ->
                runCatching { uriHandler.openUri("geo:$lat,$lon?q=$lat,$lon") }
            },
            locationGranted = locationGranted,
            onRequestLocation = onRequestLocation,
            // It covers the whole saved log (cleared from semantics below it), so TalkBack
            // announces it as a new pane.
            overlay = true,
        )
    }
}

private const val KEY_LIVE_PERMISSION_EXPLAINED = "live_permission_explained"

/** One string each for an overlay's bar title and its pane title, so the two cannot drift. */
private const val PRE_CONNECT_HELP_TITLE = "Setup + pairing help"
private const val SAVED_LOG_TITLE = "Saved log"

/** Locked screen shown while an OTA is in flight but the link is down (the reboot/reconnect
 *  window). No scan/connect controls, so the reconnect loop can finish uninterrupted.
 *
 *  [showAlertRestore] is the ONE exception to "no controls", and it is decided by the caller
 *  (AcabApp's preConnectRestoreOffer), not here: a silence this app imposed has to stay one tap
 *  from undone for as long as it lasts, and the copy on this screen puts that window at up to a
 *  minute. Taking it needs no board (the alert mode is a phone preference), and it cannot disturb
 *  the reconnect loop: the board write it also makes is dropped while there is no link; the next
 *  connect re-sends the wanted mode, and reconcileBuzzer re-asserts it from the first status frame
 *  if the board still disagrees.
 *
 *  It LEADS, above the spinner, the same position the offer takes on the other two panel surfaces.
 *  The wait content keeps its own centred column under it, so this screen looks exactly as it did
 *  whenever nothing is owed. */
@Composable
private fun OtaWaitScreen(ota: OtaProgress, showAlertRestore: Boolean, ble: AcabBleManager) {
    // The board being updated. The link is down for the reboot, so no frame names it; the connect
    // target's kind does (AcabBleManager.targetKind holds the session's fw kind through the drop).
    val kind by ble.targetKind.collectAsState()
    CompositionLocalProvider(LocalAlertRestoreKind provides kind) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (showAlertRestore) {
                AlertRestorePanel(ble)
                Spacer(Modifier.height(28.dp))
            }
            Column(
                Modifier.fillMaxWidth().weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator()
                Spacer(Modifier.height(20.dp))
                Text("Updating firmware", style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.height(8.dp))
                Text(
                    ota.message.ifBlank { renderBoardCopy(OTA_WAIT_REBOOTING_TEMPLATE, kind) },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp),
                )
                Spacer(Modifier.height(6.dp))
                Text(renderBoardCopy(OTA_WAIT_NOTE_TEMPLATE, kind),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center)
            }
        }
    }
    }
}
