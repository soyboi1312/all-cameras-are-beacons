/*
 * ACAB - Flock Safety detector implementation.
 * Matching logic only; the signature tables are in flock_signatures.h, sourced
 * from public registries and research (see docs/signatures.md).
 */
#include "flock_detect.h"
#include "flock_signatures.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Signature tables now live in flock_signatures.h (public-sourced; see
// docs/signatures.md). Retune detection by editing that header; this file is
// matching logic only.
// ---------------------------------------------------------------------------
static bool gFlockExtendedOui = false;   // default: high-confidence OUIs only

// True only for the vendor-specific Raven UUIDs (0x31xx-0x35xx), not the generic BT SIG ones.
static bool isRavenVendorSvc(uint16_t u) {
    return u == RAVEN_SVC_GPS || u == RAVEN_SVC_POWER || u == RAVEN_SVC_NETWORK ||
           u == RAVEN_SVC_UPLOAD || u == RAVEN_SVC_ERROR;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static bool ouiMatch(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;   // skip locally-administered / random MACs (no real OUI)
    for (size_t i = 0; i < FLOCK_OUI_COUNT; i++) {
        if (mac[0] == FLOCK_OUI[i].b[0] && mac[1] == FLOCK_OUI[i].b[1] &&
            mac[2] == FLOCK_OUI[i].b[2]) {
            if (FLOCK_OUI[i].ext && !gFlockExtendedOui) continue;  // extended-only
            return true;
        }
    }
    return false;
}

// Falcon cameras' Liteon WiFi-module OUIs (probe-request matched - see
// flockClassifyWiFi). Same random-MAC guard as ouiMatch.
static bool falconWifiOui(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;
    for (size_t i = 0; i < FALCON_WIFI_OUI_COUNT; i++) {
        if (mac[0] == FALCON_WIFI_OUI[i].b[0] && mac[1] == FALCON_WIFI_OUI[i].b[1] &&
            mac[2] == FALCON_WIFI_OUI[i].b[2])
            return true;
    }
    return false;
}

// case-insensitive substring (so we don't depend on GNU strcasestr)
static bool ciContains(const char* hay, const char* needle) {
    if (!hay || !needle || !*needle) return false;
    for (const char* p = hay; *p; p++) {
        const char* a = p; const char* b = needle;
        while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
        if (!*b) return true;
    }
    return false;
}

static bool nameMatch(const char* name) {
    if (!name || !name[0]) return false;
    for (size_t i = 0; i < FLOCK_NAME_COUNT; i++)
        if (ciContains(name, FLOCK_NAME_PATTERNS[i])) return true;
    // Bare 10-digit-name matching removed 2026-06-18: in the field it false-
    // positived on rotating/private BLE addresses with placeholder numeric names (a
    // phone advertising "0102000000", not a camera). The specific Flock signatures
    // (Penguin / FS / 0x09C8 / Flock- SSID / b4:1e:52) stay. To bring 10-digit
    // matching back safely, gate it on a public (non-random) BLE address.
    return false;
}

// ---------------------------------------------------------------------------
// BLE advertisement AD-structure parser.
// Pulls out the name, manufacturer company id, and the 16-bit service UUIDs.
// ---------------------------------------------------------------------------
struct AdvFields {
    char     name[40];
    bool     haveName;
    uint16_t mfgId;
    bool     haveMfg;
    uint16_t svc16[16];   // up to 16 short service UUIDs
    uint8_t  svcCount;
    bool     raven_gps, raven_power, raven_oldloc;
};

static void parseAdv(const uint8_t* adv, size_t len, AdvFields* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;

        switch (adType) {
            case 0x08: // shortened local name
            case 0x09: // complete local name
                if (!f->haveName) {
                    uint8_t n = dataLen < sizeof(f->name) - 1 ? dataLen : sizeof(f->name) - 1;
                    memcpy(f->name, data, n);
                    f->name[n] = 0;
                    f->haveName = true;
                }
                break;
            case 0xFF: // manufacturer specific data: [company_id LE][...]
                if (dataLen >= 2 && !f->haveMfg) {
                    f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
                    f->haveMfg = true;
                }
                break;
            case 0x02: // incomplete list of 16-bit service UUIDs
            case 0x03: // complete list of 16-bit service UUIDs
                for (uint8_t k = 0; k + 1 < dataLen && f->svcCount < 16; k += 2) {
                    uint16_t u = (uint16_t)data[k] | ((uint16_t)data[k+1] << 8);
                    f->svc16[f->svcCount++] = u;
                    if (u == RAVEN_SVC_GPS)    f->raven_gps = true;
                    if (u == RAVEN_SVC_POWER)  f->raven_power = true;
                    if (u == RAVEN_SVC_OLDLOC) f->raven_oldloc = true;
                }
                break;
            case 0x06: // incomplete list of 128-bit service UUIDs
            case 0x07: { // complete list of 128-bit service UUIDs
                // Raven advertises its services in 128-bit form, which the 16-bit
                // walk above never sees - so Ravens used to fall through to a
                // camera OUI/name match. Each UUID is 16 bytes, little-endian, and
                // Raven's all sit on the Bluetooth base UUID
                // (0000xxxx-0000-1000-8000-00805f9b34fb), so match that LE prefix
                // and pull the 16-bit short back out for the Raven test below.
                static const uint8_t BT_BASE_LE[12] =
                    { 0xfb,0x34,0x9b,0x5f,0x80,0x00,0x00,0x80,0x00,0x10,0x00,0x00 };
                for (uint8_t k = 0; k + 16 <= dataLen && f->svcCount < 16; k += 16) {
                    const uint8_t* u = &data[k];
                    if (memcmp(u, BT_BASE_LE, 12) != 0 || u[14] || u[15]) continue;
                    uint16_t s = (uint16_t)u[12] | ((uint16_t)u[13] << 8);
                    f->svc16[f->svcCount++] = s;
                    if (s == RAVEN_SVC_GPS)    f->raven_gps = true;
                    if (s == RAVEN_SVC_POWER)  f->raven_power = true;
                    if (s == RAVEN_SVC_OLDLOC) f->raven_oldloc = true;
                }
                break;
            }
            default: break;
        }
        i += 1 + adLen;
    }
}

