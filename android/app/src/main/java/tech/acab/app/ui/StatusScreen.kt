package tech.acab.app.ui

import android.content.Context
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.OtaPhase
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.model.displayName
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.textTone
import tech.acab.app.ui.theme.tone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

internal fun shouldShowFinishSetupCard(demo: Boolean, dismissed: Boolean): Boolean =
    !demo && !dismissed

internal enum class FinishSetupLiveState(val label: String) {
    ACTIVE("ACTIVE"),
    BLOCKED("BLOCKED"),
    WAITING("WAITING"),
    OFF("OFF"),
}

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

internal fun finishSetupPhoneAlertsLabel(
    enabled: Boolean,
    notificationsAvailable: Boolean,
): String = when {
    !enabled -> "OFF"
    !notificationsAvailable -> "BLOCKED"
    else -> "ON"
}

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
            "with matches and stars first. Radar shows signal strength only, not direction."

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
    "matches and stars first · counts include every recent device"

/** The two count cards that split TOTAL NEARBY, a title and a detail line each. TWIN: iOS
 *  `DashboardSnapshot.matchedCardTitle` / `matchedCardDetail` / `ambientCardTitle` /
 *  `ambientCardDetail` in DashboardPresentation.swift, byte-identical; both suites pin the four
 *  literals. "MATCHED + WATCHED" because a star counts as a match here ([statusNearbySummary]
 *  folds watched rows into `matched`), and the detail names the two things that means. */
internal const val STATUS_MATCHED_CARD_TITLE = "MATCHED + WATCHED"
internal const val STATUS_MATCHED_CARD_DETAIL = "signatures or exact stars"
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
 *  TWIN: iOS DashboardPresentation.swift `dashboardLastHeardLabel`, same strings in the same hero
 *  slot - reword one and reword the other. The minute branch is the mandatory total-function
 *  default: the caller only ever hands this a row inside the 45 s freshness window, so it is
 *  defensive, not a rendered cue. */
internal fun statusLastHeardAge(
    lastSeenAtMs: Long?,
    nowMs: Long,
    demo: Boolean,
): String = when {
    demo -> "sample sighting · not live"
    lastSeenAtMs == null -> "last heard unknown"
    nowMs - lastSeenAtMs < 1_000L -> "last heard just now"
    nowMs - lastSeenAtMs < 60_000L -> "last heard ${(nowMs - lastSeenAtMs).coerceAtLeast(0L) / 1_000L}s ago"
    else -> "last heard ${(nowMs - lastSeenAtMs).coerceAtLeast(0L) / 60_000L}m ago"
}

internal data class StatusScanPresentation(
    val scanning: Boolean,
    val bleUpdating: Boolean,
    val bleFault: Boolean,
    val label: String,
)

/** One radio truth table drives the Status label, pulse, sweep, and impairment pill.
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
    return StatusScanPresentation(scanning, bleUpdating, bleFault, label)
}

/** The header pill's one word. ARM ORDER IS SHARED with iOS `BeaconRadioPresentation.chipLabel`,
 *  which maps the connection label beaconRadioPresentation picked, so the pill ranks the same
 *  facts as [statusScanPresentation]: sample mode (null, so LinkChip draws DEMO), then the link
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

private const val FINISH_SETUP_DISMISSED = "finish_setup_dismissed"

/** Status / home: the at-a-glance "how many eyes are on me" view.
 *  [onOpenLogCategory] jumps to the Log tab with the given category filter applied; the
 *  count tiles call it so a number here is one tap from its rows. */
