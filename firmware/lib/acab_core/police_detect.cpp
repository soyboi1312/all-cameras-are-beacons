/*
 * ACAB - Motorola Solutions gear detector (a law-enforcement-equipment proxy).
 * Matches are reported under the BODY-CAM device type, so the apps fold them into the
 * "Body cam" category (the separate police-gear category is merged into body cam).
 * Signatures in police_signatures.h, sourced from the IEEE OUI registry.
 */
#include "police_detect.h"
#include "police_signatures.h"
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <string.h>
#include <stdio.h>

static bool gEnabled = false;   // OFF by default: broad OUI match, opt-in

void policeSetEnabled(bool enabled) { gEnabled = enabled; }
bool policeIsEnabled() { return gEnabled; }

static bool ouiMatch(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;   // skip locally-administered / random MACs (no real OUI)
    for (size_t i = 0; i < POLICE_OUI_COUNT; i++)
        if (mac[0] == POLICE_OUI[i][0] && mac[1] == POLICE_OUI[i][1] &&
            mac[2] == POLICE_OUI[i][2]) return true;
    return false;
}

static bool emit(AcabDetection* out, const uint8_t mac[6], int rssi, AcabSource src) {
    // Reported under the body-cam type so the apps bucket it in the "Body cam" category.
    // The detail names the real source; no "police" wording goes on the wire, which keeps
    // the iOS build App-Store-safe (iOS no longer has to special-case a police category).
    acabInit(out, ACAB_AXON_BODYCAM, src, mac, (int16_t)rssi);
    out->method = M_OUI;
    out->confidence = 60;   // the device IS Motorola Solutions (an LE-equipment proxy)
    snprintf(out->detail, sizeof(out->detail), "Motorola Solutions OUI");
    return true;
}

bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out) {
    (void)adv; (void)advLen;
    if (!gEnabled && !desertIsEnabled()) return false;
    if (!ouiMatch(mac)) return false;
    return emit(out, mac, rssi, SRC_BLE);
}

bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out) {
    if ((!gEnabled && !desertIsEnabled()) || !frame || len < 24) return false;
    uint8_t ftype = (frame[0] >> 2) & 0x3;   // management frames only
    if (ftype != 0x0) return false;
    const uint8_t* addr2 = &frame[10];   // transmitter
    const uint8_t* addr3 = &frame[16];   // BSSID
    if (ouiMatch(addr2)) return emit(out, addr2, rssi, SRC_WIFI);
    if (ouiMatch(addr3)) return emit(out, addr3, rssi, SRC_WIFI);
    return false;
}
