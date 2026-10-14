import XCTest
@testable import Beacons

/// A phone with no stored alert mode must never change whether the board makes sound on its own,
/// and since the app review of 2026-10-12 (A.7) neither may a stored Buzzer: a connect writes only
/// a stored quiet mode, or a pick the user made while no board was ready.
///
/// THE DEFECT (security review 2026-09-29). With nothing stored, the in-memory mode defaulted to
/// .buzzer and the connect path pushed it, so a reinstall, cleared data or a second phone un-muted
/// a board the user had muted elsewhere, Desert included, and the board saved that to its flash.
/// The re-review found a second way in: Desert's app-origin mute and restore stored a mode on such
/// a phone, and a mesh board left the .buzzer placeholder unmirrored for Desert to capture.
///
/// The pure-rule tests pin what both platforms run. The manager tests drive the REAL BLEManager
/// over an isolated preference suite: its reconcileBuzzer, setAlertMode and setDesertMode, and
/// connectTimeBuzzerWrite, the exact value the connect path hands to the board.
/// Not covered here, because they need a real peripheral: the per-link hold being cleared in
/// didConnect, clearConnection, didDisconnect and at READY, the owed pick being consumed at READY,
/// and the Config object setDesertMode actually sends (the pure desertEnableConfig and
/// desertDisableConfig are pinned instead). Android twin: ConnectBuzzerPolicyTest.kt, same
/// pure-rule vectors.
final class ConnectBuzzerPolicyTests: XCTestCase {

    // MARK: - the pure rules

    /// A connect writes a stored QUIET mode and nothing else: no stored mode writes nothing, and a
    /// stored Buzzer writes nothing either, so a board muted from another phone stays muted.
    /// Reverting to "write mode == .buzzer" fails the first two lines; the previous rule,
    /// `hasStoredMode ? mode == .buzzer : nil`, fails the third (it wrote true).
    func testConnectWritesOnlyAStoredQuietMode() {
        XCTAssertNil(connectBuzzerWrite(hasStoredMode: false, mode: .buzzer))
        XCTAssertNil(connectBuzzerWrite(hasStoredMode: false, mode: .silent))
        XCTAssertNil(connectBuzzerWrite(hasStoredMode: true, mode: .buzzer))
        XCTAssertEqual(connectBuzzerWrite(hasStoredMode: true, mode: .vibrate), false)
        XCTAssertEqual(connectBuzzerWrite(hasStoredMode: true, mode: .silent), false)
    }

    /// The one exception: a pick the user made while no board was ready (the Desert restore offer
    /// on the connect screen) is written at the next connect, Buzzer included. With nothing stored
    /// there is no pick to owe. Dropping the pickOwed arm fails the first line (nil, not true).
    func testAPickOwedFromWhileAwayIsWrittenAtConnect() {
        XCTAssertEqual(connectBuzzerWrite(hasStoredMode: true, mode: .buzzer, pickOwed: true), true)
        XCTAssertEqual(connectBuzzerWrite(hasStoredMode: true, mode: .silent, pickOwed: true), false)
        XCTAssertEqual(connectBuzzerWrite(hasStoredMode: true, mode: .vibrate, pickOwed: true), false)
        XCTAssertNil(connectBuzzerWrite(hasStoredMode: false, mode: .buzzer, pickOwed: true))
    }

    /// A phone with no mode mirrors: sound on reads .buzzer, muted reads .silent (never .vibrate).
    /// A stored mode or an app-held mode on this link turns the mirror off. A stored Buzzer the
    /// phone did not set on this link reaches this rule as hasStoredMode false (reconcileBuzzer),
    /// so it mirrors a muted board as .silent by the second line.
    func testMirrorRule() {
        XCTAssertEqual(mirroredAlertMode(hasStoredMode: false, heldThisLink: false, boardBuzzer: true), .buzzer)
        XCTAssertEqual(mirroredAlertMode(hasStoredMode: false, heldThisLink: false, boardBuzzer: false), .silent)
        XCTAssertNil(mirroredAlertMode(hasStoredMode: true, heldThisLink: false, boardBuzzer: true))
        XCTAssertNil(mirroredAlertMode(hasStoredMode: false, heldThisLink: true, boardBuzzer: true))
    }

