import XCTest
@testable import Beacons

/// Pins the wrap rule both iOS category strips use (Status and Log). Widths are points on a
/// 390pt iPhone: the strip is 350pt with 6pt gaps, a six-across share of about 53.3pt, and a
/// 10pt NETCAM label is about 41pt at the default text size. The rule is Android's
/// categoryTilesPerRow with iOS geometry; Android twin: CategoryTilesPerRowTest.
final class CategoryStripLayoutTests: XCTestCase {
    private func cols(_ widest: CGFloat, width: CGFloat = 350, preferred: Int = 6,
                      count: Int = 6, spacing: CGFloat = 6) -> Int {
        CategoryStripLayout.columns(widestTile: widest, rowWidth: width, preferred: preferred,
                                    count: count, spacing: spacing)
    }

    func testSixAcrossWhileTheWidestLabelFits() {
        XCTAssertEqual(cols(41), 6)
    }

    func testWrapsToThreeWhenALabelWouldNotFitItsShare() {
        XCTAssertEqual(cols(54), 3, "a label wider than a ~53.3pt share wraps instead of truncating")
    }

    func testTheLogsSevenTileLayoutKeepsFourWhenItFits() {
        XCTAssertEqual(cols(41, preferred: 4, count: 7, spacing: 8), 4)
        XCTAssertEqual(cols(90, preferred: 4, count: 7, spacing: 8), 3)
    }

    /// At the two largest accessibility sizes a 10pt NETCAM is wider than a three-across share
    /// (~112.7pt on a 350pt strip), which truncated it on Status and broke it mid-word on the Log
    /// before the two-across step existed.
    func testALabelTooWideForThreeDropsToTwoAndNoFurther() {
        XCTAssertEqual(cols(120), 2)
        XCTAssertEqual(cols(120, preferred: 3, count: 3, spacing: 8), 2, "a three-tile Log strip too")
        XCTAssertEqual(cols(500), 2, "two is the floor")
        XCTAssertEqual(cols(100, preferred: 3, count: 3, spacing: 8), 3)
    }

    func testOneOrTwoTilesAreNeverRearranged() {
        XCTAssertEqual(cols(500, preferred: 1, count: 1, spacing: 8), 1)
        XCTAssertEqual(cols(500, preferred: 2, count: 2, spacing: 8), 2)
    }
}
