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
// themselves away with probe requests from a Liteon WiFi module. Liteon is shared
// silicon (one of the biggest laptop WiFi-NIC suppliers), so these are matched on
// PROBE REQUESTS ONLY (see flockClassifyWiFi) - but note that gate distinguishes APs
// from clients, NOT cameras from laptops: probe requests are exactly what a
// not-yet-associated laptop emits, and Windows ships MAC randomization off, so the
// real OUI is on the air. Only OUIs field-validated AT a live Falcon ship (ext=0).
// Earlier unconfirmed candidates that came from community OUI lists were removed for
// clean-room provenance. Re-add / promote an OUI only after confirming it at a live
// Falcon in our own capture.
// ext=1 = NON-SHIPPING candidate: compiled out of every build (gFlockExtendedOui in
// flock_detect.cpp is compile-time false with no setter, NVS restore, or BLE toggle),
// kept only as a provenance record until validated at a live Falcon.
struct FalconWifiOui { uint8_t b[3]; uint8_t ext; };
static const FalconWifiOui FALCON_WIFI_OUI[] = {
    // Shipped (ext=0): field-validated at a live Falcon over probe requests.
    //   D8:F3:BC / C0:35:32 were 2026-06 near-Falcon-only candidates (held out as a
    //   bystander-laptop risk); PROMOTED 2026-07-24 after our own drive recaptured
    //   BOTH broadcasting "PROBE-FALCON" / "DATA-FALCON" SSIDs (a Flock-specific name
    //   no bystander laptop emits), which pins the OUI to a Falcon. The probe-req gate
    //   in flockClassifyWiFi still holds shared-silicon false positives down, and the
    //   FLOCK_SSID_FALCON_SUFFIX name match is the stronger, safer primary signal.
    {{0xD8,0xF3,0xBC}, 0},  // D8:F3:BC  own capture 2026-06 + 2026-07-24 (DATA-FALCON SSID)
    {{0xC0,0x35,0x32}, 0},  // C0:35:32  own capture 2026-06 + 2026-07-24 (PROBE/DATA-FALCON SSID)
    {{0x24,0xB2,0xB9}, 0},  // 24:B2:B9:F5:D0:43               own capture; field-validated at a live Falcon
    {{0xF4,0x6A,0xDD}, 0},  // F4:6A:DD:62:38:5D / :5E:3A:F3   own capture; field-validated
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

// Falcon cameras also stand up per-function networks named "PROBE-FALCON" and
// "DATA-FALCON" (own drive capture 2026-07-24, seen on the C0:35:32 / D8:F3:BC
// Falcon OUIs below). Match any "*-FALCON" SSID: like the "Flock-" AP name it is a
// strong, Flock-specific WiFi signal, and being name-based it needs no probe-req
// gate, so it catches a Falcon in beacon / associated mode too (where the OUI path,
// which is probe-request-only, cannot). Anchored as a SUFFIX so consumer names like
// "Atlanta-Falcons" or "Millennium Falcon" do not match (see ciEndsWith use).
#define FLOCK_SSID_FALCON_SUFFIX  "-FALCON"

// ---------------------------------------------------------------------------
// BLE advertised-name patterns  (ANCHORED - see nameMatch in flock_detect.cpp)
// ---------------------------------------------------------------------------
// Substring-anywhere matching false-positives on consumer gear ("FS-" is a generic
// white-label model prefix; any name containing "penguin"/"flock" matched), so each
// pattern is anchored to the form the sources actually document:
//   FLOCK_NAME_LITERAL       case-insensitive substring; specific enough to rank
//                            strong (80) on its own
//   FLOCK_NAME_PREFIX_DIGITS name starts with the pattern + a 1+ decimal-digit tail
//   FLOCK_NAME_PREFIX_HEX    name starts with the pattern + a 1+ hex-digit tail
//   FLOCK_NAME_PREFIX        name starts with the pattern (no structural tail)
// The PREFIX forms rank strong (80) only when a co-signal backs them - a public
// (non-random) BLE address (real Flock beacons don't rotate) or the 0x09C8 mfg id -
// and stay hint-grade (70) otherwise, so an "FS-100" gadget on a rotating address
// never draws a strong ALPR verdict. See nameMatch in flock_detect.cpp.
//   "FS Ext Battery"             -> ryanohoro (external-battery health beacons)
//   "Penguin-" + digits          -> ryanohoro (Penguin-##########)
//   "FS-" + hex                  -> own field capture (FS-BEC46A, 2026-06; one capture,
//                                   so the tail requires hex but not a fixed length)
//   "Flock" prefix               -> brand string, public; loosest of the four
// (A bare 10-digit name is a documented post-Mar-2025 Flock pattern but is NOT
// matched here: in the field it false-positived on phones broadcasting placeholder
// numeric names like "0102000000". Re-add only behind a public-BLE-address gate.)
enum FlockNameForm : uint8_t {
    FLOCK_NAME_LITERAL,
    FLOCK_NAME_PREFIX_DIGITS,
    FLOCK_NAME_PREFIX_HEX,
    FLOCK_NAME_PREFIX,
};
struct FlockNamePat { const char* pat; uint8_t form; };
static const FlockNamePat FLOCK_NAME_PATTERNS[] = {
    { "FS Ext Battery", FLOCK_NAME_LITERAL },
    { "Penguin-",       FLOCK_NAME_PREFIX_DIGITS },
    { "FS-",            FLOCK_NAME_PREFIX_HEX },
    { "Flock",          FLOCK_NAME_PREFIX },
};
static const size_t FLOCK_NAME_COUNT =
    sizeof(FLOCK_NAME_PATTERNS) / sizeof(FLOCK_NAME_PATTERNS[0]);

// ---------------------------------------------------------------------------
// BLE manufacturer company ID
// ---------------------------------------------------------------------------
// 0x09C8 on Flock BT health beacons; ryanohoro attributes it to "XUNTONG" (a silicon/module
// vendor, not Flock), so it's SHARED and unverified. It's matched at a deliberately low
// confidence (45, see flock_detect.cpp) - below the apps' weak-match threshold (50), so a
// hit renders as "weak match, verify" rather than a calm partial match - because a hit is
// a hint, not an assertion, until a field capture confirms it. TODO before trusting it
// higher: confirm 0x09C8's registrant + exclusivity in the current Bluetooth SIG
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
