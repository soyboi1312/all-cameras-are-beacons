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

    /// The Log's first time-section header is built from activeNearbyInterval, so retuning the
    /// window moves the copy with it; this pins the shipped number.
    /// TWIN: Android StatusBeaconPresentationTest.activeSectionHeaderNamesTheWindow.
    func testActiveSectionHeaderNamesTheWindow() {
        XCTAssertEqual(BLEManager.activeSectionHeader, "heard in the last 45 s")
    }

    /// The first-zero line (C9) exists only for a connected, real, scanning, empty session, and
    /// it IS FirstRunTour.quietSentence, not a copy. Android pins the same cases in
    /// StatusRadarScopeSemanticsTest.firstZeroLineOnlyForAConnectedEmptyRealSession.
    func testFirstZeroLineOnlyForAConnectedEmptyRealSession() {
        XCTAssertEqual(statusFirstZeroLine(connected: true, isDemoMode: false, scanning: true, total: 0),
                       FirstRunTour.quietSentence)
        XCTAssertNil(statusFirstZeroLine(connected: true, isDemoMode: true, scanning: true, total: 0))
        XCTAssertNil(statusFirstZeroLine(connected: true, isDemoMode: false, scanning: true, total: 1))
        XCTAssertNil(statusFirstZeroLine(connected: false, isDemoMode: false, scanning: true, total: 0))
    }

    /// The false all-clear (STA-1): a connected board with both radios switched off, 0 nearby.
    /// The quiet sentence ("zero nearby means no supported broadcast was recognized ...") must not
    /// stand under the parked sweep; the slot says why the board is not scanning instead, in the
    /// radio presentation's own words. Wrong input: before the scanning gate this returned the
    /// quiet sentence. TWIN: android StatusRadarScopeSemanticsTest's not-scanning case.
    func testRadiosOffZeroShowsWhyNotTheQuietSentence() throws {
        let status = try makeStatus(ble: false, wifi: false)
        let radio = beaconRadioPresentation(connectionState: .connected, sessionReady: true,
            isReconnecting: false, isDemoMode: false, status: status, combinedUpdateRunning: false)
        XCTAssertFalse(radio.isScanning)
        XCTAssertNil(statusFirstZeroLine(connected: true, isDemoMode: false,
                                         scanning: radio.isScanning, total: 0))
        XCTAssertEqual(statusNotScanningLine(connected: true, isDemoMode: false,
                                             scanning: radio.isScanning, total: 0,
                                             detail: radio.detail),
                       "Both beacon detection radios are switched off.")
        // The not-scanning line never doubles the quiet sentence, a sample session or a count.
        XCTAssertNil(statusNotScanningLine(connected: true, isDemoMode: false, scanning: true,
                                           total: 0, detail: radio.detail))
        XCTAssertNil(statusNotScanningLine(connected: true, isDemoMode: true, scanning: false,
                                           total: 0, detail: radio.detail))
        XCTAssertNil(statusNotScanningLine(connected: true, isDemoMode: false, scanning: false,
                                           total: 2, detail: radio.detail))
        XCTAssertNil(statusNotScanningLine(connected: false, isDemoMode: false, scanning: false,
                                           total: 0, detail: radio.detail))
    }

    /// STA-2: two dots that hash to the same ring and the same angle (two MACs with one hash
    /// bucket) must not draw on top of each other. The priority dot (index 0) keeps its hash
    /// angle; the second steps along the ring until it is at least one dot diameter away.
    /// Wrong input: without the step both centres are the same point (distance 0).
    /// TWIN: android StatusRadarScopeSemanticsTest's radarDotPositions case.
    func testRadarDotsOnOneRingAndAngleComeOutOneDiameterApart() {
        let c = CGPoint(x: 179, y: 179)
        let ring: CGFloat = 358.0 / 6.0   // the STRONG ring of a 358pt scope
        let r = RadarScope.dotSize / 2
        let placed = RadarScope.dotPositions(angles: [40, 40, 40], ringRadii: [ring, ring, ring],
                                             centre: c, dotRadius: r, obstacles: [])
        XCTAssertEqual(placed.count, 3)
        // The priority dot keeps its home.
        XCTAssertEqual(placed[0].x, c.x + CGFloat(cos(40.0 * .pi / 180)) * ring, accuracy: 0.001)
        XCTAssertEqual(placed[0].y, c.y + CGFloat(sin(40.0 * .pi / 180)) * ring, accuracy: 0.001)
        for i in 0..<placed.count {
            // Every dot stays on its own ring.
            XCTAssertEqual(hypot(placed[i].x - c.x, placed[i].y - c.y), ring, accuracy: 0.001)
            for j in 0..<i {
                XCTAssertGreaterThanOrEqual(
                    hypot(placed[i].x - placed[j].x, placed[i].y - placed[j].y), 2 * r,
                    "dots \(j) and \(i) overlap")
            }
        }
    }

    /// STA-2: a dot whose hash spot is under an obstacle frame (the TOTAL NEARBY caption's bare
    /// text frame here; the words carry no plate since R18) steps clear of it, and a ring with no
    /// clear spot keeps the hash angle instead of dropping the dot.
    func testRadarDotStepsOffAnObstacleAndAFullRingKeepsItsHome() {
        let c = CGPoint(x: 100, y: 100)
        let r = RadarScope.dotSize / 2
        // A text frame straddling the ring at 90 degrees (straight down from the centre).
        let caption = CGRect(x: 80, y: 140, width: 40, height: 30)
        let placed = RadarScope.dotPositions(angles: [90], ringRadii: [50], centre: c,
                                             dotRadius: r, obstacles: [caption])
        let p = placed[0]
        let nx = min(max(p.x, caption.minX), caption.maxX) - p.x
        let ny = min(max(p.y, caption.minY), caption.maxY) - p.y
        XCTAssertGreaterThanOrEqual(hypot(nx, ny), r, "the dot still touches the caption")
        XCTAssertEqual(hypot(p.x - c.x, p.y - c.y), 50, accuracy: 0.001)
        // An obstacle that covers the whole disc: nowhere is clear, so the dot keeps its home.
        let full = RadarScope.dotPositions(angles: [90], ringRadii: [50], centre: c, dotRadius: r,
                                           obstacles: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        XCTAssertEqual(full[0].x, 100, accuracy: 0.001)
        XCTAssertEqual(full[0].y, 150, accuracy: 0.001)
    }

    /// J7: the FAQ's "Replay the setup checklist" with no live board (sample data or no link, so no
    /// frame) is a preview, which draws the preview line and neutral rows instead of unticked
    /// checks. A replay with a live frame, and the real post-connect sheet, are never previews.
    /// Wrong input: before the gate the frameless replay drew empty check circles under "your
    /// beacon is listening". TWIN: android FirstRunTour's checklistIsPreview test.
    func testChecklistReplayWithoutABoardIsAPreview() throws {
        let frame = try makeStatus(ble: true, wifi: true)
        XCTAssertTrue(checklistIsPreview(replay: true, frame: nil))
        XCTAssertFalse(checklistIsPreview(replay: true, frame: frame))
        XCTAssertFalse(checklistIsPreview(replay: false, frame: nil))
        XCTAssertFalse(checklistIsPreview(replay: false, frame: frame))
        XCTAssertEqual(renderBoardCopy(FirstRunTour.checklistPreviewNote, nil),
                       "preview: this is what you see after your beacon connects.")
        XCTAssertEqual(renderBoardCopy(FirstRunTour.checklistPreviewNote, .ouiSpy),
                       "preview: this is what you see after your OUI-Spy connects.")
        XCTAssertEqual(renderBoardCopy(FirstRunTour.checklistPreviewNote, .meshDetect),
                       "preview: this is what you see after your Mesh-Detect connects.")
    }

    /// The quiet sentence names the Active window through the constant, not a literal. Android:
    /// StatusBeaconPresentationTest.quietSentenceNamesTheWindow.
    func testQuietSentenceNamesTheWindow() {
        XCTAssertTrue(FirstRunTour.quietSentence.hasPrefix("quiet does not mean clear. zero nearby means"))
        XCTAssertTrue(FirstRunTour.quietSentence.contains("in the last 45 seconds."))
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

    /// U1-d: Status drops the bare SAMPLE DATA telegram in sample data (the banner, the pill and
    /// the row say sample already) and keeps the radio variants and every live label.
    /// Wrong input: hiding every sample label. TWIN: android StatusBeaconPresentationTest.
    func testSampleDataHidesOnlyTheBareScanKicker() {
        XCTAssertNil(dashboardScanKicker(scanLabel: "SAMPLE DATA", isDemoMode: true))
        XCTAssertEqual(dashboardScanKicker(scanLabel: "SAMPLE DATA · BLUETOOTH ONLY", isDemoMode: true),
                       "SAMPLE DATA · BLUETOOTH ONLY")
        XCTAssertEqual(dashboardScanKicker(scanLabel: "SAMPLE DATA · RADIOS OFF", isDemoMode: true),
                       "SAMPLE DATA · RADIOS OFF")
        XCTAssertEqual(dashboardScanKicker(scanLabel: "SCANNING · BLE · WI-FI", isDemoMode: false),
                       "SCANNING · BLE · WI-FI")
    }

    /// U1-d: the strongest header carries no suffix in sample data and "· RECENT" in a real
    /// session. Wrong input: the old "· SAMPLE" suffix. TWIN: android StatusBeaconPresentationTest.
    func testStrongestHeaderDropsTheSuffixInSampleData() {
        XCTAssertEqual(dashboardStrongestHeader(kind: "MATCH", isDemoMode: true), "STRONGEST MATCH")
        XCTAssertEqual(dashboardStrongestHeader(kind: "MATCH", isDemoMode: false),
                       "STRONGEST MATCH · RECENT")
        XCTAssertEqual(dashboardStrongestHeader(kind: "AMBIENT", isDemoMode: true), "STRONGEST AMBIENT")
    }

    /// M3: the sweep angle is fract(t / 4.5 s) x 360 of an ABSOLUTE clock reading. A beam that is
    /// re-created (a re-mount, a tab return, a scanning flicker) reads the same absolute time as
    /// the one it replaced, so at t = 10 s it reads 80 degrees, where a beam timed from its own
    /// mount would restart at 0. Wrong input: an angle from a per-view start time.
    /// TWIN: android StatusRadarScopeSemanticsTest (radarSweepDegrees, 4_500 ms).
    func testRadarSweepAngleComesFromTheAbsoluteClock() {
        XCTAssertEqual(RadarScope.sweepPeriod, 4.5)
        // The FIRST reading is a real reference-date clock, mid-turn: a beam that takes its own
        // first frame as 0 (a per-view start time) reads 0 here instead of 220.
        XCTAssertEqual(radarSweepDegrees(at: 780_000_010.25), 220, accuracy: 1e-3,
                       "a new beam joins the turn already in progress")
        XCTAssertEqual(radarSweepDegrees(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(radarSweepDegrees(at: 2.25), 180, accuracy: 1e-9)
        XCTAssertEqual(radarSweepDegrees(at: 4.5), 0, accuracy: 1e-9)
        XCTAssertEqual(radarSweepDegrees(at: 10.0), 80, accuracy: 1e-6)
        XCTAssertEqual(radarSweepDegrees(at: -1.125), 270, accuracy: 1e-9)
        // Continuity: the beam before a re-mount and the beam after it, read at the same absolute
        // time, agree, and a later frame moves forward from there (a real reference-date clock).
        let t = 780_000_010.25
        let before = radarSweepDegrees(at: t)
        let after = radarSweepDegrees(at: t)
        XCTAssertEqual(before, after)
        XCTAssertEqual(radarSweepDegrees(at: t + 0.2) - before, 16, accuracy: 1e-3,
                       "0.2 s of a 4.5 s turn is 16 degrees further on")
    }

    /// M2: the tab roots draw one header row below the accessibility sizes and fall back to the
    /// system bar at them. Wrong input: always true (the title would clip at AX sizes).
    func testTabHeaderIsOneRowOnlyBelowAccessibilitySizes() {
        XCTAssertTrue(tabHeaderUsesSingleRow(.large))
        XCTAssertTrue(tabHeaderUsesSingleRow(.xLarge))
        XCTAssertTrue(tabHeaderUsesSingleRow(.xxxLarge))
        XCTAssertFalse(tabHeaderUsesSingleRow(.accessibility1))
        XCTAssertFalse(tabHeaderUsesSingleRow(.accessibility5))
    }

    /// The owner dropped the middle ring's word (2026-09-25): the radar labels only the inner ring
    /// STRONG and the disc edge WEAK, and the dots still snap to all three rings. Wrong input that
    /// must fail here: putting ("GOOD", 2) back into RadarScope.ringWords. TWIN: android
    /// StatusRadarScopeSemanticsTest.radarRingWordsAreStrongAndWeakOnly.
    func testRadarRingWordsAreStrongAndWeakOnly() {
        XCTAssertEqual(RadarScope.ringWords.map { $0.word }, ["STRONG", "WEAK"])
        XCTAssertEqual(RadarScope.ringWords.map { $0.ring }, [1, 3])
    }

    /// The owner cut the Status radar by about a quarter (2026-09-25, decisions R12): its side is
    /// 0.75 of the content column, capped at 315 (0.75 x the old 420 cap). The literals are
    /// asserted, not the constants against themselves: the rule is SHARED with Android
    /// (STATUS_RADAR_SIDE_FRACTION, STATUS_RADAR_MAX_SIDE, statusRadarSide). Wrong input that must
    /// fail here: the old whole-column side (fraction 1, cap 420), which is 358 on a 390pt phone's
    /// 358pt column. TWIN: android StatusRadarScopeSemanticsTest
    /// .radarSideIsThreeQuartersOfTheColumnCappedAt315.
    func testRadarSideIsThreeQuartersOfTheColumnCappedAt315() {
        XCTAssertEqual(RadarSideLayout.fraction, 0.75)
        XCTAssertEqual(RadarSideLayout.cap, 315)
        XCTAssertEqual(RadarSideLayout.side(column: 358), 268.5, accuracy: 0.001)   // 390pt phone
        XCTAssertEqual(RadarSideLayout.side(column: 420), 315, accuracy: 0.001)     // exactly the cap
        XCTAssertEqual(RadarSideLayout.side(column: 800), 315, accuracy: 0.001)     // iPad column
        XCTAssertEqual(RadarSideLayout.side(column: .infinity), 315)                // ideal-size query
        XCTAssertEqual(RadarSideLayout.side(column: 0), 0)
    }
}
