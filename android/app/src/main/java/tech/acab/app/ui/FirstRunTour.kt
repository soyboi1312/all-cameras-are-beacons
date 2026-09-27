package tech.acab.app.ui

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.ToggleOn
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.LocationOn
import androidx.compose.material.icons.outlined.LockClock
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.connectedBoardKind
import tech.acab.app.ble.renderBoardCopy
import tech.acab.app.model.DeviceStatus
import tech.acab.app.ui.theme.Acab

/*
 * First run after a connection: the post-connect setup checklist (C14; ChecklistSheet), its
 * persistence (object FirstRunTour) and copy, and the session-only sample-data tour
 * (FirstRunTourOverlay).
 *
 * WHY THE CHECKLIST EXISTS: AcabApp hands off to MainScreen the instant state == READY, and that
 * "I'm connected, now what?" moment used to have no guidance at all. The checklist answers it once:
 * what is already true (paired, detectors on), what is optional (Location, phone notifications,
 * Live Mode, the offline buffer), and what quiet means.
 *
 * The sample tour's three cards mirror iOS FirstRunTourView's sampleCards word for word. Nothing
 * enforces that, so a wording change made on one side alone drifts silently: edit both files in
 * the same change.
 */
private data class TourCard(
    val icon: ImageVector,
    val title: String,
    val body: String,
    val note: String,
)

/** Session-only orientation for sample data. It deliberately has no persistence key: leaving
 * sample data resets it, and a sample session never opens or completes the real-board checklist
 * (shouldOpenChecklist excludes demo). */
private val SAMPLE_TOUR_CARDS = listOf(
    TourCard(
        Icons.Filled.SettingsInputAntenna,
        "this is sample data",
        "six fictional nearby devices fill the app so you can try every screen without a beacon. nothing here came from your surroundings.",
        "sample settings are safe to explore. they do not configure hardware or replace the setup checklist shown when your real beacon connects.",
    ),
    TourCard(
        Icons.AutoMirrored.Filled.ListAlt,
        "follow a sample hit",
        "tap a category on Status to open its filtered Log, tap a row for the full details, and use Map to see where your phone heard each example.",
        "the examples cover ALPR, a drone, body camera, tracker, recording glasses, and a network camera.",
    ),
    TourCard(
        Icons.Filled.Tune,
        "leave whenever you are ready",
        "an Exit Sample Data banner stays at the top of the app, so you can return to beacon scanning from any tab.",
        "your real saved Log is restored after you exit. sample detections are never added to it.",
    ),
)

/** The tour overlay's pane title, announced by TalkBack when the full-screen tour opens and
 *  closes (the pattern the Help, saved-log and dossier overlays set); lowercase-first like every
 *  spoken name that is not a button. Pinned in SampleTourChromeTest. */
internal const val SAMPLE_TOUR_PANE_TITLE = "sample data tour"

/** The mono kicker at the leading edge of the Skip row, naming the tour on screen. TWIN: iOS
 *  FirstRunTourView's "SAMPLE DATA TOUR" kicker beside Skip, byte-identical. */
internal const val SAMPLE_TOUR_KICKER = "SAMPLE DATA TOUR"

/** The sample-data tour: three cards shown once per sample session (AcabApp's sampleTourHandled).
 *  Its content and layout are not part of the redesign (L5): its colors change through its Acab.*
 *  reads, which resolve through the foundation's aliases to the current palette, and its text
 *  sizes moved to the M3 type scale for the owner's R8 report (card body and note, skip and next
 *  labels; the step counter text left with P3-12, the dots speak it). The card title keeps its
 *  fixed display size. */
