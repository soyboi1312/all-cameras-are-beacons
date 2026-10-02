import XCTest
@testable import Beacons

/// Which rows leave the detection store at its cap (storeEvictionVictims).
///
/// THE DEFECT (security review 2026-09-29). A transmitter faking a few thousand default-on
/// signatures from fresh addresses filled the store, and the old rule then dropped the OLDEST flag
/// rows: earlier sessions, replayed history, watched devices. The next checkpoint sealed the loss.
/// The rule now lets a flood evict its own rows, and watched rows go last.
///
/// Android twin: StoreEvictionPolicyTest.kt, vector for vector. Rows are listed oldest first, the
/// order each call site hands them over (by lastSeen here, by last filing on Android). The call
/// sites themselves, and which clock feeds firstSeen there, are not pinned by this suite.
final class StoreEvictionPolicyTests: XCTestCase {

    private struct Row {
        let id: String
        var ambient = false
        var watched = false
        var firstSeen: Date?
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func victims(_ rows: [Row], overflow: Int) -> [String] {
        storeEvictionVictims(rows: rows, overflow: overflow, now: now,
                             id: { $0.id }, isAmbient: { $0.ambient },
                             isWatched: { $0.watched }, firstSeen: { $0.firstSeen })
    }

    private func old(_ n: Int, prefix: String = "old") -> [Row] {
        (0..<n).map { Row(id: "\(prefix)\($0)", firstSeen: now.addingTimeInterval(-3600)) }
    }

    private func fresh(_ n: Int, age: TimeInterval = 60, prefix: String = "new") -> [Row] {
        (0..<n).map { Row(id: "\(prefix)\($0)", firstSeen: now.addingTimeInterval(-age)) }
    }

    /// Both suites pin the shared numbers, so changing one side alone fails a test.
    func testSharedThresholds() {
        XCTAssertEqual(storeFloodWindow, 600)
        XCTAssertEqual(storeFloodCohortRows, 500)
    }

    func testNothingOverflowsNothingGoes() {
        XCTAssertEqual(victims(old(3), overflow: 0), [])
    }

    /// Ambient rows go first, least recently seen first, and a watched ambient row is skipped.
    func testAmbientRowsGoFirstAndWatchedAmbientIsKept() {
        let rows = [Row(id: "flagA", firstSeen: now.addingTimeInterval(-3600)),
                    Row(id: "ambB", ambient: true),
                    Row(id: "ambC", ambient: true, watched: true),
                    Row(id: "ambD", ambient: true)]
        XCTAssertEqual(victims(rows, overflow: 1), ["ambB"])
        XCTAssertEqual(victims(rows, overflow: 2), ["ambB", "ambD"])
        XCTAssertEqual(victims(rows, overflow: 3), ["ambB", "ambD", "flagA"])
    }

    /// THE ATTACK: 10 older rows, then 501 rows first seen a minute ago. The flood evicts its own
    /// oldest rows; every older row stays. Under the old rule this returned old0...old2.
    func testAFloodEvictsItsOwnRows() {
        XCTAssertEqual(victims(old(10) + fresh(501), overflow: 3), ["new0", "new1", "new2"])
    }

    /// Exactly the threshold is not a flood, so the ordinary rolling log applies. Pins `>`.
    func testAtTheThresholdTheOldestFlagsGo() {
        XCTAssertEqual(victims(old(10) + fresh(500), overflow: 3), ["old0", "old1", "old2"])
    }

    /// The window is inclusive at exactly ten minutes and closed one second later.
    func testWindowEdge() {
        XCTAssertEqual(victims(old(10) + fresh(501, age: 600), overflow: 1), ["new0"])
        XCTAssertEqual(victims(old(10) + fresh(501, age: 601), overflow: 1), ["old0"])
    }

    /// A row with no first-seen stamp counts as old, so 501 unstamped rows are not a flood.
    func testUnstampedRowsCountAsOld() {
        let unstamped = (0..<501).map { Row(id: "nil\($0)", firstSeen: nil) }
        XCTAssertEqual(victims(old(10) + unstamped, overflow: 1), ["old0"])
    }

    /// Watched flag rows are never counted into a flood and go only when nothing else is left.
    func testWatchedRowsGoLast() {
        let rows = [Row(id: "w", watched: true, firstSeen: now.addingTimeInterval(-3600)),
                    Row(id: "x", firstSeen: now.addingTimeInterval(-3600))]
        XCTAssertEqual(victims(rows, overflow: 1), ["x"])
        XCTAssertEqual(victims(rows, overflow: 2), ["x", "w"])
        let watchedFlood = (0..<501).map { Row(id: "wf\($0)", watched: true, firstSeen: now) }
        XCTAssertEqual(victims(old(10) + watchedFlood, overflow: 1), ["old0"],
                       "watched rows do not make a flood")
    }

    /// A watched row first seen during a flood is neither counted nor taken with the fakes.
    func testAWatchedRowInsideAFloodIsNotTakenWithIt() {
        let rows = old(10) + [Row(id: "wnew", watched: true, firstSeen: now.addingTimeInterval(-60))] + fresh(501)
        XCTAssertEqual(victims(rows, overflow: 2), ["new0", "new1"])
    }

    /// Watched rows do not count toward the threshold: 400 unwatched plus 101 watched is no flood.
    func testWatchedRowsDoNotCountTowardAFlood() {
        let watchedFresh = (0..<101).map { Row(id: "w\($0)", watched: true, firstSeen: now.addingTimeInterval(-60)) }
        XCTAssertEqual(victims(old(10) + fresh(400) + watchedFresh, overflow: 1), ["old0"])
    }

    /// Ambient rows do not count toward the threshold either, even freshly stamped ones.
    func testAmbientRowsDoNotCountTowardAFlood() {
        let ambientFresh = (0..<2).map { Row(id: "amb\($0)", ambient: true, firstSeen: now.addingTimeInterval(-60)) }
        XCTAssertEqual(victims(old(10) + ambientFresh + fresh(499), overflow: 3), ["amb0", "amb1", "old0"])
    }

    /// Every id comes back once, even when a later pass walks rows an earlier pass already took.
    func testNoRowIsReturnedTwice() {
        let out = victims(fresh(501) + old(10), overflow: 505)
        XCTAssertEqual(Set(out).count, 505)
        XCTAssertEqual(Array(out.suffix(4)), ["old0", "old1", "old2", "old3"])
    }

    /// Ambient rows run out first, then the flood's own rows follow, not the older flags.
    func testAmbientThenFlood() {
        let rows = [Row(id: "amb", ambient: true)] + old(10) + fresh(501)
        XCTAssertEqual(victims(rows, overflow: 2), ["amb", "new0"])
    }
}
