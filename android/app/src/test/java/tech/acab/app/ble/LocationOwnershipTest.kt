package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis

class LocationOwnershipTest {

    @Test
    fun visibleReadyLinkOwnsLocationOnlyWithPermission() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(false, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.CONNECTING, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, false))
    }

    @Test
    fun backgroundDriveRequiresActualForegroundService() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.CONNECTING, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, true, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, true))
        assertFalse(shouldOwnLocation(false, ConnState.READY, false, true, true))
    }

    @Test
    fun foregroundReadyAndDriveAreIndependentReasons() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, true, false))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, true, false, false))
    }

    @Test
    fun demoReadyAndExitUseTheSameOwnershipTransitionsAsARealLink() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, true, false, false))
    }

    @Test
    fun backgroundCallbacksCannotOwnLocationWithoutDriveService() {
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, true, false))
        assertTrue(shouldOwnLocation(true, ConnState.READY, false, true, true))
    }

    @Test
    fun strongestPinChoosesOnlyStrictlyStrongerLocatedSamples() {
        val first = selectStrongestLocatedSample(null, 32.7 to -117.1, -80)!!
        assertEquals(32.7 to -117.1, first.coord)

        // Equal and weaker samples keep the exact earlier pair, avoiding map-pin jitter.
        assertSame(first, selectStrongestLocatedSample(first, 32.8 to -117.2, -80))
        assertSame(first, selectStrongestLocatedSample(first, 32.9 to -117.3, -90))

        val stronger = selectStrongestLocatedSample(first, 33.0 to -117.4, -60)!!
        assertEquals(33.0 to -117.4, stronger.coord)
        assertEquals(-60, stronger.rssi)
    }

    /**
     * A replayed capture-era fix is parked at [STALE_FIX_PIN_RSSI] so it can supply a pin when
     * nothing better exists and STILL lose to any real sighting. Both halves are asserted through
     * the pure functions the manager's private routines call: the FILL half through
     * [staleLocatedPinFill] (what considerStaleLocatedSample writes), the RANKING half through
     * [selectStrongestLocatedSample] (what considerLocatedSample calls with the parked floor as
     * its current sample). A floor that outranked a live fix would leave a camera pinned where the
     * phone once stood; a floor that could not fill an empty pin would drop the only position an
     * offline capture has; a fill that overwrote a won pin would move a camera to the phone's old
     * position. Deleting the `existing != null` guard in staleLocatedPinFill fails the third
     * block; raising STALE_FIX_PIN_RSSI to -127 or above fails the second.
     * TWIN: iOS `testStaleFixPinFloorYieldsToAnyRealSighting` in MuteAndNearbyPolicyTests.swift.
     */
    @Test
    fun staleFixPinYieldsToAnyRealSighting() {
        // Fills an empty pin at the floor: an offline-only device still maps.
        val parked = staleLocatedPinFill(existing = null, candidate = 32.7 to -117.1)!!
        assertEquals(32.7 to -117.1, parked.coord)
        assertEquals(STALE_FIX_PIN_RSSI, parked.rssi)
        // ...but never an unmappable one, the same refusal selectStrongestLocatedSample makes.
        assertNull(staleLocatedPinFill(existing = null, candidate = 0.0 to 0.0))
        assertNull(staleLocatedPinFill(existing = null, candidate = 91.0 to 0.0))

        // Loses to the weakest real reading, so a live sighting takes the pin back.
        val real = selectStrongestLocatedSample(parked, 33.0 to -117.4, -127)!!
        assertEquals(33.0 to -117.4, real.coord)
        assertEquals(-127, real.rssi)
        assertTrue(STALE_FIX_PIN_RSSI < -127)

        // And never the other way round: a won pin, ranked or floor, is not overwritten by a
        // later stale replay in either contest.
        assertSame(real, selectStrongestLocatedSample(real, 32.7 to -117.1, STALE_FIX_PIN_RSSI))
        assertNull(staleLocatedPinFill(existing = real.coord, candidate = 32.7 to -117.1))
        assertNull(staleLocatedPinFill(existing = parked.coord, candidate = 33.0 to -117.4))
    }

    /**
     * The replay routing that IS the stale-pin fix, pinned on the pure decision fileHistory
     * switches on: a missing or in-window `gage` enters the ranked contest, a stale or malformed
     * one the floor. Swapping the two arms of [replayPinContest], or widening its window past
     * [FIX_MAX_AGE_SEC], fails here; the same edge is pinned on liveWireCoordinateIsFresh above,
     * so the two cannot disagree about which fixes are current.
     * TWIN: iOS `testReplayPinContestSplitsOnTheLiveFreshnessWindow` in
     * MuteAndNearbyPolicyTests.swift, same five inputs, same answers.
     */
    @Test
    fun replayPinContestSplitsOnTheLiveFreshnessWindow() {
        assertEquals(ReplayPinContest.RANKED, replayPinContest(null)) // legacy / sub-second form
        assertEquals(ReplayPinContest.RANKED, replayPinContest(0))
        assertEquals(ReplayPinContest.RANKED, replayPinContest(120))
        assertEquals(ReplayPinContest.FLOOR, replayPinContest(121))
        assertEquals(ReplayPinContest.FLOOR, replayPinContest(-1))
    }

    /**
     * The checkpoint load writes exactly what [checkpointObserverPin] returns, so these tests pin
     * the restore itself. This helper calls it at a fixed row RSSI of -60, with no saved pair and
     * no pin held unless a test passes one.
     */
    private fun checkpointPin(
        type: DeviceType = DeviceType.TRACKER,
        pair: Pair<Double, Double>? = null,
        peak: Int? = null,
        wire: Pair<Double, Double>?,
        gpsAgeSec: Int? = null,
        replayed: Boolean,
        held: LocatedPinSample? = null,
    ): LocatedPinSample? = checkpointObserverPin(
        type, pair?.first, pair?.second, peak, wire?.first, wire?.second, -60, gpsAgeSec,
        replayed, held?.coord, held?.rssi,
    )

    /**
     * A LIVE row checkpointed without a pin, whose wire fix was already stale (`gage` past the
     * 120 s window) or malformed, seeds NOTHING on reload: the ingest refused that fix and the map
     * gate refuses it, so the session drew no pin, and restoring one would pin the device at the
     * phone's old position. Deleting the `replayed` guard fails this test with a floor pin.
     * TWIN: iOS `testCheckpointLiveRowWithAStaleFixSeedsNothing` in MapPinRulesTests.swift.
     */
    @Test
    fun aCheckpointLiveRowWithAStaleFixSeedsNothing() {
        for (age in listOf(121, -1)) {
            assertNull("age $age",
                checkpointPin(wire = 32.7 to -117.1, gpsAgeSec = age, replayed = false))
        }
    }

    /**
     * A REPLAYED row checkpointed without a pin, whose fix was already stale at capture, keeps its
     * coordinate only as a floor pin, as the replay ingest does: it parks at the stale-pin floor,
     * a later located sighting at -127 takes it back, and it never overwrites a pin already held.
     * Routing the stale age through the ranked arm fails the floor, displacement and held-pin
     * assertions (the pin would sit at -60, above a -127 sighting); dropping the empty-pin guard
     * from the stale fill fails the two held-pin assertions.
     * TWIN: iOS `testCheckpointReplayedRowWithAStaleFixSeedsOnlyTheFloorPin`.
     */
    @Test
    fun aCheckpointReplayedRowWithAStaleFixSeedsOnlyTheFloorPin() {
        val wire = 32.7 to -117.1
        for (age in listOf(121, -1)) {
            val parked = checkpointPin(wire = wire, gpsAgeSec = age, replayed = true)
            assertEquals("age $age", wire, parked?.coord)
            assertEquals("age $age", STALE_FIX_PIN_RSSI, parked?.rssi)
            val real = selectStrongestLocatedSample(parked, 33.0 to -117.4, -127)
            assertEquals("age $age", LocatedPinSample(33.0 to -117.4, -127), real)
        }
        val held = 33.0 to -117.4
        assertNull("a ranked pin holds", checkpointPin(
            wire = wire, gpsAgeSec = 121, replayed = true, held = LocatedPinSample(held, -127)))
        assertNull("a floor pin holds", checkpointPin(
            wire = wire, gpsAgeSec = 121, replayed = true,
            held = LocatedPinSample(held, STALE_FIX_PIN_RSSI)))
    }

    /**
     * A missing `gage` (the legacy / sub-second encoding) or one inside the window ranks the wire
     * coordinate on the row's own RSSI, for a live and a replayed row alike, as both ingest paths
     * do. It competes like any located sample: a stronger pin already held for the id holds, and
     * a weaker one is replaced. Narrowing the window below 120 fails the 120 rows here; widening
     * it fails the 121 rows of the two stale tests above.
     * TWIN: iOS `testCheckpointRowWithACurrentOrMissingFixRanksOnItsOwnRSSI`.
     */
    @Test
    fun aCheckpointRowWithACurrentOrMissingFixRanksOnItsOwnRssi() {
        val wire = 32.7 to -117.1
        for (replayed in listOf(false, true)) {
            for (age in listOf(null, 0, 120)) {
                assertEquals("replayed $replayed, age $age", LocatedPinSample(wire, -60),
                    checkpointPin(wire = wire, gpsAgeSec = age, replayed = replayed))
            }
        }
        val held = 33.0 to -117.4
        assertNull("a stronger pin holds",
            checkpointPin(wire = wire, replayed = false, held = LocatedPinSample(held, -50)))
        assertEquals("a weaker pin is replaced", LocatedPinSample(wire, -60),
            checkpointPin(wire = wire, replayed = false, held = LocatedPinSample(held, -70)))
    }

    /**
     * A drone's wire coordinate is the aircraft, never the observer, and a row with no coordinate
     * has nothing to seed, whatever its age or replay flag says. The drone refusal guards only the
     * wire arm; a drone's saved observer pair still restores (the paired test below). Null island
     * is refused here because [validCoord] refuses it.
     * TWIN: iOS `testCheckpointRowNeverSeedsADroneOrAMissingCoordinate` (which has no 0,0 row:
     * `Detection.coordinate` drops 0,0 before the iOS helper can see it).
     */
    @Test
    fun aCheckpointRowNeverSeedsADroneOrAnUnmappableCoordinate() {
        for (replayed in listOf(false, true)) {
            for (age in listOf(null, 121)) {
                assertNull(checkpointPin(type = DeviceType.DRONE, wire = 32.7 to -117.1,
                    gpsAgeSec = age, replayed = replayed))
                assertNull(checkpointPin(wire = null, gpsAgeSec = age, replayed = replayed))
                assertNull(checkpointPin(wire = 0.0 to 0.0, gpsAgeSec = age, replayed = replayed))
            }
        }
    }

    /**
     * A saved pair WITHOUT its peak restores nothing by itself: nothing in it says how it ranked
     * or where it came from, so the row re-runs the wire contest. persistDetections never writes
     * one, but every earlier iOS build did, and the rule is shared. The pair here stands for a
     * stale home fix and differs from the wire coordinate, so trusting the pair at the row RSSI
     * fails every coordinate assertion, the floor assertion and the nil assertion.
     * TWIN: iOS `testCheckpointPairWithoutAPeakReRunsTheWireContest`.
     */
    @Test
    fun aCheckpointPairWithoutAPeakReRunsTheWireContest() {
        val home = 32.7 to -117.15
        val wire = 32.71 to -117.1
        val parked = checkpointPin(pair = home, wire = wire, gpsAgeSec = 121, replayed = true)
        assertEquals("stale replayed row", wire, parked?.coord)
        assertEquals("stale replayed row", STALE_FIX_PIN_RSSI, parked?.rssi)
        assertNull("stale live row",
            checkpointPin(pair = home, wire = wire, gpsAgeSec = 121, replayed = false))
        val ranked = checkpointPin(pair = home, wire = wire, gpsAgeSec = null, replayed = false)
        assertEquals("missing age", wire, ranked?.coord)
        assertEquals("missing age", -60, ranked?.rssi)
    }

    /**
     * A saved pair WITH its peak restores at that peak, whatever the row's own age, replay flag or
     * type says: the peak records the contest the pair was written from (a floor-parked pin
     * carries the floor), and a drone's pair is its observer fix. It still competes, so a stronger
     * pin already held for the id holds. The peak is clamped to the Int16 range on both apps, and
     * a pair at 0,0 or out of range is no pair, so the row takes the wire arm.
     * TWIN: iOS `testCheckpointPairWithAPeakRestoresAtThatPeak`.
     */
    @Test
    fun aCheckpointPairWithAPeakRestoresAtThatPeak() {
        val pair = 32.7 to -117.15
        val wire = 32.71 to -117.1
        for (type in listOf(DeviceType.TRACKER, DeviceType.DRONE)) {
            assertEquals("$type", LocatedPinSample(pair, -55), checkpointPin(
                type = type, pair = pair, peak = -55, wire = wire, gpsAgeSec = 121,
                replayed = false))
        }
        assertEquals("a floor-parked pair keeps its floor", STALE_FIX_PIN_RSSI,
            checkpointPin(pair = pair, peak = STALE_FIX_PIN_RSSI, wire = wire,
                replayed = true)?.rssi)
        assertNull("a stronger pin holds", checkpointPin(
            pair = pair, peak = -55, wire = wire, replayed = false,
            held = LocatedPinSample(wire, -50)))
        assertEquals("the peak is clamped", -32_768,
            checkpointPin(pair = pair, peak = -40_000, wire = null, replayed = false)?.rssi)
        for (bad in listOf(0.0 to 0.0, 91.0 to 0.0)) {
            assertEquals("$bad is no pair", LocatedPinSample(wire, -60),
                checkpointPin(pair = bad, peak = -55, wire = wire, replayed = false))
        }
    }

    @Test
    fun unlocatedOrInvalidSamplesCannotRaiseThePinRssiBar() {
        assertNull(selectStrongestLocatedSample(null, null, -20))
        assertNull(selectStrongestLocatedSample(null, 0.0 to 0.0, -20))

        val located = LocatedPinSample(32.7 to -117.1, -90)
        assertSame(located, selectStrongestLocatedSample(located, null, -10))
        assertSame(located, selectStrongestLocatedSample(located, 91.0 to 0.0, -10))
    }

    @Test
    fun liveWireFallbackUsesTheSameTwoMinuteFreshnessBoundary() {
        assertTrue(liveWireCoordinateIsFresh(null)) // legacy / sub-second wire form
        assertTrue(liveWireCoordinateIsFresh(0))
        assertTrue(liveWireCoordinateIsFresh(120))
        assertFalse(liveWireCoordinateIsFresh(121))
        assertFalse(liveWireCoordinateIsFresh(-1))
    }

    @Test
    fun mapCoordinatePreservesRidAircraftAuthority() {
        val observer = 32.7 to -117.1
        val aircraft = 32.8 to -117.2
        assertEquals(
            aircraft,
            mapCoordinateForDetection(DeviceType.DRONE, aircraft.first, aircraft.second, observer),
        )
        assertEquals(
            observer,
            mapCoordinateForDetection(DeviceType.TRACKER, aircraft.first, aircraft.second, observer),
        )
        assertEquals(
            observer,
            mapCoordinateForDetection(DeviceType.DRONE, null, null, observer),
        )
        assertEquals(
            aircraft,
            mapCoordinateForDetection(DeviceType.TRACKER, aircraft.first, aircraft.second, null),
        )
    }

    /** Mirrors iOS MapPinRulesTests.testNonDroneMapCoordinateCanRejectAStaleLiveWireFallback: the
     *  gate withholds ONLY the non-drone wire fallback, never a retained observer pin and never a
     *  drone's own aircraft fix. Deleting the `allowNonDroneWireFallback &&` term from
     *  mapCoordinateForDetection fails the first assertion. */
    @Test
    fun aStaleLiveWireFallbackIsRefusedWithoutTouchingObserverOrAircraftPins() {
        val observer = 32.7 to -117.1
        val aircraft = 32.8 to -117.2
        assertNull(
            mapCoordinateForDetection(
                DeviceType.TRACKER, aircraft.first, aircraft.second, null,
                allowNonDroneWireFallback = false),
        )
        assertEquals(
            observer,
            mapCoordinateForDetection(
                DeviceType.TRACKER, aircraft.first, aircraft.second, observer,
                allowNonDroneWireFallback = false),
        )
        assertEquals(
            aircraft,
            mapCoordinateForDetection(
                DeviceType.DRONE, aircraft.first, aircraft.second, observer,
                allowNonDroneWireFallback = false),
        )
    }

    /** The gate itself, on the SAME 120 s boundary iOS uses. Offline rows and the sample tour are
     *  always allowed; a live row is allowed only inside the window. */
    @Test
    fun onlyOfflineDemoOrAFreshLiveFixMayFallBackToTheWireCoordinate() {
        assertTrue(mapWireFallbackAllowed(offline = false, demo = false, gpsAgeSec = 120))
        assertFalse(mapWireFallbackAllowed(offline = false, demo = false, gpsAgeSec = 121))
        assertTrue(mapWireFallbackAllowed(offline = true, demo = false, gpsAgeSec = 121))
        assertTrue(mapWireFallbackAllowed(offline = false, demo = true, gpsAgeSec = 121))
        assertTrue(mapWireFallbackAllowed(offline = false, demo = false, gpsAgeSec = null))
    }

    @Test
    fun recentMapRejectsOrderingSlotsButKeepsAFormerReplayRowOnceHeardLive() {
        val now = 1_800_000_000_000L
        assertNull(trustworthyMapLastSeen(
            now - 1_000L, TimeBasis.Bracketed(now - 20_000L, now), rowOffline = true))
        assertNull(trustworthyMapLastSeen(
            now - 1_000L, TimeBasis.Unknown, rowOffline = true))
        assertEquals(now - 1_000L, trustworthyMapLastSeen(
            now - 1_000L, TimeBasis.Reconstructed(now - 1_000L, 3), rowOffline = true))

        // The stored basis describes first-seen. A later live hit owns an exact lastSeen, so the
        // old bracket must not hide the now-live row from Recent.
        assertEquals(now, trustworthyMapLastSeen(
            now, TimeBasis.Bracketed(now - 20_000L, now - 10_000L), rowOffline = false))
        assertNull(trustworthyMapLastSeen(
            AcabBleManager.HIST_PSEUDO_BASE, null, rowOffline = false))
    }
}