@Composable
fun StatusScreen(
    ble: AcabBleManager,
    reconnecting: Boolean = false,
    onSelect: (Detection) -> Unit = {},
    onOpenLogCategory: (String) -> Unit = {},
    onOpenDetectorSettings: () -> Unit = {},
    onOpenHelp: () -> Unit = {},
    locationGranted: Boolean = false,
    notificationsAvailable: Boolean = false,
    onOpenSetup: () -> Unit = {},
) {
    val detections by ble.detections.collectAsState()
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val watchedList by ble.watched.collectAsState()
    val watchedMacs = remember(watchedList) {
        watchedList.mapTo(HashSet(watchedList.size)) { it.mac.lowercase() }
    }
    val liveWanted by ble.driveModeWanted.collectAsState()
    val liveRunning by ble.driveMode.collectAsState()
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
    val context = LocalContext.current
    val setupPrefs = remember { context.getSharedPreferences("acab_ui", Context.MODE_PRIVATE) }
    var finishSetupDismissed by remember {
        mutableStateOf(setupPrefs.getBoolean(FINISH_SETUP_DISMISSED, false))
    }
    val phoneAlertsOn = DetectionNotifier.anyEnabled(context)
    val showFinishSetup = shouldShowFinishSetupCard(demo, finishSetupDismissed)
    // mutedBySystem costs two Binder IPCs and its answer feeds only the finish-setup card,
    // while this screen recomposes at ~1-3 Hz under the tick and detection flows - so it is
    // asked only while the card can show, never per recomposition (zero IPCs once dismissed).
    // ON_RESUME is the one moment the answer can have changed: system settings and the
    // permission dialog both pause the activity (same pattern as DeviceScreen's notifGranted).
    // Keying the effect on showFinishSetup makes addObserver's sync-up ON_RESUME re-ask the
    // moment the card becomes showable again (e.g. sample mode ending), not just on a real
    // return from background.
    var phoneAlertsAvailable by remember {
        mutableStateOf(!showFinishSetup || !DetectionNotifier.mutedBySystem(context))
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, showFinishSetup) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && showFinishSetup) {
                phoneAlertsAvailable = !DetectionNotifier.mutedBySystem(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val finishLiveState = finishSetupLiveState(
        wanted = liveWanted,
        active = liveRunning && ble.driveServiceReady,
        notificationsAvailable = notificationsAvailable,
    )
    val finishPhoneAlerts = finishSetupPhoneAlertsLabel(
        enabled = phoneAlertsOn,
        notificationsAvailable = phoneAlertsAvailable,
    )
    val dismissFinishSetup = {
        finishSetupDismissed = true
        setupPrefs.edit().putBoolean(FINISH_SETUP_DISMISSED, true).apply()
    }

    // Staleness is a function of the clock, not of anything the UI observes, and eviction is
    // cap-only, so nothing recomposes this screen when a device simply stops being heard.
    // Without this tick the radar freezes at its last-publish count and a Flock heard twenty
    // minutes ago keeps winning "STRONGEST SIGNAL · LIVE" for the rest of the session.
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

    // The tiles hang off the radar's "TOTAL NEARBY" count (the strongest card sits between them
    // whenever anything is nearby), so they have to measure the same thing. Off the whole store
    // they were session totals, and the strip could read "ALPR 3" under a radar honestly
    // reporting 0 nearby. One grouped pass whenever `nearby` changes, instead of an O(n) scan per
    // tile per recomposition. remember compares its key with equals and Detection is a data class,
    // so a publish that adds, drops or changes a fresh row regroups, and so does a tick that ages
    // one out, while a quiet tick pays at most that O(n) list comparison.
    val typeCounts = remember(nearby) { nearby.groupingBy { it.type }.eachCount() }
    fun count(type: DeviceType) = typeCounts[type] ?: 0

    // Headline tracks radio state so a pulsing dot never claims a scan that isn't happening.
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
    // update in flight gets its own line instead of the crimson "radio fault" one.
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
            .padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        // header: wordmark + link chip
        Row(verticalAlignment = Alignment.CenterVertically) {
            BrandMark(size = 21)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onOpenHelp) {
                Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = "help and support",
                    tint = Acab.dim, modifier = Modifier.size(19.dp))
            }
            LinkChip(
                version = status?.version,
                demo = demo,
                connected = !reconnecting && status != null,
                stateLabel = linkStateLabel,
            )
        }

        // OS-level "remove animations": the looping ornaments (dot pulse, radar sweep) park.
        val reduceMotion = rememberReduceMotion()

        Row(verticalAlignment = Alignment.CenterVertically) {
            // the scan dot breathes so the header reads as live, not a static badge;
            // the animated alpha is read inside graphicsLayer (draw phase), so the
            // pulse repaints one dot instead of recomposing the whole screen at 60fps.
            // It only breathes while something is actually listening: a pulse over
            // "RADIOS OFF" is the lie this header exists to not tell.
            // Null under reduce-motion: no transition even runs, the dot just holds solid.
            val blink = if (reduceMotion) null else rememberInfiniteTransition(label = "scanDot").animateFloat(
                initialValue = 1f, targetValue = 0.2f,
                animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing), RepeatMode.Reverse),
                label = "scanDotAlpha",
            )
            Box(
                Modifier
                    .size(7.dp)
                    .graphicsLayer { alpha = if (scanning) (blink?.value ?: 1f) else 1f }
                    // With WI-FI up and the nRF dead, scanning is still true, so a plain accent
                    // dot pulses identically to a healthy scan while half the detection surface
                    // is dark. Amber is the only thing separating the two at a glance.
                    .background(
                        if (!scanning) Acab.faint else if (bleFault) Acab.warn else Acab.accent,
                        CircleShape,
                    ),
            )
            Spacer(Modifier.size(8.dp))
            Kicker(scanLabel, color = if (bleFault) Acab.warn else Acab.dim)
            // Far-right recency note: everything on the radar / in the counts was heard within the
            // ~45s "nearby" window (ble.freshIdSet), so say so - only when there's actually something up.
            if (!demo && nearby.isNotEmpty()) {
                Spacer(Modifier.weight(1f))
                Kicker(STATUS_SEEN_WINDOW_KICKER, color = Acab.faint)
            }
        }

        if (bleFault) CoprocFaultPill() else if (bleUpdating) CoprocUpdatingPill()

        // While the board replays its offline buffer on reconnect: a subtle, non-blocking pill.
        // determinate once the board's hist lead-in supplies a total; a live count until then.
        if (syncing) SyncingPill(count = syncCount, total = syncTotal)

        if (showFinishSetup) {
            FinishSetupCard(
                liveState = finishLiveState,
                locationOn = locationGranted,
                phoneAlertsState = finishPhoneAlerts,
                bufferOn = status?.bufOn,
                onReview = {
                    dismissFinishSetup()
                    onOpenSetup()
                },
                onDismiss = dismissFinishSetup,
            )
        }

        // T2: keep the scope from stretching screen-wide on tablets; capped + centered.
        RadarScope(summary = nearbySummary, scanning = scanning, reduceMotion = reduceMotion,
            modifier = Modifier.align(Alignment.CenterHorizontally).widthIn(max = 420.dp))

        // SECTION ORDER BELOW THE SCOPE IS SHARED with iOS DashboardView (its body, RadarScope
        // down to PunkLine): the strongest card, the category tiles, the legend that explains the
        // dial (count cards, the two conditional lines, the captions, the no-direction pill),
        // then the brand line. The square scope already spends most of a 390dp phone's first
        // screen, so the verdict and the two taps it leads to (dossier, Log) come before the
        // legend, which can scroll. Reorder one side only and the other side's comment becomes
        // a lie.
        if (nearest != null) NearestCard(
            d = nearest,
            age = nearestAge,
            kind = nearbySummary.strongestKind ?: StatusStrongestKind.AMBIENT,
            demo = demo,
            onSelect = onSelect,
        )

        // per-category counts: one strip of compact tiles. Which tiles, in what order, drawn
        // and spoken as what, and counting which types, is STATUS_STRIP_TILES (where the iOS twin
        // is named); this only draws them. Network Cam rides the same strip as Log and Map so
        // Status shows every category the other tabs do (netcamTone + CameraOutdoor come from the
        // type's own tone()/icon(), like every other tile here). Each tile deep-links to the Log
        // with that category's filter, so a count is one tap from its rows. The strip wraps to
        // rows of three as soon as the widest label no longer fits a six-across tile, and to rows
        // of two after that (rememberCategoryTilesPerRow measures it), so labels stay whole at
        // every Android font scale.
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val perRow = rememberCategoryTilesPerRow(STATUS_STRIP_TILES.map { it.label }, maxWidth,
                STATUS_STRIP_TILES.size)
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

        RadarLegend(summary = nearbySummary, onOpenLogCategory = onOpenLogCategory)

        // Brand ornament, last on both phones (iOS DashboardView puts PunkLine last too), so it
        // spends nothing of the budget above the fold.
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { PunkLine() }
    }
    }
}