@Composable
fun FirstRunTourOverlay(
    onFinish: () -> Unit,
    onBack: () -> Unit = onFinish,
) {
    BackHandler(onBack = onBack)
    val cards = SAMPLE_TOUR_CARDS
    val pager = rememberPagerState(pageCount = { cards.size })
    val scope = rememberCoroutineScope()
    // Full-bleed opaque surface with a swallow-taps click so nothing behind it can be reached
    // while the tour is up: a full-screen pager of cards, not a sheet.
    Box(
        Modifier
            .fillMaxSize()
            .semantics { paneTitle = SAMPLE_TOUR_PANE_TITLE }
            .background(Acab.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            // Consume only pointer changes no child handled. Skip/Next still receive their taps,
            // while empty overlay space cannot reach the app beneath and no giant disabled
            // TalkBack node is published for this touch shield.
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Final)
                        event.changes.filterNot { it.isConsumed }.forEach { it.consume() }
                    }
                }
            },
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                // The tour's name at the leading edge, an uppercase identifier so Kicker sets it
                // in the instrument face (R16). TWIN: iOS FirstRunTourView's kicker beside Skip.
                Box(Modifier.padding(start = 12.dp)) { Kicker(SAMPLE_TOUR_KICKER) }
                // R8b: Skip reads labelLarge, the M3 button default, not the old 12 sp mono; the
                // TextButton keeps its own minimum touch target. TWIN: iOS
                // FirstRunTourView skip button, ACABTheme.font(.body) semibold in dim.
                TextButton(onClick = onFinish) {
                    Text("Skip", color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelLarge)
                }
            }

            HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { i ->
                val c = cards[i]
                // Scrollable: at large font scales (or a short landscape window) a page's copy
                // outgrows the viewport, and without the scroll the overflow was simply cut off.
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = 26.dp, vertical = 18.dp),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(c.icon, contentDescription = null, tint = Acab.accent,
                        modifier = Modifier.size(34.dp))
                    Spacer(Modifier.height(18.dp))
                    Text(
                        c.title,
                        color = Acab.text,
                        fontSize = 23.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.semantics { heading() },
                    )
                    Spacer(Modifier.height(18.dp))
                    // R8: the card's body and note read on the M3 type scale (bodyLarge, then
                    // bodyMedium, both in onSurfaceVariant), not the old fixed mono sizes, and
                    // take the scale's own line heights, so both follow the font scale. The note
                    // is secondary ink, never faint: it is the sentence that says sample settings
                    // are safe to explore. TWIN: iOS FirstRunTourView.cardView, body
                    // ACABTheme.font(.body) and note ACABTheme.font(.subheadline), both in dim.
                    Text(c.body, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyLarge)
                    Spacer(Modifier.height(18.dp))
                    Text(c.note, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium)
                }
            }

            Column(
                Modifier.fillMaxWidth().padding(bottom = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // The three-dot page indicator says which step this is; the "step N of 3" text
                // that once sat above it said the same thing twice (2026-09-26 review P3-12,
                // "say it once"). The words survive as the indicator's spoken value
                // (tourStepDescription), and the Row stays the polite live region the text was,
                // so TalkBack still reads the new step after a swipe or next. TWIN: iOS
                // FirstRunTourView page indicator, the same accessibility value.
                val stepDescription = tourStepDescription(pager.currentPage, cards.size)
                Row(
                    Modifier.semantics {
                        contentDescription = stepDescription
                        liveRegion = LiveRegionMode.Polite
                    },
                    horizontalArrangement = Arrangement.Center,
                ) {
                    cards.indices.forEach { i ->
                        val on = i == pager.currentPage
                        Box(
                            Modifier
                                .padding(horizontal = 3.5.dp)
                                .size(if (on) 7.dp else 5.dp)
                                .background(if (on) Acab.accent else Acab.faint, CircleShape),
                        )
                    }
                }
            }

            val last = pager.currentPage >= cards.size - 1
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 26.dp)
                    .minimumInteractiveComponentSize()
                    .background(Acab.accent, RoundedCornerShape(Acab.radiusSm))
                    .clickable(
                        onClickLabel = if (last) "explore sample data" else "next tour step",
                        role = Role.Button,
                    ) {
                        if (last) onFinish()
                        else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                    }
                    .padding(vertical = 15.dp),
                contentAlignment = Alignment.Center,
            ) {
                // R8b: the label reads labelLarge, the M3 button default, not the old 14 sp bold
                // mono. The minimum interactive size and the 15 dp vertical padding keep the hit
                // target. TWIN: iOS FirstRunTourView next button, ACABTheme.font(.body) semibold.
                Text(if (last) "Explore Sample Data" else "Next", color = Acab.onAccent,
                    style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center)
            }
        }
    }
}

