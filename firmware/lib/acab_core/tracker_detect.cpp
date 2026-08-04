/*
 * ACAB - BLE item-tracker detector implementation.
 *
 * Signatures (all broadcast continuously by the tag, no pairing needed):
 *   - Apple Find My: manufacturer data, company id 0x004C (Apple), payload type
 *     0x12. The 0x19-length form is the "offline / separated from owner"
 *     broadcast - a tag away from its owner, i.e. the stalking-relevant one. We
 *     skip the shorter "nearby" form (ambient Apple gear) so we don't flag the
 *     user's own phone / earbuds.
 *   - Tile: 16-bit service DATA 0xFEED (with a payload, not a bare UUID-list entry).
 *   - Samsung SmartTag: 16-bit service DATA 0xFD5A (Samsung offline finding).
 *   Tile/Samsung are matched ONLY as SERVICE DATA (AD 0x16) carrying a real payload, and
 *   at a confidence BELOW Apple's - NOT yet field-validated against a real tag. A lone
 *   0xFEED/0xFD5A in a 0x02/0x03 UUID list is trivially spoofed and collides with random
 *   consumer gear, so that path is deliberately not matched.
 *
 * AirTags rotate their MAC, so we match on payload, never OUI.
 */
#include "tracker_detect.h"
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <string.h>
#include <stdio.h>
#include <Preferences.h>   // persist the on/off toggle across reboots (NVS)

#define TILE_SVC           0xFEED
#define SAMSUNG_SMARTTAG   0xFD5A
#define APPLE_COMPANY_ID   0x004C
// Google Find Hub / FMDN. Rides Google's EDDYSTONE UUID 0xFEAA, NOT Fast Pair 0xFE2C, so the UUID
// alone is worthless: every retail Eddystone beacon shares it. The discriminator is the frame-type
// byte, and it is safe because google/eddystone protocol-specification.md defines only UID 0x00,
// URL 0x10, TLM 0x20 and EID 0x30 - the 0x4x high nibble is RESERVED, so no defined Eddystone
// frame can reach this match. src: Google Find Hub Network Accessory Spec tables 15/16;
// PoPETs 2025(4) table 3 (Chipolo ONE/CARD Point, Moto Tag, Pebblebee Clip, Sony WH-1000XM5).
//
// WE MATCH 0x41 ONLY, which is the same rule as Apple's above and for the same reason: Google's
// spec says unwanted-tracking mode "maps to the 'separated state' defined by the DULT spec".
// DO NOT WIDEN THIS TO 0x40, the near-owner form. Three independent reasons, any one fatal:
//   - the spec advertises FHN frames unconditionally every 2s after provisioning, with no
//     owner-presence suppression and no model/class byte on air, so 0x40 comes off provisioned
//     earbuds and headphones sitting next to their owner (Sony WH-1000XM5 is on the list above);
//   - the spec MANDATES an RPA/NRPA rotating with the EID every ~1024s, so a 0x40 hit re-alerts
//     roughly every 17 minutes forever and an exact-MAC Ignore can NEVER silence it. That is the
//     Meta Quest pathology this project already compile-time-gates off;
//   - ACAB_TRACKER outranks ACAB_NEARBY_DEVICE for dedup tenure, so 0x40 churn would evict real
//     camera detections from the table.
// 0x41 is the opposite on every count: the spec pins the BLE address for 24h in UT mode, which is
// what makes Ignore hold and makes the follow-me scorer meaningful.
// ACCEPTED MISS, stated so nobody "fixes" it: an attacker can suppress 0x41 (PoPETs 7.1.2). The
// Apple row has the identical hole and this project already chose the miss. A miss beats crying
// wolf in a feature people use to find out whether they are being followed.
#define GOOGLE_FHN_SVC     0xFEAA
#define FHN_TYPE_SEPARATED 0x41   // UT mode ON == DULT "separated state"
#define FHN_TYPE_NEAROWNER 0x40   // UT mode off - DIAG watchlist only, NEVER matched
// Element lengths INCLUDING the 2 UUID bytes (i.e. sdLen == adLen-1). PINNED, not ranged: the
// spec lets the hashed-flags byte be omitted only "if the beacon doesn't support battery level
// indication AND isn't in unwanted tracking protection mode", so a conforming 0x41 always has it.
#define FHN_SD_LEN_20_UT   24     // 2 UUID + 1 type + 20B EID + 1 hashed flags
#define FHN_SD_LEN_32_UT   36     // 2 UUID + 1 type + 32B EID + 1 hashed flags (BLE5 ext adv)
#define APPLE_FINDMY_TYPE  0x12
#define FINDMY_OFFLINE_LEN 0x19   // separated-from-owner payload length
// Min length of a 16-bit service-DATA element (2 UUID bytes + payload) to accept a
// Tile/Samsung finding UUID - rejects a bare/empty entry a spoofer could trivially set.
#define TRK_MIN_SD         4

static bool gEnabled = false;

// NVS-backed so an app-set toggle survives a reboot. Only writes on a real change
// (toggles are rare), so flash wear is negligible.
void trackerSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p;
    p.begin("acab-trk", false);
    p.putBool("on", enabled);
    p.end();
}
bool trackerIsEnabled() { return gEnabled; }

