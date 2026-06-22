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

// The drone vendor's own corporate MA-L blocks (IEEE).
// (registration dates in comments; the newest are on the latest hardware only.)
static const uint8_t DRONE_DJI_OUI[][3] = {
    { 0x60, 0x60, 0x1f },   // 2013-03-11
    { 0x34, 0xd2, 0x62 },   // 2019-08-13
    { 0x48, 0x1c, 0xb9 },   // 2022-05-07
    { 0xe4, 0x7a, 0x2c },   // 2023-10-19
    { 0x58, 0xb8, 0x58 },   // 2024-07-26
    { 0x04, 0xa8, 0x5a },   // 2025-01-09
    { 0x8c, 0x58, 0x23 },   // 2025-05-27
    { 0x0c, 0x9a, 0xe6 },   // 2025-08-14
    { 0x88, 0x29, 0x85 },   // 2025-10-29
    { 0x4c, 0x43, 0xf6 },   // 2025-12-01
};
static const size_t DRONE_DJI_OUI_COUNT = sizeof(DRONE_DJI_OUI) / sizeof(DRONE_DJI_OUI[0]);

// Confidence for an OUI-only drone-vendor match (no Remote ID). Deliberately low:
// it means "vendor hardware nearby", not "an airborne drone", and it isn't RID.
#define DRONE_OUI_CONFIDENCE  60

#endif // ACAB_DRONE_SIGNATURES_H
