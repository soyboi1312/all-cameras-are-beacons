import XCTest
@testable import Beacons

/// Pins the board-kind naming (Models/BoardKind.swift): the model, the precedence, the remembered
/// record's kind rules (RememberedBoard.swift) and every per-kind rendering of the connect-screen
/// copy. The expected strings are the iOS column of the owner-approved wording table (38 rows,
/// OUI-Spy plan, 2026-09-25): the beacon renderings are today's beacon text, except the connect
/// surfaces the plan settled to one string shared with Android. Every store touch goes to a
/// throwaway UserDefaults suite created and removed here, never the install.
/// Android twin: BoardKindTest (same fixtures, Android's pairing words).
final class BoardKindTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private let boardA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let boardB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUp() {
        super.setUp()
        suiteName = "tech.beacons.tests.boardKind.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: model

    /// The stored raw values are a wire contract with the Android twin and with every install that
    /// already wrote one; renaming a case must fail here.
    func testRawValuesAreTheStoredContract() {
        XCTAssertEqual(BoardKind.allCases.map(\.rawValue), ["beacon", "ouiSpy", "meshDetect"])
    }

    func testFirmwareLabelIsAuthoritative() {
        XCTAssertEqual(BoardKind.fromFirmwareLabel("beacon board"), .beacon)
        XCTAssertEqual(BoardKind.fromFirmwareLabel("beacon board rev-B"), .beacon)
        XCTAssertEqual(BoardKind.fromFirmwareLabel("ACAB-ouispy"), .ouiSpy)
        XCTAssertEqual(BoardKind.fromFirmwareLabel("mesh-detect-ACAB"), .meshDetect)
        XCTAssertEqual(BoardKind.fromFirmwareLabel("mesh-detect-ACAB-ch1"), .meshDetect)
        XCTAssertNil(BoardKind.fromFirmwareLabel(""))
        XCTAssertNil(BoardKind.fromFirmwareLabel("odid-sim"))
        XCTAssertNil(BoardKind.fromFirmwareLabel(nil))
        // The label the Status frame carries is DeviceStatus.firmwareLabel, version stripped.
        let status = try? JSONDecoder().decode(DeviceStatus.self,
                                               from: Data(#"{"fw":"ACAB-ouispy 2.0.9"}"#.utf8))
        XCTAssertEqual(BoardKind.fromFirmwareLabel(status?.firmwareLabel), .ouiSpy)
    }

    /// Only a REAL advertised name is a hint. The app's own "ACAB" fallback never reaches this
    /// function (BLEManager.didDiscover passes the advert key alone), which is why "ACAB" can mean
    /// OUI-Spy here; a nameless advert is nil.
    func testAdvertNameIsOnlyAHint() {
        XCTAssertEqual(BoardKind.fromAdvertName("beacon"), .beacon)
        XCTAssertEqual(BoardKind.fromAdvertName("ACAB"), .ouiSpy)
        XCTAssertEqual(BoardKind.fromAdvertName("ACAB-mesh"), .meshDetect)
        XCTAssertEqual(BoardKind.fromAdvertName("ACAB-mes"), .meshDetect, "the shortened primary advert")
        XCTAssertNil(BoardKind.fromAdvertName(nil), "a nameless advert never reads as an OUI-Spy")
        XCTAssertNil(BoardKind.fromAdvertName(""))
        XCTAssertNil(BoardKind.fromAdvertName("ACAB-01"))
        XCTAssertNil(BoardKind.fromAdvertName("AdaDFU"))
        XCTAssertNil(BoardKind.fromAdvertName("beacons"))
    }

    /// The DEBUG hook's synthetic name and label must read back as the kind they stand for, or a
    /// `-boardKind ouiSpy` screenshot would show beacon copy.
    func testSampleNameAndLabelReadBackAsTheirKind() {
        for kind in BoardKind.allCases {
            XCTAssertEqual(BoardKind.fromAdvertName(kind.advertisedName), kind)
            XCTAssertEqual(BoardKind.fromFirmwareLabel(kind.sampleFirmwareLabel), kind)
        }
        XCTAssertEqual(BoardKind.beacon.sampleFirmwareLabel, "beacon board",
                       "the sample frame outside the hook keeps today's label")
    }

    func testNounTable() {
        XCTAssertEqual(BoardKind.allCases.map(\.noun), ["beacon", "OUI-Spy", "Mesh-Detect"])
        XCTAssertEqual(BoardKind.allCases.map(\.aNoun), ["a beacon", "an OUI-Spy", "a Mesh-Detect"])
        XCTAssertEqual(BoardKind.allCases.map(\.plural), ["beacons", "OUI-Spy", "Mesh-Detect"])
        XCTAssertEqual(BoardKind.allCases.map(\.upperNoun), ["BEACON", "OUI-SPY", "MESH-DETECT"])
        XCTAssertEqual(BoardKind.allCases.map(\.heroTitle),
                       ["All Cameras Are Beacons", "OUI-Spy", "Mesh-Detect"])
    }

    func testHeroTitleReadsUnknownAsTheBeacon() {
        XCTAssertEqual(boardHeroTitle(nil), "All Cameras Are Beacons")
        XCTAssertEqual(boardHeroTitle(.beacon), "All Cameras Are Beacons")
        XCTAssertEqual(boardHeroTitle(.ouiSpy), "OUI-Spy")
        XCTAssertEqual(boardHeroTitle(.meshDetect), "Mesh-Detect")
    }

    // MARK: precedence

    func testBoardPrecedenceIsFirmwareThenLiveHintThenStored() {
        XCTAssertEqual(resolveBoardKind(firmwareLabel: "mesh-detect-ACAB", storedKind: .ouiSpy,
                                        advertHint: .beacon), .meshDetect, "the fw label wins")
        XCTAssertEqual(resolveBoardKind(firmwareLabel: "odid-sim", storedKind: .ouiSpy,
                                        advertHint: .beacon), .beacon,
                       "a label that names no kind falls through to the live hint")
        XCTAssertEqual(resolveBoardKind(firmwareLabel: "odid-sim", storedKind: .ouiSpy,
                                        advertHint: nil), .ouiSpy,
                       "and with no hint to the stored kind")
        XCTAssertEqual(resolveBoardKind(firmwareLabel: nil, storedKind: nil, advertHint: .meshDetect),
                       .meshDetect)
        XCTAssertEqual(resolveBoardKind(firmwareLabel: nil, storedKind: .meshDetect, advertHint: nil),
                       .meshDetect, "the stealth advert (no name): the stored kind alone")
        XCTAssertNil(resolveBoardKind(firmwareLabel: nil, storedKind: nil, advertHint: nil))
        // The app fallback name with no real advert name: DiscoveredDevice carries no hint.
        XCTAssertNil(resolveBoardKind(firmwareLabel: nil, storedKind: nil,
                                      advertHint: BoardKind.fromAdvertName(nil)))
    }

    /// A remembered board reflashed with another image keeps its bond, so its stored kind is the
    /// OLD image's until the next ready session stamps the new one. A real live advert naming the
    /// other kind wins before connect, in both directions; the `fw` label still wins after connect
    /// and re-stamps the store; a nameless (stealth) advert leaves the stored kind in charge.
    func testReflashedRememberedBoardReadsItsLiveAdvertBothWays() {
        for (stored, live) in [(BoardKind.beacon, BoardKind.ouiSpy), (.ouiSpy, .beacon),
                               (.ouiSpy, .meshDetect), (.meshDetect, .ouiSpy)] {
            let remembered = RememberedBoard(id: boardA, name: "ACAB", kind: stored)
            let sighting = BoardPickerEntry(id: boardA, name: "ACAB", rssi: -50, firmware: nil,
                                            isRemembered: false, kind: live)
            // Before connect: the remembered row, the kind the precedence gives, and the screen.
            let row = mergeBoardPickerEntries(remembered: remembered, rememberedRetrieved: true,
                                              scanned: [sighting])
            XCTAssertEqual(row.first.map(boardPickerRowTitle), "your \(live.noun)",
                           "stored \(stored), advertising \(live)")
            let preConnect = resolveBoardKind(firmwareLabel: nil, storedKind: stored, advertHint: live)
            XCTAssertEqual(preConnect, live)
            XCTAssertEqual(resolveScreenKind(targetActive: false, targetKind: nil,
                                             rememberedKind: preConnect, rowKinds: row.map(\.kind)),
                           live)
            XCTAssertEqual(renderBoardCopy(ConnectCopy.setupSentence, preConnect),
                           renderBoardCopy(ConnectCopy.setupSentence, live))
            // After connect the fw label wins over both, and re-stamps the stored kind.
            let fw = live.sampleFirmwareLabel
            XCTAssertEqual(resolveBoardKind(firmwareLabel: fw, storedKind: stored, advertHint: stored),
                           live, "the fw label outranks a hint and the store")
            XCTAssertEqual(rememberedBoardAfterStatusFrame(current: remembered, frameBoardID: boardA,
                                                           firmwareLabel: fw, sessionReady: true,
                                                           isDemoMode: false)?.kind, live)
            // The stealth advert: no name, so the stored kind names the board.
            XCTAssertEqual(resolveBoardKind(firmwareLabel: nil, storedKind: stored,
                                            advertHint: BoardKind.fromAdvertName(nil)), stored)
        }
    }

    func testScreenKindRules() {
        // The target wins while it is active, even over a known remembered board, nil included.
        XCTAssertEqual(resolveScreenKind(targetActive: true, targetKind: .meshDetect,
                                         rememberedKind: .ouiSpy, rowKinds: [.beacon]), .meshDetect)
        XCTAssertNil(resolveScreenKind(targetActive: true, targetKind: nil,
                                       rememberedKind: .ouiSpy, rowKinds: [.ouiSpy]))
        // Then the remembered board.
        XCTAssertEqual(resolveScreenKind(targetActive: false, targetKind: .meshDetect,
                                         rememberedKind: .ouiSpy, rowKinds: [.beacon]), .ouiSpy)
        // Then every row agreeing.
        XCTAssertEqual(resolveScreenKind(targetActive: false, targetKind: nil, rememberedKind: nil,
                                         rowKinds: [.ouiSpy, .ouiSpy]), .ouiSpy)
        // A mixed scan, a row with no hint, and an empty scan all stay beacon (nil).
        XCTAssertNil(resolveScreenKind(targetActive: false, targetKind: nil, rememberedKind: nil,
                                       rowKinds: [.ouiSpy, .beacon]))
        XCTAssertNil(resolveScreenKind(targetActive: false, targetKind: nil, rememberedKind: nil,
                                       rowKinds: [.ouiSpy, nil]))
        XCTAssertNil(resolveScreenKind(targetActive: false, targetKind: nil, rememberedKind: nil,
                                       rowKinds: [nil, .ouiSpy]))
        XCTAssertNil(resolveScreenKind(targetActive: false, targetKind: nil, rememberedKind: nil,
                                       rowKinds: []))
    }

    // MARK: remembered record

    func testStoreRoundTripsTheKindAndForgetRemovesIt() {
        let store = RememberedBoardStore(defaults: defaults)
        store.save(RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy))
        XCTAssertEqual(store.load(), RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy))
        XCTAssertEqual(defaults.string(forKey: RememberedBoardStore.kindKey), "ouiSpy")
        XCTAssertEqual(RememberedBoardStore.kindKey, "rememberedBoardKind")
        // A record saved without a kind drops a kind left from an earlier board.
        store.save(RememberedBoard(id: boardB, name: "beacon"))
        XCTAssertNil(defaults.object(forKey: RememberedBoardStore.kindKey))
        store.save(RememberedBoard(id: boardA, name: "ACAB", kind: .meshDetect))
        store.save(nil)
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: RememberedBoardStore.kindKey), "forget clears the kind too")
    }

    /// Migration: every install before the key, and a value this build does not know, load nil.
    func testOldOrUnknownKindLoadsNil() {
        defaults.set(boardA.uuidString, forKey: RememberedBoardStore.idKey)
        defaults.set("ACAB", forKey: RememberedBoardStore.nameKey)
        XCTAssertEqual(RememberedBoardStore(defaults: defaults).load(),
                       RememberedBoard(id: boardA, name: "ACAB"),
                       "no key: nil, and never inferred from the stored name")
        defaults.set("colonelPanic", forKey: RememberedBoardStore.kindKey)
        XCTAssertNil(RememberedBoardStore(defaults: defaults).load()?.kind)
    }

    func testSecureReadyKeepsTheKindForTheSameBoardAndResetsItForAnother() {
        let stored = RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy)
        XCTAssertNil(rememberedBoardAfterSecureReady(current: stored, readyID: boardA, readyName: "ACAB"),
                     "the same board keeps its kind and writes nothing")
        XCTAssertEqual(rememberedBoardAfterSecureReady(current: stored, readyID: boardA,
                                                       readyName: "ACAB-2"),
                       RememberedBoard(id: boardA, name: "ACAB-2", kind: .ouiSpy))
        XCTAssertEqual(rememberedBoardAfterSecureReady(current: stored, readyID: boardB,
                                                       readyName: "beacon"),
                       RememberedBoard(id: boardB, name: "beacon"),
                       "a different board starts with no kind until its first frame")
    }

    func testFirstFrameStampsOnceAndOnlyForTheRememberedReadyBoard() {
        let unknown = RememberedBoard(id: boardA, name: "ACAB")
        func stamp(_ current: RememberedBoard?, id: UUID? = nil, label: String = "ACAB-ouispy",
                   ready: Bool = true, demo: Bool = false) -> RememberedBoard? {
            rememberedBoardAfterStatusFrame(current: current, frameBoardID: id ?? boardA,
                                            firmwareLabel: label, sessionReady: ready,
                                            isDemoMode: demo)
        }
        XCTAssertEqual(stamp(unknown), RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy))
        XCTAssertNil(stamp(RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy)),
                     "an unchanged kind writes nothing, so a 1 Hz stream writes once")
        XCTAssertEqual(stamp(RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy),
                             label: "beacon board")?.kind, .beacon, "a reflashed board restamps")
        XCTAssertNil(stamp(unknown, demo: true), "sample data never stamps")
        XCTAssertNil(stamp(unknown, ready: false), "only a ready session stamps")
        XCTAssertNil(stamp(unknown, id: boardB), "another board's frame never stamps")
        XCTAssertNil(stamp(unknown, label: "odid-sim"), "a label that names no kind stamps nothing")
        XCTAssertNil(stamp(nil), "nothing remembered, nothing to stamp")
    }

    /// A ready session's kind-naming `fw` label retires the connected row's pre-session hint, so
    /// after a drop that stale sighting cannot outrank the kind the label just stamped.
    func testReadyFrameRetiresThePreSessionHint() {
        func retires(_ label: String = "ACAB-ouispy", hint: BoardKind? = .beacon,
                     ready: Bool = true, demo: Bool = false) -> Bool {
            statusFrameRetiresKindHint(firmwareLabel: label, rowHint: hint, sessionReady: ready,
                                       isDemoMode: demo)
        }
        XCTAssertTrue(retires(), "a reflashed board's old sighting goes once the label names it")
        XCTAssertTrue(retires(hint: .ouiSpy), "a matching hint goes too: the stamp now carries it")
        XCTAssertFalse(retires(hint: nil), "no hint, nothing to retire")
        XCTAssertFalse(retires(ready: false), "only a ready session's frame retires it")
        XCTAssertFalse(retires(demo: true), "sample data never retires it")
        XCTAssertFalse(retires("odid-sim"), "a label that names no kind keeps the hint")
        XCTAssertFalse(retires(""), "an empty label keeps the hint")
    }

    func testMergedRowTakesTheLiveHintThenTheStoredKind() {
        let scannedOuiSpy = BoardPickerEntry(id: boardA, name: "ACAB", rssi: -50, firmware: nil,
                                             isRemembered: false, kind: .ouiSpy)
        let reflashed = mergeBoardPickerEntries(
            remembered: RememberedBoard(id: boardA, name: "beacon", kind: .meshDetect),
            rememberedRetrieved: true, scanned: [scannedOuiSpy])
        XCTAssertEqual(reflashed.map(\.kind), [.ouiSpy],
                       "a reflashed board reads as what it advertises now, not the stored kind")
        XCTAssertEqual(reflashed.first.map(boardPickerRowTitle), "your OUI-Spy")
        let nameless = BoardPickerEntry(id: boardA, name: "ACAB", rssi: -50, firmware: nil,
                                        isRemembered: false, kind: nil)
        let stealth = mergeBoardPickerEntries(
            remembered: RememberedBoard(id: boardA, name: "ACAB", kind: .meshDetect),
            rememberedRetrieved: true, scanned: [nameless])
        XCTAssertEqual(stealth.map(\.kind), [.meshDetect],
                       "a sighting with no name (the stealth advert) keeps the stored kind")
        let unknown = mergeBoardPickerEntries(
            remembered: RememberedBoard(id: boardA, name: "ACAB"),
            rememberedRetrieved: true, scanned: [scannedOuiSpy])
        XCTAssertEqual(unknown.map(\.kind), [.ouiSpy], "no stored kind: the live hint")
        let noAdvert = mergeBoardPickerEntries(
            remembered: RememberedBoard(id: boardA, name: "ACAB", kind: .ouiSpy),
            rememberedRetrieved: true, scanned: [])
        XCTAssertEqual(noAdvert.map(\.kind), [.ouiSpy], "the stealth case: the stored kind alone")
    }

    /// The manager resolves the remembered row's kind from its injected store at launch.
    func testManagerReadsTheStoredKind() {
        RememberedBoardStore(defaults: defaults).save(RememberedBoard(id: boardA, name: "ACAB",
                                                                      kind: .ouiSpy))
        let ble = BLEManager(defaults: defaults)
        XCTAssertEqual(ble.rememberedKind, .ouiSpy)
        XCTAssertNil(ble.targetKind, "no connect has begun")
    }

    #if DEBUG
    /// DEBUG `-boardKind`: the parse accepts the three raw values only, and without `-demo` the
    /// display row lives in memory: the picker and the kinds read it, the store never does.
    func testDebugBoardKindHook() {
        XCTAssertEqual(boardKindLaunchArgument(["Beacons", "-boardKind", "ouiSpy"]), .ouiSpy)
        XCTAssertEqual(boardKindLaunchArgument(["-boardKind", "meshDetect", "-demo"]), .meshDetect)
        XCTAssertEqual(boardKindLaunchArgument(["-boardKind", "beacon"]), .beacon)
        XCTAssertNil(boardKindLaunchArgument(["-boardKind", "OUI-Spy"]))
        XCTAssertNil(boardKindLaunchArgument(["-boardKind"]), "a flag with no value reads nothing")
        XCTAssertNil(boardKindLaunchArgument([]))

        let ble = BLEManager(defaults: defaults)
        ble.applyDebugBoardKind(.meshDetect, demo: false)
        XCTAssertEqual(ble.pickerEntries.count, 1)
        XCTAssertEqual(ble.pickerEntries.first?.isRemembered, true)
        XCTAssertNil(ble.pickerEntries.first?.rssi, "no live signal")
        XCTAssertEqual(ble.pickerEntries.first.map(boardPickerRowTitle), "your Mesh-Detect")
        XCTAssertEqual(ble.rememberedKind, .meshDetect)
        XCTAssertNil(ble.rememberedBoard, "the real record is untouched")
        XCTAssertNil(RememberedBoardStore(defaults: defaults).load(), "nothing reaches UserDefaults")

        let demo = BLEManager(defaults: defaults)
        demo.applyDebugBoardKind(.ouiSpy, demo: true)
        XCTAssertTrue(demo.pickerEntries.isEmpty, "with -demo the hook only swaps the sample label")
    }
    #endif

    #if DEBUG
    /// DEBUG `-bluetoothIdle`: the parse, then a manager built under it rests on the idle,
    /// Bluetooth-allowed state and never creates its CBCentralManager. Without the hook's gate in
    /// initializeCentral, the launch path and the Scan for Beacons tap below would both create one,
    /// which parks the state on .unknown (the simulator's "Starting Bluetooth...").
    func testDebugBluetoothIdleHook() {
        XCTAssertTrue(bluetoothIdleLaunchArgument(["Beacons", "-bluetoothIdle"]))
        XCTAssertTrue(bluetoothIdleLaunchArgument(["-bluetoothIdle", "-boardKind", "ouiSpy"]))
        XCTAssertFalse(bluetoothIdleLaunchArgument(["Beacons", "-demo"]))
        XCTAssertFalse(bluetoothIdleLaunchArgument([]))
        XCTAssertFalse(bluetoothIdleLaunchArgument(["-bluetoothidle"]), "the flag is exact")

        let saved = BLEManager.debugBluetoothIdleAtLaunch
        defer { BLEManager.debugBluetoothIdleAtLaunch = saved }
        BLEManager.debugBluetoothIdleAtLaunch = false
        XCTAssertFalse(BLEManager(defaults: defaults).debugBluetoothIdle,
                       "an ordinary manager is not under the hook")
        BLEManager.debugBluetoothIdleAtLaunch = true
        let ble = BLEManager(defaults: defaults)
        XCTAssertTrue(ble.debugBluetoothIdle)
        XCTAssertEqual(ble.connectionState, .idle, "the scan panel's state, not Starting Bluetooth")
        XCTAssertTrue(ble.bluetoothGranted, "the allowed state: no pre-permission rationale")
        XCTAssertFalse(ble.bluetoothRestricted)
        XCTAssertEqual(bluetoothScanButtonTitle(isScanning: false, bluetoothGranted: ble.bluetoothGranted),
                       "Scan for Beacons")
        ble.startScanFromUser()
        XCTAssertEqual(ble.connectionState, .idle, "a Scan for Beacons tap is inert: no scan")
        ble.startScan()
        XCTAssertEqual(ble.connectionState, .idle)
        // With -boardKind too, the remembered row shows beside the scan panel.
        ble.applyDebugBoardKind(.ouiSpy, demo: false)
        XCTAssertEqual(ble.pickerEntries.first.map(boardPickerRowTitle), "your OUI-Spy")
        XCTAssertEqual(ble.connectionState, .idle)
        XCTAssertNil(RememberedBoardStore(defaults: defaults).load(), "nothing reaches UserDefaults")
    }
    #endif

    /// The "Setup + pairing help" subtitle is one string on both apps (Android
    /// CONNECT_SETUP_HELP_SUBTITLE), lowercase-first, and names no board.
    func testSetupHelpSubtitleIsTheSettledString() {
        XCTAssertEqual(ConnectCopy.setupHelpSubtitle,
                       "offline help for power, permissions, pairing, and connection recovery")
    }

    /// The checklist's Location rationale names the checklist's board; unknown reads as beacon.
    func testLocationRationaleNamesTheBoard() {
        let lead = "Location is optional. it keeps Live Mode current in the background, shows where your phone heard detections on Map, and lets the "
        let tail = " label buffered hits with the last location your phone shared over encrypted Bluetooth. choose Not Now and detection still works. nothing is uploaded automatically."
        XCTAssertEqual(renderBoardCopy(FirstRunTour.locationRationale, nil), lead + "beacon" + tail)
        for kind in BoardKind.allCases {
            XCTAssertEqual(renderBoardCopy(FirstRunTour.locationRationale, kind), lead + kind.noun + tail)
        }
    }

    /// The offline-sync banner names the board only in its all-unreplayed arm. Byte-identical to
    /// Android offlineSyncMessage.
    func testOfflineSyncBannerNamesTheBoard() {
        XCTAssertEqual(offlineSyncMessage(count: 0, unreplayed: 1, kind: nil),
                       "1 buffered detection couldn't be replayed from the beacon")
        XCTAssertEqual(offlineSyncMessage(count: 0, unreplayed: 3, kind: .ouiSpy),
                       "3 buffered detections couldn't be replayed from the OUI-Spy")
        XCTAssertEqual(offlineSyncMessage(count: 0, unreplayed: 1, kind: .meshDetect),
                       "1 buffered detection couldn't be replayed from the Mesh-Detect")
        let kinds: [BoardKind?] = [nil] + BoardKind.allCases.map { Optional($0) }
        for kind in kinds {
            XCTAssertEqual(offlineSyncMessage(count: 1, unreplayed: 0, kind: kind),
                           "1 detection recorded while you were away")
            XCTAssertEqual(offlineSyncMessage(count: 5, unreplayed: 0, kind: kind),
                           "5 detections recorded while you were away")
            XCTAssertEqual(offlineSyncMessage(count: 2, unreplayed: 1, kind: kind),
                           "2 detections recorded while you were away (1 more couldn't be replayed)")
        }
    }

    // MARK: copy

    /// Every templated surface, per kind, against the table. The beacon (and nil) rendering is the
    /// one users see today on every surface the plan did not settle.
    private let templateRenderings: [BoardKind: [(String, String, String)]] = [
        .beacon: [
            ("ConnectCopy.setupSentence", ConnectCopy.setupSentence,
             "power on your beacon and keep it nearby."),
            ("ConnectCopy.bluetoothRationale", ConnectCopy.bluetoothRationale,
             "connects your phone to your beacon. the beacon does the listening, not your phone."),
            ("ConnectCopy.bluetoothOff", ConnectCopy.bluetoothOff,
             "turn on Bluetooth to find your beacon."),
            ("ConnectCopy.bluetoothRestricted", ConnectCopy.bluetoothRestricted,
             "Bluetooth is restricted by device policy, so the app cannot scan for a beacon."),
            ("ConnectCopy.bluetoothDenied", ConnectCopy.bluetoothDenied,
             "Bluetooth access is off for beacons. turn it on in Settings to scan for your beacon."),
            ("ConnectCopy.looking", ConnectCopy.looking,
             "looking for your beacon\u{2026}"),
            ("ConnectCopy.noneFound", ConnectCopy.noneFound,
             "no beacons found. make sure your beacon is powered on and nearby, then scan again."),
            ("ConnectCopy.securePairingNote", ConnectCopy.securePairingNote,
             "tap your beacon, then accept the iOS pairing request if it appears. pairing encrypts the detection link to this phone."),
            ("BLEManager.pairWindowHint", BLEManager.pairWindowHint,
             "turn the beacon off and on, then connect within two minutes."),
            ("ConnectCopy.hearsRow", ConnectCopy.hearsRow,
             "What your beacon can hear"),
            ("ConnectCopy.hearsShow", ConnectCopy.hearsShow,
             "show what your beacon can hear"),
            ("ConnectCopy.hearsHide", ConnectCopy.hearsHide,
             "hide what your beacon can hear"),
            ("ConnectCopy.savedLogKicker", ConnectCopy.savedLogKicker,
             "history on this phone \u{00B7} browse and export, no beacon needed"),
            ("ConnectCopy.scopeFootnote", ConnectCopy.scopeFootnote,
             "passive detection only. the beacon never jams, spoofs, or interferes."),
            ("ConnectCopy.locationOff", ConnectCopy.locationOff,
             "beacon scanning still works. most pins showing where your phone heard a detection will be absent, while drones with Remote ID coordinates can still appear."),
            ("ConnectCopy.locationRestricted", ConnectCopy.locationRestricted,
             "a device policy prevents the app from recording where your phone heard detections. beacon scanning still works, and drones with Remote ID coordinates can still appear on the map."),
            ("desertRestoreOffer", desertRestoreOffer,
             "desert mode ended on the beacon, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode."),
            ("ConnectCopy.connectingBody", ConnectCopy.connectingBody,
             "keep your beacon powered on and nearby. approve the iOS pairing request if it appears."),
            ("ConnectCopy.reconnectingTitle", ConnectCopy.reconnectingTitle,
             "reconnecting to your beacon\u{2026}"),
            ("ConnectCopy.reconnectingBody", ConnectCopy.reconnectingBody,
             "it reconnects on its own when the beacon is back in range, even in the background. keep waiting, or stop to scan for a different beacon."),
            ("ConnectCopy.reconnectBannerTitle", ConnectCopy.reconnectBannerTitle,
             "reconnecting to your beacon"),
            ("ConnectCopy.reconnectBannerSubtitle", ConnectCopy.reconnectBannerSubtitle,
             "your open screen and capture are preserved."),
            ("RememberedBoardCopy.labelTemplate", RememberedBoardCopy.labelTemplate,
             "your beacon"),
            ("FirstRunTour.checklistTitle", FirstRunTour.checklistTitle,
             "your beacon is listening"),
            ("FirstRunTour.checklistSubtitle", FirstRunTour.checklistSubtitle,
             "detection is already active. these optional phone and beacon features can be changed later under Beacon."),
            ("FirstRunTour.checklistPreviewNote", FirstRunTour.checklistPreviewNote,
             "preview: this is what you see after your beacon connects."),
        ],
        .ouiSpy: [
            ("ConnectCopy.setupSentence", ConnectCopy.setupSentence,
             "power on your OUI-Spy and keep it nearby."),
            ("ConnectCopy.bluetoothRationale", ConnectCopy.bluetoothRationale,
             "connects your phone to your OUI-Spy. the OUI-Spy does the listening, not your phone."),
            ("ConnectCopy.bluetoothOff", ConnectCopy.bluetoothOff,
             "turn on Bluetooth to find your OUI-Spy."),
            ("ConnectCopy.bluetoothRestricted", ConnectCopy.bluetoothRestricted,
             "Bluetooth is restricted by device policy, so the app cannot scan for an OUI-Spy."),
            ("ConnectCopy.bluetoothDenied", ConnectCopy.bluetoothDenied,
             "Bluetooth access is off for beacons. turn it on in Settings to scan for your OUI-Spy."),
            ("ConnectCopy.looking", ConnectCopy.looking,
             "looking for your OUI-Spy\u{2026}"),
            ("ConnectCopy.noneFound", ConnectCopy.noneFound,
             "no OUI-Spy found. make sure your OUI-Spy is powered on and nearby, then scan again."),
            ("ConnectCopy.securePairingNote", ConnectCopy.securePairingNote,
             "tap your OUI-Spy, then accept the iOS pairing request if it appears. pairing encrypts the detection link to this phone."),
            ("BLEManager.pairWindowHint", BLEManager.pairWindowHint,
             "turn the OUI-Spy off and on, then connect within two minutes."),
            ("ConnectCopy.hearsRow", ConnectCopy.hearsRow,
             "What your OUI-Spy can hear"),
            ("ConnectCopy.hearsShow", ConnectCopy.hearsShow,
             "show what your OUI-Spy can hear"),
            ("ConnectCopy.hearsHide", ConnectCopy.hearsHide,
             "hide what your OUI-Spy can hear"),
            ("ConnectCopy.savedLogKicker", ConnectCopy.savedLogKicker,
             "history on this phone \u{00B7} browse and export, no OUI-Spy needed"),
            ("ConnectCopy.scopeFootnote", ConnectCopy.scopeFootnote,
             "passive detection only. the OUI-Spy never jams, spoofs, or interferes."),
            ("ConnectCopy.locationOff", ConnectCopy.locationOff,
             "OUI-Spy scanning still works. most pins showing where your phone heard a detection will be absent, while drones with Remote ID coordinates can still appear."),
            ("ConnectCopy.locationRestricted", ConnectCopy.locationRestricted,
             "a device policy prevents the app from recording where your phone heard detections. OUI-Spy scanning still works, and drones with Remote ID coordinates can still appear on the map."),
            ("desertRestoreOffer", desertRestoreOffer,
             "desert mode ended on the OUI-Spy, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode."),
            ("ConnectCopy.connectingBody", ConnectCopy.connectingBody,
             "keep your OUI-Spy powered on and nearby. approve the iOS pairing request if it appears."),
            ("ConnectCopy.reconnectingTitle", ConnectCopy.reconnectingTitle,
             "reconnecting to your OUI-Spy\u{2026}"),
            ("ConnectCopy.reconnectingBody", ConnectCopy.reconnectingBody,
             "it reconnects on its own when the OUI-Spy is back in range, even in the background. keep waiting, or stop to scan for a different OUI-Spy."),
            ("ConnectCopy.reconnectBannerTitle", ConnectCopy.reconnectBannerTitle,
             "reconnecting to your OUI-Spy"),
            ("ConnectCopy.reconnectBannerSubtitle", ConnectCopy.reconnectBannerSubtitle,
             "your open screen and capture are preserved."),
            ("RememberedBoardCopy.labelTemplate", RememberedBoardCopy.labelTemplate,
             "your OUI-Spy"),
            ("FirstRunTour.checklistTitle", FirstRunTour.checklistTitle,
             "your OUI-Spy is listening"),
            ("FirstRunTour.checklistSubtitle", FirstRunTour.checklistSubtitle,
             "detection is already active. these optional phone and OUI-Spy features can be changed later under Beacon."),
            ("FirstRunTour.checklistPreviewNote", FirstRunTour.checklistPreviewNote,
             "preview: this is what you see after your OUI-Spy connects."),
        ],
        .meshDetect: [
            ("ConnectCopy.setupSentence", ConnectCopy.setupSentence,
             "power on your Mesh-Detect and keep it nearby."),
            ("ConnectCopy.bluetoothRationale", ConnectCopy.bluetoothRationale,
             "connects your phone to your Mesh-Detect. the Mesh-Detect does the listening, not your phone."),
            ("ConnectCopy.bluetoothOff", ConnectCopy.bluetoothOff,
             "turn on Bluetooth to find your Mesh-Detect."),
            ("ConnectCopy.bluetoothRestricted", ConnectCopy.bluetoothRestricted,
             "Bluetooth is restricted by device policy, so the app cannot scan for a Mesh-Detect."),
            ("ConnectCopy.bluetoothDenied", ConnectCopy.bluetoothDenied,
             "Bluetooth access is off for beacons. turn it on in Settings to scan for your Mesh-Detect."),
            ("ConnectCopy.looking", ConnectCopy.looking,
             "looking for your Mesh-Detect\u{2026}"),
            ("ConnectCopy.noneFound", ConnectCopy.noneFound,
             "no Mesh-Detect found. make sure your Mesh-Detect is powered on and nearby, then scan again."),
            ("ConnectCopy.securePairingNote", ConnectCopy.securePairingNote,
             "tap your Mesh-Detect, then accept the iOS pairing request if it appears. pairing encrypts the detection link to this phone."),
            ("BLEManager.pairWindowHint", BLEManager.pairWindowHint,
             "turn the Mesh-Detect off and on, then connect within two minutes."),
            ("ConnectCopy.hearsRow", ConnectCopy.hearsRow,
             "What your Mesh-Detect can hear"),
            ("ConnectCopy.hearsShow", ConnectCopy.hearsShow,
             "show what your Mesh-Detect can hear"),
            ("ConnectCopy.hearsHide", ConnectCopy.hearsHide,
             "hide what your Mesh-Detect can hear"),
            ("ConnectCopy.savedLogKicker", ConnectCopy.savedLogKicker,
             "history on this phone \u{00B7} browse and export, no Mesh-Detect needed"),
            ("ConnectCopy.scopeFootnote", ConnectCopy.scopeFootnote,
             "passive detection only. the Mesh-Detect never jams, spoofs, or interferes."),
            ("ConnectCopy.locationOff", ConnectCopy.locationOff,
             "Mesh-Detect scanning still works. most pins showing where your phone heard a detection will be absent, while drones with Remote ID coordinates can still appear."),
            ("ConnectCopy.locationRestricted", ConnectCopy.locationRestricted,
             "a device policy prevents the app from recording where your phone heard detections. Mesh-Detect scanning still works, and drones with Remote ID coordinates can still appear on the map."),
            ("desertRestoreOffer", desertRestoreOffer,
             "desert mode ended on the Mesh-Detect, so your alert mode is still silent. the app does not change it on its own. Restore Alerts puts back the mode you had before desert mode."),
            ("ConnectCopy.connectingBody", ConnectCopy.connectingBody,
             "keep your Mesh-Detect powered on and nearby. approve the iOS pairing request if it appears."),
            ("ConnectCopy.reconnectingTitle", ConnectCopy.reconnectingTitle,
             "reconnecting to your Mesh-Detect\u{2026}"),
            ("ConnectCopy.reconnectingBody", ConnectCopy.reconnectingBody,
             "it reconnects on its own when the Mesh-Detect is back in range, even in the background. keep waiting, or stop to scan for a different Mesh-Detect."),
            ("ConnectCopy.reconnectBannerTitle", ConnectCopy.reconnectBannerTitle,
             "reconnecting to your Mesh-Detect"),
            ("ConnectCopy.reconnectBannerSubtitle", ConnectCopy.reconnectBannerSubtitle,
             "your open screen and capture are preserved."),
            ("RememberedBoardCopy.labelTemplate", RememberedBoardCopy.labelTemplate,
             "your Mesh-Detect"),
            ("FirstRunTour.checklistTitle", FirstRunTour.checklistTitle,
             "your Mesh-Detect is listening"),
            ("FirstRunTour.checklistSubtitle", FirstRunTour.checklistSubtitle,
             "detection is already active. these optional phone and Mesh-Detect features can be changed later under Beacon."),
            ("FirstRunTour.checklistPreviewNote", FirstRunTour.checklistPreviewNote,
             "preview: this is what you see after your Mesh-Detect connects."),
        ],
    ]

    func testEveryTemplateRendersTheTableForEveryKind() {
        for kind in BoardKind.allCases {
            let cases = templateRenderings[kind] ?? []
            XCTAssertEqual(cases.count, 26, "one expectation per template for \(kind)")
            for (name, template, expected) in cases {
                XCTAssertEqual(renderBoardCopy(template, kind), expected, "\(name) as \(kind)")
                if kind == .beacon {
                    XCTAssertEqual(renderBoardCopy(template, nil), expected,
                                   "\(name): unknown reads exactly as beacon")
                }
            }
        }
    }

    private let failureRenderings: [BoardKind: [(BeaconConnectionFailure, String)]] = [
        .beacon: [
            (.timeout,
             "the connection timed out. keep the beacon powered on and nearby, then scan again."),
            (.transport,
             "the beacon could not connect. keep it powered on and nearby, then scan again."),
            (.securePairing,
             "secure pairing did not finish. scan again, tap your beacon, then accept the iOS pairing request if it appears."),
            (.missingService,
             "this does not appear to be a compatible beacon. check its firmware, then scan again."),
            (.missingChannel("<x>"),
             "this beacon is missing its <x> channel, so it cannot report to the app. check its firmware, then scan again."),
            (.secureServiceDiscovery,
             "the beacon's secure service could not be discovered. reconnect and try again."),
            (.secureChannelDiscovery,
             "the beacon's secure channels could not be discovered. reconnect and try again."),
        ],
        .ouiSpy: [
            (.timeout,
             "the connection timed out. keep the OUI-Spy powered on and nearby, then scan again."),
            (.transport,
             "the OUI-Spy could not connect. keep it powered on and nearby, then scan again."),
            (.securePairing,
             "secure pairing did not finish. scan again, tap your OUI-Spy, then accept the iOS pairing request if it appears."),
            (.missingService,
             "this does not appear to be a compatible OUI-Spy. check its firmware, then scan again."),
            (.missingChannel("<x>"),
             "this OUI-Spy is missing its <x> channel, so it cannot report to the app. check its firmware, then scan again."),
            (.secureServiceDiscovery,
             "the OUI-Spy's secure service could not be discovered. reconnect and try again."),
            (.secureChannelDiscovery,
             "the OUI-Spy's secure channels could not be discovered. reconnect and try again."),
        ],
        .meshDetect: [
            (.timeout,
             "the connection timed out. keep the Mesh-Detect powered on and nearby, then scan again."),
            (.transport,
             "the Mesh-Detect could not connect. keep it powered on and nearby, then scan again."),
            (.securePairing,
             "secure pairing did not finish. scan again, tap your Mesh-Detect, then accept the iOS pairing request if it appears."),
            (.missingService,
             "this does not appear to be a compatible Mesh-Detect. check its firmware, then scan again."),
            (.missingChannel("<x>"),
             "this Mesh-Detect is missing its <x> channel, so it cannot report to the app. check its firmware, then scan again."),
            (.secureServiceDiscovery,
             "the Mesh-Detect's secure service could not be discovered. reconnect and try again."),
            (.secureChannelDiscovery,
             "the Mesh-Detect's secure channels could not be discovered. reconnect and try again."),
        ],
    ]

    func testFailureHintsNameTheTarget() {
        for kind in BoardKind.allCases {
            for (failure, expected) in failureRenderings[kind] ?? [] {
                XCTAssertEqual(beaconConnectionRecovery(failure, kind: kind), expected)
                if kind == .beacon {
                    XCTAssertEqual(beaconConnectionRecovery(failure, kind: nil), expected)
                }
                XCTAssertTrue(expected.contains(kind.noun))
                XCTAssertFalse(expected.contains("board"), "the user-facing noun is the product")
            }
            XCTAssertEqual(failureRenderings[kind]?.count, 7)
        }
    }

    /// The two update-quarantine lines name the connected board, and unknown reads as beacon.
    /// TWIN: Android BoardKindTest.otaLinesNameTheBoardBeingUpdated.
    func testUpdateQuarantineLinesNameTheBoard() {
        let tail = " this clears any delayed update replies from the previous attempt."
        let kinds: [BoardKind?] = [nil] + BoardKind.allCases.map { Optional($0) }
        for kind in kinds {
            let noun = (kind ?? .beacon).noun
            XCTAssertEqual(renderBoardCopy(BLEManager.otaReconnectBeforeRetryTemplate, kind),
                           "reconnect to the \(noun) before retrying the board update." + tail)
            XCTAssertEqual(renderBoardCopy(BLEManager.nrfReconnectBeforeRetryTemplate, kind),
                           "reconnect to the \(noun) before retrying the co-processor update." + tail)
        }
        XCTAssertEqual(renderBoardCopy(BLEManager.otaReconnectBeforeRetryTemplate, .ouiSpy),
                       "reconnect to the OUI-Spy before retrying the board update." + tail)
        XCTAssertEqual(renderBoardCopy(BLEManager.nrfReconnectBeforeRetryTemplate, .meshDetect),
                       "reconnect to the Mesh-Detect before retrying the co-processor update." + tail)
        for kind in kinds {
            for template in [BLEManager.otaReconnectBeforeRetryTemplate,
                             BLEManager.nrfReconnectBeforeRetryTemplate] {
                let text = renderBoardCopy(template, kind)
                XCTAssertFalse(text.contains("{") || text.contains("}"), "unfilled hole: \(text)")
                XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "dash: \(text)")
            }
        }
    }

    /// No rendering leaves a hole unfilled or carries a dash the copy rules ban.
    func testNoRenderingLeaksAHoleOrADash() {
        var all: [String] = []
        let kinds: [BoardKind?] = [nil] + BoardKind.allCases.map { Optional($0) }
        for kind in kinds {
            for (_, template, _) in templateRenderings[.beacon] ?? [] {
                all.append(renderBoardCopy(template, kind))
            }
            all += (failureRenderings[.beacon] ?? []).map { beaconConnectionRecovery($0.0, kind: kind) }
            all.append(RememberedBoardCopy.label(kind: kind))
            all.append(boardHeroTitle(kind))
        }
        XCTAssertFalse(all.isEmpty)
        for text in all {
            XCTAssertFalse(text.contains("{") || text.contains("}"), "unfilled hole: \(text)")
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "dash: \(text)")
        }
    }

    // MARK: picker rows

    func testPickerRowsNameTheirKind() {
        func row(_ kind: BoardKind?, remembered: Bool, rssi: Int? = -50,
                 fw: String? = nil) -> BoardPickerEntry {
            BoardPickerEntry(id: boardA, name: "ACAB", rssi: rssi, firmware: fw,
                             isRemembered: remembered, kind: kind)
        }
        XCTAssertEqual(boardPickerRowTitle(row(.beacon, remembered: false)), "beacon")
        XCTAssertEqual(boardPickerRowTitle(row(.ouiSpy, remembered: false)), "OUI-Spy")
        XCTAssertEqual(boardPickerRowTitle(row(.meshDetect, remembered: false)), "Mesh-Detect")
        XCTAssertEqual(boardPickerRowTitle(row(nil, remembered: false)), "beacon",
                       "no or an unknown name reads beacon, never the raw \"ACAB\"")
        XCTAssertEqual(boardPickerRowTitle(row(.ouiSpy, remembered: true)), "your OUI-Spy")
        XCTAssertEqual(boardPickerRowTitle(row(nil, remembered: true)), "your beacon")

        XCTAssertEqual(boardPickerRowSubtitle(row(.ouiSpy, remembered: false)), "tap to pair securely")
        XCTAssertEqual(boardPickerRowSubtitle(row(.ouiSpy, remembered: true)), "tap to connect",
                       "the advertised name is gone from the remembered subtitle")
        XCTAssertEqual(boardPickerRowSubtitle(row(.ouiSpy, remembered: true, rssi: nil)),
                       "no live signal \u{00B7} tap to connect")

        XCTAssertEqual(boardPickerRowAccessibilityLabel(row(.ouiSpy, remembered: true, rssi: nil)),
                       "your OUI-Spy, no live signal, connects securely")
        XCTAssertEqual(boardPickerRowAccessibilityLabel(row(.meshDetect, remembered: false,
                                                            rssi: -95, fw: "2.0.9")),
                       "Mesh-Detect, \(beaconSignalDescription(rssi: -95)) signal, connects securely, firmware 2.0.9")
    }

    /// The buttons keep their text for every kind (the scan button searches the whole line).
    func testButtonsDoNotTakeAKind() {
        XCTAssertEqual(bluetoothScanButtonTitle(isScanning: false, bluetoothGranted: true),
                       "Scan for Beacons")
        XCTAssertEqual(bluetoothScanButtonTitle(isScanning: true, bluetoothGranted: true),
                       "Stop Scanning")
        XCTAssertEqual(bluetoothScanButtonTitle(isScanning: false, bluetoothGranted: false),
                       "Continue")
    }
}
