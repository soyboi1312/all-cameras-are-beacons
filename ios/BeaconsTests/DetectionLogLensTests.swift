import XCTest
import CoreLocation
@testable import Beacons

final class DetectionLogLensTests: XCTestCase {
    private func detection(_ mac: String = "aa:bb:cc:dd:ee:01", name: String = "Camera",
                           rssi: Int = -60, type: DeviceType = .networkCamera,
                           offline: Bool = false, detail: String? = nil) throws -> Detection {
        var json: [String: Any] = ["t": type.rawValue, "s": 0, "meth": 1, "c": 65,
                                  "mac": mac, "name": name, "rssi": rssi, "n": 1, "off": offline]
        if let detail { json["det"] = detail }
        return try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: json))
    }

    /// One index for the whole case, the way DetectionsView keeps one across publishes: the
    /// reuse rule is keyed on the row's identity text, so rows that differ only in RSSI share an
    /// entry and a renamed row gets a fresh one.
    private let index = DetectionLogSearchIndex()

    private func matches(_ query: String, _ d: Detection) -> Bool {
        DetectionLogQuery(query).matches(d, index: index)
    }

    private func lens(_ rows: [Detection], query: String = "", sort: DetectionLogSort = .newest,
                      category: String? = nil, unseen: Set<String> = [], onlyNew: Bool = false,
                      onlyOffline: Bool = false, watched: Set<String> = []) -> [Detection] {
        applyDetectionLogLens(rows, category: category, unseenOnly: onlyNew,
            offlineOnly: onlyOffline, query: DetectionLogQuery(query), sort: sort,
            isUnseen: { unseen.contains($0.id) }, isWatched: { watched.contains($0.id) },
            index: index)
    }

    func testEmptyQueryPreservesNewestInputOrder() throws {
        let rows = try [detection(rssi: -90), detection("aa:bb:cc:dd:ee:02", rssi: -30)]
        XCTAssertEqual(lens(rows, query: " \n  ").map(\.id), rows.map(\.id))
    }

    func testSearchFoldsCaseAndAccentsAndRequiresEveryWord() throws {
        let d = try detection(name: "Café Garden Camera")
        XCTAssertTrue(matches("CAFE garden", d))
        XCTAssertTrue(matches("garden CAMERA", d))
        XCTAssertFalse(matches("cafe garage", d))
    }

    /// The fold is NFD + strip combining marks + SIMPLE lowercase on BOTH platforms, so the same
    /// query returns the same rows on both phones. Pinned against the expected answers, not the
    /// platform's own transform: full case folding (ß -> ss) matched "strasse" here and nowhere
    /// on Android, which is the drift this test exists to catch. Android's LogExportLensTest
    /// pins the same four answers. Restoring `String.folding(options: .caseInsensitive)` to
    /// DetectionLogQuery.fold fails the "strasse" assertion.
    func testFoldIsNFDStripMarksAndSimpleLowercaseOnBothPlatforms() throws {
        let street = try detection(name: "Straße Cam")
        XCTAssertTrue(matches("straße", street), "the exact spelling always matches")
        XCTAssertTrue(matches("STRAẞE", street), "capital sharp s lowercases to ß on both sides")
        XCTAssertFalse(matches("strasse", street), "no ß -> ss expansion on either platform")

        let istanbul = try detection("aa:bb:cc:dd:ee:02", name: "İstanbul Gate")
        XCTAssertTrue(matches("istanbul", istanbul),
                      "NFD splits the dot off the capital İ before it is stripped")
    }

    /// Tokens split on the Unicode White_Space set: a no-break space or an ideographic space
    /// pasted from a note separates two words exactly as a plain space does, in the query and
    /// in a row's name. Android's `isLogTokenSeparator` is pinned on the same two characters.
    func testNoBreakAndIdeographicSpacesSplitTokensLikeASpace() throws {
        let d = try detection(name: "Café Garden Camera")
        XCTAssertTrue(matches("garden\u{00A0}camera", d))
        XCTAssertTrue(matches("cafe\u{3000}garden", d))
        XCTAssertFalse(matches("garden\u{00A0}garage", d), "each word is still required")

        let spacedName = try detection("aa:bb:cc:dd:ee:02", name: "Garden\u{00A0}Cam")
        XCTAssertTrue(matches("garden cam", spacedName))
    }

    /// The folded haystack is reused across publishes: a re-sighted row that changed only its
    /// RSSI must not be derived and folded again, while a row whose identity text moved (a new
    /// advertised name, or a rename through DeviceNames) must be. Dropping the identity compare
    /// in DetectionLogSearchIndex.entry(for:) fails the second half (a stale haystack keeps
    /// matching the old name); dropping the reuse path fails the first (folds reaches 2).
    func testFoldedHaystackIsReusedUntilTheRowsIdentityTextMoves() throws {
        let own = DetectionLogSearchIndex()
        let query = DetectionLogQuery("garden")
        let first = try detection(name: "Garden Camera", rssi: -80)
        let louder = try detection(name: "Garden Camera", rssi: -40)
        XCTAssertTrue(query.matches(first, index: own))
        XCTAssertTrue(query.matches(louder, index: own))
        XCTAssertEqual(own.folds, 1, "an RSSI-only change reuses the folded haystack")

        let renamed = try detection(name: "Garage Camera", rssi: -40)
        XCTAssertFalse(query.matches(renamed, index: own))
        XCTAssertEqual(own.folds, 2, "a changed advertised name refolds the row")

        DeviceNames.shared.rebuild(
            watched: [WatchedDevice(mac: renamed.mac, label: "Garden Gate")], ignored: [])
        defer { DeviceNames.shared.rebuild(watched: [], ignored: []) }
        XCTAssertTrue(query.matches(renamed, index: own), "a custom name reaches the search")
        XCTAssertEqual(own.folds, 3, "a DeviceNames rebuild refolds through its revision")
    }

    func testMACSearchAcceptsPastedAndPartialAddresses() throws {
        let d = try detection("AA:BB:CC:DD:EE:01")
        for query in ["aa:bb:cc:dd:ee:01", "AA-BB-CC-DD-EE-01", "aabbccddee01", "CC-DD-EE"] {
            XCTAssertTrue(matches(query, d), query)
        }
        XCTAssertFalse(matches("aabbccddee99", d))
    }

    /// The visible "NODE EE01" chip is searchable through its four address characters, and the
    /// constant word "node" is in no row's haystack. Android's LogExportLensTest pins the same
    /// pair for the same lens. Joining a "node <last4>" field back into DetectionLogQuery's field
    /// list fails the second assertion: a token every row carries turns the lens into a no-op
    /// while the chip and the export slug still say a search is applied.
    func testNodeHandleMatchesByItsCharactersButTheWordNodeMatchesNothing() throws {
        let d = try detection("AA:BB:CC:DD:EE:01", name: "Field tag")
        XCTAssertEqual(d.nodeName, "EE01")
        XCTAssertTrue(matches("ee01", d))
        XCTAssertFalse(matches("node", d))
        XCTAssertFalse(matches("node ee01", d))
    }

    func testSearchFindsMakerAndCategoryWithoutAnAdvertisedName() throws {
        let d = try detection(name: "", type: .flockCamera)
        XCTAssertTrue(matches("flock", d))
        XCTAssertTrue(matches("ALPR", d))
    }

    /// `Detection.vendor` is byte-identical on both platforms, and for a body cam it reads the
    /// signature the board reported instead of answering the whole category with one maker's
    /// name. Android's LogExportLensTest pins the same three answers. Restoring the fixed
    /// "Axon (unverified)" arm fails the Motorola row (it matched "axon") and both "unverified"
    /// rows (a word no vendor carries matched every body cam). The "motorola" miss on the Axon
    /// row is the only assertion that fails when "BWC DEVICE" stops parsing as a signature: the
    /// row then falls back to the category's "Axon / Utility / Motorola" and still matches "axon".
    func testBodyCamSearchReadsTheSignatureVendorNotAFixedGuess() throws {
        let axon = try detection(type: .axonBodyCam, detail: "BWC DEVICE")
        let motorola = try detection("aa:bb:cc:dd:ee:02", type: .axonBodyCam,
                                     detail: "Motorola Solutions OUI")
        XCTAssertTrue(matches("axon", axon))
        XCTAssertFalse(matches("axon", motorola))
        XCTAssertTrue(matches("motorola", motorola))
        XCTAssertFalse(matches("motorola", axon),
                       "the Axon row names its signature's maker, not the category's three")
        XCTAssertFalse(matches("unverified", axon))
        XCTAssertFalse(matches("unverified", motorola))
    }

    func testStrongestSortUsesRawRSSIAndKeepsNewestTieOrder() throws {
        let newerWeak = try detection(rssi: -85)
        let newerStrong = try detection("aa:bb:cc:dd:ee:02", rssi: -40)
        let olderStrong = try detection("aa:bb:cc:dd:ee:03", rssi: -40)
        XCTAssertEqual(lens([newerWeak, newerStrong, olderStrong], sort: .strongest).map(\.id),
                       [newerStrong.id, olderStrong.id, newerWeak.id])
    }

    func testSearchScopeAndWatchedCategoryIntersect() throws {
        let target = try detection(name: "Garden Tag", type: .tracker, offline: true)
        let unstarred = try detection("aa:bb:cc:dd:ee:02", name: "Garden Tag",
                                     type: .tracker, offline: true)
        let nonMatching = try detection("aa:bb:cc:dd:ee:03", name: "Garage",
                                       type: .tracker, offline: true)
        let rows = [target, unstarred, nonMatching]
        XCTAssertEqual(lens(rows, query: "garden", category: "WATCHED", unseen: [target.id],
                            onlyNew: true, onlyOffline: true, watched: [target.id, nonMatching.id])
            .map(\.id), [target.id])
        XCTAssertEqual(lens(rows, category: "TRACKER", watched: [target.id]).count, 3,
                       "a star must not replace the row's real category")
    }

    func testExportLensPreservesFrozenEvidenceAndMatchedSortOrder() throws {
        let weak = try detection(name: "Garden weak", rssi: -85, type: .tracker, offline: true)
        let strong = try detection("aa:bb:cc:dd:ee:02", name: "Garden strong",
                                   rssi: -40, type: .tracker, offline: true)
        let other = try detection("aa:bb:cc:dd:ee:03", name: "Garage", rssi: -20)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let fix = CLLocationCoordinate2D(latitude: 32.7, longitude: -117.1)
        let input = BLEManager.DetectionExportSnapshot(rows: [weak, strong, other].map {
            BLEManager.CSVRowInput(d: $0, firstSeen: timestamp, loc: fix, basis: .unknown)
        }, unseenIDs: [strong.id])
        let output = input.reviewed(category: "WATCHED", unseenOnly: false, offlineOnly: true,
            query: DetectionLogQuery("garden"), sort: .strongest,
            isWatched: { [weak.id, strong.id].contains($0.id) })
        XCTAssertEqual(output.detections.map(\.id), [strong.id, weak.id])
        XCTAssertEqual(output.unseenIDs, [strong.id])
        XCTAssertEqual(output.rows.first?.firstSeen, timestamp)
        XCTAssertEqual(output.rows.first?.loc?.longitude, fix.longitude)
        XCTAssertEqual(output.basis(for: strong.id), .unknown)
        XCTAssertEqual(input.rows.count, 3, "reviewing never mutates the frozen source snapshot")
    }

    func testNoSearchMatchesExportsNoRowsRatherThanWholeLog() throws {
        let d = try detection()
        let input = BLEManager.DetectionExportSnapshot(rows: [
            BLEManager.CSVRowInput(d: d, firstSeen: nil, loc: nil, basis: .unknown)
        ], unseenIDs: [d.id])
        let output = input.reviewed(category: nil, unseenOnly: false, offlineOnly: false,
            query: DetectionLogQuery("does-not-exist"), sort: .newest, isWatched: { _ in false })
        XCTAssertTrue(output.rows.isEmpty)
        XCTAssertTrue(output.unseenIDs.isEmpty)
    }
}
