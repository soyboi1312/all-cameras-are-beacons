package tech.acab.app.ui

import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.MAP_RECENT_WINDOW_MS
import tech.acab.app.ble.MapDetectionEvidence
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.validCoord
import kotlin.math.floor
import kotlin.math.pow
import kotlin.math.sqrt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

/** User-facing history lens for Map only. The Log always retains and displays its full evidence
 * feed unless the user applies its own filters. Declaration order is the segment order on the map
 * (active · N / recent · N / all · N), and the choice is persisted by [name] under "history_scope"
 * in the "acab.map" prefs, so a case is never renamed. TWIN: iOS `MapHistoryScope`
 * (`case active, recent, all`) in MapTabView.swift. */
internal enum class MapHistoryScope { Active, Recent, All }

/** Whether a row last heard at [lastSeenAt] belongs to [scope] at [now]. Active and Recent share
 * one shape over their own windows ([ACTIVE_NEARBY_WINDOW_MS], the 45 s Status uses, and
 * [MAP_RECENT_WINDOW_MS]): an undated row and a stamp ahead of [now] are both out.
 *
 * [demo] is the sample-data bypass on every non-All scope: in sample data every row is active,
 * dated or not, the same bypass Status (StatusScreen `nearby`) and the Log (LogScreen's Active
 * boundary, `if (demo) feedLive.size`) apply to the 45 s window. The seed stamps its rows once, so
 * without it the Map alone would fall to "active · 0" 45 s into the tour while the other two tabs
 * still show every row (C10 / C11). Recent takes the same bypass, because Active (45 s) is a subset
 * of Recent (15 min): without it the default Recent scope emptied 15 minutes into the tour and the
 * segments read "active · 5 / recent · 0", which cannot be true (review finding MAP-01). All is
 * unchanged. TWIN: iOS `mapScopeIncludes(lastSeen:basis:scope:now:isDemoMode:)` in MapTabView.swift
 * (MAP-01 asks it for the same bypass on every non-All scope). */
internal fun mapHistoryIncludes(
    lastSeenAt: Long?,
    scope: MapHistoryScope,
    now: Long,
    demo: Boolean = false,
): Boolean = when (scope) {
    MapHistoryScope.All -> true
    MapHistoryScope.Recent -> demo || (lastSeenAt != null && now - lastSeenAt in 0..MAP_RECENT_WINDOW_MS)
    MapHistoryScope.Active -> demo || (lastSeenAt != null && now - lastSeenAt in 0..ACTIVE_NEARBY_WINDOW_MS)
}

/** Stable ordered membership for the history lens. [latestLastSeen] is an authoritative slow
 * refresh, separate from the geometry snapshot, so continuously-heard stationary rows stay Recent
 * and quiet rows expire without turning packet-rate timestamp updates into projection work. */
internal fun mapHistoryIds(
    rows: List<MapDetectionEvidence>,
    scope: MapHistoryScope,
    now: Long,
    latestLastSeen: Map<String, Long>,
    demo: Boolean = false,
): List<String> = if (scope == MapHistoryScope.All) {
    rows.map { it.detection.id }
} else {
    rows.mapNotNull { row ->
        row.detection.id.takeIf {
            mapHistoryIncludes(latestLastSeen[it], scope, now, demo = demo)
        }
    }
}

/** The clock the Active and Recent lenses compare stamps against: wall-clock, read at the moment
 * of the comparison. MapScreen also keeps a tick (`historyNow`: 1 s under Active, 30 s under Recent
 * and All) that INVALIDATES membership while the radio is quiet; that tick is never the comparison
 * clock, because a row heard since the tick carries a stamp newer than it and [mapHistoryIncludes]
 * rejects a stamp ahead of `now`, which would hide exactly the freshest sightings from the lens
 * until the next tick. TWIN: iOS
 * `makeSnapshot` in MapTabView.swift reads `let now = Date()` inside the projection pass and hands
 * that to `mapHistoryScopeIncludes` for the same reason. */
internal fun recentScopeClock(): Long = System.currentTimeMillis()