// Restore the persisted on/off (or `defaultEnabled` if never set). Call once in
// setup() instead of hard-coding the default, so a board remembers a tracker scan
// you turned on in the app across power cycles.
void trackerRestoreEnabled(bool defaultEnabled) {
    Preferences p;
    p.begin("acab-trk", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// Pull out what we need: manufacturer data, and any 16-bit SERVICE DATA (AD 0x16)
// element with its payload length. We do NOT harvest bare 0x02/0x03 UUID-list entries
// for trackers - a lone finding UUID there is the spoof-prone case.
struct TrkAdv {
    uint16_t mfgId;     bool haveMfg;
    const uint8_t* mfg; uint8_t mfgLen;
    uint16_t sd16[12];  uint8_t sdLen[12]; uint8_t sdCount;   // 16-bit service-data UUID + element length
    const uint8_t* sd[12];                                    // -> the 2 UUID bytes; payload starts at [2]
};

static void parseAdv(const uint8_t* adv, size_t len, TrkAdv* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;
        if (adType == 0xFF && dataLen >= 2 && !f->haveMfg) {
            f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
            f->mfg = data; f->mfgLen = dataLen; f->haveMfg = true;
        } else if (adType == 0x16 && dataLen >= 2 && f->sdCount < 12) {  // 16-bit service data (UUID + payload)
            f->sd16[f->sdCount]  = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
            f->sdLen[f->sdCount] = dataLen;   // includes the 2 UUID bytes
            f->sd[f->sdCount]    = data;      // frame-type byte lives at data[2] (see FHN below)
            f->sdCount++;
        }
        i += 1 + adLen;
    }
}

// Fill and return a tracker detection - keeps the classify function tidy.
static bool emit(AcabDetection* out, const uint8_t mac[6], int rssi,
                 AcabMethod method, uint8_t conf, const char* what) {
    acabInit(out, ACAB_TRACKER, SRC_BLE, mac, (int16_t)rssi);
    out->method = method;
    out->confidence = conf;
    snprintf(out->detail, sizeof(out->detail), "%s", what);
    return true;
}

bool trackerClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out) {
    if ((!gEnabled && !desertIsEnabled()) || !adv || !advLen) return false;
    TrkAdv f; parseAdv(adv, advLen, &f);

    // Apple Find My - only the offline/separated form (tag away from its owner).
    if (f.haveMfg && f.mfgId == APPLE_COMPANY_ID && f.mfgLen >= 4 &&
        f.mfg[2] == APPLE_FINDMY_TYPE && f.mfg[3] == FINDMY_OFFLINE_LEN)
        return emit(out, mac, rssi, M_MFG_ID, 85, "Apple Find My (offline)");

    // Tile / Samsung SmartTag - require the finding UUID to arrive as SERVICE DATA with a
    // real payload (not a bare UUID-list entry), and keep confidence below Apple's until a
    // real tag is validated in the field. See the header note.
    for (uint8_t i = 0; i < f.sdCount; i++) {
        if (f.sdLen[i] < TRK_MIN_SD) continue;
        if (f.sd16[i] == TILE_SVC)
            return emit(out, mac, rssi, M_SERVICE_DATA, 65, "Tile");
        if (f.sd16[i] == SAMSUNG_SMARTTAG)
            return emit(out, mac, rssi, M_SERVICE_DATA, 60, "Samsung SmartTag");
        // Google Find Hub, separated form only. Length is pinned and the frame-type byte checked;
        // see the GOOGLE_FHN_SVC block above for why 0x40 is deliberately excluded.
        if (f.sd16[i] == GOOGLE_FHN_SVC && f.sd[i] &&
            (f.sdLen[i] == FHN_SD_LEN_20_UT || f.sdLen[i] == FHN_SD_LEN_32_UT) &&
            f.sd[i][2] == FHN_TYPE_SEPARATED)
            return emit(out, mac, rssi, M_SERVICE_DATA, 65, "Google Find Hub (separated)");
#ifdef ACAB_DIAG
        // Watchlist only, same pattern as the "Pigvision" candidate in flock_detect: logged in
        // DIAG builds, never a detection, no buzzer, no app row.
        //  (a) 0x40 density - the crowd count that would decide whether the near-owner form could
        //      ever be anything but noise. Promote nothing without that capture.
        //  (b) a 0x41 at an unexpected length - spec-noncompliant, and if it ever fires the pinned
        //      length gate above is costing us a real hit.
        if (f.sd16[i] == GOOGLE_FHN_SVC && f.sdLen[i] >= 4) {
            if (f.sd[i][2] == FHN_TYPE_NEAROWNER)
                Serial.printf("[fhn] 0x40 near-owner candidate, sdLen=%u\n", f.sdLen[i]);
            else if (f.sd[i][2] == FHN_TYPE_SEPARATED)
                Serial.printf("[fhn] 0x41 at UNEXPECTED sdLen=%u (expect 24/36)\n", f.sdLen[i]);
        }
#endif
    }
    return false;
}
