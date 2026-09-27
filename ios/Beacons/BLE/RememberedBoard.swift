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

/// What is persisted: CoreBluetooth's per-phone peripheral UUID (not the board's BLE address),
/// the name to show before any advertisement arrives, and the board's kind as its Status `fw`
/// label last reported it (nil until the first frame of a ready session stamps it; see
/// rememberedBoardAfterStatusFrame). The kind is what lets the row say "your OUI-Spy" before any
/// advert, which becomes the only source once the stealth firmware stops advertising a name.
/// Stored per record, so the planned remembered LIST carries {id, name, kind} into each entry.
struct RememberedBoard: Equatable {
    let id: UUID
    let name: String
    var kind: BoardKind? = nil
}

/// The one reader/writer of the remembered board. Takes BLEManager's injected `defaults`, so a
/// hosted test passes a throwaway suite and never touches the real install. Read ONCE at init and
/// cached by BLEManager: nothing on the 3 Hz status path or in a SwiftUI body reads UserDefaults.
struct RememberedBoardStore {
    static let idKey = "rememberedBoardID"
    static let nameKey = "rememberedBoardName"
    /// BoardKind.rawValue. Missing (every install before this key) or unknown loads as nil, which
    /// reads as beacon until the next connect stamps the true kind. Never inferred from the stored
    /// name: "ACAB" is also the app's own nameless fallback, so a stored "ACAB" proves nothing.
    /// TWIN: Android remembered_board_kind in prefs "acab".
    static let kindKey = "rememberedBoardKind"

    let defaults: UserDefaults

    func load() -> RememberedBoard? {
        guard let raw = defaults.string(forKey: Self.idKey), let id = UUID(uuidString: raw)
        else { return nil }
        return RememberedBoard(id: id, name: defaults.string(forKey: Self.nameKey) ?? "",
                               kind: defaults.string(forKey: Self.kindKey).flatMap(BoardKind.init(rawValue:)))
    }

    func save(_ board: RememberedBoard?) {
        if let board {
            defaults.set(board.id.uuidString, forKey: Self.idKey)
            defaults.set(board.name, forKey: Self.nameKey)
            if let kind = board.kind {
                defaults.set(kind.rawValue, forKey: Self.kindKey)
            } else {
                defaults.removeObject(forKey: Self.kindKey)
            }
        } else {
            defaults.removeObject(forKey: Self.idKey)
            defaults.removeObject(forKey: Self.nameKey)
            defaults.removeObject(forKey: Self.kindKey)
        }
    }
}

/// REMEMBER: the board a session just reached secure readiness with becomes the remembered one.
/// A different board replaces the old one. Returns nil when nothing changes, so the caller writes
/// UserDefaults only on a real change (the OTA reboot reconnect re-runs readiness on the same
/// board and must not rewrite it).
///
/// The same board keeps its stored kind; a different board starts with none, and the first
/// status frame stamps it (rememberedBoardAfterStatusFrame, about a second later). The identity
/// short-circuit compares the kind too, through Equatable.
/// TWIN: Android rememberedBoardAfterReady (same keep / reset rule).
func rememberedBoardAfterSecureReady(current: RememberedBoard?, readyID: UUID,
                                     readyName: String) -> RememberedBoard? {
    let next = RememberedBoard(id: readyID, name: readyName,
                               kind: current?.id == readyID ? current?.kind : nil)
    return next == current ? nil : next
}

/// STAMP: the remembered record takes its kind from a status frame's `fw` label. Only a real,
/// ready session counts (never sample data), only a frame from the remembered board itself, only
/// a label that names a kind, and only when that kind differs from the stored one, so a 1 Hz
/// status stream writes UserDefaults once per board, not once per frame. The advert hint is never
/// stored: only the firmware's own label is evidence enough to keep.
/// Returns nil when nothing changes. TWIN: Android's first-frame stamp in AcabBleManager.kt.
func rememberedBoardAfterStatusFrame(current: RememberedBoard?, frameBoardID: UUID?,
                                     firmwareLabel: String, sessionReady: Bool,
                                     isDemoMode: Bool) -> RememberedBoard? {
    guard sessionReady, !isDemoMode, let current, let frameBoardID, frameBoardID == current.id,
          let kind = BoardKind.fromFirmwareLabel(firmwareLabel), kind != current.kind
    else { return nil }
    var next = current
    next.kind = kind
    return next
}

