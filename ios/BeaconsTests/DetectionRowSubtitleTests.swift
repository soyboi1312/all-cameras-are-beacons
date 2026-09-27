import XCTest
@testable import Beacons

/// R19 (review P2-5): the Log row subtitle of a NAMED row leads with DeviceType.inlineLabel
/// ("ALPR camera", "body cam"), the lowercase-first form every row uses, never `label`, whose
/// Title Case ("ALPR Camera", "Body Camera") sat beside "Network camera" in one list. A nameless
/// row keeps source · method. The Map cluster sheet reuses DetectionRow, so it follows. TWIN:
/// android LogRowSubtitleTest (LogScreen.kt detectionRowSubtitle).
final class DetectionRowSubtitleTests: XCTestCase {
    private func detection(type: DeviceType, name: String?) throws -> Detection {
        var json: [String: Any] = ["t": type.rawValue, "s": 0, "meth": 1, "c": 75,
                                  "mac": "aa:bb:cc:dd:ee:01", "rssi": -60, "n": 1]
        if let name { json["name"] = name }
        return try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: json))
    }

    /// FAILS IF the named branch goes back to `label` ("ALPR Camera · ...", "Body Camera · ...").
    func testANamedRowLeadsWithTheInlineLabel() throws {
        let alpr = try detection(type: .flockCamera, name: "Flock Falcon 01")
        let body = try detection(type: .axonBodyCam, name: "X6A12345")
        XCTAssertTrue(alpr.hasName)
        XCTAssertEqual(DetectionRow.subtitle(for: alpr),
                       "\(alpr.type.inlineLabel) \u{00B7} \(alpr.method.label)")
        XCTAssertEqual(DetectionRow.subtitle(for: body),
                       "\(body.type.inlineLabel) \u{00B7} \(body.method.label)")
        XCTAssertEqual(alpr.type.inlineLabel, "ALPR camera")
        XCTAssertEqual(body.type.inlineLabel, "body cam")
        // The Title Case export word never leads a row.
        XCTAssertFalse(DetectionRow.subtitle(for: alpr).hasPrefix(alpr.type.label))
        XCTAssertFalse(DetectionRow.subtitle(for: body).hasPrefix(body.type.label))
    }

    /// A nameless row has nothing but the category in its title, so the subtitle says where and
    /// how it was heard instead of repeating the category.
    func testANamelessRowKeepsSourceAndMethod() throws {
        let d = try detection(type: .networkCamera, name: nil)
        XCTAssertFalse(d.hasName)
        XCTAssertEqual(DetectionRow.subtitle(for: d), "\(d.source.label) \u{00B7} \(d.method.label)")
    }
}
