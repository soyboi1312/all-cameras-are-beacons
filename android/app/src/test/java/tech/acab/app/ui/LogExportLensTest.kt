package tech.acab.app.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.DetectionExportRowSnapshot
import tech.acab.app.ble.DetectionExportSnapshot
import tech.acab.app.ble.LOG_ACTIVE_SECTION_HEADER
import tech.acab.app.ble.activeBoundary
import tech.acab.app.ble.frozenNewIdSet
import tech.acab.app.ble.newestFirstEnvelope
import tech.acab.app.model.BodyCamSignature
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceNames
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.bodyCamSignature
import tech.acab.app.model.maker
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.vendor
import java.time.ZoneId
import java.time.ZonedDateTime

class LogExportLensTest {
    private fun row(
        mac: String,
        type: DeviceType,
        offline: Boolean = false,
        rssi: Int = -50,
        name: String? = null,
        rid: String? = null,
        detail: String? = null,
    ) = Detection.fromJson(
        JSONObject().put("t", type.raw).put("c", 1).put("mac", mac).put("rssi", rssi)
            .putOpt("name", name).putOpt("id", rid).putOpt("det", detail)
            .put("new", true).put("hist", offline).put("offline", offline))

    /** Offline is a filter that composes with any scope, not a scope of its own: offline only
     *  under All keeps the replayed tracker, and under New it still needs the row to be unseen.
     *  A predicate that ignores offlineOnly returns both trackers. */
    @Test
    fun categoryAndScopeApplyToTheSuppliedLiveOrPausedFeed() {
        val alpr = row("a", DeviceType.FLOCK_CAMERA)
        val trackerOffline = row("b", DeviceType.TRACKER, offline = true)
        val trackerLive = row("c", DeviceType.TRACKER)
        val laterLive = row("d", DeviceType.TRACKER)
        val live = listOf(laterLive, trackerLive, trackerOffline, alpr)

        assertEquals(
            listOf(trackerOffline),
            filterLogRows(live, "TRACKER", LogScope.New, setOf(trackerOffline.id)),
        )
        assertEquals(
            listOf(trackerOffline),
            filterLogRows(live, "TRACKER", LogScope.All, emptySet(), offlineOnly = true),
        )
        assertEquals(
            listOf(trackerOffline),
            filterLogRows(
                live, "TRACKER", LogScope.New, setOf(trackerOffline.id, trackerLive.id),
                offlineOnly = true,
            ),
        )

        // A paused export supplies its frozen feed; a later live row is not available for the
        // lens to accidentally re-read or add.
        val paused = live.drop(1)
        assertEquals(
            listOf(trackerLive, trackerOffline),
            filterLogRows(paused, "TRACKER", LogScope.All, emptySet()),
        )
    }

    @Test
    fun watchedLensOverlapsUnderlyingTypesAndKeepsHistoricalWatchedRows() {
        val starredTracker = row("AA:00:00:00:00:01", DeviceType.TRACKER)
        val ordinaryCamera = row("AA:00:00:00:00:02", DeviceType.NETWORK_CAMERA)
        val historicalWatched = row("AA:00:00:00:00:03", DeviceType.WATCHED)
        val feed = listOf(starredTracker, ordinaryCamera, historicalWatched)
        val watchedMacs = setOf(starredTracker.mac.lowercase())

        assertEquals(
            listOf(starredTracker, historicalWatched),
            filterLogRows(
                feed, WATCHED_FILTER_KEY, LogScope.All, emptySet(), watchedMacs,
            ),
        )
        // The star lens does not rewrite the tracker's real category.
        assertEquals(
            listOf(starredTracker),
            filterLogRows(feed, "TRACKER", LogScope.All, emptySet(), watchedMacs),
        )
        assertEquals(2, watchedDetectionCount(feed, watchedMacs))

        // Unstarring removes the overlapping tracker, but historical firmware t=8 evidence keeps
        // its WATCHED semantics without requiring current watchlist membership.
        assertEquals(
            listOf(historicalWatched),
            filterLogRows(feed, WATCHED_FILTER_KEY, LogScope.All, emptySet()),
        )
    }

