/*
 * ACAB - Drone detector (FAA Remote ID / ASTM F3411, via OpenDroneID).
 *
 * Wraps the vendored opendroneid-core-c decoder. One classifier per way a drone
 * can broadcast Remote ID:
 *   - BLE : service-data advertisement, UUID 0xFFFA, app code 0x0D
 *   - WiFi: NAN action frames, and beacon vendor IEs (90:3a:e6 / fa:0b:bc)
 *
 * The ODID decode is the vendored opendroneid-core-c (Apache-2.0); the AD/frame
 * walking that locates the Remote ID bytes parses the public ASTM F3411 / ODID
 * wire formats directly. See docs/signatures.md.
 */
#ifndef ACAB_DRONE_DETECT_H
#define ACAB_DRONE_DETECT_H

#include "detection.h"
#include <stddef.h>

// Look for Remote ID in a BLE advertisement. `payload` is the full advertising
// payload (AD structures); we hunt for the ODID service-data block inside it.
bool droneClassifyBLE(const uint8_t mac[6], const uint8_t* payload, size_t len,
                      int rssi, AcabDetection* out);

// Look for Remote ID in an 802.11 frame captured in promiscuous mode (NAN
// action frame, or a beacon carrying an ODID vendor IE).
bool droneClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                       AcabDetection* out);

#endif // ACAB_DRONE_DETECT_H
