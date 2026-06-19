/*
 * ACAB - Unified scanner.
 *
 * Owns the radios and runs every detector at once:
 *   - NimBLE active scan            -> drone (RID) + Flock + Axon, per advert
 *   - 802.11 promiscuous + hopping  -> drone (RID) + Flock, per mgmt frame
 *
 * De-dupes by (type, MAC) and calls the firmware-supplied sink once per new
 * sighting (and again on refresh after the dedup window). The two builds
 * (OUI-Spy, Mesh-Detect) differ only in the sink they register.
 */
#ifndef ACAB_SCANNER_H
#define ACAB_SCANNER_H

#include "detection.h"

struct AcabScannerConfig {
    bool        enableBLE;          // scan BLE advertisements
    bool        enableWiFi;         // 802.11 promiscuous capture
    bool        initNimBLE;         // false if the firmware already inited NimBLE
    const char* bleDeviceName;      // only used when initNimBLE == true
    bool        wifiChannelHop;     // hop 1..13, or sit on a fixed channel
    uint8_t     wifiFixedChannel;   // used when wifiChannelHop == false
    uint32_t    wifiHopIntervalMs;  // dwell time per channel
    uint32_t    dedupWindowMs;      // re-emit a device as "new" after this gap
};

// Sensible defaults: both radios on, NimBLE self-init, channel hopping, 60 s dedup.
AcabScannerConfig acabScannerDefaults();

// Start scanning. `sink` fires from scanner task context for each detection.
void acabScannerBegin(const AcabScannerConfig& cfg, AcabDetectionSink sink);

// Feed in our own GPS fix; fixed-device detections (Flock/Axon) get stamped
// with it. Drones carry their own broadcast coordinates, so they don't.
void acabScannerSetSelfGPS(double lat, double lon, bool valid);

// Whitelist: silently drop detections from these MACs (no report/beep/mesh).
// App-pushed over config; held in RAM (the app re-sends on reconnect).
void acabScannerSetIgnoreList(const uint8_t macs[][6], int count);

// Total detections emitted this session (for status/heartbeat reporting).
uint32_t acabScannerTotalDetections();

// Diagnostics: raw BLE adverts and 802.11 mgmt frames seen since boot, matched
// or not. Lets a field test tell "radio alive, nothing matched" from "radio
// seeing nothing at all."
uint32_t acabScannerBleSeen();
uint32_t acabScannerWifiSeen();

// Turn each detection radio on/off at runtime (app-controllable). Disabling BLE
// only stops the *scan* - a GATT link to the app stays up. Both start enabled in
// acabScannerBegin().
void acabScannerSetBLE(bool on);
void acabScannerSetWiFi(bool on);
bool acabScannerBLEEnabled();
bool acabScannerWiFiEnabled();

#endif // ACAB_SCANNER_H