/// RETIRE: does this status frame retire the connected board's pre-session scan hint
/// (BLEManager.retirePreSessionKindHint)? Only a real, ready session counts (never sample data),
/// only when the row still carries a hint, and only a `fw` label that names a kind: that label has
/// just stamped the stored kind, so a sighting from before the session must not outrank it after a
/// drop or a disconnect. A label that names no kind leaves the hint in place.
func statusFrameRetiresKindHint(firmwareLabel: String, rowHint: BoardKind?, sessionReady: Bool,
                                isDemoMode: Bool) -> Bool {
    sessionReady && !isDemoMode && rowHint != nil && BoardKind.fromFirmwareLabel(firmwareLabel) != nil
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
/// `kind` is the row's kind for its copy: a scanned row's real advert hint, or for the remembered
/// row its live hint, else its stored kind (mergeBoardPickerEntries). Nil reads as beacon.
struct BoardPickerEntry: Equatable, Identifiable {
    let id: UUID
    var name: String
    var rssi: Int?
    var firmware: String?
    var isRemembered: Bool
    var kind: BoardKind? = nil
}

/// SHOW: merge the remembered board into the scanned rows.
///  - The remembered board leads, whether or not an advertisement was seen. It appears only once
///    CoreBluetooth has handed back a peripheral for its identifier (`rememberedRetrieved`); a
///    row the app cannot connect would be a dead tap.
///  - If the scan also saw it (today's firmware), the scanned row folds INTO it: one row, the
///    live name, RSSI and firmware from the advertisement, never two rows. Its kind is the live
///    advert hint when the scan heard a name, else the stored one (resolveBoardKind's order): a
///    board reflashed with another image reads as what it advertises now, and a nameless
///    (stealth) advert keeps the stored kind.
///  - Every other scanned row keeps its scan order, so multiple boards nearby list exactly as
///    before.
/// Android twin: AcabBleManager.kt mergeRememberedRow / pickerRows (same lead and live-name rules).
func mergeBoardPickerEntries(remembered: RememberedBoard?, rememberedRetrieved: Bool,
                             scanned: [BoardPickerEntry]) -> [BoardPickerEntry] {
    guard let remembered, rememberedRetrieved else { return scanned }
    var lead = BoardPickerEntry(id: remembered.id, name: remembered.name, rssi: nil,
                                firmware: nil, isRemembered: true, kind: remembered.kind)
    var rest: [BoardPickerEntry] = []
    for row in scanned {
        if row.id == remembered.id {
            lead.name = row.name
            lead.rssi = row.rssi
            lead.firmware = row.firmware
            lead.kind = row.kind ?? remembered.kind
        } else {
            rest.append(row)
        }
    }
    return [lead] + rest
}

/// Shared picker copy for the remembered row. Android twin: AcabBleManager.kt RememberedBoardCopy
/// (its label(kind) and subtitle(hasSignal)), byte-identical.
///
/// The subtitle no longer carries the advertised name ("ACAB \u{00B7} tap to connect"): beside
/// "your OUI-Spy" the raw name contradicted the title, and it never told two boards apart, since
/// every board of one kind advertises the same name.
enum RememberedBoardCopy {
    /// A template: render it with label(kind:).
    static let labelTemplate = "your {noun}"
    static let noSignal = "no live signal \u{00B7} tap to connect"
    static let seen = "tap to connect"

    /// "your beacon" / "your OUI-Spy" / "your Mesh-Detect"; unknown reads as beacon.
    static func label(kind: BoardKind?) -> String { renderBoardCopy(labelTemplate, kind) }

    /// The remembered row's second line: whether an advertisement is live, then the tap.
    static func subtitle(hasSignal: Bool) -> String { hasSignal ? seen : noSignal }
}
