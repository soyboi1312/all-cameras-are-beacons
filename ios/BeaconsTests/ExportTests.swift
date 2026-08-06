import XCTest
import CoreLocation
@testable import Beacons

/// Export-format tests: the CSV drone-column gate and the GPX writer.
///
/// WHY THESE EXIST. On 2026-08-05 a real 2747-row export was found to carry a bogus drone position
/// on 2746 of 2746 NON-drone rows: `lat`/`lon` on the wire is overloaded ("drones: broadcast
/// position; others: detector GPS", ble-protocol.md line 88) and the CSV writer copied it into
/// drone_lat/drone_lon unconditionally. 555 of those rows were byte-identical to the row's own
/// approx_lat/lon, i.e. the phone's position exported as an aircraft's. Both writers already
/// carried a comment claiming "blank for a non-drone row"; nothing enforced it. These tests are
/// that enforcement.
///
/// Fixtures are built as WIRE JSON rather than by calling an initializer, so the exact same
/// fixture strings can be handed to the Android suite. Detection is decode-only, which makes the
/// wire format the only construction path and therefore the natural parity surface.
final class ExportTests: XCTestCase {

    // MARK: fixtures (shared with AcabBleManagerExportTest.kt - keep these strings identical)

    /// A BLE "nearby device" that carries lat/lon, which for a non-drone is the DETECTOR's GPS.
    /// This is the exact shape that produced the phantom-aircraft bug.
    static let nearbyJSON = """
    {"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,\
    "lat":32.763243,"lon":-117.116077,"cid":76,"n":1}
    """

    /// A drone with Remote ID: its lat/lon IS the aircraft, and plat/plon is the operator.
    static let droneJSON = """
    {"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,\
    "lat":32.763950,"lon":-117.114273,"plat":32.762257,"plon":-117.114303,\
    "alt":208,"id":"1581F67QC236L014509G","n":15}
    """

    /// Name/detail containing XML metacharacters, to pin the GPX escaping.
    static let xmlNastyJSON = """
    {"t":7,"s":0,"meth":0,"c":0,"mac":"aa:bb:cc:dd:ee:ff","rssi":-50,\
    "lat":1.5,"lon":2.5,"det":"a & b <tag> \\"quoted\\"","n":1}
    """

    private func decode(_ json: String) throws -> Detection {
        try JSONDecoder().decode(Detection.self, from: Data(json.utf8))
    }