/** What the tour's page indicator says for the card at [page] (zero-based) of [count]: the
 *  "step N of 3" the cards once drew as text (P3-12), now spoken only. Pinned in
 *  SampleTourStepIndicatorTest. TWIN: iOS FirstRunTourView's page indicator accessibility value. */
internal fun tourStepDescription(page: Int, count: Int): String = "step ${page + 1} of $count"

/** Persistence for the checklist's one-time seen flag, and the checklist's shared copy.
 *  TWIN: iOS enum FirstRunTour in FirstRunTourView.swift. */
object FirstRunTour {
    private const val PREFS = "acab_ui"
    private const val KEY = "first_run_tour_seen"
    fun hasSeen(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)
    /** Checklist completion: the seen flag and [FINISH_SETUP_DISMISSED] in ONE editor, so one
     *  apply() commits both. The iOS twin persistChecklistCompletion (RootView.swift) makes two
     *  writes to one UserDefaults: the seen flag (markSeen(in:) on its FirstRunTour), then
     *  FinishSetupOnboarding.complete(in:). The key names are the pre-checklist build's, kept for
     *  upgrade continuity: a user who finished the old tour has first_run_tour_seen = true and
     *  never sees the checklist. */
    fun markChecklistComplete(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY, true)
            .putBoolean(FINISH_SETUP_DISMISSED, true)
            .apply()

    // The setup checklist's copy, one home per string. Each is compared with its iOS twin on
    // `enum FirstRunTour` in FirstRunTourView.swift (same meaning, camelCase names).

    // The three board-naming lines are templates, rendered for the checklist's kind
    // (checklistBoardKind) through renderBoardCopy; null reads as beacon. "under Beacon" names the
    // tab and stays.

    /** The checklist sheet's title. TWIN: iOS FirstRunTour.checklistTitle. */
    const val CHECKLIST_TITLE_TEMPLATE = "your {noun} is listening"
    /** The line under the title in a preview ([checklistIsPreview]): the replay with no live
     *  board to describe says so first, so "your beacon is listening" and the neutral rows are not
     *  read as a failed setup (J7). TWIN: iOS FirstRunTour.checklistPreviewNote. */
    const val CHECKLIST_PREVIEW_NOTE_TEMPLATE = "preview: this is what you see after your {noun} connects."
    /** The line under the title. TWIN: iOS FirstRunTour.checklistSubtitle. */
    const val CHECKLIST_SUBTITLE_TEMPLATE = "detection is already active. these optional phone and {noun} features can be changed later under Beacon."
    /** What an empty radar does and does not mean, as one sentence, with the window read from
     *  [ACTIVE_NEARBY_WINDOW_MS] so the number cannot drift from the Status count it explains.
     *  TWIN: iOS FirstRunTour.quietSentence (built from activeNearbyInterval). */
    val QUIET_SENTENCE = "quiet does not mean clear. zero nearby means no supported broadcast was recognized in the last ${ACTIVE_NEARBY_WINDOW_MS / 1_000L} seconds. silent, wired, cellular-only, 5 GHz-only, powered-off, or unsupported gear can still be there."
    /** Which detectors start on and why. TWIN: iOS FirstRunTour.detectorsNote. */
    const val DETECTORS_NOTE = "ALPR, drones, body cams, and glasses start on. trackers and network cameras start off because they can be noisy. desert mode reports every nearby broadcast when you want proof of life, so turn it back off when you are done."
    /** Why Location is asked for. No Live Mode clause here: docs/app-guide.md says Android Live
     *  Mode does not request background Location, while the iOS twin keeps that clause because
     *  iPhone needs Location to start Live Mode. The rest is shared and ends on the canonical
     *  privacy sentence. A template: the board that labels buffered hits is the checklist's board
     *  (checklistBoardKind), rendered through renderBoardCopy; null reads as beacon.
     *  TWIN: iOS FirstRunTour.locationRationale. */
    const val LOCATION_RATIONALE_TEMPLATE = "Location is optional. it shows where your phone heard detections on Map, and lets the {noun} label buffered hits with the last location your phone shared over encrypted Bluetooth. choose Not Now and detection still works. nothing is uploaded automatically."
    /** The checklist's fixed row titles, in row order (the detectors row is counted, so it is
     *  built at runtime and is not here). Sentence case, as every row title since the 2026-09-26
     *  review's P3-11 ("Location" and "Live Mode" are feature names and keep their case).
     *  TWIN: iOS FirstRunTour.checklistRowTitles. */
    val CHECKLIST_ROW_TITLES = listOf("Paired over encrypted Bluetooth", "Location", "Phone notifications", "Live Mode", "Offline buffer")
}

