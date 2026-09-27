package tech.acab.app.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.PlaylistAddCheck
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.RadioButtonChecked
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.SearchBar
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.LOG_ACTIVE_SECTION_HEADER
import tech.acab.app.ble.activeBoundary
import tech.acab.app.ble.newestFirstEnvelope
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceNames
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.bufferHealthNotices
import tech.acab.app.model.customName
import tech.acab.app.model.titleName
import tech.acab.app.model.hasName
import tech.acab.app.model.maker
import tech.acab.app.model.methodLabel
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.sourceLabel
import tech.acab.app.model.vendor
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.telemetry
import java.io.File
import java.text.Normalizer
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

/** Seed for the Log's lens: everything, only-new-since-the-watermark, offline-only, or one
 *  category. Public so callers (MainScreen deep links) can seed LogScreen with an initial filter.
 *  Internally the screen splits this into independent axes (category, offline filter and the
 *  active / new / all scope, like iOS), so a seed only picks the starting position of one axis.
 *  [OfflineOnly] seeds the offline filter with the scope on All; no producer sends it today, and
 *  MainScreen's saver keeps its arm so a restored seed still round-trips. */
sealed interface LogFilter {
    data object All : LogFilter
    data object NewOnly : LogFilter
    data object OfflineOnly : LogFilter
    data class Category(val key: String) : LogFilter
}

/** The scope axis of the log lens, in segment order: Active (heard within the 45 s window and
 *  not a replay), New (after the seen watermark), All. Offline is not a scope: it is the
 *  `offlineOnly` filter in the Log tools menu, so it composes with any segment. Composes with the
 *  nullable category filter too. TWIN: iOS `StatusScope` in DetectionsView.swift. */
internal enum class LogScope { Active, New, All }
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
 *  the screen); a one-shot caller may let the default build a throwaway. [offlineOnly] is the Log
 *  tools menu's "Offline only" filter. [activeIds] is read only by [LogScope.Active] (see
 *  [logScopeKeeps]). LogScreen calls this with [LogScope.All] once per lens-key change and cuts
 *  the segment afterwards with [logScopeCut], so a segment switch never re-runs the search. */
