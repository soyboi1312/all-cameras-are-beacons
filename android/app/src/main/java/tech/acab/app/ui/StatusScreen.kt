package tech.acab.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.SystemUpdateAlt
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import tech.acab.app.R
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.OtaPhase
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.model.titleName
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabPalette
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.JetBrainsMono
import tech.acab.app.ui.theme.tabular
import tech.acab.app.ui.theme.telemetry
import tech.acab.app.ui.theme.textTone
import tech.acab.app.ui.theme.tone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** The radar is intentionally a summary, not a one-dot-per-radio plot. SHARED WITH iOS - this
 *  one IS the same number: DashboardSnapshot.dotLimit in DashboardPresentation.swift. Both suites
 *  pin the literal 14 rather than the constant, so a one-sided edit fails on that side. */
internal const val STATUS_RADAR_DOT_CAP = 14

internal enum class StatusCountTileDestination { LOG, DETECTOR_SETTINGS }

internal data class StatusCountTilePresentation(
    val visibleCount: String,
    val off: Boolean,
    val destination: StatusCountTileDestination,
    val clickLabel: String,
    val contentDescription: String,
)

/** A disabled detector can still have detections inside the recent 45-second window. */
internal fun statusCountTileDestination(
    count: Int,
    enabled: Boolean?,
): StatusCountTileDestination =
    if (enabled == false && count == 0) StatusCountTileDestination.DETECTOR_SETTINGS
    else StatusCountTileDestination.LOG

/** [contentDescription] is the tile's spoken sentence: name, count, and the detector setting
 *  when it is off. "recently heard" is the radar's own word for the 45 s window
 *  ([StatusNearbySummary.radarContentDescription] says "recently heard devices nearby"), so the
 *  tile and the dial describe the same thing. TWIN: iOS DashboardPresentation.swift
 *  `dashboardTileAccessibilityLabel`, byte-identical; both suites pin the sentence. */
internal fun statusCountTilePresentation(
    spokenLabel: String,
    count: Int,
    enabled: Boolean?,
): StatusCountTilePresentation {
    val off = enabled == false
    val destination = statusCountTileDestination(count, enabled)
    return StatusCountTilePresentation(
        visibleCount = count.toString(),
        off = off,
        destination = destination,
        clickLabel = if (destination == StatusCountTileDestination.DETECTOR_SETTINGS)
            "open detector settings" else "show in log",
        contentDescription = "$spokenLabel, $count recently heard" +
            if (off) ", detector off" else "",
    )
}

/** One tile of the Status category strip. [label] is the drawn width-budget abbreviation
 *  ("TRKR", "GLAS"), which a screen reader would speak as gibberish, so [spoken] is what TalkBack
 *  says in its place: plural, because a count follows. [counted] is every type whose recent rows
 *  the tile counts; the ALPR tile counts FLOCK_RAVEN too, which is why its spoken name covers
 *  both, and why both ride the flock [toggle], the one detector that produces them. The Log
 *  filter key is [DeviceType.category] of [type]. TWIN: iOS DashboardPresentation.swift
 *  `DashboardStripTile`. */
internal data class StatusStripTile(
    val type: DeviceType,
    val label: String,
    val spoken: String,
    val counted: List<DeviceType>,
    val toggle: (DeviceStatus) -> Boolean,
)

/** The six category tiles, in strip order. TWIN: iOS `DashboardSnapshot.stripTiles`, same six
 *  tiles in the same order, `label` and `spoken` byte-identical; both suites pin them. */
internal val STATUS_STRIP_TILES: List<StatusStripTile> = listOf(
    StatusStripTile(DeviceType.FLOCK_CAMERA, "ALPR", "ALPR cameras and Raven audio sensors",
        listOf(DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN), DeviceStatus::flock),
    StatusStripTile(DeviceType.DRONE, "DRONE", "drones", listOf(DeviceType.DRONE), DeviceStatus::drone),
    StatusStripTile(DeviceType.BODY_CAM, "BODY", "body cameras", listOf(DeviceType.BODY_CAM),
        DeviceStatus::bodyCam),
    StatusStripTile(DeviceType.TRACKER, "TRKR", "trackers", listOf(DeviceType.TRACKER),
        DeviceStatus::tracker),
    StatusStripTile(DeviceType.GLASSES, "GLAS", "glasses", listOf(DeviceType.GLASSES),
        DeviceStatus::glasses),
    StatusStripTile(DeviceType.NETWORK_CAMERA, "NETCAM", "network cameras",
        listOf(DeviceType.NETWORK_CAMERA), DeviceStatus::ncam),
)

internal enum class StatusStrongestKind { MATCHED, UNCLASSIFIED, AMBIENT }

/** The Status scan kicker as drawn. Sample data says sample less on Status (STA-6): the bare
 *  "SAMPLE DATA" is not drawn (the banner and the SAMPLE pill already say it), while the radio
 *  variants still are, because they carry a fact ("SAMPLE DATA · BLUETOOTH ONLY"). null = draw
 *  nothing. The presenter keeps returning "SAMPLE DATA" (the pill and the radar's sweep read the
 *  same presentation); the Beacon tab's Scan radios row names the sample radios in the live
 *  arms' form instead (beaconRadioStatusLabel, 2026-09-26 review P3-8). TWIN: iOS
 *  dashboardScanKicker(scanLabel:isDemoMode:) in DashboardPresentation.swift. */
internal fun statusScanKicker(label: String, demo: Boolean): String? =
    if (demo && label == "SAMPLE DATA") null else label

/** The strongest card's header. Real sessions add " · RECENT"; sample data adds nothing, because
 *  the row's own line says "sample sighting · not live" and RECENT would contradict it. TWIN: iOS
 *  dashboardStrongestHeader(kind:isDemoMode:) in DashboardPresentation.swift. */
internal fun statusStrongestHeader(kind: StatusStrongestKind, demo: Boolean): String {
    val base = when (kind) {
        StatusStrongestKind.MATCHED -> "STRONGEST MATCH"
        StatusStrongestKind.UNCLASSIFIED -> "STRONGEST UNCLASSIFIED"
        StatusStrongestKind.AMBIENT -> "STRONGEST AMBIENT"
    }
    return if (demo) base else "$base · RECENT"
}

/** One radar blip. [watched] rides along because starring a device deliberately does NOT change
 *  its [Detection.type] (see isWatchedFilterMember), so the type alone cannot tell the scope to
 *  draw a star in gold. [priority] is the dot-cap ordering key: stars first, then matches. */
internal data class StatusRadarDot(
    val row: Detection,
    val watched: Boolean,
    val priority: Int,
)

/** Exact arithmetic for the Status radar. Only Desert-mode catch-all rows are ambient. UNKNOWN is
 * fail-closed protocol evidence: it may be a future/retired real category, so it gets an honest
 * unclassified bucket unless the person explicitly starred that address. */
internal data class StatusNearbySummary(
    val total: Int,
    val matched: Int,
    val ambient: Int,
    val unclassified: Int,
    val watched: Int,
    val dots: List<StatusRadarDot>,
    val strongest: Detection?,
    val strongestKind: StatusStrongestKind?,
) {
    /** First caption line under the radar. TWIN: iOS `DashboardSnapshot.radarCaption` in
     *  DashboardPresentation.swift, byte-identical; both suites pin the literal. */
    val radarCaption: String
        get() = "${dots.size} of $total dots · $STATUS_RADAR_DOT_CAP max"

    /** The one spoken sentence for the whole scope: rings, blips and the sweep are positional
     *  decoration a screen reader cannot use, so it says what the scope actually knows. TWIN: iOS
     *  `RadarScope.accessibilityLabel` in Components.swift, byte-identical, singular at one for the
     *  devices and the dots alike. A getter like [radarCaption]: the semantics lambda that reads it
     *  runs when the semantics tree is collected, not on every recomposition. */
    val radarContentDescription: String
        get() = "$total recently heard device${if (total == 1) "" else "s"} nearby. " +
            "${dots.size} dot${if (dots.size == 1) "" else "s"} drawn, at most $STATUS_RADAR_DOT_CAP, " +
            "with matches and watched devices first. Radar shows signal strength only, not direction."

    /** Under the count cards, only when there is something to say. TWIN: iOS
     *  `DashboardSnapshot.unclassifiedLine` / `watchedLine` in DashboardPresentation.swift,
     *  byte-identical; both suites pin them. Unclassified is a dim fact (a wire type this build
     *  does not know), not an alert; watched is the tap that opens the Log's WATCHED lens.
     *  Getters, not stored fields, so nothing is built while a count is 0. RadarLegend reads them
     *  in its composition body, so a non-zero line is built on every recomposition of the legend,
     *  the same cost as [radarCaption] and the inline templates they replaced; the
     *  semantics-lambda deferral [radarContentDescription] describes does not apply to them. */
    val unclassifiedLine: String?
        get() = if (unclassified > 0) "$unclassified unclassified · category not recognized by this app" else null
    val watchedLine: String?
        get() = if (watched > 0) "$watched watched · included in matches" else null
}

/** Spoken form of one radar count card: the number first, then the card's own words, so
 *  TalkBack lands on the count the card exists to show. [title] and [detail] are the two lines
 *  the card draws under the number (the STATUS_MATCHED_CARD_* or STATUS_AMBIENT_CARD_* pair), so
 *  the matched card says "3 MATCHED + WATCHED, signatures or exact stars": the same three things,
 *  in the same order, that VoiceOver reads from the iOS card's combined children
 *  (DashboardView.nearbyCount). The join lives here, not at the RadarCountCard call site, so the
 *  unit tests pin the spoken form itself. */
internal fun statusRadarCountCardDescription(count: Int, title: String, detail: String): String =
    "$count $title, $detail"

/** Second caption line under the radar. The second clause is the sentence that tells the user
 *  the 14-dot cap does not cap the counters ([StatusNearbySummary.total] and the breakdown count
 *  every recent device). TWIN: iOS `DashboardSnapshot.radarCaptionDetail`, byte-identical. */
internal const val STATUS_RADAR_CAPTION_DETAIL =
    "matches and watched devices first · counts include every recent device"

/** The two count cards that split TOTAL NEARBY, a title and a detail line each. TWIN: iOS
 *  `DashboardSnapshot.matchedCardTitle` / `matchedCardDetail` / `ambientCardTitle` /
 *  `ambientCardDetail` in DashboardPresentation.swift, byte-identical; both suites pin the four
 *  literals. "MATCHED + WATCHED" because a star counts as a match here ([statusNearbySummary]
 *  folds watched rows into `matched`), and the detail names the two things that means. */
internal const val STATUS_MATCHED_CARD_TITLE = "MATCHED + WATCHED"
internal const val STATUS_MATCHED_CARD_DETAIL = "signatures or your watchlist"
internal const val STATUS_AMBIENT_CARD_TITLE = "AMBIENT"
internal const val STATUS_AMBIENT_CARD_DETAIL = "Desert-mode broadcasts"

