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
// Capture-build guard for the ESP32 side, mirroring the one in nrf-ble-scan/src/main.cpp.
// This header is pulled in by acab_scanner.cpp, which every ESP32 env compiles, so the guard
// covers oui-spy, mesh-detect, mesh-detect-ch1 and beacon-board alike.
//
// ACAB_ACTIVE_SCAN makes the scanner TRANSMIT (breaks the "passive, never transmits" framing) and
// ACAB_BENCH_NO_SLEEP skips the soft-power park so the board ignores SW1 entirely. Both are
// bench-only. They previously compiled clean into a signed release image: the commented
// -DACAB_ACTIVE_SCAN sits in the shared [env] build_flags block every env inherits, one
// uncommented line away from shipping, and neither release script inspects the image before
// signing it. Refuse to compile instead unless the capture intent is explicit.
#if (defined(ACAB_ACTIVE_SCAN) || defined(ACAB_BENCH_NO_SLEEP)) && !defined(ACAB_CAPTURE_BUILD)
#error "ACAB_ACTIVE_SCAN / ACAB_BENCH_NO_SLEEP are bench-only. Set -DACAB_CAPTURE_BUILD to build one on purpose; NEVER ship it."
#endif

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

// Clamp an attacker-sourced byte string to printable ASCII (0x20..0x7E) as it is
// copied into dst: any other byte (control chars, high bytes) becomes '.'. Copies
// min(n, cap-1) bytes then null-terminates. Keeps a crafted advert name / WiFi SSID /
// drone ODID id from injecting control bytes that would make the detection JSON
// invalid (iOS silently drops invalid JSON, suppressing the live alert). Shared so
// every ingest path sanitizes identically.
void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap);

// Feed in our own GPS fix; fixed-device detections (Flock/Axon) get stamped
// with it. Drones carry their own broadcast coordinates, so they don't.
void acabScannerSetSelfGPS(double lat, double lon, bool valid);

// Run the full BLE classifier chain on a single advert and funnel any match
// into the detection pipeline. The NimBLE scan callback calls this for the
// board's own radio; a dual-radio build also calls it for adverts a companion
// nRF52840 forwards over UART. Counts toward acabScannerBleSeen(). mac is in
// human order (mac[0] = OUI first byte); payload is the raw advert AD bytes.
// isReplay=true routes a recovered black-box record to the app WITHOUT beeping or
// polluting the live dedup table / gTotal / offline buffer (see AcabDetection::replay).
void acabScannerIngestBLE(const uint8_t mac[6], const uint8_t* payload, size_t plen, int rssi, bool isReplay = false);

// Re-arm offline-buffer capture (call when the app disconnects): the first sighting of
// each device after this buffers once more, so capture isn't a single per-boot event.
void acabScannerReArmCapture();

// Whitelist: silently drop detections from these MACs (no report/beep/mesh).
// App-pushed over config; held in RAM (the app re-sends on reconnect).
void acabScannerSetIgnoreList(const uint8_t macs[][6], int count);

// How many MACs are currently on the ignore list (for app reconciliation).
uint32_t acabScannerIgnoreCount();

// Watchlist (app-pushed): the inverse of the ignore list. The user stars a specific
// device by exact MAC; from then on the board alerts every time that MAC is seen (normal
// dedup cadence) even when no built-in signature matches it. Held in RAM + persisted to
// NVS across boots (the app also re-sends on reconnect).
void acabScannerSetWatchList(const uint8_t macs[][6], int count);

// How many MACs are currently on the watchlist (for app reconciliation).
uint32_t acabScannerWatchCount();

// Total detections emitted this session (for status/heartbeat reporting).
uint32_t acabScannerTotalDetections();

// Diagnostics: raw BLE adverts and 802.11 mgmt frames seen since boot, matched
// or not. Lets a field test tell "radio alive, nothing matched" from "radio
// seeing nothing at all."
uint32_t acabScannerBleSeen();
uint32_t acabScannerWifiSeen();
// Sink-queue drop accounting. A nonzero buffered-drop count means the offline ring missed records
// it was asked to keep (the claim was rolled back, so the device re-arms, but that sighting is
// gone); a nonzero deliver-only count is benign, since a missed live notify simply re-arrives.
// Reported as `sdrop` (the total) in periodic status, and individually in the {"diag":true} reply.
uint32_t acabScannerSinkDropDeliverOnly();
uint32_t acabScannerSinkDropBuffered();
uint32_t acabScannerSinkDropReplay();
uint32_t acabScannerSinkHighWater();
uint32_t acabScannerSinkDropTotal();