    @Test
    fun pausedExportKeepsSideMetadataAfterTheLiveStoreDropsItsRows() {
        val kept = row("kept", DeviceType.TRACKER)
        val filteredOut = row("other", DeviceType.FLOCK_CAMERA)
        val keptAt = 1_700_000_123_456L
        val frozen = DetectionExportSnapshot(listOf(
            DetectionExportRowSnapshot(
                kept, firstSeenMs = keptAt,
                timeBasis = TimeBasis.Reconstructed(keptAt, 9),
                observerCoord = 32.7 to -117.1,
            ),
            DetectionExportRowSnapshot(
                filteredOut, firstSeenMs = keptAt + 1_000L,
                timeBasis = TimeBasis.Exact,
                observerCoord = 40.0 to -73.0,
            ),
        ))
        val vm = LogViewModel()
        vm.pause(frozen)

        // No live store is modelled here, and none can be: exportSnapshot reads only the frozen
        // field and the rows it is handed, so what the manager holds is irrelevant BY
        // CONSTRUCTION. That is the property under test - the paused export lenses its own
        // immutable snapshot and therefore keeps the original evidence metadata. (A local list
        // built and cleared here used to stand in for the eviction; it was read by nothing, and
        // reading like coverage is worse than having none.)
        val exported = vm.exportSnapshot(listOf(kept))!!

        assertEquals(listOf(kept), exported.rows.map { it.detection })
        assertEquals(keptAt, exported.rows.single().firstSeenMs)
        assertEquals(TimeBasis.Reconstructed(keptAt, 9), exported.rows.single().timeBasis)
        assertEquals(32.7 to -117.1, exported.rows.single().observerCoord)

        // NEW membership must come from the frozen firstSeenMs, which is what makes it survive an
        // eviction: the live sibling (AcabBleManager.newIdSet) reads firstSeenAt, and a missing
        // entry there turns an evicted row into NEW. frozenNewIdSet is called directly, with no
        // manager involved, so what this pins is that the frozen path never consults one.
        assertEquals(emptySet<String>(), frozenNewIdSet(
            exported.rows, seenWatermark = keptAt + 10_000L,
            approxWatermark = AcabBleManager.HIST_PSEUDO_BASE))
    }

    @Test
    fun searchIsTokenizedFoldedAndOnlyMacsIgnoreAddressSeparators() {
        val named = row(
            "AA:BB:CC:DD:EE:01", DeviceType.TRACKER, name = "Café Garden Camera")
        val vendor = row(
            "10:20:30:40:50:60", DeviceType.BODY_CAM,
            detail = "Motorola Solutions OUI")

        assertEquals(listOf(named), filterLogRows(
            listOf(named, vendor), null, LogScope.All, emptySet(),
            query = "cafe camera",
        ))
        assertEquals(listOf(named), filterLogRows(
            listOf(named, vendor), null, LogScope.All, emptySet(),
            query = "aabb-cc",
        ))
        // Punctuation stays literal for ordinary words; it is not stripped from a combined
        // haystack where field boundaries could manufacture a match.
        assertEquals(emptyList<Detection>(), filterLogRows(
            listOf(named), null, LogScope.All, emptySet(), query = "garden-camera"))
        assertEquals(listOf(vendor), filterLogRows(
            listOf(named, vendor), null, LogScope.All, emptySet(), query = "motorola"))
    }

    /** `Detection.vendor` is byte-identical on both platforms, and for a body cam it reads the
     *  signature the board reported instead of answering the whole category with one maker's
     *  name. iOS DetectionLogLensTests pins the same three answers. This side is the table iOS
     *  was rewritten to, so what this pins is the rule, not a fix: answering BODY_CAM with a
     *  fixed "Axon (unverified)" (the retired iOS arm) fails the Motorola row (it would match
     *  "axon") and the "unverified" row (a word no vendor carries would match every body cam). */
    @Test
    fun bodyCamSearchReadsTheSignatureVendorNotAFixedGuess() {
        val axon = row("AA:BB:CC:DD:EE:01", DeviceType.BODY_CAM, detail = "BWC DEVICE")
        val motorola = row(
            "AA:BB:CC:DD:EE:02", DeviceType.BODY_CAM, detail = "Motorola Solutions OUI")
        val rows = listOf(axon, motorola)
        assertEquals(listOf(axon), filterLogRows(rows, null, LogScope.All, emptySet(), query = "axon"))
        assertEquals(listOf(motorola), filterLogRows(rows, null, LogScope.All, emptySet(), query = "motorola"))
        assertEquals(emptyList<Detection>(), filterLogRows(rows, null, LogScope.All, emptySet(), query = "unverified"))
    }

