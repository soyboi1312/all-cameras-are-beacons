/*
 * ACAB - Motorola Solutions gear detector (a law-enforcement-equipment proxy), including
 * WatchGuard Video, the in-car and body-worn video maker Motorola Solutions owns.
 * Matches are reported under the BODY-CAM device type, so the apps fold them into the
 * "Body cam" category (the separate police-gear category is merged into body cam).
 * Signatures in bodycam_vendor_signatures.h, sourced from the IEEE OUI registry.
 */
#include "police_detect.h"
#include "bodycam_vendor_signatures.h"
#include "axon_detect.h"     // parent category switch: this is a SUB-toggle of body cam
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include "acab_nvs_toggle.h" // persist the Motorola sub-toggle across reboots (NVS)
#include <string.h>
#include <stdio.h>

// Module default off; main.cpp restores the persisted value at boot, and EVERY board passes
// false - both beacon-board and mesh-detect call policeRestoreEnabled(false). Opt-in since
// the 2026-07-23 ground truth; see the banner in bodycam_vendor_signatures.h.
static AcabNvsToggle gEnabled{"acab-moto", "on", false};

void policeSetEnabled(bool enabled) { gEnabled.set(enabled); }
bool policeIsEnabled() { return gEnabled.on; }

// Reload the persisted sub-toggle on boot; if none saved yet, use defaultEnabled.
void policeRestoreEnabled(bool defaultEnabled) { gEnabled.restore(defaultEnabled); }

// This match is a SUB-TOGGLE of the body-cam category, so it needs BOTH switches:
// the category (axon) must be on, and this broad-match opt-out must not be set.
// Turning the category off kills every body-cam signature; turning only this off
// leaves the conf-90 Axon BWCDEVICE tag and Utility BodyWorn running. Desert mode
// forces classification regardless, as it does for every other detector.
static inline bool active() {
    if (desertIsEnabled()) return true;
    return gEnabled.on && axonIsEnabled();
}

// The detail string per table. WIRE CONTRACT: both apps resolve the maker from these EXACT
// strings (BodyCamSignature in OUIVendors.swift / OuiVendors.kt). A WatchGuard Video block
// reported as "Motorola Solutions OUI" would name the parent company and tell the user the
// block is Motorola's own, which the registry says it is not.
static const char kMotorolaDetail[]   = "Motorola Solutions OUI";
static const char kWatchGuardDetail[] = "WatchGuard Video OUI";

static bool prefixIn(const uint8_t mac[6], const uint8_t (*table)[3], size_t count) {
    for (size_t i = 0; i < count; i++)
        if (mac[0] == table[i][0] && mac[1] == table[i][1] && mac[2] == table[i][2]) return true;
    return false;
}

// The detail string for the table this MAC's OUI sits in, or nullptr for no match.
static const char* ouiMatch(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return nullptr;   // skip locally-administered / random MACs (no real OUI)
    if (prefixIn(mac, POLICE_OUI, POLICE_OUI_COUNT)) return kMotorolaDetail;
    if (prefixIn(mac, WATCHGUARD_VIDEO_OUI, WATCHGUARD_VIDEO_OUI_COUNT)) return kWatchGuardDetail;
    return nullptr;
}

static bool emit(AcabDetection* out, const uint8_t mac[6], int rssi, AcabSource src,
                 const char* detail) {
    // Reported under the body-cam type so the apps bucket it in the "Body cam" category.
    // The detail names the real source; no "police" wording goes on the wire, which keeps
    // the iOS build App-Store-safe (iOS no longer has to special-case a police category).
    acabInit(out, ACAB_AXON_BODYCAM, src, mac, (int16_t)rssi);
    out->method = M_OUI;
    // Confidence grades the TYPE claim ("body camera"), not the vendor read: each table is
    // that company's own block, so the vendor is right, but Motorola's dominant 2.4 GHz
    // products are two-way radios, docks, and infrastructure carried by retail/school/venue
    // staff, and WatchGuard's block also carries its in-car video and docks, so "body camera"
    // is often wrong. Held below 50 so both apps draw the amber weak-match "verify this"
    // treatment instead of a calm partial match. One number for both tables on purpose.
    out->confidence = 45;
    snprintf(out->detail, sizeof(out->detail), "%s", detail);
    return true;
}

bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out) {
    (void)adv; (void)advLen;
    if (!active()) return false;
    const char* detail = ouiMatch(mac);
    if (!detail) return false;
    return emit(out, mac, rssi, SRC_BLE, detail);
}

bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out) {
    if (!active() || !frame || len < 24) return false;
    uint8_t ftype = (frame[0] >> 2) & 0x3;   // management frames only
    if (ftype != 0x0) return false;
    const uint8_t* addr2 = &frame[10];   // transmitter
    const uint8_t* addr3 = &frame[16];   // BSSID
    if (const char* detail = ouiMatch(addr2)) return emit(out, addr2, rssi, SRC_WIFI, detail);
    if (const char* detail = ouiMatch(addr3)) return emit(out, addr3, rssi, SRC_WIFI, detail);
    return false;
}
