import XCTest
@testable import Beacons

/// The Log tools menu's Title Case labels (owner decision 2026-09-25: buttons and menu items use
/// Apple title-style capitalization). The category items and the export submenu read
/// `DetectionCategory.menuLabel`; the chips and the lens footer keep `chipLabel` in caps.
final class LogExportMenuLabelTests: XCTestCase {

    /// The export submenu names the active category filter in menu-item case, so a partial export
    /// can't be mistaken for the whole log. Wrong input: the label was built from logCategoryLabel
    /// (the chip's caps) and read "EXPORT NETWORK CAM". TWIN: Android `logExportMenuHeader` in
    /// LogScreen.kt, byte-identical.
    func testExportLabelNamesTheCategoryByItsMenuLabel() {
        XCTAssertEqual(logExportMenuLabel(nil), "Export")
        XCTAssertEqual(logExportMenuLabel("CAMERA"), "Export Network Cam")
        XCTAssertEqual(logExportMenuLabel("BODY CAM"), "Export Body Cam")
        XCTAssertEqual(logExportMenuLabel("DRONE"), "Export Drone")
        XCTAssertEqual(logExportMenuLabel("ALPR"), "Export ALPR")
        XCTAssertEqual(logExportMenuLabel("WATCHED"), "Export Watched")
        // A key the menu does not list (a deep link can seed one) passes through.
        XCTAssertEqual(logExportMenuLabel("SOMETHING"), "Export SOMETHING")
    }

    /// One filter, one name: the menu label is the chip's words in a different case, never
    /// different words. The key stays out of both (CAMERA reads Network Cam / NETWORK CAM).
    func testMenuLabelIsTheChipLabelsWords() {
        for c in detectionCategories {
            XCTAssertEqual(c.menuLabel.uppercased(), c.chipLabel, c.key)
        }
        XCTAssertEqual(detectionCategories.map(\.menuLabel),
                       ["ALPR", "Drone", "Body Cam", "Tracker", "Glasses", "Network Cam", "Watched"])
    }

    /// The chips and the lens footer stay in caps: only the menu changed case.
    func testChipLabelsStayUppercase() {
        XCTAssertEqual(logCategoryLabel("CAMERA"), "NETWORK CAM")
        for c in detectionCategories {
            XCTAssertEqual(c.chipLabel, c.chipLabel.uppercased(), c.key)
        }
    }

    /// The Sort Detections picker's items, drawn from DetectionLogSort.label.
    func testSortLabelsUseTitleCase() {
        XCTAssertEqual(DetectionLogSort.newest.label, "Newest")
        XCTAssertEqual(DetectionLogSort.strongest.label, "Strongest Signal")
    }
}