/** The "Beacons" wordmark. */
@Composable
private fun BrandMark(size: Int) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text("beacons", color = Acab.text, fontSize = size.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.display)
    }
}

/** Optional setup review kept out of the one-time tour. Every choice remains usable as-is. */
@Composable
private fun FinishSetupCard(
    liveState: FinishSetupLiveState,
    locationOn: Boolean,
    phoneAlertsState: String,
    bufferOn: Boolean?,
    onReview: () -> Unit,
    onDismiss: () -> Unit,
) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Column(
        Modifier.fillMaxWidth().background(Acab.bg2, shape)
            .border(1.dp, Acab.lineStrong, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("finish setup", color = Acab.text, fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold)
                Text("optional choices you can review anytime in Beacon", color = Acab.faint,
                    fontSize = 10.sp, fontFamily = Acab.mono)
            }
            Icon(
                Icons.Filled.Close,
                contentDescription = "dismiss finish setup",
                tint = Acab.dim,
                modifier = Modifier.minimumInteractiveComponentSize().size(20.dp)
                    .clickable(role = Role.Button, onClick = onDismiss),
            )
        }
        SetupStateRow("Live Mode", liveState.label)
        SetupStateRow("Location", if (locationOn) "ALLOWED" else "OPTIONAL")
        SetupStateRow("Phone alerts", phoneAlertsState)
        SetupStateRow("Offline buffer", when (bufferOn) { true -> "ON"; false -> "OFF"; null -> "CHECK" })
        Row(
            Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                .clip(RoundedCornerShape(50))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(50))
                .clickable(onClickLabel = "review setup in Beacon", role = Role.Button, onClick = onReview)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Text("REVIEW IN BEACON", color = Acab.accentText, fontSize = 10.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Spacer(Modifier.size(6.dp))
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.accent,
                modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun SetupStateRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Acab.dim, fontSize = 11.sp, modifier = Modifier.weight(1f))
        Text(value, color = Acab.faint, fontSize = 9.5.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono, letterSpacing = 0.7.sp)
    }
}

