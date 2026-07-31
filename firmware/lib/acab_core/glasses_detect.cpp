/*
 * ACAB - Smart / recording-glasses detector implementation.
 *
 * Match: the BLE manufacturer-specific data (AD type 0xFF) company ID - the first two
 * payload bytes, LITTLE-ENDIAN per the BLE spec (data[0] = low byte, data[1] = high
 * byte) - against the verified eyewear company-ID table (glasses_signatures.h). The
 * company ID is in the advert payload, not the MAC, so this survives BLE MAC
 * randomization.
 *
 * Quest disambiguation: for the Meta corporate IDs (shared with the Meta Quest VR
 * headset) we also look for the "META_RB_GLASS" ASCII token in the manufacturer data.
 * When it is present, the hit is confirmed glasses (higher confidence, no Quest caveat).
 * When it is absent, shared corporate IDs (Quest / TCL-phone overlap) do NOT emit at
 * all in shipped builds: a Quest advertises from a rotating private address, so a bare
 * shared-ID match re-alerts on every rotation and the exact-MAC Ignore can never
 * silence it. CAPTURE-PENDING: the token's on-wire framing is unverified, so it is
 * only ever a confidence bump, never a standalone match.
 */
#include "glasses_detect.h"
#include "glasses_signatures.h"
#include "ascii_match.h"     // shared acabBytesContainAscii (META_RB_GLASS token, both byte orders)
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <string.h>
#include <stdio.h>
#include <Preferences.h>   // persist the on/off toggle across reboots (NVS)

static bool gEnabled = true;   // default ON: the company-ID match is specific, not a flood risk

// Bare matches on SHARED corporate IDs (sharedId in glasses_signatures.h) are compile-time
// OFF: 0x058E is also the Meta Quest's own registration, and a Quest's rotating private
// address defeats dedup and per-MAC ignore, so a household Quest would beep forever with
// no way to mute it short of disabling the whole category. Build-time only, deliberately
// no setter / NVS / BLE toggle: flip it only after a field-verified payload discriminator
// exists (the META_RB_GLASS token path below stays live regardless of this flag).
static const bool kGlassesSharedIdsEnabled = false;

// NVS-backed so an app-set toggle survives a reboot. Only writes on a real change
// (toggles are rare), so flash wear is negligible.
void glassesSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p;
    p.begin("acab-glass", false);
    p.putBool("on", enabled);
    p.end();
}
bool glassesIsEnabled() { return gEnabled; }

// Restore the persisted on/off (or `defaultEnabled` if never set). Call once in setup()
// instead of hard-coding the default, so a board remembers an app-set toggle across
// power cycles.
void glassesRestoreEnabled(bool defaultEnabled) {
    Preferences p;
    p.begin("acab-glass", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// Pull out just the manufacturer-specific data (AD type 0xFF): company ID + payload.
struct GlAdv {
    uint16_t mfgId;     bool haveMfg;
    const uint8_t* mfg; uint8_t mfgLen;   // includes the 2 company-id bytes
};

static void parseAdv(const uint8_t* adv, size_t len, GlAdv* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;
        if (adType == 0xFF && dataLen >= 2 && !f->haveMfg) {
            // BLE company ID is little-endian: low byte first.
            f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
            f->mfg = data; f->mfgLen = dataLen; f->haveMfg = true;
        }
        i += 1 + adLen;
    }
}

bool glassesClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out) {
    if ((!gEnabled && !desertIsEnabled()) || !adv || !advLen) return false;

    GlAdv f; parseAdv(adv, advLen, &f);
    if (!f.haveMfg) return false;

    for (size_t i = 0; i < GLASSES_SIG_COUNT; i++) {
        const GlassesSig& s = GLASSES_SIGS[i];
        if (f.mfgId != s.companyId) continue;

        // For the Meta corporate IDs (shared with the Quest), the META_RB_GLASS token in
        // the manufacturer data confirms glasses over a VR headset. Token search skips
        // the 2 company-id bytes.
        bool tokenConfirmed = s.metaShared && f.mfgLen > 2 &&
            acabBytesContainAscii(f.mfg + 2, (uint8_t)(f.mfgLen - 2), GLASSES_META_TOKEN);

        // Shared corporate IDs (Quest / TCL phones) only emit when the token confirms
        // glasses; a bare shared-ID hit is a Quest-shaped false alarm (see the gate above).
        if (s.sharedId && !kGlassesSharedIdsEnabled && !tokenConfirmed) continue;

        acabInit(out, ACAB_GLASSES, SRC_BLE, mac, (int16_t)rssi);
        out->method     = M_MFG_ID;   // company ID in the payload; survives MAC randomization
        out->confidence = s.confidence;
        snprintf(out->detail, sizeof(out->detail), "%s", s.detail);

        if (tokenConfirmed) {
            out->confidence = GLASSES_META_CONFIRMED_CONF;
            snprintf(out->detail, sizeof(out->detail), "Ray-Ban Meta: recording glasses");
        }
        return true;
    }
    return false;
}
