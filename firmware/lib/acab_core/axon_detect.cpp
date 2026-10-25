/*
 * ACAB - Axon body-worn camera detector (field-validated, on by default).
 *
 * The AXON_OUI table below holds the two Axon OUIs (see axon_signatures.h); a public
 * MAC on either is the loose match (conf 75). The "BWCDEVICE" service-data tag is a
 * STANDALONE, MAC-independent match (conf 90, with or without the OUI - Axon is
 * moving to rotating BLE MACs, which breaks the OUI path). Axon's own Bluetooth SIG
 * numbers (service UUID 0xFE6B, and company ID 0x034D with its serial-shaped payload) are the
 * second MAC-independent match (conf 75, "Axon Bluetooth ID"): they name the vendor, not the product.
 *
 * Validating against a real unit:
 *   1. Put a BLE sniffer next to a powered Axon body cam.
 *   2. Note the advert: manufacturer company ID, static manufacturer-data bytes,
 *      the MAC OUI, any advertised name, and service-data tags.
 *   3. Put the OUI or tag in axon_signatures.h (an OUI also goes in AXON_OUI below),
 *      then axonSetEnabled(true).
 *   4. Check it fires on the Axon and NOT on nearby phones/wearables.
 */
#include "axon_detect.h"
#include "axon_signatures.h"
#include "acab_scanner.h"    // acabSanitizeAscii: clamp attacker-sourced names on ingest
#include "ascii_match.h"     // shared acabBytesContainAscii ("BWCDEVICE" tag) + acabAsciiCiContains
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include "acab_nvs_toggle.h" // persist the body-cam toggle across reboots (NVS)
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// TWO Axon OUIs, and they carry different kinds of evidence - both cited in axon_signatures.h,
// which is where the provenance for each lives. Read that file before touching either value.
//   AXON_OUI_REGISTERED (00:25:DF) is the block the IEEE registry attributes to Axon by name.
//     FIELD-VALIDATED 2026-06-17, and observed since on 13 distinct MACs in the serial logs
//     (recounted 2026-10-21).
//   AXON_OUI_BWC_FIELD (D8:1F:65) is a block the registry lists only as "Private", so it can never
//     name a registrant. At admission, attribution rested on 9 distinct MACs carrying two
//     independent Axon identifiers (the BWCDEVICE tag on eight, Axon's SIG service UUID 0xFE6B on
//     the ninth), across 2026-08-09 and 2026-09-19, five owner-confirmed by eye at the later
//     capture. On BLE it exists to catch Axon gear that sends no BWCDEVICE tag, which the tag path
//     misses by construction; that was exactly ONE device (04:a2:57), which 0xFE6B now catches too.
//     On WiFi it is the only match for the block: two owner-confirmed WiFi rows on 2026-10-21.
// The BWCDEVICE service-data tag remains the primary, MAC-independent signature at conf 90, and is
// the single best-evidenced signature in the tree: re-confirmed at two airports 2026-07-21, three
// more 2026-07-23 (SAN/DFW/Destin), two on the 2026-07-23 San Diego capture, three on 2026-08-09,
// and five owner-confirmed on 2026-09-19.
// OUI-only is the loose match (could be any Axon product); classify() also checks
// for the "BWCDEVICE" service-data tag, and when it's there, confirms body cam and
// raises confidence. An OUI-only hit on either block reports 75 on BLE.
static const uint8_t AXON_OUI[][3] = { AXON_OUI_REGISTERED, AXON_OUI_BWC_FIELD };

// Default on: field-validated 2026-06-17 (00:25:DF + BWCDEVICE).
static AcabNvsToggle gEnabled{"acab-axon", "on", true};

// NVS-backed so an app-set body-cam toggle survives a reboot (mirrors tracker/glasses).
// This is the CATEGORY switch: it covers Axon (OUI + the BWCDEVICE tag) and Utility
// BodyWorn, and the broad Motorola proxy gates on it too. Motorola has its own persisted
// sub-toggle on top (policeSetEnabled), so this no longer overwrites that choice.
void axonSetEnabled(bool enabled) { gEnabled.set(enabled); }
bool axonIsEnabled() { return gEnabled.on; }

// Reload the persisted toggle on boot; if none saved yet, use defaultEnabled.
void axonRestoreEnabled(bool defaultEnabled) { gEnabled.restore(defaultEnabled); }

// ---- local helpers (same AD parsing as flock_detect, kept separate) ----
// ASCII matching (the "BWCDEVICE" service-data tag in both byte orders, and the
// case-insensitive name substring) lives in the shared ascii_match.h.

struct AxAdv {
    char     name[40]; bool haveName;
    uint8_t  svc[48];  uint8_t svcLen;   // concatenated service-data / 128-bit-UUID bytes
    bool     sigSvc;                     // AD 0x16 service data under AXON_SIG_SVC_UUID, with a payload
    bool     sigCid;                     // AD 0xFF manufacturer data under AXON_SIG_COMPANY_ID, serial-shaped
};