internal fun filterLogRows(
    feed: List<Detection>,
    category: String?,
    scope: LogScope,
    newIds: Set<String>,
    watchedMacs: Set<String> = emptySet(),
    query: String = "",
    sort: LogSort = LogSort.Newest,
    index: LogSearchIndex = LogSearchIndex(),
    offlineOnly: Boolean = false,
    activeIds: Set<String> = emptySet(),
): List<Detection> {
    val preparedQuery = PreparedLogQuery(query)
    index.beginPass()
    // The cheap set and flag tests run before the query, which is the only per-row fold.
    val filtered = feed.filter { d ->
        d.matchesCategoryFilter(category, watchedMacs) && (!offlineOnly || d.offline) &&
            logScopeKeeps(d, scope, newIds, activeIds) && preparedQuery.matches(d, index)
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

/** Whether [d] belongs to [scope]. Active = heard within the 45 s window ([activeIds], which the
 *  caller cuts from the newest-first live rows with activeBoundary) AND not a replay from the
 *  board's offline buffer, even when its id is in the set; New = unseen since the watermark
 *  ([newIds]); All = every row. The one predicate [filterLogRows], [logScopeCut] and
 *  [logScopeCounts] share, so the list, the segment counts and the export cannot disagree.
 *  TWIN: iOS `logScopeKeeps(_:scope:isUnseen:activeIDs:)` in DetectionsView.swift. */
internal fun logScopeKeeps(d: Detection, scope: LogScope, newIds: Set<String>, activeIds: Set<String>): Boolean =
    when (scope) {
        LogScope.Active -> !d.offline && d.id in activeIds
        LogScope.New -> d.id in newIds
        LogScope.All -> true
    }

/** The selected segment's rows out of the scope-free lens [lensAll], in its order. All returns
 *  [lensAll] itself. This cut, never [lensAll], is what the list shows and the export freezes.
 *  TWIN: iOS `logScopeCut` in DetectionsView.swift. */
internal fun logScopeCut(
    lensAll: List<Detection>,
    scope: LogScope,
    newIds: Set<String>,
    activeIds: Set<String>,
): List<Detection> =
    if (scope == LogScope.All) lensAll else lensAll.filter { logScopeKeeps(it, scope, newIds, activeIds) }

/** The counts the Active and New segments show. All shows no count. */
internal data class LogScopeCounts(val active: Int, val new: Int)

/** Both segment counts in one pass over the lens (category, offline, search), never over the whole
 *  store, so "new · 2" counts the rows the New segment would show. TWIN: iOS `logScopeCounts`. */
internal fun logScopeCounts(lensAll: List<Detection>, newIds: Set<String>, activeIds: Set<String>): LogScopeCounts {
    var active = 0
    var unseen = 0
    for (d in lensAll) {
        if (logScopeKeeps(d, LogScope.Active, newIds, activeIds)) active++
        if (logScopeKeeps(d, LogScope.New, newIds, activeIds)) unseen++
    }
    return LogScopeCounts(active, unseen)
}

/** The segment's words: "active · N", "new · N", "all" (All has no count). Drift row "log scope
 *  segment labels" captures this whole declaration up to its column-0 brace, so keep the
 *  expression body. TWIN: iOS `logScopeSegmentLabel(_:count:)` in DetectionsView.swift. */
internal fun logScopeSegmentLabel(scope: LogScope, count: Int): String = when (scope) {
    LogScope.Active -> "active · $count"
    LogScope.New -> "new · $count"
    LogScope.All -> "all"
}

/** Header of the second time section: rows heard earlier on the local calendar day. */
internal const val LOG_EARLIER_TODAY_HEADER = "earlier today"

/** Header of the third time section: older days, and every row whose stamp cannot be trusted. */
internal const val LOG_OLDER_HEADER = "older"

/** One time section of the Log under the Newest sort: its header and its rows in feed order. A
 *  null title is the untitled section of the Active segment (decision L6): the list draws no
 *  header for it. TWIN: iOS `LogSection` in DetectionsView.swift. */
internal data class LogSection(val title: String?, val rows: List<Detection>)

/** Splits [shown] (newest first) into up to three sections, empty ones left out:
 *  1. [LOG_ACTIVE_SECTION_HEADER]: live rows in [activeIds];
 *  2. [LOG_EARLIER_TODAY_HEADER]: the rest whose last-seen stamp ([stampMs]) falls on the local
 *     calendar day of [nowMs] in [zone] AND can be trusted;
 *  3. [LOG_OLDER_HEADER]: everything else (older days, no stamp, an untrusted stamp).
 *  A live row's stamp is this phone's clock, so it is always trusted. An offline replay is trusted
 *  only when [basis] is Exact or Reconstructed, the basis rule trustworthyMapLastSeen applies for
 *  the Map. [basis] is the FIRST-seen basis (timeBasisMap), so the live arm is what files a row first
 *  replayed as a bracket and then heard live today under "earlier today", as iOS does. The day
 *  bounds are computed once per call, so no per-row date is built. [nowMs] only fixes the day.
 *  Under [LogScope.Active] (decision L6) every shown row was heard in the last 45 s, so the header
 *  would only repeat the segment: the rows come back as ONE untitled section, with no per-row work
 *  at all. All and New keep the three sections.
 *  TWIN: iOS `logSections(_:scope:activeIDs:stamp:basis:now:calendar:)` in DetectionsView.swift. */
internal fun logSections(
    shown: List<Detection>,
    scope: LogScope,
    activeIds: Set<String>,
    stampMs: (String) -> Long?,
    basis: (String) -> TimeBasis,
    nowMs: Long,
    zone: ZoneId,
): List<LogSection> {
    if (scope == LogScope.Active) return if (shown.isEmpty()) emptyList() else listOf(LogSection(null, shown))
    val day = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    val dayStart = day.atStartOfDay(zone).toInstant().toEpochMilli()
    val dayEnd = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
    val active = ArrayList<Detection>()
    val earlier = ArrayList<Detection>()
    val older = ArrayList<Detection>()
    for (d in shown) {
        if (!d.offline && d.id in activeIds) {
            active.add(d)
            continue
        }
        val stamp = stampMs(d.id)
        val trustworthy = !d.offline || basis(d.id).let { it is TimeBasis.Exact || it is TimeBasis.Reconstructed }
        if (trustworthy && stamp != null && stamp >= dayStart && stamp < dayEnd) earlier.add(d) else older.add(d)
    }
    return buildList {
        if (active.isNotEmpty()) add(LogSection(LOG_ACTIVE_SECTION_HEADER, active))
        if (earlier.isNotEmpty()) add(LogSection(LOG_EARLIER_TODAY_HEADER, earlier))
        if (older.isNotEmpty()) add(LogSection(LOG_OLDER_HEADER, older))
    }
}

/** The spoken verdict for a row's confidence percent; never drawn (the row shows the bare number).
 *  Same bands and words as iOS `DetectionRow.confidenceWord`. Drift row "confidence verdict
 *  words" captures this declaration up to its column-0 brace, so keep the multi-line form. */
internal fun confidenceWord(pct: Int): String = when {
    pct < 50 -> "weak match, verify"
    pct < 80 -> "partial match"
    else -> "strong match"
}

/** The provenance overline above a row's title: "OFFLINE", "MUTED", then the time-basis word
 *  (Reconstructed RECON, Bracketed RANGE, Unknown NO TIME; Exact and null add nothing), joined by
 *  " · ". null when no word applies. TWIN: iOS `logRowOverline(offline:muted:basis:)` in
 *  DetectionRow.swift, same words in the same order. */
internal fun logRowOverline(offline: Boolean, muted: Boolean, basis: TimeBasis?): String? {
    val words = buildList {
        if (offline) add("OFFLINE")
        if (muted) add("MUTED")
        when (basis) {
            is TimeBasis.Reconstructed -> add("RECON")
            is TimeBasis.Bracketed -> add("RANGE")
            is TimeBasis.Unknown -> add("NO TIME")
            else -> Unit
        }
    }
    return words.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** Which Log tools menu items show, written once. [menu] also enables the tools button. */
internal data class LogToolGates(
    val menu: Boolean,
    val pause: Boolean,
    val select: Boolean,
    val markSeen: Boolean,
    val export: Boolean,
    val clear: Boolean,
)

/** The Log tools menu's gates: the menu needs rows (it stays usable while paused so Resume is
 *  reachable); pause needs something to freeze; Mark Seen needs rows and is offered in sample
 *  data too, where AcabBleManager.markAllSeen moves the watermark in memory only (exitDemo
 *  restores the real one), exactly as iOS does. Clear Log is never offered in sample mode, because
 *  it would imply the retained log is erased. PLATFORM DIFFERENCE, sample data only: iOS offers
 *  "Clear Sample" there and Android offers no clear; with a real board both menus list the same
 *  items (TWIN: iOS DetectionsView.logToolsMenu). An empty real log disables the whole menu (TWIN:
 *  iOS disables the button on an empty log), so Clear Log is not reachable there; the old
 *  icon-only clear pill was, and that change is deliberate. [clear] only gates the item inside an
 *  enabled menu. [hasRows] is the live store, [feedHasRows] the shown feed. */
internal fun logToolGates(hasRows: Boolean, feedHasRows: Boolean, paused: Boolean, demo: Boolean) =
    LogToolGates(menu = hasRows || paused, pause = feedHasRows || paused, select = hasRows,
        markSeen = hasRows, export = hasRows, clear = !demo)

/** One Log tools menu action. Every member names `: LogTool`, or it is not a subtype. */
private sealed interface LogTool {
    data class Sort(val sort: LogSort) : LogTool
    data class Category(val key: String?) : LogTool
    data object ToggleOffline : LogTool
    data object TogglePause : LogTool
    data object Select : LogTool
    data object MarkSeen : LogTool
    data class Export(val gpx: Boolean) : LogTool
    data object Clear : LogTool
}

/** Where the Log's own column sits in the window, in px, so the hosted search bar can lie over it.
 *  MainScreen's bar host spans the whole window in the compact branch (the Scaffold topBar, while
 *  the column is `tabBody(..., Modifier.fillMaxSize().padding(inner))`, inset by Scaffold's
 *  default contentWindowInsets, the system bars in material3 1.3.1) and the whole area beside the
 *  rail in the wide branch (while the column is TabBody's 380dp listWidth at the host's left
 *  edge). The measured span is the one rule that holds in both. Written from layout; the int
 *  states skip equal writes. Read only in the bar's layout phase, so a change re-measures the bar
 *  and recomposes nothing. */
@Stable
private class LogColumnSpan {
    var left by mutableIntStateOf(0)
    var width by mutableIntStateOf(0)        // 0 = not laid out yet: the bar spans its host
    fun update(c: LayoutCoordinates) {
        left = c.positionInWindow().x.roundToInt()
        width = c.size.width
    }
}

/** The lens-summary line, the list's footer: how many rows the list shows out of the feed it is
 *  reading. The line counts the lens the list shows, which is the FROZEN feed while paused, and
 *  names that feed; the paused chip "PAUSED · N NEW" words what piled up behind the freeze.
 *  [category] is the category filter's LABEL ([logCategoryLabel]: the words its chip shows, so
 *  the CAMERA key reads NETWORK CAM), appended as " · ALPR".
 *  TWIN: iOS `logLensSummary` in DetectionsView.swift, byte-identical text; pinned by
 *  LogExportLensTest. */
internal fun logLensSummaryText(shown: Int, total: Int, paused: Boolean, category: String?): String =
    "$shown of $total" + (if (paused) " paused" else " retained") + (category?.let { " · $it" } ?: "")

/** The spoken form of [logLensSummaryText]. TWIN: iOS `logLensSummaryDescription` in
 *  DetectionsView.swift, byte-identical. */
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

/** One category the Log tools menu offers as a filter. [key] is the DeviceType.category the filter
 *  matches on ([WATCHED_FILTER_KEY] for the watchlist overlay), [label] the filter chip's words
 *  (the Map's MAP_CATEGORIES labels, and iOS detectionCategories.chipLabel), [spoken] the filter
 *  chip's TalkBack name, [menuLabel] the Log tools menu item's words in Title Case (menu items
 *  are title-cased, chips stay caps; the Export header reads it too). TWIN: iOS
 *  DetectionCategory.menuLabel, byte-identical. Defined once so a new category is added in one
 *  place. "Nearby Device" is deliberately absent: it is ambient noise, not a filter category. */
private data class LogCategory(val key: String, val label: String, val spoken: String, val menuLabel: String)

/** The words a category filter shows for [key]: its [LogCategory.label] (the chip's, so the CAMERA
 *  key reads NETWORK CAM), or the key itself for a key the menu does not list (a deep link can seed
 *  one; the chip shows the key then too). The lens footer reads this, never the raw key; the export
 *  menu header reads [LogCategory.menuLabel] instead ([logExportMenuHeader]). The key stays only
 *  where it is an identifier (the filter itself, the export filename slug). TWIN: iOS
 *  DetectionsView, which maps the key through detectionCategories chipLabel for logLensSummary
 *  (review finding LOG-4). */
internal fun logCategoryLabel(key: String?): String? =
    key?.let { k -> LOG_CATEGORIES.firstOrNull { it.key == k }?.label ?: k }

private val LOG_CATEGORIES = listOf(
    LogCategory("ALPR", "ALPR", "ALPR", "ALPR"),
    LogCategory("DRONE", "DRONE", "DRONE", "Drone"),
    LogCategory("BODY CAM", "BODY CAM", "Body camera", "Body Cam"),
    LogCategory("TRACKER", "TRACKER", "Tracker", "Tracker"),
    LogCategory("GLASSES", "GLASSES", "Glasses", "Glasses"),
    LogCategory("CAMERA", "NETWORK CAM", "Network camera", "Network Cam"),
    // Overlay lens: current stars keep their underlying type; historical firmware t=8 rows also
    // belong. Membership is resolved by isWatchedFilterMember, not DeviceType.category alone.
    LogCategory(WATCHED_FILTER_KEY, "WATCHED", "Watched or starred", "Watched"),
)

/** Per-emission tallies off the LIVE store, computed once per (detections, watermark,
 *  watchedMacs). [newIds] is the batch newIdSet result (ONE storeLock take per publish); live it
 *  IS the screen's rowNewIds, which the New cut and the New segment count read, so neither takes
 *  the lock per row. [watchedCount] feeds the WATCHED auto-reset and whether the Log tools menu
 *  offers WATCHED at all. */
private class LogTallies(
    val newIds: Set<String>,
    val watchedCount: Int,
)

/** The Log: detection history. Search sits in the tab's top bar (MainScreen's slot), or inline at
 *  the top of the column when no slot is provided (the connect screen's saved log). Under it: the
 *  active / new / all segments, a chip row for each filter that is on (paused, category,
 *  offline), then the rows, in time sections under the Newest sort. The Log tools menu in the bar
 *  holds sort, category, offline only, pause / resume, select, mark seen, CSV / GPX export and
 *  clear; select mode batch-mutes rows.
 *  [initialFilter] seeds the lens on first composition (drive-mode notifications deep-link here
 *  with NewOnly); null keeps the default ALL lens.
 *  [selectedId] is the currently open dossier in the tablet two-pane layout; the matching
 *  row gets a subtle highlight. null (the phone default) means no row is highlighted.
 *  [wide] is that two-pane layout itself (MainScreen's `wide`, 840dp and up): a tap there only
 *  fills the pane beside the list, so the rows draw no disclosure chevron ([logRowShowsChevron],
 *  2026-09-26 review P3-6; iPad draws none either). */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class, ExperimentalFoundationApi::class)
@Composable
fun LogScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit,
    initialFilter: LogFilter? = null,
    selectedId: String? = null,
    wide: Boolean = false,
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
    // Independent lens axes, ANDed together like iOS: a nullable category filter, the offline
    // filter and the active / new / all scope. A seed only positions the axis it names; the others
    // stay at their defaults. rememberSaveable (under MainScreen's per-tab SaveableStateProvider):
    // a tab switch or a rotation must not reset a lens the user set. Deep-link re-seeding still
    // works because the key(logScreenKey) wrapper discards this state when a fresh seed arrives.
    var catFilter by rememberSaveable { mutableStateOf((initialFilter as? LogFilter.Category)?.key) }
    var scope by rememberSaveable {
        mutableStateOf(
            when (initialFilter) {
                LogFilter.NewOnly -> LogScope.New
                else -> LogScope.All            // All, Category and OfflineOnly all start on All
            }
        )
    }
    var offlineOnly by rememberSaveable { mutableStateOf(initialFilter is LogFilter.OfflineOnly) }
    var searchQuery by rememberSaveable { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(LogSort.Newest) }

    // The 1 s tick behind the Active cut and the local day. Read ONLY inside the two
    // derivedStateOf lambdas below, never in this body, so a second that moves neither the
    // boundary nor the day recomposes nothing.
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1_000); nowMs = System.currentTimeMillis() } }

    // First ordinary open of the log baselines the New marks to what is already here, so a fresh
    // install / first offline backlog is not a wall of new rows. Once-only (persisted flag inside).
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
    // ViewModel owns the rows, their metadata and the pause instant. Separate keys keep the
    // connected and saved-log surfaces apart.
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

    // Built off the LIVE store (iOS parity): while paused only the ROWS freeze. newIdSet reads the
    // watermark, so it keys here; the per-row isNewSinceWatermark would take storeLock once per
    // row, newIdSet is ONE take.
    val tallies = remember(detections, watermark, watchedMacs) {
        LogTallies(newIds = ble.newIdSet(detections), watchedCount = watchedDetectionCount(detections, watchedMacs))
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
    // Last-seen stamps for every row, live and replayed: ONE lock take per feed emission live,
    // the frozen stamps while paused. Never per tick and never per row.
    val frozenLastSeen = remember(pauseVm.frozenExport) { pauseVm.frozenExport?.lastSeenMsById() ?: emptyMap() }
    val stamps = remember(feed, paused, frozenLastSeen) { if (paused) frozenLastSeen else ble.logLastSeenSnapshot(feed) }
    // The Active boundary: a binary search over the newest-first live stamps, re-run by the tick
    // inside derivedStateOf, so this body recomposes only when the boundary moves. Replays are
    // never Active; in sample mode every live row is (Status's demo bypass). While paused both
    // values below read the pause instant, so the Active cut and the day stay frozen.
    val feedLive = remember(feed) { feed.filter { !it.offline } }
    val liveEnvelope = remember(feedLive, stamps) { newestFirstEnvelope(feedLive.map { stamps[it.id] }) }
    val k by remember(feedLive, liveEnvelope, demo) {
        derivedStateOf { if (demo) feedLive.size else activeBoundary(liveEnvelope, pauseVm.pausedAtMs ?: nowMs) }
    }
    val zone = remember { ZoneId.systemDefault() }   // a mid-session time-zone change applies on the next Log entry
    val today by remember(zone) { derivedStateOf { Instant.ofEpochMilli(pauseVm.pausedAtMs ?: nowMs).atZone(zone).toLocalDate() } }
    val activeIds = remember(feedLive, k) {
        val n = k.coerceAtMost(feedLive.size)
        feedLive.subList(0, n).mapTo(HashSet(n)) { it.id }
    }

    // WATCHED is the sole category that can disappear because the user unstarred its last current
    // member. Historical t=8 rows keep the count nonzero. Reset instead of leaving a lens on that
    // matches nothing any more.
    LaunchedEffect(catFilter, tallies.watchedCount) {
        if (catFilter == WATCHED_FILTER_KEY && tallies.watchedCount == 0) catFilter = null
    }

    // The lens runs ONCE per lens-key change and WITHOUT the scope axis: a segment switch, a tick
    // or a boundary move only re-cuts it (O(n)), never re-runs the search. A publish that DID
    // change the feed (a re-sighted row's RSSI) still re-lenses, but through `searchIndex`, which
    // keeps every row's folded haystack across publishes and refolds only a row whose identity
    // text moved (LogSearchIndex says which fields), so the rebuild is a substring test per row,
    // not a nine-field derivation plus a fold. `DeviceNames.revision` is a key because the search
    // reads custom names and `watchedMacs` cannot see a relabel; iOS keys its LogLensMemo on the
    // watched and ignored lists for the same reason.
    val searchIndex = remember { LogSearchIndex() }
    val namesRevision = DeviceNames.revision
    val lensAll = remember(feed, catFilter, rowNewIds, watchedMacs, searchQuery, sort, namesRevision, offlineOnly) {
        filterLogRows(feed, catFilter, LogScope.All, rowNewIds, watchedMacs, searchQuery, sort, searchIndex, offlineOnly = offlineOnly)
    }
    val shown = remember(lensAll, scope, rowNewIds, activeIds) { logScopeCut(lensAll, scope, rowNewIds, activeIds) }
    val counts = remember(lensAll, rowNewIds, activeIds) { logScopeCounts(lensAll, rowNewIds, activeIds) }
    val todayStartMs = remember(today, zone) { today.atStartOfDay(zone).toInstant().toEpochMilli() }
    // `scope` is a key of its own: two segments can cut EQUAL lists (sample data, where every row is
    // Active), and only the scope then says whether the Active segment's untitled section applies.
    val sections = remember(shown, scope, activeIds, timeBases, today, sort, stamps, zone, todayStartMs) {
        // logSections reads its day argument only to fix the local day. Passing the tick here
        // would subscribe this body to the 1 s tick (contracts 3.3); todayStartMs already carries
        // the evaluation day: the pause instant's day while paused, the tick's day otherwise.
        if (sort != LogSort.Newest) null
        else logSections(shown, scope, activeIds, { stamps[it] }, { timeBases[it] ?: TimeBasis.Exact }, todayStartMs, zone)
    }
    val columnSpan = remember { LogColumnSpan() }
    // O(1) invalidation token; only visible lazy rows evaluate isIgnored. Building a 5,000-row
    // muted set at the ~3 Hz feed cadence would turn a row mark into an avoidable hot-path scan.
    val muteRevision = 31 * System.identityHashCode(ignoredRules) +
        System.identityHashCode(activeProjection)

    fun exitSelect() { selectMode = false; selected = emptySet() }
    // System Back ends select mode the way the X on the select bar does, instead of falling
    // through to the activity and dropping the selection with the app. In MainScreen's compact
    // shell the Scaffold subcomposes this body after MainScreen's own Back handlers, so this one
    // wins; in the expanded shell it composes before them, so an open inline dossier closes on
    // the first Back and select mode ends on the next.
    BackHandler(enabled = selectMode) { exitSelect() }
    fun togglePause() {
        if (pauseVm.paused) pauseVm.resume()
        else pauseVm.pause(ble.freezeFeedExport())
    }

    /** [gpx] false = the CSV evidence file, true = GPX for a mapping app.
     *
     *  Exports whatever the log is CURRENTLY SHOWING, not the whole history. That is what the Log
     *  tools menu's "CSV, shown rows" and "GPX, for maps" items promise, and the alternative
     *  (silently handing over everything) is the worse surprise for this product in particular.
     *  The lens also lands in the FILENAME, so a partial export cannot be mistaken for a complete
     *  one once it has left the app. */
    fun exportLog(gpx: Boolean = false, wholeLog: Boolean = false) {
        // The file write goes to IO (a Desert-mode log can be thousands of rows, which
        // would jank the main thread); the share sheet fires back on Main once it's done.
        // Freeze before launching IO. For a routine export this is EXACTLY the shown cut: live or
        // paused, category, offline, search, sort and the active / new / all segment. The Clear
        // sheet's escape hatch is the sole whole-store path because it is about to delete the
        // whole store.
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
        // category key, active or new, offline, search, strongest, paused, joined by "-". TWIN:
        // iOS `exportQualifier` in DetectionsView.swift, same words, same order; writeDetections
        // lowercases the whole slug there the way the category is lowercased here.
        val slugParts = if (wholeLog) emptyList() else buildList {
            catFilter?.let { add(it.lowercase().replace(' ', '-')) }
            when (scope) {
                LogScope.Active -> add("active")
                LogScope.New -> add("new")
                LogScope.All -> Unit
            }
            if (offlineOnly) add("offline")
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
                // the next export and at app start) and to the real Clear Log; never delete this
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

    val gates = logToolGates(hasRows = detections.isNotEmpty(), feedHasRows = feed.isNotEmpty(), paused = paused, demo = demo)
    // WATCHED is offered only while it has a member, as on iOS (tuneCategories); the auto-reset
    // above clears it when the last member goes.
    val showWatched = tallies.watchedCount > 0
    // Read only inside click handlers (LogToolsMenu), so the bar never captures this body's
    // state; an exhaustive `when` with no else, so a new LogTool fails the build until handled.
    val toolHandler = rememberUpdatedState<(LogTool) -> Unit> { tool ->
        when (tool) {
            is LogTool.Sort -> sort = tool.sort
            is LogTool.Category -> catFilter = tool.key
            LogTool.ToggleOffline -> offlineOnly = !offlineOnly
            LogTool.TogglePause -> togglePause()
            // resume first: bulk mute acts on live rows (iOS parity)
            LogTool.Select -> { pauseVm.resume(); selectMode = true; selected = emptySet() }
            // Works in sample data too: markAllSeen keeps a sample watermark in memory and never
            // writes prefs there (persistedLogMutationAllowed), and exitDemo restores the real
            // one. scope resets to all so the user is never stranded on an empty New segment.
            LogTool.MarkSeen -> { ble.markAllSeen(); scope = LogScope.All }
            is LogTool.Export -> exportLog(gpx = tool.gpx)
            LogTool.Clear -> if (!demo) confirmClear = true
        }
    }
    // The bar composes in MainScreen's host (C7). It captures only what it draws plus the
    // handler State and the span holder, never the feed or the tick. The menu hides in select
    // mode: a stray Select would wipe the checks and Mark Seen would clear the new marks
    // mid-triage.
    TabTopBar {
        LogSearchBar(
            query = searchQuery, onQueryChange = { searchQuery = it }, showTools = !selectMode,
            gates = gates, sort = sort, catFilter = catFilter, offlineOnly = offlineOnly, paused = paused,
            showWatched = showWatched, onTool = toolHandler, hosted = true, columnSpan = columnSpan,
        )
    }
    val onRowClick: (Detection) -> Unit = { d ->
        if (selectMode) {
            selected = if (d.id in selected) selected - d.id else selected + d.id
        } else {
            onSelect(d)
        }
    }

    // ONE root: the list column and, in select mode, the select bar overlaid on it. The saved log
    // hosts this screen in a Column, where two sibling roots gave the select bar zero height.
    Box(Modifier.fillMaxSize().onGloballyPositioned(columnSpan::update)) {
        Column(Modifier.fillMaxSize()) {
            if (LocalTabTopBarSlot.current == null) {
                LogSearchBar(
                    query = searchQuery, onQueryChange = { searchQuery = it }, showTools = !selectMode,
                    gates = gates, sort = sort, catFilter = catFilter, offlineOnly = offlineOnly, paused = paused,
                    showWatched = showWatched, onTool = toolHandler, hosted = false, columnSpan = columnSpan,
                )
            }
            // Cap the readable list width and center it, so a tablet/landscape viewport stops
            // stretching one column across the whole screen. At phone width the 640 cap is a no-op.
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                LazyColumn(
                    Modifier.widthIn(max = 640.dp).fillMaxSize(),
                    // The select bar is an overlay; reserve its full two-row/large-text height so
                    // the final evidence rows remain scrollable above it rather than disappearing
                    // underneath.
                    contentPadding = PaddingValues(bottom = if (selectMode) 136.dp else 16.dp),
                ) {
                    // Board-side loss/censoring flags belong beside the evidence, not buried in
                    // settings. They are persistent and intentionally cannot be dismissed locally.
                    status?.bufferHealthNotices?.forEach { notice ->
                        item(key = "log-buffer-${notice.name}", contentType = "banner") {
                            Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp)) {
                                BufferHealthBanner(notice)
                            }
                        }
                    }
                    // The controls draw only while the feed has rows: an empty log shows its empty
                    // state alone, and these two items are gated on the negation of the "log-empty"
                    // branch below. TWIN: iOS DetectionsView.masterList, which draws its controls
                    // Section only while the log has rows.
                    if (feed.isNotEmpty()) {
                        item(key = "log-scope", contentType = "scope") {
                            LogScopeControl(scope, counts) { scope = it }
                        }
                    }
                    if (feed.isNotEmpty() && (paused || catFilter != null || offlineOnly)) {
                        item(key = "log-filters", contentType = "filters") {
                            LogFilterChips(
                                paused = paused,
                                pausedNew = pausedNew,
                                catFilter = catFilter,
                                offlineOnly = offlineOnly,
                                onResume = { pauseVm.resume() },
                                onClearCategory = { catFilter = null },
                                onClearOffline = { offlineOnly = false },
                            )
                        }
                    }
                    if (feed.isEmpty()) {
                        item(key = "log-empty", contentType = "empty") {
                            val radiosOff = status?.let { !it.ble && !it.wifi } == true
                            when {
                                demo -> EmptyState("Sample data mode.", null)
                                // no status frame at all = no board linked; "Scanning…" would be a lie
                                status == null -> EmptyState(
                                    "No board linked.",
                                    "connect your beacon, it does the listening",
                                )
                                radiosOff -> EmptyState("Radios are off. Turn them on in Beacon.", null)
                                else -> EmptyState(
                                    "Scanning…",
                                    "Detections log here as beacons spots surveillance gear nearby.",
                                )
                            }
                        }
                    } else if (shown.isEmpty()) {
                        // Rows exist but the lens hides them all (Active with nothing heard in the
                        // window, New with everything seen, offline only with nothing buffered, a
                        // category with no rows, a query no row matches): explain instead of a
                        // blank void, and offer the same one-tap reset iOS does.
                        item(key = "log-nomatch", contentType = "empty") {
                            NoMatchState(
                                scope, catFilter, searchQuery, offlineOnly,
                                onClearFilters = {
                                    searchQuery = ""; catFilter = null; scope = LogScope.All; offlineOnly = false
                                },
                                onShowAll = { scope = LogScope.All },
                            )
                        }
                    } else {
                        // Each row is its own lazy item (keyed), so a Desert-mode log of thousands
                        // only composes the rows on screen instead of building every row at once.
                        // Under Strongest the list is flat; under Newest it splits into time
                        // sections, and first / last are per section.
                        val secs = sections
                        if (secs == null) {
                            itemsIndexed(shown, key = { _, d -> d.id }, contentType = { _, _ -> "row" }) { index, d ->
                                LogListRow(
                                    d = d,
                                    isFirst = index == 0,
                                    isLast = index == shown.lastIndex,
                                    highlighted = selectedId != null && d.id == selectedId,
                                    timeBasis = timeBases[d.id],
                                    muteRevision = muteRevision,
                                    ble = ble,
                                    selectMode = selectMode,
                                    wide = wide,
                                    checked = d.id in selected,
                                    onRowClick = onRowClick,
                                )
                            }
                        } else {
                            secs.forEachIndexed { si, section ->
                                if (si > 0) {
                                    item(key = "log-divider-${section.title}", contentType = "divider") {
                                        GroupedDivider()
                                    }
                                }
                                // An untitled section (the Active segment, decision L6) draws no header.
                                val title = section.title
                                if (title != null) {
                                    stickyHeader(key = "log-section-$title", contentType = "header") {
                                        SectionLabel(
                                            title,
                                            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface),
                                        )
                                    }
                                }
                                val rows = section.rows
                                itemsIndexed(rows, key = { _, d -> d.id }, contentType = { _, _ -> "row" }) { index, d ->
                                    LogListRow(
                                        d = d,
                                        isFirst = index == 0,
                                        isLast = index == rows.lastIndex,
                                        highlighted = selectedId != null && d.id == selectedId,
                                        timeBasis = timeBases[d.id],
                                        muteRevision = muteRevision,
                                        ble = ble,
                                        selectMode = selectMode,
                                        wide = wide,
                                        checked = d.id in selected,
                                        onRowClick = onRowClick,
                                    )
                                }
                            }
                        }
                    }
                    // The shown / feed ratio, as the list's footer whenever the feed has rows:
                    // under the rows AND under the no-match panel, never under the empty state.
                    // It counts the feed the lens is reading, the FROZEN one while paused, and
                    // names it. TWIN: iOS logLensSummary, the footer of the last rows section and
                    // of the no-match Section alike.
                    if (feed.isNotEmpty()) {
                        item(key = "log-footer", contentType = "footer") {
                            val catLabel = logCategoryLabel(catFilter)
                            SectionFooter(
                                logLensSummaryText(shown.size, feed.size, paused, catLabel),
                                Modifier.semantics {
                                    contentDescription =
                                        logLensSummaryDescription(shown.size, feed.size, paused, catLabel)
                                },
                            )
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
    }

    // Destructive log wipe needs a confirmation, with an export-first escape hatch: a bottom
    // sheet with FULL-WIDTH STACKED buttons, so the three labels never crowd one row.
    if (confirmClear && !demo) {
        ModalBottomSheet(onDismissRequest = { confirmClear = false }, modifier = Modifier.statusBarsPadding()) {
            LightSheetSystemBarIcons()
            Column(
                Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Clear ${detections.size} detection${if (detections.size == 1) "" else "s"}?",
                    style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
                Text(
                    "This deletes the log on this phone, including the app's copies of earlier exports, " +
                        "and can't be undone. If this is evidence, export it first and save or send it " +
                        "somewhere else. Only a copy outside the app survives.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.size(4.dp))
                OutlinedButton(
                    // ALWAYS the whole log, never the current lens. The button below deletes
                    // EVERYTHING, so a filtered export here would hand back a subset and then
                    // destroy the rest - the one place a partial export is silent data loss.
                    onClick = { exportLog(gpx = false, wholeLog = true); confirmClear = false },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Export CSV First")
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
                ) {
                    Text("Clear Log")
                }
                TextButton(onClick = { confirmClear = false }, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel")
                }
            }
        }
    }
}

/** The Log's M3 SearchBar, inline form only (it never expands over the banner stack). [hosted] is
 *  true when MainScreen's top-bar host draws it; the frame then lays the bar over the Log's own
 *  column ([columnSpan]) rather than over the host, which is wider in both MainScreen branches.
 *  Inline (the saved log) the bar already sits in the column. The query style is bodyLarge
 *  because the text input reads LocalTextStyle (AcabTheme's guard). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LogSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    showTools: Boolean,
    gates: LogToolGates,
    sort: LogSort,
    catFilter: String?,
    offlineOnly: Boolean,
    paused: Boolean,
    showWatched: Boolean,
    onTool: State<(LogTool) -> Unit>,
    hosted: Boolean,
    columnSpan: LogColumnSpan,
) {
    val keyboard = LocalSoftwareKeyboardController.current
    var hostLeft by remember { mutableIntStateOf(0) }
    val frame = if (!hosted) Modifier.fillMaxWidth() else Modifier.fillMaxWidth()
        .onGloballyPositioned { hostLeft = it.positionInWindow().x.roundToInt() }
        .layout { measurable, c ->
            val w = if (columnSpan.width > 0) columnSpan.width.coerceAtMost(c.maxWidth) else c.maxWidth
            val x = (columnSpan.left - hostLeft).coerceIn(0, c.maxWidth - w)
            val p = measurable.measure(c.copy(minWidth = w, maxWidth = w))
            layout(c.maxWidth, p.height) { p.place(x, 0) }
        }
    Box(frame, contentAlignment = Alignment.TopCenter) {
        ProvideTextStyle(MaterialTheme.typography.bodyLarge) {
            SearchBar(
                inputField = {
                    SearchBarDefaults.InputField(
                        query = query,
                        onQueryChange = onQueryChange,
                        onSearch = { keyboard?.hide() },
                        expanded = false,
                        onExpandedChange = {},
                        placeholder = { Text(LOG_SEARCH_PLACEHOLDER) },
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                        trailingIcon = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (query.isNotEmpty()) {
                                    IconButton(onClick = { onQueryChange("") }) {
                                        Icon(Icons.Filled.Close, contentDescription = "Clear search")
                                    }
                                }
                                if (showTools) LogToolsMenu(gates, sort, catFilter, offlineOnly, paused, showWatched, onTool)
                            }
                        },
                    )
                },
                expanded = false,
                onExpandedChange = {},
                // The 640 cap is the list's own, so the bar is centred over the list the way the
                // list is centred in its column.
                modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(horizontal = 16.dp),
            ) {}
        }
    }
}

/** The header over the Log tools menu's two export items: "Export", or "Export <menu label>"
 *  while a category filter is on ([LogCategory.menuLabel], so the CAMERA key reads Export Network
 *  Cam; a key the menu does not list reads as the key itself, as [logCategoryLabel] does).
 *  TWIN: the iOS Export submenu label in DetectionsView.logToolsMenu, byte-identical. */
internal fun logExportMenuHeader(catFilter: String?): String =
    catFilter?.let { k -> "Export ${LOG_CATEGORIES.firstOrNull { it.key == k }?.menuLabel ?: k}" } ?: "Export"

/** The "Log tools" button and its one flat menu: sort, category (WATCHED only while
 *  [showWatched]), offline only, then the actions [gates] allows (the two export items under a
 *  non-clickable [logExportMenuHeader] line). Default M3 colours. Every item
 *  closes the menu, then hands its [LogTool] to [onTool], which is read only here in the click
 *  handlers. TWIN: the iOS "Log tools" Menu (DetectionsView.logToolsMenu), same items in the same
 *  order with a real board (iOS nests category and export in submenus). In sample data both keep
 *  Mark Seen (in memory only) and they differ on Clear alone: this menu hides Clear Log, iOS
 *  offers "Clear Sample" (see [logToolGates]). */
@Composable
private fun LogToolsMenu(
    gates: LogToolGates,
    sort: LogSort,
    catFilter: String?,
    offlineOnly: Boolean,
    paused: Boolean,
    showWatched: Boolean,
    onTool: State<(LogTool) -> Unit>,
) {
    var open by remember { mutableStateOf(false) }
    fun pick(tool: LogTool) {
        open = false
        onTool.value(tool)
    }
    val checkMark: @Composable (Boolean) -> Unit = { on ->
        if (on) Icon(Icons.Filled.Check, contentDescription = null) else Spacer(Modifier.size(24.dp))
    }
    Box {
        IconButton(onClick = { open = true }, enabled = gates.menu) {
            Icon(Icons.Filled.Tune, contentDescription = "Log tools")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf(LogSort.Newest to "Newest", LogSort.Strongest to "Strongest Signal").forEach { (choice, label) ->
                DropdownMenuItem(
                    text = { Text(label) },
                    leadingIcon = { checkMark(sort == choice) },
                    onClick = { pick(LogTool.Sort(choice)) },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("All Categories") },
                leadingIcon = { checkMark(catFilter == null) },
                onClick = { pick(LogTool.Category(null)) },
            )
            LOG_CATEGORIES.forEach { c ->
                if (c.key == WATCHED_FILTER_KEY && !showWatched) return@forEach
                DropdownMenuItem(
                    text = { Text(c.menuLabel) },
                    leadingIcon = { checkMark(catFilter == c.key) },
                    onClick = { pick(LogTool.Category(c.key)) },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Offline Only") },
                leadingIcon = { Spacer(Modifier.size(24.dp)) },
                trailingIcon = { Checkbox(checked = offlineOnly, onCheckedChange = null) },
                onClick = { pick(LogTool.ToggleOffline) },
                modifier = Modifier.semantics { toggleableState = ToggleableState(offlineOnly) },
            )
            HorizontalDivider()
            if (gates.pause) {
                DropdownMenuItem(
                    text = { Text(if (paused) "Resume Live Feed" else "Pause Live Feed") },
                    leadingIcon = {
                        Icon(if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, contentDescription = null)
                    },
                    onClick = { pick(LogTool.TogglePause) },
                )
            }
            if (gates.select) {
                DropdownMenuItem(
                    text = { Text("Select") },
                    leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAddCheck, contentDescription = null) },
                    onClick = { pick(LogTool.Select) },
                )
            }
            if (gates.markSeen) {
                DropdownMenuItem(
                    text = { Text("Mark Seen") },
                    leadingIcon = { Icon(Icons.Filled.DoneAll, contentDescription = null) },
                    onClick = { pick(LogTool.MarkSeen) },
                )
            }
            if (gates.export) {
                // A header, not an item: it names the action and, with a category filter on, the
                // category, so a partial export cannot be taken for the whole log. Same words as
                // the iOS Export submenu label (logExportMenuHeader).
                Text(
                    logExportMenuHeader(catFilter),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp).semantics { heading() },
                )
                DropdownMenuItem(
                    text = { Text("CSV, Shown Rows") },
                    leadingIcon = { Icon(Icons.Filled.IosShare, contentDescription = null) },
                    onClick = { pick(LogTool.Export(gpx = false)) },
                )
                DropdownMenuItem(
                    text = { Text("GPX, for Maps") },
                    leadingIcon = { Icon(Icons.Filled.Place, contentDescription = null) },
                    onClick = { pick(LogTool.Export(gpx = true)) },
                )
            }
            if (gates.clear) {
                HorizontalDivider()
                // No destructive colour: the confirmation sheet carries the weight.
                DropdownMenuItem(
                    text = { Text("Clear Log") },
                    leadingIcon = { Icon(Icons.Filled.DeleteOutline, contentDescription = null) },
                    onClick = { pick(LogTool.Clear) },
                )
            }
        }
    }
}

/** The active / new / all segments (M3 single-choice segmented buttons, default colours and
 *  check). Labels are never clamped: at large font scales "active · 12" wraps inside its
 *  segment rather than being cut, centred, and breaks before the dot, never between the dot and
 *  the count ([segmentLabelForDisplay], shared with Map's MapScopeSegments). The row takes its tallest segment's height and every segment
 *  fills it, so a wrapped label does not leave the outline jagged. TWIN: the iOS segmented
 *  Picker over StatusScope. */
@Composable
private fun LogScopeControl(scope: LogScope, counts: LogScopeCounts, onScope: (LogScope) -> Unit) {
    SingleChoiceSegmentedButtonRow(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp)
            .height(IntrinsicSize.Min),
    ) {
        LogScope.entries.forEachIndexed { index, s ->
            SegmentedButton(
                selected = scope == s,
                onClick = { onScope(s) },
                modifier = Modifier.fillMaxHeight(),
                shape = SegmentedButtonDefaults.itemShape(index = index, count = LogScope.entries.size),
                label = {
                    Text(
                        segmentLabelForDisplay(logScopeSegmentLabel(s, when (s) {
                            LogScope.Active -> counts.active
                            LogScope.New -> counts.new
                            LogScope.All -> 0
                        })),
                        textAlign = TextAlign.Center,
                    )
                },
            )
        }
    }
}

/** The spoken name of a removable Log filter chip ([LogFilterChips]): its tap, since the close
 *  mark is decorative and the chip is gone once tapped. [filter] is the filter's spoken name. */
internal fun logFilterChipRemoveDescription(filter: String): String = "Remove the $filter filter"

/** One chip per filter that is on, in the fixed order paused, category, offline; each tap clears
 *  its own filter. Selected M3 InputChips with a decorative trailing close mark. Each chip speaks
 *  its tap as its name and the filter as its state: the paused chip "Resume live feed" with its
 *  drawn label, the category and offline chips [logFilterChipRemoveDescription] with the
 *  filter's spoken name, so TalkBack says what the tap does rather than a generic "double tap to
 *  activate". TWIN: iOS DetectionsView's paused filterChip, spoken "Resume live feed" with the
 *  label as its accessibilityValue. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LogFilterChips(
    paused: Boolean,
    pausedNew: Int,
    catFilter: String?,
    offlineOnly: Boolean,
    onResume: () -> Unit,
    onClearCategory: () -> Unit,
    onClearOffline: () -> Unit,
) {
    FlowRow(
        Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (paused) {
            val pausedLabel = if (pausedNew > 0) "PAUSED · $pausedNew NEW" else "PAUSED"
            InputChip(
                selected = true, onClick = onResume,
                label = { Text(pausedLabel) },
                trailingIcon = { Icon(Icons.Filled.Close, contentDescription = null, Modifier.size(InputChipDefaults.IconSize)) },
                // contentDescription replaces the drawn label, so the label rides as the state.
                modifier = Modifier.semantics { contentDescription = "Resume live feed"; stateDescription = pausedLabel },
            )
        }
        if (catFilter != null) {
            // A deep link can seed a key the menu does not list; the chip then shows the key.
            val category = LOG_CATEGORIES.firstOrNull { it.key == catFilter }
            val spoken = category?.spoken ?: catFilter
            InputChip(
                selected = true, onClick = onClearCategory,
                label = { Text(category?.label ?: catFilter) },
                trailingIcon = { Icon(Icons.Filled.Close, contentDescription = null, Modifier.size(InputChipDefaults.IconSize)) },
                modifier = Modifier.semantics {
                    contentDescription = logFilterChipRemoveDescription(spoken); stateDescription = spoken
                },
            )
        }
        if (offlineOnly) {
            InputChip(
                selected = true, onClick = onClearOffline,
                label = { Text("OFFLINE") },
                trailingIcon = { Icon(Icons.Filled.Close, contentDescription = null, Modifier.size(InputChipDefaults.IconSize)) },
                modifier = Modifier.semantics {
                    contentDescription = logFilterChipRemoveDescription("offline only"); stateDescription = "Offline only"
                },
            )
        }
    }
}

/** One list row in its section's slice. The muted state and the overline are remembered per row,
 *  so only visible rows evaluate them, and only when their inputs move. */
@Composable
private fun LogListRow(
    d: Detection,
    isFirst: Boolean,
    isLast: Boolean,
    highlighted: Boolean,
    timeBasis: TimeBasis?,
    muteRevision: Int,
    ble: AcabBleManager,
    selectMode: Boolean,
    wide: Boolean,
    checked: Boolean,
    onRowClick: (Detection) -> Unit,
) {
    val muted = remember(d.mac, muteRevision) { ble.isMutedForProjection(d.mac) }
    val overline = remember(d.offline, muted, timeBasis) { logRowOverline(d.offline, muted, timeBasis) }
    PanelSegment(isFirst, isLast, highlighted) {
        DetectionRow(d, overline, selectMode, wide, checked, muted, isLast, onClick = { onRowClick(d) })
    }
}

/** One lazy item's slice of a section. Rows stay individually lazy (a Desert-mode log can hold
 *  thousands) and the slice is transparent, so the list reads as rows directly on the surface;
 *  the first slice of a section rounds its top corners and the last its bottom ones, which only
 *  shows when [highlighted] (the two-pane selection) fills the slice, and bounds the ripple. The
 *  8dp inset plus the row's own 8dp puts content at 16dp, level with the section headers. */
@Composable
private fun PanelSegment(isFirst: Boolean, isLast: Boolean, highlighted: Boolean = false, content: @Composable () -> Unit) {
    val m = MaterialTheme.shapes.medium
    val none = CornerSize(0.dp)
    val shape = when {
        isFirst && isLast -> m
        isFirst -> m.copy(bottomStart = none, bottomEnd = none)
        isLast -> m.copy(topStart = none, topEnd = none)
        else -> RectangleShape
    }
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp).clip(shape)
            .then(if (highlighted) Modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh) else Modifier),
    ) { content() }
}