    /** The fifth body-cam signature (firmware 2.1.0). WatchGuard Video belongs to Motorola
     *  Solutions, but the firmware reports the registry's name, so the row names WatchGuard as the
     *  maker and a "motorola" search does not claim it. iOS DetectionLogLensTests pins the same
     *  answers. Dropping the enum entry fails every assertion here: the row falls back to the
     *  category's "Axon / Utility / Motorola", which matches "motorola". */
    @Test
    fun watchGuardRowNamesItsOwnMaker() {
        val wg = row("00:1D:96:E7:97:4F", DeviceType.BODY_CAM, detail = "WatchGuard Video OUI")
        assertEquals(BodyCamSignature.WATCHGUARD, wg.bodyCamSignature)
        assertEquals("WatchGuard Video", wg.vendor)
        assertEquals("WatchGuard Video", wg.maker)
        assertEquals("WatchGuard Video", wg.ouiVendor)
        assertEquals(listOf(wg), filterLogRows(listOf(wg), null, LogScope.All, emptySet(), query = "watchguard"))
        assertEquals(emptyList<Detection>(), filterLogRows(listOf(wg), null, LogScope.All, emptySet(), query = "motorola"))
    }

    /** The lens-summary line, the list's footer, counts the lens the list shows, which is the
     *  FROZEN feed while paused, names that feed and carries the category, so "5 of 5 paused"
     *  says the list is a snapshot, not that sightings were lost. Byte-identical to iOS
     *  `logLensSummary` in DetectionsView.swift, text and spoken form; a changed word here is a
     *  changed word there. */
    @Test
    fun theLensSummaryLineNamesTheListItCounted() {
        assertEquals("3 of 10 retained", logLensSummaryText(3, 10, paused = false, category = null))
        assertEquals("3 of 10 paused · ALPR", logLensSummaryText(3, 10, paused = true, category = "ALPR"))
        assertEquals("3 matching detections of 10 retained",
            logLensSummaryDescription(3, 10, paused = false, category = null))
        assertEquals("3 matching detections of 10 in the paused log · ALPR",
            logLensSummaryDescription(3, 10, paused = true, category = "ALPR"))
    }

    /** The fold is NFD + strip combining marks + SIMPLE lowercase on BOTH platforms, so the same
     *  query returns the same rows on both phones. Pinned against the expected answers, not the
     *  platform's own transform: iOS full case folding (ß -> ss) matched "strasse" there and
     *  nowhere here, which is the drift this test exists to catch. iOS DetectionLogLensTests
     *  pins the same four answers. Folding through `String.lowercase()` on the whole string
     *  instead of per code point keeps the answers but loses the supplementary-plane claim in
     *  normalizedLogSearch's KDoc; folding with a ß -> ss expansion fails "strasse". */
    @Test
    fun foldIsNFDStripMarksAndSimpleLowercaseOnBothPlatforms() {
        val street = row("AA:BB:CC:DD:EE:01", DeviceType.TRACKER, name = "Straße Cam")
        val istanbul = row("AA:BB:CC:DD:EE:02", DeviceType.TRACKER, name = "İstanbul Gate")
        val rows = listOf(street, istanbul)

        // The exact spelling always matches; capital sharp s lowercases to ß on both sides.
        assertEquals(listOf(street), filterLogRows(rows, null, LogScope.All, emptySet(), query = "straße"))
        assertEquals(listOf(street), filterLogRows(rows, null, LogScope.All, emptySet(), query = "STRAẞE"))
        // No ß -> ss expansion on either platform.
        assertEquals(emptyList<Detection>(), filterLogRows(rows, null, LogScope.All, emptySet(), query = "strasse"))
        // NFD splits the dot off the capital İ before it is stripped.
        assertEquals(listOf(istanbul), filterLogRows(rows, null, LogScope.All, emptySet(), query = "istanbul"))
    }