    /// Desert on and Desert off each go out as ONE Config object, so a link lost between two writes
    /// can neither leave the board in Desert and audible nor drop the restore.
    func testDesertWritesCarryTheirBuzzerStateInOneWrite() {
        XCTAssertEqual(desertEnableConfig(mutes: true), ["desert": true, "buzzer": false])
        XCTAssertEqual(desertEnableConfig(mutes: false), ["desert": true])
        XCTAssertEqual(desertDisableConfig(restoreTo: .buzzer), ["desert": false, "buzzer": true])
        XCTAssertEqual(desertDisableConfig(restoreTo: .vibrate), ["desert": false, "buzzer": false])
        XCTAssertEqual(desertDisableConfig(restoreTo: nil), ["desert": false])
    }

    /// 2.1.0 stored Desert's modes as if they were picks, and only Buzzer can be unpicked. A legacy
    /// Buzzer is dropped once (the phone then mirrors), and so is Desert's forced Silent beside a
    /// saved Buzzer. Beside a saved Vibrate, always a hand pick, the Silent stays so Desert-off
    /// stores the pick. Otherwise legacy Silent and Vibrate only ever mute, so they stay.
    func testLegacyStoreRule() {
        XCTAssertNil(alertModeKeptFromLegacyStore(.buzzer, desertSaved: nil))
        XCTAssertEqual(alertModeKeptFromLegacyStore(.vibrate, desertSaved: nil), .vibrate)
        XCTAssertEqual(alertModeKeptFromLegacyStore(.silent, desertSaved: nil), .silent)
        XCTAssertNil(alertModeKeptFromLegacyStore(nil, desertSaved: nil))
        XCTAssertNil(alertModeKeptFromLegacyStore(.silent, desertSaved: .buzzer))
        XCTAssertEqual(alertModeKeptFromLegacyStore(.silent, desertSaved: .vibrate), .silent)
    }

    // MARK: - the real manager

    /// A real decoded status frame, the same construction path the BLE link uses.
    private func status(buzzer: Bool, fw: String = "beacon board 2.1.0") throws -> DeviceStatus {
        let json = #"{"fw":""# + fw + #"","buzzer":"# + (buzzer ? "true}" : "false}")
        return try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }

    private let modeKey = "acab.alertMode"
    private let savedKey = "acab.alertModeBeforeDesert"
    private let originAwareKey = "acab.alertModeOriginAware"

    /// Fresh install meets a muted board: the phone shows Silent, follows the board when it
    /// changes, stores nothing, and the connect path would write nothing.
    func testNoStoredModeMirrorsTheBoardAndWritesNothingAtConnect() throws {
        let defaults = isolatedDefaults()
        let ble = BLEManager(defaults: defaults)
        XCTAssertNil(ble.connectTimeBuzzerWrite, "no stored mode: the connect path writes nothing")
        ble.reconcileBuzzer(try status(buzzer: false))
        XCTAssertEqual(ble.alertMode, .silent)
        ble.reconcileBuzzer(try status(buzzer: true))
        XCTAssertEqual(ble.alertMode, .buzzer)
        XCTAssertNil(ble.connectTimeBuzzerWrite, "mirroring the board does not make it a stored mode")
        XCTAssertNil(defaults.string(forKey: modeKey), "mirroring must never store a mode")
    }

    /// A stored mode is what the connect path writes, and a board reporting sound does not move a
    /// hand-picked Vibrate.
    func testAStoredModeIsWrittenAtConnectAndNotOverwrittenByTheBoard() throws {
        let defaults = isolatedDefaults()
        defaults.set(AlertMode.vibrate.rawValue, forKey: modeKey)
        let ble = BLEManager(defaults: defaults)
        XCTAssertEqual(ble.connectTimeBuzzerWrite, false)
        ble.reconcileBuzzer(try status(buzzer: true))
        XCTAssertEqual(ble.alertMode, .vibrate)
    }

    /// A user pick on a mirroring phone stores the mode and ends mirroring for good.
    func testAUserPickEndsMirroring() throws {
        let defaults = isolatedDefaults()
        let ble = BLEManager(defaults: defaults)
        ble.reconcileBuzzer(try status(buzzer: true))
        ble.setAlertMode(.vibrate, origin: .user)
        ble.reconcileBuzzer(try status(buzzer: true))
        XCTAssertEqual(ble.alertMode, .vibrate)
        XCTAssertEqual(defaults.string(forKey: modeKey), AlertMode.vibrate.rawValue)
        XCTAssertEqual(ble.connectTimeBuzzerWrite, false)
    }

