import XCTest
import MapKit
@testable import Beacons

/// `mapCenterKeepingPinVisible` (MapTabView.swift): the camera centre that keeps a tapped pin
/// above the compact dossier sheet at its medium detent (P2-4, R19). The geometry is the iPhone
/// 17 Pro verify shot of 2026-09-26: the map ran from 315pt to 874pt in the window (with the
/// sample banner up), the sheet's top edge sat at 420pt, and the tapped ALPR pin at 534pt was
/// under the sheet.
final class MapPinVisibleUnderSheetTests: XCTestCase {

    private let mapTop: CGFloat = 315, mapHeight: CGFloat = 559, sheetTop: CGFloat = 420
    private let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
    private let center = CLLocationCoordinate2D(latitude: 34.4208, longitude: -119.6982)
    private var region: MKCoordinateRegion { MKCoordinateRegion(center: center, span: span) }
    private var degreesPerPoint: Double { 0.02 / 559 }
    private var centerY: CGFloat { mapTop + mapHeight / 2 }

    /// A pin at window row `y` under the current region.
    private func pin(atRow y: CGFloat) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: center.latitude + Double(centerY - y) * degreesPerPoint,
                               longitude: center.longitude + 0.003)
    }
    /// The window row a pin lands on once the map is centred at `c`.
    private func row(of pin: CLLocationCoordinate2D, centredAt c: CLLocationCoordinate2D) -> CGFloat {
        centerY - CGFloat((pin.latitude - c.latitude) / degreesPerPoint)
    }

    func testAPinUnderTheSheetIsPannedOntoTheMidlineOfTheUncoveredStrip() {
        let p = pin(atRow: 534)
        let c = mapCenterKeepingPinVisible(pin: p, region: region, mapTop: mapTop,
                                           mapHeight: mapHeight, sheetTop: sheetTop)
        XCTAssertNotNil(c)
        guard let c else { return }
        let target = ((mapTop + 32) + (sheetTop - 32)) / 2
        XCTAssertEqual(row(of: p, centredAt: c), target, accuracy: 0.5)
        XCTAssertEqual(c.longitude, center.longitude, "a vertical pan: the longitude is untouched")
    }

    func testAPinAlreadyInsideTheStripDoesNotMoveTheCamera() {
        XCTAssertNil(mapCenterKeepingPinVisible(pin: pin(atRow: 370), region: region, mapTop: mapTop,
                                                mapHeight: mapHeight, sheetTop: sheetTop))
    }

    func testAPinAboveTheMapIsBroughtDownIntoTheStrip() {
        let p = pin(atRow: 300)
        let c = mapCenterKeepingPinVisible(pin: p, region: region, mapTop: mapTop,
                                           mapHeight: mapHeight, sheetTop: sheetTop)
        XCTAssertNotNil(c)
        guard let c else { return }
        let y = row(of: p, centredAt: c)
        XCTAssertGreaterThan(y, mapTop + 32)
        XCTAssertLessThan(y, sheetTop - 32)
    }

    func testUnmeasuredOrTooThinGeometryNeverPans() {
        let p = pin(atRow: 534)
        XCTAssertNil(mapCenterKeepingPinVisible(pin: p, region: region, mapTop: 0, mapHeight: 0, sheetTop: 0),
                     "before the first geometry measurement")
        XCTAssertNil(mapCenterKeepingPinVisible(pin: p, region: region, mapTop: 400, mapHeight: 559, sheetTop: 450),
                     "a strip thinner than two margins")
    }
}