/** [mapHistoryIds] against [recentScopeClock]. This is the screen's entry point on purpose: it has
 * no `now` parameter, so the invalidation tick cannot be handed in as the comparison clock. */
internal fun recentScopeIds(
    rows: List<MapDetectionEvidence>,
    scope: MapHistoryScope,
    latestLastSeen: Map<String, Long>,
    demo: Boolean = false,
): List<String> = mapHistoryIds(rows, scope, recentScopeClock(), latestLastSeen, demo)

/** One map evidence snapshot split by [hasMapRepresentation] (MapScreen.kt): `first` holds the
 * located rows, which feed the pins, the ALL chip, the category chips and the scope segments;
 * `second` holds the unlocated rows, which feed ONLY the headline's "without a location" count. */
internal fun splitMapEvidence(
    rows: List<MapDetectionEvidence>,
): Pair<List<MapDetectionEvidence>, List<MapDetectionEvidence>> = rows.partition { row ->
    val d = row.detection
    hasMapRepresentation(d.type, row.coordinate, d.pilotLat, d.pilotLon)
}

/** The located rows [scope] keeps, [scopedIds] being its membership ([recentScopeIds], unused under
 * All). Its size is the ALL chip's number: the located rows in the current scope before the
 * category chip, the rows the pins represent with no chip on and the selected scope's segment
 * count. TWIN: iOS `MapSnapshot.totalLocated` in MapTabView.swift (the `total += 1` after the
 * mapCoord and scope guards in makeSnapshot). An unlocated row never counts here. */
internal fun mapScopedLocated(
    located: List<MapDetectionEvidence>,
    scope: MapHistoryScope,
    scopedIds: List<String>,
): List<MapDetectionEvidence> = if (scope == MapHistoryScope.All) {
    located
} else {
    val allowed = scopedIds.toHashSet()
    located.filter { it.detection.id in allowed }
}

/** A stored "history_scope" value, back to its scope. An unknown or missing value (a pref written
 * by a future build, a hand-edited file) falls back to Recent, the default lens, never a crash. */
internal fun parseMapHistoryScope(stored: String?): MapHistoryScope =
    runCatching { MapHistoryScope.valueOf(stored ?: "Recent") }.getOrDefault(MapHistoryScope.Recent)

/** What the scope segments and the honesty headline print. [active], [recent] and [all] count the
 * located rows through the current category chip per scope (what each segment would show);
 * [withoutLocation] counts the unlocated rows through the same chip and the SELECTED scope. */
internal data class MapScopeCounts(val active: Int, val recent: Int, val all: Int, val withoutLocation: Int)

/** One pass over [locatedIds] tallies Active and Recent through [mapHistoryIncludes] against
 * [lastSeenMs] (the trusted stamps, `mapLastSeenSnapshot`); `all` is every located row; one pass
 * over [unlocatedIds] counts those in the selected [scope]. Allocates no intermediate collection.
 * [demo] is [mapHistoryIncludes]'s sample-data bypass, so in sample data `active` and `recent`
 * both equal `all` and each segment agrees with the pins its scope draws. TWIN: iOS `MapSnapshot` activeCount /
 * recentCount / allCount / withoutLocation (MapTabView.swift), counted through the same bypass in
 * `mapScopeIncludes(lastSeen:basis:scope:now:isDemoMode:)`. */
internal fun mapScopeCounts(
    lastSeenMs: Map<String, Long>,
    locatedIds: Collection<String>,
    unlocatedIds: Collection<String>,
    scope: MapHistoryScope,
    nowMs: Long,
    demo: Boolean = false,
): MapScopeCounts {
    var active = 0
    var recent = 0
    for (id in locatedIds) {
        val seen = lastSeenMs[id]
        if (mapHistoryIncludes(seen, MapHistoryScope.Active, nowMs, demo = demo)) active++
        if (mapHistoryIncludes(seen, MapHistoryScope.Recent, nowMs, demo = demo)) recent++
    }
    var without = 0
    for (id in unlocatedIds) {
        if (mapHistoryIncludes(lastSeenMs[id], scope, nowMs, demo = demo)) without++
    }
    return MapScopeCounts(active, recent, locatedIds.size, without)
}

