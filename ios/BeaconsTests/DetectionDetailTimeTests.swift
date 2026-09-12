import XCTest
@testable import Beacons

/// The dossier's clock text. DetectionDetailView re-renders on a 1 s tick because these readings
/// move with the clock and nothing @Published does, and they only follow that tick while the
/// formatters measure against the `now` they are handed. Every `now` below is in 1970, so a
/// formatter that quietly reads the wall clock instead prints an age of decades and fails here.
final class DetectionDetailTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAgoMeasuresToThePassedNowNotTheWallClock() {
        XCTAssertEqual(dossierRelativeAgo(now.addingTimeInterval(-61), now: now), "1m ago")
    }

    func testAgoAdvancesWithEachTick() {
        let heard = now
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(4)), "now")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(5)), "5s ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(59)), "59s ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(60)), "1m ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(3_600)), "1h ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(86_400)), "1d ago")
    }

    func testAgoWithoutATimeIsADashAndAFutureStampIsNow() {
        XCTAssertEqual(dossierRelativeAgo(nil, now: now), "-")
        XCTAssertEqual(dossierRelativeAgo(now.addingTimeInterval(30), now: now), "now")
    }

    func testAgoDegradesOnAPoisonedDateInsteadOfTrapping() {
        let poisoned = Date(timeIntervalSinceReferenceDate: -1e300)
        XCTAssertTrue(dossierRelativeAgo(poisoned, now: now).hasSuffix("d ago"))
    }

    func testSpanMeasuresToThePassedNowNotTheWallClock() {
        XCTAssertEqual(dossierSightingSpan(since: now.addingTimeInterval(-18 * 60), now: now), "18m")
    }

    func testSpanFloorsAtOneSecondAndAdvancesWithEachTick() {
        let first = now
        XCTAssertEqual(dossierSightingSpan(since: first, now: now), "1s")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(59)), "59s")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(60)), "1m")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(3_600)), "1h")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(86_400)), "1d")
    }
}
