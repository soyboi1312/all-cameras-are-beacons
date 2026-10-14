import XCTest
@testable import Beacons

/// The pure rules and manager seams behind the app review 2026-10-12 iOS data-layer fixes. TWIN:
/// android AppReviewDataTest.kt (the rules both apps share) and NotificationSafeNameTest.kt (the
/// banner-safety vectors ported below). Not driven here, because each needs a live link, a
/// location fix or the notification center: the ingest alert gate, the mute and unwatch
/// withdrawals (only their shared identifier is), the w_redact write, and startFirmwareUpdate's
/// revision guard, which sits behind otaLink, a live CBPeripheral no unit test can build.
final class AppReviewDataTests: XCTestCase {

    /// A real decoded frame, the same construction path the BLE link uses.
    private func detection(type: DeviceType = .tracker, name: String? = nil,
                           mac: String = "aa:bb:cc:dd:ee:01", confidence: Int = 72) throws -> Detection {
        var json: [String: Any] = ["t": type.rawValue, "s": 0, "meth": 1, "c": confidence,
                                   "mac": mac, "rssi": -60, "n": 1]
        if let name { json["name"] = name }
        return try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - Banner text safety (ported from android NotificationSafeNameTest)

    func testPlainNamesPassThroughUnchanged() {
        XCTAssertEqual(DetectionNotifier.notificationSafeName("Axon Body 4"), "Axon Body 4")
        // Accents, a non-BMP emoji and a ZWJ sequence are not controls and survive whole.
        let emoji = "Caf\u{00E9} \u{1F4F7} \u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(DetectionNotifier.notificationSafeName(emoji), emoji)
    }

    func testStripsNewlinesAndC0C1Controls() {
        for c in ["\n", "\r\n", "\t", "\u{0000}", "\u{001F}", "\u{007F}", "\u{0085}", "\u{009F}",
                  "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(DetectionNotifier.notificationSafeName("A\(c)B"), "AB",
                           "U+\(String(c.unicodeScalars.first!.value, radix: 16))")
        }
    }

    func testStripsBidiMarksEmbeddingsOverridesAndIsolates() {
        for c in ["\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
                  "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"] {
            XCTAssertEqual(DetectionNotifier.notificationSafeName("a\(c)b"), "ab",
                           "U+\(String(c.unicodeScalars.first!.value, radix: 16))")
        }
        // The classic spoof: an RLO makes the tail render reversed.
        XCTAssertEqual(DetectionNotifier.notificationSafeName("Tracker\u{202E}exe.jpg"), "Trackerexe.jpg")
    }

    /// One past each stripped range's edge, so an off-by-one widening of a range fails.
    func testNeighboursOfTheStrippedRangesAreKept() {
        for c in ["\u{00A0}", "\u{2027}", "\u{202F}", "\u{2065}", "\u{206A}", "\u{200D}"] {
            XCTAssertEqual(DetectionNotifier.notificationSafeName("a\(c)b"), "a\(c)b",
                           "U+\(String(c.unicodeScalars.first!.value, radix: 16))")
        }
    }

    /// A name that strips to nothing reads as no name: the alert says "Detected nearby" rather than
    /// an empty name or a raw control sequence.
    func testTrimsAndStripsToEmptySoTheAlertFallsBack() throws {
        XCTAssertEqual(DetectionNotifier.notificationSafeName("  \n Watch \u{202E} "), "Watch")
        XCTAssertEqual(DetectionNotifier.notificationSafeName("\n\r\t\u{202E}\u{2066}"), "")
        XCTAssertEqual(DetectionNotifier.alertText(for: try detection(name: "\u{202E}\n"),
                                                   redact: false).body,
                       "Detected nearby, 72% confidence.")
    }

    // MARK: - Alert titles and redaction

    /// FAILS on the old title, DeviceType.label: "ALPR Camera", "Body Camera".
    /// TWIN: android AppReviewDataTest alertTitlesAreSentenceCaseInlineLabels.
    func testAlertTitlesAreSentenceCaseInlineLabels() throws {
        func title(_ t: DeviceType) throws -> String {
            DetectionNotifier.alertText(for: try detection(type: t), redact: false).title
        }
        XCTAssertEqual(try title(.flockCamera), "ALPR camera")
        XCTAssertEqual(try title(.axonBodyCam), "Body cam")
        XCTAssertEqual(try title(.drone), "Drone")
        XCTAssertEqual(try title(.recordingGlasses), "Recording glasses")
        XCTAssertEqual(try title(.networkCamera), "Network camera")
        XCTAssertEqual(try title(.flockRaven), "Flock Raven")
        XCTAssertEqual(try title(.watched), "Watched device")
    }

