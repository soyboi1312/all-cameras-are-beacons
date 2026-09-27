package tech.acab.app.ble

/** Which product line a board belongs to, for COPY ONLY. The premium board is the beacon; the two
 *  Colonel Panic boards that run the same shared firmware keep their own names, so an OUI-Spy owner
 *  reads "your OUI-Spy" on the connect screen instead of being told they own a beacon.
 *
 *  Nothing here decides pairing, the GATT profile, OTA routing or any behaviour: the image a board
 *  runs decides those, and every kind runs the same service. Unknown is `null` (never a fourth
 *  case), and every copy function takes `BoardKind?` and renders null exactly as [BEACON], so a
 *  fresh install, a never-connected phone, an old remembered record and sample data all read as
 *  they always did.
 *
 *  [raw] is the stored and cross-platform value (the remembered record's `remembered_board_kind`
 *  pref). The nouns are proper nouns where they are not "beacon", so they keep their capitals
 *  mid-sentence while the sentence itself still starts lowercase ("your OUI-Spy is listening").
 *  TWIN: iOS BoardKind in ios/Beacons/Models/BoardKind.swift, the same raw values, nouns, titles,
 *  fw-label prefixes and advert names. */
enum class BoardKind(
    val raw: String,
    /** "your {noun}". */
    val noun: String,
    /** The noun with its article: "scan for {a_noun}". */
    val aNoun: String,
    /** "no {plural} found". OUI-Spy and Mesh-Detect are names, so they do not take an "s". */
    val plural: String,
    /** The noun as a C2 kicker ("WHAT YOUR {NOUN} CAN HEAR"). */
    val nounUpper: String,
    /** The Beacon tab hero's title. */
    val heroTitle: String,
) {
    BEACON("beacon", "beacon", "a beacon", "beacons", "BEACON", "All Cameras Are Beacons"),
    OUI_SPY("ouiSpy", "OUI-Spy", "an OUI-Spy", "OUI-Spy", "OUI-SPY", "OUI-Spy"),
    MESH_DETECT("meshDetect", "Mesh-Detect", "a Mesh-Detect", "Mesh-Detect", "MESH-DETECT", "Mesh-Detect");

    companion object {
        /** A stored raw value back to its kind; a missing or unknown value is null (unknown). */
        fun fromRaw(raw: String?): BoardKind? = entries.firstOrNull { it.raw == raw }

        /** AUTHORITATIVE. The Status frame's fw label (DeviceStatus.firmwareLabel, the fw string
         *  without its version). The labels are the wire contract in firmware/src/beacon-board/
         *  main.cpp (kFwLabel "beacon board", rev-B "beacon board rev-B", the single-radio
         *  "ACAB-ouispy") and firmware/src/mesh-detect/main.cpp ("mesh-detect-ACAB", "-ch<N>" on
         *  other channels). Prefixes, so rev-B, capture builds and channel builds all resolve. */
        fun fromFirmwareLabel(label: String?): BoardKind? = when {
            label == null -> null
            label.startsWith("beacon board") -> BEACON
            label.startsWith("ACAB-ouispy") -> OUI_SPY
            label.startsWith("mesh-detect") -> MESH_DETECT
            else -> null
        }

        /** A PRE-CONNECT HINT only, from a REAL advertised local name (ScanRecord.deviceName, never
         *  BluetoothDevice.name, a cached GAP name, and never the scan callback's "ACAB" fallback
         *  for a nameless advert, which would read every stealth board as an OUI-Spy). The dual
         *  board advertises "beacon", the single-radio OUI-Spy "ACAB", and Mesh-Detect "ACAB-mes"
         *  in its primary advert and "ACAB-mesh" in its scan response. Anything else is null. */
        fun fromAdvertName(name: String?): BoardKind? = when {
            name == null -> null
            name == "beacon" -> BEACON
            name == "ACAB" -> OUI_SPY
            name.startsWith("ACAB-mes") -> MESH_DETECT
            else -> null
        }
    }
}

/** The noun a copy template reads when the kind is unknown. */
private fun BoardKind?.orBeacon(): BoardKind = this ?: BoardKind.BEACON

/** This platform's name for the system pairing prompt, the one per-platform token the shared
 *  templates carry ({os_pairing_request}). TWIN: iOS osPairingRequest ("the iOS pairing request"). */
