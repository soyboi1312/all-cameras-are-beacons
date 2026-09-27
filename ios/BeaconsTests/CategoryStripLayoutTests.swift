import XCTest
@testable import Beacons

/// Pins the CategoryStripLayout wrap rule. Widths are points: a 350pt strip with 6pt gaps has
/// a six-across share of about 53.3pt, and the Status tiles' NETCAM (JetBrains Mono 11pt with
/// 0.8 tracking, R16) is about 44.4pt at the default text size, under that share. The fixture
/// widths below are the rule's inputs, not measurements of a face. The rule is Android's
/// categoryTilesPerRow with iOS geometry;
/// Android twin: CategoryTilesPerRowTest.
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

    func testASmallerPreferredCountIsKeptWhenItFits() {
        XCTAssertEqual(cols(41, preferred: 4, count: 7, spacing: 8), 4)
        XCTAssertEqual(cols(90, preferred: 4, count: 7, spacing: 8), 3)
    }

    /// A label wider than a three-across share (~112.7pt on a 350pt strip) drops to two. At the
    /// two largest accessibility sizes the old 10pt NETCAM label was that wide, which truncated
    /// it on Status and broke it mid-word on the Log before the two-across step existed.
    func testALabelTooWideForThreeDropsToTwoAndNoFurther() {
        XCTAssertEqual(cols(120), 2)
        XCTAssertEqual(cols(120, preferred: 3, count: 3, spacing: 8), 2, "a three-tile strip too")
        XCTAssertEqual(cols(500), 2, "two is the floor")
        XCTAssertEqual(cols(100, preferred: 3, count: 3, spacing: 8), 3)
    }

    func testOneOrTwoTilesAreNeverRearranged() {
        XCTAssertEqual(cols(500, preferred: 1, count: 1, spacing: 8), 1)
        XCTAssertEqual(cols(500, preferred: 2, count: 2, spacing: 8), 2)
    }
}
