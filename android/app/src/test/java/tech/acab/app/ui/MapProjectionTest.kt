package tech.acab.app.ui

import kotlin.system.measureNanoTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.MAP_RECENT_WINDOW_MS
import tech.acab.app.ble.MapDetectionEvidence
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType

class MapProjectionTest {
    private fun detection(index: Int, rssi: Int = -70) = Detection.fromJson(
        JSONObject().put("t", DeviceType.TRACKER.raw).put("c", 80)
            .put("mac", "projection-$index").put("rssi", rssi))

    private fun denseRows(size: Int): List<MapDetectionEvidence> = List(size) { index ->
        MapDetectionEvidence(
            detection(index),
            coordinate = (20.0 + (index % 100) * 0.02) to
                (-120.0 + (index / 100) * 0.02),
            lastSeenAt = 1_800_000_000_000L - index,
        )
    }

    /** Deterministic workload instrumentation, not a device-speed threshold. The printed average
     * is useful in CI/build handoff while visited==size proves the algorithm remains one-pass. */
    private fun verifyDenseProjection(size: Int) {
        val rows = denseRows(size)
        val expected = buildMapRenderPlan(
            rows, MapViewport.WORLD, zoom = 11.0, markerCap = 600,
            showBreadcrumbs = true,
        )
        assertEquals(size, expected.visited)
        assertEquals(size, expected.displayedRows)
        assertEquals(size, expected.inViewportIds.size)
        assertEquals(size, expected.representedRows + expected.omittedRows)
        assertEquals(expected.representedRows - expected.symbols.size, expected.simplifiedRows)
        assertTrue(expected.symbols.size <= 600)
        // DENSITY, pinned from both ends. Every assertion above survives a grid collapse - one
        // cell swallowing the whole fixture leaves visited/displayed/represented untouched and
        // merely prints a faster benchmark - so a zoom or density-scale regression that merges
        // the map into a handful of bubbles passes these three dense tests unnoticed. The
        // fixture spreads 100 latitudes over just under 2 degrees, so at zoom 11 it must break
        // into many cells: 138 / 144 / 153 symbols today, the counts docs/map-performance.md
        // reports for this workload. Retune those deliberately, with the doc, rather than
        // discovering the collapse on a device.
        assertTrue("collapsed to ${expected.symbols.size} symbols", expected.symbols.size >= 100)
        val fullest = expected.symbols.maxOf { it.members.size }
        assertTrue("one bubble holds $fullest of $size rows", fullest <= size / 10)

        var checksum = 0
        var elapsed = 0L
        repeat(5) {
            var plan = expected
            elapsed += measureNanoTime {
                plan = buildMapRenderPlan(
                    rows, MapViewport.WORLD, zoom = 11.0, markerCap = 600,
                    showBreadcrumbs = true,
                )
            }
            // Equality traverses all members; keep that validation outside the timed stage.
            assertEquals(expected, plan)
            checksum += plan.symbols.size
        }
        assertEquals(expected.symbols.size * 5, checksum)
        println("MAP_PROJECTION_BENCH size=$size avg_ns=${elapsed / 5} " +
            "symbols=${expected.symbols.size} simplified=${expected.simplifiedRows} " +
            "omitted=${expected.omittedRows}")
    }

    @Test fun denseProjection500() = verifyDenseProjection(500)
    @Test fun denseProjection2500() = verifyDenseProjection(2_500)
    @Test fun denseProjection4999() = verifyDenseProjection(4_999)

    @Test
    fun cacheKeysMarkerCapAndReusesStructurallyUnchangedViewportPlan() {
        val rows = denseRows(40)
        val cache = MapRenderPlanCache()
        val wide = MapViewport(50.0, -80.0, 0.0, -140.0)
        val first = cache.get(rows, wide, 14.0, 20, true) { false }
        assertSame(first, cache.get(rows, wide, 14.0, 20, true) { false })

        // A pan whose bounds still contain the same cells performs the debounced cull but returns
        // the prior plan identity, which lets MapScreen retain its existing osmdroid overlays.
        val sameContents = cache.get(
            rows, wide.copy(north = 49.0), 14.0, 20, true) { false }
        assertSame(first, sameContents)

        val differentCap = cache.get(rows, wide, 14.0, 10, true) { false }
        assertNotSame(first, differentCap)
        assertTrue(differentCap.symbols.size <= 10)
    }