    /// THE RE-REVIEW DEFECT. Desert on and off from a phone with no stored mode still mutes and
    /// restores the board, but stores no mode, so the next connect writes nothing. Before the fix
    /// this stored .buzzer and every later connect un-muted a board muted from another phone.
    func testDesertRoundTripStoresNoModeOnAPhoneWithNoStoredMode() throws {
        let defaults = isolatedDefaults()
        let ble = BLEManager(defaults: defaults)
        ble.reconcileBuzzer(try status(buzzer: true))
        ble.setDesertMode(true)
        XCTAssertEqual(ble.alertMode, .silent, "Desert still mutes")
        XCTAssertNil(defaults.string(forKey: modeKey))
        XCTAssertNil(ble.connectTimeBuzzerWrite)
        ble.reconcileBuzzer(try status(buzzer: true))
        XCTAssertEqual(ble.alertMode, .silent,
                       "the app-held mute outranks a frame from before the mute landed")
        ble.setDesertMode(false)
        XCTAssertEqual(ble.alertMode, .buzzer, "the user ended Desert, so the board's sound comes back")
        XCTAssertNil(defaults.string(forKey: modeKey), "an app-origin restore is not a pick")
        XCTAssertNil(ble.connectTimeBuzzerWrite)
    }

    /// A mesh board has no buzzer, so a phone with no stored mode mirrors it as Silent. Desert on
    /// that board then has nothing to capture, so nothing can come back as sound later.
    func testMeshBoardMirrorsAsSilentAndDesertCapturesNothing() throws {
        let defaults = isolatedDefaults()
        let ble = BLEManager(defaults: defaults)
        ble.reconcileBuzzer(try status(buzzer: false, fw: "mesh-detect-ACAB"))
        XCTAssertEqual(ble.alertMode, .silent)
        ble.setDesertMode(true)
        ble.setDesertMode(false)
        XCTAssertEqual(ble.alertMode, .silent)
        XCTAssertNil(defaults.string(forKey: modeKey))
        XCTAssertNil(defaults.string(forKey: savedKey), "no pre-Desert mode was captured")
        XCTAssertNil(ble.connectTimeBuzzerWrite)
    }