/** The scope segment labels. TWIN: iOS `mapScopeSegmentLabel(_:count:)` in MapTabView.swift, and
 * the drift row "map scope segment labels" reads this exact shape (expression body, `}` at column 0). */
internal fun mapScopeSegmentLabel(scope: MapHistoryScope, count: Int): String = when (scope) {
    MapHistoryScope.Active -> "active · $count"
    MapHistoryScope.Recent -> "recent · $count"
    MapHistoryScope.All -> "all · $count"
}

/** The legend card's honesty headline, its first line: the located rows in scope and category,
 * and the rows that have no location at all. TWIN: iOS `mapHonestyHeadline(onMap:withoutLocation:)`; the drift row
 * "map honesty headline" reads this exact expression body.
 *
 * PLATFORM DIFFERENCE in the numbers passed in: a Remote ID drone with ONLY an operator coordinate
 * (no drone position and no observer fix) is located here, because mapRepresentationCoord
 * (MapScreen.kt) falls back to the operator position for a drone, so it counts in "N on the map"
 * and in the active / recent / all segments and draws its operator marker. iOS has no map
 * coordinate for that row, so there it counts as "without a location" and joins no segment count
 * (the iOS mapHonestyHeadline doc records the same difference). Every other row splits the same
 * way on both phones. */
internal fun mapHonestyHeadline(onMap: Int, withoutLocation: Int): String =
    "$onMap on the map · $withoutLocation without a location"

/** Ceiling on how often a detection-driven revision may rebuild the map, by retained row count.
 * THE SHARED LADDER: iOS `mapDetectionRefreshInterval(rowCount:)` in MapTabView.swift returns the
 * same four values in seconds, and both suites pin them (MapPinRulesTests there, MapProjectionTest
 * here). Camera, filter, scope, toggle and focus rebuilds never pass through it (see
 * [coalesceDetectionRevisions]). Policy, not a measured frame time. */
internal fun mapDetectionRefreshIntervalMs(rowCount: Int): Long = when {
    rowCount >= 4_000 -> 1_000L
    rowCount >= 2_000 -> 750L
    rowCount >= 500 -> 500L
    else -> 300L
}

/** "Never installed": far enough back that any interval has already elapsed, and far enough from
 * Long.MIN_VALUE that `now - lastInstallAt` cannot overflow. */
internal const val DETECTION_REFRESH_NEVER = Long.MIN_VALUE / 2

/** How long the next detection-driven install still has to wait. Zero before a first install and
 * once an interval has passed, so a quiet feed's next revision lands at once (the leading edge);
 * the remainder of the interval otherwise. Pure, so the arithmetic is pinned without a coroutine. */
internal fun detectionRefreshWaitMs(rowCount: Int, lastInstallAt: Long, now: Long): Long =
    (mapDetectionRefreshIntervalMs(rowCount) - (now - lastInstallAt)).coerceAtLeast(0L)

/**
 * Follow the manager's spatial revision into the map under a leading + trailing ceiling.
 *
 * The first revision after a quiet spell installs at once. A burst behind it (Desert mode, a
 * buffered-row drain, a drone path growing per packet) collapses: each newer revision cancels
 * the wait of the one before it, and whichever revision is newest when the interval since the
 * last install runs out is the one installed. So a burst costs one snapshot per interval, and its
 * LAST revision always lands. Nothing between is lost: a revision is only a key, and the snapshot
 * MapScreen takes against it reads the store as it stands then, skipped revisions included.
 *
 * Not gated here: a revision equal to [installedRevision] (nothing new), and user-driven rebuilds,
 * which never pass through this function. Runs until cancelled. MapScreen launches it for the
 * life of the screen and re-seeds from the live value on re-entry, so a wait in flight when the
 * tab left composition is owed to nobody. [clock] must be monotonic milliseconds: a wall-clock
 * step must neither stretch nor skip a wait. TWIN: iOS `scheduleDetectionSnapshotRefresh` in
 * MapTabView.swift, the same leading + trailing shape over the same ladder.
 */
