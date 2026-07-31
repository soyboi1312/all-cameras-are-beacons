/*
 * ACAB - Smart / recording-glasses detector.
 *
 * Spots camera-equipped eyewear (Ray-Ban / Oakley Meta, Snap Spectacles, Luxottica
 * frames, and TCL/RayNeo AR glasses) by the vendor's Bluetooth SIG company ID in the
 * BLE manufacturer-specific data (AD type 0xFF). The company ID rides in the payload,
 * not the MAC, so detection survives BLE MAC randomization.
 *
 * Its OWN category (ACAB_GLASSES) - NOT a tracker, NOT a body cam. Confidence is graded
 * per vendor (see glasses_signatures.h): eyewear-only registrants are high; the Meta
 * corporate IDs are moderate because they are SHARED with the Meta Quest VR headset, so
 * a hit "may be a Quest, not glasses" - reported honestly in the detail string, and
 * upgraded when the META_RB_GLASS token disambiguates. CAPTURE-PENDING: confirm real
 * glasses advertise this while worn.
 *
 * DEFAULT ON (like the body-cam detector): the company-ID match is specific enough that
 * it does not flood the way the item-tracker scan does. The app / mesh can flip it off,
 * and the choice is persisted to NVS.
 */
#ifndef ACAB_GLASSES_DETECT_H
#define ACAB_GLASSES_DETECT_H

#include "detection.h"
#include <stddef.h>

// Master on/off. Default: ON. glassesSetEnabled persists the choice to NVS;
// glassesRestoreEnabled reloads it on boot so an app-set toggle survives a reboot /
// power-cycle instead of reverting to the compile-time default.
void glassesSetEnabled(bool enabled);
bool glassesIsEnabled();
void glassesRestoreEnabled(bool defaultEnabled);

// Classify a BLE advertisement as recording glasses. Returns true + fills `out` only
// when glasses detection is on AND a known eyewear company ID matches.
bool glassesClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out);

#endif // ACAB_GLASSES_DETECT_H
