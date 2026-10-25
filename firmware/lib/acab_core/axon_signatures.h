/*
 * ACAB - body-worn camera signatures, two vendors (clean-room).
 *
 * Provenance is PER VALUE, not per file. This banner used to say "both values are public /
 * own-capture, not ported", which stopped being true when the Utility BodyWorn signature
 * landed. Read the citation on each value:
 *   - Axon OUI 00:25:DF and the "BWCDEVICE" tag: public IEEE registry and our own field
 *     capture. Not ported from anyone.
 *   - Axon OUI D8:1F:65: OWN FIELD CAPTURE ONLY. The IEEE registry lists the block as "Private",
 *     so it can never name a registrant; the attribution rests on nine MACs carrying two
 *     independent Axon identifiers, five of them owner-confirmed by eye on 2026-09-19. Read the
 *     block on the value itself before relying on it.
 *   - Utility Inc. "BodyWorn Remote" NAME: third-party field observation, taken from the
 *     community nite-oui-collection (nitekry) and credited in CREDITS.md.
 *   - Utility Inc. OUIs 00:09:BC / 00:16:ED: public IEEE registry.
 *   - Axon SIG service UUID 0xFE6B and company ID 0x034D: public Bluetooth SIG registry and our
 *     own field capture. Not ported from anyone.
 * See docs/signatures.md.
 */
#ifndef ACAB_AXON_SIGNATURES_H
#define ACAB_AXON_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// MAC OUI: Axon Enterprise, Inc. (formerly TASER International) - the block the IEEE
// registry attributes to them (MA-L, 2010).
//   src: IEEE OUI registry -> https://maclookup.app/macaddress/0025DF
// OUI-ONLY GROUND TRUTH on this block (hits with NO BWCDEVICE tag in the packet, one weak packet
// each at -88 dBm or below, conf 75): 54:7b:5a (2026-09-16) and 7d:8c:de + f8:38:3f (2026-09-23,
// Agoura Hills area, two officers on scene, one second apart), ALL THREE OWNER-CONFIRMED as body
// cams. Recorded from app CSV exports, so which advert each one sent is not known. Every Axon-block
// BLE advert in the serial logs carries the tag, METROPOLISDEVICE, 0xFE6B or 0x034D (none carries
// no Axon identifier), and five Axon-block MACs sent 0xFE6B only (docs/signatures.md). It is not a
// reason to raise the 75, because a dock or other Axon gear on the same block is indistinguishable
// on the air.
#define AXON_OUI_REGISTERED  { 0x00, 0x25, 0xdf }