/** The far-right recency kicker beside the scan label, naming the window every count on this
 *  screen is filtered to. Built from ACTIVE_NEARBY_WINDOW_MS, the default window of the
 *  [AcabBleManager.freshIdSet] call that builds `nearby` in [StatusScreen], so the words cannot
 *  drift from the filter. A top-level val: built once, not on every recomposition. TWIN: iOS
 *  `DashboardSnapshot.seenWindowKicker`, built from activeNearbyInterval; both suites pin
 *  "SEEN < 45s", so retuning one window fails there. */
internal val STATUS_SEEN_WINDOW_KICKER = "SEEN < ${ACTIVE_NEARBY_WINDOW_MS / 1_000L}s"

internal fun statusNearbySummary(
    rows: List<Detection>,
    watchedMacs: Set<String>,
): StatusNearbySummary {
    fun isWatched(row: Detection): Boolean = row.isWatchedFilterMember(watchedMacs)

    // Ranking keys for the STRONGEST card and the dot cut: signal, then id. TWIN: iOS
    // DashboardPresentation.swift `strongerDashboardSighting`, same two keys - keep them
    // together, this rule has one owner. Last-heard is deliberately not a key: both candidates
    // are already inside the same 45 s freshness window, this runs on every ~3 Hz publish, and a
    // recency key would trade the hero card's name back and forth between two equally-loud
    // devices several times a second. It would also cost a per-row `lastSeen(id)` read, which
    // takes storeLock on the main thread - the pathology `freshIdSet` exists to avoid.
    fun comesBefore(row: Detection, priority: Int, b: StatusRadarDot): Boolean = when {
        priority != b.priority -> priority < b.priority
        row.rssi != b.row.rssi -> row.rssi > b.row.rssi
        else -> row.id < b.row.id
    }
    fun stronger(a: Detection, b: Detection?): Boolean =
        b == null || a.rssi > b.rssi || (a.rssi == b.rssi && a.id < b.id)

    var watched = 0
    var ambient = 0
    var unclassified = 0
    var strongestMatched: Detection? = null
    var strongestUnclassified: Detection? = null
    var strongestAmbient: Detection? = null
    // Bounded insertion keeps this O(n * 14), avoiding a full Desert-mode sort/allocation on each
    // Status publish while producing the same deterministic priority order.
    val dotCandidates = ArrayList<StatusRadarDot>(STATUS_RADAR_DOT_CAP)
    for (row in rows) {
        val rowWatched = isWatched(row)
        val rowAmbient = !rowWatched && row.type == DeviceType.NEARBY_DEVICE
        val rowUnclassified = !rowWatched && row.type == DeviceType.UNKNOWN
        if (rowWatched) watched++
        when {
            rowAmbient -> {
                ambient++
                if (stronger(row, strongestAmbient)) strongestAmbient = row
            }
            rowUnclassified -> {
                unclassified++
                if (stronger(row, strongestUnclassified)) strongestUnclassified = row
            }
            else -> if (stronger(row, strongestMatched)) strongestMatched = row
        }
        val priority = when {
            rowWatched -> 0
            !rowAmbient && !rowUnclassified -> 1
            rowUnclassified -> 2
            else -> 3
        }
        val insertAt = dotCandidates.indexOfFirst { comesBefore(row, priority, it) }
            .let { if (it < 0) dotCandidates.size else it }
        if (insertAt < STATUS_RADAR_DOT_CAP) {
            dotCandidates.add(insertAt, StatusRadarDot(row, rowWatched, priority))
            if (dotCandidates.size > STATUS_RADAR_DOT_CAP) dotCandidates.removeAt(STATUS_RADAR_DOT_CAP)
        }
    }
    val matched = rows.size - ambient - unclassified
    val strongestKind = when {
        strongestMatched != null -> StatusStrongestKind.MATCHED
        strongestUnclassified != null -> StatusStrongestKind.UNCLASSIFIED
        strongestAmbient != null -> StatusStrongestKind.AMBIENT
        else -> null
    }
    val strongest = strongestMatched ?: strongestUnclassified ?: strongestAmbient
    return StatusNearbySummary(
        total = rows.size,
        matched = matched,
        ambient = ambient,
        unclassified = unclassified,
        watched = watched,
        dots = dotCandidates,
        strongest = strongest,
        strongestKind = strongestKind,
    )
}

/** Compact clock copy for a live row. Future/skewed stamps are treated as just now.
 *
 *  TWIN: iOS DashboardPresentation.swift `dashboardLastHeardLabel`, same strings and the same
 *  branches (just now, seconds, minutes, hours, "more than a day ago") in the same hero slot -
 *  reword one and reword the other. The minute, hour and day branches are defensive totality:
 *  the caller only ever hands this a row inside the 45 s freshness window, so they are not a
 *  rendered cue today. */
internal fun statusLastHeardAge(
    lastSeenAtMs: Long?,
    nowMs: Long,
    demo: Boolean,
): String = when {
    demo -> "sample sighting · not live"
    lastSeenAtMs == null -> "last heard unknown"
    nowMs - lastSeenAtMs < 1_000L -> "last heard just now"
    nowMs - lastSeenAtMs < 60_000L -> "last heard ${(nowMs - lastSeenAtMs).coerceAtLeast(0L) / 1_000L}s ago"
    nowMs - lastSeenAtMs < 3_600_000L -> "last heard ${(nowMs - lastSeenAtMs) / 60_000L}m ago"
    nowMs - lastSeenAtMs < 86_400_000L -> "last heard ${(nowMs - lastSeenAtMs) / 3_600_000L}h ago"
    else -> "last heard more than a day ago"
}

/** The strongest slot's empty state: FirstRunTour.QUIET_SENTENCE, verbatim, only when a real
 *  board is connected, its sweep is live ([scanning], [StatusScanPresentation.scanning]) and
 *  nothing is nearby. The quiet sentence says the beacon listened and heard nothing, so it must
 *  never stand under a parked sweep (radios off, a BLE fault with Wi-Fi off, a co-processor or
 *  firmware update): that would be a false all-clear. [statusNotScanningLine] owns the slot then.
 *  [connected] is the value the Status LinkChip is handed (`!reconnecting && status != null`).
 *  TWIN: iOS DashboardPresentation.swift `statusFirstZeroLine`, which takes the same four inputs
 *  (its scanning input is the radio presentation's isScanning). */
internal fun statusFirstZeroLine(connected: Boolean, demo: Boolean, scanning: Boolean, total: Int): String? =
    if (connected && !demo && scanning && total == 0) FirstRunTour.QUIET_SENTENCE else null

/** The strongest slot's empty state while the board is connected but NOT scanning: the scan
 *  presentation's plain sentence for why ([StatusScanPresentation.notScanningDetail], e.g. "Both
 *  beacon detection radios are switched off."), so a 0 under a parked sweep never reads as an
 *  all-clear. Null in sample mode, while anything is nearby, before the link is up, and whenever
 *  [statusFirstZeroLine] owns the slot. TWIN: iOS DashboardPresentation.swift
 *  `statusNotScanningLine`, same five inputs (its detail is beaconRadioPresentation's `detail`).
 *  iOS `connected` is also true before the first frame, so its slot can read that arm's sentence;
 *  here `connected` needs a frame, so the missing-frame arm carries no detail. */
internal fun statusNotScanningLine(
    connected: Boolean,
    demo: Boolean,
    scanning: Boolean,
    total: Int,
    notScanningDetail: String?,
): String? = if (connected && !demo && !scanning && total == 0) notScanningDetail else null

/** [notScanningDetail] is the plain sentence for a non-scanning arm, null while scanning. The
 *  sentences are byte-identical to the `detail` of the same arm in iOS beaconRadioPresentation
 *  (BeaconPresentation.swift); only the arms [statusNotScanningLine] can show carry one (a
 *  reconnect and a missing frame are never `connected` here, and sample mode never shows it). */
internal data class StatusScanPresentation(
    val scanning: Boolean,
    val bleUpdating: Boolean,
    val bleFault: Boolean,
    val label: String,
    val notScanningDetail: String? = null,
)

/** One radio truth table drives the Status label, the sweep and the co-processor banner.
 *
 *  The live-board labels are SHARED: iOS returns the same strings as scanLabel from
 *  beaconRadioPresentation (BeaconPresentation.swift), and the Beacon tab's collapsed row uses
 *  them too ([beaconRadioStatusLabel]). One board state, one sentence, on both phones, and on
 *  both Android tabs except where the Beacon row's arm order differs (last paragraph).
 *  StatusBeaconPresentationTest pins this label to the Beacon row's and pins the words; nothing
 *  mechanical holds iOS to them, so a reword is a by-hand edit on both platforms.
 *  Sample mode is shared too, as of 2026-09-08. Both tours echo the radio switches into the
 *  synthetic status (iOS: writeConfig -> demoStatusKeyByConfigKey in BLEManager.swift) and both
 *  presenters now read that echo, returning the same four labels and sweeping the radar whenever
 *  either sample radio is on. iOS used to return a flat "SAMPLE DATA · NO LIVE RADIOS" with
 *  scanning false, which parked its beam for the whole tour.
 *
 *  ARM ORDER IS SHARED with iOS beaconRadioPresentation, and the header pill's
 *  [statusLinkChipLabel] follows it: sample mode, then the link facts (reconnecting, then the
 *  phone's own update reboot, then no frame), then the board's own nrfup bit, then the
 *  coordinator's running flag, then the radios. iOS ranks two more link facts between its reboot
 *  and its first frame, the connection state and the secure session; neither is an input here,
 *  because AcabApp.kt leaves this screen uncovered only at READY or in the reconnect shell.
 *  So an unexpected drop in the middle of a combined update reads RECONNECTING on both phones,
 *  and the gap before the first frame after it reads CONNECTED · WAITING FOR BOARD STATUS under
 *  a WAITING pill; the coordinator's sentence returns once a frame is in hand.
 *
 *  THE UPDATE REBOOT IS A LINK FACT ON BOTH PHONES. [rebootingForUpdate] is
 *  [otaPhaseIsUpdateReboot] (OtaPhase REBOOTING or CONFIRMING), the twin of iOS
 *  isRebootingForUpdate, in the same slot. It reads UPDATING FIRMWARE · DETECTION MAY PAUSE under
 *  an UPDATING pill until the run confirms or fails, and that includes the gap between the
 *  reboot's reconnect and its first frame: the reboot drop clears the frame here (AcabBleManager
 *  cleanup) while iOS keeps the pre-reboot one, so without this arm that gap read WAITING here and
 *  UPDATING on iOS. Both suites pin those combinations (StatusBeaconPresentationTest,
 *  DashboardPresentationTests).
 *
 *  [beaconRadioStatusLabel] takes the same link facts first, through
 *  [beaconConnectionPresentation] and its own update-reboot arm in the same slot, so the reboot's
 *  no-frame gap reads UPDATING FIRMWARE · DETECTION MAY PAUSE there too. After the link facts it
 *  ranks the coordinator's CHECKING, UPDATING_S3 and RECONNECTING phases above the nrfup bit, so
 *  wherever the shell is uncovered the Beacon row differs from this label only for a frame that
 *  carries nrfup during one of those phases, outside the update reboot. */
