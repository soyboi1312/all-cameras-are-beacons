import XCTest
@testable import Beacons

/// "wifi5" is tri-state: only beacon-c5 sends it, and ABSENT (nil) = no 5 GHz radio, which hides
/// the switch. FAILS IF an absent key decodes to true or false (an S3 board would get a switch that
/// writes into the void) or a present value is dropped. TWIN: Android DeviceStatusWifi5Test.kt,
/// same three cases and verbatim fixture JSON.
final class DeviceStatusWifi5Tests: XCTestCase {

    private func status(_ json: String) throws -> DeviceStatus {
        try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }

    func testPresentTrueReadsTrue() throws {
        XCTAssertEqual(try status(#"{"fw":"beacon c5 2.1.0","wifi":true,"wifi5":true}"#).wifi5, true)
    }

    func testPresentFalseReadsFalse() throws {
        XCTAssertEqual(try status(#"{"fw":"beacon c5 2.1.0","wifi":true,"wifi5":false}"#).wifi5, false)
    }

    func testAbsentReadsNilNeverADefault() throws {
        XCTAssertNil(try status(#"{"fw":"beacon board 2.1.0","wifi":true,"wifiEco":0}"#).wifi5)
    }
}
