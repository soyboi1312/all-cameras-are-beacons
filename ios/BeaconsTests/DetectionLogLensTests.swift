import XCTest
import CoreLocation
@testable import Beacons

final class DetectionLogLensTests: XCTestCase {
    private func detection(_ mac: String = "aa:bb:cc:dd:ee:01", name: String = "Camera",
                           rssi: Int = -60, type: DeviceType = .networkCamera,
                           offline: Bool = false, detail: String? = nil,
                           history: Bool = false) throws -> Detection {
        var json: [String: Any] = ["t": type.rawValue, "s": 0, "meth": 1, "c": 65,
                                  "mac": mac, "name": name, "rssi": rssi, "n": 1, "off": offline]
        if let detail { json["det"] = detail }
        if history { json["hist"] = true }   // a replayed record; fixtures pass offline: true too
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
        // `onlyOffline:` models the tools menu's Offline Only filter, not a scope (C10).
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

    // MARK: - Log scope, counts, sections and row overline (contracts 3.2 to 3.6)

    /// Active keeps only rows that are live AND in the Active set: a replayed row is never Active,
    /// even when its id is in the set (a replay stamped a moment ago is not something nearby now).
    /// Dropping `!d.isHistory` from logScopeKeeps keeps the replayed row and fails the first line.
    func testActiveScopeCutKeepsOnlyFreshLiveRows() throws {
        let fresh = try detection("aa:bb:cc:dd:ee:01")
        let stale = try detection("aa:bb:cc:dd:ee:02")
        let replayed = try detection("aa:bb:cc:dd:ee:03", offline: true, history: true)
        let rows = [fresh, stale, replayed]
        let activeIDs: Set<String> = [fresh.id, replayed.id]
        XCTAssertEqual(logScopeCut(rows, scope: .active, isUnseen: { _ in false },
                                   activeIDs: activeIDs).map(\.id), [fresh.id])
        XCTAssertEqual(logScopeCut(rows, scope: .all, isUnseen: { _ in false },
                                   activeIDs: activeIDs).map(\.id), rows.map(\.id))
        XCTAssertEqual(logScopeCut(rows, scope: .new, isUnseen: { $0.id == stale.id },
                                   activeIDs: activeIDs).map(\.id), [stale.id])
    }

    /// The segment counts come from the shown lens, so a category narrows them too. Counting over
    /// the feed instead gives (2, 3).
    func testScopeCountsComeFromTheLensNotTheStore() throws {
        let a = try detection("aa:bb:cc:dd:ee:01", type: .tracker)
        let b = try detection("aa:bb:cc:dd:ee:02", type: .tracker)
        let c = try detection("aa:bb:cc:dd:ee:03", type: .tracker)
        let d = try detection("aa:bb:cc:dd:ee:04", type: .networkCamera)
        let e = try detection("aa:bb:cc:dd:ee:05", type: .networkCamera)
        let feed = [a, b, c, d, e]
        let unseen: Set<String> = [a.id, b.id, d.id]
        let lensAll = lens(feed, category: "TRACKER")
        XCTAssertEqual(lensAll.map(\.id), [a.id, b.id, c.id])
        let counts = logScopeCounts(lensAll, isUnseen: { unseen.contains($0.id) },
                                    activeIDs: [a.id, d.id])
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.new, 2)
    }

    /// The segments read "active · N", "new · N" and "all": All carries no count.
    /// LOG-4: the network camera filter's key is CAMERA and its chip says NETWORK CAM. The lens
    /// footer and its spoken form must say the chip's label, so one filter has one name on screen
    /// (the Export item says the same words in menu case, "Export Network Cam"; that is pinned in
    /// LogExportMenuLabelTests). Wrong input: the footer used to interpolate the key and read
    /// "1 of 6 retained · CAMERA". TWIN: Android LogExportLensTest's footer-label case.
    func testLensFooterNamesTheCategoryByItsChipLabel() {
        XCTAssertEqual(logCategoryLabel("CAMERA"), "NETWORK CAM")
        XCTAssertEqual(logCategoryLabel("BODY CAM"), "BODY CAM")
        XCTAssertNil(logCategoryLabel(nil))
        XCTAssertEqual(logLensSummaryText(shown: 1, total: 6, paused: false,
                                          category: logCategoryLabel("CAMERA")),
                       "1 of 6 retained \u{00B7} NETWORK CAM")
        XCTAssertEqual(logLensSummaryDescription(shown: 1, total: 6, paused: true,
                                                 category: logCategoryLabel("CAMERA")),
                       "1 matching detections of 6 in the paused log \u{00B7} NETWORK CAM")
        XCTAssertEqual(logLensSummaryText(shown: 3, total: 3, paused: false, category: nil),
                       "3 of 3 retained")
    }

