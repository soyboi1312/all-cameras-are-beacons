/*
 * ACAB - Police / Motorola Solutions gear signatures (clean-room).
 *
 * Matching these OUIs flags a Motorola Solutions WiFi/BLE device nearby - a strong
 * proxy for law-enforcement equipment (Motorola Solutions is the dominant US public-
 * safety comms vendor). It is NOT ALPR-specific, and NOT their LMR radios (700/800
 * MHz, off this 2.4 GHz board). Broad by nature, so the detector is opt-in. Full
 * notes in docs/signatures.md.
 */
#ifndef ACAB_POLICE_SIGNATURES_H
#define ACAB_POLICE_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// Motorola Solutions Inc. corporate OUI blocks (IEEE). Add more from the registry
// (search vendor "Motorola Solutions") as you confirm them. Keep Motorola Mobility /
// Lenovo OUIs OUT - that is the unrelated consumer-phone business.
static const uint8_t POLICE_OUI[][3] = {
    // 4C:CC:34  Motorola Solutions, Inc.   src: https://maclookup.app/macaddress/4CCC34
    { 0x4c, 0xcc, 0x34 },
};
static const size_t POLICE_OUI_COUNT = sizeof(POLICE_OUI) / sizeof(POLICE_OUI[0]);

#endif // ACAB_POLICE_SIGNATURES_H