internal fun statusScanPresentation(
    demo: Boolean,
    reconnecting: Boolean,
    rebootingForUpdate: Boolean,
    hasStatus: Boolean,
    bleIntent: Boolean,
    wifiIntent: Boolean,
    coAlive: Boolean?,
    nrfUpdating: Boolean,
    firmwareUpdateRunning: Boolean,
): StatusScanPresentation {
    // Sample radio switches echo into the shared synthetic status. Keep the familiar default label,
    // but reflect a one-radio or radios-off preview and park the radar when both are off.
    if (demo) {
        val label = when {
            bleIntent && wifiIntent -> "SAMPLE DATA"
            bleIntent -> "SAMPLE DATA · BLUETOOTH ONLY"
            wifiIntent -> "SAMPLE DATA · WI-FI ONLY"
            else -> "SAMPLE DATA · RADIOS OFF"
        }
        return StatusScanPresentation(
            scanning = bleIntent || wifiIntent,
            bleUpdating = false,
            bleFault = false,
            label = label,
        )
    }
    // No radio claim while the link is being restored, or while the phone's own update is
    // rebooting and confirming the board: the same window the iOS isRebootingForUpdate arm parks
    // its scan for. Every radio flag below needs both link facts clear and a frame in hand.
    val frameSpeaks = !reconnecting && !rebootingForUpdate && hasStatus
    // nrfup describes the co-processor's actual update phase, independent of whether its normal
    // scan intent was on before entering the bootloader. Faults, unlike updates, remain intent-gated.
    val bleUpdating = frameSpeaks && nrfUpdating
    val bleListening = frameSpeaks && bleIntent && coAlive != false && !nrfUpdating
    val bleFault = frameSpeaks && !firmwareUpdateRunning && bleIntent &&
        coAlive == false && !nrfUpdating
    val wifiUp = frameSpeaks && wifiIntent
    val genericFirmwareUpdate = firmwareUpdateRunning && !bleUpdating
    val scanning = !genericFirmwareUpdate && (bleListening || wifiUp)
    // The plain sentences for the non-scanning arms a connected real session can reach (see
    // [statusNotScanningLine]); the iOS beaconRadioPresentation `detail` of the same arm, verbatim.
    val updateDetail = "Keep the app open and the beacon nearby until the update finishes."
    val notScanningDetail = when {
        scanning || reconnecting || !hasStatus -> null
        rebootingForUpdate -> updateDetail
        bleUpdating -> "Bluetooth detection is paused for the update and Wi-Fi scanning is off."
        genericFirmwareUpdate -> updateDetail
        bleFault -> "The Bluetooth detection radio stopped responding and Wi-Fi scanning is off."
        else -> "Both beacon detection radios are switched off."
    }
    val label = when {
        // NOT "counts retained": every number on this screen hangs off `nearby`, which drops any
        // row older than the 45s freshness window, so the radar and the tiles reach zero 45s into
        // a reconnect. The Log keeps the rows; this header must not promise the radar does.
        reconnecting -> "RECONNECTING · BOARD STATUS UNAVAILABLE"
        // Before the missing frame, in the iOS isRebootingForUpdate arm's slot. The reboot drop
        // clears the frame, so without this the gap between the reboot's reconnect and its first
        // frame read WAITING, with no sign of the update while rollback is still armed.
        rebootingForUpdate -> "UPDATING FIRMWARE · DETECTION MAY PAUSE"
        !hasStatus -> "CONNECTED · WAITING FOR BOARD STATUS"
        // The board's own nrfup bit before the coordinator's flag, as on iOS: it is the one
        // update state that says which detector is paused and whether Wi-Fi still covers.
        bleUpdating && wifiUp -> "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR"
        bleUpdating -> "UPDATING CO-PROCESSOR · NOT SCANNING"
        genericFirmwareUpdate -> "UPDATING FIRMWARE · DETECTION MAY PAUSE"
        bleListening && wifiUp -> "SCANNING · BLE · WI-FI"
        bleFault && wifiUp -> "SCANNING · WI-FI ONLY · BLE RADIO FAULT"
        bleListening -> "SCANNING · BLE"
        wifiUp -> "SCANNING · WI-FI"
        bleFault -> "BLE RADIO FAULT · NOT SCANNING"
        else -> "RADIOS OFF · NOT SCANNING"
    }
    return StatusScanPresentation(scanning, bleUpdating, bleFault, label, notScanningDetail)
}

/** The header pill's one word. ARM ORDER IS SHARED with iOS `BeaconRadioPresentation.chipLabel`,
 *  which maps the connection label beaconRadioPresentation picked, so the pill ranks the same
 *  facts as [statusScanPresentation]: sample mode (null, so LinkChip draws SAMPLE), then the link
 *  facts (reconnecting, then the phone's own update reboot, then no frame), then an update (the
 *  board's nrfup bit or the coordinator's running flag, one word for both), then a radio fault,
 *  then CONNECTED. So after an unexpected drop the gap before the first frame reads WAITING, as
 *  on iOS, and UPDATING returns with the frame. The update reboot reads UPDATING through its whole
 *  reboot-to-confirm window, its own no-frame gap included, as iOS does through
 *  isRebootingForUpdate. The iOS chip also has words for states this screen is covered in
 *  (SECURING, BT OFF and the other not-connected states): AcabApp.kt leaves the shell uncovered
 *  only at READY or in the reconnect shell. [bleUpdating] and [bleFault] are the
 *  [StatusScanPresentation] flags, which already exclude a reconnect, the update reboot and a
 *  missing frame. Pinned in StatusBeaconPresentationTest; iOS pins its chipLabel in
 *  DashboardPresentationTests. */
internal fun statusLinkChipLabel(
    demo: Boolean,
    reconnecting: Boolean,
    rebootingForUpdate: Boolean,
    hasStatus: Boolean,
    firmwareUpdateRunning: Boolean,
    bleUpdating: Boolean,
    bleFault: Boolean,
): String? = when {
    demo -> null
    reconnecting -> "RECONNECTING"
    rebootingForUpdate -> "UPDATING"
    !hasStatus -> "WAITING"
    firmwareUpdateRunning || bleUpdating -> "UPDATING"
    bleFault -> "RADIO FAULT"
    else -> "CONNECTED"
}

/** The phone's own S3 update reboot, the link fact [statusScanPresentation] and
 *  [statusLinkChipLabel] take as rebootingForUpdate. The OTA engine enters REBOOTING at the
 *  board's done reply (or at the drop that stands in for a lost one) and CONFIRMING once the
 *  rebooted board's first frame passes the version check, and leaves them for DONE when the
 *  confirm reply lands or FAILED when the run gives up. TWIN: iOS BLEManager
 *  `isRebootingForUpdate`, true from the reboot until the rebooted board confirms or the wait is
 *  abandoned. Pinned in StatusBeaconPresentationTest. */
internal fun otaPhaseIsUpdateReboot(phase: OtaPhase): Boolean =
    phase == OtaPhase.REBOOTING || phase == OtaPhase.CONFIRMING

/** The accessibility-size stack threshold on this screen, the one RadarCountCards already used:
 *  from this fontScale the count cards (RadarCountCards) and the strongest cell (NearestCard)
 *  stack instead of sitting side by side. One value, two readers, so the two cells change shape
 *  together. */
private const val STATUS_LARGE_TEXT_STACK_SCALE = 1.5f

// Text styles on the publish-rate path, built once from the M3 type scale instead of per
// composition. Every number, telemetry line and uppercase label on this screen is the instrument
// face (R16, Theme.kt telemetry): the uppercase labels (ring words, tile labels, OFF, the count
// card titles, the no-direction caption) take the spaced capitals, as Kicker sets a label; the
// numbers and lines take none. TWIN: iOS DashboardView and RadarScope (Components.swift).
// The count keeps displayLarge's size and line height (the caller caps it, as iOS pins its own
// count with telemetryFixed at the SF size), so statusRadarCountCapDp's 64/57 is unchanged. The
// face is JetBrains Mono at Bold, not displayLarge's own Regular: the dial's one number is the
// Status hero, and both platforms draw it in the same heavy cut. Bold changes no width (a digit
// advances 0.6 em in every bundled mono cut) and no line height, so the cap and the dot obstacles hold.
// TWIN: iOS RadarScope countBlock (Components.swift), telemetryFixed(..., weight: .bold).
internal val RadarCountStyle = AcabTypography.displayLarge.tabular()
    .copy(fontFamily = JetBrainsMono, fontWeight = FontWeight.Bold)

/** The radar count's ink: the text ink while the board is [scanning], the faint ink while the
 *  sweep is parked, so a 0 over radios that are not listening does not read as a result (STA-1).
 *  On Android [Acab.text] is onSurface and [Acab.faint] is onSurfaceVariant.
 *  TWIN: iOS RadarScope countBlock (Components.swift), `sweeping ? ACABTheme.text : ACABTheme.faint`. */
internal fun radarCountInk(scanning: Boolean, palette: AcabPalette): Color =
    if (scanning) palette.onSurface else palette.onSurfaceVariant
private val RingLabelStyle = AcabTypography.labelMedium.telemetry(tracked = true)

/** The ring words and the ring each names (1 = inner, 2 = middle, 3 = the disc edge). The middle
 *  ring carries no word: the owner found WEAK and STRONG enough (2026-09-25), and the dots still
 *  snap to all three rings. TWIN: iOS `RadarScope.ringWords` in Components.swift, same words, same
 *  rings. */
internal val RADAR_RING_WORDS: List<Pair<String, Int>> = listOf("STRONG" to 1, "WEAK" to 3)

/** The Status radar's side as a share of the content column, and the cap on it. The owner cut
 *  the dial by a quarter on 2026-09-25 ("it takes up so much space"): it was the whole column up
 *  to 420dp, and is now 0.75 of the column up to 315dp (0.75 x 420), so the brand line under the
 *  caption and more of the strip reach the first screen. Everything inside the dial follows its
 *  measured size (rings, ring words, dots and their obstacles) or the side itself (the count cap,
 *  [statusRadarCountCapDp]). TWIN: iOS RadarSideLayout in Components.swift (its fraction, cap and
 *  side(column:)), which DashboardView wraps RadarScope in: the same 0.75 of the column and the
 *  same 315 cap. */
internal const val STATUS_RADAR_SIDE_FRACTION = 0.75f
internal val STATUS_RADAR_MAX_SIDE: Dp = 315.dp

/** The radar's side on a content column [column] wide: [STATUS_RADAR_SIDE_FRACTION] of it, never
 *  more than [STATUS_RADAR_MAX_SIDE]. */
internal fun statusRadarSide(column: Dp): Dp =
    minOf(column * STATUS_RADAR_SIDE_FRACTION, STATUS_RADAR_MAX_SIDE)