/** The finish-setup completion key in the `acab_ui` preferences. Moved here from StatusScreen.kt,
 *  with the Live Mode state below, when the Status finish-setup card left.
 *  WRITE-ONLY in this build: [FirstRunTour.markChecklistComplete] sets it so that a downgrade to a
 *  build that still has the Status finish-setup card does not show that card again. Nothing here
 *  reads it; the checklist gate reads only first_run_tour_seen (shouldOpenChecklist). */
internal const val FINISH_SETUP_DISMISSED = "finish_setup_dismissed"

internal enum class FinishSetupLiveState { ACTIVE, BLOCKED, WAITING, OFF }

internal fun finishSetupLiveState(
    wanted: Boolean,
    active: Boolean,
    notificationsAvailable: Boolean,
): FinishSetupLiveState = when {
    !wanted -> FinishSetupLiveState.OFF
    !notificationsAvailable -> FinishSetupLiveState.BLOCKED
    active -> FinishSetupLiveState.ACTIVE
    else -> FinishSetupLiveState.WAITING
}

/** The checklist rows' state lines, the iOS sentences (TWIN: iOS ChecklistRows in
 *  ChecklistView.swift), each drawn under its row title. The shared arms are word for word iOS
 *  with the platform name swapped. RECORDED PLATFORM DIFFERENCES: Android Live Mode does not use
 *  Location (docs/app-guide.md; LOCATION_RATIONALE_TEMPLATE drops the Live Mode clause), so the granted
 *  Location line names Map only; Android has no restricted / permanently-denied Location fact
 *  ([finishSetupLocationChoice]), so the iOS restricted and denied arms have no input here; the
 *  iOS Live Activities and waits-for-Location Live Mode arms have no Android state; and the
 *  buffer row has an Android-only unknown arm (no frame yet), where iOS reads a sticky Bool. */
internal fun checklistLocationDetail(granted: Boolean): String =
    if (granted) "allowed; Map is ready" else "optional; not decided yet"

/** The phone notifications row. [count] is how many categories this phone notifies for,
 *  [blockedBySystem] the system refusing to deliver them, [demo] sample data. Sample data never
 *  reads the blocked sentence: nothing in sample data is delivered, so the system's answer is not
 *  a fact about it. TWIN: iOS ChecklistRows.notificationDetail, which gates the same arm on
 *  `!ble.demoMode`. */
internal fun checklistNotificationDetail(count: Int, blockedBySystem: Boolean, demo: Boolean): String = when {
    count == 0 -> "off until you choose categories under Beacon"
    !demo && blockedBySystem -> "$count chosen, but Android is blocking them; turn notifications on for beacons in Settings"
    count == 1 -> "$count category enabled on this phone"
    else -> "$count categories enabled on this phone"
}

/** The Live Mode row, from [finishSetupLiveState]. [kind] is the checklist's board
 *  (checklistBoardKind); null reads as beacon. TWIN: iOS ChecklistRows liveMode. */
