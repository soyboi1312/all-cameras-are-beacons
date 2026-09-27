import Foundation
import XCTest
@testable import Beacons

/// The 2026-09-26 UI review's P3 polish on the Beacon tab and the tour, pinned where a pure
/// function carries the rule: the sample Scan radios row value (P3-8), the card kicker that only
/// repeats the page title (P3-7), sentence-case row titles (P3-11) and the iPad scope-segment cap
/// (P3-3, a TWIN number).
final class BeaconPagePolishTests: XCTestCase {
    // MARK: P3-8: the sample Scan radios row speaks in the live arm's words

    /// The four sample strings are the presenter's four healthy connected arms, byte for byte: a
    /// drift in either direction fails here.
    func testSampleRadiosRowValueMatchesTheLiveArmsWordForWord() throws {
        let cases: [(Bool, Bool)] = [(true, true), (true, false), (false, true), (false, false)]
        for (ble, wifi) in cases {
            let live = beaconRadioPresentation(
                connectionState: .connected,
                sessionReady: true,
                isReconnecting: false,
                isDemoMode: false,
                status: try makeStatus(ble: ble, wifi: wifi),
                combinedUpdateRunning: false)
            XCTAssertEqual(sampleRadiosRowValue(bleOn: ble, wifiOn: wifi), live.scanLabel,
                           "ble=\(ble) wifi=\(wifi)")
        }
    }

    func testSampleRadiosRowValueNeverSaysSample() {
        for ble in [true, false] {
            for wifi in [true, false] {
                XCTAssertFalse(sampleRadiosRowValue(bleOn: ble, wifiOn: wifi).contains("SAMPLE"),
                               "ble=\(ble) wifi=\(wifi)")
            }
        }
    }

    // MARK: P3-7: a kicker that only repeats the page title is not drawn

    func testKickerThatRepeatsThePageTitleIsARepeat() {
        XCTAssertTrue(cardKickerRepeatsPageTitle("SCAN RADIOS", pageTitle: "Scan radios"))
        XCTAssertTrue(cardKickerRepeatsPageTitle("BOARD LED", pageTitle: "Board LED"))
        XCTAssertTrue(cardKickerRepeatsPageTitle("LIVE MODE", pageTitle: "Live Mode"))
        XCTAssertTrue(cardKickerRepeatsPageTitle("ABOUT", pageTitle: "About"))
    }

    func testKickerThatCarriesAnotherWordStays() {
        XCTAssertFalse(cardKickerRepeatsPageTitle("DESERT MODE", pageTitle: "Desert mode + buffer"))
        XCTAssertFalse(cardKickerRepeatsPageTitle("OFFLINE BUFFER", pageTitle: "Desert mode + buffer"))
        XCTAssertFalse(cardKickerRepeatsPageTitle("PHONE NOTIFICATIONS", pageTitle: "Notifications"))
        XCTAssertFalse(cardKickerRepeatsPageTitle("INSTALLED", pageTitle: "Firmware"))
    }

    /// A card drawn outside a sub-screen (the firmware card under the update banner) has no page
    /// title and keeps its kicker.
    func testKickerWithoutAPageTitleStays() {
        XCTAssertFalse(cardKickerRepeatsPageTitle("FIRMWARE", pageTitle: ""))
    }

    // MARK: P3-11: row titles are sentence case

    func testSentenceCaseRowTitleRaisesOnlyTheFirstLetter() {
        XCTAssertEqual(DeviceView.sentenceCaseRowTitle("body cam"), "Body cam")
        XCTAssertEqual(DeviceView.sentenceCaseRowTitle("recording glasses"), "Recording glasses")
        XCTAssertEqual(DeviceView.sentenceCaseRowTitle("ALPR camera"), "ALPR camera")
        XCTAssertEqual(DeviceView.sentenceCaseRowTitle(""), "")
    }

    func testChecklistRowTitlesStartWithACapital() throws {
        for title in FirstRunTour.checklistRowTitles {
            let first = try XCTUnwrap(title.first)
            XCTAssertTrue(first.isUppercase, title)
        }
        XCTAssertEqual(FirstRunTour.checklistRowTitles[3], "Live Mode", "a feature name keeps its case")
    }

    // MARK: P3-12: the tour's dots speak the step the removed text once drew

    /// The same words Android's tourStepDescription speaks ("step N of 3"), one-based.
    func testTourStepValueSpeaksAOneBasedStep() {
        XCTAssertEqual(FirstRunTour.tourStepValue(page: 0, count: 3), "step 1 of 3")
        XCTAssertEqual(FirstRunTour.tourStepValue(page: 1, count: 3), "step 2 of 3")
        XCTAssertEqual(FirstRunTour.tourStepValue(page: 2, count: 3), "step 3 of 3")
    }

    // MARK: P3-1: the floating header is the legend cap's top inset, not a smaller region

    /// The 55% share is taken of the whole region (header included), so floating the header
    /// costs the card nothing where the docked header showed the keys whole; the header only
    /// bounds the room. Wrong inputs: the share taken of the region less the header (the first
    /// P3-1 build) returns 330 for the tall region, not 385; a room that ignores the header
    /// returns 220 for the short region, not 142, running the card up under the header.
    func testLegendCardCapTreatsTheFloatingHeaderAsARoomBoundOnly() {
        // A tall region: the share binds and the header does not shrink it.
        XCTAssertEqual(mapLegendCardCap(regionHeight: 700, summaryHeight: 60, accessibilitySize: false,
                                        topInset: 100, bottomInset: 90), 385, accuracy: 0.001)
        // A short region: the card stops 8pt under the header (400 - 100 - 150 - 8).
        XCTAssertEqual(mapLegendCardCap(regionHeight: 400, summaryHeight: 60, accessibilitySize: false,
                                        topInset: 100, bottomInset: 150), 142, accuracy: 0.001)
    }

    // MARK: P3-3: the iPad scope segments cap, the same number as Android

    func testScopeSegmentsCapIsTheSharedNumber() {
        XCTAssertEqual(MapTabView.mapScopeSegmentsMaxWidth, 520)
    }

    private func makeStatus(ble: Bool, wifi: Bool) throws -> DeviceStatus {
        let object: [String: Any] = ["fw": "beacon board", "ble": ble, "wifi": wifi]
        return try JSONDecoder().decode(DeviceStatus.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }
}