// Rough Raven firmware-family guess from which service UUIDs are present - the
// set changes between Raven generations, so it's only a hint.
static const char* estimateRavenFW(const AdvFields* f) {
    if (f->raven_oldloc && !f->raven_gps) return "1.1.x";
    if (f->raven_gps && !f->raven_power)  return "1.2.x";
    if (f->raven_gps && f->raven_power)   return "1.3.x";
    return "?";
}

// ---------------------------------------------------------------------------
// Public: BLE classifier
// ---------------------------------------------------------------------------
bool flockClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                      int rssi, AcabDetection* out) {
    AdvFields f;
    if (adv && advLen) parseAdv(adv, advLen, &f);
    else memset(&f, 0, sizeof(f));

    bool ravenVendor = false;
    for (uint8_t i = 0; i < f.svcCount; i++)
        if (isRavenVendorSvc(f.svc16[i])) { ravenVendor = true; break; }

    // --- Raven (audio/gunshot detector): most specific, so check it first ---
    if (ravenVendor) {
        acabInit(out, ACAB_FLOCK_RAVEN, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_SERVICE_UUID;
        out->confidence = 92;
        if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
        snprintf(out->detail, sizeof(out->detail), "raven fw %s", estimateRavenFW(&f));
        return true;
    }

    // --- Flock camera: manufacturer ID (XUNTONG) ---
    if (f.haveMfg) {
        for (size_t i = 0; i < FLOCK_MFG_COUNT; i++) {
            if (f.mfgId == FLOCK_MFG_IDS[i]) {
                acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
                out->method = M_MFG_ID;
                out->confidence = 85;
                if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
                snprintf(out->detail, sizeof(out->detail), "mfg 0x%04X", f.mfgId);
                return true;
            }
        }
    }

    // --- Flock camera: advertised-name pattern ---
    if (f.haveName && nameMatch(f.name)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_NAME;
        out->confidence = 80;
        strncpy(out->name, f.name, sizeof(out->name) - 1);
        return true;
    }

    // --- Flock camera: known OUI (weakest signal - OUIs drift over time) ---
    if (ouiMatch(mac)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_BLE, mac, (int16_t)rssi);
        out->method = M_OUI;
        out->confidence = 65;
        if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);
        return true;
    }

    return false;
}

