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
// silicon is a LiteOn WCBN3510A, and Lite-On's OUIs are shared across millions of
// consumer devices, so matching them is a false-positive magnet (in the field they
// flagged a Molekule air purifier and a home camera). The old ~67-OUI "superset"
// is gone on purpose; match the SSID / name / mfg-id below instead.
struct FlockOui { uint8_t b[3]; uint8_t ext; };
static const FlockOui FLOCK_OUI[] = {
    // B4:1E:52  Flock Safety, Inc.  (IEEE MA-L, registered 2024-05-09)
    //   src: IEEE OUI registry -> https://maclookup.app/macaddress/b41e52
    {{0xb4,0x1e,0x52}, 0},
};
static const size_t FLOCK_OUI_COUNT = sizeof(FLOCK_OUI) / sizeof(FLOCK_OUI[0]);

// ---------------------------------------------------------------------------
// WiFi client OUIs (Falcon cameras) - PROBE-REQUEST matched
// ---------------------------------------------------------------------------
// Falcon cams join a network as WiFi clients (no "Flock-" AP of their own) and give
// themselves away with probe requests from a Liteon WiFi module. These specific Liteon
// OUIs were seen on deflock-confirmed Falcons in the field (own field captures, 2026-06).
// Liteon is shared silicon, so these are matched on PROBE REQUESTS ONLY (see
// flockClassifyWiFi) to hold false positives down; grow the list from more field captures.
struct FalconWifiOui { uint8_t b[3]; };
static const FalconWifiOui FALCON_WIFI_OUI[] = {
    // Own field captures (deflock-confirmed Falcons, 2026-06):
    {{0xD8,0xF3,0xBC}},  // D8:F3:BC:7D:D4:CF
    {{0xC0,0x35,0x32}},  // C0:35:32:AF:A3:7D
    {{0x24,0xB2,0xB9}},  // 24:B2:B9:F5:D0:43
    {{0xF4,0x6A,0xDD}},  // F4:6A:DD:62:38:5D / :5E:3A:F3
    // Additional candidate Liteon "Flock WiFi" OUIs (pending own-capture confirmation).
    // All IEEE-registered to Liteon Technology - the same module family as the four
    // above. Probe-req gated like the rest, so the shared-silicon FP risk stays bounded.
    {{0x70,0xC9,0x4E}},
    {{0x3C,0x91,0x80}},
    {{0x80,0x30,0x49}},
    {{0x14,0x5A,0xFC}},
    {{0x74,0x4C,0xA1}},
    {{0x9C,0x2F,0x9D}},
    {{0x94,0x08,0x53}},
    {{0xE4,0xAA,0xEA}},
};
static const size_t FALCON_WIFI_OUI_COUNT = sizeof(FALCON_WIFI_OUI) / sizeof(FALCON_WIFI_OUI[0]);

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