    private func row(_ json: String,
                     loc: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 40.0, longitude: -70.0),
                     basis: TimeBasis = .exact,
                     at: Date = Date(timeIntervalSince1970: 1_780_000_000)) throws -> BLEManager.CSVRowInput {
        BLEManager.CSVRowInput(d: try decode(json), firstSeen: at, loc: loc, basis: basis)
    }

    private func cols(_ csvLine: String) -> [String] { csvLine.components(separatedBy: ",") }

    /// XMLDocument is macOS-only, so well-formedness is checked with XMLParser, which ships on
    /// iOS. This is the assertion that actually matters for GPX: a mapping app rejects the whole
    /// file on a parse error, so "contains the right substring" is not enough on its own.
    private func isWellFormedXML(_ s: String) -> Bool {
        let p = XMLParser(data: Data(s.utf8))
        return p.parse()
    }

    // MARK: - the drone-column gate (the bug)

    func testNonDroneRowLeavesDroneColumnsEmpty() throws {
        let csv = BLEManager.buildCSV([try row(Self.nearbyJSON)])
        let body = csv.components(separatedBy: "\n")[1]
        let c = cols(body)
        // Columns are 0-indexed against the header: 14 drone_lat, 15 drone_lon,
        // 20 operator_lat, 21 operator_lon.
        XCTAssertEqual(c[14], "", "drone_lat must be blank on a non-drone row")
        XCTAssertEqual(c[15], "", "drone_lon must be blank on a non-drone row")
        XCTAssertEqual(c[20], "", "operator_lat must be blank on a non-drone row")
        XCTAssertEqual(c[21], "", "operator_lon must be blank on a non-drone row")
    }

    /// The sharpest form of the regression: the fixture's wire lat/lon is ALSO what a detector-GPS
    /// row would export as approx. If the gate is removed, these two columns become equal, which
    /// is exactly the 555-row signature seen in the real export.
    func testNonDroneDroneColumnsAreNotACopyOfTheApproxPosition() throws {
        let here = CLLocationCoordinate2D(latitude: 32.763243, longitude: -117.116077)
        let csv = BLEManager.buildCSV([try row(Self.nearbyJSON, loc: here)])
        let c = cols(csv.components(separatedBy: "\n")[1])
        XCTAssertEqual(c[10], "32.763243", "sanity: approx_lat is the phone position")
        XCTAssertNotEqual(c[14], c[10], "drone_lat must never mirror approx_lat")
        XCTAssertEqual(c[14], "")
    }

    func testDroneRowKeepsItsBroadcastAndOperatorPositions() throws {
        let csv = BLEManager.buildCSV([try row(Self.droneJSON)])
        let c = cols(csv.components(separatedBy: "\n")[1])
        XCTAssertEqual(c[14], "32.763950", "a real drone must still export its aircraft position")
        XCTAssertEqual(c[15], "-117.114273")
        XCTAssertEqual(c[20], "32.762257", "operator position is the most valuable drone field")
        XCTAssertEqual(c[21], "-117.114303")
    }

    // MARK: - GPX

    func testGpxIsWellFormedAndDeclaresTheNamespace() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(gpx.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        XCTAssertTrue(gpx.hasSuffix("</gpx>"))
        // Parses as XML, not just "looks right".
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// The honesty rule: a non-drone pin is the PHONE, and the file has to say so, because a
    /// mapping app will otherwise render it as the device's location.
    func testNonDroneWaypointIsNamedAsHeardNotAsALocation() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.contains("<name>Heard:"), "non-drone waypoints must be named 'Heard:'")
        XCTAssertTrue(gpx.contains("Position is where the PHONE was, not the device."))
    }

    func testNonDroneEmitsExactlyOneWaypointAtThePhonePosition() throws {
        let here = CLLocationCoordinate2D(latitude: 12.5, longitude: -34.25)
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON, loc: here)])
        XCTAssertEqual(gpx.components(separatedBy: "<wpt ").count - 1, 1)
        XCTAssertTrue(gpx.contains("lat=\"12.500000\" lon=\"-34.250000\""))
        XCTAssertFalse(gpx.contains("broadcast position"), "no aircraft waypoint for a non-drone")
    }

    func testDroneEmitsHeardAircraftAndOperatorWaypoints() throws {
        let gpx = BLEManager.buildGPX([try row(Self.droneJSON)])
        XCTAssertEqual(gpx.components(separatedBy: "<wpt ").count - 1, 3)
        XCTAssertTrue(gpx.contains("<name>Heard:"))
        XCTAssertTrue(gpx.contains("Drone (broadcast position)"))
        XCTAssertTrue(gpx.contains("Drone OPERATOR"))
        XCTAssertTrue(gpx.contains("lat=\"32.763950\" lon=\"-117.114273\""))
        XCTAssertTrue(gpx.contains("lat=\"32.762257\" lon=\"-117.114303\""))
    }

    func testRowWithNoFixEmitsNoWaypoint() throws {
        // A non-drone with no captured location has nothing mappable; a <wpt> without lat/lon is
        // invalid GPX, so the row must be skipped rather than emitted with empty attributes.
        let json = """
        {"t":7,"s":0,"meth":0,"c":0,"mac":"11:22:33:44:55:66","rssi":-70,"n":1}
        """
        let gpx = BLEManager.buildGPX([try row(json, loc: nil)])
        XCTAssertFalse(gpx.contains("<wpt "))
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// A bracketed row has no single instant. GPX <time> can only hold a point, so writing either
    /// end would claim a precision the data does not have; the basis goes in <desc> instead.
    func testBracketedRowOmitsTimeButStatesTheBasis() throws {
        let r = try row(Self.nearbyJSON,
                        basis: .bracketed(after: Date(timeIntervalSince1970: 1_780_000_000),
                                          before: Date(timeIntervalSince1970: 1_780_000_600)))
        let gpx = BLEManager.buildGPX([r])
        XCTAssertFalse(gpx.contains("<time>"), "a bracketed row must not export a point time")
        XCTAssertTrue(gpx.contains("time: bracketed"))
    }

    func testExactRowCarriesATimeElement() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.contains("<time>"))
        XCTAssertTrue(gpx.contains("time: exact"))
    }

    /// Unescaped user/vendor text would produce invalid XML that a mapping app rejects outright.
    func testXmlMetacharactersAreEscaped() throws {
        let gpx = BLEManager.buildGPX([try row(Self.xmlNastyJSON)])
        XCTAssertTrue(gpx.contains("&amp;"))
        XCTAssertTrue(gpx.contains("&lt;tag&gt;"))
        XCTAssertFalse(gpx.contains("<tag>"), "raw markup must not survive into the document")
        // The real assertion: it still parses.
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// Ampersand must be escaped FIRST or the entities introduced by the later replacements get
    /// their own ampersand re-escaped into "&amp;lt;".
    func testAmpersandIsNotDoubleEscaped() throws {
        let gpx = BLEManager.buildGPX([try row(Self.xmlNastyJSON)])
        XCTAssertFalse(gpx.contains("&amp;lt;"), "double-escaped entity: & was replaced after <")
    }

    func testEmptySnapshotIsStillAValidGpxDocument() throws {
        let gpx = BLEManager.buildGPX([])
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
        XCTAssertFalse(gpx.contains("<wpt "))
    }
}