internal const val OS_PAIRING_REQUEST = "Android's pairing request"

/** Render one shared copy template for [kind] (null reads as beacon). The templates are plain
 *  literals with {noun}, {a_noun}, {plural}, {NOUN} and {os_pairing_request} tokens, identical
 *  byte for byte on both apps, so firmware/tools/check-signature-drift.py can compare them without
 *  evaluating any interpolation. Five replaces on a short string: cheap enough for a composition.
 *  TWIN: iOS renderBoardCopy in ios/Beacons/Models/BoardKind.swift. */
internal fun renderBoardCopy(template: String, kind: BoardKind?): String {
    val k = kind.orBeacon()
    return template
        .replace("{noun}", k.noun)
        .replace("{a_noun}", k.aNoun)
        .replace("{plural}", k.plural)
        .replace("{NOUN}", k.nounUpper)
        .replace("{os_pairing_request}", OS_PAIRING_REQUEST)
}

/** A row's advert hint after one more frame from the same address: the kind this frame's REAL
 *  advertised name implies, else the hint an earlier frame gave. A frame with no name (a scan
 *  response, the stealth advert) or with a name no kind claims keeps the earlier hint; only a
 *  name that names a kind replaces it. TWIN: iOS BLEManager's discovery merge, which writes
 *  `kindHint` only when the frame's hint is non-nil (the last non-nil hint wins). */
internal fun carriedAdvertHint(advertName: String?, previous: BoardKind?): BoardKind? =
    BoardKind.fromAdvertName(advertName) ?: previous

/** The kind of ONE board, by precedence, strongest first: the live Status fw label (pass it only
 *  when this board is the connected one), then the row's LIVE advert hint (a name this scan
 *  heard), then the kind stored on the remembered record (pass it only when this board IS the
 *  remembered one), else null. The live hint outranks the stored kind so a remembered board that
 *  was reflashed with another image reads by what it advertises NOW before connect; the stored
 *  kind still names a board that advertises no name (the stealth advert) or was not heard, and
 *  the first fw frame of the next READY session re-stamps the stored kind
 *  (rememberedBoardAfterStatus). Pure, so the order is pinned by a test.
 *  TWIN: iOS resolveBoardKind(firmwareLabel:storedKind:advertHint:) in ios/Beacons/Models/BoardKind.swift. */
internal fun resolveBoardKind(
    firmwareLabel: String?,
    storedKind: BoardKind?,
    advertHint: BoardKind?,
): BoardKind? = BoardKind.fromFirmwareLabel(firmwareLabel) ?: advertHint ?: storedKind

/** The kind the connected (or last connected) board reads as: its Status fw label while a frame is
 *  in, else [targetKind], which AcabBleManager resolved at connect (live advert hint > stored) and
 *  refreshed from every fw frame, so it survives the drop that clears the status. Read by the
 *  Beacon tab (hero title, About link, restore offer), the checklist and the Live Mode dialog. */
internal fun connectedBoardKind(firmwareLabel: String?, targetKind: BoardKind?): BoardKind? =
    BoardKind.fromFirmwareLabel(firmwareLabel) ?: targetKind

/** The kind for startup-screen copy that is not about one row:
 *   1. [targetKind] while a connect, pairing or reconnect is in flight or its failure is shown
 *      ([targetActive]), even when that is null;
 *   2. else [rememberedKind] when known;
 *   3. else the one kind every visible picker row agrees on ([rowKinds], each row's own kind);
 *   4. else null, which reads as beacon.
 *  So an OUI-Spy owner on a fresh install reads beacon copy until the scan hears their board, a
 *  phone that remembers an OUI-Spy reads OUI-Spy from launch, and a mixed scan stays beacon.
 *  TWIN: iOS resolveScreenKind in ios/Beacons/Models/BoardKind.swift. */
internal fun resolveScreenKind(
    targetActive: Boolean,
    targetKind: BoardKind?,
    rememberedKind: BoardKind?,
    rowKinds: List<BoardKind?>,
): BoardKind? {
    if (targetActive) return targetKind
    if (rememberedKind != null) return rememberedKind
    val first = rowKinds.firstOrNull() ?: return null
    return first.takeIf { rowKinds.all { it == first } }
}
