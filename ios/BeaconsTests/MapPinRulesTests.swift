import XCTest
import CoreLocation
import MapKit
@testable import Beacons

/// The two rules behind what a map pin stands for and how old it is allowed to look.
///
/// WHY THIS HAS A TEST. Both rules fail silently. A grouping tolerance that drifts either merges
/// two genuinely different poles into one pin or leaves a body camera buried under the sighting
/// drawn on top of it, and neither shows up in a screenshot. An age boundary that drifts makes
/// yesterday's persisted pin pulse like a live alert, which is the single most misleading thing
/// this map can do.
///
/// EXACTLY WHAT IS SHARED WITH ANDROID: the tolerance, the priority order, the most-recent
/// tie-break, the three age boundaries, and "a missing stamp is RECENT, never FRESH". The Android
/// suite asserts the same rules against its own implementation.
///
/// WHAT IS NOT SHARED: artwork, and how each platform gets to the answer. The badge and the
/// dimmed marker are drawn per platform off each platform's own pin, so the numbers behind them
/// are each side's own and must not be matched up. `MapPinRules.lead` is likewise iOS's own: it
/// exists because the iOS map resolves a group's winner on every publish, and it is asserted
/// below against `ordered` on this platform, never against anything Android does.
final class MapPinRulesTests: XCTestCase {

    // MARK: - Fixtures

    /// A stand-in for a stored row. The rules take the two fields they actually use through
    /// closures, so nothing here needs a Detection, a store, or CoreBluetooth.
    private struct Row {
        let tag: String
        let type: DeviceType
        let seen: Date?
    }

    private func ordered(_ rows: [Row]) -> [String] {
        MapPinRules.ordered(rows, type: { $0.type }, lastSeen: { $0.seen }).map(\.tag)
    }

    private func lead(_ rows: [Row]) -> String? {
        MapPinRules.lead(rows, type: { $0.type }, lastSeen: { $0.seen })?.tag
    }