    /** Tokens split on the Unicode White_Space set: a no-break space or an ideographic space
     *  pasted from a note separates two words exactly as a plain space does, in the query and in
     *  a row's name. `\\s` would pass this on a device and fail it here on the host JVM, which is
     *  why isLogTokenSeparator spells the set out; iOS pins the same two characters. */
    @Test
    fun noBreakAndIdeographicSpacesSplitTokensLikeASpace() {
        val named = row("AA:BB:CC:DD:EE:01", DeviceType.TRACKER, name = "Café Garden Camera")
        val spacedName = row("AA:BB:CC:DD:EE:02", DeviceType.TRACKER, name = "Garden Cam")
        val rows = listOf(named, spacedName)

        assertEquals(listOf(named), filterLogRows(rows, null, LogScope.All, emptySet(), query = "garden camera"))
        assertEquals(listOf(named), filterLogRows(rows, null, LogScope.All, emptySet(), query = "cafe　garden"))
        // Each word is still required.
        assertEquals(emptyList<Detection>(), filterLogRows(rows, null, LogScope.All, emptySet(), query = "garden garage"))
        assertEquals(rows, filterLogRows(rows, null, LogScope.All, emptySet(), query = "garden cam"))
    }

    /** The folded haystack is reused across publishes: a re-sighted row that changed only its
     *  RSSI must not be derived and folded again, while a row whose identity text moved (a new
     *  advertised name, or a rename through DeviceNames) must be. Dropping the identity compare
     *  in LogSearchIndex.entry fails the second half (a stale haystack keeps matching the old
     *  name); dropping the reuse path fails the first (folds reaches 2). */
    @Test
    fun foldedHaystackIsReusedUntilTheRowsIdentityTextMoves() {
        val index = LogSearchIndex()
        val query = PreparedLogQuery("garden")
        val first = row("AA:BB:CC:DD:EE:01", DeviceType.TRACKER, rssi = -80, name = "Garden Camera")
        val louder = first.copy(rssi = -40, count = 2)
        assertTrue(query.matches(first, index))
        assertTrue(query.matches(louder, index))
        assertEquals("an RSSI-only change reuses the folded haystack", 1, index.folds)

        val renamed = louder.copy(name = "Garage Camera")
        assertFalse(query.matches(renamed, index))
        assertEquals("a changed advertised name refolds the row", 2, index.folds)

        DeviceNames.rebuild(
            watchedPairs = listOf(renamed.mac to "Garden Gate"),
            ignoredPairs = emptyList(),
        )
        try {
            assertTrue("a custom name reaches the search", query.matches(renamed, index))
            assertEquals("a DeviceNames rebuild refolds through its revision", 3, index.folds)
        } finally {
            DeviceNames.rebuild(emptyList(), emptyList())
        }
    }

    /** The visible "NODE EE01" chip is searchable through its four address characters, and the
     *  constant word "node" is in no row's haystack. iOS DetectionLogLensTests pins the same pair
     *  for the same lens. Re-adding a "node <last4>" literal to PreparedLogQuery's field list
     *  fails the second assertion: a token every row carries turns the lens into a no-op while
     *  the chip and the export slug still say a search is applied. */
    @Test
    fun theNodeHandleMatchesByItsCharactersButTheWordNodeMatchesNothing() {
        val named = row("AA:BB:CC:DD:EE:01", DeviceType.TRACKER, name = "Field tag")
        val other = row("AA:BB:CC:DD:EE:02", DeviceType.TRACKER, name = "Field pole")
        val rows = listOf(named, other)
        assertEquals(listOf(named), filterLogRows(
            rows, null, LogScope.All, emptySet(), query = "ee01"))
        assertEquals(emptyList<Detection>(), filterLogRows(
            rows, null, LogScope.All, emptySet(), query = "node"))
        assertEquals(emptyList<Detection>(), filterLogRows(
            rows, null, LogScope.All, emptySet(), query = "node ee01"))
    }

    @Test
    fun searchFindsCustomNamesAndRidThenStrongestKeepsNewestTieOrder() {
        val weak = row(
            "AA:00:00:00:00:11", DeviceType.DRONE, rssi = -85, rid = "RID-ALPHA")
        val newestStrong = row("AA:00:00:00:00:12", DeviceType.TRACKER, rssi = -40)
        val olderStrong = row("AA:00:00:00:00:13", DeviceType.TRACKER, rssi = -40)
        DeviceNames.rebuild(
            watchedPairs = listOf(newestStrong.mac to "Garden Gate"),
            ignoredPairs = emptyList(),
        )
        try {
            assertEquals(listOf(newestStrong), filterLogRows(
                listOf(weak, newestStrong, olderStrong), null, LogScope.All, emptySet(),
                query = "garden gate",
            ))
            assertEquals(listOf(weak), filterLogRows(
                listOf(weak, newestStrong, olderStrong), null, LogScope.All, emptySet(),
                query = "rid-alpha",
            ))
            assertEquals(
                listOf(newestStrong, olderStrong, weak),
                filterLogRows(
                    listOf(weak, newestStrong, olderStrong), null, LogScope.All, emptySet(),
                    sort = LogSort.Strongest,
                ),
            )
        } finally {
            DeviceNames.rebuild(emptyList(), emptyList())
        }
    }