// Co-processor (dual-radio nRF) stats, mirrored up over UART for the two-radio
// "is it working?" diagnostic. hasCoProc stays false on a single-board build.
void     acabScannerSetCoProcStats(uint32_t advSeen, uint32_t forwarded, bool scanning, uint32_t bbCount);
bool     acabScannerHasCoProc();
// Timestamp the last byte-line heard from the co-processor. The dual-radio UART path calls
// this on EVERY ingested nRF line (adverts, the 5s "D" heartbeat, version/black-box replies)
// so liveness can decay. No-op effect on single-board builds (nothing calls it).
void     acabScannerNoteCoProcRx();
// Co-processor liveness: true only if we have heard a line from the nRF within the timeout.
// false = never seen OR gone silent (nRF radio fault -> the BLE detection half is dark). Drives
// the status "co" flag and the A1 recovery reflash. Always false on a single-board build.
bool     acabScannerCoProcAlive();
uint32_t acabScannerCoProcAdvSeen();
uint32_t acabScannerCoProcForwarded();
bool     acabScannerCoProcScanning();
uint32_t acabScannerCoProcBbCount();   // black-box records stored on the nRF's flash
// Send a command line to the co-processor (e.g. black-box "DUMP" / "BCLR") via the
// registered cmd sink. No-op if no co-processor link is set.
void     acabScannerSendCoProcCmd(const char* cmd);
// Re-push the co-processor state that lives only in its RAM: the BLE scan on/off line and the
// ignore-list mirror. The nRF drops both on ANY reset (power blip, WDT, and most visibly a BLE
// DFU), so the dual-radio UART parser calls this every time the nRF announces its version
// ("V<n>") on boot. Safe to call repeatedly; no-op when no cmd sink is registered, so a
// single-radio build pays one null test.
void     acabScannerResyncCoProc();

// Turn each detection radio on/off at runtime (app-controllable). Disabling BLE
// only stops the *scan* - a GATT link to the app stays up. Both start enabled in
// acabScannerBegin().
void acabScannerSetBLE(bool on);
void acabScannerSetWiFi(bool on);
bool acabScannerBLEEnabled();
bool acabScannerWiFiEnabled();

// WiFi eco mode (battery SKU): seconds of promiscuous-RX sleep inserted AFTER each full channel
// sweep. 0 = continuous (off). The app offers 0/3/7/15; the setter snaps to that ladder. Persisted
// to NVS. Trades battery for WiFi-only coverage (Flock APs, network cameras) during the gaps; BLE
// is never throttled. No effect while the WiFi radio toggle is off, or in fixed-channel mode.
void acabScannerSetWifiEco(int sec);
int  acabScannerWifiEco();

// Recompute + reinstall the 802.11 promiscuous frame filter. Production is MGMT-only, but
// the network-camera opt-in (netcamIsEnabled) widens it to also deliver DATA frames so their
// source-MAC can be OUI-matched; turning that toggle off narrows it back so no data-frame
// firehose is delivered at all (zero cost). netcamSetEnabled() calls this on every flip.
// No-op until WiFi is up / when WiFi is disabled in the config.
void acabScannerRefreshWifiFilter();

// Optional out-of-band command sink for a co-processor. A dual-radio build sets
// this so radio commands are mirrored to a companion nRF52840 over UART: it is
// called with a short ASCII line when the BLE radio is toggled ("S1" / "S0") or
// the ignore list changes ("IC" to clear, then "IA <mac12hex>" per entry).
// Default null = no-op, so single-board builds are unaffected.
typedef void (*AcabCmdSink)(const char* line);
void acabScannerSetCmdSink(AcabCmdSink sink);

#endif // ACAB_SCANNER_H