    /// THE A.7 DEFECT. A stored Buzzer meeting a muted board used to re-assert sound (three
    /// buzzer:true writes, alertMode held at .buzzer) and wrote buzzer:true at every connect. It
    /// now mirrors the board like a phone with no mode: Silent on screen, the pick still stored,
    /// nothing written at connect, and sound shown again once the board reports it. On the old
    /// code the first assertion fails (.buzzer) and so does the connect write (true).
    func testAStoredBuzzerMirrorsAMutedBoardAndWritesNothingAtConnect() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: originAwareKey)   // stored after the upgrade rule, so it is a pick
        defaults.set(AlertMode.buzzer.rawValue, forKey: modeKey)
        let ble = BLEManager(defaults: defaults)
        XCTAssertEqual(ble.alertMode, .buzzer)
        ble.reconcileBuzzer(try status(buzzer: false))
        XCTAssertEqual(ble.alertMode, .silent, "a board muted elsewhere stays muted and says so")
        XCTAssertNil(ble.connectTimeBuzzerWrite)
        XCTAssertEqual(defaults.string(forKey: modeKey), AlertMode.buzzer.rawValue,
                       "the mirror moves the screen, never the stored pick")
        ble.reconcileBuzzer(try status(buzzer: true))
        XCTAssertEqual(ble.alertMode, .buzzer)
        XCTAssertNil(ble.connectTimeBuzzerWrite)
    }

    /// A mesh board (always buzzer:false) meets a stored Buzzer the same way: mirrored as Silent in
    /// memory only. The stored pick survives, so the user's real beacon is neither muted nor
    /// un-muted by its next connect. Four frames, one past the old re-assert burst.
    func testMeshFramesNeverRewriteAStoredBuzzer() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: originAwareKey)
        defaults.set(AlertMode.buzzer.rawValue, forKey: modeKey)
        let ble = BLEManager(defaults: defaults)
        for _ in 0..<4 { ble.reconcileBuzzer(try status(buzzer: false, fw: "mesh-detect-ACAB")) }
        XCTAssertEqual(ble.alertMode, .silent)
        XCTAssertEqual(defaults.string(forKey: modeKey), AlertMode.buzzer.rawValue)
        XCTAssertNil(ble.connectTimeBuzzerWrite)
    }

    /// The exception through the real manager: a pick made with no ready board (a test manager
    /// never has one) is owed to the next connect, Buzzer included, and the pick holds against a
    /// muted frame instead of being mirrored away. Without the owed pick the connect write is nil.
    func testAPickMadeWhileAwayIsWrittenAtTheNextConnect() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: originAwareKey)
        let ble = BLEManager(defaults: defaults)
        ble.setAlertMode(.buzzer, origin: .user)
        XCTAssertEqual(ble.connectTimeBuzzerWrite, true)
        ble.reconcileBuzzer(try status(buzzer: false))
        XCTAssertEqual(ble.alertMode, .buzzer, "a pick is asserted, not mirrored")
    }

    /// The upgrade from 2.1.0: a stored Buzzer with no upgrade flag may be Desert's restore, so it
    /// is dropped once. The phone then writes nothing at connect, and the flag stops it happening
    /// again.
    func testLegacyStoredBuzzerIsDroppedOnceAtUpgrade() throws {
        let defaults = isolatedDefaults()
        defaults.set(AlertMode.buzzer.rawValue, forKey: modeKey)
        let ble = BLEManager(defaults: defaults)
        XCTAssertNil(ble.connectTimeBuzzerWrite)
        XCTAssertNil(defaults.string(forKey: modeKey))
        XCTAssertTrue(defaults.bool(forKey: originAwareKey))
    }

    /// A 2.1.0 phone updated while Desert ran: its stored Silent is Desert's own mute. It is dropped
    /// at upgrade, the saved mode stays, and turning Desert off restores the board for this link
    /// without storing a mode nobody picked. Before this rule the restore stored Buzzer for good.
    func testUpgradeMidDesertRestoresWithoutStoringAMode() throws {
        let defaults = isolatedDefaults()
        defaults.set(AlertMode.silent.rawValue, forKey: modeKey)
        defaults.set(AlertMode.buzzer.rawValue, forKey: savedKey)
        let ble = BLEManager(defaults: defaults)
        XCTAssertNil(ble.connectTimeBuzzerWrite)
        XCTAssertNil(defaults.string(forKey: modeKey))
        XCTAssertEqual(defaults.string(forKey: savedKey), AlertMode.buzzer.rawValue)
        ble.reconcileBuzzer(try status(buzzer: false))
        ble.setDesertMode(false)
        XCTAssertEqual(ble.alertMode, .buzzer, "Desert-off still restores the board")
        XCTAssertNil(defaults.string(forKey: modeKey), "an app-origin restore is not a pick")
        XCTAssertNil(ble.connectTimeBuzzerWrite)
    }

    /// A 2.1.0 phone updated while Desert ran after the user picked Vibrate: the forced Silent stays,
    /// so the connect path only ever mutes, and Desert-off stores the Vibrate pick for good.
    func testUpgradeMidDesertKeepsAVibratePick() throws {
        let defaults = isolatedDefaults()
        defaults.set(AlertMode.silent.rawValue, forKey: modeKey)
        defaults.set(AlertMode.vibrate.rawValue, forKey: savedKey)
        let ble = BLEManager(defaults: defaults)
        XCTAssertEqual(ble.connectTimeBuzzerWrite, false)
        ble.reconcileBuzzer(try status(buzzer: false))
        ble.setDesertMode(false)
        XCTAssertEqual(ble.alertMode, .vibrate)
        XCTAssertEqual(defaults.string(forKey: modeKey), AlertMode.vibrate.rawValue)
        XCTAssertEqual(ble.connectTimeBuzzerWrite, false)
    }

    /// A legacy quiet mode survives the upgrade, and a Buzzer stored after it (a pick) survives a
    /// relaunch. The owed write does not: a relaunched phone holds the pick as a stored Buzzer,
    /// which mirrors the board and writes nothing at connect.
    func testUpgradeKeepsQuietModesAndLaterPicks() throws {
        let quiet = isolatedDefaults()
        quiet.set(AlertMode.vibrate.rawValue, forKey: modeKey)
        XCTAssertEqual(BLEManager(defaults: quiet).connectTimeBuzzerWrite, false)

        let picked = isolatedDefaults()
        let first = BLEManager(defaults: picked)
        first.setAlertMode(.buzzer, origin: .user)
        XCTAssertEqual(first.connectTimeBuzzerWrite, true, "owed to this process's next connect")
        let relaunched = BLEManager(defaults: picked)
        XCTAssertNil(relaunched.connectTimeBuzzerWrite)
        XCTAssertEqual(relaunched.alertMode, .buzzer)
    }
}