// D8:1F:65 - a SECOND block that field capture, not the registry, put in this table. BOTH BLOCKS
// ARE REAL AND BOTH ARE OBSERVED; they differ in who vouches for them, not in whether they show up.
// Recounted 2026-10-21 over the serial logs in firmware/tools/detection logs: 13 distinct MACs on
// 00:25:DF (aug-9-flock-o, drive_home_9-4, lvt-lot1, sep252026, sep272026 and oct012026, several
// firing conf 90 on the tag) and 10 on D8:1F:65; with the app CSV exports, 33 and 22. An earlier
// draft of this comment claimed 00:25:DF had never been seen on the air; that was false, and the
// asymmetry it argued from does not exist.
//
// WHY IT QUALIFIES, against the confidence ladder in bodycam_vendor_signatures.h. That ladder puts
// "corporate OUI alone" at the bottom (diagnostics or opt-in, nothing more) and "two independent
// vendor co-signals" near the top. This block is NOT OUI-alone: it is carried by two independent
// Axon identifiers, in two cities six weeks apart.
//
//   AT ADMISSION (2026-09-19), NINE distinct MACs, zero non-Axon devices seen on the block:
//     8 carry the AXON_BWC_PAYLOAD tag below (AD 0x21, reversed "AXJANUSBWCDEVICE"):
//       2026-09-19 Adams Ave Street Fair, San Diego - 05:cf:af, 00:26:41, 05:2b:7b, 05:4f:c5,
//         04:e5:0d. ALL FIVE OWNER-CONFIRMED BY EYE at the event, the strongest ground truth this
//         signature has. Recorded in the app CSV export, not a serial log.
//       2026-08-09 aug-9-flock-o.log - 04:a5:3b, 04:ca:37, 04:98:47, each at conf 90.
//     1 carries Axon's own SIG service UUID instead, which is the independent co-signal:
//       2026-08-09 aug-9-flock-o.log - 04:a2:57, AD 0x16 service UUID 0xFE6B (TASER
//         International, the same value VENDOR_BLE_ID tags AXON-SVC in vendor_capture.h),
//         ASCII "D01AT522D" in the service data. It is Axon gear that carries no BWCDEVICE tag,
//         so before this block landed it scored conf 0 "hardware OUI" - a MISSED DETECTION, and
//         the concrete thing this entry fixes. Non-tagged Axon gear on a public MAC is exactly
//         what an OUI fallback is for.
//
// THE REGISTRANT IS UNKNOWABLE FROM THE REGISTRY, and that is a finished answer, not a pending
// errand. Checked 2026-09-19 against the IEEE CSV: the row reads exactly
//     MA-L,D81F65,Private,
// i.e. a real MA-L allocation whose holder paid to withhold their name - one of 107 "Private" rows
// in 40,180. Do not re-run this lookup expecting a different result. Two consequences:
//   1. The width question is settled in our favour. There is no MA-M or MA-S subdivision of this
//      block, so the whole 24-bit prefix belongs to one holder and a bare 24-bit entry is correct.
//   2. The MODULE-MAKER RISK CANNOT BE CLOSED BY REGISTRY, only by more field ground truth. If a
//      non-Axon device ever appears on this block, this becomes the Liteon trap that
//      flock_signatures.h documents and the entry must come straight back out. Zero such devices
//      in roughly 21,000 scanned so far, including a 4,300-device crowd.
//
// WHAT THIS ENTRY ACTUALLY BUYS, stated plainly so nobody overrates it: NO device in the serial logs
// since the AXON_SIG_* rule below landed (2026-10-20). Each of the 10 D8:1F:65 devices in those logs
// carries the tag or Axon's SIG service UUID 0xFE6B, and both match with no OUI at all. When this
// entry landed it caught one device, 04:a2:57, which 0xFE6B now catches too. It stays as the fallback
// for Axon gear on this block that sends neither value. On WiFi it is the ONLY match for the block
// (axonClassifyWiFi has no tag or SIG check): two owner-confirmed D8:1F:65 WiFi rows on 2026-10-21
// reached the app through this entry alone, and one of them was a device no other rule caught
// (docs/signatures.md, the 2026-10-21 record). A device on rotating random addresses stops presenting
// the OUI (and axonOuiHit, on both the BLE and WiFi paths, skips locally-administered MACs
// outright), so this buys nothing once Axon finishes moving to rotating addresses.
// AXON_BWC_PAYLOAD is what survives that; this is the fallback beneath it.
//   src: own field capture, 2026-08-09 and 2026-09-19 (owner-confirmed).
#define AXON_OUI_BWC_FIELD   { 0xd8, 0x1f, 0x65 }

// ASCII tag a real Axon body cam self-identifies with in its BLE service data. In
// the field capture it rode inside a 128-bit service-UUID (AD 0x21) which, being
// little-endian, only reads as "AXJANUSBWCDEVICE" when the bytes are reversed - so
// the matcher searches both byte orders (see acabBytesContainAscii in ascii_match.h).
// The tag is a STANDALONE match (MAC-independent, so it survives BLE MAC
// randomization); the OUI is the weaker fallback for un-tagged / other Axon gear.
//   src: own field capture, 2026-06.
#define AXON_BWC_PAYLOAD  "BWCDEVICE"