    /// CON-13: a segment is not a filter. "Clear Filters" shows only while a search, a category
    /// or Offline Only is on; an empty Active or New segment with no filter offers "Show All";
    /// All with no filter offers nothing. Wrong input: the old panel always said "Clear Filters".
    /// TWIN: Android's logNoMatchAction test.
    func testNoMatchOffersClearFiltersOnlyWhenAFilterIsOn() {
        XCTAssertEqual(logNoMatchAction(scope: .new, category: nil, searching: false, offlineOnly: false),
                       .showAll)
        XCTAssertEqual(logNoMatchAction(scope: .active, category: nil, searching: false, offlineOnly: false),
                       .showAll)
        XCTAssertNil(logNoMatchAction(scope: .all, category: nil, searching: false, offlineOnly: false))
        XCTAssertEqual(logNoMatchAction(scope: .new, category: "DRONE", searching: false, offlineOnly: false),
                       .clearFilters)
        XCTAssertEqual(logNoMatchAction(scope: .all, category: nil, searching: true, offlineOnly: false),
                       .clearFilters)
        XCTAssertEqual(logNoMatchAction(scope: .active, category: nil, searching: false, offlineOnly: true),
                       .clearFilters)
    }

    func testLogScopeSegmentLabelCountsOnlyActiveAndNew() {
        XCTAssertEqual(logScopeSegmentLabel(.active, count: 3), "active \u{00B7} 3")
        XCTAssertEqual(logScopeSegmentLabel(.new, count: 0), "new \u{00B7} 0")
        XCTAssertEqual(logScopeSegmentLabel(.all, count: 5), "all")
    }