/// Elided live-notify records must still decode. The firmware trims optional Remote ID fields to
/// fit a small ATT MTU rather than dropping the sighting (see firmware detect_elide.h), so a phone
/// on a 185-MTU link receives records missing any suffix of
/// palt -> hgt -> vspd -> spd -> hdg -> sta -> plat/plon.
/// The parser is written with decodeIfPresent throughout, so this SHOULD hold; the brief asked for
/// a fixture rather than an assumption, and this is it.
final class ElidedRecordTests: XCTestCase {

    private func decode(_ json: String) throws -> Detection {
        try JSONDecoder().decode(Detection.self, from: Data(json.utf8))
    }

    /// Fully populated drone record, then each elision level applied in the documented order.
    private static let levels: [String] = [
        // 0: nothing elided
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"hgt":125,"palt":82,"sta":1,"n":15,"new":true}"#,
        // 1: palt gone
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"hgt":125,"sta":1,"n":15,"new":true}"#,
        // 2: + hgt
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 3: + vspd
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 4: + spd
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 5: + hdg
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"sta":1,"n":15,"new":true}"#,
        // 6: + sta
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"n":15,"new":true}"#,
        // 7: + plat/plon (maximum elision)
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"alt":208,"n":15,"new":true}"#,
    ]

    func testEveryElisionLevelStillDecodes() throws {
        for (level, json) in Self.levels.enumerated() {
            let d = try decode(json)
            // The mandatory set survives every level, which is the actual promise: the alert still
            // says what it is, how sure, and where.
            XCTAssertEqual(d.type, .drone, "level \(level)")
            XCTAssertEqual(d.mac, "60:60:1f:1a:1a:3f", "level \(level)")
            XCTAssertEqual(d.rssi, -86, "level \(level)")
            XCTAssertEqual(d.confidence, 99, "level \(level)")
            XCTAssertEqual(d.uasID, "1581F67QC236L014509G", "level \(level)")
            XCTAssertNotNil(d.coordinate, "aircraft position must survive level \(level)")
        }
    }

    func testElisionRemovesFieldsInTheDocumentedOrder() throws {
        let full = try decode(Self.levels[0])
        XCTAssertNotNil(full.pilotAlt); XCTAssertNotNil(full.pilotCoordinate)

        XCTAssertNil(try decode(Self.levels[1]).pilotAlt, "palt goes first")
        XCTAssertNotNil(try decode(Self.levels[1]).heightAGL, "hgt is still present at level 1")
        XCTAssertNil(try decode(Self.levels[2]).heightAGL, "hgt goes second")
        XCTAssertNil(try decode(Self.levels[3]).speedV, "vspd goes third")
        XCTAssertNil(try decode(Self.levels[4]).speedH, "spd goes fourth")
        XCTAssertNil(try decode(Self.levels[5]).heading, "hdg goes fifth")
        XCTAssertNil(try decode(Self.levels[6]).ridStatus, "sta goes sixth")
        // Operator position is last on purpose: it is the most actionable optional field.
        XCTAssertNotNil(try decode(Self.levels[6]).pilotCoordinate,
                        "operator position must survive until the final level")
        XCTAssertNil(try decode(Self.levels[7]).pilotCoordinate, "plat/plon goes last")
    }

    /// The non-drone path is 99% of traffic and must be untouched by any of this.
    func testOrdinaryRecordIsUnaffected() throws {
        let d = try decode(#"{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,"n":1}"#)
        XCTAssertEqual(d.mac, "c2:40:d8:1c:2b:96")
        XCTAssertNil(d.pilotCoordinate)
        XCTAssertNil(d.speedH)
    }
}
