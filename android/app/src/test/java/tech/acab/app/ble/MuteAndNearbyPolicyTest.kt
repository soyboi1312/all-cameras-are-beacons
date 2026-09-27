package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.bodyCamSignature

class MuteAndNearbyPolicyTest {
    private val base = IgnoredDevice(mac = "aa:bb:cc:dd:ee:ff", label = "camera")

    @Test
    fun onlyUnscopedMutesAreBoardBacked() {
        assertTrue(isBoardBackedMute(base))
        assertFalse(isBoardBackedMute(base.copy(expiresAt = 10_000L)))
        assertFalse(isBoardBackedMute(base.copy(latitude = 1.0, longitude = 2.0)))
        // A partially decoded/corrupt location rule must fail closed instead of becoming permanent.
        assertFalse(isBoardBackedMute(base.copy(latitude = 1.0)))
    }

    @Test
    fun nearbyWindowMatchesStatusBoundary() {
        val now = 1_000_000L
        assertTrue(lastSeenIsNearby(now, now))
        assertTrue(lastSeenIsNearby(now - ACTIVE_NEARBY_WINDOW_MS, now))
        assertFalse(lastSeenIsNearby(now - ACTIVE_NEARBY_WINDOW_MS - 1, now))
        assertFalse(lastSeenIsNearby(now + 1, now))
        assertFalse(lastSeenIsNearby(null, now))
    }

    /** The Log's Active cut: a binary search over newest-first stamps made non-increasing by
     *  newestFirstEnvelope. `now` is a real epoch-ms value because the envelope's 0L sentinel is
     *  stale only against an epoch clock. Fails if the boundary uses `>=` (fixture (a) gives 2),
     *  if the envelope skips its running minimum (fixture (b) gives 5), or if the sentinel is
     *  Long.MIN_VALUE (the subtraction wraps, the sentinel reads fresh, fixture (b) gives 5).
     *  TWIN: iOS MuteAndNearbyPolicyTests.testActiveBoundaryIsABinarySearchOverNewestFirstStamps,
     *  same fixtures. */
    @Test
    fun activeBoundaryIsABinarySearchOverNewestFirstStamps() {
        val now = 1_758_700_000_000L
        // (a) the one-sided rule: a stamp exactly 45 s old is still active, 46 s is not.
        val a = newestFirstEnvelope(listOf(now, now - 10_000L, now - 45_000L, now - 46_000L))
        assertEquals(3, activeBoundary(a, now))
        // (b) a missing stamp: it and every row after it drop out of the Active prefix.
        val b = newestFirstEnvelope(listOf(now, null, now - 10_000L, now - 20_000L, now - 30_000L))
        assertEquals(listOf(now, 0L, 0L, 0L, 0L), b.toList())
        assertEquals(1, activeBoundary(b, now))
        // The edges: nothing stale and everything stale.
        assertEquals(2, activeBoundary(newestFirstEnvelope(listOf(now, now)), now))
        assertEquals(0, activeBoundary(newestFirstEnvelope(listOf(null, now)), now))
        assertEquals(0, activeBoundary(LongArray(0), now))
    }

    @Test
    fun placeMuteRequiresFreshFixAndDistinguishesOutside() {
        val here = base.copy(latitude = 37.0, longitude = -122.0, radiusMeters = 50.0)
        val accurate = MutePosition(37.0 to -122.0, horizontalAccuracyMeters = 5.0)
        assertEquals(
            MuteRuleStatus.CURRENT_LOCATION_REQUIRED,
            evaluateMuteRule(here, 1_000L, null) { _, _ -> error("distance must not run") },
        )
        assertEquals(
            MuteRuleStatus.ACTIVE,
            evaluateMuteRule(here, 1_000L, accurate) { _, _ -> 49.9 },
        )
        assertEquals(
            MuteRuleStatus.OUTSIDE_RADIUS,
            evaluateMuteRule(here, 1_000L, accurate) { _, _ -> 50.1 },
        )
        assertEquals(
            MuteRuleStatus.INVALID_PLACE,
            evaluateMuteRule(base.copy(latitude = 37.0), 1_000L, accurate) { _, _ -> 0.0 },
        )
    }