/** The largest rendered count size, in dp, that keeps the count block clear of STRONG's word on
 *  a dial [sideDp] wide (R7: STRONG is never below or under the count). Android derivation: the
 *  scope's 4dp top padding leaves a canvas [sideDp] wide and [sideDp] - 4 tall, so r is
 *  (sideDp - 4) / 2, and STRONG's text bottom sits r/3 + 3dp (the ring radius plus labelGapPx)
 *  above the centre. The count block is centred on the disc: the count line (RadarCountStyle,
 *  a 64sp line on a 57sp face, so 64/57 of the size) over the pinned TOTAL NEARBY caption (the
 *  16sp labelMedium line, pinned, so 16dp); its top therefore sits (64/57 x size + 16) / 2 above
 *  the centre, and the size may grow until that reaches the word. On a 268.5dp dial (a 390dp phone
 *  less two 16dp gutters, times 0.75) that is about 70dp, which the default 57sp count never
 *  reaches; a larger font scale is held there. The spoken summary is unchanged. Floored at 1dp so
 *  a degenerate dial never asks for a zero or negative size. TWIN: iOS
 *  RadarScope.countSizeCap(side:) in Components.swift, the same rule on iOS's own metrics. */
internal fun statusRadarCountCapDp(sideDp: Float): Float {
    val lineRatio = RadarCountStyle.lineHeight.value / RadarCountStyle.fontSize.value
    val caption = AcabTypography.labelMedium.lineHeight.value
    val r = (sideDp - 4f) / 2f
    return maxOf(1f, (2f * (r / 3f + 3f) - caption) / lineRatio)
}
private val TileCountStyle = AcabTypography.titleMedium.telemetry()
private val LegendCountStyle = AcabTypography.headlineSmall.telemetry()
/** The dots caption under the legend ("6 of 6 dots"). */
private val CaptionTelemetry = AcabTypography.bodySmall.telemetry()
/** The strongest cell's telemetry lines (NODE, the age, source · seen) and its signal number. */
private val BodyTelemetry = AcabTypography.bodyMedium.telemetry()
/** The two count-card titles (MATCHED + WATCHED, AMBIENT). */
private val TelegramStyle = AcabTypography.labelMedium.telemetry(tracked = true)
/** The strongest cell's "dBm" unit: a unit, not a label, so no tracking. */
private val DbmStyle = AcabTypography.labelMedium.telemetry()
/** The tile OFF line. */
private val TelegramSmallStyle = AcabTypography.labelSmall.telemetry(tracked = true)
/** The no-direction caption, measured and drawn in this one style: an uppercase label, so Medium
 *  with the spaced capitals, as Kicker sets one (iOS noDirectionPhrase). */
private val NoDirectionCaptionStyle = AcabTypography.bodySmall.telemetry(weight = FontWeight.Medium, tracked = true)

/** Status / home: the at-a-glance "how many eyes are on me" view.
 *  [onOpenLogCategory] jumps to the Log tab with the given category filter applied; the
 *  count tiles call it so a number here is one tap from its rows. The top bar (title, help,
 *  link pill) is published to MainScreen's host through [StatusTopBar]. */
@Composable
fun StatusScreen(
    ble: AcabBleManager,
    reconnecting: Boolean = false,
    onSelect: (Detection) -> Unit = {},
    onOpenLogCategory: (String) -> Unit = {},
    onOpenDetectorSettings: () -> Unit = {},
    onOpenHelp: () -> Unit = {},
) {
    val detections by ble.detections.collectAsState()
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val watchedList by ble.watched.collectAsState()
    val watchedMacs = remember(watchedList) {
        watchedList.mapTo(HashSet(watchedList.size)) { it.mac.lowercase() }
    }
    val combinedUpdate by ble.combinedProgress.collectAsState()
    // Only the reboot window, as one Boolean, mapped before collectAsState: the engine publishes a
    // new OtaProgress at every SENDING progress step, and collecting that whole would recompose
    // this screen at transfer rate for a fact that flips at most twice a run.
    // The first composition must show the phase as it stands right now, and reading a StateFlow's
    // value inside composition is a lint error (StateFlowValueCalledInComposition), so the seed is
    // taken once inside remember, the way MapScreen seeds mapEvidenceRev from spatialEvidenceRev.
    val rebootingSeed = remember(ble) { otaPhaseIsUpdateReboot(ble.otaProgress.value.phase) }
    val rebootingForUpdate by remember(ble) {
        ble.otaProgress.map { otaPhaseIsUpdateReboot(it.phase) }.distinctUntilChanged()
    }.collectAsState(initial = rebootingSeed)
    val syncing by ble.syncingOfflineLog.collectAsState()
    val syncCount by ble.offlineSyncCount.collectAsState()
    val syncTotal by ble.offlineSyncTotal.collectAsState()
    // OS-level "remove animations", read once per composition: the radar sweep parks, and the two
    // progress banners show a static icon instead of a spinner.
    val reduceMotion = rememberReduceMotion()

    // Staleness is a function of the clock, not of anything the UI observes, and eviction is
    // cap-only, so nothing recomposes this screen when a device simply stops being heard.
    // Without this tick the radar freezes at its last-publish count and a Flock heard twenty
    // minutes ago keeps holding the STRONGEST ... · RECENT cell and the TOTAL NEARBY count for
    // the rest of the session (TWIN: iOS DashboardView's tick comment names the same cue).
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            tick++
        }
    }
    // "Nearby" means heard in the last ~45s. Offline rows are the board's buffer replayed, never
    // a live sighting, so they're out regardless of how fileHistory happened to stamp them.
    // Demo rows are exempt: they're a fixture stamped once at seed time, and ageing them out
    // would empty the tour's radar 45s in.
    //
    // freshIdSet, not isStale per row: this block re-runs on every ~3 Hz publish AND on the tick,
    // over the whole active feed, so the per-row form took storeLock up to FEED_CAP times a pass
    // on the main thread - the same monitor the BLE thread holds for every arriving advert. One
    // locked pass instead, the way LogScreen already reads newIdSet. Same window, same one-sided
    // comparison, so the radar counts exactly what it counted before.
    val nearby = remember(detections, tick, demo) {
        if (demo) detections else {
            val fresh = ble.freshIdSet(detections)
            detections.filter { !it.offline && it.id in fresh }
        }
    }
    val nearbySummary = remember(nearby, watchedMacs) { statusNearbySummary(nearby, watchedMacs) }
    val nearest = nearbySummary.strongest
    val nearestAge = remember(nearest?.id, detections, tick, demo) {
        statusLastHeardAge(
            lastSeenAtMs = nearest?.let { if (demo) null else ble.lastSeen(it.id) },
            nowMs = System.currentTimeMillis(),
            demo = demo,
        )
    }

    // The tiles sit directly under the radar's TOTAL NEARBY count, so they have to measure the
    // same thing. Off the whole store they were session totals, and the strip could read
    // "ALPR 3" under a radar honestly reporting 0 nearby. One grouped pass whenever `nearby`
    // changes, instead of an O(n) scan per tile per recomposition. remember compares its key
    // with equals and Detection is a data class,
    // so a publish that adds, drops or changes a fresh row regroups, and so does a tick that ages
    // one out, while a quiet tick pays at most that O(n) list comparison.
    val typeCounts = remember(nearby) { nearby.groupingBy { it.type }.eachCount() }
    fun count(type: DeviceType) = typeCounts[type] ?: 0

    // The scan line tracks radio state so it never claims a scan that isn't happening.
    // status.ble/status.wifi are toggle INTENT, not liveness: on a dual-radio board a dead nRF
    // leaves status.ble true while the whole BLE half is dark, so coAlive is what says it's
    // actually listening (single-radio boards omit it, hence != false rather than == true).
    // A null status is "no frame yet", not proof that either radio is live. It gets a waiting
    // label and a parked sweep until the board supplies a frame.
    val s = status
    // No frame YET, not "no board": this screen only exists once the link is READY, and the
    // first status frame still has to cross the link (finishReady's queued read sits behind the
    // handshake writes, and the board's connect-time notify is async), so there is a real gap on
    // every connect. The page remains usable in that gap, while the animation waits for evidence.
    // A nRF mid BLE DFU is silent on purpose (it reboots into its bootloader), which reads as
    // coAlive == false through no fault of the radio. nrfUpdating is the board saying so, so an
    // update in flight gets its own line instead of the amber "radio fault" one.
    val scan = statusScanPresentation(
        demo = demo,
        reconnecting = reconnecting,
        rebootingForUpdate = rebootingForUpdate,
        hasStatus = s != null,
        bleIntent = s?.ble == true,
        wifiIntent = s?.wifi == true,
        coAlive = s?.coAlive,
        nrfUpdating = s?.nrfUpdating == true,
        firmwareUpdateRunning = combinedUpdate.isRunning,
    )
    val scanning = scan.scanning
    val bleUpdating = scan.bleUpdating
    val bleFault = scan.bleFault
    val scanLabel = scan.label
    val linkStateLabel = statusLinkChipLabel(
        demo = demo,
        reconnecting = reconnecting,
        rebootingForUpdate = rebootingForUpdate,
        hasStatus = s != null,
        firmwareUpdateRunning = combinedUpdate.isRunning,
        bleUpdating = bleUpdating,
        bleFault = bleFault,
    )
    // The value the LinkChip is handed, and the first-zero line's `connected`, by construction
    // (iOS DashboardView uses one value for both the same way).
    val linkConnected = !reconnecting && s != null

    // Unconditional, after the link facts it draws and before any content. Primitives only, so
    // the bar skips at the feed rate and the host's slot is not rebuilt ~3 times a second.
    StatusTopBar(
        version = s?.version,
        demo = demo,
        connected = linkConnected,
        linkStateLabel = linkStateLabel,
        onOpenHelp = onOpenHelp,
    )

    // T2: cap readable content width so tablets/landscape stop stretching one column edge to
    // edge; at phone width the 640 cap is a no-op. Box scrolls + centers, inner Column is capped.
    Box(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        contentAlignment = Alignment.TopCenter,
    ) {
    Column(
        Modifier
            .widthIn(max = 640.dp)
            .fillMaxWidth()
            .padding(horizontal = Acab.pad)
            .padding(bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // The scan line, then the recency note at the far end. No dot: the words carry the
        // liveness (they say RADIOS OFF, WAITING or a fault outright), and with Wi-Fi up and the
        // nRF dead the scan still reads as scanning, so amber on the words is what separates that
        // state from a healthy scan at a glance.
        // In sample data the bare SAMPLE DATA line is not drawn (statusScanKicker); the recency
        // note is live-only, so the whole row goes with it.
        val scanKicker = statusScanKicker(scanLabel, demo)
        if (scanKicker != null) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Box(Modifier.weight(1f)) {
                Kicker(scanKicker, color = if (bleFault) Acab.warn else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            // Far-right recency note: everything on the radar / in the counts was heard within the
            // ~45s "nearby" window (ble.freshIdSet), so say so - only when there's actually something up.
            if (!demo && nearby.isNotEmpty()) {
                Spacer(Modifier.width(8.dp))
                Kicker(STATUS_SEEN_WINDOW_KICKER)
            }
        }

        if (bleFault) CoprocFaultBanner() else if (bleUpdating) CoprocUpdatingBanner(reduceMotion)

        // While the board replays its offline buffer on reconnect: a non-blocking banner.
        // determinate once the board's hist lead-in supplies a total; a live count until then.
        if (syncing) SyncingBanner(count = syncCount, total = syncTotal, reduceMotion = reduceMotion)

        // The disc, with the no-direction caption directly under it (C9), then the brand line.
        // The scope is 0.75 of the column up to 315dp (statusRadarSide), centred, so it neither
        // fills a phone's first screen nor stretches screen-wide on tablets (T2).
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                RadarScope(summary = nearbySummary, scanning = scanning, reduceMotion = reduceMotion,
                    side = statusRadarSide(maxWidth))
            }
            // The one fact that stops the radar being read as a direction finder, always rendered
            // and read right where the eye leaves the disc.
            NoDirectionCaption()
            // The brand line, back under the caption by the owner's call on 2026-09-25 so it sits
            // on the first screen, as it did before the redesign dropped it (C8). 8dp more than
            // the column's spacing, so it reads as its own line and not a third caption phrase.
            PunkLine(Modifier.padding(top = 8.dp))
        }

        // SECTION ORDER IS SHARED with iOS DashboardView (its body's content VStack), per C9 and
        // the owner's 2026-09-25 call: radar, the no-direction caption, the brand line, the
        // category strip, the strongest cell, then the legend cell. The first three are the
        // Column above (RadarScope, then NoDirectionCaption, then PunkLine); below this line
        // come the strip (CountTile rows), the strongest slot (NearestCard, or the
        // statusFirstZeroLine / statusNotScanningLine text when a connected real session has
        // nothing in the window), then RadarLegend (count cards, the unclassified line and the
        // watched tap as one cell, with the two caption lines as its last rows; iOS draws those
        // two under the cell). No "Look around" row. The scope is 0.75 of the column
        // (statusRadarSide) and still the largest thing on a 390dp phone's first screen, so the
        // counts, the verdict and the taps they lead to (Log, dossier) come before the legend,
        // which can scroll. Reorder one side only and the other side's comment becomes a lie.

        // per-category counts: one strip of compact tiles. Which tiles, in what order, drawn
        // and spoken as what, and counting which types, is STATUS_STRIP_TILES (where the iOS twin
        // is named); this only draws them. Network Cam gets a tile, as it gets a category in the
        // Log filter and the Map chips, so Status shows every category the other tabs do
        // (netcamTone + CameraOutdoor come from the type's own tone()/icon(), like every other
        // tile here). Each tile deep-links to the Log
        // with that category's filter, so a count is one tap from its rows. The strip wraps to
        // rows of three as soon as the widest label no longer fits a six-across tile, and to rows
        // of two after that (rememberCategoryTilesPerRow measures it), so labels stay whole at
        // every Android font scale.
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val perRow = rememberCategoryTilesPerRow(STATUS_STRIP_TILES.map { it.label }, maxWidth,
                STATUS_STRIP_TILES.size, labelStyle = CategoryTileTelemetryLabelStyle)
            Column(verticalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                STATUS_STRIP_TILES.chunked(perRow).forEach { rowTiles ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                        rowTiles.forEach { t ->
                            val n = t.counted.sumOf { count(it) }
                            // null before the first frame: not off, not on, just unknown.
                            val enabled = status?.let(t.toggle)
                            CountTile(t.type, t.label, t.spoken, n, enabled, Modifier.weight(1f)) {
                                when (statusCountTileDestination(n, enabled)) {
                                    StatusCountTileDestination.LOG -> onOpenLogCategory(t.type.category)
                                    StatusCountTileDestination.DETECTOR_SETTINGS -> onOpenDetectorSettings()
                                }
                            }
                        }
                        repeat(perRow - rowTiles.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }

        // The strongest slot: the strongest recent sighting, or, on a connected real session
        // with nothing in the window, what zero means instead of an empty slot: the quiet
        // sentence while the board scans (statusFirstZeroLine), or why it is not scanning while
        // the sweep is parked (statusNotScanningLine), so a 0 over dead radios never reads as an
        // all-clear. No header on the empty state: there is no sighting to name.
        if (nearest != null) {
            NearestCard(
                d = nearest,
                age = nearestAge,
                kind = nearbySummary.strongestKind ?: StatusStrongestKind.AMBIENT,
                demo = demo,
                onSelect = onSelect,
            )
        } else {
            (statusFirstZeroLine(connected = linkConnected, demo = demo, scanning = scanning,
                total = nearbySummary.total)
                ?: statusNotScanningLine(connected = linkConnected, demo = demo, scanning = scanning,
                    total = nearbySummary.total, notScanningDetail = scan.notScanningDetail))?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                )
            }
        }

        RadarLegend(summary = nearbySummary, onOpenLogCategory = onOpenLogCategory)
    }
    }
}