internal suspend fun coalesceDetectionRevisions(
    revisions: Flow<Long>,
    installedRevision: Long,
    rowCount: () -> Int,
    clock: () -> Long = { System.nanoTime() / 1_000_000L },
    install: (Long) -> Unit,
) {
    var installed = installedRevision
    var lastInstallAt = DETECTION_REFRESH_NEVER
    revisions.collectLatest { revision ->
        if (revision == installed) return@collectLatest
        val wait = detectionRefreshWaitMs(rowCount(), lastInstallAt, clock())
        if (wait > 0L) delay(wait)
        lastInstallAt = clock()
        installed = revision
        install(revision)
    }
}

/** Plain viewport value so projection work can be cached independently from osmdroid objects. */
internal data class MapViewport(
    val north: Double,
    val east: Double,
    val south: Double,
    val west: Double,
) {
    fun contains(lat: Double, lon: Double): Boolean {
        if (lat !in south..north) return false
        return if (west <= east) lon in west..east else lon >= west || lon <= east
    }

    companion object {
        val WORLD = MapViewport(90.0, 180.0, -90.0, -180.0)
    }
}

/** One marker or bubble produced by the projection. [cluster] distinguishes adaptive grid bubbles
 * from exact same-position pin groups, whose first member supplies the category pin artwork. */
internal data class MapSymbolGroup(
    val lat: Double,
    val lon: Double,
    val members: List<Detection>,
    val dominantCategory: String,
    val homogeneousCategory: Boolean,
    val cluster: Boolean,
)

/** Projection result plus audit-friendly work/count metrics. `visited` is deliberately exposed to
 * deterministic size tests: a dense pass must visit each retained candidate once, never once per
 * category or once per cluster mode. */
internal data class MapRenderPlan(
    val overlayRows: List<Detection>,
    val symbols: List<MapSymbolGroup>,
    val inViewportIds: List<String>,
    val visited: Int,
    val displayedRows: Int,
    val representedRows: Int,
    val simplifiedRows: Int,
    val omittedRows: Int,
)

internal const val MAP_FAR_ZOOM = 13.0

/** THE same-spot order, one copy for both places it is applied: which member of an exact-pin
 * group draws the pin and leads its member sheet. Priority first ([infraPinPriority], lowest
 * number wins), then most recently seen, with an undated member last inside its band: an undated
 * row never outranks one that can be dated. Ties all the way down keep the input order, which is
 * the feed's newest-first, because sortedWith is stable. Shared with iOS: `MapPinRules.ordered` in
 * MapTabView.swift, priority first, then most recent with an undated member last, then arrival
 * order, which InfraPin.orderedMemberIDs(lastSeen:) applies at the tap on the stamps read then.
 *
 * SymbolBucket.finish applies it on the evidence snapshot's stamps when the projection runs; the
 * draw loop in MapScreen applies it again through [orderSameSpotMembers] on the live last-seen
 * read it takes per rebuild, because the snapshot is installed on a ceiling (see
 * [coalesceDetectionRevisions]) and an older member may have been heard since. */
internal fun <T> sameSpotOrder(typeOf: (T) -> DeviceType, lastSeenOf: (T) -> Long?): Comparator<T> =
    compareBy<T> { infraPinPriority(typeOf(it)) }.thenByDescending { lastSeenOf(it) ?: Long.MIN_VALUE }

/** The draw loop's application of [sameSpotOrder] to the live rows behind one exact-pin group.
 * A group of one is handed back as is, no sort, so a lone pin renders exactly as it always has. */
internal fun orderSameSpotMembers(
    members: List<Detection>,
    lastSeenOf: (String) -> Long?,
): List<Detection> =
    if (members.size <= 1) members
    else members.sortedWith(sameSpotOrder({ it.type }, { lastSeenOf(it.id) }))

