/*
 * ACAB - Flock Safety signature tables (clean-room).
 *
 * Every entry here is sourced from a public registry, a published standard, or
 * independent third-party research - NOT from upstream detection code. Full
 * citations are in docs/signatures.md. Drop this into flock_detect.cpp in place
 * of the inline tables; the only logic change is adding the SSID-prefix match
 * to flockClassifyWiFi (see note at FLOCK_SSID_PREFIX).
 */
#ifndef ACAB_FLOCK_SIGNATURES_H
#define ACAB_FLOCK_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// ---------------------------------------------------------------------------
// MAC OUI
// ---------------------------------------------------------------------------
// Only Flock Safety's OWN IEEE block is defensibly Flock-specific. The WiFi/BT
// silicon is a LiteOn WCBN3510A, and Lite-On's OUIs are shared across millions
// of consumer devices, so matching them is a false-positive magnet (in the field
// they flagged a Molekule air purifier and a home camera). The old ~67-OUI
// "superset" is intentionally gone; match the SSID / name / mfg-id below instead.
struct FlockOui { uint8_t b[3]; uint8_t ext; };
static const FlockOui FLOCK_OUI[] = {
    // B4:1E:52  Flock Safety, Inc.  (IEEE MA-L, registered 2024-05-09)
    //   src: IEEE OUI registry -> https://maclookup.app/macaddress/b41e52
    {{0xb4,0x1e,0x52}, 0},
};
static const size_t FLOCK_OUI_COUNT = sizeof(FLOCK_OUI) / sizeof(FLOCK_OUI[0]);

// ---------------------------------------------------------------------------
// WiFi SSID prefix
// ---------------------------------------------------------------------------
// Falcon cameras stand up a setup/health AP named "Flock-<partial MAC>". This is
// the strong WiFi signature (far better than an OUI). Add a prefix test on the
// SSID IE in flockClassifyWiFi; it replaces the dropped OUI-superset matches.
//   src: ryanohoro "Spotting Flock Safety's Falcon Cameras"; GainSec WiFi research.
#define FLOCK_SSID_PREFIX  "Flock-"

// ---------------------------------------------------------------------------
// BLE advertised-name patterns  (case-insensitive substring)
// ---------------------------------------------------------------------------
//   "FS Ext Battery", "Penguin"  -> ryanohoro (external-battery health beacons)
//   "FS-"                        -> own field capture (e.g. FS-BEC46A, 2026-06)
//   "Flock"                      -> brand string, public
// (A bare 10-digit name is a documented post-Mar-2025 Flock pattern but is NOT
// matched here: in the field it false-positived on phones broadcasting placeholder
// numeric names like "0102000000". Re-add only behind a public-BLE-address gate.)
static const char* FLOCK_NAME_PATTERNS[] = {
    "FS Ext Battery",
    "Penguin",
    "FS-",
    "Flock",
};
static const size_t FLOCK_NAME_COUNT =
    sizeof(FLOCK_NAME_PATTERNS) / sizeof(FLOCK_NAME_PATTERNS[0]);

// ---------------------------------------------------------------------------
// BLE manufacturer company ID
// ---------------------------------------------------------------------------
// 0x09C8 on Flock BT health beacons; ryanohoro attributes it to "XUNTONG".
// TODO before shipping: confirm 0x09C8's registrant in the current Bluetooth SIG
// assigned-numbers company-identifier list.
static const uint16_t FLOCK_MFG_IDS[] = { 0x09C8 };
static const size_t FLOCK_MFG_COUNT = sizeof(FLOCK_MFG_IDS) / sizeof(FLOCK_MFG_IDS[0]);

// ---------------------------------------------------------------------------
// Raven (audio sensor) service UUIDs - 16-bit shorts on the Bluetooth base UUID,
// advertised in 128-bit form. The 0x31xx-0x35xx are Raven-specific and come from
// field captures (not a registry) - confirm against your own capture. The 0x18xx
// are standard Bluetooth SIG profile UUIDs (public) used only as weak backup.
// ---------------------------------------------------------------------------
#define RAVEN_SVC_GPS       0x3100  // Raven-specific  (own capture)
#define RAVEN_SVC_POWER     0x3200  // Raven-specific  (own capture)
#define RAVEN_SVC_NETWORK   0x3300  // Raven-specific  (own capture)
#define RAVEN_SVC_UPLOAD    0x3400  // Raven-specific  (own capture)
#define RAVEN_SVC_ERROR     0x3500  // Raven-specific  (own capture)
#define RAVEN_SVC_DEVINFO   0x180a  // std Bluetooth SIG: Device Information
#define RAVEN_SVC_OLDHEALTH 0x1809  // std Bluetooth SIG: Health Thermometer
#define RAVEN_SVC_OLDLOC    0x1819  // std Bluetooth SIG: Location and Navigation

#endif // ACAB_FLOCK_SIGNATURES_H
