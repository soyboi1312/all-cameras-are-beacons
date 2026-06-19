/*
 * ACAB - Police / Motorola Solutions gear detector.
 *
 * OUI-only match on Motorola Solutions blocks (see police_signatures.h). Flags "a
 * Motorola Solutions device nearby" - a useful law-enforcement-equipment hint, but
 * broad (it catches any of their WiFi/BLE gear), so it is OFF by default and the
 * app / mesh turns it on.
 */
#ifndef ACAB_POLICE_DETECT_H
#define ACAB_POLICE_DETECT_H

#include "detection.h"
#include <stddef.h>

// Master on/off. Default: OFF (opt-in, like the tracker detector).
void policeSetEnabled(bool enabled);
bool policeIsEnabled();

// Match a Motorola Solutions OUI on a BLE advertiser's MAC.
bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out);

// Match a Motorola Solutions OUI on an 802.11 management frame (transmitter / BSSID).
bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out);

#endif // ACAB_POLICE_DETECT_H
