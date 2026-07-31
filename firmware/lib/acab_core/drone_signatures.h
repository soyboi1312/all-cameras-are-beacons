/*
 * ACAB - Drone vendor MAC OUIs (clean-room) - a fallback UNDER Remote ID.
 *
 * Primary drone detection is OpenDroneID / ASTM F3411 Remote ID (drone_detect.cpp),
 * a standardised self-declared broadcast. This table is a SECONDARY, lower-confidence
 * signal: a device transmitting from one of a drone vendor's OWN corporate IEEE OUI
 * blocks when NO Remote ID was decoded. It catches that vendor's drones / controllers /
 * goggles that don't broadcast RID (older units, RID disabled, non-US firmware). The
 * vendor randomises its MAC in some Wi-Fi modes, so an OUI hit is a bonus "vendor gear
 * nearby" signal layered under RID, never a replacement for it.
 *
 * Every block below is the vendor's own corporate MA-L registration in the IEEE
 * registry - not commodity module silicon, so it passes the no-shared-silicon rule the
 * rest of the OUI tables follow.
 *   src: IEEE OUI registry, cross-checked against standards-oui.ieee.org/oui/oui.txt.
 *        See docs/signatures.md.
 */
#ifndef ACAB_DRONE_SIGNATURES_H
#define ACAB_DRONE_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// One drone-vendor OUI: the 3-byte corporate MA-L block plus a short vendor label so the
// detection detail string names the right maker ("Skydio gear, no Remote ID" etc).
struct DroneOui {
    uint8_t     oui[3];     // vendor's own corporate MA-L block (IEEE), high byte first
    const char* vendor;     // short label for the detail string
};

// The drone vendors' own corporate MA-L blocks (IEEE). Every block is the vendor's OWN
// registration, not commodity module silicon, so it passes the no-shared-silicon rule.
// (DJI registration dates in comments; the newest are on the latest hardware only.)
static const DroneOui DRONE_VENDOR_OUI[] = {
    // DJI (registrant "SZ DJI Technology Co.,Ltd").
    { { 0x60, 0x60, 0x1f }, "DJI" },   // 2013-03-11  FIELD-OBSERVED 2026-07-23: a live airborne
                                       //   DJI broadcast Remote ID from this block (San Diego).
                                       //   Confirms the block is real DJI hardware; does NOT
                                       //   confirm the OUI path is safe to enable by default.
    { { 0x34, 0xd2, 0x62 }, "DJI" },   // 2019-08-13
    { { 0x48, 0x1c, 0xb9 }, "DJI" },   // 2022-05-07
    { { 0xe4, 0x7a, 0x2c }, "DJI" },   // 2023-10-19
    { { 0x58, 0xb8, 0x58 }, "DJI" },   // 2024-07-26
    { { 0x04, 0xa8, 0x5a }, "DJI" },   // 2025-01-09
    { { 0x8c, 0x58, 0x23 }, "DJI" },   // 2025-05-27
    { { 0x0c, 0x9a, 0xe6 }, "DJI" },   // 2025-08-14
    { { 0x88, 0x29, 0x85 }, "DJI" },   // 2025-10-29
    { { 0x4c, 0x43, 0xf6 }, "DJI" },   // 2025-12-01

    // Parrot SA (ANAFI line, incl. the ANAFI USA carried by US agencies). NOTE: 90:3A:E6 is
    //   also the OUI the OpenDroneID WiFi beacon vendor IE rides (see droneRidWiFi); that is
    //   an IE match, not a transmitter-MAC match, and RID is decoded FIRST, so this fallback
    //   only fires on non-RID Parrot gear. src: IEEE (both blocks "Parrot SA / Parrot Drones").
    { { 0x90, 0x3a, 0xe6 }, "Parrot" },
    { { 0xa0, 0x14, 0x3d }, "Parrot" },

    // Skydio Inc (the most-deployed US-agency drone; Skydio 2/X2/X10). src: IEEE ("Skydio Inc").
    { { 0x38, 0x1d, 0x14 }, "Skydio" },

    // Autel Robotics (EVO line). src: IEEE ("Autel Robotics"). Not to be confused with
    //   Beijing Autelan (a WLAN vendor), which is deliberately NOT matched.
    { { 0xec, 0x5b, 0xcd }, "Autel" },
    { { 0x18, 0xd7, 0x93 }, "Autel" },

    // Yuneec (Typhoon / H520). src: IEEE ("Yuneec Technology" / "Yuneec International").
    { { 0xe0, 0xb6, 0xf5 }, "Yuneec" },
};
static const size_t DRONE_VENDOR_OUI_COUNT = sizeof(DRONE_VENDOR_OUI) / sizeof(DRONE_VENDOR_OUI[0]);

// Confidence for an OUI-only drone-vendor match (no Remote ID). Deliberately low:
// it means "vendor hardware nearby", not "an airborne drone", and it isn't RID.
#define DRONE_OUI_CONFIDENCE  60

#endif // ACAB_DRONE_SIGNATURES_H