    @Test
    fun hereMuteRequiresAccuracyNoWiderThanItsRuleRadius() {
        val coord = 37.0 to -122.0
        assertTrue(positionSupportsHere(MutePosition(coord, 50.0), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, 50.001), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, -1.0), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, Double.POSITIVE_INFINITY), 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, null), radiusMeters = 50.0))

        val rule = base.copy(latitude = coord.first, longitude = coord.second, radiusMeters = 50.0)
        assertEquals(
            MuteRuleStatus.CURRENT_LOCATION_REQUIRED,
            evaluateMuteRule(rule, 1_000L, MutePosition(coord, 50.001)) { _, _ ->
                error("distance must not run for an imprecise fix")
            },
        )
    }

    @Test
    fun historicalWatchedTypeDoesNotBypassCurrentMute() {
        val mac = base.mac
        assertFalse(activeProjectionIncludes(
            mac, isCurrentlyWatched = false, activeIgnoredMacs = setOf(mac)))
        assertTrue(activeProjectionIncludes(
            mac, isCurrentlyWatched = true, activeIgnoredMacs = setOf(mac)))
        assertTrue(activeProjectionIncludes(
            mac, isCurrentlyWatched = false, activeIgnoredMacs = emptySet()))
    }

    @Test
    fun boardOnlyMuteCountDisclosesOnlyTheUnrepresentedRemainder() {
        assertEquals(4, unrepresentedBoardRuleCount(boardCount = 4, localBoardBackedCount = 0))
        assertEquals(2, unrepresentedBoardRuleCount(boardCount = 4, localBoardBackedCount = 2))
        assertEquals(0, unrepresentedBoardRuleCount(boardCount = 1, localBoardBackedCount = 2))
    }

    @Test
    fun sampleModeCannotMutateThePersistedLogOrSeenWatermark() {
        assertFalse(persistedLogMutationAllowed(demoMode = true))
        assertTrue(persistedLogMutationAllowed(demoMode = false))
    }

    /** U1-a: sample data opens with New = the rows the seed flags `"new": true`, on both apps.
     *  The (mac, flaggedNew) table is literal so a seed edit that drops or adds a flag goes red
     *  here; the New set is computed the way the Log computes it (first > watermark). Wrong
     *  inputs, each red: a watermark AT the seed time with no unflagged offset (New = 0), or
     *  ignoring the flag (every row first seen at the seed time, New = 6). TWIN: iOS
     *  MuteAndNearbyPolicyTests.sampleBaselineMakesTheFlaggedRowsNew. */
    @Test
    fun sampleBaselineMakesTheFlaggedRowsNew() {
        val rows = DEMO_SAMPLE_ROWS.map { Detection.fromJson(JSONObject(it)) }
        assertEquals(
            listOf(
                "AC:AB:00:7F:2A:10" to true,
                "DA:7E:E0:44:21:09" to true,
                "00:25:DF:BA:7C:33" to false,
                "4C:00:12:19:AA:BB" to false,
                "1A:2B:3C:4D:5E:6F" to true,
                "44:19:B6:22:0A:5C" to true,
            ),
            rows.map { it.mac to it.isNew },
        )
        val seededAt = 1_790_000_000_000L
        val watermark = sampleSeenWatermarkMs(seededAt)
        val newMacs = rows.filter { sampleFirstSeenMs(it.isNew, seededAt) > watermark }.map { it.mac }
        assertEquals(
            listOf("AC:AB:00:7F:2A:10", "DA:7E:E0:44:21:09", "1A:2B:3C:4D:5E:6F", "44:19:B6:22:0A:5C"),
            newMacs,
        )
        // Every stamp stays on the live axis, above the buffered-record pseudo axis.
        assertTrue(rows.all { sampleFirstSeenMs(it.isNew, seededAt) > AcabBleManager.HIST_PSEUDO_BASE })
    }

    /** U3-f seed fidelity: the sample body cam row is the firmware's Axon OUI-only arm, so its
     *  signature detail resolves and the dossier never calls this live row an offline-buffer
     *  replay. Wrong input: a seed row without `det` (bodyCamSigDetail null). */
    @Test
    fun sampleBodyCamRowCarriesAWireRealSignatureAndIsLive() {
        val bodyCam = DEMO_SAMPLE_ROWS.map { Detection.fromJson(JSONObject(it)) }
            .single { it.type == DeviceType.BODY_CAM }
        assertNotNull(bodyCam.bodyCamSignature)
        assertEquals("Axon OUI", bodyCam.detail)
        assertFalse(bodyCam.hist)
        assertFalse(bodyCam.offline)
    }

    @Test
    fun emptyPhoneNeverErasesUnknownBoardWithoutExplicitClear() {
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(0, 4, false))
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(0, null, false))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, 4, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, null, true))
        assertEquals(BoardIgnoreSyncAction.ACK_CLEAR, boardIgnoreSyncAction(0, 0, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_LIST, boardIgnoreSyncAction(2, 4, false))
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(2, 2, false))
    }

    @Test
    fun pendingClearRetriesUntilBoardStatusAcknowledgesZero() {
        // The policy is shared by ignore and watch lists: a nonzero/unknown count means the
        // destructive clear must be retried, while zero is the only acknowledgement.
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, 1, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, null, true))
        assertEquals(BoardIgnoreSyncAction.ACK_CLEAR, boardIgnoreSyncAction(0, 0, true))
    }

    @Test
    fun sampleManagedEditsNeverPersist() {
        assertFalse(managedListPersistenceAllowed(demoMode = true))
        assertTrue(managedListPersistenceAllowed(demoMode = false))
    }

    @Test
    fun exactMacIndexNormalizesOnceForConstantTimeIngestLookup() {
        val rules = (0 until 256).map { i ->
            IgnoredDevice(
                mac = "AA:BB:CC:DD:${(i / 256).toString(16).padStart(2, '0')}:" +
                    (i % 256).toString(16).padStart(2, '0'),
                label = "rule $i",
            )
        }
        val index = indexIgnoredDevices(rules)
        assertEquals(256, index.size)
        assertEquals("rule 255", index["aa:bb:cc:dd:00:ff"]?.label)
    }
}