internal const val LOG_SEARCH_PLACEHOLDER = "Search name, MAC or vendor"

/** Built once from AcabTypography, never per row. The row's instrument text is JetBrains Mono (R16,
 *  Theme.kt telemetry): the provenance overline (uppercase words, tracked), the signal number and
 *  the stacked row's confidence. The name and the compact row's supporting line stay Roboto: the
 *  supporting line is descriptive copy that already wraps, and mono would wrap it sooner.
 *  TWIN: iOS DetectionRow overlineText / signalText / confidenceText. */
private val LogRowOverlineStyle = AcabTypography.labelSmall.telemetry(tracked = true)
private val LogRowSignalStyle = AcabTypography.labelMedium.telemetry()
private val LogRowConfidenceStyle = AcabTypography.bodyMedium.telemetry()

/** Font scale from which [DetectionRow] stacks instead of sharing one line between the name and
 *  the signal column. Measured 2026-09-20 on the beacon_play_36 AVD (411dp wide) with the sample
 *  data, on the earlier row, where the NODE handle and the provenance chips shared the name's
 *  line and the name was capped at one line: 1.3 kept every sample name but the 14-character
 *  drone serial whole, and 1.35 cut the first maker name. The compact row no longer caps the name
 *  or the supporting line (they wrap, as on iOS), so below this scale nothing is cut; the
 *  threshold now only decides when the glyph and the signal column give their width back.
 *  The stock font-size slider on that AVD steps from 1.3 straight to 1.5. */