// (LinkChip now lives in Components.kt as the one shared status pill; the Map
// header uses the same composable.)

/** Radar: concentric rings, crosshairs, a rotating sweep, and up to fourteen prioritized dots.
 *  Rings are honest: blips snap to the STRONG/GOOD/WEAK ring of their signal band, and
 *  [RadarLegend]'s pill says outright that the angle (a stable MAC hash) carries no bearing.
 *  [summary] is built from the nearby set, already filtered for staleness by the caller; the count
 *  in the middle is exact even when the intentionally bounded blips cannot show every row. The sweep only turns
 *  while [scanning], since a sweeping radar over a dead radio reads as a live all-clear. The dial
 *  only: the legend under it is [RadarLegend], placed by the caller after the card and the tiles. */
@Composable
private fun RadarScope(
    summary: StatusNearbySummary,
    scanning: Boolean,
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    // Under reduce-motion no transition runs at all; the wedge still draws, parked, so the
    // scope keeps its look without the loop.
    val sweep = if (reduceMotion) null else rememberInfiniteTransition(label = "sweep").animateFloat(
        initialValue = 0f, targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(4500, easing = LinearEasing), RepeatMode.Restart),
        label = "sweepAngle",
    )
    val dots = summary.dots

    // STRONG / GOOD / WEAK band labels, fading outward (45/38/30% text).
    //
    // THESE ARE STRENGTH WORDS, NOT DISTANCE WORDS. They were NEAR / MID / FAR until 2026-09-08,
    // which labelled a signal-strength quantity with distance, and the screen then had to walk it
    // back twice on itself (the SIGNAL STRENGTH ONLY - NO DIRECTION pill, then
    // STATUS_RADAR_CAPTION_DETAIL). RSSI is not distance, because transmit power is a per-DEVICE
    // choice (faq-content.json q-signal): a pole-mounted ALPR camera reads strong from across a
    // street while a tracking tag a few meters away reads weak. The vocabulary is the one
    // BoardRow already speaks for rssiBars, so the ring a blip sits on and the spoken word for its
    // bars cannot disagree. Do not put NEAR / MID / FAR back. TWIN: iOS DashboardView.ringLabels.
    //
    // Ornamental dial
    // furniture, so the size is divided back out of the font scale: at 2x text these labels
    // would collide with the rings and the center count, and they carry no information the
    // caption below does not restate.
    //
    // Keyed on Acab.highContrast as well: the layouts bake Acab.text, and Theme.kt's rule for
    // anything that caches a rendered colour is to key it on highContrast, or a palette swap
    // keeps stale-coloured labels on the dial.
    val density = LocalDensity.current
    val fontScale = density.fontScale
    val measurer = rememberTextMeasurer()
    val ringLabels = remember(measurer, fontScale, Acab.highContrast) {
        listOf("STRONG" to 0.45f, "GOOD" to 0.38f, "WEAK" to 0.30f).map { (word, alpha) ->
            measurer.measure(
                AnnotatedString(word),
                TextStyle(
                    color = Acab.text.copy(alpha = alpha), fontSize = (7.5f / fontScale).sp,
                    fontFamily = Acab.mono, fontWeight = FontWeight.Medium, letterSpacing = 1.sp,
                ),
            )
        }
    }

    // Hoisted out of the draw lambda, which runs at display refresh rate while the sweep turns:
    // Brush.sweepGradient boxes every stop into a Pair and the ring style was a fresh Stroke per
    // ring, so the scope allocated on every animation frame. The gradient bakes exactly one
    // palette colour, so that colour is its key (it moves with Acab.highContrast, and with any
    // other palette edit). No size key: the center is left Unspecified, which SweepGradient
    // resolves to the center of the DrawScope at draw time, the same point as the `c` computed
    // in the lambda, and ShaderBrush re-creates its Shader itself when the size it was last
    // applied at changes.
    val sweepBrush = remember(Acab.accentGlow) {
        Brush.sweepGradient(
            0.72f to Color.Transparent,
            0.99f to Acab.accentGlow,
            1.0f to Color.Transparent,
        )
    }
    // Density is the only input a 1 dp stroke bakes.
    val hairline = remember(density) { Stroke(with(density) { 1.dp.toPx() }) }

    Box(
        modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .padding(top = 4.dp)
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

            // three rings, the outer one stronger
            for (i in 1..3) {
                drawCircle(
                    color = if (i == 3) Acab.lineStrong else Acab.line,
                    radius = r * i / 3f, center = c, style = hairline,
                )
            }
            // crosshairs
            drawLine(Acab.line, Offset(c.x, c.y - r), Offset(c.x, c.y + r), 1.dp.toPx())
            drawLine(Acab.line, Offset(c.x - r, c.y), Offset(c.x + r, c.y), 1.dp.toPx())

            // ring labels on the vertical axis above center; WEAK (the outermost) sits just
            // inside the outer ring so it doesn't clip at the canvas edge. Index loops here
            // and over the dots: withIndex() and the List iterator allocate per frame.
            for (i in ringLabels.indices) {
                val layout = ringLabels[i]
                val ringR = r * (i + 1) / 3f
                val y = if (i == 2) c.y - ringR + 4.dp.toPx()
                else c.y - ringR - layout.size.height - 3.dp.toPx()
                drawText(layout, topLeft = Offset(c.x - layout.size.width / 2f, y))
            }

            // rotating sweep, a soft crimson wedge. Reading `sweep` inside the branch means
            // a parked radar also stops re-drawing at 60fps, not just stops lying. With
            // reduce-motion on, sweep is null and the wedge draws once, parked at 0.
            if (scanning) {
                rotate(sweep?.value ?: 0f, c) {
                    drawArc(
                        brush = sweepBrush,
                        startAngle = 0f, sweepAngle = 360f, useCenter = true,
                        topLeft = Offset(c.x - r, c.y - r), size = Size(r * 2, r * 2),
                    )
                }
            }

            // one blip per detection: angle from the MAC (stable), radius snapped
            // to the ring of its signal band (bars 4 = strong, 3 = good, weaker = weak).
            // A starred row keeps its real category type, so the gold comes from the dot's
            // watched flag, not from the type (iOS DashboardView draws it the same way).
            for (i in dots.indices) {
                val dot = dots[i]
                val d = dot.row
                val angle = (abs(d.mac.hashCode()) % 360) * (PI / 180.0)
                val bars = rssiBars(d.rssi)
                val rad = when {
                    bars >= 4 -> r / 3f
                    bars == 3 -> r * 2f / 3f
                    else -> r
                }
                val pos = Offset(c.x + (cos(angle) * rad).toFloat(), c.y + (sin(angle) * rad).toFloat())
                val tone = if (dot.watched) Acab.watchTone else d.type.tone()
                // two-layer glow under a solid core
                drawCircle(tone.copy(alpha = 0.12f), 12.dp.toPx(), pos)
                drawCircle(tone.copy(alpha = 0.35f), 7.dp.toPx(), pos)
                drawCircle(tone, 4.dp.toPx(), pos)
            }
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("${summary.total}", color = Acab.text, fontSize = 62.sp, fontWeight = FontWeight.Bold)
            // TOTAL NEARBY covers matched/watched AND ambient devices, which the cards below
            // split apart. It is still a RECENT count (already filtered for staleness), not the
            // whole-Log total, which is why it reads lower than the Log's own count. Twin
            // comment: Components.swift's Kicker on the iOS dial says the same thing.
            // pinned: the kicker is an ornament under a 62sp number that already scales;
            // iOS pins it the same way so the dial composition holds at large font scales.
            Kicker("TOTAL NEARBY", pinned = true)
        }
    }
}