// The 0x034D payload shape (AXON_SIG_CID_SERIAL_LEN in axon_signatures.h): 0x02, then a serial of
// uppercase letters and digits. p points at the first payload byte (data + 2); the caller, parseAdv,
// checks dataLen >= 2 + 1 + AXON_SIG_CID_SERIAL_LEN first, so every byte read here is inside the AD.
static bool axonCidSerial(const uint8_t* p) {
    if (p[0] != 0x02) return false;
    for (size_t k = 1; k <= AXON_SIG_CID_SERIAL_LEN; k++)
        if (!((p[k] >= '0' && p[k] <= '9') || (p[k] >= 'A' && p[k] <= 'Z'))) return false;
    return true;
}

static void parseAdv(const uint8_t* adv, size_t len, AxAdv* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;
        if ((adType == 0x08 || adType == 0x09) && !f->haveName) {
            // clamp the attacker-controlled advertised name to printable ASCII on ingest (same
            // invariant as the other ingest paths), not a raw memcpy.
            acabSanitizeAscii(f->name, data, dataLen, sizeof(f->name)); f->haveName = true;
        } else if (adType == 0x06 || adType == 0x07 ||   // 128-bit service-UUID list
                   adType == 0x20 || adType == 0x21 ||   // service data 32/128-bit
                   adType == 0x16) {                      // service data 16-bit
            uint8_t room = (uint8_t)(sizeof(f->svc) - f->svcLen);
            uint8_t n = dataLen < room ? dataLen : room;
            memcpy(f->svc + f->svcLen, data, n);
            f->svcLen += n;
            // Axon's SIG service UUID, little-endian, then at least one payload byte. Read from the
            // AD itself, not from svc[], so a full buffer cannot hide it.
            if (adType == 0x16 && dataLen >= 3 &&
                data[0] == (AXON_SIG_SVC_UUID & 0xFF) && data[1] == (AXON_SIG_SVC_UUID >> 8))
                f->sigSvc = true;
        } else if (adType == 0xFF && dataLen >= 2 + 1 + AXON_SIG_CID_SERIAL_LEN &&
                   data[0] == (AXON_SIG_COMPANY_ID & 0xFF) && data[1] == (AXON_SIG_COMPANY_ID >> 8) &&
                   axonCidSerial(data + 2)) {
            f->sigCid = true;   // Axon's SIG company ID, little-endian, then the serial shape
        }
        i += 1 + adLen;
    }
}

// The ONE OUI lookup, shared by the BLE and WiFi paths, so there is one place to edit an OUI.
// 0 = no match, 1 = Axon (AXON_OUI), 2 = Utility Inc. The caller needs to know WHICH so the
// detail string can name the right vendor.
static int axonOuiHit(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return 0;   // locally-administered / random MAC carries no real OUI
    for (size_t i = 0; i < sizeof(AXON_OUI) / sizeof(AXON_OUI[0]); i++)
        if (mac[0] == AXON_OUI[i][0] && mac[1] == AXON_OUI[i][1] &&
            mac[2] == AXON_OUI[i][2]) return 1;
    for (size_t i = 0; i < UTIL_BWC_OUI_COUNT; i++)
        if (mac[0] == UTIL_BWC_OUI[i][0] && mac[1] == UTIL_BWC_OUI[i][1] &&
            mac[2] == UTIL_BWC_OUI[i][2]) return 2;
    return 0;
}