    @Test
    fun frozenExportRetainsTheExactSearchedAndSortedDisplayOrder() {
        val weakMatch = row(
            "A0:00:00:00:00:01", DeviceType.TRACKER, rssi = -80, name = "Field tag")
        val strongMatch = row(
            "A0:00:00:00:00:02", DeviceType.TRACKER, rssi = -35, name = "Field beacon")
        val other = row(
            "A0:00:00:00:00:03", DeviceType.FLOCK_CAMERA, rssi = -20, name = "Field pole")
        val frozenRows = listOf(weakMatch, strongMatch, other).mapIndexed { index, d ->
            DetectionExportRowSnapshot(
                detection = d,
                firstSeenMs = 1_800_000_000_000L + index,
                timeBasis = TimeBasis.Exact,
                observerCoord = null,
            )
        }
        val vm = LogViewModel().apply { pause(DetectionExportSnapshot(frozenRows)) }
        val shown = filterLogRows(
            vm.frozen, "TRACKER", LogScope.All, emptySet(), query = "field",
            sort = LogSort.Strongest,
        )
        val exported = vm.exportSnapshot(shown)!!

        assertEquals(listOf(strongMatch, weakMatch), shown)
        assertEquals(shown, exported.rows.map { it.detection })
        assertEquals(
            listOf(1_800_000_000_001L, 1_800_000_000_000L),
            exported.rows.map { it.firstSeenMs },
        )
    }

    /** Active keeps only live rows inside the window. A replayed row is never Active, even with
     *  its id in the set (the caller adds nothing replayed, but the predicate must not trust
     *  that). Dropping the `!d.offline` clause from logScopeKeeps keeps the replayed row. */
    @Test
    fun activeScopeCutKeepsOnlyFreshLiveRows() {
        val a = row("AA:00:00:00:00:01", DeviceType.TRACKER)
        val b = row("AA:00:00:00:00:02", DeviceType.TRACKER)
        val c = row("AA:00:00:00:00:03", DeviceType.TRACKER, offline = true)
        val activeIds = setOf(a.id, c.id)
        assertEquals(listOf(a), logScopeCut(listOf(a, b, c), LogScope.Active, emptySet(), activeIds))
        assertEquals(listOf(a), filterLogRows(listOf(a, b, c), null, LogScope.Active, emptySet(), activeIds = activeIds))
    }

    /** The segment counts come from the lens (here the TRACKER category), not from the store:
     *  counting over the whole feed gives active 2, new 3. */
    @Test
    fun scopeCountsComeFromTheLensNotTheStore() {
        val t1 = row("AA:00:00:00:00:11", DeviceType.TRACKER)
        val t2 = row("AA:00:00:00:00:12", DeviceType.TRACKER)
        val t3 = row("AA:00:00:00:00:13", DeviceType.TRACKER)
        val p1 = row("AA:00:00:00:00:14", DeviceType.FLOCK_CAMERA)
        val p2 = row("AA:00:00:00:00:15", DeviceType.FLOCK_CAMERA)
        val feed = listOf(t1, t2, t3, p1, p2)
        val newIds = setOf(t1.id, t2.id, p1.id)
        val activeIds = setOf(t3.id, p2.id)
        val lensAll = filterLogRows(feed, "TRACKER", LogScope.All, newIds)
        assertEquals(LogScopeCounts(active = 1, new = 2), logScopeCounts(lensAll, newIds, activeIds))
    }

    /** "active · N", "new · N", "all": All carries no count. TWIN: iOS logScopeSegmentLabel. */
    @Test
    fun logScopeSegmentLabelCountsOnlyActiveAndNew() {
        assertEquals("active · 3", logScopeSegmentLabel(LogScope.Active, 3))
        assertEquals("new · 0", logScopeSegmentLabel(LogScope.New, 0))
        assertEquals("all", logScopeSegmentLabel(LogScope.All, 5))
    }