/** Everything that explains the dial, one block in one order on both phones (iOS
 *  DashboardView.radarLegend): the count cards that split TOTAL NEARBY, the two conditional
 *  lines, the two caption lines, then the no-direction pill. Every card and line word is the
 *  presentation's (STATUS_MATCHED_CARD_TITLE and friends, [StatusNearbySummary.unclassifiedLine] /
 *  [StatusNearbySummary.watchedLine], [StatusNearbySummary.radarCaption],
 *  STATUS_RADAR_CAPTION_DETAIL), where the iOS twins are named; the no-direction pill's text and
 *  the watched tap's click label are written here. Same tones as iOS: crimson
 *  (accentText) for the match card, dim for ambient and for the unclassified line, the watched
 *  tint for the watched tap. Column spacing matches the screen's so the legend reads as three of
 *  its sections. */
@Composable
private fun RadarLegend(summary: StatusNearbySummary, onOpenLogCategory: (String) -> Unit) {
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            RadarCountCards(summary)
            summary.unclassifiedLine?.let { line ->
                // Dim on purpose: a wire type this build does not know is a fact to report, not
                // an alert (NearestCard treats unclassified the same way).
                Text(
                    line,
                    color = Acab.dim, fontSize = 10.5.sp, fontFamily = Acab.mono,
                    textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
                )
            }
            summary.watchedLine?.let { line ->
                // The watched affordance is this tap on both phones (iOS: the star Button in
                // DashboardView.nearbyBreakdown), not a seventh strip tile: it sits under the
                // card whose count it explains, and the strip keeps its six-across layout.
                Row(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .clip(RoundedCornerShape(Acab.radiusSm))
                        .clickable(onClickLabel = "show in log", role = Role.Button) {
                            onOpenLogCategory(WATCHED_FILTER_KEY)
                        }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Filled.Star, contentDescription = null,
                        tint = DeviceType.WATCHED.textTone(), modifier = Modifier.size(14.dp))
                    Text(line, color = DeviceType.WATCHED.textTone(), fontSize = 11.sp,
                        fontFamily = Acab.mono, fontWeight = FontWeight.Medium)
                }
            }
        }
        // Both lines come from the presentation, where iOS DashboardSnapshot.radarCaption /
        // radarCaptionDetail are the byte-identical twins and both suites pin the literals.
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                summary.radarCaption,
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                STATUS_RADAR_CAPTION_DETAIL,
                color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
            )
        }
        // The one fact that stops the radar being read as a direction finder, promoted from a
        // 9sp whisper to a legible pill (parity with iOS doing the same). Always rendered, where
        // the lines above it come and go.
        Row(
            Modifier
                .background(Acab.bg2, RoundedCornerShape(50))
                .border(1.dp, Acab.line, RoundedCornerShape(50))
                .padding(horizontal = 14.dp, vertical = 7.dp),
        ) {
            Text(
                "SIGNAL STRENGTH ONLY · NO DIRECTION",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                fontWeight = FontWeight.Bold, letterSpacing = 1.sp, textAlign = TextAlign.Center,
            )
        }
    }
}