// Axon's own Bluetooth SIG assigned numbers: the second MAC-INDEPENDENT Axon signal, beneath the tag.
//   0xFE6B  16-bit service UUID, matched as SERVICE DATA (AD 0x16) with at least one payload byte
//   0x034D  company identifier, matched as MANUFACTURER DATA (AD 0xFF) with a serial-shaped payload
//           (AXON_SIG_CID_SERIAL_LEN below)
// Both are registered to "TASER International, Inc." (Axon's former name) in the SIG Assigned
// Numbers. A SIG number is issued to the product vendor, not to a radio-module maker, so a hit says
// "Axon equipment" without the shared-silicon risk of an OUI. It does NOT say which product, so the
// detail string names the identifier ("Axon Bluetooth ID"), never a device class.
//
// OWN FIELD CAPTURE, every serial log in firmware/tools (counted 2026-10-20, AD structures parsed):
//   0xFE6B: 7 distinct devices in aug-9-drive.log, aug-9-flock-o.log, sep252026.log and
//     oct012026.log. 5 on D8:1F:65, 1 on 00:25:DF, 1 on a BLE non-resolvable private address (no
//     OUI at all). Every payload holds
//     serial-shaped ASCII: a "D01A" form on the six on Axon blocks, an "X7" form on the private one.
//     One D8:1F:65 device in oct012026.log alternated this advert with a BWCDEVICE-tagged one, which
//     ties the "D01A" form to a body cam.
//   0x034D: 2 distinct devices. One on 00:25:DF (drive_home_9-4.log, an "X8" serial, "X870054FW"),
//     one on an unregistered random-static address (aug-9-drive.log). That second payload is not
//     serial-shaped: it starts with the device's own address. The only Axon identifier near it was
//     the 0xFE6B "X7" advert from the private address 147 s later; no tag or Axon OUI was heard in
//     that log. Since 2026-10-21 it no longer matches (AXON_SIG_CID_SERIAL_LEN below).
//   No device on any other public block carried either value.
// What this buys over the OUI path: the one device off the Axon blocks that still matches, the
// 0xFE6B "X7" device on a private address, conf 0 before this rule and not confirmed by eye. Like
// the tag, it sees a device the OUI path cannot: one on a random address. On the Axon blocks it
// changes only the detail string and the method (service data or manufacturer ID instead of OUI);
// the confidence stays 75. 2026-10-21: a D8:1F:65 device
// sending 0xFE6B (app export acab-detections 6.csv) was owner-confirmed as one of nine body-cam rows
// on a downtown San Diego walk and drive, the first eyes-on hit for this rule.
//   src: Bluetooth SIG Assigned Numbers (member UUIDs + company identifiers) and own field capture.
#define AXON_SIG_SVC_UUID    0xFE6B
#define AXON_SIG_COMPANY_ID  0x034D

// 0x034D counts only with the payload shape its one Axon-block sighting carried: the byte 0x02, then
// a serial of this many uppercase letters and digits ("X870054FW"). Owner decision 2026-10-21. A
// company ID is the cheapest thing a non-Axon device can reuse, and the only 0x034D advert without
// that shape (the off-block aug-9-drive.log device above) would otherwise report as a body cam. The
// cost: an Axon product with a different 0x034D payload off the Axon blocks stays unmatched until a
// capture shows its shape; on the blocks the OUI path still reports it at the same 75 ("Axon OUI").
// 0xFE6B has no such gate: every one of its sightings carries a serial. Checked by axonCidSerial in
// axon_detect.cpp; test_axon.cpp walks every edge of the shape.
#define AXON_SIG_CID_SERIAL_LEN  9

// ---------------------------------------------------------------------------
// Utility Inc. "BodyWorn" police body-cam system (a different brand, same body-cam
// category as Axon). Field-observed BLE signature: the system's activation remote
// advertises a Complete Local Name containing "BodyWorn Remote" on Utility's public
// OUI 00:09:BC (Utility also holds 00:16:ED). The advertised NAME is the strong,
// MAC-independent signal (like Axon's BWCDEVICE tag); the OUI is the weaker fallback.
// A vendor 128-bit UUID (0cf1640c-1c36-4c68-b411-08f344e1d6d1) exists but only appears
// post-connect, so it is NOT usable in passive scanning.
//   src: nite-oui-collection (nitekry), nRF-Connect capture 2025-08 ->
//        https://github.com/nitekry/nite-oui-collection (groups/le, capture_filters)
#define UTIL_BWC_NAME  "BodyWorn Remote"

// Utility Inc. public OUI blocks, the WEAK fallback behind the name match above. Kept
// here rather than inline in axon_detect.cpp so every OUI in the project lives in a
// signatures header next to its citation, matching the clean-room provenance discipline
// used by flock_signatures.h and bodycam_vendor_signatures.h. Weak on purpose: Utility makes
// other gear on these blocks, so an OUI-only hit is confidence 70 vs 85 for the name.
//   src: IEEE OUI registry (both MA-L, registrant "Utility, Inc." / "Utility Inc")
static const uint8_t UTIL_BWC_OUI[][3] = {
    { 0x00, 0x09, 0xbc },   // 00:09:BC  Utility Inc.
    { 0x00, 0x16, 0xed },   // 00:16:ED  Utility Inc.
};
static const size_t UTIL_BWC_OUI_COUNT = sizeof(UTIL_BWC_OUI) / sizeof(UTIL_BWC_OUI[0]);

#endif // ACAB_AXON_SIGNATURES_H