internal fun checklistLiveModeDetail(state: FinishSetupLiveState, kind: BoardKind? = null): String = when (state) {
    FinishSetupLiveState.ACTIVE -> "active on supported system surfaces"
    FinishSetupLiveState.OFF -> "off by choice; change it later under Beacon"
    FinishSetupLiveState.BLOCKED -> "on by default, but its notification is blocked by Android"
    FinishSetupLiveState.WAITING -> renderBoardCopy("ready to start with this {noun}", kind)
}

/** The offline buffer row, from the board's frame. null = no frame reports it yet (sample data,
 *  no link): ANDROID-ONLY arm, never a bare "CHECK". [kind] as for the Live Mode row.
 *  TWIN: iOS ChecklistRows buffer. */
internal fun checklistBufferDetail(bufOn: Boolean?, kind: BoardKind? = null): String = when (bufOn) {
    true -> renderBoardCopy("on; the {noun} retains hits while this phone is away", kind)
    false -> "off; turn it on under Beacon if you want away-time hits retained"
    null -> renderBoardCopy("not known until your {noun} reports it", kind)
}

/** The board the checklist names. In sample data, only the canned frame's own fw label, which
 *  reads "beacon board" in every release build (the DEBUG board-kind hook can swap it); a real
 *  board's kinds never leak into the sample. Otherwise the connected board (connectedBoardKind:
 *  the fw label while a frame is in, else the connect target's kind), and for a replay with no
 *  link the remembered board; null reads as beacon. TWIN: iOS BLEManager.connectedKind, which
 *  reads the sample frame's label the same way. */
internal fun checklistBoardKind(
    demo: Boolean,
    firmwareLabel: String?,
    targetKind: BoardKind?,
    rememberedKind: BoardKind?,
): BoardKind? =
    if (demo) BoardKind.fromFirmwareLabel(firmwareLabel)
    else connectedBoardKind(firmwareLabel, targetKind) ?: rememberedKind

/** Which Location control the checklist offers. TWIN: iOS FinishSetupLocationChoice in
 *  ChecklistView.swift. */
internal enum class FinishSetupLocationChoice { CONTINUE_OR_NOT_NOW, OPEN_SETTINGS_OR_DONE, DONE }

/** Authorized wins over denied, then denied over undecided. Android always passes
 *  isDenied = false: MainActivity exposes no permanently-denied fact (requestOptionalLocation
 *  itself sends a Continue tap to the app's Settings page in that case), so ChecklistSheet never
 *  sees OPEN_SETTINGS_OR_DONE and draws no arm for it. TWIN: iOS finishSetupLocationChoice(
 *  isAuthorized:isDenied:) in ChecklistView.swift. */
internal fun finishSetupLocationChoice(isAuthorized: Boolean, isDenied: Boolean): FinishSetupLocationChoice = when {
    isAuthorized -> FinishSetupLocationChoice.DONE
    isDenied -> FinishSetupLocationChoice.OPEN_SETTINGS_OR_DONE
    else -> FinishSetupLocationChoice.CONTINUE_OR_NOT_NOW
}

/** The checklist's Continue requests Location only after the sheet was really shown and closed,
 *  on a ready, real session. TWIN: iOS shouldRequestOnboardingLocation(continueChosen:
 *  isSessionReady:finishSetupWasPresented:isDemoMode:isAppActive:) in RootView.swift; Android has
 *  no isAppActive input because the request runs from the sheet's own dismissal, on screen. */
internal fun shouldRequestOnboardingLocation(
    continueChosen: Boolean,
    isSessionReady: Boolean,
    sheetWasPresented: Boolean,
    isDemoMode: Boolean,
): Boolean = continueChosen && sheetWasPresented && isSessionReady && !isDemoMode

/** The six category detectors the status frame reports; null before the first frame. Not moto
 *  (a sub-toggle of the body-cam detector) and not droui (it refines the drone detector). TWIN:
 *  iOS enabledDetectorCount(_:) in ChecklistView.swift, over flock, drone, axon, tracker,
 *  glasses, ncam. */
