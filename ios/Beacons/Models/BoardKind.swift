import Foundation

/// Which product a board is, for COPY ONLY: the beacon (this project's own dual-radio board, the
/// premium device, and its single-radio "beacon c5" build), the Colonel Panic OUI-Spy, or the
/// Colonel Panic Mesh-Detect. The app names the hardware in the owner's hand ("your OUI-Spy is
/// listening") instead of calling every board a beacon. Nothing about pairing, OTA, detection or
/// the scan filter reads this.
///
/// Unknown is `nil`, never a case: every copy function takes `BoardKind?` and reads nil exactly as
/// `.beacon`, so a fresh install, a never-connected phone, an old remembered record and sample data
/// all keep today's beacon wording.
///
/// The raw values are STORED (RememberedBoardStore.kindKey) and shared with the Android twin,
/// android/app/src/main/java/tech/acab/app/ble/BoardKind.kt, byte for byte. So are the nouns,
/// the hero titles, the firmware-label prefixes and the advert names below.
///
/// The name follows the firmware IMAGE, not the hardware: a Colonel Panic board flashed with the
/// beacon image reports "beacon board" and reads as a beacon. That is right for copy, because the
/// image decides the behavior.
enum BoardKind: String, CaseIterable, Equatable {
    case beacon
    case ouiSpy
    case meshDetect

    /// The noun mid-sentence ("your OUI-Spy"). OUI-Spy and Mesh-Detect are proper nouns and keep
    /// their capitals; a sentence that opens with one still starts lowercase elsewhere.
    var noun: String {
        switch self {
        case .beacon: return "beacon"
        case .ouiSpy: return "OUI-Spy"
        case .meshDetect: return "Mesh-Detect"
        }
    }

    /// The noun with its article ("an OUI-Spy").
    var aNoun: String {
        switch self {
        case .beacon: return "a beacon"
        case .ouiSpy: return "an OUI-Spy"
        case .meshDetect: return "a Mesh-Detect"
        }
    }

    /// The plural ("no OUI-Spy found"). The two product names do not take an s.
    var plural: String {
        switch self {
        case .beacon: return "beacons"
        case .ouiSpy: return "OUI-Spy"
        case .meshDetect: return "Mesh-Detect"
        }
    }

    /// The noun in a C2 uppercase identifier ("WHAT YOUR OUI-SPY CAN HEAR").
    var upperNoun: String {
        switch self {
        case .beacon: return "BEACON"
        case .ouiSpy: return "OUI-SPY"
        case .meshDetect: return "MESH-DETECT"
        }
    }

    /// The Beacon tab hero's title. The beacon keeps the brand line; the other two name the
    /// product. TWIN: Android BoardKind.heroTitle.
    var heroTitle: String {
        switch self {
        case .beacon: return "All Cameras Are Beacons"
        case .ouiSpy: return "OUI-Spy"
        case .meshDetect: return "Mesh-Detect"
        }
    }

    /// The name each product's firmware advertises (firmware/src/beacon-board/main.cpp kBleName,
    /// firmware/src/mesh-detect/main.cpp acabBleBegin). Used only by the DEBUG `-boardKind` hook's
    /// display row, never to match a real advert (fromAdvertName does that).
    var advertisedName: String {
        switch self {
        case .beacon: return "beacon"
        case .ouiSpy: return "ACAB"
        case .meshDetect: return "ACAB-mesh"
        }
    }

    /// The Status `fw` label each product's firmware reports (without the version). The sample
    /// status frame reports `.beacon`'s ("beacon board"); the DEBUG `-demo -boardKind` hook swaps
    /// in another product's (BLEManager.seedDemoData).
    var sampleFirmwareLabel: String {
        switch self {
        case .beacon: return "beacon board"
        case .ouiSpy: return "ACAB-ouispy"
        case .meshDetect: return "mesh-detect-ACAB"
        }
    }

    /// AUTHORITATIVE: the kind from the connected board's Status `fw` label
    /// (DeviceStatus.firmwareLabel). "beacon" covers rev-A ("beacon board"), "beacon board rev-B",
    /// the capture builds and "beacon c5"; "mesh-detect" covers every channel build
    /// ("mesh-detect-ACAB-ch1"). Anything else, the empty label included, is unknown. TWIN: Android
    /// BoardKind.fromFirmwareLabel.
    static func fromFirmwareLabel(_ label: String?) -> BoardKind? {
        guard let label else { return nil }
        if label.hasPrefix("beacon") { return .beacon }
        if label.hasPrefix("ACAB-ouispy") { return .ouiSpy }
        if label.hasPrefix("mesh-detect") { return .meshDetect }
        return nil
    }