    /** The drawn segment label binds the count to its dot (a wrap breaks before the dot, never
     *  between the dot and the count), and the row's supporting line holds each dot to the word
     *  before it. Both are display-only transforms: the pure labels above stay iOS-identical. */
    @Test
    fun displayTransformsBindMiddleDots() {
        assertEquals("active · 5", segmentLabelForDisplay(logScopeSegmentLabel(LogScope.Active, 5)))
        assertEquals("all", segmentLabelForDisplay(logScopeSegmentLabel(LogScope.All, 5)))
        assertEquals("recent · 0", segmentLabelForDisplay(mapScopeSegmentLabel(MapHistoryScope.Recent, 0)))
        assertEquals(
            "Tracker · manufacturer data · 60%",
            keepingMiddleDotsAttached("Tracker · manufacturer data · 60%"),
        )
    }

    /** Newest splits into heard in the last 45 s / earlier today / older, in feed order, with
     *  empty sections left out. r3 was first filed from a bracketed replay and then heard live
     *  today, so its live stamp is trusted (the `!d.offline` arm; the basis map holds the
     *  FIRST-seen basis). r4 is a bracketed replay heard today: untrusted, so older. r5 is a
     *  reconstructed replay from this morning: trusted. r6 has no basis entry (Exact). r7 is
     *  from yesterday. Ignoring the basis gives [2, 4, 1]; a stamp map without the replayed rows
     *  gives [2, 2, 3]; dropping the live arm gives [2, 2, 3]. */
    @Test
    fun newestSortSplitsActiveThenTodayThenOlder() {
        val zone = ZoneId.of("America/Los_Angeles")
        val now = ZonedDateTime.of(2026, 9, 24, 12, 0, 0, 0, zone)
        fun at(hour: Int, dayOffset: Long = 0) =
            now.plusDays(dayOffset).withHour(hour).toInstant().toEpochMilli()
        val nowMs = now.toInstant().toEpochMilli()
        val r1 = row("AA:00:00:00:00:21", DeviceType.TRACKER)
        val r2 = row("AA:00:00:00:00:22", DeviceType.TRACKER)
        val r3 = row("AA:00:00:00:00:23", DeviceType.TRACKER)
        val r4 = row("AA:00:00:00:00:24", DeviceType.TRACKER, offline = true)
        val r5 = row("AA:00:00:00:00:25", DeviceType.TRACKER, offline = true)
        val r6 = row("AA:00:00:00:00:26", DeviceType.TRACKER)
        val r7 = row("AA:00:00:00:00:27", DeviceType.TRACKER)
        val stamps = mapOf(
            r1.id to nowMs - 5_000L,
            r2.id to nowMs - 10_000L,
            r3.id to at(10),
            r4.id to at(11),
            r5.id to at(8),
            r6.id to at(9),
            r7.id to at(15, dayOffset = -1),
        )
        val timeBases = mapOf(
            r3.id to TimeBasis.Bracketed(1L, 2L),
            r4.id to TimeBasis.Bracketed(1L, 2L),
            r5.id to TimeBasis.Reconstructed(at(8), 60),
        )
        val activeIds = setOf(r1.id, r2.id)
        val basis: (String) -> TimeBasis = { timeBases[it] ?: TimeBasis.Exact }

        val all = listOf(r1, r2, r3, r4, r5, r6, r7)
        val sections = logSections(all, LogScope.All, activeIds, stamps::get, basis, nowMs, zone)
        assertEquals(
            listOf(LOG_ACTIVE_SECTION_HEADER, LOG_EARLIER_TODAY_HEADER, LOG_OLDER_HEADER),
            sections.map { it.title },
        )
        assertEquals(listOf(listOf(r1, r2), listOf(r3, r5, r6), listOf(r4, r7)), sections.map { it.rows })

        // New keeps the three sections, exactly as All does (decision L6 changes only Active).
        assertEquals(sections, logSections(all, LogScope.New, activeIds, stamps::get, basis, nowMs, zone))

        val onlyOld = logSections(listOf(r7), LogScope.All, emptySet(), stamps::get, basis, nowMs, zone)
        assertEquals(listOf(LOG_OLDER_HEADER), onlyOld.map { it.title })
    }