/** The split is primary Status information, so it gets readable numeric cards rather than a
 * tiny radar footnote. At accessibility text sizes they stack instead of squeezing. */
@Composable
private fun RadarCountCards(summary: StatusNearbySummary) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val stacked = maxWidth < 280.dp || LocalDensity.current.fontScale >= 1.5f
        if (stacked) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                RadarCountCard(STATUS_MATCHED_CARD_TITLE, STATUS_MATCHED_CARD_DETAIL,
                    summary.matched, Acab.accentText, Modifier.fillMaxWidth())
                RadarCountCard(STATUS_AMBIENT_CARD_TITLE, STATUS_AMBIENT_CARD_DETAIL,
                    summary.ambient, Acab.dim, Modifier.fillMaxWidth())
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                RadarCountCard(STATUS_MATCHED_CARD_TITLE, STATUS_MATCHED_CARD_DETAIL,
                    summary.matched, Acab.accentText, Modifier.weight(1f))
                RadarCountCard(STATUS_AMBIENT_CARD_TITLE, STATUS_AMBIENT_CARD_DETAIL,
                    summary.ambient, Acab.dim, Modifier.weight(1f))
            }
        }
    }
}

/** One count card: the number, the title, the detail line, stacked and centred like iOS
 *  DashboardView.nearbyCount. The count and title take the card's tone; the detail is always
 *  dim. */
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
            .background(Acab.bg2, RoundedCornerShape(Acab.radiusSm))
            // one node per card, count first: unmerged, TalkBack stopped on the number and
            // again on each word. Built when the semantics tree is collected, not per frame.
            .semantics(mergeDescendants = true) {
                contentDescription = statusRadarCountCardDescription(count, title, detail)
            }
            .padding(10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("$count", color = tone, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Text(title, color = tone, fontSize = 10.sp, fontFamily = Acab.mono,
            fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(detail, color = Acab.dim, fontSize = 9.sp, fontFamily = Acab.mono,
            textAlign = TextAlign.Center)
    }
}

/** The nRF fault is a whole half of the detection surface going dark, so it can't live only on
 *  the Device tab. Short form here, Device carries the full what-to-try. Amber rather than the
 *  Device banner's crimson: this sits beside the scan dot, and a crimson pill next to a crimson
 *  dot reads as decoration instead of a warning. */
@Composable
private fun CoprocFaultPill() {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.warn.copy(alpha = 0.4f), shape)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.WarningAmber, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(12.dp))
        Spacer(Modifier.size(8.dp))
        Text(
            "nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.",
            color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** Same slot as CoprocFaultPill, for the one case where the dark nRF is intentional: it's
 *  taking new firmware. Says the same thing about coverage without the alarm colours. */
@Composable
private fun CoprocUpdatingPill() {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        CircularProgressIndicator(color = Acab.dim, strokeWidth = 1.5.dp,
            modifier = Modifier.size(12.dp))
        Spacer(Modifier.size(8.dp))
        Text(
            "updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** Subtle inline pill shown while the board is draining its offline buffer on reconnect.
 *  Determinate once the board's hist lead-in supplies a total (a live count until then), with a
 *  breathing dot and, when records have started landing, a live "N so far" count. Non-blocking, no modal. */
@Composable
private fun SyncingPill(count: Int, total: Int) {
    val shape = RoundedCornerShape(50)
    // Reduce-motion parks the breathing dot (the text already says syncing is in progress).
    val reduceMotion = rememberReduceMotion()
    val blink = if (reduceMotion) null else rememberInfiniteTransition(label = "syncDot").animateFloat(
        initialValue = 1f, targetValue = 0.25f,
        animationSpec = infiniteRepeatable(tween(700, easing = LinearEasing), RepeatMode.Reverse),
        label = "syncDotAlpha",
    )
    Row(
        Modifier
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier
                .size(6.dp)
                .graphicsLayer { alpha = blink?.value ?: 1f }
                .background(Acab.dim, CircleShape),
        )
        Text(
            when {
                total > 0 -> "syncing offline log, $count of $total"
                count > 0 -> "syncing offline log, $count so far"
                else -> "syncing offline log…"
            },
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** One compact count tile in the category strip. Tapping deep-links to the Log filtered to
 *  this category; the click label tells a screen reader that is what the tap does. [spoken] is
 *  the tile's [StatusStripTile.spoken]. */
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
    val shape = RoundedCornerShape(Acab.radiusSm)
    val off = enabled == false
    val presentation = statusCountTilePresentation(spoken, n, enabled)
    Column(
        modifier
            .minimumInteractiveComponentSize()
            .clip(shape)
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClickLabel = presentation.clickLabel,
                role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = presentation.contentDescription
            }
            .padding(horizontal = CategoryTileSidePadding, vertical = CategoryTileEndPadding),
        verticalArrangement = Arrangement.spacedBy(5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // null: the tile is ONE merged clickable node and the label Text below already names
        // it; a contentDescription here made TalkBack read the category twice per tile.
        Icon(type.icon(), contentDescription = null,
            tint = if (off || n == 0) Acab.faint else type.tone(), modifier = Modifier.size(14.dp))
        // Turning a detector off does not erase what was just heard. Keep the number until it
        // ages out, and show the setting separately from the evidence count.
        Text(presentation.visibleCount, color = if (n == 0) Acab.faint else Acab.text,
            fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = if (off || n == 0) Acab.faint else type.textTone(),
            style = LocalTextStyle.current.merge(CategoryTileLabelStyle), maxLines = 1)
        // ONE OFF TREATMENT ON BOTH PHONES: the count stays, and OFF is a dim fourth line under
        // the label (iOS DashboardView.tile draws the same line). Dim, not amber: the user
        // switched this detector off, nothing is faulty. The empty string keeps the line's
        // height, so an OFF tile is no taller than its neighbours.
        Text(if (off) "OFF" else "", color = Acab.dim, fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono, maxLines = 1)
    }
}

/** Hero card for the strongest matched device, falling back to ambient when no match is nearby. */
@Composable
private fun NearestCard(
    d: Detection,
    age: String,
    kind: StatusStrongestKind,
    demo: Boolean,
    onSelect: (Detection) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val title = (when (kind) {
            StatusStrongestKind.MATCHED -> "STRONGEST MATCH"
            StatusStrongestKind.UNCLASSIFIED -> "STRONGEST UNCLASSIFIED"
            StatusStrongestKind.AMBIENT -> "STRONGEST AMBIENT"
        }) + if (demo) " · SAMPLE" else " · RECENT"
        // TWIN: iOS DashboardView nearestCard `Kicker("STRONGEST ...", color: sighting.matched ?
        // accentText : dim)`. accentText, not accent: a crimson WORD, and the fill tone is under
        // AA as text. Crimson ONLY for a match: ambient and unclassified traffic is not an alert
        // and reads dim on both phones.
        Kicker(title, color = if (kind == StatusStrongestKind.MATCHED) Acab.accentText else Acab.dim)
        // Inline the panel so the click ripple sits ABOVE the opaque bg and clipped to the
        // rounded shape (panel() bundles bg+border+padding, which would hide a ripple behind it).
        Row(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(Acab.radius))
                .background(Acab.bg2, RoundedCornerShape(Acab.radius))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radius))
                .clickable { onSelect(d) }
                .padding(Acab.padCard),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CatGlyph(d.type, size = 40, filled = true)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                // Lead with the same user/device name used in Log and Detail. Category-only copy
                // made the most prominent Status card less useful whenever several devices of
                // the same kind were nearby.
                Text(d.displayName,
                    color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                // THE FOUR LINES ARE SHARED, line for line, with iOS DashboardView nearestCard:
                // the name, `inlineCategory · NODE xxxx` (the lowercase category on both phones,
                // never the type label), the last-heard age on its own dim line, then
                // `source · seen N×` faint. The age stands alone so neither line has to wrap
                // beside the glyph and the dBm column.
                Text("${d.type.inlineCategory} · NODE ${nodeName(d.mac)}",
                    color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                Text(age, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                Text("${d.sourceLabel} · seen ${d.count}×",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text("${d.rssi}", color = Acab.accentText, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
                Text("dBm", color = Acab.dim, fontSize = 9.sp, fontFamily = Acab.mono)
                SignalBars(rssiBars(d.rssi), tint = d.type.tone())
            }
            Spacer(Modifier.size(10.dp))
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
                modifier = Modifier.size(20.dp))
        }
    }
}

/** "they're watching. watch back." Pinned against fontScale (divide by it) like iOS: this is
 *  brand ornament, not information, and at accessibility sizes it wrapped into the layout's
 *  budget while carrying nothing a screen reader or low-vision user needs larger. */
@Composable
private fun PunkLine() {
    val fs = LocalDensity.current.fontScale
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("they're watching. ", color = Acab.dim, fontSize = 14.sp / fs, fontWeight = FontWeight.Medium)
        Text("watch back.", color = Acab.accentText, fontSize = 14.sp / fs, fontWeight = FontWeight.Medium,
            fontStyle = FontStyle.Italic)
    }
}

/** Last 4 hex of the MAC, uppercased: a short node handle. */
private fun nodeName(mac: String): String = mac.replace(":", "").takeLast(4).uppercase()