    /// A PRE-CONNECT HINT from a REAL advertised local name
    /// (advertisementData[CBAdvertisementDataLocalNameKey]), never from peripheral.name, which is a
    /// cached GAP name, and never from the app's own "ACAB" fallback: a nameless advert (the
    /// planned stealth firmware) must not read as an OUI-Spy. Mesh-Detect's primary advert carries
    /// the shortened "ACAB-mes" and its scan response "ACAB-mesh", so it matches the prefix.
    /// TWIN: Android BoardKind.fromAdvertName.
    static func fromAdvertName(_ name: String?) -> BoardKind? {
        guard let name else { return nil }
        if name == "beacon" { return .beacon }
        if name == "ACAB" { return .ouiSpy }
        if name.hasPrefix("ACAB-mes") { return .meshDetect }
        return nil
    }
}

/// THE PRECEDENCE for one board, strongest first: the live Status `fw` label (pass it only when
/// this board is the connected one), then the board's LIVE advert hint (a real name heard for it),
/// then the kind stored on the remembered record (pass it only when this board IS the remembered
/// one), then unknown. The live hint outranks the stored kind so a remembered board reflashed with
/// another image reads by what it advertises NOW before connect; the stored kind still names a
/// board that advertises no name (the stealth advert) or was not heard, and the first `fw` frame
/// of the next ready session re-stamps it (rememberedBoardAfterStatusFrame). The hint is never
/// stored. Pure, so the rule is pinned by a unit test. TWIN: Android resolveBoardKind.
func resolveBoardKind(firmwareLabel: String?, storedKind: BoardKind?,
                      advertHint: BoardKind?) -> BoardKind? {
    BoardKind.fromFirmwareLabel(firmwareLabel) ?? advertHint ?? storedKind
}

/// The kind for the connect-screen copy that is not about one row (the setup sentence, the
/// Bluetooth panels, "looking for your ...", the footnotes):
///  1. the target board's kind while a connect or reconnect runs or its failure is showing
///     (`targetActive`), whatever that kind is, nil included;
///  2. otherwise the remembered board's kind, when known;
///  3. otherwise the one kind every visible picker row agrees on;
///  4. otherwise nil, which reads as beacon. A mixed scan (a beacon and an OUI-Spy in range) and
///     an empty one stay beacon.
/// TWIN: Android resolveScreenKind.
func resolveScreenKind(targetActive: Bool, targetKind: BoardKind?, rememberedKind: BoardKind?,
                       rowKinds: [BoardKind?]) -> BoardKind? {
    if targetActive { return targetKind }
    if let rememberedKind { return rememberedKind }
    guard let first = rowKinds.first, let kind = first else { return nil }
    return rowKinds.allSatisfy { $0 == kind } ? kind : nil
}

/// This platform's words for the OS pairing prompt, the one hole a shared template carries that
/// differs per app. TWIN: Android OS_PAIRING_REQUEST ("Android's pairing request").
let osPairingRequest = "the iOS pairing request"

/// Fill a shared copy template's holes for `kind` (nil reads as beacon): {noun}, {a_noun},
/// {plural}, {NOUN} and {os_pairing_request}. The templates stay whole string literals at their
/// homes so check-signature-drift.py can compare them with the Android twins byte for byte; only
/// this function fills them. Five short replacements, cheap enough for a view body.
/// TWIN: Android renderBoardCopy.
func renderBoardCopy(_ template: String, _ kind: BoardKind?) -> String {
    let k = kind ?? .beacon
    return template
        .replacingOccurrences(of: "{noun}", with: k.noun)
        .replacingOccurrences(of: "{a_noun}", with: k.aNoun)
        .replacingOccurrences(of: "{plural}", with: k.plural)
        .replacingOccurrences(of: "{NOUN}", with: k.upperNoun)
        .replacingOccurrences(of: "{os_pairing_request}", with: osPairingRequest)
}

/// The Beacon tab hero's title for the connected board; unknown reads as the beacon's brand line.
func boardHeroTitle(_ kind: BoardKind?) -> String {
    (kind ?? .beacon).heroTitle
}

/// DEBUG `-boardKind ouiSpy|meshDetect|beacon`, for screenshots and UI checks. Only the three raw
/// values are accepted; anything else, or a flag with no value, is ignored. Parsed once in
/// ACABApp next to `-demo` (see BLEManager.applyDebugBoardKind). TWIN: Android
/// MainActivity.EXTRA_BOARD_KIND.
func boardKindLaunchArgument(_ args: [String]) -> BoardKind? {
    guard let i = args.firstIndex(of: "-boardKind"), i + 1 < args.count else { return nil }
    return BoardKind(rawValue: args[i + 1])
}