    /** Decision L6: under the Active segment the Log draws NO time-section header. Every shown row
     *  there was heard in the last 45 s, so the builder returns ONE untitled section holding the
     *  shown rows in feed order, and the list skips the header of an untitled section. Wrong input:
     *  a builder that ignores the scope returns [LOG_ACTIVE_SECTION_HEADER] here (a header drawn
     *  under Active) and fails the first assertion. An empty Active cut has no section.
     *  TWIN: iOS DetectionLogLensTests.testActiveScopeIsOneUntitledSection. */
    @Test
    fun activeScopeIsOneUntitledSection() {
        val zone = ZoneId.of("America/Los_Angeles")
        val nowMs = ZonedDateTime.of(2026, 9, 24, 12, 0, 0, 0, zone).toInstant().toEpochMilli()
        val r1 = row("AA:00:00:00:00:31", DeviceType.TRACKER)
        val r2 = row("AA:00:00:00:00:32", DeviceType.TRACKER)
        val stamps = mapOf(r1.id to nowMs - 5_000L, r2.id to nowMs - 10_000L)
        val basis: (String) -> TimeBasis = { TimeBasis.Exact }
        val sections = logSections(
            listOf(r1, r2), LogScope.Active, setOf(r1.id, r2.id), stamps::get, basis, nowMs, zone)
        assertEquals(listOf<String?>(null), sections.map { it.title })
        assertEquals(listOf(listOf(r1, r2)), sections.map { it.rows })
        assertTrue(logSections(emptyList(), LogScope.Active, emptySet(), stamps::get, basis, nowMs, zone).isEmpty())
    }

    /** One overline, one order on both apps: OFFLINE, MUTED, then the basis word. */
    @Test
    fun rowOverlineNamesProvenanceInOneOrder() {
        assertEquals("OFFLINE · MUTED · RECON", logRowOverline(true, true, TimeBasis.Reconstructed(0, 0)))
        assertNull(logRowOverline(false, false, TimeBasis.Exact))
        assertNull(logRowOverline(false, false, null))
        assertEquals("RANGE", logRowOverline(false, false, TimeBasis.Bracketed(1L, 2L)))
        assertEquals("OFFLINE · NO TIME", logRowOverline(true, false, TimeBasis.Unknown))
    }

    /** The spoken verdict bands are iOS DetectionRow.confidenceWord's: under 50 weak, under 80
     *  partial, 80 up strong. A `<= 50` weak band fails the 50 row. */
    @Test
    fun confidenceWordBandsMatchIos() {
        assertEquals("weak match, verify", confidenceWord(49))
        assertEquals("partial match", confidenceWord(50))
        assertEquals("partial match", confidenceWord(79))
        assertEquals("strong match", confidenceWord(80))
    }

    /** A paused Active export freezes the Active cut at the pause instant. The frozen stamps are
     *  evaluated against pausedAtMs, not a later clock (at t0 + 60 s the cut would empty), the
     *  export takes the cut, never the whole lens (three rows), and resume clears the instant. */
    @Test
    fun pausedActiveExportFreezesTheActiveCut() {
        val t0 = 1_758_700_000_000L
        val replayed = row("AA:00:00:00:00:31", DeviceType.TRACKER, offline = true)
        val fresh = row("AA:00:00:00:00:32", DeviceType.TRACKER)
        val stale = row("AA:00:00:00:00:33", DeviceType.TRACKER)
        fun snap(d: Detection, lastSeen: Long) = DetectionExportRowSnapshot(
            d, firstSeenMs = lastSeen, timeBasis = TimeBasis.Exact, observerCoord = null, lastSeenMs = lastSeen)
        val snapshot = DetectionExportSnapshot(listOf(
            snap(replayed, t0 - 5_000L), snap(fresh, t0 - 10_000L), snap(stale, t0 - 60_000L)))
        val vm = LogViewModel()
        vm.pause(snapshot, atMs = t0)
        assertEquals(t0, vm.pausedAtMs)

        val feedLive = vm.frozen.filter { !it.offline }
        val last = vm.frozenExport!!.lastSeenMsById()
        val env = newestFirstEnvelope(feedLive.map { last[it.id] })
        val k = activeBoundary(env, vm.pausedAtMs!!)
        assertEquals(1, k)
        assertEquals(0, activeBoundary(env, t0 + 60_000L))

        // The replayed id is added on purpose: the cut itself must drop it.
        val activeIds = feedLive.take(k).map { it.id }.toSet() + replayed.id
        val lensAll = filterLogRows(vm.frozen, null, LogScope.All, emptySet())
        val shown = logScopeCut(lensAll, LogScope.Active, emptySet(), activeIds)
        assertEquals(listOf(fresh), vm.exportSnapshot(shown)!!.rows.map { it.detection })

        vm.resume()
        assertNull(vm.pausedAtMs)
    }