private class SymbolBucket(
    val cluster: Boolean,
    first: MapDetectionEvidence,
) {
    val entries = ArrayList<MapDetectionEvidence>(2).apply { add(first) }
    var latSum = first.coordinate!!.first
    var lonSum = first.coordinate!!.second
    private var firstCategory = first.detection.type.category
    private var sameCategory = true
    private var categoryCounts: MutableMap<String, Int>? = null

    fun add(row: MapDetectionEvidence) {
        val category = row.detection.type.category
        if (category != firstCategory) {
            if (sameCategory) {
                sameCategory = false
                categoryCounts = hashMapOf(firstCategory to entries.size)
            }
            val counts = categoryCounts!!
            counts[category] = (counts[category] ?: 0) + 1
        } else if (!sameCategory) {
            val counts = categoryCounts!!
            counts[category] = (counts[category] ?: 0) + 1
        }
        entries.add(row)
        latSum += row.coordinate!!.first
        lonSum += row.coordinate.second
    }

    fun finish(): MapSymbolGroup {
        if (cluster) {
            val dominant = categoryCounts?.maxByOrNull { it.value }?.key ?: firstCategory
            return MapSymbolGroup(
                lat = latSum / entries.size,
                lon = lonSum / entries.size,
                members = entries.map { it.detection },
                dominantCategory = dominant,
                homogeneousCategory = sameCategory,
                cluster = true,
            )
        }
        // The snapshot's stamps order the bucket here; the draw loop re-applies the same order on
        // its live read (orderSameSpotMembers), so this is the projection's half of one rule.
        val ordered = if (entries.size == 1) entries else entries.sortedWith(
            sameSpotOrder({ it.detection.type }, { it.lastSeenAt }),
        )
        val lead = ordered.first()
        return MapSymbolGroup(
            lat = lead.coordinate!!.first,
            lon = lead.coordinate.second,
            members = ordered.map { it.detection },
            dominantCategory = lead.detection.type.category,
            homogeneousCategory = sameCategory,
            cluster = false,
        )
    }
}

/**
 * Cull and bucket a map feed in one input pass.
 *
 * At street zoom, high-volume ambient types use screen-sized cells while infrastructure and RID
 * aircraft retain exact pins (same-fix stacks still collapse). Below [MAP_FAR_ZOOM], every
 * non-RID row joins the adaptive grid: that is the far-zoom simplification which makes All history
 * usable after a long drive. Cell size grows with retained density before the pass begins, keeping
 * symbol allocation bounded without throwing away the members inside a bubble.
 */