    /// The body rule is unchanged and is android detectionAlertText's: a named device leads; a
    /// nameless one, or one whose stripped name is exactly `label`, says "Detected nearby". FAILS
    /// if the compare moves to the new title or ignores case (the "Body cam" line reads "Detected
    /// nearby") or drops the label arm (the "Tracker" line reads "Tracker detected").
    func testAlertBodyNamesTheDeviceOrSaysDetectedNearby() throws {
        func body(_ t: DeviceType, _ name: String?) throws -> String {
            DetectionNotifier.alertText(for: try detection(type: t, name: name), redact: false).body
        }
        XCTAssertEqual(try body(.axonBodyCam, "Axon Body 4"), "Axon Body 4 detected, 72% confidence.")
        XCTAssertEqual(try body(.axonBodyCam, nil), "Detected nearby, 72% confidence.")
        XCTAssertEqual(try body(.axonBodyCam, "Body cam"), "Body cam detected, 72% confidence.")
        XCTAssertEqual(try body(.tracker, "Tracker\u{202E}"), "Detected nearby, 72% confidence.")
    }

    /// FAILS on the old notifier, which posted the category and the device name whatever the
    /// in-app switch said. The sentence is also the hidden-previews placeholder, so it is pinned
    /// literally. TWIN: android AppReviewDataTest redactedAlertIsGeneric.
    func testRedactedAlertNamesNothing() throws {
        let text = DetectionNotifier.alertText(for: try detection(type: .tracker, name: "AirTag"),
                                               redact: true)
        XCTAssertEqual(text.title, "beacons")
        XCTAssertEqual(text.body, "Something was detected nearby.")
        XCTAssertEqual(DetectionNotifier.redactedBody, "Something was detected nearby.")
    }

    // MARK: - Withdrawal identifier

    /// Mute and unwatch withdraw by this identifier and notifyIfNeeded posts under it, so the two
    /// must agree whatever case the MAC arrived in: the managed lists store it lowercased.
    /// FAILS if the lowercasing goes (the uppercase line keeps its case) or the prefix changes
    /// (the Clear's prefix scope would miss it). TWIN: alertId in android DetectionNotifier.kt.
    func testAlertIdentifierIgnoresMacCase() {
        XCTAssertEqual(DetectionNotifier.alertIdentifier("AA:BB:CC:DD:EE:01"), "acab.det.aa:bb:cc:dd:ee:01")
        XCTAssertEqual(DetectionNotifier.alertIdentifier("aa:bb:cc:dd:ee:01"), "acab.det.aa:bb:cc:dd:ee:01")
        XCTAssertEqual(DetectionNotifier.detectionNotificationIDs(
            [DetectionNotifier.alertIdentifier("aa:bb:cc:dd:ee:01")]).count, 1)
    }

    // MARK: - Mute refusal reason

