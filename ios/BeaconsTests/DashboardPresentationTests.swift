import XCTest
@testable import Beacons

final class DashboardPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ index: Int, type: DeviceType = .nearbyDevice,
                     rssi: Int = -50, offline: Bool = false) throws -> Detection {
        try Detection.decodeWireJSON(JSONSerialization.data(withJSONObject: [
            "t": type.rawValue, "s": 0, "meth": 1, "c": 65,
            "mac": String(format: "aa:bb:cc:%02x:%02x:%02x", index >> 16, (index >> 8) & 255, index & 255),
            "name": "Device \(index)", "rssi": rssi, "n": 1, "off": offline, "hist": offline,
        ]))
    }

    private func snapshot(_ rows: [Detection], watched: Set<String> = [],
                          dates: [String: Date]? = nil, demo: Bool = false) -> DashboardSnapshot {
        dashboardSnapshot(rows, now: now, isDemoMode: demo,
            lastHeard: { dates == nil ? self.now : dates?[$0] },
            isWatched: { watched.contains($0.id) })
    }

    func testDenseDesertCountIsCompleteAndRadarKeepsMatches() throws {
        let ambient = try (0..<4_998).map { try row($0, rssi: -30) }
        let camera = try row(5_000, type: .flockCamera, rssi: -85)
        let star = try row(5_001, rssi: -95)
        let result = snapshot(ambient + [camera, star], watched: [star.id])
        XCTAssertEqual(result.total, 5_000)
        XCTAssertEqual(result.matched, 2)
        XCTAssertEqual(result.ambient, 4_998)
        XCTAssertEqual(result.watched, 1)
        XCTAssertEqual(result.total, result.matched + result.ambient)
        XCTAssertEqual(result.dots.count, 14)
        XCTAssertEqual(result.dots[0].detection.id, star.id)
        XCTAssertEqual(result.dots[1].detection.id, camera.id)
        XCTAssertEqual(result.strongest?.detection.id, camera.id)
        XCTAssertEqual(result.radarCaption, "14 of 5000 dots · 14 max")
        // Byte-identical to Android's STATUS_RADAR_CAPTION_DETAIL, pinned in
        // StatusBeaconPresentationTest too; the second clause is the one that says the dot cap
        // does not cap the counters.
        XCTAssertEqual(DashboardSnapshot.radarCaptionDetail,
                       "matches and stars first · counts include every recent device")
    }

    func testAllCategoriesAndStarsAreAccountedWithoutDoubleCounting() throws {
        let rows = try DeviceType.allCases.enumerated().map { try row($0.offset, type: $0.element) }
        let tracker = rows.first { $0.type == .tracker }!
        let unknown = rows.first { $0.type == .unknown }!
        let result = snapshot(rows, watched: [tracker.id, unknown.id])
        XCTAssertEqual(result.total, rows.count)
        XCTAssertEqual(result.ambient, 1)
        XCTAssertEqual(result.matched, rows.count - 1)
        XCTAssertEqual(result.watched, 3, "wire WATCHED, starred tracker, and starred unknown")
        XCTAssertEqual(result.categoryCounts[.tracker], 1, "a star never replaces its category")
    }

    func testUnknownFirmwareCategoryIsNotCalledAmbient() throws {
        let unknown = try row(1, type: .unknown, rssi: -80)
        let phone = try row(2, rssi: -20)
        let result = snapshot([unknown, phone])
        XCTAssertEqual(result.matched, 0)
        XCTAssertEqual(result.ambient, 1)
        XCTAssertEqual(result.unclassified, 1)
        XCTAssertEqual(result.total, result.matched + result.ambient + result.unclassified)
        XCTAssertEqual(result.strongest?.detection.id, unknown.id)
        XCTAssertEqual(result.dots.first?.detection.id, unknown.id)
    }

    func testRecentWindowExcludesHistoryStaleAndUndatedRows() throws {
        let fresh = try row(1, type: .tracker)
        let boundary = try row(2, type: .flockCamera)
        let stale = try row(3)
        let undated = try row(4)
        let history = try row(5, type: .flockCamera, offline: true)
        let result = snapshot([fresh, boundary, stale, undated, history], dates: [
            fresh.id: now, boundary.id: now.addingTimeInterval(-45),
            stale.id: now.addingTimeInterval(-45.01), history.id: now,
        ])
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.matched, 2)
    }

    func testSampleRowsRemainVisibleWithoutPretendingTheirAgeIsLive() throws {
        let d = try row(1)
        XCTAssertEqual(snapshot([d], dates: [:], demo: true).total, 1)
        XCTAssertEqual(dashboardLastHeardLabel(nil, now: now, isDemoMode: true), "sample sighting · not live")
    }

    func testRadarAndStrongestAreStableOnEqualSignals() throws {
        let rows = try (0..<30).map { try row($0, type: .tracker) }
        let forward = snapshot(rows)
        let reverse = snapshot(Array(rows.reversed()))
        XCTAssertEqual(forward.dots.map(\.detection.id), reverse.dots.map(\.detection.id))
        XCTAssertEqual(forward.strongest?.detection.id, reverse.strongest?.detection.id)
    }

    /// Pins the SHARED tie-break: signal, then id, and NOT recency. Android's
    /// statusNearbySummary uses the same two keys; adding a lastHeard key back to
    /// strongerDashboardSighting would fail this, because `older` here has the lower id and the
    /// older stamp and still has to win.
    func testStrongestTiesBreakOnIdNotRecencyAndAmbientIsFallbackOnly() throws {
        let older = try row(1, type: .tracker, rssi: -60)
        let newer = try row(2, type: .tracker, rssi: -60)
        let phone = try row(3, rssi: -10)
        XCTAssertLessThan(older.id, newer.id, "fixture assumes row 1 sorts first")
        let result = snapshot([older, newer, phone], dates: [
            older.id: now.addingTimeInterval(-30), newer.id: now, phone.id: now,
        ])
        XCTAssertEqual(result.strongest?.detection.id, older.id)
        XCTAssertEqual(result.dots.first?.detection.id, older.id)
        XCTAssertTrue(result.strongest?.matched == true)
        XCTAssertEqual(snapshot([phone]).strongest?.detection.id, phone.id)
        XCTAssertTrue(snapshot([phone]).strongest?.matched == false)
    }

    func testDisabledDetectorWithRecentEvidenceStillOpensItsLog() {
        XCTAssertFalse(dashboardTileOpensSettings(enabled: false, count: 2))
        XCTAssertTrue(dashboardTileOpensSettings(enabled: false, count: 0))
        XCTAssertFalse(dashboardTileOpensSettings(enabled: true, count: 0))
        XCTAssertFalse(dashboardTileOpensSettings(enabled: nil, count: 0))
    }

    func testLastHeardAgeIsExplicitAndTicksWithoutNewDetection() {
        XCTAssertEqual(dashboardLastHeardLabel(now, now: now, isDemoMode: false), "last heard just now")
        XCTAssertEqual(dashboardLastHeardLabel(now, now: now.addingTimeInterval(17), isDemoMode: false), "last heard 17s ago")
        XCTAssertEqual(dashboardLastHeardLabel(now.addingTimeInterval(0.01), now: now, isDemoMode: false), "last heard just now")
        XCTAssertEqual(dashboardLastHeardLabel(nil, now: now, isDemoMode: false), "last heard unknown")
    }

    func testEmptyScopeHasNoSyntheticDotsOrStrongestCard() {
        let result = snapshot([])
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.dots.isEmpty)
        XCTAssertNil(result.strongest)
        XCTAssertEqual(result.radarCaption, "0 of 0 dots · 14 max")
    }

    /// The breakdown under the radar has one owner. Every literal here is byte-identical to
    /// Android's STATUS_MATCHED_CARD_TITLE / _DETAIL, STATUS_AMBIENT_CARD_TITLE / _DETAIL and
    /// StatusNearbySummary.unclassifiedLine / watchedLine, pinned there in
    /// StatusBeaconPresentationTest. Rewording either side fails its own suite; the other side
    /// is a by-hand edit. The two lines exist only when they have something to say.
    func testNearbyBreakdownLiteralsMatchAndroidAndOnlyRenderWhenThereIsSomethingToSay() throws {
        XCTAssertEqual(DashboardSnapshot.matchedCardTitle, "MATCHED + WATCHED")
        XCTAssertEqual(DashboardSnapshot.matchedCardDetail, "signatures or exact stars")
        XCTAssertEqual(DashboardSnapshot.ambientCardTitle, "AMBIENT")
        XCTAssertEqual(DashboardSnapshot.ambientCardDetail, "Desert-mode broadcasts")

        let unknown = try row(1, type: .unknown)
        let star = try row(2)
        let full = snapshot([unknown, star], watched: [star.id])
        XCTAssertEqual(full.unclassifiedLine, "1 unclassified · category not recognized by this app")
        XCTAssertEqual(full.watchedLine, "1 watched · included in matches")

        let tracker = try row(3, type: .tracker)
        let quiet = snapshot([tracker])
        XCTAssertNil(quiet.unclassifiedLine)
        XCTAssertNil(quiet.watchedLine)
    }

    /// The six tiles, their drawn and spoken names, which types each counts and which board
    /// toggle each reads, are one list on both phones (Android STATUS_STRIP_TILES, pinned in
    /// StatusBeaconPresentationTest with the same three frames). The ALPR tile counts Raven rows,
    /// so its spoken name says so: dropping .flockRaven from `counted`, or shortening the spoken
    /// name back to "ALPR cameras", fails here. The sentence is Android's
    /// statusCountTilePresentation contentDescription, byte for byte.
    func testStripTilesMatchAndroidAndTheAlprTileCountsAndNamesRaven() throws {
        let tiles = DashboardSnapshot.stripTiles
        XCTAssertEqual(tiles.map(\.type),
                       [.flockCamera, .drone, .axonBodyCam, .tracker, .recordingGlasses, .networkCamera])
        XCTAssertEqual(tiles.map(\.label), ["ALPR", "DRONE", "BODY", "TRKR", "GLAS", "NETCAM"])
        XCTAssertEqual(tiles.map(\.spoken), [
            "ALPR cameras and Raven audio sensors", "drones", "body cameras", "trackers",
            "glasses", "network cameras",
        ])
        XCTAssertEqual(tiles[0].counted, [.flockCamera, .flockRaven])

        let camera = try row(1, type: .flockCamera)
        let raven = try row(2, type: .flockRaven)
        let drone = try row(3, type: .drone)
        let result = snapshot([camera, raven, drone])
        XCTAssertEqual(result.stripCount(tiles[0]), 2, "the ALPR tile folds Raven in")
        XCTAssertEqual(result.stripCount(tiles[1]), 1)
        XCTAssertEqual(result.stripCount(tiles[3]), 0)

        // Each tile reads its own board toggle; the ALPR tile's Raven rows ride the flock bit.
        // Every frame sets all six detector keys, because DeviceStatus defaults flock, drone and
        // glasses on and the other three off, so an absent key proves nothing. Across the three
        // frames no two tiles share an on/off pattern and no tile is on in all three or off in
        // all three, while every other Bool on the frame reads the same in all three. So pointing
        // any tile at another detector's key path, or at a non-detector Bool, fails.
        let wireKeys = ["flock", "drone", "axon", "tracker", "glasses", "ncam"]   // tile order
        let patterns: [[Bool]] = [
            [true, false, false, true, true, false],
            [false, true, false, true, false, true],
            [false, false, true, false, true, true],
        ]
        for (index, pattern) in patterns.enumerated() {
            var keys: [String: Any] = [:]
            for (key, on) in zip(wireKeys, pattern) { keys[key] = on }
            let frame = try makeStatus(ble: true, wifi: true, extra: keys)
            XCTAssertEqual(tiles.map { frame[keyPath: $0.toggle] }, pattern, "frame \(index)")
        }

        XCTAssertEqual(dashboardTileAccessibilityLabel(spoken: tiles[0].spoken, count: 2, off: false),
                       "ALPR cameras and Raven audio sensors, 2 recently heard")
        XCTAssertEqual(dashboardTileAccessibilityLabel(spoken: "trackers", count: 3, off: true),
                       "trackers, 3 recently heard, detector off")
    }

    /// ARM ORDER of the Status header, pinned with Android's statusScanPresentation
    /// (StatusBeaconPresentationTest pins the same three combinations and the framed one): link
    /// facts outrank the combined coordinator. Moving the combinedUpdateRunning arm in
    /// beaconRadioPresentation back above the isReconnecting arm fails the two reconnect cases,
    /// and above the nil-frame guard fails the first-frame gap, because each would then read
    /// "UPDATING FIRMWARE · DETECTION MAY PAUSE" under an UPDATING pill. The pill words are the
    /// ones Android's statusLinkChipLabel returns for the same four cases.
    func testStatusHeaderReadsReconnectAndFirstFrameBeforeTheRunningUpdate() throws {
        // The drop cleared the frame (didDisconnectPeripheral) and armed the reconnect while the
        // coordinator was still running.
        let reconnect = beaconRadioPresentation(
            connectionState: .connecting, sessionReady: false, isReconnecting: true,
            isDemoMode: false, status: nil, combinedUpdateRunning: true)
        XCTAssertEqual(reconnect.scanLabel, "RECONNECTING · BOARD STATUS UNAVAILABLE")
        XCTAssertEqual(reconnect.chipLabel, "RECONNECTING")
        XCTAssertFalse(reconnect.isScanning)

        // A retained frame with the nrfup bit does not change that: the reconnect wins.
        let reconnectStaleNrf = beaconRadioPresentation(
            connectionState: .connecting, sessionReady: false, isReconnecting: true,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true, coproc: false, nrfUpdating: true),
            combinedUpdateRunning: true)
        XCTAssertEqual(reconnectStaleNrf.scanLabel, "RECONNECTING · BOARD STATUS UNAVAILABLE")
        XCTAssertEqual(reconnectStaleNrf.chipLabel, "RECONNECTING")
        XCTAssertFalse(reconnectStaleNrf.isScanning)

        // Back on the link, session ready, first frame not yet in: the link fact again.
        let firstFrameGap = beaconRadioPresentation(
            connectionState: .connected, sessionReady: true, isReconnecting: false,
            isDemoMode: false, status: nil, combinedUpdateRunning: true)
        XCTAssertEqual(firstFrameGap.scanLabel, "CONNECTED · WAITING FOR BOARD STATUS")
        XCTAssertEqual(firstFrameGap.chipLabel, "WAITING")
        XCTAssertFalse(firstFrameGap.isScanning)

        // With a frame in hand the coordinator's sentence returns.
        let framed = beaconRadioPresentation(
            connectionState: .connected, sessionReady: true, isReconnecting: false,
            isDemoMode: false, status: try makeStatus(ble: true, wifi: true),
            combinedUpdateRunning: true)
        XCTAssertEqual(framed.scanLabel, "UPDATING FIRMWARE · DETECTION MAY PAUSE")
        XCTAssertEqual(framed.chipLabel, "UPDATING")
    }

    /// This app's own update reboot keeps the coordinator's line (the isRebootingForUpdate arm).
    /// The OTA engine holds the link through the reboot, so the presenter sees .connected, no
    /// session and the retained pre-reboot frame. Without the arm the sessionReady guard claims
    /// that window and `reboot` reads "FINISHING SECURE SETUP · RADIO STATUS UNAVAILABLE" under a
    /// SECURING pill, which fails the first two assertions. Android has no secure-session input, so
    /// that first case has no Android counterpart. The second is paired with the `confirming` case
    /// of Android's StatusBeaconPresentationTest statusHeaderReadsTheUpdateRebootBeforeTheMissingFrame,
    /// and the no-frame pairing is testOwnUpdateRebootOutranksTheMissingFrame below.
    func testOwnUpdateRebootKeepsTheCoordinatorLineInsteadOfSecuring() throws {
        let retainedFrame = try makeStatus(ble: true, wifi: true)
        let reboot = beaconRadioPresentation(
            connectionState: .connected, sessionReady: false, isReconnecting: false,
            isDemoMode: false, status: retainedFrame, combinedUpdateRunning: true,
            isRebootingForUpdate: true)
        XCTAssertEqual(reboot.scanLabel, "UPDATING FIRMWARE · DETECTION MAY PAUSE")
        XCTAssertEqual(reboot.chipLabel, "UPDATING")
        XCTAssertEqual(reboot.detail,
                       "Keep the app open and the beacon nearby until the update finishes.")
        XCTAssertFalse(reboot.isScanning)

        // Reconnected but not yet confirmed: the session is back and `status` still holds the
        // pre-reboot frame. The arm does not lean on the coordinator's flag, so that frame cannot
        // speak for the radios even with the flag down; without the arm this reads
        // "SCANNING · BLE · WI-FI".
        let confirming = beaconRadioPresentation(
            connectionState: .connected, sessionReady: true, isReconnecting: false,
            isDemoMode: false, status: retainedFrame, combinedUpdateRunning: false,
            isRebootingForUpdate: true)
        XCTAssertEqual(confirming.scanLabel, "UPDATING FIRMWARE · DETECTION MAY PAUSE")
        XCTAssertFalse(confirming.isScanning)
    }

    /// The update reboot outranks the missing frame, paired with the `gap` and `reconnect` cases of
    /// Android's StatusBeaconPresentationTest statusHeaderReadsTheUpdateRebootBeforeTheMissingFrame.
    /// This app keeps the pre-reboot frame through its own reboot, so the nil frame is Android's
    /// shape: its reboot drop clears the frame and its reconnect lands READY before the first one.
    /// The case pins that both presenters rank the reboot above the nil-frame guard. Without the
    /// isRebootingForUpdate arm, or with it moved below that guard, `gap` reads "CONNECTED ·
    /// WAITING FOR BOARD STATUS" under a WAITING pill and fails the first two assertions. Moving
    /// the arm above the isReconnecting arm fails the last one.
    func testOwnUpdateRebootOutranksTheMissingFrame() {
        let gap = beaconRadioPresentation(
            connectionState: .connected, sessionReady: true, isReconnecting: false,
            isDemoMode: false, status: nil, combinedUpdateRunning: true,
            isRebootingForUpdate: true)
        XCTAssertEqual(gap.scanLabel, "UPDATING FIRMWARE · DETECTION MAY PAUSE")
        XCTAssertEqual(gap.chipLabel, "UPDATING")
        XCTAssertFalse(gap.isScanning)

        // The presenter still ranks the reconnect first, as Android's does.
        let reconnect = beaconRadioPresentation(
            connectionState: .connecting, sessionReady: false, isReconnecting: true,
            isDemoMode: false, status: nil, combinedUpdateRunning: true,
            isRebootingForUpdate: true)
        XCTAssertEqual(reconnect.chipLabel, "RECONNECTING")
    }

    /// The recency kicker is built from activeNearbyInterval, the window this snapshot drops
    /// quiet rows with (testRecentWindowExcludesHistoryStaleAndUndatedRows pins that boundary at
    /// 45 s). Byte-identical to Android's STATUS_SEEN_WINDOW_KICKER, built from
    /// ACTIVE_NEARBY_WINDOW_MS and pinned in StatusBeaconPresentationTest, so retuning either
    /// window fails on the side that moved.
    func testSeenWindowKickerNamesTheFreshnessWindow() {
        XCTAssertEqual(DashboardSnapshot.seenWindowKicker, "SEEN < 45s")
    }

    private func makeStatus(ble: Bool, wifi: Bool, coproc: Bool? = nil, nrfUpdating: Bool? = nil,
                            extra: [String: Any] = [:]) throws -> DeviceStatus {
        var object: [String: Any] = ["fw": "beacon board", "ble": ble, "wifi": wifi]
        if let coproc { object["co"] = coproc }
        if let nrfUpdating { object["nrfup"] = nrfUpdating }
        for (key, value) in extra { object[key] = value }
        return try JSONDecoder().decode(
            DeviceStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