internal fun buildMapRenderPlan(
    rows: List<MapDetectionEvidence>,
    viewport: MapViewport,
    zoom: Double,
    markerCap: Int,
    showBreadcrumbs: Boolean,
    hasTrackerTrail: (String) -> Boolean = { false },
): MapRenderPlan {
    require(markerCap > 0)
    if (rows.isEmpty()) {
        return MapRenderPlan(emptyList(), emptyList(), emptyList(), 0, 0, 0, 0, 0)
    }

    val densityScale = sqrt((rows.size.toDouble() / markerCap).coerceAtLeast(1.0))
        .coerceAtMost(8.0)
    val clusterCell = (360.0 / 2.0.pow(zoom + 2.0) * densityScale).coerceIn(1e-6, 12.0)
    val buckets = LinkedHashMap<Long, SymbolBucket>(minOf(rows.size, markerCap * 2))
    val overlayRows = ArrayList<Detection>()
    val inViewport = ArrayList<String>()
    var visited = 0

    for (row in rows) {
        visited++
        val d = row.detection
        val c = row.coordinate?.takeIf { validCoord(it.first, it.second) }
        val operatorOnScreen = d.type == DeviceType.DRONE &&
            validCoord(d.pilotLat, d.pilotLon) && viewport.contains(d.pilotLat!!, d.pilotLon!!)
        val primaryOnScreen = c != null && viewport.contains(c.first, c.second)
        val onScreen = primaryOnScreen || operatorOnScreen
        if (onScreen) inViewport.add(d.id)

        // Paths may cross the viewport while their endpoint pin is outside it. Preserve the
        // existing drone exemption and ask for a tracker trail only after the cheap coordinate test.
        val keepOffscreen = d.type == DeviceType.DRONE ||
            (showBreadcrumbs && d.type == DeviceType.TRACKER && hasTrackerTrail(d.id))
        if (!onScreen && !keepOffscreen) continue
        overlayRows.add(d)
        if (c == null) continue // operator-only RID row: its OP marker still renders below

        val adaptiveCluster = clusterable(d.type) ||
            (zoom < MAP_FAR_ZOOM && d.type != DeviceType.DRONE)
        val cell = if (adaptiveCluster) clusterCell else PIN_GROUP_EPSILON_DEG
        val gx = floor(c.second / cell).toLong()
        val gy = floor(c.first / cell).toLong()
        val packed = (gx shl 32) xor (gy and 0xFFFF_FFFFL)
        // Geographic gx is nowhere near the 32-bit separation required for these namespaces to
        // collide. Keeping one insertion-ordered map preserves newest-first bucket priority.
        val key = if (adaptiveCluster) packed xor Long.MIN_VALUE else packed
        val bucket = buckets[key]
        if (bucket == null) buckets[key] = SymbolBucket(adaptiveCluster, row) else bucket.add(row)
    }

    val selected = ArrayList<MapSymbolGroup>(minOf(buckets.size, markerCap))
    var represented = 0
    var omitted = 0
    var bucketIndex = 0
    for (bucket in buckets.values) {
        val size = bucket.entries.size
        if (bucketIndex++ < markerCap) {
            selected.add(bucket.finish())
            represented += size
        } else {
            omitted += size
        }
    }
    return MapRenderPlan(
        overlayRows = overlayRows,
        symbols = selected,
        inViewportIds = inViewport,
        visited = visited,
        displayedRows = overlayRows.size,
        representedRows = represented,
        simplifiedRows = (represented - selected.size).coerceAtLeast(0),
        omittedRows = omitted,
    )
}

/** Identity-based cache: Compose can still collect hot Detection rows for the no-GPS RSSI ring,
 * while geometry/culling stays fixed until evidence, scope, filter, viewport or zoom actually
 * changes. */
internal class MapRenderPlanCache {
    private var rowsIdentity: Any? = null
    private var viewport: MapViewport? = null
    private var zoomBucket = Int.MIN_VALUE
    private var markerCap = Int.MIN_VALUE
    private var breadcrumbs = false
    private var cached: MapRenderPlan? = null

    fun get(
        rows: List<MapDetectionEvidence>,
        viewport: MapViewport,
        zoom: Double,
        markerCap: Int,
        showBreadcrumbs: Boolean,
        hasTrackerTrail: (String) -> Boolean,
    ): MapRenderPlan {
        val bucket = (zoom * 4.0).toInt()
        val prior = cached
        if (prior != null && rowsIdentity === rows && this.viewport == viewport &&
            zoomBucket == bucket && this.markerCap == markerCap &&
            breadcrumbs == showBreadcrumbs) return prior
        val next = buildMapRenderPlan(
            rows, viewport, zoom, markerCap, showBreadcrumbs, hasTrackerTrail)
        // Panning inside the same set of cells still has to run the cull once, but it need not
        // tear down/recreate identical osmdroid overlays. Reuse the old identity when the new
        // plan is structurally equal. This comparison runs on every MISS - a debounced viewport
        // or zoom change, a marker-cap or breadcrumb change, and every installed spatial revision
        // (coalesceDetectionRevisions meters those to the row-count ladder), since a new evidence
        // list identity is a miss by itself - but never on hot RSSI/count publications, which keep
        // the row list identity and return above.
        val stableNext = if (prior != null && prior == next) prior else next
        rowsIdentity = rows
        this.viewport = viewport
        zoomBucket = bucket
        this.markerCap = markerCap
        breadcrumbs = showBreadcrumbs
        cached = stableNext
        return stableNext
    }
}