    /** MapScreen's overlay rebuild gate. Every field an overlay draws from has to move the key,
     *  and the plan is keyed by identity, which MapRenderPlanCache makes exact by handing back the
     *  prior instance for a structurally equal plan. FAILS IF MapOverlaySignature.equals drops
     *  ageMinute (pin age tiers would not roll until some unrelated change rebuilt), drops
     *  spatialRevision (a landed tracker crumb would not redraw its trail until then), drops a
     *  toggle or the zoom bucket, or compares the plan structurally instead of by the identity
     *  its KDoc promises (the equal copy would match). */
    @Test
    fun overlaySignatureMovesOnEveryDrawnFieldAndKeysThePlanByIdentity() {
        val plan = MapRenderPlan(emptyList(), emptyList(), emptyList(), 0, 0, 0, 0, 0)
        fun sig(
            p: MapRenderPlan = plan,
            zoomBucket: Int = 64,
            showBreadcrumbs: Boolean = false,
            showLabels: Boolean = false,
            spatialRevision: Long = 7L,
            ageMinute: Long = 30_000_000L,
        ) = MapOverlaySignature(
            p, zoomBucket, showBreadcrumbs, showLabels, spatialRevision, ageMinute,
        )

        assertEquals(sig(), sig())
        assertEquals(sig().hashCode(), sig().hashCode())
        assertNotEquals(sig(), sig(p = plan.copy()))
        assertNotEquals(sig(), sig(zoomBucket = 65))
        assertNotEquals(sig(), sig(showBreadcrumbs = true))
        assertNotEquals(sig(), sig(showLabels = true))
        assertNotEquals(sig(), sig(spatialRevision = 8L))
        assertNotEquals(sig(), sig(ageMinute = 30_000_001L))
    }

    @Test
    fun newSpatialRowsInvalidateTrailOnlyProjectionChanges() {
        val original = listOf(MapDetectionEvidence(
            detection(1), coordinate = 30.0 to -110.0, lastSeenAt = 1_800_000_000_000L))
        val offscreen = MapViewport(1.0, 1.0, -1.0, -1.0)
        val cache = MapRenderPlanCache()

        val withoutTrail = cache.get(original, offscreen, 15.0, 20, true) { false }
        assertTrue(withoutTrail.overlayRows.isEmpty())

        // AcabBleManager advances spatialEvidenceRev when a crumb lands; Compose then supplies a
        // new evidence list identity even though the endpoint coordinate itself is unchanged.
        val revisedRows = ArrayList(original)
        val withTrail = cache.get(revisedRows, offscreen, 15.0, 20, true) { true }
        assertNotSame(withoutTrail, withTrail)
        assertEquals(listOf(original.single().detection), withTrail.overlayRows)
    }

    @Test
    fun recentMembershipRefreshesTimeWithoutChangingGeometry() {
        val now = 1_800_000_000_000L
        val row = MapDetectionEvidence(
            detection(7), coordinate = 32.7 to -117.1,
            lastSeenAt = now - MAP_RECENT_WINDOW_MS + 1_000L,
        )
        val rows = listOf(row)
        assertEquals(listOf(row.detection.id), mapHistoryIds(
            rows, MapHistoryScope.Recent, now,
            latestLastSeen = mapOf(row.detection.id to row.lastSeenAt!!),
        ))

        val later = now + 60_000L
        assertTrue(mapHistoryIds(
            rows, MapHistoryScope.Recent, later,
            latestLastSeen = mapOf(row.detection.id to row.lastSeenAt!!),
        ).isEmpty())
        // A stationary row has no geometry revision, but its slow refreshed lastSeen keeps it in.
        assertEquals(listOf(row.detection.id), mapHistoryIds(
            rows, MapHistoryScope.Recent, later,
            latestLastSeen = mapOf(row.detection.id to later - 1_000L),
        ))
        // Unknown/approximate times are deliberately absent from the authoritative map.
        assertTrue(mapHistoryIds(
            rows, MapHistoryScope.Recent, later, latestLastSeen = emptyMap(),
        ).isEmpty())
        assertEquals(listOf(row.detection.id), mapHistoryIds(
            rows, MapHistoryScope.All, later, latestLastSeen = emptyMap(),
        ))
    }