    /// The contracts 3.4 fixture. r3 was first filed from a bracketed replay and then heard live,
    /// so its LAST-SEEN basis (what the closure returns) is .exact and it lands in "earlier today";
    /// the bracketed replay r4 is untrustworthy and goes under "older"; the trustworthy replay r5
    /// is "earlier today" but can never be Active. Wrong inputs: a membership rule that ignores
    /// the basis gives [2, 4, 1]; section 2 restricted to live rows gives [2, 2, 3]; section 1
    /// without the replay check gives [3, 2, 2] on the second call.
    func testNewestSortSplitsActiveThenTodayThenOlder() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12))!
        func at(_ hour: Int, day: Int = 24) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        let r1 = try detection("aa:bb:cc:dd:ee:01")
        let r2 = try detection("aa:bb:cc:dd:ee:02")
        let r3 = try detection("aa:bb:cc:dd:ee:03")
        let r4 = try detection("aa:bb:cc:dd:ee:04", offline: true, history: true)
        let r5 = try detection("aa:bb:cc:dd:ee:05", offline: true, history: true)
        let r6 = try detection("aa:bb:cc:dd:ee:06")
        let r7 = try detection("aa:bb:cc:dd:ee:07")
        let stamps: [String: Date] = [
            r1.id: now.addingTimeInterval(-5), r2.id: now.addingTimeInterval(-10),
            r3.id: at(10), r4.id: at(11), r5.id: at(8), r6.id: at(9), r7.id: at(18, day: 23),
        ]
        let bases: [String: TimeBasis] = [
            r1.id: .exact, r2.id: .exact, r3.id: .exact,
            r4.id: .bracketed(after: nil, before: now), r5.id: .exact, r6.id: .exact, r7.id: .exact,
        ]
        let shown = [r1, r2, r3, r4, r5, r6, r7]
        func split(_ activeIDs: Set<String>, scope: StatusScope = .all) -> [LogSection] {
            logSections(shown, scope: scope, activeIDs: activeIDs, stamp: { stamps[$0] },
                        basis: { bases[$0] ?? .unknown }, now: now, calendar: cal)
        }

        let sections = split([r1.id, r2.id])
        XCTAssertEqual(sections.map(\.title), ["heard in the last 45 s", "earlier today", "older"])
        XCTAssertEqual(sections.map { $0.rows.map(\.id) },
                       [[r1.id, r2.id], [r3.id, r5.id, r6.id], [r4.id, r7.id]])

        let withReplayID = split([r1.id, r2.id, r5.id])
        XCTAssertEqual(withReplayID.map { $0.rows.map(\.id) },
                       [[r1.id, r2.id], [r3.id, r5.id, r6.id], [r4.id, r7.id]],
                       "a replayed row is never Active, even when its id is in the set")

        // New keeps the three sections, exactly as All does (decision L6 changes only Active).
        let underNew = split([r1.id, r2.id], scope: .new)
        XCTAssertEqual(underNew.map(\.title), sections.map(\.title))
        XCTAssertEqual(underNew.map { $0.rows.map(\.id) }, sections.map { $0.rows.map(\.id) })
    }

    /// Decision L6: under the Active segment the Log draws NO time-section header. Every shown row
    /// there was heard in the last 45 s, so the builder returns ONE untitled section holding the
    /// shown rows in feed order, and the list skips the header of an untitled section. Wrong
    /// input: a builder that ignores the scope returns ["heard in the last 45 s"] here (a header
    /// drawn under Active) and fails the first assertion. An empty Active cut has no section.
    func testActiveScopeIsOneUntitledSection() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r1 = try detection("aa:bb:cc:dd:ee:01")
        let r2 = try detection("aa:bb:cc:dd:ee:02")
        let stamps: [String: Date] = [r1.id: now.addingTimeInterval(-5),
                                      r2.id: now.addingTimeInterval(-10)]
        let sections = logSections([r1, r2], scope: .active, activeIDs: [r1.id, r2.id],
                                   stamp: { stamps[$0] }, basis: { _ in .exact }, now: now,
                                   calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(sections.map(\.title), [nil])
        XCTAssertEqual(sections.map { $0.rows.map(\.id) }, [[r1.id, r2.id]])
        XCTAssertTrue(logSections([], scope: .active, activeIDs: [], stamp: { _ in nil },
                                  basis: { _ in .exact }, now: now,
                                  calendar: Calendar(identifier: .gregorian)).isEmpty)
    }

    /// The provenance overline names OFFLINE, then MUTED, then the first-seen time word, and is nil
    /// when no word applies. MUTED appended before OFFLINE fails the first assertion.
    func testRowOverlineNamesProvenanceInOneOrder() {
        XCTAssertEqual(logRowOverline(offline: true, muted: true, basis: .reconstructed(precisionSec: 2)),
                       "OFFLINE \u{00B7} MUTED \u{00B7} RECON")
        XCTAssertNil(logRowOverline(offline: false, muted: false, basis: .exact))
        XCTAssertEqual(logRowOverline(offline: false, muted: false, basis: .unknown), "NO TIME")
        XCTAssertEqual(logRowOverline(offline: true, muted: false, basis: .exact), "OFFLINE")
    }

    /// An "-active" export holds exactly the rows the Active segment shows at the tap: the live rows
    /// inside the window, never a replay (contracts 3.6). A `reviewed` that ignores `activeIDs`
    /// returns all three rows and fails the second assertion.
    func testActiveReviewKeepsOnlyRowsFreshAtTheTap() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let replayed = try detection("aa:bb:cc:dd:ee:01", offline: true, history: true)
        let live10 = try detection("aa:bb:cc:dd:ee:02")
        let live60 = try detection("aa:bb:cc:dd:ee:03")
        let snapshot = BLEManager.DetectionExportSnapshot(rows: [
            BLEManager.CSVRowInput(d: replayed, firstSeen: nil, loc: nil, basis: .exact,
                                   lastSeen: now.addingTimeInterval(-5)),
            BLEManager.CSVRowInput(d: live10, firstSeen: nil, loc: nil, basis: .exact,
                                   lastSeen: now.addingTimeInterval(-10)),
            BLEManager.CSVRowInput(d: live60, firstSeen: nil, loc: nil, basis: .exact,
                                   lastSeen: now.addingTimeInterval(-60)),
        ], unseenIDs: [])
        let active = snapshot.activeIDs(now: now, isDemoMode: false)
        XCTAssertEqual(active, [live10.id])
        let reviewed = snapshot.reviewed(category: nil, unseenOnly: false, offlineOnly: false,
            activeIDs: active, query: DetectionLogQuery(""), sort: .newest,
            isWatched: { _ in false })
        XCTAssertEqual(reviewed.detections.map(\.id), [live10.id])
        XCTAssertEqual(snapshot.activeIDs(now: now, isDemoMode: true), [live10.id, live60.id],
                       "sample data keeps every live row Active, as Status does")
    }

    /// U3-d: a row nothing names draws the category's title fallback ("body cam", "network
    /// camera") while displayName, which feeds CSV / GPX, hasName and the managed lists, keeps
    /// the export label. A named row (here the maker the payload carried) is unchanged.
    /// Wrong inputs: changing `label` (the export value), or leaving titleName = displayName.
    /// TWIN: android StatusBeaconPresentationTest's titleName case.
    func testTitleNameUsesTheDisplayFallbackAndKeepsTheExportLabel() throws {
        func wire(_ json: [String: Any]) throws -> Detection {
            try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: json))
        }
        let cam = try wire(["t": 3, "s": 0, "meth": 1, "c": 75, "mac": "00:25:DF:00:00:01",
                            "rssi": -88, "n": 1])
        XCTAssertEqual(cam.titleName, "body cam")
        XCTAssertEqual(cam.displayName, "Body Camera")
        XCTAssertFalse(cam.hasName)
        XCTAssertEqual(DeviceType.axonBodyCam.label, "Body Camera", "the CSV / GPX type value")

        let netcam = try wire(["t": 10, "s": 1, "meth": 1, "c": 65, "mac": "02:00:00:00:00:02",
                               "rssi": -70, "n": 1])
        XCTAssertEqual(netcam.titleName, "network camera")
        XCTAssertEqual(netcam.displayName, "Network camera")

        let hik = try wire(["t": 10, "s": 1, "meth": 1, "c": 65, "mac": "44:19:B6:00:00:03",
                            "rssi": -70, "det": "Hikvision on wifi", "n": 1])
        XCTAssertEqual(hik.titleName, "Hikvision")
        XCTAssertEqual(hik.displayName, "Hikvision")
    }
}