internal fun enabledDetectorCount(s: DeviceStatus?): Int? =
    s?.let { listOf(it.flock, it.drone, it.bodyCam, it.tracker, it.glasses, it.ncam).count { on -> on } }

/** The detectors row's title: the plain phrase before the first status frame, then the count.
 *  Sentence case like the other row titles (P3-11); a counted title starts with its figure.
 *  TWIN: iOS checklistDetectorsTitle(count:) in ChecklistView.swift. */
internal fun checklistDetectorsTitle(count: Int?): String = when (count) {
    null -> "Detectors on"
    1 -> "1 detector on"
    else -> "$count detectors on"
}

/**
 * The one post-connect setup checklist (C14), an M3 ModalBottomSheet. It replaces the real-board
 * tour and the Status finish-setup card.
 *
 * ANY CLOSE IS COMPLETION (Done, the scrim, a drag, Back call [onDismiss]; a chevron calls
 * [onOpenNotifications] / [onOpenLiveMode] instead), and the caller persists completion in each of
 * those callbacks. A close whose hide animation is cancelled, because the sheet left composition
 * (a link drop, an activity recreation), runs nothing and so completes nothing; the unseen gate
 * opens the sheet again on the next ready session.
 *
 * [replay] is the read-only copy that Help's "replay the setup checklist" row opens: state lines only,
 * no buttons and no chevrons, and the caller persists nothing.
 *
 * Rows 1 and 2 read ONE input, the rule both apps share: `frame` = the status frame from a real
 * board (null in sample data, whose canned status is no board, and null before the first frame
 * or after a drop). "paired" = a frame is present; the paired subline, the detector count and the
 * DETECTORS_NOTE / opt-in choice all read the same frame. So sample data and a connect before the
 * first frame both show an unchecked paired row with no subline, "detectors on" with no check and
 * DETECTORS_NOTE. TWIN: iOS ChecklistView.alreadyTrueSection, which reads the same frame
 * (`ble.demoMode ? nil : ble.status`) for the same three things.
 *
 * Location has no OPEN_SETTINGS_OR_DONE arm on Android (see [finishSetupLocationChoice]).
 * Continue sets the caller's intent ([onContinueLocation]) only once the hide has finished, and
 * immediately before [onDismiss] reads it.
 *
 * TWIN: iOS ChecklistView in ChecklistView.swift.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun ChecklistSheet(
    ble: AcabBleManager,
    replay: Boolean,
    locationGranted: Boolean,
    notificationsAvailable: Boolean,
    onDismiss: () -> Unit,
    onContinueLocation: () -> Unit = {},
    onOpenNotifications: () -> Unit = {},
    onOpenLiveMode: () -> Unit = {},
) {
    // Host context and lifecycle, read here and not inside the sheet (a dialog window).
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val targetKind by ble.targetKind.collectAsState()
    val rememberedKind by ble.rememberedKind.collectAsState()
    // The board every board-naming line below names ("your OUI-Spy is listening").
    val kind = checklistBoardKind(demo, status?.firmwareLabel, targetKind, rememberedKind)
    val liveWanted by ble.driveModeWanted.collectAsState()
    val liveRunning by ble.driveMode.collectAsState()
    // Sample data's canned board is no board, and with no link there is no frame (the manager
    // clears it on a drop), so rows 1 and 2 draw a check only for a real, connected board.
    val frame = if (demo) null else status
    // A cache read, as the Status card did (isEnabled reads the same cache anyEnabled does).
    val phoneAlertsCount = DetectionNotifier.NOTIFIABLE.count { DetectionNotifier.isEnabled(context, it) }
    // mutedBySystem asks the system over Binder, so it is asked on ON_RESUME only, never in
    // composition. addObserver on a RESUMED owner delivers ON_RESUME synchronously, which is the
    // one read when the sheet opens; every later resume (back from system settings) reads again.
    // The seed is a constant, not a read, so opening reads once and not twice.
    var phoneAlertsAvailable by remember { mutableStateOf(true) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                phoneAlertsAvailable = !DetectionNotifier.mutedBySystem(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var closing by remember { mutableStateOf(false) }
    // Hide, then act. The guard stops a Done tap and a drag from running onDismiss twice (which
    // would request Location twice). The action runs only when the hide completes normally:
    // invokeOnCompletion also fires for a cancelled job, which is either the sheet leaving
    // composition (nothing persists, no request) or a drag catching the sheet mid-hide (the guard
    // reopens so the drag's own dismissal is not swallowed).
    fun closeThen(action: () -> Unit) {
        if (closing) return
        closing = true
        scope.launch { sheetState.hide() }.invokeOnCompletion { cause ->
            if (cause == null) action() else closing = false
        }
    }
    val (pairedTitle, locationTitle, notificationsTitle, liveTitle, bufferTitle) = FirstRunTour.CHECKLIST_ROW_TITLES
    val scheme = MaterialTheme.colorScheme

    // statusBarsPadding: fully expanded, this sheet fills the screen height, and material3 1.3.1's
    // default contentWindowInsets pad only the bottom, so its drag handle sat in the status bar
    // beside the clock. As the sheet's outermost modifier it keeps the sheet's top edge below the
    // status bar, and a shorter sheet (a tablet) still rests on the bottom edge.
    ModalBottomSheet(
        onDismissRequest = { if (!closing) { closing = true; onDismiss() } },
        modifier = Modifier.statusBarsPadding(),
        sheetState = sheetState,
    ) {
        LightSheetSystemBarIcons()
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
            Text(
                renderBoardCopy(FirstRunTour.CHECKLIST_TITLE_TEMPLATE, kind),
                Modifier.padding(horizontal = 16.dp).semantics { heading() },
                style = MaterialTheme.typography.headlineSmall,
                color = scheme.onSurface,
            )
            // In a preview the first thing under the title says so, before the subtitle's
            // "detection is already active" can be read as a claim about now.
            val preview = checklistIsPreview(replay, frame)
            if (preview) {
                Text(
                    renderBoardCopy(FirstRunTour.CHECKLIST_PREVIEW_NOTE_TEMPLATE, kind),
                    Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = scheme.onSurface,
                )
            }
            Text(
                renderBoardCopy(FirstRunTour.CHECKLIST_SUBTITLE_TEMPLATE, kind),
                Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
            )
            // What is already true. Each row is one TalkBack stop that states its fact as
            // "done" or "not yet", the words iOS ChecklistView speaks as its accessibilityValue.
            val paired = frame != null
            val detectorCount = enabledDetectorCount(frame)
            // As on iOS: no check beside "0 detectors on".
            val detectorsOn = (detectorCount ?: 0) > 0
            // In a preview the two rows are neutral: a plain glyph and no "done" / "not yet"
            // state, since there is no board whose state they could report (iOS draws
            // "lock.fill" and "switch.2" the same way).
            GroupedRow(
                pairedTitle,
                modifier = if (preview) Modifier.semantics(mergeDescendants = true) {}
                           else Modifier.checklistState(paired),
                supporting = if (frame != null) {
                    { Kicker("${frame.firmwareLabel} · firmware ${frame.version}") }
                } else null,
                leading = {
                    if (preview) Icon(Icons.Filled.Lock, contentDescription = null, tint = scheme.onSurfaceVariant)
                    else DoneMark(paired)
                },
            )
            GroupedRow(
                checklistDetectorsTitle(detectorCount),
                modifier = if (preview) Modifier.semantics(mergeDescendants = true) {}
                           else Modifier.checklistState(detectorsOn),
                supporting = {
                    Kicker(if (frame == null) FirstRunTour.DETECTORS_NOTE else CONNECT_OPT_IN_SENTENCE)
                },
                leading = {
                    if (preview) Icon(Icons.Filled.ToggleOn, contentDescription = null, tint = scheme.onSurfaceVariant)
                    else DoneMark(detectorsOn)
                },
            )
            GroupedDivider()
            // What is optional.
            val choice = finishSetupLocationChoice(isAuthorized = locationGranted, isDenied = false)
            GroupedRow(
                locationTitle,
                leading = { Icon(Icons.Outlined.LocationOn, contentDescription = null, tint = scheme.primary) },
                supporting = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Kicker(checklistLocationDetail(locationGranted))
                        if (choice == FinishSetupLocationChoice.CONTINUE_OR_NOT_NOW) {
                            Kicker(renderBoardCopy(FirstRunTour.LOCATION_RATIONALE_TEMPLATE, kind))
                            if (!replay) {
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Button(onClick = { closeThen { onContinueLocation(); onDismiss() } }) {
                                        Text("Continue")
                                    }
                                    OutlinedButton(onClick = { closeThen(onDismiss) }) {
                                        Text("Not Now")
                                    }
                                }
                            }
                        }
                    }
                },
            )
            GroupedRow(
                notificationsTitle,
                supporting = { Kicker(checklistNotificationDetail(phoneAlertsCount, !phoneAlertsAvailable, demo)) },
                leading = { Icon(Icons.Outlined.Notifications, contentDescription = null, tint = scheme.primary) },
                trailing = if (!replay) {
                    { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) }
                } else null,
                onClick = if (!replay) {
                    { closeThen(onOpenNotifications) }
                } else null,
                onClickLabel = if (!replay) "open phone notifications in Beacon" else null,
            )
            GroupedRow(
                liveTitle,
                supporting = {
                    Kicker(checklistLiveModeDetail(finishSetupLiveState(
                        wanted = liveWanted,
                        active = liveRunning && ble.driveServiceReady,
                        notificationsAvailable = notificationsAvailable,
                    ), kind))
                },
                leading = { Icon(Icons.Outlined.LockClock, contentDescription = null, tint = scheme.primary) },
                trailing = if (!replay) {
                    { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) }
                } else null,
                onClick = if (!replay) {
                    { closeThen(onOpenLiveMode) }
                } else null,
                onClickLabel = if (!replay) "open Live Mode in Beacon" else null,
            )
            GroupedRow(
                bufferTitle,
                supporting = {
                    Kicker(checklistBufferDetail(frame?.bufOn, kind))
                },
                leading = { Icon(Icons.Outlined.Inventory2, contentDescription = null, tint = scheme.primary) },
            )
            Text(
                FirstRunTour.QUIET_SENTENCE,
                Modifier.fillMaxWidth().padding(16.dp),
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = { closeThen(onDismiss) }) { Text("Done") }
            }
        }
    }
}

/** One TalkBack stop per "already true" row, with its state as "done" or "not yet". TWIN: iOS
 *  ChecklistView alreadyTrueSection, `.accessibilityValue(done ? "done" : "not yet")`. */