// Classify one BLE advertisement. Returns false if the module is off (and Desert is not
// forcing it), or if none of the Axon OUI, the BWCDEVICE tag, Axon's SIG numbers and the Utility
// signals match.
bool axonClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                     int rssi, AcabDetection* out) {
    if (!gEnabled.on && !desertIsEnabled()) return false;

    AxAdv f;
    if (adv && advLen) parseAdv(adv, advLen, &f);
    else memset(&f, 0, sizeof(f));

    int  ouiHit = axonOuiHit(mac);
    bool sigHit = ouiHit == 1;   // a public MAC on one of the two Axon blocks

    // Durable, MAC-INDEPENDENT signal: the "BWCDEVICE" service-data tag. Axon is
    // moving to rotating BLE MACs, which breaks the OUI match - but the tag rides in
    // the advert payload, so make it a STANDALONE match (not just a confidence bump on
    // top of the OUI). A random-MAC Axon body cam still gets caught by its own tag.
    bool tagHit = acabBytesContainAscii(f.svc, f.svcLen, AXON_BWC_PAYLOAD);

    // Second MAC-independent signal: Axon's own SIG assigned numbers (axon_signatures.h). Names
    // the vendor, not the product, so it ranks below the tag and above the OUI.
    bool sigIdHit = f.sigSvc || f.sigCid;

    // Utility Inc. "BodyWorn" police body cam (a different brand, same body-cam category,
    // so it rides this same detector + toggle). The advertised name is the strong, MAC-
    // independent signal; the public OUI is the weaker fallback. Signatures (name + the
    // OUI table) live in axon_signatures.h next to their citations.
    bool utilName = acabAsciiCiContains(f.name, UTIL_BWC_NAME);
    bool utilOui  = ouiHit == 2;   // axonOuiHit already skipped locally-administered MACs
    bool utilHit  = utilName || utilOui;

    if (!sigHit && !tagHit && !sigIdHit && !utilHit) return false;

    acabInit(out, ACAB_AXON_BODYCAM, SRC_BLE, mac, (int16_t)rssi);
    if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);

    if (tagHit) {
        // Axon, confirmed by its own broadcast tag - highest confidence, and it survives
        // MAC randomization. Reported as service-data, not OUI.
        out->method = M_SERVICE_DATA;
        out->confidence = 90;
        snprintf(out->detail, sizeof(out->detail), "BWC DEVICE");
    } else if (sigIdHit) {
        // Axon equipment by its own SIG number, product unknown. 75, the same tier as the Axon OUI:
        // both say "Axon gear of some kind". This one wins the detail string because it is vendor-
        // issued and survives MAC randomization. Not M_OUI, so acabApplyDurability leaves it alone.
        out->method = f.sigSvc ? M_SERVICE_DATA : M_MFG_ID;
        out->confidence = 75;
        snprintf(out->detail, sizeof(out->detail), "Axon Bluetooth ID");
    } else if (sigHit) {
        // Axon loose match: OUI only (could be any Axon product). Weaker; the
        // OUI table only matches public MACs, so acabApplyDurability leaves it as-is.
        out->method = M_OUI;
        out->confidence = 75;
        snprintf(out->detail, sizeof(out->detail), "Axon OUI");
    } else {
        // Utility BodyWorn (the only remaining reason we didn't bail). The "BodyWorn Remote"
        // name is specific + MAC-independent, so it's a strong hit; OUI-only is the weak fallback
        // (Utility makes other gear too). Third-party field-observed, not own-captured yet.
        out->method = utilName ? M_NAME : M_OUI;
        out->confidence = utilName ? 85 : 70;
        snprintf(out->detail, sizeof(out->detail), "Utility BodyWorn");
    }
    return true;
}

// ---- WiFi OUI path (see the header for why this exists) --------------------------------
// Mirrors policeClassifyWiFi's shape: mgmt frames only, check transmitter then BSSID.
// Matches the SAME tables the BLE path uses, through the same axonOuiHit (AXON_OUI + Utility's).

static bool axonEmitWiFi(AcabDetection* out, const uint8_t mac[6], int rssi, bool utility) {
    acabInit(out, ACAB_AXON_BODYCAM, SRC_WIFI, mac, (int16_t)rssi);
    out->method = M_OUI;
    // 65, NOT the BLE tier's 75. The OUI read is just as reliable (these are public,
    // non-randomized MACs), but the TYPE claim is weaker on WiFi: the OUI says "an Axon
    // device", and Axon's WiFi estate includes docks, evidence terminals and station
    // infrastructure alongside Fleet in-car video. Field hits so far: eight (docs/signatures.md,
    // body cam section), six at owner-confirmed body-cam scenes. Where the BLE side was heard
    // too, the pair was ONE device: WiFi one below BLE on 00:25:DF, and on D8:1F:65 (one pair,
    // provisional) WiFi = (BLE - 1) + 0x800000. In the 2026-08-03 LVT capture the BLE side carried
    // the BWCDEVICE tag, so body cams transmit on WiFi. Same tier as an unvalidated netcam OUI,
    // below the field-validated Axon BLE match (75) and far below the BWCDEVICE tag (90). Raise
    // this only when captures show how often a WiFi Axon hit is fixed station gear rather than
    // gear on a person or in a car.
    out->confidence = 65;
    // Name the vendor that actually matched. axonOuiHit checks the Axon OUI table AND
    // Utility Inc's OUIs, so labelling every hit "Axon" misattributed Utility hardware to a
    // competitor, in a detail string the user reads to decide whether the match is credible.
    //
    // These strings are a WIRE CONTRACT: both apps resolve the body-cam vendor by EXACT match
    // against a fixed set (iOS BodyCamSignature, Android its twin), so an unrecognised string
    // silently degrades the detail screen. They must stay byte-identical to strings the BLE paths
    // already emit. No " on wifi" suffix for that reason, and because it would be redundant anyway: the
    // radio is already carried in the detection's own `source` field and shown as the band.
    if (utility) snprintf(out->detail, sizeof(out->detail), "%s", "Utility BodyWorn");
    else         snprintf(out->detail, sizeof(out->detail), "%s", "Axon OUI");
    return true;
}

bool axonClassifyWiFi(const uint8_t* frame, size_t len, int rssi, AcabDetection* out) {
    if (!gEnabled.on && !desertIsEnabled()) return false;
    if (!frame || len < 24) return false;
    if (((frame[0] >> 2) & 0x3) != 0x0) return false;   // management frames only
    const uint8_t* addr2 = &frame[10];   // transmitter
    const uint8_t* addr3 = &frame[16];   // BSSID
    if (int h = axonOuiHit(addr2)) return axonEmitWiFi(out, addr2, rssi, h == 2);
    if (int h = axonOuiHit(addr3)) return axonEmitWiFi(out, addr3, rssi, h == 2);
    return false;
}