// ---------------------------------------------------------------------------
// Public: WiFi classifier (802.11 management frames)
// Frame layout: [fc(2)][dur(2)][addr1(6)][addr2(6)][addr3(6)][seq(2)]...
// ---------------------------------------------------------------------------
bool flockClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                       AcabDetection* out) {
    if (!frame || len < 24) return false;

    uint8_t ftype    = (frame[0] >> 2) & 0x3;   // 0 = management
    uint8_t subtype  = (frame[0] >> 4) & 0xF;
    if (ftype != 0x0) return false;

    const uint8_t* addr2 = &frame[10];  // transmitter
    const uint8_t* addr3 = &frame[16];  // BSSID

    // Pull the SSID IE (id 0) if this frame carries one (beacon / probe-resp /
    // probe-req). Read up front, because the SSID is now the primary signal.
    char ssid[33] = {0};
    bool sawSSID = false, emptySSID = false;
    for (size_t ie = 24; ie + 2 <= len; ) {
        uint8_t id = frame[ie], l = frame[ie + 1];
        if (ie + 2 + l > len) break;
        if (id == 0) {                       // SSID element
            sawSSID = true;
            emptySSID = (l == 0);
            uint8_t n = l < 32 ? l : 32;
            memcpy(ssid, &frame[ie + 2], n);
            ssid[n] = 0;
            break;
        }
        ie += 2 + l;
    }

    // --- Primary: the "Flock-<partial MAC>" AP name is the strong WiFi signature
    //     (src: ryanohoro / GainSec). Match it directly with no OUI gate, since a
    //     camera's WiFi MAC belongs to the module maker, not Flock's own OUI. ---
    size_t pfxLen = strlen(FLOCK_SSID_PREFIX);
    if (sawSSID && !emptySSID && strncmp(ssid, FLOCK_SSID_PREFIX, pfxLen) == 0) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_SSID;
        out->confidence = 88;
        strncpy(out->name, ssid, sizeof(out->name) - 1);
        return true;
    }

    // --- Secondary: Flock's own OUI (B4:1E:52) on the transmitter or BSSID ---
    bool txHit  = ouiMatch(addr2);
    bool bssHit = ouiMatch(addr3);

    // Falcon cams ride as WiFi clients (Liteon module, no "Flock-" AP) and give
    // themselves away with PROBE REQUESTS. Match their OUI on a probe request only -
    // Liteon is shared silicon, so the probe-req gate holds the false positives down.
    // (Field-validated at a live Falcon, 2026-06.)
    if (subtype == 0x4 && falconWifiOui(addr2)) {
        acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, addr2, (int16_t)rssi);
        out->method = M_PROBE;
        out->confidence = 72;
        snprintf(out->detail, sizeof(out->detail), "Falcon probe (OUI)");
        return true;
    }

    if (!txHit && !bssHit) return false;

    const uint8_t* src = txHit ? addr2 : addr3;
    acabInit(out, ACAB_FLOCK_CAMERA, SRC_WIFI, src, (int16_t)rssi);

    // An empty-SSID probe request from a Flock OUI is the documented strong signal.
    if (subtype == 0x4 && sawSSID && emptySSID) {
        out->method = M_PROBE;
        out->confidence = 78;
        snprintf(out->detail, sizeof(out->detail), "wildcard probe");
    } else {
        out->method = M_OUI;
        out->confidence = 68;
        if (ssid[0]) strncpy(out->name, ssid, sizeof(out->name) - 1);
    }
    return true;
}
