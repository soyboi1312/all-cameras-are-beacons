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
    }
    return false;
}
