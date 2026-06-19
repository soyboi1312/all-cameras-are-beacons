/*
 * ACAB - Police / Motorola Solutions gear detector implementation.
 * Signatures in police_signatures.h, sourced from the IEEE OUI registry.
 */
#include "police_detect.h"
#include "police_signatures.h"
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
    acabInit(out, ACAB_POLICE_GEAR, src, mac, (int16_t)rssi);
    out->method = M_OUI;
    out->confidence = 60;   // the device IS Motorola Solutions; "police" is the inference
    snprintf(out->detail, sizeof(out->detail), "Motorola Solutions OUI");
    return true;
}

bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out) {
    (void)adv; (void)advLen;
    if (!gEnabled) return false;
    if (!ouiMatch(mac)) return false;
    return emit(out, mac, rssi, SRC_BLE);
}

bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out) {
    if (!gEnabled || !frame || len < 24) return false;
    uint8_t ftype = (frame[0] >> 2) & 0x3;   // management frames only
    if (ftype != 0x0) return false;
    const uint8_t* addr2 = &frame[10];   // transmitter
    const uint8_t* addr3 = &frame[16];   // BSSID
    if (ouiMatch(addr2)) return emit(out, addr2, rssi, SRC_WIFI);
    if (ouiMatch(addr3)) return emit(out, addr3, rssi, SRC_WIFI);
    return false;
}
