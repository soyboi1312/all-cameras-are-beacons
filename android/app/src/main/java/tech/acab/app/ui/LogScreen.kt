package tech.acab.app.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.automirrored.filled.PlaylistAddCheck
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.RadioButtonChecked
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceNames
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.displayName
import tech.acab.app.model.customName
import tech.acab.app.model.maker
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.vendor
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import tech.acab.app.model.bufferHealthNotices
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.textTone
import tech.acab.app.ui.theme.tone
import java.io.File
import java.text.Normalizer
import tech.acab.app.model.hasName
import androidx.compose.ui.text.style.TextOverflow

/** Seed for the Log's lens: everything, only-new-since-the-watermark, or one category.
 *  Public so callers (MainScreen deep links) can seed LogScreen with an initial filter.
 *  Internally the screen splits this into two composable axes (category x scope, like
 *  iOS), so a seed only picks the starting position of one axis. */
sealed interface LogFilter {
    data object All : LogFilter
    data object NewOnly : LogFilter
    data object OfflineOnly : LogFilter
    data class Category(val key: String) : LogFilter
}

/** The scope axis of the log lens: everything, only-new (after the seen watermark), or
 *  only offline-buffered records. Composes with the nullable category filter, matching
 *  iOS StatusScope, so ALPR+NEW is one lens rather than two mutually exclusive ones. */
internal enum class LogScope { All, New, Offline }
internal enum class LogSort { Newest, Strongest }

/** The three Unicode general categories NFD leaves behind once it has split an accent off its
 *  base letter. Three raw Int comparisons and deliberately NOT a set: this question is asked once
 *  per code point of every searchable field of every row that is (re)folded, and a `setOf(...)`
 *  written inside that loop allocates a vararg array, a LinkedHashSet and its backing map PER
 *  CHARACTER. */
private fun isCombiningMarkType(type: Int): Boolean =
    type == Character.NON_SPACING_MARK.toInt() ||
        type == Character.COMBINING_SPACING_MARK.toInt() ||
        type == Character.ENCLOSING_MARK.toInt()

/** ONE fold on both platforms: NFD, drop every combining mark (Mn / Mc / Me), then the SIMPLE
 *  per-code-point lowercase mapping. "Café" -> "cafe", "Straße" stays "straße" (no ß -> ss
 *  expansion, no ligature expansion: NFD is not NFKD), "İ" -> "i" because NFD splits its dot off
 *  first. Walked by code point, not UTF-16 unit, so a supplementary letter lowercases instead of
 *  passing through as two untouched surrogates. TWIN: iOS `DetectionLogQuery.fold` in
 *  DetectionLogLens.swift - same three steps, same answers; LogExportLensTest and
 *  DetectionLogLensTests pin "Café", "Straße" and U+00A0. */
private fun normalizedLogSearch(value: String): String {
    // ASCII fast path. Lowercasing maps only A-Z within ASCII and there are no combining marks to
    // strip there, so for a pure-ASCII value the transform below is exactly `lowercase()`. MACs,
    // OUI vendors, type labels and category keys are all ASCII and are most of what a row
    // contributes; the full transform still runs for anything a device (or the user) actually
    // spelled with accents.
    if (value.all { it.code < 0x80 }) return value.lowercase()
    val decomposed = Normalizer.normalize(value, Normalizer.Form.NFD)
    return buildString(decomposed.length) {
        var i = 0
        while (i < decomposed.length) {
            val cp = decomposed.codePointAt(i)
            if (!isCombiningMarkType(Character.getType(cp))) {
                appendCodePoint(Character.toLowerCase(cp))
            }
            i += Character.charCount(cp)
        }
    }
}

/** The Unicode White_Space set, spelled out: Zs / Zl / Zp (`isSpaceChar`, which is what admits a
 *  no-break space, U+2007 and U+202F) plus the five ASCII controls and NEL. Spelled out rather
 *  than `\\s`, because that class is ICU-backed on a device but ASCII-only on the host JVM the
 *  unit tests run on, and a tokenizer that behaves differently under test is no tokenizer.
 *  TWIN: iOS `Character.isWhitespace`, the same property, in DetectionLogQuery.init. */
private fun isLogTokenSeparator(cp: Int): Boolean =
    Character.isSpaceChar(cp) || cp in 0x09..0x0D || cp == 0x85

/** Split a folded query on [isLogTokenSeparator]; empty pieces (leading, trailing, or between two
 *  separators) are dropped, so any run of whitespace is one boundary. */
private fun splitLogTokens(folded: String): List<String> {
    val out = ArrayList<String>()
    var start = -1
    var i = 0
    while (i < folded.length) {
        val cp = folded.codePointAt(i)
        val width = Character.charCount(cp)
        if (isLogTokenSeparator(cp)) {
            if (start >= 0) { out.add(folded.substring(start, i)); start = -1 }
        } else if (start < 0) {
            start = i
        }
        i += width
    }
    if (start >= 0) out.add(folded.substring(start))
    return out
}

/** Per-row folded haystack, kept ACROSS publishes. The store republishes every ~300 ms while
 *  detections stream and hands the lens a new list each time, but a re-sighted row differs from
 *  its predecessor in RSSI / count / lastSeen only: nothing the search reads moved. Without this,
 *  every publish re-derived the nine identity fields and re-folded them for all 5,000 retained
 *  rows, in composition on the main thread, for as long as a query was typed.
 *
 *  An entry is reused while the row's identity text is unchanged: the six wire fields the nine
 *  searched strings derive from (mac, name, rid, detail, type, method) plus the
 *  [DeviceNames.revision] the customName rung reads through. Any of those moving refolds that one
 *  row; a rename refolds all of them, once, on the next pass. Entries are pruned only when the map
 *  has outgrown the feed by [PRUNE_SLACK], so an unchanged feed never pays a walk.
 *  TWIN: iOS `DetectionLogSearchIndex` in DetectionLogLens.swift - same key, same reuse rule,
 *  same prune. */
internal class LogSearchIndex {
    private class Entry(
        val mac: String,
        val name: String?,
        val rid: String?,
        val detail: String?,
        val type: DeviceType,
        val method: Int,
        val namesRevision: Int,
        val searchable: String,
        var lastPass: Int,
    ) {
        /** Built on first demand only: an ordinary word query never consults it. */
        var compactMac: String? = null
    }

    private val entries = HashMap<String, Entry>()
    private var pass = 0
    private var touched = 0

    /** Folds performed since construction. Tests read it to prove that a publish which changed
     *  only RSSI reused the entry, and that a name change did not. */
    var folds = 0
        private set

    /** Bracket one lens pass: [endPass] prunes entries no row touched, but only once the map has
     *  outgrown the feed, and never after a pass that consulted nothing (an empty query). */
    fun beginPass() {
        pass++
        touched = 0
    }

    fun endPass(feedSize: Int) {
        if (touched == 0 || entries.size <= feedSize + PRUNE_SLACK) return
        val current = pass
        entries.values.removeIf { it.lastPass != current }
    }

    fun searchable(d: Detection): String = entry(d).searchable

    fun compactMac(d: Detection): String {
        val e = entry(d)
        e.compactMac?.let { return it }
        // The MAC is ASCII, so its fold is a plain lowercase; the separators come out so a hex
        // token pasted with or without ':'/'-' matches either way.
        val compact = normalizedLogSearch(d.mac).filter { it != ':' && it != '-' }
        e.compactMac = compact
        return compact
    }

    private fun entry(d: Detection): Entry {
        val revision = DeviceNames.revision
        touched++
        val cached = entries[d.id]
        if (cached != null && cached.namesRevision == revision && cached.mac == d.mac &&
            cached.name == d.name && cached.rid == d.rid && cached.detail == d.detail &&
            cached.type == d.type && cached.method == d.method
        ) {
            cached.lastPass = pass
            return cached
        }
        folds++
        val built = Entry(
            d.mac, d.name, d.rid, d.detail, d.type, d.method, revision, foldRow(d), pass,
        )
        entries[d.id] = built
        return built
    }

    private companion object {
        /** Entries beyond the feed size tolerated before a prune walks the map. */
        const val PRUNE_SLACK = 512

        /** The one place the Log derives a row's whole identity instead of reading stored fields. */
        fun foldRow(d: Detection): String {
            // THE SAME FIELD SET iOS SEARCHES, in the same order: DetectionLogQuery.foldedHaystack
            // in DetectionLogLens.swift. One lens, one owner - it decides both what the list shows
            // and what the CSV/GPX export carries, so a field on one platform only means the same
            // query returns different evidence on the two phones.
            //
            // `displayName` is deliberately absent, and leaving it out searches exactly the same
            // text: it returns customName, name, rid, maker or type.label and nothing else, and
            // all five are listed in their own right, so naming them directly drops a second
            // `maker` derivation per row. The NODE handle is absent for a different reason: the
            // visible "NODE 1A2B" chip is the row's last four address characters, which the
            // compact-address path already answers, and baking the constant word "node" into
            // every row's haystack made a bare `node` query match the whole feed while the lens
            // chip and the export slug both claimed a search was narrowing it.
            val fields = listOfNotNull(
                d.customName, d.name, d.maker, d.ouiVendor, d.vendor, d.mac, d.rid,
                d.type.label, d.type.category,
            )
            return normalizedLogSearch(fields.joinToString(" "))
        }
    }
}