/** The C9 no-direction caption literal: the one spoken label of [NoDirectionCaption] and the
 *  source of its two drawn phrases. TWIN: iOS DashboardView.noDirectionCaption. */
internal const val STATUS_NO_DIRECTION_CAPTION = "SIGNAL STRENGTH ONLY · NO DIRECTION"
/** The caption's two phrases, split once at file level, never per composition. */
private val STATUS_NO_DIRECTION_PHRASES = STATUS_NO_DIRECTION_CAPTION.split(" · ")

/** The no-direction caption under the disc. On one line when the whole literal fits the width;
 *  otherwise its two phrases stack as two centred lines, without the dot, so a large font scale
 *  never splits NO from DIRECTION or starts a line with the separator. TWIN: iOS
 *  DashboardView.noDirectionCaption (ViewThatFits: the whole literal as one Text on one line, then
 *  a centred VStack of the same two phrases). TalkBack reads the full literal once either way. No parameters, so it
 *  skips when the Status body recomposes at the publish rate; the literal is measured once per
 *  style and font scale. */
@Composable
private fun NoDirectionCaption() {
    val style = NoDirectionCaptionStyle
    val ink = MaterialTheme.colorScheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val fontScale = LocalDensity.current.fontScale
    val oneLineWidth = remember(measurer, style, fontScale) {
        measurer.measure(AnnotatedString(STATUS_NO_DIRECTION_CAPTION), style, softWrap = false).size.width
    }
    BoxWithConstraints(
        Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = STATUS_NO_DIRECTION_CAPTION },
        contentAlignment = Alignment.Center,
    ) {
        if (oneLineWidth <= constraints.maxWidth) {
            Text(STATUS_NO_DIRECTION_CAPTION, color = ink, style = style, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth())
        } else {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                STATUS_NO_DIRECTION_PHRASES.forEach { phrase ->
                    Text(phrase, color = ink, style = style, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** The brand line's face: Space Grotesk Medium, the face the line had before the redesign (HEAD's
 *  Acab.display at FontWeight.Medium). The TTF never left res/font, which C4 kept for the widget
 *  layouts; this line is the only Compose text drawn in it. The rest of the app is Roboto (C4),
 *  apart from the connect wordmark (Space Grotesk Bold, Theme.kt WordmarkFace) and the instrument
 *  layer (JetBrains Mono, R16, Theme.kt telemetry). */
private val PunkLineFace = FontFamily(Font(R.font.space_grotesk_medium, FontWeight.Medium))

/** "they're watching. watch back." The brand line, back on Status by the owner's call on
 *  2026-09-25 (C8 had dropped it), directly under the no-direction caption. As before the
 *  redesign: "they're watching." in the dim ink (onSurfaceVariant, Acab.dim), "watch back." in
 *  the crimson text ink (primary, Acab.accentText) and italic, Space Grotesk Medium at 14sp.
 *  Pinned against fontScale (divide by it) like iOS: this is brand ornament, not information,
 *  and at accessibility sizes it wrapped into the layout's budget while carrying nothing a screen
 *  reader or low-vision user needs larger. One Text over one AnnotatedString, so TalkBack stops
 *  on it once, after the caption and before the strip, as VoiceOver reads the iOS twin's single
 *  Text. TWIN: iOS PunkLine in Components.swift. No state parameters, so it skips when the Status
 *  body recomposes at the publish rate. */
@Composable
private fun PunkLine(modifier: Modifier = Modifier) {
    val fs = LocalDensity.current.fontScale
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    // The vivid crimson (AcabPalette.crimsonInk, the iOS tint, shared with the Beacon hero), not
    // M3 primary, and upright: the owner's reference shows the old vivid crimson, and iOS draws
    // this face upright.
    val crimson = Acab.palette.crimsonInk
    // Keyed on the two inks it bakes, so a contrast switch rebuilds it.
    val line = remember(dim, crimson) {
        buildAnnotatedString {
            withStyle(SpanStyle(color = dim)) { append("they're watching. ") }
            withStyle(SpanStyle(color = crimson)) { append("watch back.") }
        }
    }
    Text(line, modifier.fillMaxWidth(), fontSize = 14.sp / fs, fontFamily = PunkLineFace,
        fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
}

/** The Status tab's top bar, published to MainScreen's host (C7): the title, the help action,
 *  then the link pill (contracts 4.1 order). Takes only the link facts it draws, never the feed
 *  or the tick, so it skips while the ~3 Hz body recomposes around it. The title ellipsizes like
 *  the Beacon bar's: help plus the pill is the same footprint the Beacon bar keeps at large font
 *  scales (its refresh moves into the overflow there), so no action moves here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StatusTopBar(
    version: String?,
    demo: Boolean,
    connected: Boolean,
    linkStateLabel: String?,
    onOpenHelp: () -> Unit,
) {
    TabTopBar {
        TopAppBar(
            title = {
                Text("Status", Modifier.semantics { heading() },
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            },
            actions = {
                IconButton(onClick = onOpenHelp) {
                    Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = "help and support")
                }
                LinkChip(version = version, demo = demo, connected = connected, stateLabel = linkStateLabel)
                Spacer(Modifier.width(12.dp))
            },
        )
    }
}

/** Where each radar dot is drawn, as x/y pairs ([x0, y0, x1, y1, ...]) in the scope's own pixels.
 *
 *  Input, in priority order (summary.dots: watched and matched first, then strongest signal):
 *  each dot's hash angle in degrees ([angleDeg], a stable MAC hash that carries no bearing) and
 *  the radius of the ring its signal band snaps to ([ringRadius]). The priority dot is placed
 *  first and keeps its hash angle whenever that spot is free; every later dot that would land
 *  within one dot diameter of a dot already placed, or would touch one of the [obstacles] (the
 *  TOTAL NEARBY count block and the two ring words (RADAR_RING_WORDS), each a bare text frame),
 *  steps along its own ring by one dot
 *  diameter of arc, (2 * [dotRadius]) / ringRadius radians, until it is clear. Deterministic: the
 *  same inputs always give the same picture, so dots do not jitter between publishes. If a ring
 *  has no clear spot left, the dot keeps its hash angle (an overlap then, never a missing dot).
 *  The caller draws the list in REVERSE, so the priority dot paints last and is never covered.
 *
 *  Pure and allocation-light on purpose: RadarScope runs it in composition, remembered on the dot
 *  list and the measured geometry, never in the draw lambda that runs every sweep frame. TWIN: iOS
 *  RadarScope.dotPositions(angles:ringRadii:centre:dotRadius:obstacles:) in Components.swift, the
 *  same rule step for step, which also draws its dots reversed and above its ring words. Pinned in
 *  StatusRadarScopeSemanticsTest. */
internal fun radarDotPositions(
    angleDeg: IntArray,
    ringRadius: FloatArray,
    cx: Float,
    cy: Float,
    dotRadius: Float,
    obstacles: List<Rect>,
): FloatArray {
    val n = angleDeg.size
    val out = FloatArray(n * 2)
    val minGap = 2f * dotRadius
    fun clear(i: Int, x: Float, y: Float): Boolean {
        for (j in 0 until i) {
            val dx = out[2 * j] - x
            val dy = out[2 * j + 1] - y
            if (dx * dx + dy * dy < minGap * minGap) return false
        }
        for (k in obstacles.indices) {
            val o = obstacles[k]
            val nx = x.coerceIn(o.left, o.right) - x
            val ny = y.coerceIn(o.top, o.bottom) - y
            if (nx * nx + ny * ny < dotRadius * dotRadius) return false
        }
        return true
    }
    for (i in 0 until n) {
        val rad = ringRadius[i]
        val base = angleDeg[i] * (PI / 180.0)
        val step = if (rad > 0f) minGap / rad.toDouble() else 0.0
        val tries = if (step > 0.0) (2.0 * PI / step).toInt() else 0
        var placed = false
        for (t in 0..tries) {
            val a = base + t * step
            val x = cx + (cos(a) * rad).toFloat()
            val y = cy + (sin(a) * rad).toFloat()
            if (clear(i, x, y)) {
                out[2 * i] = x
                out[2 * i + 1] = y
                placed = true
                break
            }
        }
        if (!placed) {
            out[2 * i] = cx + (cos(base) * rad).toFloat()
            out[2 * i + 1] = cy + (sin(base) * rad).toFloat()
        }
    }
    return out
}

/** One radar sweep revolution, shared with iOS (RadarScope.sweepPeriod = 4.5 s in
 *  Components.swift; 4_500 ms here, scale 1000). */
internal const val RADAR_SWEEP_PERIOD_MS = 4_500L

/** The sweep angle at an ABSOLUTE clock reading: fract(t / period) x 360 degrees, clockwise on
 *  screen (positive angle, y down), negative times wrapped by floorMod. Absolute, never measured
 *  from when this scope entered composition, so a tab return, a re-created scope or a scanning
 *  flag that drops and returns continues the phase instead of restarting at 0 (M3). TWIN: iOS
 *  radarSweepDegrees(at:period:) in Components.swift, same period and direction. */
internal fun radarSweepDegrees(timeMs: Long, periodMs: Long = RADAR_SWEEP_PERIOD_MS): Float =
    Math.floorMod(timeMs, periodMs).toFloat() / periodMs * 360f

/** Radar: a filled disc, three rings, a crosshair, a rotating crimson sweep, and up to fourteen
 *  prioritized dots, each on a disc-coloured knockout ring. The ring words and the count block sit
 *  straight on the disc, with the crosshair, the rings and the sweep running behind their letters
 *  (R18: the owner read the R7 plates as an outline around the words, so they are gone, and the
 *  words draw as 2.0.8 drew them). Rings are honest: blips snap to the ring of
 *  their signal band (strong, middle, weak; only STRONG and WEAK are labelled, RADAR_RING_WORDS),
 *  and the no-direction caption the caller draws directly under the disc says outright that the
 *  angle (a stable MAC hash) carries no bearing.
 *  [summary] is built from the nearby set, already filtered for staleness by the caller; the count
 *  in the middle is exact even when the intentionally bounded blips cannot show every row. The sweep only turns
 *  while [scanning], since a sweeping radar over a dead radio reads as a live all-clear. The dial
 *  only: the legend is [RadarLegend], placed by the caller after the strip and the strongest cell.
 *  [side] is the dial's width ([statusRadarSide]); the count's size cap is derived from it. */
@Composable
private fun RadarScope(
    summary: StatusNearbySummary,
    scanning: Boolean,
    reduceMotion: Boolean,
    side: Dp,
    modifier: Modifier = Modifier,
) {
    // The sweep angle is written once per frame from the frame clock and read ONLY inside the
    // Canvas draw lambda below, so a frame invalidates the draw and recomposes nothing. The frame
    // clock (Choreographer's frame time) is monotonic and shared by every composition, so the
    // phase is a function of the clock, not of this scope's lifetime: leaving the tab and coming
    // back, or scanning dropping and returning, continues the turn instead of restarting it at 0
    // (the old rememberInfiniteTransition restarted from 0 on every entry, and kept ticking while
    // parked). The loop runs only while scanning and motion is allowed; under reduce-motion no
    // loop runs at all and the wedge draws parked at 0, so the scope keeps its look.
    // TWIN: iOS SweepBeam (Components.swift), a TimelineView on the same radarSweepDegrees rule
    // and the same RADAR_SWEEP_PERIOD_MS / RadarScope.sweepPeriod.
    // Seeded from System.nanoTime, the base Choreographer's frame times use, so the first draw
    // after entering the tab (before the loop's first frame) already sits at the clock's phase
    // rather than at 0; the loop re-seeds the same way when scanning resumes.
    var sweepAngle by remember { mutableFloatStateOf(radarSweepDegrees(System.nanoTime() / 1_000_000)) }
    LaunchedEffect(scanning, reduceMotion) {
        if (!scanning || reduceMotion) return@LaunchedEffect
        sweepAngle = radarSweepDegrees(System.nanoTime() / 1_000_000)
        while (true) withFrameNanos { sweepAngle = radarSweepDegrees(it / 1_000_000) }
    }
    val dots = summary.dots

    // Palette roles are read here, in composition, and captured by the draw lambda. The disc,
    // rings, edge and sweep are the radar-only tokens (AcabPalette.radarDisc and friends): the
    // pre-redesign instrument colours the owner kept on 2026-09-25 over the Route A grey disc
    // (surfaceContainer, outlineVariant rings, primary at 0.28). Acab.palette is snapshot state,
    // so a contrast switch recomposes this scope with the other level's four. The text inks
    // stay scheme roles. TWIN: iOS RadarScope in Components.swift reads ACABPalette's radarDisc /
    // radarRing / radarEdge / radarSweep; each platform keeps its OWN old sweep (here the old
    // accentGlow, plain SrcOver; iOS the accent at 0.40 with a screen blend).
    val scheme = MaterialTheme.colorScheme
    val radar = Acab.palette
    val disc = radar.radarDisc
    val ringInk = radar.radarRing
    val edgeInk = radar.radarEdge
    val labelInk = scheme.onSurfaceVariant
    val sweepInk = radar.radarSweep

    // Ring words (RADAR_RING_WORDS): STRONG and WEAK on the vertical axis above centre, drawn
    // straight on the disc with no plate behind them: STRONG just above the inner ring, WEAK just
    // inside the disc edge; the middle ring has no word. The count block is centred on the disc.
    // TWIN: iOS RadarScope.ringLabels in Components.swift, which states the same placement. The
    // crosshair, the rings and the sweep run under the letters (R18; the R7 plates read as an
    // outline around each word once R10 brought the old disc colour and the crosshair back).
    //
    // THESE ARE STRENGTH WORDS, NOT DISTANCE WORDS. They were NEAR / MID / FAR until 2026-09-08,
    // which labelled a signal-strength quantity with distance, and the screen then had to walk it
    // back twice on itself (the SIGNAL STRENGTH ONLY - NO DIRECTION caption, then
    // STATUS_RADAR_CAPTION_DETAIL). RSSI is not distance, because transmit power is a per-DEVICE
    // choice (faq-content.json q-signal): a pole-mounted ALPR camera reads strong from across a
    // street while a tracking tag a few meters away reads weak. The vocabulary is the one
    // BoardRow already speaks for rssiBars, so the ring a blip sits on and the spoken word for its
    // bars cannot disagree. Do not put NEAR / MID / FAR back. TWIN: iOS RadarScope.ringLabels in Components.swift.
    //
    // Ornamental dial
    // furniture, so the size is divided back out of the font scale: at 2x text these labels
    // would collide with the rings and the center count, and they carry no information the
    // caption below does not restate.
    //
    // Keyed on the colour it bakes: the layouts carry labelInk, so a contrast switch (a new
    // onSurfaceVariant) re-measures them instead of keeping stale-coloured labels on the dial.
    val density = LocalDensity.current
    val fontScale = density.fontScale
    val measurer = rememberTextMeasurer()
    val ringLabels = remember(measurer, fontScale, labelInk) {
        val style = RingLabelStyle.copy(
            color = labelInk,
            fontSize = RingLabelStyle.fontSize / fontScale,
            lineHeight = RingLabelStyle.lineHeight / fontScale,
            letterSpacing = RingLabelStyle.letterSpacing / fontScale,
        )
        RADAR_RING_WORDS.map { (word, ring) -> ring to measurer.measure(AnnotatedString(word), style) }
    }

    // Hoisted out of the draw lambda, which runs at display refresh rate while the sweep turns:
    // Brush.sweepGradient boxes every stop into a Pair and the ring style was a fresh Stroke per
    // ring, so the scope allocated on every animation frame. The gradient bakes exactly one
    // palette colour (radarSweep, which differs between the two contrast levels), so that colour
    // is its key. No size key: the center is left Unspecified, which SweepGradient resolves to
    // the center of the DrawScope at draw time, the same point as the `c` computed in the
    // lambda, and ShaderBrush re-creates its Shader itself when the size it was last applied at
    // changes.
    val sweepBrush = remember(sweepInk) {
        Brush.sweepGradient(
            0.72f to Color.Transparent,
            0.99f to sweepInk,
            1.0f to Color.Transparent,
        )
    }
    // Density is the only input these bake: the 1 dp ring and crosshair stroke, the two label
    // offsets (WEAK sits this far inside the disc edge, STRONG this far outside its ring), and
    // the dot's knockout ring and core radii. The draw lambda then calls no dp.toPx() at all.
    val hairline = remember(density) { Stroke(with(density) { 1.dp.toPx() }) }
    val labelInsetPx = remember(density) { with(density) { 4.dp.toPx() } }
    val labelGapPx = remember(density) { with(density) { 3.dp.toPx() } }
    val dotRingPx = remember(density) { with(density) { 6.dp.toPx() } }
    val dotCorePx = remember(density) { with(density) { 4.dp.toPx() } }
    // The count scales with the font scale (it is the dial's one piece of real content) until it
    // would reach STRONG's word (statusRadarCountCapDp); from there it holds, font size and line
    // height together, so the block's measured height stays the derivation's 64/57 of the size.
    // Both directions go through the density's own sp/dp conversion, never size x fontScale:
    // Android 14+ scales large text nonlinearly (57sp at font scale 2.0 renders well under
    // 114dp), so a linear estimate overshoots and the cap would draw the count SMALLER at 2.0
    // than at 1.0.
    val countStyle = remember(side, density) {
        val capDp = statusRadarCountCapDp(side.value)
        val renderedDp = with(density) { RadarCountStyle.fontSize.toDp() }.value
        if (renderedDp <= capDp) RadarCountStyle
        else with(density) {
            val lineRatio = RadarCountStyle.lineHeight.value / RadarCountStyle.fontSize.value
            RadarCountStyle.copy(fontSize = capDp.dp.toSp(), lineHeight = (capDp * lineRatio).dp.toSp())
        }
    }

    // The measured geometry the dot placement avoids: the canvas, the count number and the TOTAL
    // NEARBY caption (the count Column is centred on the disc, so their rects follow from the
    // sizes). Written from onSizeChanged, so they settle after the first layout and stay put.
    var canvasSize by remember { mutableStateOf(IntSize.Zero) }
    var countSize by remember { mutableStateOf(IntSize.Zero) }
    var captionSize by remember { mutableStateOf(IntSize.Zero) }
    // Dot positions, in composition and remembered: radarDotPositions walks each dot along its
    // ring, which is cheap per publish (~3 Hz, at most fourteen dots) but must never run per
    // sweep frame. The obstacles are the count number, the TOTAL NEARBY caption and the two
    // ring words, each the bare text's frame (no plate padding since R18), computed exactly as
    // the draw lambda below places them.
    val dotXY = remember(dots, canvasSize, countSize, captionSize, ringLabels, labelInsetPx,
        labelGapPx, dotRingPx) {
        val w = canvasSize.width.toFloat()
        val h = canvasSize.height.toFloat()
        val r = minOf(w, h) / 2f
        val cx = w / 2f
        val cy = h / 2f
        val obstacles = ArrayList<Rect>(4)
        val blockH = (countSize.height + captionSize.height).toFloat()
        val blockTop = cy - blockH / 2f
        obstacles += Rect(cx - countSize.width / 2f, blockTop, cx + countSize.width / 2f,
            blockTop + countSize.height)
        obstacles += Rect(cx - captionSize.width / 2f, blockTop + countSize.height,
            cx + captionSize.width / 2f, blockTop + blockH)
        for (i in ringLabels.indices) {
            val ring = ringLabels[i].first
            val lw = ringLabels[i].second.size.width.toFloat()
            val lh = ringLabels[i].second.size.height.toFloat()
            val ringR = r * ring / 3f
            val y = if (ring == 3) cy - ringR + labelInsetPx else cy - ringR - lh - labelGapPx
            obstacles += Rect(cx - lw / 2f, y, cx + lw / 2f, y + lh)
        }
        radarDotPositions(
            angleDeg = IntArray(dots.size) { abs(dots[it].row.mac.hashCode()) % 360 },
            ringRadius = FloatArray(dots.size) {
                val bars = rssiBars(dots[it].row.rssi)
                when {
                    bars >= 4 -> r / 3f
                    bars == 3 -> r * 2f / 3f
                    else -> r - dotRingPx
                }
            },
            cx = cx, cy = cy, dotRadius = dotRingPx, obstacles = obstacles,
        )
    }

    Box(
        modifier
            .width(side)
            .aspectRatio(1f)
            .padding(top = 4.dp)
            .onSizeChanged { canvasSize = it }
            // One spoken element for the whole instrument, as the iOS scope is: the count and
            // its kicker fold into this node, and the sentence replaces the bare number
            // TalkBack read before.
            .semantics(mergeDescendants = true) {
                contentDescription = summary.radarContentDescription
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val r = size.minDimension / 2f
            val c = Offset(size.width / 2f, size.height / 2f)

            // the disc, then rings at a third and two thirds, then the crimson edge ring on the
            // disc edge itself (ring 3), inset half a stroke so the canvas does not clip it
            drawCircle(disc, r, c)
            for (i in 1..2) {
                drawCircle(ringInk, r * i / 3f, c, style = hairline)
            }
            drawCircle(edgeInk, r - hairline.width / 2f, c, style = hairline)

            // the pre-redesign crosshair, back by the owner's call on 2026-09-25: one vertical and
            // one horizontal hairline through the centre, each the full disc diameter, in the ring
            // ink. Drawn right after the rings, so the sweep, the ring words, the dots and the
            // count block all sit over it; the vertical line runs on under the letters of STRONG,
            // WEAK and TOTAL NEARBY, as it did in 2.0.8 (R18 removed the plates that masked it).
            // It is NOT a dot-placement obstacle (dotXY): dots may sit on it, as they did before.
            // TWIN: iOS RadarScope's crosshair Path in Components.swift.
            drawLine(ringInk, Offset(c.x, c.y - r), Offset(c.x, c.y + r), hairline.width)
            drawLine(ringInk, Offset(c.x - r, c.y), Offset(c.x + r, c.y), hairline.width)

            // rotating sweep, a crimson wedge under the labels and the dots. Reading
            // `sweepAngle` inside the branch means a parked radar also stops re-drawing at 60fps,
            // not just stops lying (and its frame loop is stopped too). With reduce-motion on, no
            // loop runs and the wedge draws once, parked at 0.
            if (scanning) {
                rotate(if (reduceMotion) 0f else sweepAngle, c) {
                    drawArc(
                        brush = sweepBrush,
                        startAngle = 0f, sweepAngle = 360f, useCenter = true,
                        topLeft = Offset(c.x - r, c.y - r), size = Size(r * 2, r * 2),
                    )
                }
            }

            // ring labels, placed as the ringLabels comment above states (TWIN: iOS
            // RadarScope.ringLabels): WEAK sits just inside the disc edge so it doesn't clip at
            // the canvas edge, STRONG just above the inner ring's top point. The bare text only,
            // over the crosshair, the rings and the sweep (R18: no plate).
            // Index loops here and over the dots: withIndex() and the List iterator allocate per
            // frame.
            for (i in ringLabels.indices) {
                val ring = ringLabels[i].first
                val layout = ringLabels[i].second
                val w = layout.size.width.toFloat()
                val h = layout.size.height.toFloat()
                val ringR = r * ring / 3f
                val x = c.x - w / 2f
                val y = if (ring == 3) c.y - ringR + labelInsetPx else c.y - ringR - h - labelGapPx
                drawText(layout, topLeft = Offset(x, y))
            }

            // one blip per detection: angle from the MAC (stable), radius snapped
            // to the ring of its signal band (bars 4 = strong, 3 = good, weaker = weak, drawn
            // just inside the disc edge, pulled in by the dot's own 6 dp ring radius, so the whole
            // dot stays on the disc). TWIN: iOS DashboardView.ringRadius and RadarScope in
            // Components.swift, which caps a dot's centre at s/2 less the iOS dot's own radius
            // (RadarScope.dotSize) for the same reason. The positions come from dotXY
            // (radarDotPositions: nudged along the ring off each other, the count block and the
            // ring words). Dots draw above the ring words, and in REVERSE priority order, so the
            // watched or strongest dot paints last and nothing covers it.
            // A starred row keeps its real category type, so the gold comes from the dot's
            // watched flag, not from the type (iOS DashboardView draws it the same way).
            // downTo compiles to a plain int loop (no progression per frame). Nothing is drawn
            // until the first layout has measured the canvas, so dots never flash at the corner.
            if (canvasSize != IntSize.Zero && dotXY.size == dots.size * 2) for (i in dots.size - 1 downTo 0) {
                val dot = dots[i]
                val d = dot.row
                val pos = Offset(dotXY[2 * i], dotXY[2 * i + 1])
                val tone = if (dot.watched) Acab.watchTone else d.type.tone()
                // a disc-coloured ring under a solid core, so a dot stays distinct over the sweep
                // and over a neighbouring dot
                drawCircle(disc, dotRingPx, pos)
                drawCircle(tone, dotCorePx, pos)
            }
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            // Text ink while scanning, faint ink while the sweep is parked ([radarCountInk]).
            // Read from Acab.palette (`radar`), the same instance the scheme is built from.
            // TWIN: iOS RadarScope countBlock in Components.swift (its `sweeping` flag draws the
            // count faint).
            Text("${summary.total}", color = radarCountInk(scanning, radar),
                style = countStyle, modifier = Modifier.onSizeChanged { countSize = it })
            // TOTAL NEARBY covers matched/watched AND ambient devices, which the cards below
            // split apart. It is still a RECENT count (already filtered for staleness), not the
            // whole-Log total, which is why it reads lower than the Log's own count. Twin
            // comment: the TOTAL NEARBY caption on the iOS dial (RadarScope in Components.swift)
            // says the same thing.
            // pinned: the caption is an ornament under a 57sp (displayLarge) number that already
            // scales; iOS pins it the same way (a fixed size, off the Dynamic Type curve) so the
            // dial composition holds at large font scales.
            // Straight on the disc, no plate: the crosshair and the sweep run under its words
            // (R18). The Box only measures the caption for the dot obstacles (captionSize).
            Box(Modifier.onSizeChanged { captionSize = it }) {
                Kicker("TOTAL NEARBY", pinned = true, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

/** Everything that explains the dial, as one grouped cell (twin: iOS DashboardView.radarLegend):
 *  the count cards that split TOTAL NEARBY, the two conditional lines, then the two caption
 *  lines. Here the captions close the cell, centred; iOS draws them as the cell's footer, outside
 *  the cell and leading-aligned. That is a settled platform idiom, not drift: an M3 card has no
 *  footer slot, and an iOS grouped cell takes one (the iOS SECTION ORDER comment in
 *  DashboardView records the same difference). Every
 *  card and line word is the presentation's (STATUS_MATCHED_CARD_TITLE and friends,
 *  [StatusNearbySummary.unclassifiedLine] /
 *  [StatusNearbySummary.watchedLine], [StatusNearbySummary.radarCaption],
 *  STATUS_RADAR_CAPTION_DETAIL), where the iOS twins are named; only the watched tap's click
 *  label is written here. Same tones as iOS: crimson (primary, the text-safe tint) for the match
 *  card, onSurfaceVariant for ambient and for the unclassified line, the watched tint for the
 *  watched tap. The no-direction caption is not here: it sits directly under the disc. */
@Composable
private fun RadarLegend(summary: StatusNearbySummary, onOpenLogCategory: (String) -> Unit) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    GroupedCard {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            RadarCountCards(summary)
            summary.unclassifiedLine?.let { line ->
                // Dim on purpose: a wire type this build does not know is a fact to report, not
                // an alert (NearestCard treats unclassified the same way).
                Text(
                    line,
                    color = dim, style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
            }
            summary.watchedLine?.let { line ->
                // The watched affordance is this tap on both phones (iOS: DashboardView.watchedRow,
                // inside radarLegend), not a seventh strip tile: it sits under the
                // card whose count it explains, and the strip keeps its six-across layout.
                Row(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .clip(MaterialTheme.shapes.small)
                        .clickable(onClickLabel = "show in log", role = Role.Button) {
                            onOpenLogCategory(WATCHED_FILTER_KEY)
                        }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Filled.Star, contentDescription = null,
                        tint = DeviceType.WATCHED.textTone(), modifier = Modifier.size(18.dp))
                    Text(line, color = DeviceType.WATCHED.textTone(),
                        style = MaterialTheme.typography.labelLarge)
                }
            }
            // Both lines come from the presentation, where iOS DashboardSnapshot.radarCaption /
            // radarCaptionDetail are the byte-identical twins and both suites pin the literals.
            Column(
                Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    summary.radarCaption,
                    color = dim, style = CaptionTelemetry,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    STATUS_RADAR_CAPTION_DETAIL,
                    color = dim, style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

/** The split is primary Status information, so it gets readable numeric cards rather than a
 * tiny radar footnote. At accessibility text sizes they stack instead of squeezing. */
@Composable
private fun RadarCountCards(summary: StatusNearbySummary) {
    val matchTone = MaterialTheme.colorScheme.primary
    val ambientTone = MaterialTheme.colorScheme.onSurfaceVariant
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = maxWidth < 280.dp || LocalDensity.current.fontScale >= STATUS_LARGE_TEXT_STACK_SCALE
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                RadarCountCard(STATUS_MATCHED_CARD_TITLE, STATUS_MATCHED_CARD_DETAIL,
                    summary.matched, matchTone, Modifier.fillMaxWidth())
                RadarCountCard(STATUS_AMBIENT_CARD_TITLE, STATUS_AMBIENT_CARD_DETAIL,
                    summary.ambient, ambientTone, Modifier.fillMaxWidth())
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                RadarCountCard(STATUS_MATCHED_CARD_TITLE, STATUS_MATCHED_CARD_DETAIL,
                    summary.matched, matchTone, Modifier.weight(1f))
                RadarCountCard(STATUS_AMBIENT_CARD_TITLE, STATUS_AMBIENT_CARD_DETAIL,
                    summary.ambient, ambientTone, Modifier.weight(1f))
            }
        }
    }
}

/** One count card: the number, the title, the detail line, stacked and centred like iOS
 *  DashboardView.nearbyCount. No fill of its own: it sits inside the legend's grouped cell. The
 *  count and title take the card's tone; the detail is always onSurfaceVariant. */
@Composable
private fun RadarCountCard(
    title: String,
    detail: String,
    count: Int,
    tone: Color,
    modifier: Modifier,
) {
    Column(
        modifier
            // one node per card, count first: unmerged, TalkBack stopped on the number and
            // again on each word. Built when the semantics tree is collected, not per frame.
            .semantics(mergeDescendants = true) {
                contentDescription = statusRadarCountCardDescription(count, title, detail)
            }
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("$count", color = tone, style = LegendCountStyle)
        Text(title, color = tone, style = TelegramStyle, textAlign = TextAlign.Center)
        Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
    }
}

/** The nRF fault is a whole half of the detection surface going dark, so it can't live only on
 *  the Beacon tab. Short form here, Beacon carries the full what-to-try. An amber icon rather
 *  than the Beacon banner's default primary tint: the scan line above it turns amber for the
 *  same fault, so the two read as one warning, and crimson is the colour of a match here. */
@Composable
private fun CoprocFaultBanner() {
    AcabBanner(
        "nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.",
        Modifier.fillMaxWidth(),
        icon = Icons.Filled.WarningAmber,
        iconTint = Acab.warn,
    )
}

/** Same slot as [CoprocFaultBanner], for the one case where the dark nRF is intentional: it's
 *  taking new firmware. Says the same thing about coverage without the alarm colours. A spinner,
 *  or a static update icon under Reduce Motion. */
@Composable
private fun CoprocUpdatingBanner(reduceMotion: Boolean) {
    AcabBanner(
        "updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.",
        Modifier.fillMaxWidth(),
        icon = if (reduceMotion) Icons.Filled.SystemUpdateAlt else null,
        iconTint = MaterialTheme.colorScheme.onSurfaceVariant,
        progress = !reduceMotion,
    )
}

/** Non-blocking banner shown while the board is draining its offline buffer on reconnect.
 *  Determinate once the board's hist lead-in supplies a total (a live count until then), with a
 *  spinner (a static sync icon under Reduce Motion) and, when records have started landing, a
 *  live "N so far" count. No modal. */
@Composable
private fun SyncingBanner(count: Int, total: Int, reduceMotion: Boolean) {
    AcabBanner(
        when {
            total > 0 -> "syncing offline log, $count of $total"
            count > 0 -> "syncing offline log, $count so far"
            else -> "syncing offline log…"
        },
        Modifier.fillMaxWidth(),
        icon = if (reduceMotion) Icons.Filled.Sync else null,
        iconTint = MaterialTheme.colorScheme.onSurfaceVariant,
        progress = !reduceMotion,
    )
}

/** One compact count tile in the category strip. Tapping deep-links to the Log filtered to
 *  this category; the click label tells a screen reader that is what the tap does. [spoken] is
 *  the tile's [StatusStripTile.spoken]. No container: the hue lives on the icon, the label is
 *  always onSurfaceVariant (4b). */
@Composable
private fun CountTile(
    type: DeviceType,
    label: String,
    spoken: String,
    n: Int,
    enabled: Boolean?,
    modifier: Modifier = Modifier,
    onClick: () -> Unit = {},
) {
    val off = enabled == false
    val presentation = statusCountTilePresentation(spoken, n, enabled)
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        modifier
            .minimumInteractiveComponentSize()
            .clip(MaterialTheme.shapes.small)
            .clickable(onClickLabel = presentation.clickLabel,
                role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = presentation.contentDescription
            }
            .padding(horizontal = CategoryTileSidePadding, vertical = CategoryTileEndPadding),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // null: the tile is ONE merged clickable node and the label Text below already names
        // it; a contentDescription here made TalkBack read the category twice per tile.
        Icon(type.icon(), contentDescription = null,
            tint = if (off || n == 0) dim else type.tone(), modifier = Modifier.size(22.dp))
        // Turning a detector off does not erase what was just heard. Keep the number until it
        // ages out, and show the setting separately from the evidence count.
        Text(presentation.visibleCount, color = if (n == 0) dim else MaterialTheme.colorScheme.onSurface,
            style = TileCountStyle)
        Text(label, color = dim,
            style = LocalTextStyle.current.merge(CategoryTileTelemetryLabelStyle), maxLines = 1)
        // ONE OFF TREATMENT ON BOTH PHONES: the count stays, and OFF is a dim fourth line under
        // the label (iOS DashboardView.tile draws the same line). Dim, not amber: the user
        // switched this detector off, nothing is faulty. The empty string keeps the line's
        // height, so an OFF tile is no taller than its neighbours.
        Text(if (off) "OFF" else "", color = dim, style = TelegramSmallStyle, maxLines = 1)
    }
}

/** Hero cell for the strongest matched device, falling back to ambient when no match is nearby. */
@Composable
private fun NearestCard(
    d: Detection,
    age: String,
    kind: StatusStrongestKind,
    demo: Boolean,
    onSelect: (Detection) -> Unit,
) {
    Column {
        val title = statusStrongestHeader(kind, demo)
        // TWIN: iOS DashboardView nearestCard header: crimson (primary here, the text-safe tint)
        // ONLY for a match; ambient and unclassified read onSurfaceVariant on both phones.
        SectionLabel(
            title,
            color = if (kind == StatusStrongestKind.MATCHED) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
            inset = false,
        )
        val filled = kind == StatusStrongestKind.MATCHED
        // Clip, then fill, then clickable, so the ripple sits above the fill inside the shape.
        val cell = Modifier.fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .clickable(role = Role.Button) { onSelect(d) }
            .padding(horizontal = 16.dp, vertical = 12.dp)
        // At STATUS_LARGE_TEXT_STACK_SCALE the cell stacks as iOS DashboardView nearestCard does
        // at accessibility sizes: the glyph alone on the first row, the name and the facts at
        // full width, then the signal at the end of its own last row. The name stays out of the
        // glyph row on both. (iOS also puts its chevron on the glyph row; this cell draws none.)
        if (LocalDensity.current.fontScale >= STATUS_LARGE_TEXT_STACK_SCALE) {
            Column(cell, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                CatGlyph(d.type, size = 40, filled = filled)
                NearestText(d, age, Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    NearestSignal(d.rssi)
                }
            }
        } else {
            Row(cell, verticalAlignment = Alignment.CenterVertically) {
                CatGlyph(d.type, size = 40, filled = filled)
                Spacer(Modifier.width(16.dp))
                NearestText(d, age, Modifier.weight(1f))
                Spacer(Modifier.width(16.dp))
                NearestSignal(d.rssi)
            }
        }
    }
}

/** The name and the lines under it, one column for both NearestCard layouts. */
@Composable
private fun NearestText(d: Detection, age: String, modifier: Modifier) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        // Lead with the same user/device name used in Log and Detail. Category-only copy
        // made the most prominent Status card less useful whenever several devices of
        // the same kind were nearby. titleName: a nameless row reads the category's display
        // name ("body cam"), as the Log row and the dossier hero do.
        Text(d.titleName, color = MaterialTheme.colorScheme.onSurface,
            style = MaterialTheme.typography.bodyLarge)
        // THE FOUR LINES ARE SHARED, line for line, with iOS DashboardView nearestCard:
        // the name, `inlineCategory · NODE xxxx` (the lowercase category on both phones,
        // never the type label), the last-heard age on its own dim line, then
        // `source · seen N×`. The age stands alone so neither line has to wrap
        // beside the glyph and the dBm column.
        // Lines 2 to 4 are the sighting's telemetry block: the instrument face (iOS twin the same).
        Text("${d.type.inlineCategory} · NODE ${nodeName(d.mac)}",
            color = dim, style = BodyTelemetry)
        Text(age, color = dim, style = BodyTelemetry)
        Text("${d.sourceLabel} · seen ${d.count}×",
            color = dim, style = BodyTelemetry)
    }
}

/** The signal as a number over its unit, in secondary ink (crimson stays on the match header).
 *  Spoken with the Log row's wording instead of the symbols, as iOS nearestSignal is. */
@Composable
private fun NearestSignal(rssi: Int) {
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Column(
        Modifier.clearAndSetSemantics {
            contentDescription = "Signal strength $rssi decibels relative to one milliwatt"
        },
        horizontalAlignment = Alignment.End,
    ) {
        Text("$rssi", color = dim, style = BodyTelemetry)
        Text("dBm", color = dim, style = DbmStyle)
    }
}

/** Last 4 hex of the MAC, uppercased: a short node handle. */
private fun nodeName(mac: String): String = mac.replace(":", "").takeLast(4).uppercase()