    @Test
    fun recentWindowIncludesBoundaryButRejectsFutureAndUndatedRows() {
        // The window itself, as a LITERAL. The boundary assertions below derive their edges from
        // the constant, so they stay green whatever its value becomes; FAQ q-map-performance
        // ("recent (the default) is the last 15 minutes") and the Map's spoken "recent fifteen
        // minutes" state it, and docs/map-performance.md repeats it, so the number is a promise to
        // the user and not an implementation detail (the "recent" scope segment names the window).
        assertEquals(15 * 60_000L, MAP_RECENT_WINDOW_MS)
        val now = 1_800_000_000_000L
        assertTrue(mapHistoryIncludes(now, MapHistoryScope.Recent, now))
        assertTrue(mapHistoryIncludes(now - MAP_RECENT_WINDOW_MS, MapHistoryScope.Recent, now))
        assertFalse(mapHistoryIncludes(now - MAP_RECENT_WINDOW_MS - 1, MapHistoryScope.Recent, now))
        assertFalse(mapHistoryIncludes(now + 1, MapHistoryScope.Recent, now))
        assertFalse(mapHistoryIncludes(null, MapHistoryScope.Recent, now))
        assertTrue(mapHistoryIncludes(null, MapHistoryScope.All, now))
    }

    /** MapScreen keeps a 30 s (1 s under Active) invalidation tick (`historyNow`); the comparison
     * clock is the separate wall-clock read inside [recentScopeIds]. A row heard since the tick
     * carries a stamp newer than the tick, and [mapHistoryIncludes] rejects a stamp ahead of `now`,
     * so comparing against the tick hides exactly the freshest sightings until the next tick
     * (the pin-stops-appearing defect this pins shut). FAILS IF [recentScopeClock] returns anything older than the newest
     * stamp (a cached tick, `System.currentTimeMillis() - 30_000L`), or [recentScopeIds] stops
     * routing through it. */
    @Test
    fun recentScopeComparesAgainstWallClockNotTheInvalidationTick() {
        // Read the helper BETWEEN two wall-clock reads, in that order. The `in lo..hi` form
        // evaluates `hi` before its left operand, so a millisecond that ticked over between the
        // two calls failed the assert even with a correct helper.
        val before = System.currentTimeMillis()
        val clock = recentScopeClock()
        val after = System.currentTimeMillis()
        assertTrue(clock in before..after)

        // Heard one second ago: newer than a tick that fired ten seconds before it, older than
        // wall-clock. Exactly the row the default Recent lens must not lose.
        val stamp = System.currentTimeMillis() - 1_000L
        val tick = stamp - 10_000L
        val row = MapDetectionEvidence(detection(9), coordinate = 32.7 to -117.1, lastSeenAt = stamp)
        val rows = listOf(row)
        val latest = mapOf(row.detection.id to stamp)
        // The tick as the clock would hide the row: the defect the helper exists to prevent.
        assertTrue(mapHistoryIds(rows, MapHistoryScope.Recent, tick, latest).isEmpty())
        assertEquals(listOf(row.detection.id), recentScopeIds(rows, MapHistoryScope.Recent, latest))
        assertEquals(listOf(row.detection.id), recentScopeIds(rows, MapHistoryScope.All, emptyMap()))
        // The Active lens routes through the same clock: the tick would hide the 1 s-old row,
        // the wall-clock read keeps it.
        assertTrue(mapHistoryIds(rows, MapHistoryScope.Active, tick, latest).isEmpty())
        assertEquals(listOf(row.detection.id), recentScopeIds(rows, MapHistoryScope.Active, latest))
    }

    /** The Active window, as a LITERAL: FAQ q-map-performance ("active is the last 45 seconds",
     * the "active" scope segment's window) and the spoken "active forty-five seconds" hardcode it. Boundary in, one millisecond past it out, future and undated out, and each scope
     * uses its own window (a 46 s-old row is Recent, not Active). FAILS IF the Active arm reads
     * the Recent window. */
    @Test
    fun activeWindowIncludesBoundaryButRejectsStaleAndFutureRows() {
        assertEquals(45_000L, ACTIVE_NEARBY_WINDOW_MS)
        val now = 1_800_000_000_000L
        assertTrue(mapHistoryIncludes(now, MapHistoryScope.Active, now))
        assertTrue(mapHistoryIncludes(now - 45_000L, MapHistoryScope.Active, now))
        assertFalse(mapHistoryIncludes(now - 45_001L, MapHistoryScope.Active, now))
        assertFalse(mapHistoryIncludes(now + 1, MapHistoryScope.Active, now))
        assertFalse(mapHistoryIncludes(null, MapHistoryScope.Active, now))
        assertFalse(mapHistoryIncludes(now - 46_000L, MapHistoryScope.Active, now))
        assertTrue(mapHistoryIncludes(now - 46_000L, MapHistoryScope.Recent, now))
    }