/** Parsed once for a Log lens. Ordinary words remain literal after case/diacritic folding: a
 * hyphenated query does not accidentally match two words. Only an all-hex token (at least two
 * digits, after removing ':'/'-') gains separator-insensitive matching against the MAC itself. */
internal class PreparedLogQuery(query: String) {
    private data class Token(val text: String, val compactAddress: String?)

    private val tokens = splitLogTokens(normalizedLogSearch(query))
        .map { text ->
            val address = text.filter { it != ':' && it != '-' }
            Token(text, address.takeIf { compact ->
                compact.length >= 2 && compact.all { it in '0'..'9' || it in 'a'..'f' }
            })
        }

    val isEmpty: Boolean get() = tokens.isEmpty()

    /** Answered once for the whole lens rather than once per row: without a hex-shaped token
     * nothing ever consults the separator-stripped MAC, so no row needs to build one. */
    private val hasAddressToken = tokens.any { it.compactAddress != null }

    /** Called for every retained row on every pass, so the folded haystack comes from [index],
     *  which keeps it across publishes; only a row whose identity text moved is derived and folded
     *  again (see [LogSearchIndex]). Treat it as a hot path: nothing here may grow to a per-row
     *  allocation on the reuse path. */
    fun matches(d: Detection, index: LogSearchIndex): Boolean {
        if (isEmpty) return true
        val searchable = index.searchable(d)
        // The MAC is already inside `searchable`; the compact form exists only so a hex token can
        // match across ':'/'-'. An ordinary word query never asks the index for it.
        val compactMac = if (hasAddressToken) index.compactMac(d) else ""
        return tokens.all { token ->
            if (searchable.contains(token.text)) return@all true
            val address = token.compactAddress
            address != null && compactMac.contains(address)
        }
    }
}

/** [index] is the caller's cross-publish haystack cache (LogScreen remembers one for the life of
 *  the screen); a one-shot caller may let the default build a throwaway. */
internal fun filterLogRows(
    feed: List<Detection>,
    category: String?,
    scope: LogScope,
    newIds: Set<String>,
    watchedMacs: Set<String> = emptySet(),
    query: String = "",
    sort: LogSort = LogSort.Newest,
    index: LogSearchIndex = LogSearchIndex(),
): List<Detection> {
    val preparedQuery = PreparedLogQuery(query)
    index.beginPass()
    val filtered = feed.filter { d ->
        d.matchesCategoryFilter(category, watchedMacs) && when (scope) {
            LogScope.All -> true
            LogScope.New -> d.id in newIds
            LogScope.Offline -> d.offline
        } && preparedQuery.matches(d, index)
    }
    index.endPass(feed.size)
    if (sort == LogSort.Newest) return filtered
    // Explicit source index makes the newest-first input order the deterministic tie-breaker even
    // if the standard-library sort implementation changes.
    return filtered.withIndex()
        .sortedWith(compareByDescending<IndexedValue<Detection>> { it.value.rssi }
            .thenBy { it.index })
        .map { it.value }
}

/** The lens-summary line under the search field: how many rows the lens shows out of the list it
 *  is reading, which is the FROZEN list while paused. It names that list, because the header
 *  kicker beside it counts the live store: "5 of 5 paused" under "200 NEW" must not read as 195
 *  lost sightings. [category] is the lit tile's key, appended as " · ALPR".
 *  TWIN: iOS `logLensSummary` in DetectionsView.swift, byte-identical text; pinned by
 *  LogExportLensTest. */
internal fun logLensSummaryText(shown: Int, total: Int, paused: Boolean, category: String?): String =
    "$shown of $total" + (if (paused) " paused" else " retained") + (category?.let { " · $it" } ?: "")

/** The spoken form of [logLensSummaryText]. TWIN: the accessibilityLabel on iOS `logLensSummary`,
 *  byte-identical. */
internal fun logLensSummaryDescription(
    shown: Int, total: Int, paused: Boolean, category: String?,
): String =
    "$shown matching detections of $total" +
        (if (paused) " in the paused log" else " retained") + (category?.let { " · $it" } ?: "")

private tailrec fun Context.hostActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.hostActivity()
    else -> null
}

/** One entry in the ordered category set for the tile strip. [type] supplies the tone +
 *  glyph, [key] is the DeviceType.category the filter matches on, [label] is the short tile
 *  caption. Defined once (mirrors iOS + MapScreen) so a new category is added in one place.
 *  "Nearby Device" is deliberately absent: it is ambient noise, not a filter category. */
private data class LogCategory(val type: DeviceType, val key: String, val label: String)

private val LOG_CATEGORIES = listOf(
    LogCategory(DeviceType.FLOCK_CAMERA, "ALPR", "ALPR"),
    LogCategory(DeviceType.DRONE, "DRONE", "DRONE"),
    LogCategory(DeviceType.BODY_CAM, "BODY CAM", "BODY"),
    LogCategory(DeviceType.TRACKER, "TRACKER", "TRKR"),
    LogCategory(DeviceType.GLASSES, "GLASSES", "GLAS"),
    LogCategory(DeviceType.NETWORK_CAMERA, "CAMERA", "NETCAM"),
    // Overlay lens: current stars keep their underlying type; historical firmware t=8 rows also
    // belong. Membership is resolved by isWatchedFilterMember, not DeviceType.category alone.
    LogCategory(DeviceType.WATCHED, WATCHED_FILTER_KEY, "WATCH"),
)

/** AND-PERF-2: header tallies computed in one pass over the list, instead of ~seven full
 *  O(n) scans (count() x5 + new + offline) on every ~3 Hz recomposition. [newIds] is the
 *  batch newIdSet result (ONE storeLock take per publish), shared by the NEW count, the
 *  NEW scope filter, and every row's new-dot so none of them re-take the lock per row. */
private class LogTallies(
    val byCategory: Map<String, Int>,
    val newIds: Set<String>,
    val offlineCount: Int,
)