private const val DETECTION_ROW_STACK_FONT_SCALE = 1.35f

/** The spoken state of a log row ([DetectionRow]'s outer node). Outside select mode only a muted
 *  row has one. In select mode the row is a checkbox (Role.Checkbox), whose checked state
 *  TalkBack speaks on its own, so an unmuted row sets none; a muted row names its check in the
 *  same words, so the check is spoken even where a stateDescription stands in for the checked
 *  state. */
internal fun logRowStateDescription(selectMode: Boolean, checked: Boolean, muted: Boolean): String? = when {
    !muted -> null
    !selectMode -> "Muted, history retained"
    else -> (if (checked) "Selected" else "Not selected") + ", muted, history retained"
}

/** One log row: glyph, the provenance overline, name, subtitle and confidence, the bare signal
 *  number, chevron. Tap opens the dossier, or toggles the check in select mode. The outer node is
 *  clickable, or toggleable as a checkbox in select mode ([logRowStateDescription]), so TalkBack
 *  reads the parts as one, in drawing order. From [DETECTION_ROW_STACK_FONT_SCALE] up it draws
 *  [StackedDetectionRow] instead. */
@Composable
private fun DetectionRow(
    d: Detection,
    overline: String?,
    selectMode: Boolean,
    wide: Boolean,
    checked: Boolean,
    muted: Boolean,
    isLast: Boolean,
    onClick: () -> Unit,
) {
    // One outer node for both layouts, so the tap target and the spoken muted state cannot differ
    // between them.
    val stateText = logRowStateDescription(selectMode, checked, muted)
    val rowModifier = Modifier.fillMaxWidth().heightIn(min = 72.dp)
        .then(
            if (selectMode) {
                Modifier.toggleable(value = checked, role = Role.Checkbox, onValueChange = { onClick() })
            } else Modifier.clickable(onClick = onClick),
        )
        .semantics { if (stateText != null) stateDescription = stateText }
        .padding(horizontal = 8.dp, vertical = 8.dp)
    if (LocalDensity.current.fontScale >= DETECTION_ROW_STACK_FONT_SCALE) {
        StackedDetectionRow(d, overline, selectMode, wide, checked, rowModifier)
        // A stacked row is several lines tall with no card around it, so a rule between rows
        // says where one device ends and the next begins (the compact rows need none: each is
        // one line band). Outside the clickable node, so it is neither tapped nor spoken.
        if (!isLast) {
            HorizontalDivider(Modifier.padding(horizontal = 8.dp), color = MaterialTheme.colorScheme.outlineVariant)
        }
        return
    }
    Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
        if (selectMode) {
            SelectMark(checked)
            Spacer(Modifier.size(12.dp))
        }
        CatGlyph(d.type, 40)
        Spacer(Modifier.size(16.dp))
        Column(Modifier.weight(1f)) {
            // No line cap on the overline: the provenance words are what stop a reader trusting
            // a reconstructed timestamp or mistaking a buffer replay for a live sighting.
            overline?.let { Text(it, style = LogRowOverlineStyle, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            // the advertised name when present, else the broadcast maker, else the category's
            // display name (titleName: "body cam", "network camera").
            // No maxLines: a cap would cut a long name short and hide the device's identity in an
            // evidence list (TWIN: iOS DetectionRow.titleText, no lineLimit either).
            Text(d.titleName, style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface)
            DetectionRowSupporting(d)
        }
        Spacer(Modifier.size(16.dp))
        DetectionRowSignal(d)
        DetectionRowChevron(selectMode, wide)
    }
}

/** [DetectionRow] at large font scales. The name leaves the glyph row and takes the full row
 *  width with no line cap; the overline, the subtitle and the confidence get a line each. The
 *  signal number sits on the FIRST line, between the glyph and the chevron, so every line of the
 *  row hangs below its own top line and a lone number at the bottom can never be read as the
 *  next row's. So TalkBack reads the signal right after the row's start, before the overline and
 *  the name (the compact row reads it after them). Rows are separated by a rule ([DetectionRow]).
 *  TWIN: iOS DetectionRow.accessibilityLayout (review finding LOG-2 moves its signal the same
 *  way); the provenance overline order OFFLINE · MUTED · <basis> is shared (logRowOverline). */
@Composable
private fun StackedDetectionRow(
    d: Detection,
    overline: String?,
    selectMode: Boolean,
    wide: Boolean,
    checked: Boolean,
    modifier: Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (selectMode) {
                SelectMark(checked)
                Spacer(Modifier.size(12.dp))
            }
            CatGlyph(d.type, 40)
            Spacer(Modifier.weight(1f))
            DetectionRowSignal(d)
            DetectionRowChevron(selectMode, wide)
        }
        overline?.let { Text(it, style = LogRowOverlineStyle, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        // No maxLines: a cap would cut a long name short. A name of several words wraps between
        // them; a single token wider than the row (a drone serial, a rename) wraps inside itself.
        Text(d.titleName, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
        Text(detectionRowSubtitle(d), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (d.confidence > 0) ConfidenceText(d.confidence)
    }
}

/** Select-mode check. Decorative: the row itself is the checkbox and carries the checked state
 *  ([DetectionRow]'s toggleable node). */
@Composable
private fun SelectMark(checked: Boolean) {
    Icon(
        if (checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
        contentDescription = null,
        tint = if (checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.size(24.dp),
    )
}

/** The compact row's supporting line: the subtitle, then the confidence after a middle dot, so
 *  it draws "BLE · OUI match · 65%" (TWIN: iOS DetectionRow supportingText). ONE text with no
 *  line cap, so a long subtitle wraps as a whole and the match method is never cut short; each
 *  middle dot is held to the word before it ([keepingMiddleDotsAttached], the iOS helper of the
 *  same name), so no line starts with a dot. The verdict word is spoken, never drawn. */
@Composable
private fun DetectionRowSupporting(d: Detection) {
    val sub = detectionRowSubtitle(d)
    val pct = d.confidence
    Text(
        keepingMiddleDotsAttached(if (pct > 0) "$sub · $pct%" else sub),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = if (pct > 0) {
            Modifier.semantics { contentDescription = "$sub, confidence $pct percent, ${confidenceWord(pct)}" }
        } else Modifier,
    )
}

/** Holds each " · " separator to the word before it with a no-break space, so a wrapped line
 *  never starts with the dot. TWIN: iOS keepingMiddleDotsAttached (SettingsView.swift), same
 *  substitution. */
internal fun keepingMiddleDotsAttached(text: String): String = text.replace(" · ", "\u00A0· ")

/** A scope segment label as drawn (Log's LogScopeControl and Map's MapScopeSegments): a no-break
 *  space after each middle dot, so a label that wraps inside its segment breaks BEFORE the dot
 *  ("active" over "· 5") and the count never sits alone on a line. Display only: the pure labels
 *  (logScopeSegmentLabel, mapScopeSegmentLabel) stay byte-identical to their iOS twins, whose
 *  segmented control never wraps a label. */
internal fun segmentLabelForDisplay(label: String): String = label.replace(" · ", " ·\u00A0")

/** A scope segment label drawn as its word over its count with no dot ("recent" over "5"), for a
 *  segment known to be too narrow for the one-line label (Map's MapScopeSegments under its type
 *  cap, mapScopeLabelsStack; P3-4). The dot is dropped, not broken around: a middle dot leading
 *  the second line is what [segmentLabelForDisplay] alone left. Display only, like it; the Log's
 *  LogScopeControl has no width model yet and keeps the one-line form. Pinned in
 *  MapChromeCapTest. */
internal fun segmentLabelStacked(label: String): String = label.replace(" · ", "\n")

/** Confidence as plain secondary text on the stacked row's own line, so the list answers
 *  "definitely something, or just suspected?" without opening the dossier. The verdict word is
 *  spoken, never drawn ([confidenceWord], the iOS bands). HIDDEN at 0 by its callers: Desert
 *  nearby-devices are confidence 0 by construction (nothing matched), and a wall of "0%" would be
 *  noise. The compact row folds the percent into [DetectionRowSupporting] instead. */
@Composable
private fun ConfidenceText(pct: Int) {
    Text("$pct%", style = LogRowConfidenceStyle,
        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
        modifier = Modifier.semantics { contentDescription = "confidence $pct percent, ${confidenceWord(pct)}" })
}

/** How it was seen, like the iOS row: "BLE · OUI match". When the title leads with
 *  something OTHER than the category (an advertised name, or now the broadcast
 *  maker), the category moves here so it is never absent from the row entirely.
 *  This branch is why the iOS row can afford a maker-led title; Android printed
 *  source·method unconditionally and would have lost the category outright.
 *  The category is DeviceType.inlineLabel ("ALPR camera", "body cam"), never `label`, whose
 *  Title Case ("ALPR Camera", "Body Camera") sat beside "Network camera" in one list; rows are
 *  lowercase-first by rule. `label` stays for CSV / GPX, search and the managed list. TWIN: iOS
 *  DetectionRow.subtitle(for:)'s hasName branch, the same inlineLabel (drift row "Log row
 *  subtitle leads with inlineLabel"). Pinned in LogRowSubtitleTest. */
internal fun detectionRowSubtitle(d: Detection): String =
    if (d.hasName) "${d.type.inlineLabel} · ${d.methodLabel}" else "${d.sourceLabel} · ${d.methodLabel}"

/** The bare RSSI number, trailing: ASCII hyphen, no unit drawn, mono digits (all one width); the
 *  unit is spoken. TWIN: the iOS DetectionRow signal text, same spoken label. */
@Composable
private fun DetectionRowSignal(d: Detection, modifier: Modifier = Modifier) {
    Text("${d.rssi}", style = LogRowSignalStyle, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
        modifier = modifier.semantics {
            contentDescription = "Signal strength ${d.rssi} decibels relative to one milliwatt"
        })
}

/** Pure: whether a Log row draws its disclosure chevron. Only outside select mode: there the
 *  row's tap toggles its check and opens nothing, so a chevron would promise a drill-in that does
 *  not happen (HIG Lists and tables; iOS drops its indicator the same way). And never in the
 *  [wide] two-pane layout, where a tap only updates the detail pane beside the list (Canonical
 *  layouts: "Selection of a list item updates the detail pane"; 2026-09-26 review P3-6, the
 *  same gate the selected-row highlight rides on). Pinned in LogSelectRowSemanticsTest and
 *  LogWideRowChevronTest. */
internal fun logRowShowsChevron(selectMode: Boolean, wide: Boolean = false): Boolean = !selectMode && !wide

/** Whether the chevron's 24dp slot is held open while the chevron is not drawn: in select mode
 *  on a compact layout, so the signal column does not jump when the mode flips. In the wide
 *  layout the chevron never draws, so there is no flip to hold a slot for and the signal number
 *  ends the row. Pure, pinned in LogWideRowChevronTest. */
internal fun logRowKeepsChevronSlot(selectMode: Boolean, wide: Boolean): Boolean = selectMode && !wide

/** Decorative: no description, so TalkBack never reads it, not even above the name. Drawn only
 *  when [logRowShowsChevron] says so, after its 8dp gap; in select mode on a compact layout its
 *  24dp slot stays empty ([logRowKeepsChevronSlot]), so the signal column does not jump when the
 *  mode flips; in the wide two-pane layout neither the gap nor the slot is drawn. TWIN: iOS
 *  DetectionRow, no disclosure indicator in select mode nor in the iPad split view. */
@Composable
private fun DetectionRowChevron(selectMode: Boolean, wide: Boolean) {
    if (logRowShowsChevron(selectMode, wide)) {
        Spacer(Modifier.size(8.dp))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
    } else if (logRowKeepsChevronSlot(selectMode, wide)) {
        Spacer(Modifier.size(8.dp + 24.dp))
    }
}

/** Floating action bar shown in select mode: cancel, count, select-all, and mute-selected. */
@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun SelectBar(count: Int, onCancel: () -> Unit, onSelectAll: () -> Unit, onIgnore: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Surface(
            Modifier.padding(16.dp).fillMaxWidth(),
            shape = MaterialTheme.shapes.medium,
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {
            Column(
                Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.Filled.Close, contentDescription = "Cancel selection")
                    }
                    Spacer(Modifier.size(8.dp))
                    Kicker("$count SELECTED")
                }
                FlowRow(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // Bulk-select every shown row (iOS parity): the whole point of select mode is
                    // batch-muting a filtered pile, not tapping hundreds of rows one by one.
                    TextButton(onClick = onSelectAll) {
                        Text("Select All")
                    }
                    Button(onClick = onIgnore, enabled = count > 0) {
                        Icon(Icons.Filled.NotificationsOff, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text("Mute")
                    }
                }
            }
        }
    }
}

/** Placeholder shown while nothing's been spotted yet. The [title] names the actual
 *  state (scanning, radios off, sample data) so an empty log never reads as a mystery. */
@Composable
private fun EmptyState(title: String, hint: String?) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.RadioButtonChecked, contentDescription = null,
            tint = MaterialTheme.colorScheme.outlineVariant, modifier = Modifier.size(40.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center)
        if (hint != null) {
            Text(hint, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center)
        }
    }
}

/** Which button the no-match panel offers ([logNoMatchAction]). */
internal enum class LogNoMatchAction { ClearFilters, ShowAll }

/** "Clear Filters" only while a filter is actually on (a search, a category or Offline only); a
 *  segment is not a filter (C10), so an empty Active or New segment with no filter on offers
 *  "Show All" (moves to the All segment) instead, and the All segment with no filter on (which
 *  cannot be empty while the feed has rows) offers nothing. TWIN: iOS DetectionsView's no-match
 *  state, same rule (review finding CON-13). */
internal fun logNoMatchAction(scope: LogScope, catFilter: String?, query: String, offlineOnly: Boolean): LogNoMatchAction? =
    when {
        query.isNotBlank() || catFilter != null || offlineOnly -> LogNoMatchAction.ClearFilters
        scope != LogScope.All -> LogNoMatchAction.ShowAll
        else -> null
    }

/** Shown when the log has rows but the lens hides every one (Active with nothing heard in the
 *  window, New with everything seen, offline only with nothing buffered, a category with no rows,
 *  a query no row matches). The title and body are byte-identical to iOS `noMatchTitle` /
 *  `noMatchBody` in DetectionsView.swift, branch for branch and in the same precedence. The
 *  button is [logNoMatchAction]'s: [onClearFilters] is the "Clear Filters" reset (search,
 *  category, scope and the offline filter back to their defaults in one tap), [onShowAll] the
 *  "Show All" move to the All segment. The icons are this platform's own. */
@Composable
private fun NoMatchState(
    scope: LogScope,
    catFilter: String?,
    query: String,
    offlineOnly: Boolean,
    onClearFilters: () -> Unit,
    onShowAll: () -> Unit,
) {
    val (icon, title, body) = when {
        query.isNotBlank() -> Triple(
            Icons.Filled.Search, "No matching detections",
            "Try a shorter name, vendor or MAC address, or clear the current filters.",
        )
        // Offline only is checked BEFORE the Active copy: an offline replay is never Active
        // (logScopeKeeps), so Active with Offline only is always empty, and "Nothing was heard in
        // the last 45 seconds" would blame the radio for what the filter did. Active + offline
        // falls through to the offlineOnly arm. TWIN: iOS noMatchTitle / noMatchBody, same
        // precedence and the same words.
        scope == LogScope.Active && !offlineOnly -> Triple(
            Icons.Outlined.Timer, "Nothing active",
            "Nothing was heard in the last ${ACTIVE_NEARBY_WINDOW_MS / 1_000L} seconds. Earlier detections stay under all.",
        )
        scope == LogScope.New -> Triple(
            Icons.Filled.DoneAll, "Nothing new",
            "Everything here is marked seen. New hits show up as they arrive.",
        )
        offlineOnly -> Triple(
            Icons.Outlined.Inbox, "Nothing offline",
            "No offline-recorded detections yet. The board buffers these while your phone is away.",
        )
        // ALPR gets a specific line: a quiet result there means something different, most current
        // installs are RF-silent (see the site + faq), so absence is expected and the map is the
        // primary ALPR surface.
        catFilter == "ALPR" -> Triple(
            Icons.Outlined.FilterAlt, "No ALPR radio signal",
            "No compatible ALPR radio signal was observed. Some cameras do not broadcast a detectable " +
                "signal, many backhaul over cellular and stay silent. Check the map for known " +
                "installations, or export a diagnostic capture to contribute if you can visually confirm one nearby.",
        )
        else -> Triple(
            Icons.Outlined.FilterAlt, "No matches",
            "No detections in this category yet.",
        )
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.outlineVariant,
            modifier = Modifier.size(32.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center)
        when (logNoMatchAction(scope, catFilter, query, offlineOnly)) {
            LogNoMatchAction.ClearFilters -> TextButton(onClick = onClearFilters) {
                Text("Clear Filters", style = MaterialTheme.typography.labelLarge)
            }
            LogNoMatchAction.ShowAll -> TextButton(onClick = onShowAll) {
                Text("Show All", style = MaterialTheme.typography.labelLarge)
            }
            null -> Unit
        }
    }
}
