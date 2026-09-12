import XCTest
import CoreLocation
@testable import Beacons

final class MuteAndNearbyPolicyTests: XCTestCase {
    private let base = IgnoredDevice(mac: "aa:bb:cc:dd:ee:ff", label: "camera")

    func testOnlyUnscopedMutesAreBoardBacked() {
        XCTAssertTrue(isBoardBackedMute(base))
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, expiresAt: Date(timeIntervalSince1970: 100))))
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, latitude: 1, longitude: 2, radiusMeters: 50)))
        // A partially decoded/corrupt location rule must fail closed instead of becoming permanent.
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, latitude: 1)))
    }

    func testNearbyWindowMatchesStatusBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(lastSeenIsNearby(now, now: now))
        XCTAssertTrue(lastSeenIsNearby(now.addingTimeInterval(-activeNearbyInterval), now: now))
        XCTAssertFalse(lastSeenIsNearby(
            now.addingTimeInterval(-activeNearbyInterval - 0.001), now: now))
        XCTAssertFalse(lastSeenIsNearby(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(lastSeenIsNearby(nil, now: now))
    }

    func testStatusStalenessTreatsAdjacentFutureTimestampAsFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(lastSeenIsStale(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(lastSeenIsStale(now.addingTimeInterval(-activeNearbyInterval), now: now))
        XCTAssertTrue(lastSeenIsStale(
            now.addingTimeInterval(-activeNearbyInterval - 0.001), now: now))
        XCTAssertTrue(lastSeenIsStale(nil, now: now))
    }

    func testSampleRowsDoNotAgeOutOfLiveActivity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-activeNearbyInterval - 1)
        XCTAssertFalse(liveRowIsNearby(old, now: now, isDemoMode: false))
        XCTAssertTrue(liveRowIsNearby(old, now: now, isDemoMode: true))
    }

    func testHereMuteRequiresCurrentNotCachedLocation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(locationFixIsCurrent(now, now: now))
        XCTAssertTrue(locationFixIsCurrent(
            now.addingTimeInterval(-currentLocationFixMaxAge), now: now))
        XCTAssertFalse(locationFixIsCurrent(
            now.addingTimeInterval(-currentLocationFixMaxAge - 0.001), now: now))
        XCTAssertFalse(locationFixIsCurrent(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(locationFixIsCurrent(nil, now: now))
    }

    func testLiveWireObserverFallbackUsesTheSameFreshnessBoundary() {
        XCTAssertTrue(liveWireObserverFixIsCurrent(gpsAgeSec: nil),
                      "nil is the legacy or sub-second wire shape")
        XCTAssertTrue(liveWireObserverFixIsCurrent(gpsAgeSec: 0))
        XCTAssertTrue(liveWireObserverFixIsCurrent(gpsAgeSec: 120))
        XCTAssertFalse(liveWireObserverFixIsCurrent(gpsAgeSec: 121))
        XCTAssertFalse(liveWireObserverFixIsCurrent(gpsAgeSec: -1))
    }

    func testHereMuteRequiresAccuracyWithinItsFiftyMeterRadius() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(locationFixSupportsHere(now, horizontalAccuracy: 50, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: 50.001, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: -1, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: .infinity, now: now))
        XCTAssertFalse(locationFixSupportsHere(
            now.addingTimeInterval(-currentLocationFixMaxAge - 1),
            horizontalAccuracy: 5, now: now))
    }

    func testBoardListReconcilesFailedNonemptyWritesWithoutAuthorizingEmptyPhone() {
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: 1, clearPending: false), .pushList)
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: 2, clearPending: false), .none)
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: nil, clearPending: false), .pushList)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 3, clearPending: false), .none)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 3, clearPending: true), .pushClear)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 0, clearPending: true), .acknowledgeClear)
    }

    func testBoardOnlyMuteCountIsVisibleWithoutInventingIdentities() {
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 4, localBoardBackedCount: 0), 4)
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 4, localBoardBackedCount: 2), 2)
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 1, localBoardBackedCount: 2), 0)
    }

    func testHistoricalWatchedTypeDoesNotBypassCurrentMute() {
        let mac = "aa:bb:cc:dd:ee:ff"
        XCTAssertFalse(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: false, activeIgnoredMacs: [mac]))
        XCTAssertTrue(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: true, activeIgnoredMacs: [mac]))
        XCTAssertTrue(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: false, activeIgnoredMacs: []))
    }

    func testWatchedFilterIncludesCurrentStarsWithoutReplacingUnderlyingType() {
        XCTAssertTrue(detectionMatchesCategory(
            type: .tracker, category: "WATCHED", isCurrentlyWatched: true))
        XCTAssertTrue(detectionMatchesCategory(
            type: .networkCamera, category: "WATCHED", isCurrentlyWatched: true))
        XCTAssertTrue(detectionMatchesCategory(
            type: .watched, category: "WATCHED", isCurrentlyWatched: false),
            "capture-time watched rows remain historical members")
        XCTAssertFalse(detectionMatchesCategory(
            type: .tracker, category: "WATCHED", isCurrentlyWatched: false))
        XCTAssertTrue(detectionMatchesCategory(
            type: .tracker, category: "TRACKER", isCurrentlyWatched: true),
            "a star must not erase the underlying category")
    }

    func testStrongestLocatedSampleRequiresStrictlyStrongerRawRSSI() {
        XCTAssertTrue(strongestLocatedSampleShouldReplace(bestRSSI: nil, candidateRSSI: -90))
        XCTAssertTrue(strongestLocatedSampleShouldReplace(bestRSSI: -90, candidateRSSI: -89))
        XCTAssertFalse(strongestLocatedSampleShouldReplace(bestRSSI: -90, candidateRSSI: -90))
        XCTAssertFalse(strongestLocatedSampleShouldReplace(bestRSSI: -90, candidateRSSI: -91))
    }

    /// A replayed capture-era fix is parked at `staleFixPinRSSI` so it can supply a pin when nothing
    /// better exists and STILL lose to any real sighting. Both halves are asserted through the pure
    /// functions the manager's private routines call: the FILL half through `staleObserverPinFill`
    /// (what considerStaleObserverPin writes), the RANKING half through
    /// `strongestLocatedSampleShouldReplace` (what considerObserverPin calls with the parked floor
    /// as its baseline). A floor that outranked a live fix would leave a camera pinned where the
    /// phone once stood; a floor that could not fill an empty pin would drop the only position an
    /// offline capture has; a fill that overwrote a won pin would move a camera to the phone's old
    /// position. Deleting the `existingCoordinate == nil` guard in staleObserverPinFill fails the
    /// last block; raising staleFixPinRSSI to -127 or above fails the ranking block.
    /// TWIN: Android `staleFixPinYieldsToAnyRealSighting` in LocationOwnershipTest.kt.
    func testStaleFixPinFloorYieldsToAnyRealSighting() {
        let capture = CLLocationCoordinate2D(latitude: 32.7, longitude: -117.1)
        let live = CLLocationCoordinate2D(latitude: 33.0, longitude: -117.4)

        // Fills an empty pin at the floor: an offline-only device still maps...
        let parked = staleObserverPinFill(existingCoordinate: nil, candidate: capture)
        XCTAssertEqual(parked?.coordinate.latitude, capture.latitude)
        XCTAssertEqual(parked?.coordinate.longitude, capture.longitude)
        XCTAssertEqual(parked?.rssi, staleFixPinRSSI)
        // ...but never an unmappable one, the same refusal considerObserverPin makes.
        XCTAssertNil(staleObserverPinFill(
            existingCoordinate: nil, candidate: CLLocationCoordinate2D(latitude: 91, longitude: 0)))

        // Loses to the weakest real reading, so a live sighting takes the pin back.
        XCTAssertTrue(strongestLocatedSampleShouldReplace(
            bestRSSI: staleFixPinRSSI, candidateRSSI: -127),
            "even the weakest real reading must take the pin back from a stale capture-era fix")
        XCTAssertTrue(strongestLocatedSampleShouldReplace(
            bestRSSI: staleFixPinRSSI, candidateRSSI: -99))
        XCTAssertLessThan(staleFixPinRSSI, -127,
            "the floor has to sit below every representable BLE reading to rank last")

        // And never the other way round: a won pin, ranked or floor, is not overwritten by a
        // later stale replay in either contest.
        XCTAssertFalse(strongestLocatedSampleShouldReplace(
            bestRSSI: -99, candidateRSSI: staleFixPinRSSI),
            "a stale fix must never displace a pin a real sighting already won")
        XCTAssertNil(staleObserverPinFill(existingCoordinate: live, candidate: capture))
        XCTAssertNil(staleObserverPinFill(existingCoordinate: capture, candidate: live))
    }

    /// The replay routing that IS the stale-pin fix, pinned on the pure decision ingestHistory
    /// switches on: a missing or in-window `gage` enters the ranked contest, a stale or malformed
    /// one the floor. Swapping the two arms of `replayPinContest`, or widening its window past
    /// `currentLocationFixMaxAge`, fails here; the same edge is pinned on
    /// liveWireObserverFixIsCurrent above, so the two cannot disagree about which fixes are current.
    /// TWIN: Android `replayPinContestSplitsOnTheLiveFreshnessWindow` in LocationOwnershipTest.kt,
    /// same five inputs, same answers.
    func testReplayPinContestSplitsOnTheLiveFreshnessWindow() {
        XCTAssertEqual(replayPinContest(gpsAgeSec: nil), .ranked, "legacy or sub-second wire shape")
        XCTAssertEqual(replayPinContest(gpsAgeSec: 0), .ranked)
        XCTAssertEqual(replayPinContest(gpsAgeSec: 120), .ranked)
        XCTAssertEqual(replayPinContest(gpsAgeSec: 121), .floor)
        XCTAssertEqual(replayPinContest(gpsAgeSec: -1), .floor)
    }

    func testLiveModeRequiresReadySessionAndLocationAndRejectsSampleData() {
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: false, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: true, isDemoMode: false, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: false, locationAuthorized: true))
        XCTAssertTrue(liveModeCanRun(
            hasReadySession: true, isDemoMode: false, locationAuthorized: true))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: true, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: true, isDemoMode: true, locationAuthorized: true))
    }

    func testSamplePhoneSettingsMutateOnlyThePreviewValue() {
        let real = SamplePhoneSettings(
            liveModeWanted: true, redactLockScreen: true, notificationTypes: [1, 3])
        var preview = real
        preview.liveModeWanted = false
        preview.redactLockScreen = false
        preview.setNotification(false, rawValue: 1)
        preview.setNotification(true, rawValue: 9)

        XCTAssertTrue(real.liveModeWanted)
        XCTAssertTrue(real.redactLockScreen)
        XCTAssertEqual(real.notificationTypes, [1, 3])
        XCTAssertFalse(preview.liveModeWanted)
        XCTAssertFalse(preview.redactLockScreen)
        XCTAssertFalse(preview.notificationEnabled(1))
        XCTAssertTrue(preview.notificationEnabled(9))
    }

    func testSampleLogMutationsCannotReachPersistentEvidenceState() {
        XCTAssertEqual(detectionLogClearAction(isDemoMode: true), .sampleMemoryOnly)
        XCTAssertEqual(detectionLogClearAction(isDemoMode: false), .memoryAndDisk)
        XCTAssertFalse(seenWatermarkWritesAllowed(isDemoMode: true))
        XCTAssertTrue(seenWatermarkWritesAllowed(isDemoMode: false))
    }

    func testDemoTourIsOptInForVisualFixtureLaunches() {
        XCTAssertTrue(shouldPresentSampleTour(isDemoMode: true, tourRequested: true))
        XCTAssertFalse(shouldPresentSampleTour(isDemoMode: true, tourRequested: false))
        XCTAssertFalse(shouldPresentSampleTour(isDemoMode: false, tourRequested: true))
    }

    func testManagedListWritesArePreviewOnlyInSampleMode() {
        XCTAssertTrue(managedListWritesAllowed(isDemoMode: false))
        XCTAssertFalse(managedListWritesAllowed(isDemoMode: true))
    }

    func testLiveModeCategoryFallbackDistinguishesUnknownFromAllOff() {
        let unknownStatus = effectiveLiveModeCategories(nil)
        XCTAssertEqual(unknownStatus, Set([
            WidgetCategory.alpr.rawValue, WidgetCategory.drone.rawValue,
            WidgetCategory.body.rawValue, WidgetCategory.tracker.rawValue,
            WidgetCategory.glasses.rawValue,
        ]))
        XCTAssertTrue(effectiveLiveModeCategories([]).isEmpty)
        XCTAssertEqual(effectiveLiveModeCategories([WidgetCategory.camera.rawValue]),
                       Set([WidgetCategory.camera.rawValue]))
    }
}
