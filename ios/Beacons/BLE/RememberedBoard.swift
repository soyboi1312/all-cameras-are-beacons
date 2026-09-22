import Foundation
import CoreBluetooth

// The owner's board, remembered so the connect picker can offer it WITHOUT an advertisement.
//
// Why this exists: a later firmware stops advertising its name and the acab0100 service UUID once
// it holds a bond and its power-on pair window has closed. startScan() filters on that UUID, so
// without this the owner's own board would never appear after an app relaunch. The app half ships
// first and behaves identically with today's firmware, which still advertises the UUID: the scan
// sighting and the remembered row MERGE into one row (same CBPeripheral identifier).
//
// Android twin: the remembered-board rules in
// android/app/src/main/java/tech/acab/app/ble/AcabBleManager.kt implement the same four rules
// (remember on secure ready, forget once the bond is gone, one merged row with the remembered
// board first, connect through the normal bounded connect path). The forget SIGNAL differs by
// platform: iOS exposes no bond list, so it forgets on a bond-gone connect failure; Android reads
// bondedDevices at lookup (rememberedBoardLookup) and forgets when the bond is no longer there. The row copy below is shared
// user-facing text and must stay byte-identical on both platforms.

/// What is persisted: CoreBluetooth's per-phone peripheral UUID (not the board's BLE address)
/// and the name to show before any advertisement arrives.
struct RememberedBoard: Equatable {
    let id: UUID
    let name: String
}

/// The one reader/writer of the remembered board. Takes BLEManager's injected `defaults`, so a
/// hosted test passes a throwaway suite and never touches the real install. Read ONCE at init and
/// cached by BLEManager: nothing on the 3 Hz status path or in a SwiftUI body reads UserDefaults.
struct RememberedBoardStore {
    static let idKey = "rememberedBoardID"
    static let nameKey = "rememberedBoardName"

    let defaults: UserDefaults

    func load() -> RememberedBoard? {
        guard let raw = defaults.string(forKey: Self.idKey), let id = UUID(uuidString: raw)
        else { return nil }
        return RememberedBoard(id: id, name: defaults.string(forKey: Self.nameKey) ?? "")
    }

    func save(_ board: RememberedBoard?) {
        if let board {
            defaults.set(board.id.uuidString, forKey: Self.idKey)
            defaults.set(board.name, forKey: Self.nameKey)
        } else {
            defaults.removeObject(forKey: Self.idKey)
            defaults.removeObject(forKey: Self.nameKey)
        }
    }
}

/// REMEMBER: the board a session just reached secure readiness with becomes the remembered one.
/// A different board replaces the old one. Returns nil when nothing changes, so the caller writes
/// UserDefaults only on a real change (the OTA reboot reconnect re-runs readiness on the same
/// board and must not rewrite it).
func rememberedBoardAfterSecureReady(current: RememberedBoard?, readyID: UUID,
                                     readyName: String) -> RememberedBoard? {
    let next = RememberedBoard(id: readyID, name: readyName)
    return next == current ? nil : next
}

/// FORGET: does this failure mean the bond between this phone and the board is gone?
///
/// Only two answers count, and neither is a range or radio problem:
///  - CBError.peerRemovedPairingInformation: the board no longer holds this phone's keys.
///  - an ATT insufficient authentication / encryption / key size refusal: the link could not be
///    encrypted with the keys this phone holds (or the user declined re-pairing), so the board's
///    READ_ENC/WRITE_ENC characteristics refuse us.
/// A timeout, a transport error, or a drop with no error is NOT evidence: the board may simply be
/// off or out of range, and forgetting it then would cost the owner the row for nothing.
func connectionErrorMeansBondIsGone(_ error: Error?) -> Bool {
    guard let ns = error as NSError? else { return false }
    switch ns.domain {
    case CBErrorDomain:
        return ns.code == CBError.Code.peerRemovedPairingInformation.rawValue
    case CBATTErrorDomain:
        return ns.code == CBATTError.Code.insufficientAuthentication.rawValue
            || ns.code == CBATTError.Code.insufficientEncryption.rawValue
            || ns.code == CBATTError.Code.insufficientEncryptionKeySize.rawValue
    default:
        return false
    }
}

/// FORGET is scoped to the remembered board. A bond failure on some other board the user tapped
/// says nothing about the owner's board.
func shouldForgetRememberedBoard(rememberedID: UUID?, failingID: UUID, error: Error?) -> Bool {
    rememberedID == failingID && connectionErrorMeansBondIsGone(error)
}

/// One row of the connect picker. `rssi == nil` means no advertisement from this board is in the
/// current scan list, which is the normal state for the remembered board on the later firmware.
struct BoardPickerEntry: Equatable, Identifiable {
    let id: UUID
    var name: String
    var rssi: Int?
    var firmware: String?
    var isRemembered: Bool
}

/// SHOW: merge the remembered board into the scanned rows.
///  - The remembered board leads, whether or not an advertisement was seen. It appears only once
///    CoreBluetooth has handed back a peripheral for its identifier (`rememberedRetrieved`); a
///    row the app cannot connect would be a dead tap.
///  - If the scan also saw it (today's firmware), the scanned row folds INTO it: one row, the
///    live name, RSSI and firmware from the advertisement, never two rows.
///  - Every other scanned row keeps its scan order, so multiple boards nearby list exactly as
///    before.
/// Android twin: AcabBleManager.kt mergeRememberedRow / pickerRows (same lead and live-name rules).
func mergeBoardPickerEntries(remembered: RememberedBoard?, rememberedRetrieved: Bool,
                             scanned: [BoardPickerEntry]) -> [BoardPickerEntry] {
    guard let remembered, rememberedRetrieved else { return scanned }
    var lead = BoardPickerEntry(id: remembered.id, name: remembered.name, rssi: nil,
                                firmware: nil, isRemembered: true)
    var rest: [BoardPickerEntry] = []
    for row in scanned {
        if row.id == remembered.id {
            lead.name = row.name
            lead.rssi = row.rssi
            lead.firmware = row.firmware
        } else {
            rest.append(row)
        }
    }
    return [lead] + rest
}

/// Shared picker copy for the remembered row. Android twin: AcabBleManager.kt RememberedBoardCopy
/// (and its subtitle(), which mirrors ConnectView.boardRowSubtitle), byte-identical.
enum RememberedBoardCopy {
    static let label = "your beacon"
    static let noSignal = "no live signal \u{00B7} tap to connect"
    static let seen = "tap to connect"
}
