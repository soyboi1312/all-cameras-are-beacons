import XCTest
import CoreBluetooth
@testable import Beacons

/// Pins the remembered-board rules in RememberedBoard.swift: what is persisted and where, when it
/// is replaced, which failures forget it, and how the picker merges it with scanned rows. Every
/// store touch goes to a throwaway UserDefaults suite created and removed here, never the install.
/// Android twin: the remembered-board rules in AcabBleManager.kt (same spec, same copy).
final class RememberedBoardTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    private let boardA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let boardB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let boardC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUp() {
        super.setUp()
        suiteName = "tech.beacons.tests.rememberedBoard.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func scanned(_ id: UUID, _ name: String, rssi: Int, fw: String? = nil) -> BoardPickerEntry {
        BoardPickerEntry(id: id, name: name, rssi: rssi, firmware: fw, isRemembered: false)
    }

    // MARK: store

    func testStoreRoundTripsAndClears() {
        let store = RememberedBoardStore(defaults: defaults)
        XCTAssertNil(store.load(), "a fresh suite remembers nothing")
        store.save(RememberedBoard(id: boardA, name: "ACAB"))
        XCTAssertEqual(store.load(), RememberedBoard(id: boardA, name: "ACAB"))
        store.save(nil)
        XCTAssertNil(store.load())
        XCTAssertNil(defaults.object(forKey: RememberedBoardStore.nameKey), "forget clears the name too")
    }

    func testStoreIgnoresAnUnparseableID() {
        defaults.set("not-a-uuid", forKey: RememberedBoardStore.idKey)
        defaults.set("ACAB", forKey: RememberedBoardStore.nameKey)
        XCTAssertNil(RememberedBoardStore(defaults: defaults).load())
    }

    /// The cache is filled from the injected store at init, so a relaunch sees the board.
    func testManagerLoadsTheRememberedBoardFromItsInjectedStore() {
        RememberedBoardStore(defaults: defaults).save(RememberedBoard(id: boardA, name: "ACAB"))
        let ble = BLEManager(defaults: defaults)
        XCTAssertEqual(ble.rememberedBoard, RememberedBoard(id: boardA, name: "ACAB"))
    }

    // MARK: remember

    func testSecureReadyRemembersFirstBoardAndReplacesWithADifferentOne() {
        XCTAssertEqual(rememberedBoardAfterSecureReady(current: nil, readyID: boardA, readyName: "ACAB"),
                       RememberedBoard(id: boardA, name: "ACAB"))
        XCTAssertEqual(rememberedBoardAfterSecureReady(
                           current: RememberedBoard(id: boardA, name: "ACAB"),
                           readyID: boardB, readyName: "ACAB"),
                       RememberedBoard(id: boardB, name: "ACAB"),
                       "a different board bonding later replaces the remembered one")
    }

    func testSecureReadyOnTheSameBoardIsNoWrite() {
        XCTAssertNil(rememberedBoardAfterSecureReady(
            current: RememberedBoard(id: boardA, name: "ACAB"), readyID: boardA, readyName: "ACAB"),
            "the OTA reboot reconnect re-runs readiness and must not rewrite defaults")
        XCTAssertEqual(rememberedBoardAfterSecureReady(
            current: RememberedBoard(id: boardA, name: "ACAB"), readyID: boardA, readyName: "ACAB-2"),
            RememberedBoard(id: boardA, name: "ACAB-2"), "a renamed board updates the shown name")
    }

    // MARK: forget

    func testOnlyBondGoneErrorsCount() {
        XCTAssertTrue(connectionErrorMeansBondIsGone(CBError(.peerRemovedPairingInformation)))
        XCTAssertTrue(connectionErrorMeansBondIsGone(CBATTError(.insufficientEncryption)))
        XCTAssertTrue(connectionErrorMeansBondIsGone(CBATTError(.insufficientAuthentication)))
        XCTAssertTrue(connectionErrorMeansBondIsGone(CBATTError(.insufficientEncryptionKeySize)))

        XCTAssertFalse(connectionErrorMeansBondIsGone(nil), "a drop with no error may be range or power")
        XCTAssertFalse(connectionErrorMeansBondIsGone(CBError(.connectionTimeout)))
        XCTAssertFalse(connectionErrorMeansBondIsGone(CBError(.peripheralDisconnected)))
        XCTAssertFalse(connectionErrorMeansBondIsGone(CBError(.encryptionTimedOut)),
                       "a timed-out encryption is a radio outcome, not proof the keys are gone")
        XCTAssertFalse(connectionErrorMeansBondIsGone(CBATTError(.readNotPermitted)))
        // Same numeric code in an unrelated domain must not match.
        let peer = CBError.Code.peerRemovedPairingInformation.rawValue
        XCTAssertFalse(connectionErrorMeansBondIsGone(NSError(domain: NSPOSIXErrorDomain, code: peer)))
    }

    func testForgetIsScopedToTheRememberedBoard() {
        let gone = CBError(.peerRemovedPairingInformation)
        XCTAssertTrue(shouldForgetRememberedBoard(rememberedID: boardA, failingID: boardA, error: gone))
        XCTAssertFalse(shouldForgetRememberedBoard(rememberedID: boardA, failingID: boardB, error: gone),
                       "another board's bond failure says nothing about the owner's board")
        XCTAssertFalse(shouldForgetRememberedBoard(rememberedID: nil, failingID: boardA, error: gone))
        XCTAssertFalse(shouldForgetRememberedBoard(rememberedID: boardA, failingID: boardA,
                                                   error: CBError(.connectionTimeout)))
    }

    // MARK: merge

    func testNoRememberedBoardLeavesScanRowsUntouched() {
        let rows = [scanned(boardB, "ACAB", rssi: -60), scanned(boardC, "ACAB", rssi: -70)]
        XCTAssertEqual(mergeBoardPickerEntries(remembered: nil, rememberedRetrieved: false, scanned: rows), rows)
    }

    func testUnretrievedRememberedBoardShowsNoDeadRow() {
        let rows = [scanned(boardB, "ACAB", rssi: -60)]
        XCTAssertEqual(mergeBoardPickerEntries(remembered: RememberedBoard(id: boardA, name: "ACAB"),
                                               rememberedRetrieved: false, scanned: rows), rows)
    }

    func testRememberedBoardWithNoAdvertLeadsAndOthersKeepScanOrder() {
        let rows = [scanned(boardC, "ACAB", rssi: -80), scanned(boardB, "ACAB", rssi: -50)]
        let merged = mergeBoardPickerEntries(remembered: RememberedBoard(id: boardA, name: "ACAB"),
                                             rememberedRetrieved: true, scanned: rows)
        XCTAssertEqual(merged.map(\.id), [boardA, boardC, boardB])
        XCTAssertEqual(merged[0], BoardPickerEntry(id: boardA, name: "ACAB", rssi: nil,
                                                   firmware: nil, isRemembered: true))
        XCTAssertEqual(merged.filter(\.isRemembered).count, 1)
    }

    func testScannedSightingOfTheRememberedBoardMergesIntoOneRow() {
        let rows = [scanned(boardB, "ACAB", rssi: -50),
                    scanned(boardA, "ACAB-live", rssi: -42, fw: "2.0.9"),
                    scanned(boardC, "ACAB", rssi: -80)]
        let merged = mergeBoardPickerEntries(remembered: RememberedBoard(id: boardA, name: "ACAB"),
                                             rememberedRetrieved: true, scanned: rows)
        XCTAssertEqual(merged.count, 3, "one board is one row, never two")
        XCTAssertEqual(merged.map(\.id), [boardA, boardB, boardC])
        XCTAssertEqual(merged[0], BoardPickerEntry(id: boardA, name: "ACAB-live", rssi: -42,
                                                   firmware: "2.0.9", isRemembered: true))
        XCTAssertFalse(merged[1].isRemembered)
    }

    // MARK: shared copy (Android twin must match byte for byte)

    func testRememberedRowCopy() {
        XCTAssertEqual(RememberedBoardCopy.label, "your beacon")
        XCTAssertEqual(RememberedBoardCopy.noSignal, "no live signal \u{00B7} tap to connect")
        XCTAssertEqual(RememberedBoardCopy.seen, "tap to connect")
    }
}