    /** One stamp map feeds every segment count. Located a (10 s), b (60 s), c (20 min), d
     * (undated); unlocated e (10 s), f (undated). Under Recent: active 1, recent 2, all 4, and
     * withoutLocation counts only the unlocated rows in the SELECTED scope (e). FAILS IF Active
     * counts with the 15-minute window (active 2) or withoutLocation ignores the scope (2). */
    @Test
    fun mapScopeCountsTallyEveryScopeFromOneMap() {
        val now = 1_800_000_000_000L
        val lastSeen = mapOf(
            "a" to now - 10_000L,
            "b" to now - 60_000L,
            "c" to now - 20 * 60_000L,
            "e" to now - 10_000L,
        )
        val located = listOf("a", "b", "c", "d")
        val unlocated = listOf("e", "f")
        assertEquals(MapScopeCounts(active = 1, recent = 2, all = 4, withoutLocation = 1),
            mapScopeCounts(lastSeen, located, unlocated, MapHistoryScope.Recent, now))
        assertEquals(2, mapScopeCounts(lastSeen, located, unlocated, MapHistoryScope.All, now).withoutLocation)
        assertEquals(1, mapScopeCounts(lastSeen, located, unlocated, MapHistoryScope.Active, now).withoutLocation)
    }

    /** V-A6, the sample-data bypass (C10 / C11, MAP-01): in sample data every row is Active and
     * Recent, dated or not, the way Status and the Log count it; All is unchanged, and a live
     * session keeps both windows. Same stamps as above. Under demo: active 4 = recent 4 = all 4,
     * and the Active scope's withoutLocation counts both unlocated rows; mapHistoryIds under
     * Active keeps an undated row. FAILS IF the bypass is dropped (active 1), is missing from
     * Recent (recent 2 under active 4, the "active · 5 / recent · 0" of MAP-01) or leaks into a
     * live session (active 4 without demo). TWIN: iOS mapScopeIncludes(isDemoMode:) in
     * MapTabView.swift, pinned by MapPinRulesTests.testDemoModeCountsAndShowsEverySampleRowAsActive. */
    @Test
    fun demoModeCountsAndShowsEverySampleRowAsActive() {
        val now = 1_800_000_000_000L
        val lastSeen = mapOf(
            "a" to now - 10_000L,
            "b" to now - 60_000L,
            "c" to now - 20 * 60_000L,
            "e" to now - 10_000L,
        )
        val located = listOf("a", "b", "c", "d")
        val unlocated = listOf("e", "f")
        assertEquals(MapScopeCounts(active = 4, recent = 4, all = 4, withoutLocation = 2),
            mapScopeCounts(lastSeen, located, unlocated, MapHistoryScope.Recent, now, demo = true))
        assertEquals(2, mapScopeCounts(
            lastSeen, located, unlocated, MapHistoryScope.Active, now, demo = true).withoutLocation)
        assertEquals(1, mapScopeCounts(lastSeen, located, unlocated, MapHistoryScope.Recent, now).active)

        assertTrue(mapHistoryIncludes(null, MapHistoryScope.Active, now, demo = true))
        assertTrue(mapHistoryIncludes(now - 20 * 60_000L, MapHistoryScope.Active, now, demo = true))
        assertTrue(mapHistoryIncludes(now - 20 * 60_000L, MapHistoryScope.Recent, now, demo = true))
        assertFalse(mapHistoryIncludes(now - 20 * 60_000L, MapHistoryScope.Recent, now))
        assertFalse(mapHistoryIncludes(null, MapHistoryScope.Active, now))

        val undated = MapDetectionEvidence(detection(8), coordinate = 32.7 to -117.1, lastSeenAt = null)
        assertEquals(listOf(undated.detection.id), mapHistoryIds(
            listOf(undated), MapHistoryScope.Active, now, latestLastSeen = emptyMap(), demo = true))
        assertTrue(mapHistoryIds(
            listOf(undated), MapHistoryScope.Active, now, latestLastSeen = emptyMap()).isEmpty())
    }