    /// The same three guards as ignoreDevice, in its order. A test manager has no location fix, so
    /// a place mute always lacks one. FAILS on the old sheet logic, which had no reason to read and
    /// fell through to "list is full" for an unstorable address: the first two lines.
    /// TWIN: android AppReviewDataTest muteRefusalFollowsIgnoreDeviceGuardOrder.
    func testMuteRefusalFollowsIgnoreDeviceGuardOrder() throws {
        let ble = BLEManager(defaults: isolatedDefaults())
        XCTAssertNil(ble.currentLocationCoord, "precondition: no fix")
        let unstorable = try detection(mac: "not-a-mac")
        XCTAssertEqual(ble.muteRefusal(for: unstorable, scope: .permanent), .unstorableAddress)
        XCTAssertEqual(ble.muteRefusal(for: unstorable, scope: .here), .unstorableAddress)
        let upper = try detection(mac: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(ble.muteRefusal(for: upper, scope: .here), .locationNeeded)
        XCTAssertEqual(ble.muteRefusal(for: upper, scope: .oneDay), .listFull)
        // Each refusal named above is one ignoreDevice really makes; both return before any write.
        XCTAssertFalse(ble.ignoreDevice(unstorable))
        XCTAssertFalse(ble.ignoreDevice(upper, scope: .here))
    }

    // MARK: - OTA revision gate

    /// Blocks only a listing the board's reported revision contradicts; "not told" never blocks.
    /// Both directions of the mismatch, so a gate that checks one side only fails. A pin of the
    /// rule moved out of SettingsView unchanged; it passes on the old logic, and the new call in
    /// startFirmwareUpdate is not driven (see the type comment).
    func testRevisionGateBlocksOnlyAContradictingListing() {
        XCTAssertTrue(FirmwareVersionPolicy.revisionMatches(boardRev: nil, fwLabel: "beacon board rev-B"))
        XCTAssertTrue(FirmwareVersionPolicy.revisionMatches(boardRev: "C", fwLabel: "beacon board rev-B"))
        XCTAssertTrue(FirmwareVersionPolicy.revisionMatches(boardRev: "A", fwLabel: "beacon board"))
        XCTAssertTrue(FirmwareVersionPolicy.revisionMatches(boardRev: "B", fwLabel: "beacon board rev-B"))
        XCTAssertTrue(FirmwareVersionPolicy.revisionMatches(boardRev: "B", fwLabel: "Beacon Board REV-B"))
        XCTAssertFalse(FirmwareVersionPolicy.revisionMatches(boardRev: "A", fwLabel: "beacon board rev-B"))
        XCTAssertFalse(FirmwareVersionPolicy.revisionMatches(boardRev: "B", fwLabel: "beacon board"))
    }

    // MARK: - "New" watermark

    /// The live baseline is the newest real first-seen stamp, not the wall clock; a pseudo-band
    /// stamp never sets it. The newest row sits a minute back so the test cannot pass by reading
    /// now. FAILS on the old `seenWatermark = now`. TWIN: android markAllSeen.
    func testMarkAllSeenBaselinesOnTheNewestRealFirstSeen() throws {
        let ble = BLEManager(defaults: isolatedDefaults())
        let newest = Date().addingTimeInterval(-60)
        let older = newest.addingTimeInterval(-600)
        let pseudo = Date(timeIntervalSince1970: 0.5)
        ble.testSeedContributionDetection(try detection(mac: "aa:bb:cc:dd:ee:01"),
                                          firstSeen: older, lastSeen: older)
        ble.testSeedContributionDetection(try detection(mac: "aa:bb:cc:dd:ee:02"),
                                          firstSeen: newest, lastSeen: newest)
        ble.testSeedContributionDetection(try detection(mac: "aa:bb:cc:dd:ee:03"),
                                          firstSeen: pseudo, lastSeen: pseudo)
        ble.markAllSeen()
        XCTAssertEqual(ble.seenWatermark, newest)
    }

    /// With no real row the baseline falls back to now. FAILS if the pseudo-band filter goes: the
    /// watermark would be the 1970 ordering key.
    func testMarkAllSeenFallsBackToNowWithOnlyPseudoRows() throws {
        let ble = BLEManager(defaults: isolatedDefaults())
        let pseudo = Date(timeIntervalSince1970: 0.5)
        ble.testSeedContributionDetection(try detection(mac: "aa:bb:cc:dd:ee:03"),
                                          firstSeen: pseudo, lastSeen: pseudo)
        let before = Date()
        ble.markAllSeen()
        let after = Date()
        let mark = try XCTUnwrap(ble.seenWatermark)
        XCTAssertTrue(mark >= before && mark <= after)
    }

    /// A first-seen stamp in the future (the phone clock moved back) caps at now, so it cannot
    /// mark later live rows seen. FAILS on the uncapped baseline: the watermark is the stamp a day
    /// ahead. TWIN: android markAllSeen.
    func testMarkAllSeenCapsAFutureStampAtNow() throws {
        let ble = BLEManager(defaults: isolatedDefaults())
        let future = Date().addingTimeInterval(86_400)
        ble.testSeedContributionDetection(try detection(mac: "aa:bb:cc:dd:ee:01"),
                                          firstSeen: future, lastSeen: future)
        let before = Date()
        ble.markAllSeen()
        let after = Date()
        let mark = try XCTUnwrap(ble.seenWatermark)
        XCTAssertTrue(mark >= before && mark <= after)
    }

    // MARK: - Unreadable saved log

    /// A temp directory this test owns, removed after it. Not UUID-named, so the app's tmp sweep
    /// (ExportTempCache) can never match it.
    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppReviewDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The load's undecodable arm keeps the file as "<name>.unreadable-<epoch ms>", frees the
    /// original path, and never overwrites a taken name. FAILS on the old loader, which kept no
    /// copy (the next checkpoint wrote over the file): every assertion on `kept`. The loader's
    /// call and the notice it raises are not driven: they read the host app's own store.
    /// TWIN: android setAsideUnreadableLog.
    func testSetAsideUnreadableLogKeepsTheFileAndNeverOverwrites() throws {
        let fm = FileManager.default
        let store = try scratchDirectory().appendingPathComponent("acab-detections.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000.5)
        try Data("not json".utf8).write(to: store)
        let kept = try XCTUnwrap(setAsideUnreadableLog(store, now: now))
        XCTAssertEqual(kept.lastPathComponent, "acab-detections.json.unreadable-1700000000500")
        XCTAssertFalse(fm.fileExists(atPath: store.path))
        XCTAssertEqual(try Data(contentsOf: kept), Data("not json".utf8))
        // Same instant again: the taken name keeps its bytes and the second goes beside it.
        try Data("second".utf8).write(to: store)
        let second = try XCTUnwrap(setAsideUnreadableLog(store, now: now))
        XCTAssertEqual(second.lastPathComponent, "acab-detections.json.unreadable-1700000000500-1")
        XCTAssertEqual(try Data(contentsOf: kept), Data("not json".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertFalse(fm.fileExists(atPath: store.path))
        XCTAssertNil(setAsideUnreadableLog(store, now: now), "no file, nothing kept")
        XCTAssertEqual(BLEManager.unreadableLogNoticeText,
                       "an earlier saved log could not be opened, so this phone kept it aside and started a new one.")
    }

    /// Clear Log's file half takes the set-aside copies with the store, and nothing else beside
    /// them. FAILS if it goes back to the store alone (the old
    /// deletePersistedDetectionsSynchronously): the `kept` assertion.
    /// TWIN: android deletePersistedLogFiles.
    func testDeletePersistedLogFilesTakesTheSetAsideCopies() throws {
        let fm = FileManager.default
        let dir = try scratchDirectory()
        let store = dir.appendingPathComponent("acab-detections.json")
        let other = dir.appendingPathComponent("acab-detections.json.bak")
        try Data("x".utf8).write(to: store)
        try Data("x".utf8).write(to: other)
        let kept = try XCTUnwrap(setAsideUnreadableLog(store, now: Date()))
        try Data("x".utf8).write(to: store)
        XCTAssertTrue(deletePersistedLogFiles(store))
        XCTAssertFalse(fm.fileExists(atPath: store.path))
        XCTAssertFalse(fm.fileExists(atPath: kept.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        XCTAssertTrue(deletePersistedLogFiles(store), "already gone is success")
    }

    /// The Log shows the set-aside notice outside sample data only. FAILS if the sample-data gate
    /// is dropped: the demo line. TWIN: android unreadableLogNoticeShowsOutsideSampleDataOnly.
    func testUnreadableLogNoticeShowsOutsideSampleDataOnly() {
        let notice = BLEManager.unreadableLogNoticeText
        XCTAssertEqual(logUnreadableNotice(notice, demo: false), notice)
        XCTAssertNil(logUnreadableNotice(notice, demo: true))
        XCTAssertNil(logUnreadableNotice(nil, demo: false))
    }

    // MARK: - One status decode

    /// "wiping" and "moto" ride DeviceStatus now, so ingestStatus decodes each frame once. Absent
    /// wiping is idle; absent moto stays nil (pre-split firmware), never defaulted.
    func testStatusCarriesWipingAndMoto() throws {
        func status(_ json: String) throws -> DeviceStatus {
            try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
        }
        let bare = try status(#"{"fw":"beacon board 2.2.0"}"#)
        XCTAssertFalse(bare.wiping)
        XCTAssertNil(bare.moto)
        let full = try status(#"{"fw":"beacon board 2.2.0","wiping":true,"moto":false}"#)
        XCTAssertTrue(full.wiping)
        XCTAssertEqual(full.moto, false)
    }

    // MARK: - Tracker title (owner request 2026-10-14)

    /// "Apple AirTag" only for the AirTag string a firmware after 2.2.1 sends (the status byte
    /// declared an AirTag); the generic Find My string keeps "Apple Find My", which most separated
    /// frames are (offline Apple devices, third-party tags, AirPods). FAILS before the AirTag key:
    /// maker was nil.
    /// TWIN: android AppReviewDataTest.trackerTitleIsAirTagOnlyWhenDeclared.
    func testTrackerTitleIsAirTagOnlyWhenDeclared() throws {
        func maker(_ det: String) throws -> String? {
            let json: [String: Any] = ["t": DeviceType.tracker.rawValue, "s": 0, "meth": 3, "c": 85,
                                       "mac": "aa:bb:cc:dd:ee:01", "rssi": -60, "n": 1, "det": det]
            return try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: json)).maker
        }
        XCTAssertEqual(try maker("Apple AirTag (offline)"), "Apple AirTag")
        XCTAssertEqual(try maker("Apple Find My (offline)"), "Apple Find My")
    }
}