/** Logbook: detection history with category tiles that double as filters, a new/all
 *  segmented filter, select-mode for batch-ignoring, and a "mark all seen" watermark.
 *  [initialFilter] seeds the filter on first composition (drive-mode notifications
 *  deep-link here with NewOnly); null keeps the default ALL lens.
 *  [selectedId] is the currently open dossier in the tablet two-pane layout; the matching
 *  row gets a subtle highlight. null (the phone default) means no row is highlighted. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun LogScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit,
    initialFilter: LogFilter? = null,
    selectedId: String? = null,
    pauseStateKey: String = "main",
) {
    // Evidence history keeps prior sightings even while an active mute suppresses Status/Map.
    val detections by ble.logDetections.collectAsState()
    val watchedList by ble.watched.collectAsState()
    val watchedMacs = remember(watchedList) {
        watchedList.mapTo(HashSet(watchedList.size)) { it.mac.lowercase() }
    }
    val ignoredRules by ble.ignored.collectAsState()
    // A HERE mute can cross its boundary without changing the persisted rule. The active
    // projection is therefore an invalidation input for the row's current MUTED state.
    val activeProjection by ble.detections.collectAsState()
    val watermark by ble.seenWatermark.collectAsState()   // recomposes "New only" when it moves
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val context = LocalContext.current
    val coScope = rememberCoroutineScope()   // for the CSV export; `scope` below is the log lens
    var exportMenuOpen by remember { mutableStateOf(false) }   // EXPORT chip dropdown (CSV / GPX)
    // Two independent lens axes, ANDed together like iOS: a nullable category filter and a
    // three-way scope. A seed only positions the axis it names; the other stays at default.
    // rememberSaveable (under MainScreen's per-tab SaveableStateProvider): a tab switch or a
    // rotation must not reset a lens the user set. Deep-link re-seeding still works because
    // the key(logScreenKey) wrapper discards this state when a fresh seed arrives.
    var catFilter by rememberSaveable { mutableStateOf((initialFilter as? LogFilter.Category)?.key) }
    var scope by rememberSaveable {
        mutableStateOf(
            when (initialFilter) {
                LogFilter.NewOnly -> LogScope.New
                LogFilter.OfflineOnly -> LogScope.Offline
                else -> LogScope.All
            }
        )
    }
    var searchQuery by rememberSaveable { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(LogSort.Newest) }

    // First ordinary open of the log baselines the New dots to what is already here, so a fresh
    // install / first offline backlog is not a wall of red dots. Once-only (persisted flag inside).
    // Skipped when we arrived via a NEW deep-link, or the baseline would mark the very rows the
    // deep-link exists to show. From here on the watermark advances on Log-tab leave (MainScreen).
    LaunchedEffect(Unit) {
        if (initialFilter != LogFilter.NewOnly) ble.seedSeenWatermarkOnce()
    }

    // Select mode: a set of selected detection ids (empty set = not in select mode).
    var selectMode by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var confirmClear by remember { mutableStateOf(false) }   // gate the destructive log wipe

    // Pause/resume the live feed. On a busy drive the log scrolls too fast to read; pausing
    // FREEZES a snapshot of the feed so it holds still. New sightings keep landing in the store
    // (ble.detections advances underneath, nothing is dropped) - we just don't show them until
    // resume, which snaps back to live. `feed` is what the whole screen renders from.
    // A Boolean in rememberSaveable was not enough: after a tab switch or rotation the actual
    // frozen rows were gone and the screen silently re-froze at a newer feed. The activity-scoped
    // ViewModel owns both pieces. Separate keys keep the connected and saved-log surfaces apart.
    val pauseVm: LogViewModel = viewModel(key = "log-pause:$pauseStateKey")
    val paused = pauseVm.paused
    val frozen = pauseVm.frozen
    val feed = if (paused) frozen else detections
    // Ids in the frozen snapshot, so we can count how many NEW sightings have piled up since the
    // pause (by id: the capped feed also sheds old rows, so a size delta would undercount).
    val frozenIds = remember(frozen) { frozen.mapTo(HashSet(frozen.size)) { it.id } }
    // once per publish while paused, not per recomposition: the id-diff walks the whole feed
    val pausedNew = remember(paused, detections, frozenIds) {
        if (paused) detections.count { it.id !in frozenIds } else 0
    }
    fun togglePause() {
        if (pauseVm.paused) pauseVm.resume()
        else pauseVm.pause(ble.freezeFeedExport())
    }

    // one traversal per (detections, watermark) change; category counts via groupingBy, with
    // new/offline derived in the same pass. newIdSet reads the watermark, so it keys here.
    // Built off the LIVE store (iOS parity): while paused only the ROWS freeze; the tiles, the
    // seg-chip counts, the header's DETECTED count and the NEW tally keep climbing, and the
    // PAUSED pill words the frozen list. The lens-summary line under the search field is the one
    // exception - it counts the frozen `feed` it is describing, which is why that line names the
    // list it counted rather than leaving the number bare.
    // The per-row isNewSinceWatermark would take storeLock once per row; newIdSet is ONE take.
    val tallies = remember(detections, watermark, watchedMacs) {
        val byCategory = detections.groupingBy { it.type.category }.eachCount().toMutableMap()
        // WATCHED overlaps every ordinary category: a starred tracker counts in both TRACKER and
        // WATCHED, while a historical t=8 row counts only once in WATCHED.
        byCategory[WATCHED_FILTER_KEY] = watchedDetectionCount(detections, watchedMacs)
        val newIds = ble.newIdSet(detections)
        var offlineCount = 0
        for (d in detections) {
            if (d.offline) offlineCount++
        }
        LogTallies(byCategory, newIds, offlineCount)
    }
    // New-ness for the DISPLAYED rows: while paused the frozen snapshot can hold rows the live
    // store has since evicted, so their ids get their own watermark check (one extra lock take,
    // and only while paused). Live, this is exactly tallies.newIds.
    val rowNewIds = if (!paused) tallies.newIds
                    else remember(pauseVm.frozenExport, watermark) {
                        pauseVm.frozenExport?.let(ble::newIdSet) ?: emptySet()
                    }
    // Time quality per row, one locked read for the whole feed rather than one per visible row.
    // Keyed on the revision as well as the feed: bracketing lands at the END of a drain, long
    // after the rows themselves were published, and the feed alone wouldn't notice.
    val timeRev by ble.timeBasisRev.collectAsState()
    val timeBases = remember(feed, timeRev, paused, pauseVm.frozenExport) {
        if (paused) {
            pauseVm.frozenExport?.rows
                ?.associate { it.detection.id to it.timeBasis }
                ?: emptyMap()
        } else {
            ble.timeBasisMap(feed)
        }
    }
    fun count(cat: String) = tallies.byCategory[cat] ?: 0
    val newCount = tallies.newIds.size
    val offlineCount = tallies.offlineCount

    // WATCHED is the sole category that can disappear because the user unstarred its last current
    // member. Historical t=8 rows keep the count nonzero. Reset instead of leaving a hidden active
    // lens with no chip available to clear it.
    LaunchedEffect(catFilter, count(WATCHED_FILTER_KEY)) {
        if (catFilter == WATCHED_FILTER_KEY && count(WATCHED_FILTER_KEY) == 0) catFilter = null
    }

    // memoized per (feed, axes, rowNewIds) so a filtered list isn't re-scanned on every
    // unrelated recomposition (select-mode taps, pause chip, sheet state). Both axes AND
    // together, so ALPR+NEW is a real lens (iOS parity). A publish that DID change the feed (a
    // re-sighted row's RSSI) still re-lenses, but through `searchIndex`, which keeps every row's
    // folded haystack across publishes and refolds only a row whose identity text moved
    // (LogSearchIndex says which fields), so the rebuild is a substring test per row, not a
    // nine-field derivation plus a fold. `DeviceNames.revision` is a key because the search
    // reads custom names and `watchedMacs` cannot see a relabel; iOS keys its LogLensMemo on the
    // watched and ignored lists for the same reason.
    val searchIndex = remember { LogSearchIndex() }
    val namesRevision = DeviceNames.revision
    val shown = remember(
        feed, catFilter, scope, rowNewIds, watchedMacs, searchQuery, sort, namesRevision,
    ) {
        filterLogRows(feed, catFilter, scope, rowNewIds, watchedMacs, searchQuery, sort, searchIndex)
    }
    // O(1) invalidation token; only visible lazy rows evaluate isIgnored. Building a 5,000-row
    // muted set at the ~3 Hz feed cadence would turn a UI badge into an avoidable hot-path scan.
    val muteRevision = 31 * System.identityHashCode(ignoredRules) +
        System.identityHashCode(activeProjection)

    fun exitSelect() { selectMode = false; selected = emptySet() }

    /** [gpx] false = the CSV evidence file, true = GPX for a mapping app.
     *
     *  Exports whatever the log is CURRENTLY FILTERED TO, not the whole history. That is what the
     *  button appears to promise while a category tile is lit, and the alternative (silently
     *  handing over everything) is the worse surprise for this product in particular. The chosen
     *  category also lands in the FILENAME, so a partial export cannot be mistaken for a complete
     *  one once it has left the app. */
    fun exportLog(gpx: Boolean = false, wholeLog: Boolean = false) {
        // The file write goes to IO (a Desert-mode log can be thousands of rows, which
        // would jank the main thread); the share sheet fires back on Main once it's done.
        // Freeze before launching IO. For a routine export this is EXACTLY the currently shown
        // live/paused + category + NEW/OFFLINE lens. The Clear-sheet escape hatch is the sole
        // whole-store path because it is about to delete the whole store.
        val exportSnapshot = when {
            wholeLog -> ble.freezeWholeLogExport()
            paused -> pauseVm.exportSnapshot(shown)
                // This invariant should be unreachable because pause publishes metadata before
                // paused=true. Fail closed instead of ever re-reading mutable/evictable maps.
                ?: run {
                    Toast.makeText(context.applicationContext,
                        "Couldn't export the paused snapshot; resume and try again.",
                        Toast.LENGTH_LONG).show()
                    return
                }
            else -> ble.freezeLogExport(shown.toList())
        }
        // The filename slug's vocabulary is ONE rule on both platforms, in this order: the
        // category key, new or offline, search, strongest, paused, joined by "-". TWIN: iOS
        // `exportQualifier` in DetectionsView.swift, same words, same order; writeDetections
        // lowercases the whole slug there the way the category is lowercased here.
        val slugParts = if (wholeLog) emptyList() else buildList {
            catFilter?.let { add(it.lowercase().replace(' ', '-')) }
            when (scope) {
                LogScope.All -> Unit
                LogScope.New -> add("new")
                LogScope.Offline -> add("offline")
            }
            if (searchQuery.isNotBlank()) add("search")
            if (sort == LogSort.Strongest) add("strongest")
            if (paused) add("paused")
        }
        val appContext = context.applicationContext
        coScope.launch {
            var packageDir: File? = null
            try {
                val send = withContext(Dispatchers.IO) {
                    val slug = slugParts.takeIf { it.isNotEmpty() }
                        ?.joinToString(prefix = "-", separator = "-") ?: ""
                    val ext = if (gpx) "gpx" else "csv"
                    val dir = createExportPackage(appContext.cacheDir, "log-exports")
                    packageDir = dir
                    try {
                        // Preserve the readable leaf while the UUID parent makes the bytes
                        // immutable for receivers that read after a later export starts.
                        val file = File(dir, "acab-detections$slug.$ext")
                        file.writeText(if (gpx) ble.renderDetectionsGpx(exportSnapshot)
                            else ble.renderDetectionsCsv(exportSnapshot))
                        val uri = FileProvider.getUriForFile(
                            appContext, "${appContext.packageName}.fileprovider", file)
                        Intent(Intent.ACTION_SEND).apply {
                            // application/gpx+xml is the registered type; mapping apps key their
                            // share-sheet filters off it, and text/xml hides the Gaia importer.
                            type = if (gpx) "application/gpx+xml" else "text/csv"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = android.content.ClipData.newUri(
                                appContext.contentResolver, file.name, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                    } catch (e: Throwable) {
                        runCatching { dir.deleteRecursively() }
                        packageDir = null
                        throw e
                    }
                }
                // The composition scope is cancelled on rotation, but check the host explicitly
                // too: no stale Activity captured before IO may receive the chooser.
                val activity = context.hostActivity()?.takeUnless {
                    it.isFinishing || it.isDestroyed
                } ?: throw IllegalStateException("this screen is no longer available; try again")
                activity.startActivity(Intent.createChooser(send, "Export detections"))
                // A receiving app can keep reading after the chooser closes. Once launch succeeds,
                // cleanup belongs to the age bound (ExportCache.kt EXPORT_PACKAGE_MAX_AGE_MS, at
                // the next export and at app start) and to the real Clear log; never delete this
                // package in our finally path.
                packageDir = null
            } catch (e: CancellationException) {
                packageDir?.let { runCatching { it.deleteRecursively() } }
                throw e
            } catch (e: Throwable) {
                packageDir?.let { runCatching { it.deleteRecursively() } }
                Toast.makeText(
                    context.applicationContext,
                    "Couldn't export detections: ${e.message ?: "write failed"}",
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    // T2: cap the readable list width and center it, so a tablet/landscape viewport stops
    // stretching one column across the whole screen. At phone width the 640 cap is a no-op.
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    LazyColumn(
        Modifier
            .widthIn(max = 640.dp)
            .fillMaxSize()
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp),
        // The select bar is an overlay; reserve its full two-row/large-text height so the final
        // evidence rows remain scrollable above it rather than disappearing underneath.
        contentPadding = PaddingValues(bottom = if (selectMode) 136.dp else 16.dp),
    ) {
        // No spacedBy here: the log rows below must sit flush so they read as one panel,
        // so each section item carries its own bottom padding instead.
        item {
            Column(
                Modifier.padding(bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Logbook", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    // The live store's count and the NEW tally, both counting the live store
                    // even while paused (the PAUSED pill on the card heading words the frozen
                    // list, and the lens-summary line under the search field carries the
                    // shown/feed ratio). In select mode the count is the selection.
                    // TWIN: iOS `header` in DetectionsView.swift, byte-identical kicker.
                    Kicker(
                        if (selectMode) "${selected.size} SELECTED"
                        else "${detections.size} DETECTED · $newCount NEW"
                    )
                }
                // Board-side loss/censoring flags belong beside the evidence, not buried in
                // settings. They are persistent and intentionally cannot be dismissed locally.
                status?.bufferHealthNotices?.forEach { BufferHealthBanner(it) }
                // Labeled action chips, like the iOS header; hidden until there's data and
                // during select mode (a stray SELECT re-tap would wipe the checks, and MARK
                // SEEN would clear the new-dots mid-triage).
                // Clear lives at the end of the list, not up here with the routine actions.
                if (!selectMode && detections.isNotEmpty()) {
                    // horizontalScroll so no chip is ever clipped out of reach: the row holds up
                    // to three chips (SELECT, EXPORT, MARK SEEN), and a filtered EXPORT label
                    // ("EXPORT BODY CAM") is much wider than the plain one. It held four until
                    // CSV and GPX folded into the one EXPORT menu below.
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.horizontalScroll(rememberScrollState())) {
                        ActionChip(Icons.AutoMirrored.Filled.PlaylistAddCheck, "SELECT") {
                            // resume first: bulk-ignore acts on live rows (iOS parity)
                            pauseVm.resume()
                            selectMode = true; selected = emptySet()
                        }
                        // CSV and GPX used to be two chips. That spent two of the four slots in a
                        // row that already has to scroll on a phone on two variants of one action,
                        // so they fold into a single EXPORT chip with a menu (iOS parity). The
                        // chip still names the SCOPE when a category tile is lit ("EXPORT DRONE"),
                        // so a partial export can't be mistaken for the whole log.
                        Box {
                            ActionChip(Icons.Filled.IosShare,
                                catFilter?.let { "EXPORT $it" } ?: "EXPORT") { exportMenuOpen = true }
                            // Explicit colours: the app draws no MaterialTheme, so a bare
                            // DropdownMenu falls back to Material's light defaults.
                            val menuColors = MenuDefaults.itemColors(
                                textColor = Acab.text, leadingIconColor = Acab.dim)
                            DropdownMenu(expanded = exportMenuOpen, onDismissRequest = { exportMenuOpen = false },
                                containerColor = Acab.bg3) {
                                DropdownMenuItem(
                                    text = { Text("CSV, shown rows") },
                                    leadingIcon = { Icon(Icons.Filled.IosShare, contentDescription = null) },
                                    colors = menuColors,
                                    onClick = { exportMenuOpen = false; exportLog(false) })
                                DropdownMenuItem(
                                    text = { Text("GPX, shown rows") },
                                    leadingIcon = { Icon(Icons.Filled.Place, contentDescription = null) },
                                    colors = menuColors,
                                    onClick = { exportMenuOpen = false; exportLog(true) })
                            }
                        }
                        // Demo rows are disposable and must never advance the real persisted New
                        // watermark that is restored when sample mode exits.
                        if (!demo) {
                            // scope resets to ALL so the user is never stranded on an empty NEW lens
                            ActionChip(Icons.Filled.DoneAll, "MARK SEEN") {
                                ble.markAllSeen(); scope = LogScope.All
                            }
                        }
                    }
                }
            }
        }

        // All / New / Offline scope chips; they compose with the category tiles below.
        item {
            FlowRow(
                Modifier.fillMaxWidth().padding(bottom = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // R7: grey ALL, crimson NEW (match iOS), so "new" is the one that pops.
                SegChip("ALL", detections.size, scope == LogScope.All) { scope = LogScope.All }
                SegChip("NEW", newCount, scope == LogScope.New, activeTone = Acab.accent) { scope = LogScope.New }
                SegChip("OFFLINE", offlineCount, scope == LogScope.Offline) { scope = LogScope.Offline }
                if (!selectMode) {
                    // Pause/resume the live feed so a fast-scrolling log can be read. Only offered
                    // once there's something to freeze (or while already paused).
                    if (feed.isNotEmpty() || paused) {
                        PauseChip(paused = paused, onToggle = ::togglePause)
                    }
                    // quick clear: the bottom "clear log…" row is a long scroll once the log is big.
                    // same confirmation, quiet styling so it isn't a mis-tap magnet. Icon-only
                    // (trash reads on its own): with the three counted seg chips to the left, a
                    // worded chip is what made "CLEAR" wrap mid-word on a 411dp-wide screen.
                    // Sample mode covers the real in-memory store with disposable rows. Hide the
                    // destructive affordance so its copy never implies the retained disk log will
                    // be erased; the manager also guards the persistence boundary defensively.
                    if (!demo) {
                        Row(
                            Modifier
                                .minimumInteractiveComponentSize()
                                .clip(RoundedCornerShape(50))
                                .border(1.dp, Acab.line, RoundedCornerShape(50))
                                .clickable { confirmClear = true }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.DeleteOutline, contentDescription = "Clear log",
                                tint = Acab.dim, modifier = Modifier.size(15.dp))
                        }
                    }
                }
            }
        }

        // Search and ordering apply INSIDE the category + ALL/NEW/OFFLINE lens. They share one row
        // whenever the field keeps its whole placeholder with the widest sort chip beside it
        // (rememberLogSearchFitsBesideSort measures both); otherwise the sort drops under the
        // field rather than squeezing its hint into an unreadable sliver. The old fixed rule
        // (stack below 380dp) stacked on every ~411dp phone, costing a full row of first screen.
        // DELIBERATE PLATFORM DIFFERENCE, kept since 2.0.8: here search and sort sit below the
        // ALL/NEW/OFFLINE chips; on iPhone they sit above the category tiles
        // (DetectionsView.searchAndSort, which names this file).
        item {
            Column(
                Modifier.fillMaxWidth().padding(bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                BoxWithConstraints(Modifier.fillMaxWidth()) {
                    if (!rememberLogSearchFitsBesideSort(maxWidth)) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            LogSearchField(searchQuery, { searchQuery = it }, Modifier.fillMaxWidth())
                            LogSortControl(sort, { sort = it })
                        }
                    } else {
                        Row(
                            Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            LogSearchField(searchQuery, { searchQuery = it }, Modifier.weight(1f))
                            LogSortControl(sort, { sort = it })
                        }
                    }
                }
                // The shown/feed ratio in its own line, like iOS logLensSummary: it counts the
                // list the lens is reading (the FROZEN one while paused) and names it, so the
                // header kicker above can count the live store the way its NEW tally does.
                Text(
                    logLensSummaryText(shown.size, feed.size, paused, catFilter),
                    color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                    modifier = Modifier.semantics {
                        contentDescription =
                            logLensSummaryDescription(shown.size, feed.size, paused, catFilter)
                    },
                )
            }
        }

        // Category tile strip; each tile toggles the list filter. Dynamic: a tile appears
        // only once its category has a detection this session, so the strip grows with the
        // categories the board actually saw instead of a fixed hardcoded row.
        item {
            // Which tiles to draw: any category with a count, plus the active filter's
            // category. The active-filter exception keeps a tile visible while it is the
            // current filter even if its live count falls to 0 (eviction/staleness); without
            // it the tile would vanish out from under the user, leaving the list filtered with
            // no tile left to tap to clear it.
            val visibleCats = LOG_CATEGORIES.filter {
                val n = count(it.key)
                if (it.key == WATCHED_FILTER_KEY) n > 0 else n > 0 || it.key == catFilter
            }
            if (visibleCats.isNotEmpty()) {
                // Same rule as the Status strip: rows of three as soon as the widest label no
                // longer fits (rememberCategoryTilesPerRow measures it), so no label truncates.
                BoxWithConstraints(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
                    val perRow = rememberCategoryTilesPerRow(visibleCats.map { it.label }, maxWidth,
                        if (visibleCats.size > 6) 4 else visibleCats.size)
                    Column(verticalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                        visibleCats.chunked(perRow.coerceAtLeast(1)).forEach { rowCats ->
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(CategoryTileGap)) {
                                rowCats.forEach { c ->
                                    CategoryTile(c.type, c.key, c.label, count(c.key), catFilter, Modifier.weight(1f)) { catFilter = it }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (feed.isEmpty()) {
            item {
                val radiosOff = status?.let { !it.ble && !it.wifi } == true
                when {
                    demo -> EmptyState("Sample data mode.", null)
                    // no status frame at all = no board linked; "Scanning…" would be a lie
                    status == null -> EmptyState(
                        "No board linked.",
                        "connect your beacon, it does the listening",
                    )
                    radiosOff -> EmptyState("Radios are off, flip them on in Beacon.", null)
                    else -> EmptyState(
                        "Scanning…",
                        "Detections log here as beacons spots surveillance gear nearby.",
                    )
                }
            }
        } else if (shown.isEmpty()) {
            // Rows exist but the active lens hides them all (NEW with everything seen,
            // OFFLINE with no buffered rows, a pinned category tile at count 0, a query no row
            // matches): explain instead of a kicker over a blank void, and offer the same
            // one-tap reset iOS does (search, category and scope back to their defaults).
            item {
                NoMatchState(scope, catFilter, searchQuery) {
                    searchQuery = ""; catFilter = null; scope = LogScope.All
                }
            }
        } else {
            item {
                // Both axes read in one heading, the same literal as iOS `logHeading` in
                // DetectionsView.swift: "ALL DETECTIONS" when no category, "ALPR · NEW" when
                // both lenses are on. The search and the sort are not named here: the sort
                // control and the lens-summary line under the search field already word them.
                val scopeTag = when (scope) {
                    LogScope.All -> "ALL"
                    LogScope.New -> "NEW"
                    LogScope.Offline -> "OFFLINE"
                }
                val label = catFilter?.let { "$it · $scopeTag" } ?: "$scopeTag DETECTIONS"
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Kicker(label)
                    // The pause chip is icon-only, so this is what words the frozen state
                    // (even at zero backlog) and the pile-up behind it.
                    if (paused) PausedPill(pausedNew)
                }
                Spacer(Modifier.size(8.dp))
            }
            // Each row is its own lazy item (keyed), so a Desert-mode log of thousands
            // only composes the rows on screen instead of building every row at once.
            // Visually the rows form ONE panel: each item paints its slice of the shared
            // surface (PanelSegment) with hairline dividers between rows.
            itemsIndexed(shown, key = { _, d -> d.id }) { index, d ->
                PanelSegment(
                    isFirst = index == 0,
                    isLast = index == shown.lastIndex,
                    highlighted = selectedId != null && d.id == selectedId,
                ) {
                    DetectionRow(
                        d = d,
                        timeBasis = timeBases[d.id],
                        muted = remember(d.mac, muteRevision) { ble.isMutedForProjection(d.mac) },
                        selectMode = selectMode,
                        checked = d.id in selected,
                        onClick = {
                            if (selectMode) {
                                selected = if (d.id in selected) selected - d.id else selected + d.id
                            } else onSelect(d)
                        },
                    )
                    if (index != shown.lastIndex) HorizontalDivider(color = Acab.line)
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
            // every currently SHOWN (filtered) row, like iOS: select-all under an active
            // lens grabs just that lens's rows
            onSelectAll = { selected = shown.mapTo(HashSet(shown.size)) { it.id } },
            onIgnore = {
                val toIgnore = detections.filter { it.id in selected }
                val refused = ble.ignoreDevices(toIgnore)
                val requested = toIgnore.map { it.mac.lowercase() }.distinct().size
                val muted = (requested - refused).coerceAtLeast(0)
                val message = if (refused == 0) {
                    "$muted device${if (muted == 1) "" else "s"} muted. Existing history was kept."
                } else {
                    "$muted muted; $refused couldn't be added because the muted-device list is full."
                }
                Toast.makeText(context.applicationContext, message, Toast.LENGTH_LONG).show()
                exitSelect()
            },
        )
    }

    // Destructive log wipe needs a confirmation, with an export-first escape hatch. R6: a bottom
    // sheet with FULL-WIDTH STACKED buttons, so the three wide mono labels never crowd one row.
    if (confirmClear && !demo) {
        ModalBottomSheet(
            onDismissRequest = { confirmClear = false },
            containerColor = Acab.bg3,
        ) {
            Column(
                Modifier.padding(horizontal = Acab.pad).padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Clear ${detections.size} detection${if (detections.size == 1) "" else "s"}?", color = Acab.text,
                    fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    "This deletes the log on this phone, including the app's copies of earlier exports, " +
                        "and can't be undone. If this is evidence, export it first and save or send it " +
                        "somewhere else. Only a copy outside the app survives.",
                    color = Acab.dim, fontSize = 14.sp,
                )
                Spacer(Modifier.size(4.dp))
                OutlinedButton(
                    // ALWAYS the whole log, never the category filter. The button beside it
                    // deletes EVERYTHING, so a filtered export here would hand back a subset and
                    // then destroy the rest - the one place a partial export is silent data loss.
                    onClick = { exportLog(gpx = false, wholeLog = true); confirmClear = false },
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, Acab.line),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.dim),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) {
                    Text("EXPORT CSV FIRST", fontSize = 12.sp, letterSpacing = 0.5.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
                Button(
                    // Drop the frozen snapshot too, or a paused screen would keep showing rows
                    // the user just cleared from the store.
                    onClick = {
                        val cleared = ble.clearLog()
                        if (cleared) {
                            pauseVm.resume()
                            confirmClear = false
                        } else {
                            Toast.makeText(
                                context.applicationContext,
                                "Couldn't finish clearing the log yet. The app will retry safely; don't assume the history is gone.",
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Acab.accent, contentColor = Acab.onAccent),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) {
                    Text("CLEAR LOG", fontSize = 12.sp, letterSpacing = 0.5.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
                TextButton(onClick = { confirmClear = false }, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel", color = Acab.dim)
                }
            }
        }
    }
}

/** Labeled header action chip: capsule, small glyph, mono label. minimumInteractiveComponentSize
 *  keeps the capsule's look while growing the touch target to the 48dp accessibility floor. */
@Composable
private fun ActionChip(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(CircleShape)
            .background(Acab.bg2, CircleShape)
            .border(1.dp, Acab.line, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Acab.dim, modifier = Modifier.size(12.dp))
        Text(label, color = Acab.dim, fontSize = 10.sp, letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Freeze/resume the live feed. Icon-only, with the accent fill flagging the paused state:
 *  the worded PAUSE/RESUME chip crowded this row into wrapping CLEAR on narrower screens,
 *  and the [PausedPill] beside the log heading now words the state + backlog instead.
 *  Same capsule anatomy as the CLEAR pill it sits beside. */
@Composable
private fun PauseChip(paused: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(shape)
            .then(if (paused) Modifier.background(Acab.accent, shape) else Modifier.border(1.dp, Acab.line, shape))
            .clickable(onClick = onToggle)
            .semantics { stateDescription = if (paused) "Paused" else "Live" }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
            contentDescription = if (paused) "Resume live feed" else "Pause live feed",
            tint = if (paused) Acab.onAccent else Acab.dim,
            modifier = Modifier.size(15.dp),
        )
    }
}

/** Worded frozen-state pill beside the log heading (iOS parity): "PAUSED", or
 *  "PAUSED · N NEW" once sightings pile up behind the freeze. Shown even at zero
 *  backlog, so a frozen list never reads as a stalled scan. */
@Composable
private fun PausedPill(newCount: Int) {
    Text(
        if (newCount > 0) "PAUSED · $newCount NEW" else "PAUSED",
        color = Acab.accentText,
        fontSize = 9.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono,
        maxLines = 1,
        modifier = Modifier
            .background(Acab.accent.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** One lazy item's slice of a shared panel. Rows stay individually lazy (a Desert-mode
 *  log can hold thousands) but paint as one continuous card: the first slice rounds the
 *  top, the last rounds the bottom, and every slice draws the side borders by clipping
 *  an oversized rounded-rect outline so no horizontal hairline lands between rows. */
@Composable
private fun PanelSegment(isFirst: Boolean, isLast: Boolean, highlighted: Boolean = false, content: @Composable () -> Unit) {
    val shape = when {
        isFirst && isLast -> RoundedCornerShape(Acab.radius)
        isFirst -> RoundedCornerShape(topStart = Acab.radius, topEnd = Acab.radius)
        isLast -> RoundedCornerShape(bottomStart = Acab.radius, bottomEnd = Acab.radius)
        else -> RectangleShape
    }
    // Two-pane selection: the open dossier's row lifts to bg3 with a crimson-tinted edge.
    // highlighted is only ever true when a selectedId is passed (tablet), so phone stays flat.
    val fill = if (highlighted) Acab.bg3 else Acab.bg2
    val edge = if (highlighted) Acab.lineStrong else Acab.line
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(fill)
            .drawBehind {
                val stroke = 1.dp.toPx()
                val corner = Acab.radius.toPx()
                // extend past whichever edges join a neighbor; the clip trims the overflow
                val topExtend = if (isFirst) 0f else corner
                val bottomExtend = if (isLast) 0f else corner
                drawRoundRect(
                    color = edge,
                    topLeft = Offset(stroke / 2f, -topExtend + stroke / 2f),
                    size = Size(
                        size.width - stroke,
                        size.height + topExtend + bottomExtend - stroke,
                    ),
                    cornerRadius = CornerRadius(corner),
                    style = Stroke(stroke),
                )
            }
            .padding(horizontal = Acab.padCard),
    ) { content() }
}

@Composable
private fun LogSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        singleLine = true,
        leadingIcon = {
            Icon(Icons.Filled.Search, contentDescription = null, tint = Acab.dim,
                modifier = Modifier.size(17.dp))
        },
        trailingIcon = if (value.isNotEmpty()) ({
            Box(
                Modifier.minimumInteractiveComponentSize().clickable { onValueChange("") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, contentDescription = "Clear search", tint = Acab.dim,
                    modifier = Modifier.size(16.dp))
            }
        }) else null,
        placeholder = {
            // TWIN: the iOS search field's placeholder in DetectionsView.searchAndSort. M3 merges
            // MaterialTheme.typography.bodyLarge into this slot (its own face and 0.5sp tracking),
            // which used to override MainActivity's Space Grotesk, so the hint drew in Material's
            // face. LogSearchPlaceholderStyle pins the face AND the tracking, so the drawn hint is
            // exactly what rememberLogSearchFitsBesideSort measures; the Space Grotesk face (as on
            // iPhone) is a deliberate change made with it (2026-09-20).
            Text(LOG_SEARCH_PLACEHOLDER, color = Acab.faint,
                style = LocalTextStyle.current.merge(LogSearchPlaceholderStyle))
        },
        textStyle = androidx.compose.ui.text.TextStyle(
            color = Acab.text, fontSize = 14.sp, fontFamily = Acab.mono),
        shape = RoundedCornerShape(Acab.radiusSm),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Acab.text,
            unfocusedTextColor = Acab.text,
            cursorColor = Acab.accent,
            focusedBorderColor = Acab.accent,
            unfocusedBorderColor = Acab.line,
            focusedContainerColor = Acab.bg2,
            unfocusedContainerColor = Acab.bg2,
        ),
    )
}

internal const val LOG_SEARCH_PLACEHOLDER = "Search name, MAC or vendor"
private val LogSearchPlaceholderStyle =
    TextStyle(fontSize = 13.sp, fontFamily = Acab.display, letterSpacing = 0.sp)
private val LogSortLabelStyle = TextStyle(
    fontSize = 10.5.sp, fontFamily = Acab.mono, fontWeight = FontWeight.Bold, letterSpacing = 0.5.sp,
)

/** Field width that is not placeholder: the M3 leading-icon slot and its gap (52dp, read from the
 *  laid-out field on a 411dp emulator: the hint starts 52dp in) plus the M3 end padding (16dp). */
private val LogSearchFieldChrome = 68.dp

/** Sort chip width that is not label: 12dp padding each side, the 15dp icon and its 6dp gap
 *  (LogSortControl). */
private val LogSortChipChrome = 45.dp

/** The sort chip's words, shared by LogSortControl and the fit rule so they cannot drift. */
internal fun logSortChipLabel(sort: LogSort): String =
    if (sort == LogSort.Newest) "NEWEST" else "STRONGEST"

/** The widest sort chip label under [measure], over every sort the chip can show, so switching
 *  the sort never flips the layout. Pure apart from [measure], so it is unit-tested. */
internal fun widestSortChipLabel(measure: (String) -> Int): Int =
    LogSort.entries.maxOf { measure(logSortChipLabel(it)) }

/** Whether search and sort fit on one row with the whole placeholder showing. Pure, so the rule
 *  is unit-tested (LogSearchSortFitTest) apart from the measuring below. */
internal fun logSearchFitsBesideSort(
    rowWidthPx: Float, placeholderPx: Float, fieldChromePx: Float,
    gapPx: Float, widestSortLabelPx: Float, sortChromePx: Float,
): Boolean = rowWidthPx >= placeholderPx + fieldChromePx + gapPx + widestSortLabelPx + sortChromePx

/** [logSearchFitsBesideSort] for this screen. It measures the WIDER sort label, so switching
 *  between NEWEST and STRONGEST never flips the layout, and it re-measures only when the density
 *  (which carries the font scale) changes. */
@Composable
private fun rememberLogSearchFitsBesideSort(rowWidth: Dp): Boolean {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val placeholderStyle = LocalTextStyle.current.merge(LogSearchPlaceholderStyle)
    val sortStyle = LocalTextStyle.current.merge(LogSortLabelStyle)
    val widths = remember(density, placeholderStyle, sortStyle) {
        val hint = measurer.measure(AnnotatedString(LOG_SEARCH_PLACEHOLDER), placeholderStyle,
            softWrap = false, maxLines = 1).size.width
        val sort = widestSortChipLabel {
            measurer.measure(AnnotatedString(it), sortStyle, softWrap = false, maxLines = 1).size.width
        }
        hint to sort
    }
    return with(density) {
        logSearchFitsBesideSort(rowWidth.toPx(), widths.first.toFloat(), LogSearchFieldChrome.toPx(),
            8.dp.toPx(), widths.second.toFloat(), LogSortChipChrome.toPx())
    }
}

@Composable
private fun LogSortControl(sort: LogSort, onSort: (LogSort) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.minimumInteractiveComponentSize()
                .clip(RoundedCornerShape(50))
                .border(1.dp, Acab.line, RoundedCornerShape(50))
                .clickable { open = true }
                .semantics(mergeDescendants = true) {
                    contentDescription = "Sort detections, ${if (sort == LogSort.Newest) "newest" else "strongest signal"}"
                }
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.AutoMirrored.Filled.Sort, contentDescription = null, tint = Acab.dim,
                modifier = Modifier.size(15.dp))
            Text(logSortChipLabel(sort),
                color = Acab.dim, style = LocalTextStyle.current.merge(LogSortLabelStyle))
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            containerColor = Acab.bg3,
        ) {
            listOf(LogSort.Newest to "Newest", LogSort.Strongest to "Strongest signal")
                .forEach { (choice, label) ->
                    DropdownMenuItem(
                        text = { Text(label) },
                        leadingIcon = {
                            if (sort == choice) Icon(Icons.Filled.CheckCircle,
                                contentDescription = null, modifier = Modifier.size(16.dp))
                        },
                        colors = MenuDefaults.itemColors(
                            textColor = Acab.text, leadingIconColor = Acab.accent),
                        onClick = { open = false; onSort(choice) },
                    )
                }
        }
    }
}

/** All / New-only segmented chip. */
@Composable
private fun SegChip(label: String, n: Int, active: Boolean, activeTone: Color = Acab.dim, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .background(if (active) activeTone else Acab.bg2, shape)
            .border(1.dp, if (active) Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .semantics { selected = active }
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

/** Compact category tile in the 5-across strip; highlighted when its filter is on.
 *  [key] is the category the filter matches on; [label] is the short display name.
 *  [activeKey] is the current category axis; tapping toggles just that axis (the
 *  NEW/OFFLINE scope composes independently), so [onFilter] hands back a key or null. */
@Composable
private fun CategoryTile(
    type: DeviceType, key: String, label: String, n: Int, activeKey: String?,
    modifier: Modifier = Modifier, onFilter: (String?) -> Unit,
) {
    val active = activeKey == key
    val spokenLabel = when (label) {
        "TRKR" -> "Tracker"
        "GLAS" -> "Glasses"
        "NETCAM" -> "Network camera"
        "BODY" -> "Body camera"
        "WATCH" -> "Watched or starred"
        else -> label
    }
    val shape = RoundedCornerShape(Acab.radiusSm)
    Column(
        modifier
            .minimumInteractiveComponentSize()
            .background(if (active) type.tone().copy(alpha = 0.12f) else Acab.bg2, shape)
            .border(1.dp, if (active) type.tone().copy(alpha = 0.4f) else Acab.line, shape)
            .clickable { onFilter(if (active) null else key) }
            .semantics(mergeDescendants = true) {
                selected = active
                contentDescription = "$spokenLabel, $n detection${if (n == 1) "" else "s"}"
            }
            .padding(horizontal = CategoryTileSidePadding, vertical = CategoryTileEndPadding),
        verticalArrangement = Arrangement.spacedBy(5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(type.icon(), contentDescription = null,
            tint = if (n == 0 && !active) Acab.faint else type.tone(), modifier = Modifier.size(14.dp))
        Text("$n", color = if (n == 0) Acab.faint else Acab.text,
            fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = if (active) type.textTone() else if (n == 0) Acab.faint else Acab.dim,
            style = LocalTextStyle.current.merge(CategoryTileLabelStyle), maxLines = 1)
    }
}

/** Font scale from which [DetectionRow] stacks instead of packing name, NODE and chips on one line.
 *  Measured on the beacon_play_36 AVD (411dp wide) with the sample data, from the laid-out title
 *  bounds in a uiautomator dump: beside NODE on a row with no other chip the name gets 139dp at
 *  1.3, 136dp at 1.35, 124dp at 1.5, 101dp at 1.8 and 85dp at 2.0, while the names grow with the
 *  scale. At 1.3 every sample name except the 14-character drone serial is whole. At 1.35 the
 *  longest maker name, "Apple Find My", is the first to lose letters; at 1.5 four of the six are
 *  cut; at 2.0 the Meta row, which also carries EXP, shows only "…". So 1.3 stays compact and
 *  1.35 up stacks. The stock font-size slider on that AVD steps from 1.3 straight to 1.5. */
private const val DETECTION_ROW_STACK_FONT_SCALE = 1.35f

/** One log row: glyph, name, source/method, RSSI + bars. Tap opens the dossier, or toggles
 *  the checkbox in select mode. From [DETECTION_ROW_STACK_FONT_SCALE] up it draws
 *  [StackedDetectionRow] instead. */
@Composable
private fun DetectionRow(
    d: Detection,
    timeBasis: TimeBasis?,
    muted: Boolean,
    selectMode: Boolean,
    checked: Boolean,
    onClick: () -> Unit,
) {
    // One outer node for both layouts, so the tap target and the spoken muted state cannot differ
    // between them.
    val rowModifier = Modifier.fillMaxWidth().clickable(onClick = onClick)
        .semantics { if (muted) stateDescription = "Muted, history retained" }
        .padding(vertical = 11.dp)
    if (LocalDensity.current.fontScale >= DETECTION_ROW_STACK_FONT_SCALE) {
        StackedDetectionRow(d, timeBasis, muted, selectMode, checked, rowModifier)
        return
    }
    Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
        if (selectMode) {
            SelectMark(checked)
            Spacer(Modifier.size(12.dp))
        }
        CatGlyph(d.type, size = 40)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // the advertised name when present, else the broadcast maker, else the type label
                //
                // weight(fill = false) makes the TITLE the flexible child, so Compose measures
                // the fixed-width siblings first. Without it a long title (a user rename has no
                // length cap) eats the whole Row and every chip after it is measured at 0dp and
                // clipped away: no NODE, no EXP, no OFFLINE, no time-basis tag. Those
                // chips are exactly what stops a reader trusting a reconstructed timestamp or
                // mistaking a buffer replay for a live sighting, so losing them is not cosmetic.
                // This is how SwiftUI's HStack already behaves on the iOS row; Android needed to
                // be told, and adding the NODE handle ahead of the chips made it reachable at
                // ordinary title lengths rather than only absurd ones. The cost is that the
                // title is what shrinks as the font grows, which is why large scales stack.
                Text(d.displayName, color = Acab.text, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold, maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                DetectionRowBadges(d, timeBasis, muted)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // weight(fill = false) + maxLines=1, same fix the TITLE row above carries: make
                // THIS text the flexible child so Compose measures the fixed-size chips (confidence,
                // the amber GPS-age pill) first and lets the source/method label ellipsize instead.
                // Without it, a narrow or large-font screen (a Pixel 2 with display size bumped)
                // overflowed this row: the label wrapped to two lines and the GPS-age pill was
                // shoved against the RSSI column. The subtitle never got the treatment the title did.
                Text(detectionRowSubtitle(d),
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                DetectionRowEvidenceChips(d)
            }
        }
        // Guaranteed gutter so the middle column's rightmost chip can never kiss the RSSI, even
        // if its content still runs to the column edge on some future locale/font combination.
        Spacer(Modifier.size(10.dp))
        DetectionRowSignal(d)
        Spacer(Modifier.size(8.dp))
        DetectionRowChevron()
    }
}

/** [DetectionRow] at large font scales. The compact row gives the name only what the fixed-width
 *  NODE handle, chips, RSSI column and chevron leave, so at 2.0 names shrank to "Floc…" and the
 *  Meta row to a bare "…". Here the name leaves the glyph row and takes the full row width with no
 *  line cap; NODE, each chip, the subtitle, confidence and the GPS age then get a line each, and
 *  the RSSI readout sits at the trailing edge of its own last line. The content order, and so the
 *  TalkBack order, is the compact row's.
 *  TWIN: iOS DetectionRow.accessibilityLayout, which stacks the same way at its own threshold
 *  (dynamicTypeSize.isAccessibilitySize). Chip order follows each platform's compact row, so MUTED
 *  comes before EXP here and after OFFLINE there. */
@Composable
private fun StackedDetectionRow(
    d: Detection,
    timeBasis: TimeBasis?,
    muted: Boolean,
    selectMode: Boolean,
    checked: Boolean,
    modifier: Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (selectMode) {
                SelectMark(checked)
                Spacer(Modifier.size(12.dp))
            }
            CatGlyph(d.type, size = 40)
            Spacer(Modifier.weight(1f))
            DetectionRowChevron()
        }
        // No maxLines: a cap would cut a long name short. A name of several words wraps between
        // them; a single token wider than the row (a drone serial, a rename) wraps inside itself.
        Text(d.displayName, color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            DetectionRowBadges(d, timeBasis, muted)
            Text(detectionRowSubtitle(d), color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
            DetectionRowEvidenceChips(d)
        }
        DetectionRowSignal(d, Modifier.align(Alignment.End))
    }
}

/** Select-mode checkbox, spoken as the row's selection state. */
@Composable
private fun SelectMark(checked: Boolean) {
    Icon(
        if (checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
        contentDescription = if (checked) "Selected" else "Not selected",
        tint = if (checked) Acab.accent else Acab.faint,
        modifier = Modifier.size(22.dp),
    )
}

/** The NODE handle, then the provenance chips. The compact row lays them in the name's line; the
 *  stacked row gives each its own line. One list, so neither layout can drop a chip. */
@Composable
private fun DetectionRowBadges(d: Detection, timeBasis: TimeBasis?, muted: Boolean) {
    // NODE handle, matching iOS DetectionRow. Android rendered NOTHING here, which is
    // why three cameras in a row were LITERALLY identical on this platform and merely
    // near-identical on iPhone: the last-4 of the MAC is the only per-device text on a
    // row whose title falls back to a shared label.
    Text("NODE ${d.mac.replace(":", "").takeLast(4).uppercase()}",
        color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    if (muted) MutedTag()
    if (d.type.isExperimental) ExpTag()
    if (d.offline) OfflineTag()
    // A log row has no space to explain itself, so it flags that this record's
    // time is derived (or absent) and leaves the explanation to the dossier.
    // Exact rows get nothing.
    when (timeBasis) {
        is TimeBasis.Reconstructed -> ReconTag()
        is TimeBasis.Bracketed -> RangeTag()
        is TimeBasis.Unknown -> NoTimeTag()
        else -> Unit
    }
}

/** How it was seen, like the iOS row: "BLE · OUI match". When the title leads with
 *  something OTHER than the category (an advertised name, or now the broadcast
 *  maker), the category moves here so it is never absent from the row entirely.
 *  This branch is why the iOS row can afford a maker-led title; Android printed
 *  source·method unconditionally and would have lost the category outright. */
private fun detectionRowSubtitle(d: Detection): String =
    if (d.hasName) "${d.type.label} · ${d.methodLabel}" else "${d.sourceLabel} · ${d.methodLabel}"

/** Confidence and the GPS-age pill, after the subtitle in both layouts. */
@Composable
private fun DetectionRowEvidenceChips(d: Detection) {
    // Confidence, so the list answers "definitely something, or just suspected?"
    // without opening the dossier. Bands match the dossier's verdict copy exactly
    // (<50 weak / <80 partial / >=80 strong) and iOS DetectionRow.confidenceTint.
    // HIDDEN at 0: Desert nearby-devices are confidence 0 by construction (nothing
    // matched), and a wall of "0%" chips would be noise.
    if (d.confidence > 0) ConfidenceBadge(d.confidence)
    // offline / Desert mode: the coordinate came from a stale phone fix
    d.locationAgeText?.let { GpsAgeBadge(it) }
}

/** RSSI over signal bars, trailing-aligned. */
@Composable
private fun DetectionRowSignal(d: Detection, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text("${d.rssi}", color = d.type.textTone(), fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono, maxLines = 1)
        SignalBars(rssiBars(d.rssi), tint = d.type.tone())
    }
}

/** Decorative: no description, so TalkBack never reads it, not even above the name. */
@Composable
private fun DetectionRowChevron() {
    Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
        modifier = Modifier.size(16.dp))
}


/** Sibling of [ReconTag]/[RangeTag] for a record nothing bounds at all: the board logged
 *  only the order of the sighting. Same neutral provenance anatomy; the dossier explains. */
@Composable
private fun NoTimeTag() {
    Text(
        "NO TIME",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** Muted "OFFLINE" chip: a record replayed from the board's offline buffer (the black box it
 *  kept while the phone was away), not a live sighting. Neutral tone so it reads as provenance,
 *  not an alert; same small-badge anatomy as ExpTag but on the neutral bg3/line palette. */
@Composable
private fun OfflineTag() {
    Text(
        "OFFLINE",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** A current mute suppresses active alerts/surfaces, but this retained evidence row remains
 * inspectable. The badge and row state make that distinction visible and spoken. */
@Composable
private fun MutedTag() {
    Text(
        "MUTED",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .semantics { contentDescription = "Muted device" }
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
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

/** Confidence chip on a log row. Colour bands are shared with the dossier and with iOS:
 *  under 50 = weak match (warn), under 80 = partial (dim), 80+ = strong (text). */
@Composable
private fun ConfidenceBadge(pct: Int) {
    val tint = when {
        pct < 50 -> Acab.warn
        pct < 80 -> Acab.dim
        else     -> Acab.text
    }
    Box(
        Modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    ) {
        Text("$pct%", color = tint, fontSize = 9.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Floating action bar shown in select mode: cancel, count, select-all, and mute-selected. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun SelectBar(count: Int, onCancel: () -> Unit, onSelectAll: () -> Unit, onIgnore: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier
                .padding(Acab.pad)
                .fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radius))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.minimumInteractiveComponentSize().size(32.dp)
                    .clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, contentDescription = "Cancel selection",
                        tint = Acab.dim, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.size(10.dp))
                Text("$count selected", color = Acab.text, fontSize = 13.sp,
                    fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
            }
            FlowRow(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Bulk-select every shown row (iOS parity): the whole point of select mode is
                // batch-ignoring a filtered pile, not tapping hundreds of rows one by one.
                Row(
                    Modifier.minimumInteractiveComponentSize()
                        .clip(RoundedCornerShape(50))
                        .border(1.dp, Acab.line, RoundedCornerShape(50))
                        .clickable(onClick = onSelectAll)
                        .padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("SELECT ALL", color = Acab.dim, fontSize = 11.sp,
                        letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
                val enabled = count > 0
                Row(
                    Modifier.minimumInteractiveComponentSize()
                        .background(if (enabled) Acab.accent else Acab.bg3, RoundedCornerShape(50))
                        .clickable(enabled = enabled, onClick = onIgnore)
                        .padding(horizontal = 14.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                        tint = if (enabled) Acab.onAccent else Acab.faint, modifier = Modifier.size(14.dp))
                    Text("MUTE", color = if (enabled) Acab.onAccent else Acab.faint,
                        fontSize = 11.sp, letterSpacing = 0.5.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
            }
        }
    }
}

// (The EXP tag now lives in Components.kt as the one shared ExpTag composable.)

/** Shown when the log has rows but the active lens hides every one (NEW with everything
 *  seen, OFFLINE with nothing buffered, a pinned category tile at count 0, a query no row
 *  matches). The title and body are byte-identical to iOS `noMatchTitle` / `noMatchBody` in
 *  DetectionsView.swift, branch for branch, and [onClearFilters] is the same "Clear filters"
 *  reset iOS `noMatchState` renders in every branch: search, category and scope back to their
 *  defaults in one tap. The icons are this platform's own. */
@Composable
private fun NoMatchState(
    scope: LogScope,
    catFilter: String?,
    query: String,
    onClearFilters: () -> Unit,
) {
    val shape = RoundedCornerShape(Acab.radius)
    val (icon, title, body) = if (query.isNotBlank()) Triple(
        Icons.Filled.Search, "No matching detections",
        "Try a shorter name, vendor or MAC address, or clear the current filters.",
    ) else when (scope) {
        LogScope.New -> Triple(
            Icons.Filled.DoneAll, "Nothing new",
            "Everything here is marked seen. New hits show up as they arrive.",
        )
        LogScope.Offline -> Triple(
            Icons.Outlined.Inbox, "Nothing offline",
            "No offline-recorded detections yet. The board buffers these while your phone is away.",
        )
        // ALPR gets a specific line: a quiet result there means something different, most current
        // installs are RF-silent (see the site + faq), so absence is expected and the map is the
        // primary ALPR surface.
        LogScope.All -> if (catFilter == "ALPR") Triple(
            Icons.Outlined.FilterAlt, "No ALPR radio signal",
            "No compatible ALPR radio signal was observed. Some cameras do not broadcast a detectable " +
                "signal, many backhaul over cellular and stay silent. Check the map for known " +
                "installations, or export a diagnostic capture to contribute if you can visually confirm one nearby.",
        ) else Triple(
            Icons.Outlined.FilterAlt, "No matches",
            "No detections in this category yet.",
        )
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Acab.bg2)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = Acab.padCard, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Acab.line, modifier = Modifier.size(32.dp))
        Text(title, color = Acab.dim, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(body, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
            textAlign = TextAlign.Center)
        TextButton(onClick = onClearFilters, modifier = Modifier.minimumInteractiveComponentSize()) {
            Text("Clear filters", color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** Placeholder shown while nothing's been spotted yet. The [title] names the actual
 *  state (scanning, radios off, sample data) so an empty log never reads as a mystery. */
@Composable
private fun EmptyState(title: String, hint: String?) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.RadioButtonChecked, contentDescription = null,
            tint = Acab.line, modifier = Modifier.size(38.dp))
        Text(title, color = Acab.dim, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center)
        if (hint != null) {
            Text(hint, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center)
        }
    }
}