    /** The ALL chip counts the located rows in the current scope, before the category chip: the
     * rows the pins represent with no chip on and the selected scope's segment count. Three
     * located rows (two heard in the last minute, one 20 minutes ago) and two unlocated rows (one
     * recent). Recent: ALL 2 = the recent segment 2; All: ALL 3 = the all segment 3; the two
     * unlocated rows only reach "without a location". FAILS IF the count reads the whole snapshot
     * (unlocated rows too: 3 under Recent, 5 under All) or ignores the scope (3 under Recent).
     * TWIN: iOS MapSnapshot.totalLocated (MapTabView.swift makeSnapshot). */
    @Test
    fun allChipCountsLocatedRowsInScopeOnly() {
        val now = 1_800_000_000_000L
        val stamps = listOf(now - 10_000L, now - 60_000L, now - 20 * 60_000L, now - 10_000L, null)
        val rows = stamps.mapIndexed { index, stamp ->
            MapDetectionEvidence(detection(index), if (index < 3) (32.7 to -117.1) else null, stamp)
        }
        val (located, unlocated) = splitMapEvidence(rows)
        assertEquals(3, located.size)
        assertEquals(2, unlocated.size)
        val lastSeen = rows.mapNotNull { r -> r.lastSeenAt?.let { r.detection.id to it } }.toMap()
        for ((scope, expected) in listOf(MapHistoryScope.Recent to 2, MapHistoryScope.All to 3)) {
            val ids = mapHistoryIds(located, scope, now, lastSeen)
            val allChip = mapScopedLocated(located, scope, ids).size
            assertEquals(expected, allChip)
            val segments = mapScopeCounts(lastSeen, located.map { it.detection.id },
                unlocated.map { it.detection.id }, scope, now)
            val segment = if (scope == MapHistoryScope.All) segments.all else segments.recent
            assertEquals(segment, allChip)
            assertEquals(allChip, mapCategoryChipModels(null, allChip, emptyMap()).first().count)
        }
        assertEquals(1, mapScopeCounts(lastSeen, located.map { it.detection.id },
            unlocated.map { it.detection.id }, MapHistoryScope.Recent, now).withoutLocation)
    }

    /** Decision B1: the main Map's "phone breadcrumb trails" option starts OFF, the fallback
     * mapPrefs.getBoolean("show_breadcrumbs", ...) uses when the user never flipped it. FAILS IF
     * the old default, true, comes back. TWIN: iOS MapPinRulesTests.
     * testMainMapBreadcrumbTrailsDefaultOff (MapTabView.showBreadcrumbsDefault). */
    @Test
    fun mainMapBreadcrumbTrailsDefaultOff() {
        assertFalse(MAP_SHOW_BREADCRUMBS_DEFAULT)
    }

    /** The persisted scope is read back through one pure function. An unknown or missing value
     * falls back to Recent, never a crash. FAILS IF it becomes a bare valueOf (throws). */
    @Test
    fun unknownStoredHistoryScopeFallsBackToRecent() {
        assertEquals(MapHistoryScope.Recent, parseMapHistoryScope("garbage"))
        assertEquals(MapHistoryScope.Recent, parseMapHistoryScope(null))
        assertEquals(MapHistoryScope.Active, parseMapHistoryScope("Active"))
        assertEquals(MapHistoryScope.All, parseMapHistoryScope("All"))
        assertEquals(MapHistoryScope.Recent, parseMapHistoryScope("Recent"))
    }

    /** The segment labels, lowercase-first with a middle dot. TWIN: iOS mapScopeSegmentLabel. */
    @Test
    fun mapScopeSegmentLabelFormatsAllThree() {
        assertEquals("active \u00B7 3", mapScopeSegmentLabel(MapHistoryScope.Active, 3))
        assertEquals("recent \u00B7 0", mapScopeSegmentLabel(MapHistoryScope.Recent, 0))
        assertEquals("all \u00B7 12", mapScopeSegmentLabel(MapHistoryScope.All, 12))
    }

    /** The honesty headline names both counts in order. TWIN: iOS mapHonestyHeadline. */
    @Test
    fun mapHonestyHeadlineNamesBothCounts() {
        assertEquals("5 on the map \u00B7 1 without a location", mapHonestyHeadline(5, 1))
        assertEquals("1 on the map \u00B7 0 without a location", mapHonestyHeadline(1, 0))
    }

