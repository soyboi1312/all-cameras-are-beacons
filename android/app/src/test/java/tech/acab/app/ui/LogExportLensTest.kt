package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.DetectionExportRowSnapshot
import tech.acab.app.ble.DetectionExportSnapshot
import tech.acab.app.ble.frozenNewIdSet
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceNames
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis

class LogExportLensTest {
    private fun row(
        mac: String,
        type: DeviceType,
        offline: Boolean = false,
        rssi: Int = -50,
        name: String? = null,
        rid: String? = null,
        detail: String? = null,
    ) = Detection(
        type = type,
        source = 0,
        method = 0,
        confidence = 1,
        mac = mac,
        rssi = rssi,
        name = name,
        rid = rid,
        detail = detail,
        lat = null,
        lon = null,
        pilotLat = null,
        pilotLon = null,
        altitude = null,
        speedH = null,
        speedV = null,
        heading = null,
        heightAGL = null,
        pilotAlt = null,
        ridStatus = null,
        count = 1,
        isNew = true,
        gpsAgeSec = null,
        hist = offline,
        seq = 0L,
        at = 0L,
        approx = false,
        offline = offline,
    )

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
            filterLogRows(live, "TRACKER", LogScope.Offline, emptySet()),
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

    /** The lens-summary line under the search field names the list it counted, the FROZEN one
     *  while paused, and carries the category: the header kicker counts the live store the way
     *  the NEW tally does, so this line is where "5 of 5 paused" beside "200 NEW" says nothing
     *  was lost. Byte-identical to iOS `logLensSummary` in DetectionsView.swift, text and spoken
     *  form; a changed word here is a changed word there. */
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
}