    /// San Diego, the app's own fallback region centre.
    private let base = CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)

    private func offset(lat: Double = 0, lon: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + lat, longitude: base.longitude + lon)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ secs: TimeInterval) -> Date { now.addingTimeInterval(-secs) }

    private func wrappedLongitudeDistance(_ a: Double, _ b: Double) -> Double {
        let direct = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(direct, 360 - direct)
    }

    private func assert(_ coordinate: CLLocationCoordinate2D,
                        isInside region: MKCoordinateRegion,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(coordinate.latitude - region.center.latitude),
                                 region.span.latitudeDelta / 2 + 1e-9,
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(wrappedLongitudeDistance(
            coordinate.longitude, region.center.longitude),
            region.span.longitudeDelta / 2 + 1e-9,
            file: file, line: line)
    }

    // MARK: - Subject vs observer coordinate

    func testNonDroneMapCoordinatePrefersStrongestObserverSighting() {
        let latestWire = offset(lat: 0.01)
        let strongestObserver = offset(lon: 0.02)
        let resolved = resolvedDetectionMapCoordinate(
            type: .tracker, wireCoordinate: latestWire,
            strongestObserverCoordinate: strongestObserver)
        XCTAssertEqual(resolved?.latitude, strongestObserver.latitude)
        XCTAssertEqual(resolved?.longitude, strongestObserver.longitude)
    }

    func testRemoteIDMapCoordinatePreservesAircraftPosition() {
        let aircraft = offset(lat: 0.01)
        let observer = offset(lon: 0.02)
        let resolved = resolvedDetectionMapCoordinate(
            type: .drone, wireCoordinate: aircraft,
            strongestObserverCoordinate: observer)
        XCTAssertEqual(resolved?.latitude, aircraft.latitude)
        XCTAssertEqual(resolved?.longitude, aircraft.longitude)
    }

    func testPositionlessDroneFallsBackToStrongestObserverSighting() {
        let observer = offset(lon: 0.02)
        let resolved = resolvedDetectionMapCoordinate(
            type: .drone, wireCoordinate: nil,
            strongestObserverCoordinate: observer)
        XCTAssertEqual(resolved?.latitude, observer.latitude)
        XCTAssertEqual(resolved?.longitude, observer.longitude)
    }

    func testNonDroneMapCoordinateCanRejectAStaleLiveWireFallback() {
        let staleWire = offset(lat: 0.01)
        XCTAssertNil(resolvedDetectionMapCoordinate(
            type: .tracker, wireCoordinate: staleWire,
            strongestObserverCoordinate: nil,
            allowNonDroneWireFallback: false))

        let strongestObserver = offset(lon: 0.02)
        let resolved = resolvedDetectionMapCoordinate(
            type: .tracker, wireCoordinate: staleWire,
            strongestObserverCoordinate: strongestObserver,
            allowNonDroneWireFallback: false)
        XCTAssertEqual(resolved?.latitude, strongestObserver.latitude)
        XCTAssertEqual(resolved?.longitude, strongestObserver.longitude)
    }

    // MARK: - Checkpoint restore

    /// BLEManager.restoreObserverPin writes exactly what `checkpointObserverPin` returns, so these
    /// tests pin the restore itself. This helper calls it at a fixed row RSSI of -60, with no saved
    /// pair and no pin held unless a test passes one.
    private func checkpointPin(type: DeviceType = .tracker,
                               pair: CLLocationCoordinate2D? = nil, peak: Int? = nil,
                               wire: CLLocationCoordinate2D?, gpsAgeSec: Int? = nil,
                               replayed: Bool,
                               held: (coordinate: CLLocationCoordinate2D, rssi: Int)? = nil)
        -> (coordinate: CLLocationCoordinate2D, rssi: Int)? {
        checkpointObserverPin(type: type, pairLat: pair?.latitude, pairLon: pair?.longitude,
                              peak: peak, wire: wire, rssi: -60, gpsAgeSec: gpsAgeSec,
                              replayed: replayed, existingCoordinate: held?.coordinate,
                              existingRSSI: held?.rssi)
    }

    /// A LIVE row checkpointed without a pin, whose wire fix was already stale (`gage` past the
    /// 120 s window) or malformed, seeds NOTHING on reload: the ingest refused that fix and the map
    /// gate refuses it, so the session drew no pin, and restoring one would pin the device at the
    /// phone's old position. Deleting the `replayed` guard fails this test with a floor pin.
    /// TWIN: Android `aCheckpointLiveRowWithAStaleFixSeedsNothing` in LocationOwnershipTest.kt.
    func testCheckpointLiveRowWithAStaleFixSeedsNothing() {
        let wire = offset(lat: 0.01)
        for age in [121, -1] {
            XCTAssertNil(checkpointPin(wire: wire, gpsAgeSec: age, replayed: false), "age \(age)")
        }
    }

    /// A REPLAYED row checkpointed without a pin, whose fix was already stale at capture, keeps its
    /// coordinate only as a floor pin, as the replay ingest does: it parks at the stale-pin floor,
    /// a later located sighting at -127 takes it back, and it never overwrites a pin already held.
    /// Routing the stale age through the ranked arm fails the floor, displacement and held-pin
    /// assertions (the pin would sit at -60, above a -127 sighting); dropping the empty-pin guard
    /// from the stale fill fails the two held-pin assertions.
    /// TWIN: Android `aCheckpointReplayedRowWithAStaleFixSeedsOnlyTheFloorPin`.
    func testCheckpointReplayedRowWithAStaleFixSeedsOnlyTheFloorPin() {
        let wire = offset(lat: 0.01)
        for age in [121, -1] {
            let parked = checkpointPin(wire: wire, gpsAgeSec: age, replayed: true)
            XCTAssertEqual(parked?.coordinate.latitude, wire.latitude, "age \(age)")
            XCTAssertEqual(parked?.coordinate.longitude, wire.longitude, "age \(age)")
            XCTAssertEqual(parked?.rssi, staleFixPinRSSI, "age \(age)")
            XCTAssertTrue(strongestLocatedSampleShouldReplace(bestRSSI: parked?.rssi,
                                                              candidateRSSI: -127), "age \(age)")
        }
        let held = offset(lon: 0.02)
        XCTAssertNil(checkpointPin(wire: wire, gpsAgeSec: 121, replayed: true,
                                   held: (held, -127)), "a ranked pin holds")
        XCTAssertNil(checkpointPin(wire: wire, gpsAgeSec: 121, replayed: true,
                                   held: (held, staleFixPinRSSI)), "a floor pin holds")
    }

    /// A missing `gage` (the legacy / sub-second encoding) or one inside the window ranks the wire
    /// coordinate on the row's own RSSI, for a live and a replayed row alike, as both ingest paths
    /// do. It competes like any located sample: a stronger pin already held for the id holds, and
    /// a weaker one is replaced. Narrowing the window below 120 fails the 120 rows here; widening
    /// it fails the 121 rows of the two stale tests above.
    /// TWIN: Android `aCheckpointRowWithACurrentOrMissingFixRanksOnItsOwnRssi`.
    func testCheckpointRowWithACurrentOrMissingFixRanksOnItsOwnRSSI() {
        let wire = offset(lat: 0.01)
        for replayed in [false, true] {
            for age in [nil, 0, 120] as [Int?] {
                let ranked = checkpointPin(wire: wire, gpsAgeSec: age, replayed: replayed)
                let label = "replayed \(replayed), age \(String(describing: age))"
                XCTAssertEqual(ranked?.coordinate.latitude, wire.latitude, label)
                XCTAssertEqual(ranked?.rssi, -60, label)
            }
        }
        let held = offset(lon: 0.02)
        XCTAssertNil(checkpointPin(wire: wire, replayed: false, held: (held, -50)),
                     "a stronger pin holds")
        let replaced = checkpointPin(wire: wire, replayed: false, held: (held, -70))
        XCTAssertEqual(replaced?.coordinate.latitude, wire.latitude, "a weaker pin is replaced")
        XCTAssertEqual(replaced?.rssi, -60)
    }

    /// A drone's wire coordinate is the aircraft, never the observer, and a row with no coordinate
    /// has nothing to seed, whatever its age or replay flag says. The drone refusal guards only the
    /// wire arm; a drone's saved observer pair still restores (the paired test below).
    /// TWIN: Android `aCheckpointRowNeverSeedsADroneOrAnUnmappableCoordinate` (which also has a
    /// 0,0 row: `Detection.coordinate` drops 0,0 before the iOS helper can see it).
    func testCheckpointRowNeverSeedsADroneOrAMissingCoordinate() {
        let wire = offset(lat: 0.01)
        for replayed in [false, true] {
            for age in [nil, 121] as [Int?] {
                XCTAssertNil(checkpointPin(type: .drone, wire: wire, gpsAgeSec: age,
                                           replayed: replayed))
                XCTAssertNil(checkpointPin(wire: nil, gpsAgeSec: age, replayed: replayed))
            }
        }
    }

    /// A saved pair WITHOUT its peak restores nothing by itself: nothing in it says how it ranked
    /// or where it came from, so the row re-runs the wire contest. Every earlier iOS build wrote
    /// its pairs that way. That pair is still not lost, whether or not the row wins a pin:
    /// testCheckpointKeepsAShippedPeaklessPairWhetherOrNotTheRowPins keeps it for the export.
    /// The pair here stands for a stale home fix and differs from the wire
    /// coordinate, so trusting the pair at the row RSSI fails every coordinate assertion, the floor
    /// assertion and the nil assertion.
    /// TWIN: Android `aCheckpointPairWithoutAPeakReRunsTheWireContest`.
    func testCheckpointPairWithoutAPeakReRunsTheWireContest() {
        let home = offset(lon: -0.05)
        let wire = offset(lat: 0.01)
        let parked = checkpointPin(pair: home, wire: wire, gpsAgeSec: 121, replayed: true)
        XCTAssertEqual(parked?.coordinate.latitude, wire.latitude, "stale replayed row")
        XCTAssertEqual(parked?.coordinate.longitude, wire.longitude, "stale replayed row")
        XCTAssertEqual(parked?.rssi, staleFixPinRSSI, "stale replayed row")
        XCTAssertNil(checkpointPin(pair: home, wire: wire, gpsAgeSec: 121, replayed: false),
                     "stale live row")
        let ranked = checkpointPin(pair: home, wire: wire, gpsAgeSec: nil, replayed: false)
        XCTAssertEqual(ranked?.coordinate.latitude, wire.latitude, "missing age")
        XCTAssertEqual(ranked?.coordinate.longitude, wire.longitude, "missing age")
        XCTAssertEqual(ranked?.rssi, -60, "missing age")
    }

    /// A saved pair WITH its peak restores at that peak, whatever the row's own age, replay flag or
    /// type says: the peak records the contest the pair was written from (a floor-parked pin
    /// carries the floor), and a drone's pair is its observer fix. It still competes, so a stronger
    /// pin already held for the id holds. The peak is clamped to the Int16 range on both apps, and
    /// a pair at 0,0 or out of range is no pair, so the row takes the wire arm.
    /// TWIN: Android `aCheckpointPairWithAPeakRestoresAtThatPeak`.
    func testCheckpointPairWithAPeakRestoresAtThatPeak() {
        let pair = offset(lon: -0.05)
        let wire = offset(lat: 0.01)
        for type in [DeviceType.tracker, .drone] {
            let restored = checkpointPin(type: type, pair: pair, peak: -55, wire: wire,
                                         gpsAgeSec: 121, replayed: false)
            XCTAssertEqual(restored?.coordinate.latitude, pair.latitude, "\(type)")
            XCTAssertEqual(restored?.coordinate.longitude, pair.longitude, "\(type)")
            XCTAssertEqual(restored?.rssi, -55, "\(type)")
        }
        XCTAssertEqual(checkpointPin(pair: pair, peak: staleFixPinRSSI, wire: wire,
                                     replayed: true)?.rssi, staleFixPinRSSI,
                       "a floor-parked pair keeps its floor")
        XCTAssertNil(checkpointPin(pair: pair, peak: -55, wire: wire, replayed: false,
                                   held: (wire, -50)), "a stronger pin holds")
        XCTAssertEqual(checkpointPin(pair: pair, peak: -40_000, wire: nil, replayed: false)?.rssi,
                       -32_768, "the peak is clamped")
        for bad in [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    CLLocationCoordinate2D(latitude: 91, longitude: 0)] {
            let label = "\(bad.latitude),\(bad.longitude) is no pair"
            let fellThrough = checkpointPin(pair: bad, peak: -55, wire: wire, replayed: false)
            XCTAssertEqual(fellThrough?.coordinate.latitude, wire.latitude, label)
            XCTAssertEqual(fellThrough?.rssi, -60, label)
        }
    }

    /// A shipped peakless pair is KEPT, for the standard export only, whether or not the restore
    /// pins the row, and it is never a pin itself, so nothing ranks it and nothing draws it: the
    /// shipped build exported that pair, and dropping it erased it from disk at the first
    /// checkpoint. This composes the two pure calls the way BLEManager.restoreObserverPin
    /// does. A live row whose board fix was 900 s old seeds no pin, so its pair is kept, for a
    /// drone too; it is still never a pin. A missing age pins the wire fix, and the keep still
    /// returns the pair for that row shape. A pair with a peak is the paired arm's, and 0,0, an
    /// out-of-range pair, half a pair and no pair are nothing to keep. Deleting the peakless
    /// branch of `legacyObserverPairToKeep` fails the loop assertions; ignoring the carried kept
    /// fields fails the carried-pair assertion. WHAT THIS FILE CANNOT CATCH: the helper takes no
    /// pin input, so "whether or not the row pins" is enforced at the call site, where
    /// restoreObserverPin runs the keep unconditionally. Re-adding the drop as a gate there would
    /// leave every assertion below passing. ExportTests owns that rule, in
    /// testRestoreThatPinsTheRowStillPreservesTheShippedPair and
    /// testShippedPeaklessPairIsKeptForTheStandardExportAndNeverBecomesAPin, which drive
    /// restoreObserverPin through testRestoreCheckpointRow. iOS only: no Android build wrote a
    /// pair without its peak.
    func testCheckpointKeepsAShippedPeaklessPairWhetherOrNotTheRowPins() {
        let shipped = offset(lon: -0.05)
        let wire = offset(lat: 0.01)
        func kept(_ pair: CLLocationCoordinate2D?, peak: Int?,
                  carried: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D? {
            legacyObserverPairToKeep(pairLat: pair?.latitude, pairLon: pair?.longitude,
                                     pairHasPeak: peak != nil,
                                     keptLat: carried?.latitude, keptLon: carried?.longitude)
        }

        for type in [DeviceType.tracker, .drone] {
            let pin = checkpointPin(type: type, pair: shipped, wire: wire, gpsAgeSec: 900,
                                    replayed: false)
            XCTAssertNil(pin, "\(type): the pair is still never a pin")
            let k = kept(shipped, peak: nil)
            XCTAssertEqual(k?.latitude, shipped.latitude, "\(type)")
            XCTAssertEqual(k?.longitude, shipped.longitude, "\(type)")
        }

        let ranked = checkpointPin(pair: shipped, wire: wire, gpsAgeSec: nil, replayed: false)
        XCTAssertNotNil(ranked, "a missing age pins the wire fix")
        XCTAssertEqual(kept(shipped, peak: nil)?.latitude, shipped.latitude,
                       "the keep takes no pin input: same answer for a row that just ranked one")
        XCTAssertEqual(kept(nil, peak: -55, carried: shipped)?.latitude, shipped.latitude,
                       "a carried kept pair rides through the next restore")

        XCTAssertNil(kept(shipped, peak: -55), "a peaked pair is the paired arm's")
        for bad in [CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    CLLocationCoordinate2D(latitude: 91, longitude: 0)] {
            XCTAssertNil(kept(bad, peak: nil), "\(bad.latitude),\(bad.longitude) is no pair")
        }
        XCTAssertNil(legacyObserverPairToKeep(pairLat: shipped.latitude, pairLon: nil,
                                              pairHasPeak: false, keptLat: nil, keptLon: nil),
                     "half a pair")
        XCTAssertNil(kept(nil, peak: nil), "no pair")
    }

    /// The write-back half. A checkpoint stores a pin WITH its peak, and a kept legacy pair on a
    /// pinless row as it came, WITHOUT a peak; with neither it stores nothing. The round trip shows
    /// the pair survives relaunches: the next restore still refuses it as a pin and keeps it again.
    /// Writing lat/lon from the pin alone (the previous checkpoint) fails the legacy and round-trip
    /// assertions; writing the pair with a peak fails the nil-peak and the nil-pin assertions.
    func testCheckpointWritesAKeptLegacyPairBackWithoutAPeak() throws {
        let shipped = offset(lon: -0.05)
        let pin = offset(lat: 0.01)
        let pinned = checkpointObserverPairToStore(pin: pin, pinRSSI: -70, legacyPair: shipped)
        XCTAssertEqual(pinned.lat, pin.latitude, "a pin wins over a legacy pair")
        XCTAssertEqual(pinned.lon, pin.longitude)
        XCTAssertEqual(pinned.peak, -70)
        let none = checkpointObserverPairToStore(pin: nil, pinRSSI: nil, legacyPair: nil)
        XCTAssertNil(none.lat)
        XCTAssertNil(none.lon)
        XCTAssertNil(none.peak)

        let legacy = checkpointObserverPairToStore(pin: nil, pinRSSI: nil, legacyPair: shipped)
        XCTAssertEqual(legacy.lat, shipped.latitude)
        XCTAssertEqual(legacy.lon, shipped.longitude)
        XCTAssertNil(legacy.peak, "written back without a peak")
        let written = CLLocationCoordinate2D(latitude: try XCTUnwrap(legacy.lat),
                                             longitude: try XCTUnwrap(legacy.lon))
        let next = checkpointPin(pair: written, peak: legacy.peak, wire: pin, gpsAgeSec: 900,
                                 replayed: false)
        XCTAssertNil(next, "the next restore still refuses it as a pin")
        let keptAgain = legacyObserverPairToKeep(pairLat: legacy.lat, pairLon: legacy.lon,
                                                 pairHasPeak: legacy.peak != nil,
                                                 keptLat: nil, keptLon: nil)
        XCTAssertEqual(keptAgain?.latitude, shipped.latitude, "and keeps it again")
        XCTAssertEqual(keptAgain?.longitude, shipped.longitude)
    }

    func testDetailThumbnailKeepsNeighborhoodScaleForALonePin() {
        let region = detectionDetailMapRegion(pin: base, trail: [])
        XCTAssertEqual(region.center.latitude, base.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, base.longitude, accuracy: 1e-9)
        XCTAssertEqual(region.span.latitudeDelta, 0.008, accuracy: 1e-9)
        XCTAssertEqual(region.span.longitudeDelta, 0.008, accuracy: 1e-9)
    }

    /// The 1.35 pad SHARED with Android's `detailBreadcrumbBounds` (DETAIL_MAP_FIT_SCALE), pinned
    /// as the literal on the same trail Android's MapLocationTest
    /// `detailBreadcrumbFloorsAShortTrailAtNeighbourhoodScale` uses for its `wide` case: two
    /// crumbs 0.01 deg apart in latitude, wider than the 0.008 floor, so the pad decides. Editing
    /// `* 1.35` in `detectionDetailMapRegion` to any other factor fails here and only here on iOS;
    /// the containment test below would pass for every pad in [1, 2).
    func testDetailThumbnailPadsAWideTrailByTheSharedFactor() {
        let pin = CLLocationCoordinate2D(latitude: 32.70, longitude: -117.1)
        let trail = [CLLocationCoordinate2D(latitude: 32.705, longitude: -117.1),
                     CLLocationCoordinate2D(latitude: 32.71, longitude: -117.1)]
        let region = detectionDetailMapRegion(pin: pin, trail: trail)
        XCTAssertEqual(region.span.latitudeDelta, 0.01 * 1.35, accuracy: 1e-9)
        XCTAssertEqual(region.span.longitudeDelta, 0.008, accuracy: 1e-9,
                       "no longitude spread, so the floor still decides that axis")
    }

    /// The two-point gate, SHARED with Android's `detailBreadcrumbBounds` (`validCrumbs.size >=
    /// 2`, DetailScreen.kt). One crumb draws no polyline on either platform, so neither platform
    /// widens the thumbnail around it: the frame stays the lone pin's neighbourhood box. Deleting
    /// the `usableTrail.count >= 2` gate in `detectionDetailMapRegion` fails this - the far crumb
    /// would drag the span roughly a degree wide and pull the centre off the pin. The Android twin
    /// is MapLocationTest.detailBreadcrumbIgnoresATrailShorterThanTwoPoints.
    func testDetailThumbnailIgnoresATrailShorterThanTwoPoints() {
        let lonePin = detectionDetailMapRegion(pin: base, trail: [])
        let oneCrumb = detectionDetailMapRegion(pin: base, trail: [offset(lat: 0.7, lon: -0.8)])
        XCTAssertEqual(oneCrumb.center.latitude, lonePin.center.latitude, accuracy: 1e-9)
        XCTAssertEqual(oneCrumb.center.longitude, lonePin.center.longitude, accuracy: 1e-9)
        XCTAssertEqual(oneCrumb.span.latitudeDelta, lonePin.span.latitudeDelta, accuracy: 1e-9)
        XCTAssertEqual(oneCrumb.span.longitudeDelta, lonePin.span.longitudeDelta, accuracy: 1e-9)
        XCTAssertEqual(oneCrumb.span.latitudeDelta, 0.008, accuracy: 1e-9)
    }

    func testDetailThumbnailFitsEveryPointInAccumulatedTrail() {
        let trail = [offset(lat: -0.01, lon: -0.02),
                     offset(lat: 0.015, lon: 0.025)]
        let region = detectionDetailMapRegion(pin: base, trail: trail)
        assert(base, isInside: region)
        for point in trail { assert(point, isInside: region) }
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 180)
        XCTAssertLessThanOrEqual(region.span.longitudeDelta, 360)
    }

    func testDetailThumbnailTakesTheShortArcAcrossAntimeridian() {
        let pin = CLLocationCoordinate2D(latitude: 10, longitude: 179.5)
        let trail = [CLLocationCoordinate2D(latitude: 10, longitude: 179),
                     CLLocationCoordinate2D(latitude: 10, longitude: -179)]
        let region = detectionDetailMapRegion(pin: pin, trail: trail)
        XCTAssertLessThan(region.span.longitudeDelta, 4,
                          "a dateline crossing must not become a nearly world-wide thumbnail")
        assert(pin, isInside: region)
        for point in trail { assert(point, isInside: region) }
    }

    // MARK: - Dense map projection policy

    func testRecentMapScopeRequiresTrustworthyTimeWithinFifteenMinutes() {
        XCTAssertEqual(MapHistoryScope.recentSeconds, 900)
        XCTAssertTrue(mapHistoryScopeIncludes(lastSeen: ago(0), basis: .exact,
                                              scope: .recent, now: now))
        XCTAssertTrue(mapHistoryScopeIncludes(lastSeen: ago(900),
                                              basis: .reconstructed(precisionSec: 2),
                                              scope: .recent, now: now))
        XCTAssertFalse(mapHistoryScopeIncludes(lastSeen: ago(901), basis: .exact,
                                               scope: .recent, now: now))
        XCTAssertFalse(mapHistoryScopeIncludes(lastSeen: ago(30),
                                               basis: .bracketed(after: ago(60), before: now),
                                               scope: .recent, now: now))
        XCTAssertFalse(mapHistoryScopeIncludes(lastSeen: ago(30), basis: .unknown,
                                               scope: .recent, now: now))
        XCTAssertFalse(mapHistoryScopeIncludes(lastSeen: now.addingTimeInterval(1), basis: .exact,
                                               scope: .recent, now: now))
    }

    func testAllHistoryIncludesUndatedAndApproximateRows() {
        XCTAssertTrue(mapHistoryScopeIncludes(lastSeen: nil, basis: .unknown,
                                              scope: .all, now: now))
        XCTAssertTrue(mapHistoryScopeIncludes(lastSeen: ago(90_000),
                                              basis: .bracketed(after: nil, before: now),
                                              scope: .all, now: now))
    }

    func testDetectionRefreshCadenceAdaptsAtDenseBoundaries() {
        XCTAssertEqual(mapDetectionRefreshInterval(rowCount: 499), 0.3)
        XCTAssertEqual(mapDetectionRefreshInterval(rowCount: 500), 0.5)
        XCTAssertEqual(mapDetectionRefreshInterval(rowCount: 2_500), 0.75)
        XCTAssertEqual(mapDetectionRefreshInterval(rowCount: 4_999), 1.0)
    }

    func testFarZoomBudgetsAnnotationsAndTrailGeometry() {
        XCTAssertEqual(mapInfrastructurePinCap(span: .init(latitudeDelta: 25, longitudeDelta: 25)), 80)
        XCTAssertEqual(mapInfrastructurePinCap(span: .init(latitudeDelta: 6, longitudeDelta: 6)), 120)
        XCTAssertEqual(mapInfrastructurePinCap(span: .init(latitudeDelta: 2, longitudeDelta: 2)), 180)
        XCTAssertEqual(mapInfrastructurePinCap(span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)), 300)
        XCTAssertEqual(mapTrailPointBudget(span: .init(latitudeDelta: 25, longitudeDelta: 25)), 12)
        XCTAssertEqual(mapTotalOverlayVertexBudget(span: .init(latitudeDelta: 2, longitudeDelta: 2)), 600)
    }

    func testClusterGridIdentityIsStableAcrossSmallPinchChanges() {
        XCTAssertEqual(MapClusterGrid.forSpan(.init(latitudeDelta: 10, longitudeDelta: 10)),
                       MapClusterGrid.forSpan(.init(latitudeDelta: 10.1, longitudeDelta: 10.1)))
    }

    /// The other half of the grid contract, and the half a constant would satisfy on its own: a
    /// wider span must pick a COARSER cell, and no cell may be finer than the span/14 rule the
    /// quantization replaced - the claim MapClusterGrid's own doc comment makes, and the reason
    /// rounding up "cannot increase marker count".
    func testClusterGridCoarsensWithSpanAndNeverUndercutsTheLegacyCell() {
        let near = MapClusterGrid.forSpan(.init(latitudeDelta: 10, longitudeDelta: 10))
        let far = MapClusterGrid.forSpan(.init(latitudeDelta: 40, longitudeDelta: 40))
        XCTAssertNotEqual(near, far)
        XCTAssertGreaterThan(far.cellDegrees, near.cellDegrees)
        for span in [0.02, 0.1, 0.4, 2.0, 10.0, 40.0, 180.0] {
            let grid = MapClusterGrid.forSpan(.init(latitudeDelta: span, longitudeDelta: span))
            XCTAssertGreaterThanOrEqual(grid.cellDegrees, span / 14, "span \(span)")
        }
    }

    /// Two sightings a few hundred metres apart: ONE bubble with the county on screen, two
    /// separate pins at street zoom. Android has owned this case for its own projection
    /// (MapProjectionTest's far/near zoom test); iOS asserted nothing about it, so a projection
    /// that ignored the span entirely - one fixed cell at every zoom, every pin merged into an
    /// untappable clump - passed the whole suite.
    func testZoomingInSeparatesTwoSpotsThatMergeAtFarZoom() {
        let seeds = [
            MapClusterSeed(id: "near-a", type: .nearbyDevice,
                           coordinate: .init(latitude: 32.75, longitude: -117.25),
                           lastSeen: now, displayName: "Nearby Device", rssi: -60),
            MapClusterSeed(id: "near-b", type: .nearbyDevice,
                           coordinate: .init(latitude: 32.75390625, longitude: -117.25),
                           lastSeen: now, displayName: "Nearby Device", rssi: -66),
        ]
        let (far, farMetrics) = buildMapClusters(
            seeds, span: .init(latitudeDelta: 10, longitudeDelta: 10), now: now)
        XCTAssertEqual(far.count, 1)
        XCTAssertEqual(far.first?.memberCount, 2)
        XCTAssertEqual(farMetrics.mergedRows, 1)

        let (near, nearMetrics) = buildMapClusters(
            seeds, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02), now: now)
        XCTAssertEqual(near.count, 2)
        XCTAssertEqual(near.map(\.memberCount), [1, 1])
        XCTAssertEqual(nearMetrics.mergedRows, 0)
        XCTAssertEqual(Set(near.flatMap(\.memberIDs)), ["near-a", "near-b"])
    }

    /// The two spoken strings a bubble can carry, neither of which a same-coordinate fixture ever
    /// reaches: a lone member speaks its own row, and a mixed bucket speaks a per-category tally
    /// in singular and plural.
    func testClusterLabelsSpeakALoneSightingAndAMixedBucketTally() {
        let seeds = [
            MapClusterSeed(id: "lone", type: .tracker, coordinate: offset(lat: 0.5),
                           lastSeen: now, displayName: "AirTag 4C", rssi: -72),
            MapClusterSeed(id: "a", type: .nearbyDevice, coordinate: base,
                           lastSeen: now, displayName: "Nearby Device", rssi: -60),
            MapClusterSeed(id: "b", type: .tracker, coordinate: base,
                           lastSeen: now, displayName: "Tile", rssi: -61),
            MapClusterSeed(id: "c", type: .tracker, coordinate: base,
                           lastSeen: now, displayName: "SmartTag", rssi: -62),
        ]
        let (clusters, _) = buildMapClusters(
            seeds, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02), now: now)
        XCTAssertEqual(clusters.count, 2)
        guard let lone = clusters.first(where: { $0.memberCount == 1 }),
              let bucket = clusters.first(where: { $0.memberCount > 1 }) else {
            return XCTFail("expected one lone pin and one multi-member bubble")
        }
        // Whole-value, so every field of a lone bubble is pinned at once: a one-member cluster
        // centres on its own recorded fix, carries its own row as the tap payload, keeps its
        // category for the artwork, and speaks the row's name, category and signal. (`id` is the
        // grid cell key, which testZoomingInSeparatesTwoSpotsThatMergeAtFarZoom owns; it is
        // carried over deliberately.)
        XCTAssertEqual(lone, MapProjectedCluster(
            id: lone.id, coord: offset(lat: 0.5), memberIDs: ["lone"], memberCount: 1,
            singleType: .tracker, singleDisplayName: "AirTag 4C", age: .fresh, uniformType: .tracker,
            accessibilityLabel: "AirTag 4C, item tracker. Signal strength -72 decibels relative to one milliwatt."))
        XCTAssertEqual(bucket.memberCount, 3)
        XCTAssertNil(bucket.singleType)
        XCTAssertNil(bucket.singleDisplayName)
        XCTAssertNil(bucket.uniformType)
        XCTAssertTrue(bucket.accessibilityLabel.hasPrefix("3 detections in this area:"),
                      bucket.accessibilityLabel)
        XCTAssertTrue(bucket.accessibilityLabel.contains("one nearby device"),
                      bucket.accessibilityLabel)
        XCTAssertTrue(bucket.accessibilityLabel.contains("2 detections of type item tracker"),
                      bucket.accessibilityLabel)
    }

    /// The map's render gate holds a bubble's subtree while `rendersSame(as:)` says nothing
    /// changed, so what that rule compares decides what a rename can reach. A lone member's
    /// spoken label is name + category + signal: the name must break the hold (a custom label has
    /// to reach VoiceOver) and the dBm must not (it moves on nearly every advert). Fails if
    /// `singleDisplayName` leaves the `rendersSame` comparison, or if the spoken label or a signal
    /// reading joins it.
    func testLoneBubbleRenderGateSeesARenameButNotASignalChange() {
        func lone(name: String, rssi: Int) -> MapProjectedCluster? {
            let seed = MapClusterSeed(id: "lone", type: .tracker, coordinate: base,
                                      lastSeen: now, displayName: name, rssi: rssi)
            let (clusters, _) = buildMapClusters(
                [seed], span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02), now: now)
            return clusters.count == 1 ? clusters[0] : nil
        }
        guard let before = lone(name: "AirTag 4C", rssi: -72),
              let renamed = lone(name: "Jane's tag", rssi: -72),
              let louder = lone(name: "AirTag 4C", rssi: -40) else {
            return XCTFail("expected exactly one lone bubble per build")
        }
        XCTAssertEqual(before.singleDisplayName, "AirTag 4C")
        XCTAssertFalse(before.rendersSame(as: renamed), "a rename must break the render hold")
        XCTAssertTrue(before.rendersSame(as: louder), "a signal change alone must not")
        XCTAssertNotEqual(before, louder, "the spoken label still carries the signal reading")
    }

    /// These three are deterministic CODE-METRIC checks at the scales performance QA uses, not a
    /// simulator timing proxy for phone FPS. They lock the dense path to exactly one input visit
    /// per seed, to the marker density the lattice below is supposed to produce, and to every
    /// input row still being reachable through some bubble.
    func testDenseProjectionBenchmark500RowsIsOnePass() {
        assertDenseProjection(rowCount: 500, expectedClusters: 26)
    }

    func testDenseProjectionBenchmark2500RowsIsOnePass() {
        assertDenseProjection(rowCount: 2_500, expectedClusters: 91)
    }

    func testDenseProjectionBenchmark4999RowsIsOnePass() {
        assertDenseProjection(rowCount: 4_999, expectedClusters: 169)
    }

    func testDenseProjectionWallClockBenchmark500Rows() {
        measureDenseProjection(rowCount: 500, expectedClusters: 26)
    }

    func testDenseProjectionWallClockBenchmark2500Rows() {
        measureDenseProjection(rowCount: 2_500, expectedClusters: 91)
    }

    func testDenseProjectionWallClockBenchmark4999Rows() {
        measureDenseProjection(rowCount: 4_999, expectedClusters: 169)
    }

    /// The shared dense workload: `rowCount` seeds on a 100 x N lattice of DISTINCT coordinates,
    /// cycling through the four categories that cluster. One fixture for both the metric checks
    /// and the wall-clock benchmarks, so the recorded time belongs to the projection the
    /// assertions describe.
    ///
    /// WHY IT LOOKS LIKE THIS. It used to stack every seed on ONE coordinate with ONE type and
    /// then assert bucketCount == 1. Identical coordinates share a cell for ANY cell size, so
    /// that assertion held for a projection which ignored MapClusterGrid.forSpan completely, and
    /// the per-cluster stage ran once no matter how many rows went in. Every value here is an
    /// exact binary fraction - 32.75 and -117.25 sit on the grid's origin, the steps are 2^-8 in
    /// latitude and 2^-7 in longitude, and a 0.4-degree span selects a 2^-5 cell - so cell
    /// membership is integer arithmetic and the expected counts cannot wobble on rounding: 8
    /// consecutive latitude values share a cell (13 bands over 100 values) and 4 consecutive
    /// longitude values share one, which is where 26 / 91 / 169 come from.
    private func denseSeeds(_ rowCount: Int) -> [MapClusterSeed] {
        // 5 against 4 categories: consecutive rows usually differ, an occasional neighbouring
        // pair matches, so buckets come out genuinely mixed instead of striped one per category.
        let types: [DeviceType] = [.nearbyDevice, .tracker, .recordingGlasses, .networkCamera]
        return (0..<rowCount).map { i in
            MapClusterSeed(
                id: "dense-\(i)", type: types[(i % 5) % 4],
                coordinate: .init(latitude: 32.75 + Double(i % 100) * 0.00390625,
                                  longitude: -117.25 + Double(i / 100) * 0.0078125),
                lastSeen: now.addingTimeInterval(-Double(i)),
                displayName: "Dense \(i)", rssi: -40 - (i % 50))
        }
    }

    /// The zoom the dense fixture is asserted at: a 0.4-degree span selects a 2^-5 cell.
    private let denseSpan = MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)

    private func assertDenseProjection(rowCount: Int, expectedClusters: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let seeds = denseSeeds(rowCount)
        let (clusters, metrics) = buildMapClusters(seeds, span: denseSpan, now: now)

        // Counted inside the insertion loop, so a second walk over the seeds fails here.
        XCTAssertEqual(metrics.inputVisits, rowCount, file: file, line: line)
        XCTAssertEqual(metrics.bucketCount, clusters.count, file: file, line: line)
        XCTAssertEqual(clusters.count, expectedClusters, file: file, line: line)
        XCTAssertEqual(metrics.mergedRows, rowCount - expectedClusters, file: file, line: line)

        // Nothing lost and nothing counted twice. A bubble stands for its members and its sheet
        // resolves them by id, so a row that disappeared here is a detection the map cannot reach.
        let memberIDs = clusters.flatMap(\.memberIDs)
        XCTAssertEqual(clusters.reduce(0) { $0 + $1.memberCount }, rowCount, file: file, line: line)
        XCTAssertEqual(memberIDs.count, rowCount, file: file, line: line)
        XCTAssertEqual(Set(memberIDs).count, rowCount, file: file, line: line)
        XCTAssertTrue(clusters.allSatisfy { $0.memberCount == $0.memberIDs.count },
                      file: file, line: line)

        // Dense buckets, not one collapsed bubble, and each one really does hold several
        // categories - so the multi-type spoken tally is built rather than skipped, and no bucket
        // claims a single category it does not have.
        XCTAssertTrue(clusters.allSatisfy { $0.memberCount > 1 }, file: file, line: line)
        XCTAssertTrue(clusters.allSatisfy { $0.singleType == nil }, file: file, line: line)
        XCTAssertTrue(clusters.contains { $0.uniformType == nil }, file: file, line: line)
    }

    /// Wall-clock output is recorded by XCTest for local comparison, with no absolute threshold:
    /// simulator/host time is useful for before/after projection work, but is not iPhone FPS.
    private func measureDenseProjection(rowCount: Int, expectedClusters: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let seeds = denseSeeds(rowCount)
        var lastCount = 0
        measure(metrics: [XCTClockMetric()]) {
            lastCount = buildMapClusters(seeds, span: denseSpan, now: now).0.count
        }
        XCTAssertEqual(lastCount, expectedClusters, file: file, line: line)
    }

    func testTrailSimplificationKeepsEndpointsWithinBudget() {
        let input = (0..<1_000).map {
            CLLocationCoordinate2D(latitude: 32 + Double($0) / 10_000,
                                   longitude: -117 + Double($0) / 10_000)
        }
        let output = simplifiedMapPolyline(input, maxPoints: 12)
        XCTAssertEqual(output.count, 12)
        XCTAssertEqual(output.first?.latitude, input.first?.latitude)
        XCTAssertEqual(output.first?.longitude, input.first?.longitude)
        XCTAssertEqual(output.last?.latitude, input.last?.latitude)
        XCTAssertEqual(output.last?.longitude, input.last?.longitude)
    }

    func testDatelineTrailAndPointSurviveWrappedViewportCull() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 10, longitude: 179.8),
            span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        let trail = [CLLocationCoordinate2D(latitude: 10, longitude: 179),
                     CLLocationCoordinate2D(latitude: 10, longitude: -179)]
        XCTAssertTrue(mapPolylineIntersectsViewport(trail, region: region))
        XCTAssertEqual(mapLongitudeDistanceDegrees(179, -179), 2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(mapLongitudeDistanceDegrees(-179.9, region.center.longitude),
                                 region.span.longitudeDelta * 0.6)
    }

    // MARK: - Grouping tolerance

    /// The cross-platform tolerance. A change here is a cross-platform change.
    func testSameSpotToleranceIsTheCrossPlatformContract() {
        XCTAssertEqual(MapPinRules.sameSpotDegrees, 1e-5)
        // ~1.1 m of latitude, which is the number the tolerance is chosen against: wide enough to
        // cover one standing position, far tighter than the gap between two real installs.
        XCTAssertEqual(MapPinRules.sameSpotDegrees * 111_320, 1.1, accuracy: 0.05)
    }

    /// The case the whole feature exists for: several rows stamped with the SAME phone coordinate.
    func testIdenticalCoordinatesAlwaysShareAKey() {
        let c = offset()
        XCTAssertEqual(MapPinRules.spotKey(c), MapPinRules.spotKey(c))
        XCTAssertNotNil(MapPinRules.spotKey(c))
    }

    /// Well inside the tolerance: GPS jitter on a single standing position still groups.
    func testCoordinatesInsideToleranceGroup() {
        // A tenth of a cell, taken from the middle of one so the pair cannot straddle an edge.
        let cell = MapPinRules.sameSpotDegrees
        let anchor = CLLocationCoordinate2D(latitude: (base.latitude / cell).rounded(.down) * cell + cell / 2,
                                            longitude: (base.longitude / cell).rounded(.down) * cell + cell / 2)
        let nudged = CLLocationCoordinate2D(latitude: anchor.latitude + cell / 10,
                                            longitude: anchor.longitude - cell / 10)
        XCTAssertEqual(MapPinRules.spotKey(anchor), MapPinRules.spotKey(nudged))
    }

    /// Two separate installs down the block never merge. 1e-3 degrees is ~111 m.
    func testDistinctPositionsDoNotGroup() {
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lat: 1e-3)))
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lon: 1e-3)))
    }

    /// An order of magnitude past the tolerance is unambiguously a different spot on both axes.
    func testTenCellsApartDoNotGroup() {
        let ten = MapPinRules.sameSpotDegrees * 10
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lat: ten)))
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lon: ten)))
    }

    /// A coordinate that cannot be bucketed degrades to "no key", never to a trap. It reaches the
    /// map only through a corrupt cache or a garbled fix, and it then renders ungrouped, which is
    /// what the map drew before grouping existed.
    func testUnbucketableCoordinatesReturnNoKey() {
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: .nan, longitude: 0)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: 0, longitude: .nan)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: .infinity, longitude: 0)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: 0, longitude: 1e300)))
    }

    // MARK: - Priority order

    /// The shared order, asserted as an order rather than as five separate numbers so renumbering
    /// the buckets stays free and reordering them does not.
    func testPriorityOrderIsWatchedAlprRavenBodyCamDroneThenEverythingElse() {
        let order: [DeviceType] = [.watched, .flockCamera, .flockRaven, .axonBodyCam, .drone]
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(MapPinRules.priority(a), MapPinRules.priority(b),
                              "\(a) must outrank \(b)")
        }
        for other: DeviceType in [.tracker, .recordingGlasses, .networkCamera, .nearbyDevice, .unknown] {
            XCTAssertGreaterThan(MapPinRules.priority(other), MapPinRules.priority(.drone),
                                 "\(other) must sit below every named category")
        }
    }

    /// The headline case, stated as the outcome and not as a comparison of two integers: a body
    /// camera stamped at the same spot as an older nearby device draws, and it is what the tap
    /// lands on.
    func testBodyCamNeverHidesUnderAnOlderLessImportantSighting() {
        let rows = [Row(tag: "nearby", type: .nearbyDevice, seen: ago(30)),
                    Row(tag: "bodycam", type: .axonBodyCam, seen: ago(9_000))]
        XCTAssertEqual(ordered(rows).first, "bodycam")
    }

    /// Priority beats recency in both input orders, so the answer never depends on how the store
    /// happened to hand the rows over.
    func testPriorityBeatsRecencyRegardlessOfInputOrder() {
        let watched = Row(tag: "watched", type: .watched, seen: ago(50_000))
        let alpr = Row(tag: "alpr", type: .flockCamera, seen: ago(5))
        XCTAssertEqual(ordered([watched, alpr]), ["watched", "alpr"])
        XCTAssertEqual(ordered([alpr, watched]), ["watched", "alpr"])
    }

    /// Every member survives the ordering; the group's job is to make all of them reachable.
    func testOrderingKeepsEveryMember() {
        let rows = [Row(tag: "a", type: .nearbyDevice, seen: ago(10)),
                    Row(tag: "b", type: .flockRaven, seen: ago(10)),
                    Row(tag: "c", type: .watched, seen: ago(10)),
                    Row(tag: "d", type: .axonBodyCam, seen: ago(10))]
        XCTAssertEqual(ordered(rows), ["c", "b", "d", "a"])
    }

    // MARK: - Tie-break by recency

    func testEqualPriorityBreaksTieByMostRecent() {
        let rows = [Row(tag: "old", type: .flockCamera, seen: ago(3_000)),
                    Row(tag: "new", type: .flockCamera, seen: ago(10)),
                    Row(tag: "middle", type: .flockCamera, seen: ago(600))]
        XCTAssertEqual(ordered(rows), ["new", "middle", "old"])
    }

    /// A member with no stamp at all loses the tie-break to one that has any stamp, rather than
    /// winning it by accident.
    func testMissingStampLosesTheRecencyTieBreak() {
        let rows = [Row(tag: "undated", type: .flockCamera, seen: nil),
                    Row(tag: "dated", type: .flockCamera, seen: ago(90_000))]
        XCTAssertEqual(ordered(rows), ["dated", "undated"])
    }

    /// Tied on BOTH keys, the order is the order they arrived in, in both directions. Swift's sort
    /// is not stable, so this is what stops a pin's identity flickering between passes.
    func testFullTieIsDeterministic() {
        let stamp = ago(120)
        let a = Row(tag: "a", type: .flockCamera, seen: stamp)
        let b = Row(tag: "b", type: .flockCamera, seen: stamp)
        XCTAssertEqual(ordered([a, b]), ["a", "b"])
        XCTAssertEqual(ordered([b, a]), ["b", "a"])
    }

    /// A group of one comes back untouched: it has to render exactly as it does today.
    func testSingleMemberGroupIsUnchanged() {
        XCTAssertEqual(ordered([Row(tag: "only", type: .nearbyDevice, seen: nil)]), ["only"])
    }

    // MARK: - Winner scan

    /// The map does NOT order a group to find out what it draws as. `ordered` sorts and allocates,
    /// and it would run for every pin on the map on every publish; `lead` answers the same
    /// question in one scan, and the tap keeps `ordered` for the member list. So the pin that
    /// DRAWS and the pin the member sheet opens on come from two different functions, and this is
    /// the test that stops them from ever disagreeing.
    func testLeadIsAlwaysTheFirstElementOfTheFullOrder() {
        let groups: [[Row]] = [
            [],
            [Row(tag: "only", type: .nearbyDevice, seen: nil)],
            // A body camera under a fresher nearby device: the headline case.
            [Row(tag: "nearby", type: .nearbyDevice, seen: ago(30)),
             Row(tag: "bodycam", type: .axonBodyCam, seen: ago(9_000))],
            // Priority beats recency by a wide margin in both directions.
            [Row(tag: "alpr", type: .flockCamera, seen: ago(5)),
             Row(tag: "watched", type: .watched, seen: ago(50_000))],
            // Equal priority: the tie-break alone decides.
            [Row(tag: "old", type: .flockCamera, seen: ago(3_000)),
             Row(tag: "new", type: .flockCamera, seen: ago(10)),
             Row(tag: "middle", type: .flockCamera, seen: ago(600))],
            // An undated row must not win a tie-break by accident.
            [Row(tag: "undated", type: .flockCamera, seen: nil),
             Row(tag: "dated", type: .flockCamera, seen: ago(90_000))],
            // Every rank at once, arriving in the worst possible order.
            [Row(tag: "unknown", type: .unknown, seen: ago(1)),
             Row(tag: "drone", type: .drone, seen: ago(2)),
             Row(tag: "bodycam", type: .axonBodyCam, seen: ago(3)),
             Row(tag: "raven", type: .flockRaven, seen: ago(4)),
             Row(tag: "alpr", type: .flockCamera, seen: ago(5)),
             Row(tag: "watched", type: .watched, seen: ago(6))],
        ]
        for rows in groups {
            let tags = rows.map(\.tag)
            XCTAssertEqual(lead(rows), ordered(rows).first, "lead disagrees with ordered for \(tags)")
            let flipped = Array(rows.reversed())
            XCTAssertEqual(lead(flipped), ordered(flipped).first,
                           "lead disagrees with ordered for reversed \(tags)")
        }
    }

    /// Tied on BOTH keys, the scan keeps the FIRST arrival, which is the same answer `ordered`'s
    /// index tie-break gives. Without this the drawn pin could swap identity between two passes
    /// over an unchanged store.
    func testLeadHoldsAFullTieOnTheEarliestArrival() {
        let stamp = ago(120)
        let a = Row(tag: "a", type: .flockCamera, seen: stamp)
        let b = Row(tag: "b", type: .flockCamera, seen: stamp)
        XCTAssertEqual(lead([a, b]), "a")
        XCTAssertEqual(lead([b, a]), "b")
    }

    /// An empty group has no winner rather than a placeholder one.
    func testLeadOfAnEmptyGroupIsNil() {
        XCTAssertNil(lead([]))
    }

    // MARK: - Same-spot membership

    private func sameMembers(_ a: [Row], _ b: [Row]) -> Bool {
        MapPinRules.sameMembers(a, b, id: { $0.tag }, type: { $0.type })
    }

    /// Same-spot membership (`MapPinRules.sameMembers`) is unchanged by a pure re-ordering of a
    /// bucket, which is what a recency crossing between two members produces on a re-sorted
    /// publish, and by a stamp. It changes when an id or a type in the bucket changes, or when
    /// the bucket gains or loses a member.
    ///
    /// This is the membership half of `InfraPin.rendersSame(as:)`, not the whole render gate:
    /// that also compares the cell id, the coord, the lead (id, type, display name), the age
    /// tier and `holdsDrone`, and leaves out every `seen` and `rssi` on purpose (its own doc
    /// says why). FAILS IF `sameMembers` compares element by element (the order flip and the
    /// rotation come back false at index 0), drops the type check on its dictionary path (the
    /// re-ordering that also changes a type comes back true), or drops its count guard (the
    /// bucket that gained a member comes back true; the one that lost a member traps on `b[i]`).
    func testSameSpotMembershipIgnoresFeedOrder() {
        let a = Row(tag: "a", type: .axonBodyCam, seen: ago(10))
        let b = Row(tag: "b", type: .axonBodyCam, seen: ago(20))
        let c = Row(tag: "c", type: .flockCamera, seen: ago(30))

        // The same members in another order are the same pin, and a stamp is not membership.
        XCTAssertTrue(sameMembers([a, b], [b, a]))
        XCTAssertTrue(sameMembers([a, b, c], [b, c, a]))
        XCTAssertTrue(sameMembers([a, b], [Row(tag: "a", type: .axonBodyCam, seen: ago(1)), b]))

        // A member swapped for another, in place or behind a re-ordering.
        XCTAssertFalse(sameMembers([a, b], [a, c]))
        XCTAssertFalse(sameMembers([a, b], [c, a]))

        // A member whose type changed: it can decide a different lead and sheet order.
        let bAsRaven = Row(tag: "b", type: .flockRaven, seen: b.seen)
        XCTAssertFalse(sameMembers([a, b], [a, bAsRaven]))
        XCTAssertFalse(sameMembers([a, b], [bAsRaven, a]))

        // A member gained or lost.
        XCTAssertFalse(sameMembers([a], [a, b]))
        XCTAssertFalse(sameMembers([a, b], [a]))
    }

    // MARK: - Age tiers

    /// The three boundaries Android has to match.
    func testAgeBoundariesAreTheCrossPlatformContract() {
        XCTAssertEqual(MapPinRules.freshSeconds, 300)
        XCTAssertEqual(MapPinRules.staleSeconds, 3_600)
    }

    func testFreshTierIsUnderFiveMinutes() {
        XCTAssertEqual(MapPinRules.age(lastSeen: now, now: now), .fresh)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(1), now: now), .fresh)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(299), now: now), .fresh)
    }

    func testRecentTierRunsFromFiveMinutesToOneHour() {
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(300), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(1_800), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(3_600), now: now), .recent)
    }

    func testStaleTierIsPastOneHour() {
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(3_601), now: now), .stale)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(86_400), now: now), .stale)
        // The case that started this: a pin persisted from a previous day.
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(5 * 86_400), now: now), .stale)
    }

    /// A stamp ahead of the clock is a clock correction, not the future, so it clamps to zero
    /// elapsed rather than computing a negative age or landing in some other tier.
    func testStampAheadOfTheClockClampsToFresh() {
        XCTAssertEqual(MapPinRules.age(lastSeen: now.addingTimeInterval(45), now: now), .fresh)
    }

    // MARK: - Missing timestamp

    /// The rule that must never invert: an undated row is RECENT. FRESH is a claim about liveness,
    /// and a row we cannot date is a row we cannot make that claim about. STALE would be the
    /// opposite lie, dimming something that may well be live.
    func testMissingTimestampIsRecentNeverFresh() {
        XCTAssertEqual(MapPinRules.age(lastSeen: nil, now: now), .recent)
    }

    /// A zeroed stamp means "unknown", not 1970. Left alone it would resolve to the oldest thing
    /// on the map and dim a row nobody ever dated.
    func testZeroTimestampIsRecent() {
        XCTAssertEqual(MapPinRules.age(lastSeen: Date(timeIntervalSince1970: 0), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: Date(timeIntervalSince1970: -1), now: now), .recent)
    }

    // MARK: - Known coverage gap: the demo seed's placement stamp
    //
    // NOT TESTED HERE, ON PURPOSE, AND NOT BECAUSE THE RULE DOES NOT MATTER. The guarantee is
    // that BLEManager.placeDemoDetections writes a lastSeen stamp for every sample row at the
    // moment it places it: drop that one line and every sample pin on the tour falls to RECENT
    // and stops pinging, which no other test in this file would catch.
    //
    // The test that covered it built a real BLEManager and called seedDemoData(showTour: false).
    // That reaches publishDetections -> writeWidgetSummary, which writes today's count, the last
    // detection, the connected flag and the per-category breakdown into the SHARED APP GROUP
    // defaults (suite group.tech.beacons.app) that the home-screen widget reads. So running the
    // unit suite left sample numbers on the user's real widget. exitDemo() does not undo that
    // reliably either: it is a restore driven off state the manager reloads asynchronously, and
    // it is dropped outright once the manager deallocates. A test must not be able to change
    // what a home screen displays, and it must not depend on a race to clean up after itself.
    //
    // The two clean ways to test it without that side effect are both changes to BLEManager
    // rather than to this file (there may be others; these are the ones that keep the guarantee
    // asserted at its source):
    //   * the sample rows and their stamping factored out into a pure builder (rows in, rows +
    //     stamps out) that the seed then installs, so the guarantee can be asserted with no
    //     manager at all; or
    //   * the widget sink behind writeWidgetSummary made injectable, so a test can hand the
    //     manager one that goes nowhere.
    // Neither exists yet, so the honest state is: this rule currently has no automated test.
    // Restoring `age(Date(), Date()) == .fresh` in its place would NOT close the gap - it only
    // re-states the fresh boundary testFreshTierIsUnderFiveMinutes already owns, and it would go
    // on passing with the seed's stamping deleted, which is worse than an admitted gap.
}