    @Test
    fun viewportCullsAcrossDateLineWithoutHidingEitherSide() {
        val viewport = MapViewport(north = 11.0, east = -179.0, south = 9.0, west = 179.0)
        assertTrue(viewport.contains(10.0, 179.8))
        assertTrue(viewport.contains(10.0, -179.8))
        assertFalse(viewport.contains(10.0, 0.0))
        assertFalse(viewport.contains(12.0, 179.8))
        val rows = listOf(179.8, -179.8, 0.1).mapIndexed { index, longitude ->
            MapDetectionEvidence(detection(index), 10.0 to longitude, null)
        }
        val plan = buildMapRenderPlan(rows, viewport, 15.0, 100, false)
        assertEquals(rows.take(2).map { it.detection.id }, plan.inViewportIds)
        assertEquals(2, plan.representedRows)
        assertEquals(3, plan.visited)
    }

    @Test
    fun hiddenBreadcrumbSettingAvoidsOffscreenTrackerLookup() {
        val rows = listOf(MapDetectionEvidence(detection(1), 30.0 to -110.0, null))
        var trailReads = 0
        val plan = buildMapRenderPlan(rows, MapViewport(1.0, 1.0, -1.0, -1.0),
            15.0, 100, false) { trailReads++; true }
        assertEquals(0, trailReads)
        assertTrue(plan.overlayRows.isEmpty())
        assertTrue(plan.symbols.isEmpty())
    }

    @Test
    fun droneOverlaysSurviveOffscreenPinsAndOperatorOnlyRows() {
        val aircraft = detection(1).copy(type = DeviceType.DRONE)
        val operatorOnly = detection(2).copy(type = DeviceType.DRONE,
            pilotLat = 0.5, pilotLon = 0.5)
        val rows = listOf(
            MapDetectionEvidence(aircraft, 30.0 to -110.0, null),
            MapDetectionEvidence(operatorOnly, null, null),
        )
        val plan = buildMapRenderPlan(rows, MapViewport(1.0, 1.0, -1.0, -1.0),
            15.0, 100, false)
        assertEquals(listOf(aircraft, operatorOnly), plan.overlayRows)
        assertEquals(listOf(operatorOnly.id), plan.inViewportIds)
        assertEquals(listOf(aircraft), plan.symbols.single().members)
    }

    @Test
    fun farZoomCombinesInfrastructureAndPreservesMembersAndCategoryCounts() {
        val a = detection(1).copy(type = DeviceType.FLOCK_CAMERA)
        val b = detection(2).copy(type = DeviceType.FLOCK_CAMERA)
        val tracker = detection(3)
        val rows = listOf(a, b, tracker).mapIndexed { index, d ->
            MapDetectionEvidence(d, (20.0 + index * 0.0001) to -120.0, null)
        }
        val far = buildMapRenderPlan(rows, MapViewport.WORLD, 8.0, 100, false)
        assertEquals(1, far.symbols.size)
        assertEquals(listOf(a, b, tracker), far.symbols.single().members)
        assertEquals(a.type.category, far.symbols.single().dominantCategory)
        assertFalse(far.symbols.single().homogeneousCategory)
        assertTrue(far.symbols.single().cluster)
        assertEquals(2, far.simplifiedRows)

        val near = buildMapRenderPlan(rows, MapViewport.WORLD, 16.0, 100, false)
        assertEquals(3, near.symbols.size)
        assertEquals(2, near.symbols.count { !it.cluster })
    }

    /** THE SHARED LADDER, as literals. iOS `mapDetectionRefreshInterval(rowCount:)` in
     * MapTabView.swift returns the same four values in seconds and MapPinRulesTests pins them the
     * same way, so a change here is a change on both phones. Each rung is asserted from both sides
     * so an off-by-one at a boundary cannot pass. */
    @Test
    fun detectionRefreshLadderMirrorsIos() {
        assertEquals(300L, mapDetectionRefreshIntervalMs(0))
        assertEquals(300L, mapDetectionRefreshIntervalMs(499))
        assertEquals(500L, mapDetectionRefreshIntervalMs(500))
        assertEquals(500L, mapDetectionRefreshIntervalMs(1_999))
        assertEquals(750L, mapDetectionRefreshIntervalMs(2_000))
        assertEquals(750L, mapDetectionRefreshIntervalMs(3_999))
        assertEquals(1_000L, mapDetectionRefreshIntervalMs(4_000))
        assertEquals(1_000L, mapDetectionRefreshIntervalMs(4_999))
    }