    /** The Log tools menu gates. In sample mode Mark Seen is offered (markAllSeen moves the
     *  watermark in memory only there, as iOS does) and Clear Log is absent (it would imply the
     *  retained log is erased); an empty real log disables the menu, so nothing is offered
     *  (clear = true is inert there; the old icon-only clear pill stayed reachable, a deliberate
     *  change); a paused, emptied frozen feed still offers Resume. The old `markSeen = hasRows &&
     *  !demo` fails the first case. */
    @Test
    fun toolsMenuKeepsTheOldChipGates() {
        assertEquals(
            LogToolGates(menu = true, pause = true, select = true, markSeen = true, export = true, clear = false),
            logToolGates(hasRows = true, feedHasRows = true, paused = false, demo = true),
        )
        assertEquals(
            LogToolGates(menu = false, pause = false, select = false, markSeen = false, export = false, clear = true),
            logToolGates(hasRows = false, feedHasRows = false, paused = false, demo = false),
        )
        val pausedEmpty = logToolGates(hasRows = true, feedHasRows = false, paused = true, demo = false)
        assertTrue(pausedEmpty.pause)
        assertTrue(pausedEmpty.menu)
    }
    /** The footer and the export header name a category filter by the words its chip shows, never
     *  by its internal key: the CAMERA key's chip says NETWORK CAM, so the footer must too, and the
     *  export header says the same words in menu case (LogCategory.menuLabel), "Export Network Cam". Wrong
     *  input: the old call site handed the raw key and drew "1 of 6 retained · CAMERA". TWIN: the
     *  iOS LOG-4 test in DetectionLogLensTests. */
    @Test
    fun theFooterAndExportHeaderNameTheCategoryByItsLabel() {
        assertEquals("NETWORK CAM", logCategoryLabel("CAMERA"))
        assertEquals("1 of 6 retained · NETWORK CAM",
            logLensSummaryText(1, 6, paused = false, category = logCategoryLabel("CAMERA")))
        assertEquals("1 matching detections of 6 retained · NETWORK CAM",
            logLensSummaryDescription(1, 6, paused = false, category = logCategoryLabel("CAMERA")))
        assertEquals("Export Network Cam", logExportMenuHeader("CAMERA"))
        assertEquals("Export Drone", logExportMenuHeader("DRONE"))
        assertEquals("Export", logExportMenuHeader(null))
        // a deep-linked key the menu does not list keeps its key, as its chip does
        assertEquals("SOMETHING", logCategoryLabel("SOMETHING"))
        assertNull(logCategoryLabel(null))
    }

    /** "Clear Filters" appears only while a filter is on; an empty segment with no filter on offers
     *  "Show All", and a segment is never called a filter. Wrong input: the old panel drew Clear
     *  Filters for an empty New segment with nothing set. TWIN: the iOS CON-13 test. */
    @Test
    fun clearFiltersOnlyWhenAFilterIsOn() {
        assertEquals(LogNoMatchAction.ShowAll,
            logNoMatchAction(LogScope.New, catFilter = null, query = "", offlineOnly = false))
        assertEquals(LogNoMatchAction.ShowAll,
            logNoMatchAction(LogScope.Active, catFilter = null, query = "  ", offlineOnly = false))
        assertEquals(LogNoMatchAction.ClearFilters,
            logNoMatchAction(LogScope.New, catFilter = "ALPR", query = "", offlineOnly = false))
        assertEquals(LogNoMatchAction.ClearFilters,
            logNoMatchAction(LogScope.All, catFilter = null, query = "axon", offlineOnly = false))
        assertEquals(LogNoMatchAction.ClearFilters,
            logNoMatchAction(LogScope.Active, catFilter = null, query = "", offlineOnly = true))
        assertNull(logNoMatchAction(LogScope.All, catFilter = null, query = "", offlineOnly = false))
    }
}
