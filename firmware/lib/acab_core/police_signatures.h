/*
 * ACAB - Police / Motorola Solutions gear signatures (clean-room).
 *
 * Matching these OUIs flags a Motorola Solutions WiFi/BLE device nearby. Motorola
 * Solutions is the dominant US public-safety comms vendor, but the same corporate
 * block also covers the MOTOTRBO two-way radios, docks, and infrastructure carried by
 * retail, school, and venue staff, so a hit is "Motorola Solutions gear", not proof of
 * a camera. It is NOT ALPR-specific, and NOT their LMR radios (700/800 MHz, off this
 * 2.4 GHz board). Broad by nature, so it sits behind its OWN sub-toggle underneath the
 * body-cam category ({"motorola":bool}, default ON on beacon-board/oui-spy, OFF on
 * mesh-detect) and emits below the apps' weak-match threshold (<50) so it always
 * renders as "verify this".
 *
 * The sub-toggle exists because this match and the Axon BWCDEVICE tag used to share one
 * switch: a user turning "body cam" off to quiet THIS broad match also silenced the
 * conf-90 field-validated Axon signature, which is the best signature on the board.
 * Now "body cam off" kills the whole category, and "motorola off" quiets only this.
 * Full notes in docs/signatures.md.
 */
#ifndef ACAB_POLICE_SIGNATURES_H
#define ACAB_POLICE_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// Motorola Solutions corporate OUI blocks (IEEE MA-L). This is the COMPLETE set
// registered to the Motorola Solutions entities as of 2026-07-19, cross-checked against
// the IEEE registry via the OUI-Master-Database merge (IEEE+Wireshark+Nmap).
//
// Keep Motorola MOBILITY / Lenovo OUIs OUT - that is the unrelated consumer-phone
// business (122 separate blocks; matching them would flag every Moto handset on the
// street). "Motorola Solutions Malaysia Sdn. Bhd." IS in scope - same corporate group,
// their manufacturing entity, not the phone business.
//
// Why listing all seven is NOT the shared-silicon trap that killed Flock's Liteon
// matching: these are Motorola Solutions' OWN MA-L blocks, so a match correctly
// attributes the device VENDOR. The uncertainty here is what the device IS (radio vs
// dock vs camera vs infrastructure), which confidence=45 and the amber weak-match
// treatment already communicate - not WHO made it. 4C:CC:34 is field-observed on
// 2.4 GHz WiFi (own capture 2026-07-18, 3 distinct MACs at one site), which is what
// establishes this vendor as detectable at all; the siblings are the same product lines.
//
// GROUND TRUTH 2026-07-23 (airport capture, 45 rows): of 30 body-cam rows, the 3 Axon BLE
// hits were confirmed real officers and ALL 27 Motorola WiFi OUI hits were confirmed NOT
// body cams. 4C:CC:34 x15, 10:74:6F x10, B8:E2:8C x2, all fixed ceiling/infrastructure gear.
// Two consequences, neither of which is "the OUIs are wrong" - vendor attribution is still
// correct, and these blocks stay:
//   1. The detector is now OPT-IN on every board (default flipped in beacon-board/main.cpp).
//   2. Read the 2026-07-18 observation above with suspicion. "3 distinct MACs at one site"
//      is the same signature a bank of fixed cameras leaves, so it probably was not evidence
//      of body cams either. It shows the vendor is DETECTABLE, not that it is body-worn.
// If this is ever promoted back to on-by-default, it needs a discriminator that separates
// worn from mounted (a stationary repeat-sighting pattern is the obvious candidate: one row
// in that capture logged 20 sightings from effectively one spot), not just a confidence tweak.
static const uint8_t POLICE_OUI[][3] = {
    // Motorola Solutions, Inc.  (One Motorola Plaza, Holtsville NY US)
    { 0x4c, 0xcc, 0x34 },   // 4C:CC:34  reg 2012-12-30  FIELD-OBSERVED 2026-07-18 (WiFi)
    { 0x00, 0x04, 0x7d },   // 00:04:7D
    { 0x00, 0x18, 0x85 },   // 00:18:85
    { 0x00, 0x1f, 0x92 },   // 00:1F:92
    // Motorola Solutions Malaysia Sdn. Bhd. (same group, manufacturing entity)
    { 0x10, 0x74, 0x6f },   // 10:74:6F
    { 0xb8, 0xe2, 0x8c },   // B8:E2:8C
    { 0x9c, 0x86, 0x2b },   // 9C:86:2B
};
static const size_t POLICE_OUI_COUNT = sizeof(POLICE_OUI) / sizeof(POLICE_OUI[0]);

// FIELD-VALIDATION QUEUE, NOT COMPILED IN. Two in-car/body-video vendors whose own corporate
// MA-L blocks are registry-confirmed (2026-08-07 pull of standards-oui.ieee.org/oui/oui.csv):
//
//   00:1D:96   WatchGuard Video
//   00:23:BD   Digital Ally, Inc.
//
// Both are narrow registrants, so they would pass the no-shared-silicon rule that keeps
// Espressif and TP-Link out of these tables. They are still absent on purpose, for two reasons.
//
// First, an OUI establishes the VENDOR, never the equipment type. Both companies ship in-car
// video, interview-room recorders, evidence storage and fleet hardware alongside anything
// body-worn, so a hit would not mean what the category name says it means. That is the exact
// error the crowdsourced lists reviewed on 2026-08-07 make dozens of times over.
//
// Second, this table has been measured, and the measurement was humbling: the "3 distinct MACs
// at one site" note that once justified it turned out to be 0/27 when properly counted, and the
// field-observed rows above are ceiling and infrastructure gear rather than anything worn. A
// vendor block earns a place here after a capture pins it to a device somebody actually saw,
// not because the registration is real.
//
// To promote either one: capture near a confirmed unit with the capture build
// (pio run -e beacon-board-capture), which now logs every prober and its frame type, then record
// the co-signals the way the netcam table records its own field validations.

#endif // ACAB_POLICE_SIGNATURES_H