    /** The wait arithmetic without a coroutine: nothing owed before a first install or once an
     * interval has passed (the leading edge), the remainder of the interval otherwise. FAILS IF
     * the never-installed sentinel stops reading as long ago, the remainder is not clamped at
     * zero, or the wait stops following the ladder. */
    @Test
    fun detectionRefreshWaitIsZeroWhenIdleAndTheRemainderOtherwise() {
        assertEquals(0L, detectionRefreshWaitMs(4_999, DETECTION_REFRESH_NEVER, 0L))
        assertEquals(0L, detectionRefreshWaitMs(4_999, DETECTION_REFRESH_NEVER, Long.MAX_VALUE / 4))
        assertEquals(250L, detectionRefreshWaitMs(100, lastInstallAt = 1_000L, now = 1_050L))
        assertEquals(950L, detectionRefreshWaitMs(4_999, lastInstallAt = 1_000L, now = 1_050L))
        assertEquals(0L, detectionRefreshWaitMs(100, lastInstallAt = 1_000L, now = 1_300L))
        assertEquals(0L, detectionRefreshWaitMs(100, lastInstallAt = 1_000L, now = 5_000L))
    }

    /** Leading + trailing, against the real coroutine and real time. Six revisions in a burst
     * under the 300 ms rung install their first revision at once and their last one after the
     * interval, and nothing between. FAILS IF the ceiling is removed (every revision installs),
     * turned into a plain debounce (the first one waits out the interval), or given a busy-drop
     * gate instead of a trailing edge (the sixth never lands and the await times out). The
     * margins are a 300 ms interval against a burst that takes a few milliseconds, so a scheduler
     * hiccup does not flip the result. */
    @Test
    fun detectionBurstInstallsItsFirstAndLastRevisionsOnly(): Unit = runBlocking {
        val clock = { System.nanoTime() / 1_000_000L }
        val revisions = MutableStateFlow(0L)
        val installs = ArrayList<Long>()
        val installedAt = ArrayList<Long>()
        val follower = launch {
            coalesceDetectionRevisions(
                revisions, installedRevision = 0L, rowCount = { 100 }, clock = clock,
            ) { installs += it; installedAt += clock() }
        }
        suspend fun awaitInstalls(n: Int) =
            withTimeout(5_000L) { while (installs.size < n) delay(5L) }

        val emittedFirstAt = clock()
        revisions.value = 1L
        awaitInstalls(1)
        assertEquals(listOf(1L), installs)
        assertTrue("leading edge waited ${installedAt[0] - emittedFirstAt} ms",
            installedAt[0] - emittedFirstAt < 300L)

        for (rev in 2L..6L) { revisions.value = rev; delay(1L) }
        awaitInstalls(2)
        assertEquals(listOf(1L, 6L), installs)
        assertTrue("trailing edge landed ${installedAt[1] - emittedFirstAt} ms after the first",
            installedAt[1] - emittedFirstAt >= 300L)

        // Quiet for longer than the interval: the next lone revision is a leading edge again.
        delay(350L)
        val emittedLastAt = clock()
        revisions.value = 7L
        awaitInstalls(3)
        assertEquals(listOf(1L, 6L, 7L), installs)
        assertTrue("idle revision waited ${installedAt[2] - emittedLastAt} ms",
            installedAt[2] - emittedLastAt < 300L)
        follower.cancel()
    }
    /** MAP-01: in sample data the segments keep active <= recent <= all, 20 minutes after the
     * seed stamped its rows (past the 15 minute Recent window). Wrong input: the bypass on Active
     * only gave active 3 with recent 0. TWIN: the iOS MAP-01 test in MapPinRulesTests. */
    @Test
    fun sampleDataScopesStayNested20MinutesAfterSeeding() {
        val now = 1_800_000_000_000L
        val seeded = now - 20 * 60_000L
        val lastSeen = mapOf("a" to seeded, "b" to seeded, "c" to seeded)
        val counts = mapScopeCounts(lastSeen, listOf("a", "b", "c"), emptyList(),
            MapHistoryScope.Recent, now, demo = true)
        assertTrue("active ${counts.active} > recent ${counts.recent}", counts.active <= counts.recent)
        assertTrue("recent ${counts.recent} > all ${counts.all}", counts.recent <= counts.all)
        assertEquals(3, counts.recent)
    }
}
