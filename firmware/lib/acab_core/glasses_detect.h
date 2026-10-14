/*
 * ACAB - Smart / recording-glasses detector.
 *
 * Spots possible recording glasses (Ray-Ban / Oakley Meta, Snap Spectacles, Luxottica
 * frames, Vuzix eyewear) on three BLE payload surfaces: the HeyCyan SDK 128-bit service
 * UUID, 16-bit SIG member service UUIDs, and the vendor company ID in manufacturer-specific
 * data (AD type 0xFF). All three ride in the payload, not the MAC, so detection survives
 * BLE MAC randomization. TCL/RayNeo 0x0BC6 is listed but gated off (see
 * glasses_signatures.h).
 *
 * Its OWN category (ACAB_GLASSES) - NOT a tracker, NOT a body cam. Confidence is graded
 * per row (see glasses_signatures.h): a company ID names the vendor, never the device type,
 * so every bare company-ID row sits below the apps' weak-match line (50) and its detail
 * names the vendor ("Luxottica device, possible glasses"). The Meta corporate IDs add the
 * Quest caveat because they are SHARED with the Meta Quest VR headset. Only the
 * META_RB_GLASS token tier (72) and the HeyCyan SDK UUID (68) rank above 50.
 * CAPTURE-PENDING: only Meta 0x01AB has been heard on worn glasses; the Luxottica, Snap and
 * Vuzix rows wait on a worn-unit capture before they can rise.
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

// Classify a BLE advertisement as possible recording glasses. Returns true + fills `out`
// only when glasses detection is on AND one of the three payload surfaces (company ID,
// 16-bit member service UUID, HeyCyan 128-bit UUID) matches; the best confidence wins.
bool glassesClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out);

#endif // ACAB_GLASSES_DETECT_H
