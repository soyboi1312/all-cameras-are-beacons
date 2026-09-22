import XCTest
@testable import Beacons

/// The home-screen widget's no-last-hit line is read with the app closed, so it must never look
/// like an all-clear. It used to draw a green `checkmark.shield.fill` both on an empty store and
/// when the beacon was not connected at all. Reverting the symbol to any check-mark variant fails
/// the first test; changing the words fails the second. The green ink itself lives in the widget
/// view, which this hosted suite cannot reach; the symbol is the part it can hold.
/// Android twin: BeaconsWidgetLastLineTest.
final class WidgetEmptyStateTests: XCTestCase {

    func testEmptyStateNeverDrawsAnAllClearCheck() {
        XCTAssertFalse(WidgetEmptyState.symbol.lowercased().contains("checkmark"),
                       "a check mark on a zero reads as all clear")
        XCTAssertEqual(WidgetEmptyState.symbol, "shield.lefthalf.filled",
                       "the half shield the Live Activity already draws on a zero")
    }

    func testEmptyStateWordsSayOnlyWhatIsKnown() {
        XCTAssertEqual(WidgetEmptyState.text(connected: true), "no detections")
        XCTAssertEqual(WidgetEmptyState.text(connected: false), "not connected")
    }
}