/** True when the sheet is the read-only replay AND has no live board to describe: [frame] is the
 *  board's status frame, already null in sample data and with no link. Then the sheet is a preview
 *  (J7): it draws [FirstRunTour.CHECKLIST_PREVIEW_NOTE_TEMPLATE] under the title and rows 1 and 2 as
 *  neutral rows, never as unticked checks. The post-connect sheet itself is never a preview.
 *  TWIN: iOS checklistIsPreview(replay:frame:) in ChecklistView.swift, the same two inputs. */
internal fun checklistIsPreview(replay: Boolean, frame: DeviceStatus?): Boolean = replay && frame == null

private fun Modifier.checklistState(done: Boolean): Modifier =
    semantics(mergeDescendants = true) { stateDescription = if (done) "done" else "not yet" }

/** A done row's primary check mark, or an empty onSurfaceVariant circle when the fact does not
 *  hold yet (no board, or no detector on). The circle keeps the leading column filled, so the
 *  top two rows do not read as icons that failed to load, and it carries no check, so nothing
 *  claims a board that is not there. Decorative in both states: the row speaks its state
 *  ([checklistState]). TWIN: iOS ChecklistView checkGlyph, "checkmark.circle.fill" or an empty
 *  "circle" in faint. */
@Composable
private fun DoneMark(shown: Boolean) {
    if (shown) {
        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
    } else {
        Icon(Icons.Outlined.RadioButtonUnchecked, contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
