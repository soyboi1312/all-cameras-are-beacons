/*
 * ACAB - Branded IP-camera vendor MAC OUIs (network-camera detection).
 *
 * The ONE honest, buildable "camera on the network" signal: IP cameras from the major
 * surveillance brands do NOT randomize their MAC, and the 802.11 DATA-frame SOURCE MAC
 * is transmitted in the clear even under WPA2/WPA3 (only the frame BODY is encrypted).
 * So a camera streaming on the host WiFi is passively OUI-matchable by its vendor block.
 *
 * HONESTY (this is a safety product - read before you touch a label):
 *   - This matches known IP-camera BRANDS, not "hidden cameras". A hit means a device
 *     from that vendor is on the air (could be an NVR, a doorbell, or a camera the host
 *     openly disclosed), NOT that someone planted a covert camera.
 *   - It CANNOT find every camera: a no-name / white-label cam on a generic Wi-Fi module,
 *     or any camera not transmitting right now, will not match. Never imply completeness.
 *   The category is "Network camera" and the detail names the vendor + "on wifi".
 *
 * Every block below is the vendor's OWN corporate MA-L registration, VERIFIED against the
 * live IEEE registry on 2026-07-17 (queried api.maclookup.app, which mirrors
 * standards-oui.ieee.org/oui/oui.txt). No commodity-module silicon, so it passes the
 * no-shared-silicon rule the rest of the OUI tables follow. The registrant name from the
 * registry is in each comment.
 *
 * WYZE WAS ADDED 2026-07-31, reversing the exclusion this header used to state. The old reason
 * ("Wyze's own OUIs also cover plugs / bulbs / locks") is true but is a reason to LABEL the hit
 * honestly, not to drop the vendor: the same is true of Anker/eufy, which is labelled to say so.
 * The half that still stands is that some Wyze models ride shared Espressif silicon, in which
 * case these blocks simply never fire, which costs nothing. Espressif itself remains excluded,
 * and that rule is untouched: an OUI is only worth having when the REGISTRANT is narrow.
 */
#ifndef ACAB_NETCAM_SIGNATURES_H
#define ACAB_NETCAM_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// One IP-camera vendor OUI: the 3-byte corporate MA-L block plus a short vendor label so
// the detection detail names the maker ("Hikvision on wifi", etc).
struct NetcamOui {
    uint8_t     oui[3];     // vendor's own corporate MA-L block (IEEE), high byte first
    const char* vendor;     // short label for the "<Vendor> on wifi" detail string
    uint8_t     validated;  // 1 = seen in our own capture AND confirmed a real camera by eye
};

// Registry-confirmed camera-brand OUIs (IEEE MA-L). The original 19 were verified 2026-07-17
// and the 24 consumer blocks (Ring/Wyze/Anker-eufy) on 2026-07-31, both against the live
// IEEE registry (see file header). Add only blocks you re-confirm against the registry.
static const NetcamOui CAMERA_VENDOR_OUI[] = {
    // Hangzhou Hikvision Digital Technology Co.,Ltd. - the six blocks research seeded, ALL
    // registry-confirmed, plus one more from the same registrant. src: IEEE MA-L.
    { { 0x18, 0x68, 0xcb }, "Hikvision", 0 },   // updated 2017-01-07
    { { 0x28, 0x57, 0xbe }, "Hikvision", 0 },   // updated 2022-12-16
    { { 0x44, 0x19, 0xb6 }, "Hikvision", 0 },   // updated 2015-11-17
    { { 0x4c, 0xbd, 0x8f }, "Hikvision", 0 },   // updated 2017-05-24
    { { 0x54, 0xc4, 0x15 }, "Hikvision", 0 },   // updated 2016-10-30
    { { 0xc0, 0x56, 0xe3 }, "Hikvision", 0 },   // updated 2015-11-17
    { { 0x98, 0xf1, 0x12 }, "Hikvision", 0 },   // registry-confirmed same registrant

    // Zhejiang Dahua Technology Co., Ltd. src: IEEE MA-L.
    { { 0x3c, 0xef, 0x8c }, "Dahua", 0 },
    { { 0x90, 0x02, 0xa9 }, "Dahua", 0 },
    { { 0x14, 0xa7, 0x8b }, "Dahua", 0 },
    { { 0x4c, 0x11, 0xbf }, "Dahua", 1 },     // FIELD-VALIDATED 2026-07-23 (airport, 2 hits)
    { { 0xe0, 0x50, 0x8b }, "Dahua", 1 },     // FIELD-VALIDATED 2026-07-23 (airport, 1 hit)
    { { 0xbc, 0x32, 0x5f }, "Dahua", 1 },     // FIELD-VALIDATED 2026-07-23 (airport, 2 hits)

    // Amcrest Technologies (Houston TX). Amcrest's OWN registration; note much Amcrest
    // hardware is Dahua-built and may transmit under a Dahua block above too. src: IEEE MA-L.
    { { 0x9c, 0x8e, 0xcd }, "Amcrest", 0 },

    // Axis Communications AB (Lund, Sweden). src: IEEE MA-L.
    { { 0x00, 0x40, 0x8c }, "Axis", 0 },
    { { 0xac, 0xcc, 0x8e }, "Axis", 0 },
    { { 0xb8, 0xa4, 0x4f }, "Axis", 0 },
    { { 0xe8, 0x27, 0x25 }, "Axis", 0 },

    // Reolink Innovation Limited. The registry shows Reolink holds exactly ONE MA-L block.
    // src: IEEE MA-L.
    { { 0xec, 0x71, 0xdb }, "Reolink", 1 },   // FIELD-VALIDATED 2026-07-23 (airport, 3 hits)

    // ---- CONSUMER / DOORBELL BRANDS (added 2026-07-31, ALL registry-only) ----------------
    // Verified the same day against a fresh 39,880-row pull of the live IEEE registry, matching
    // on the EXACT registrant name rather than a substring: a first substring pass on "ring"
    // returned 24 blocks because it also matched "ENGINEERING". These are the real ones.
    //
    // Why these brands and not Nest / Blink / Arlo: a vendor OUI is only worth having when the
    // REGISTRANT is narrow. Ring LLC and Wyze Labs register in their own names and ship little
    // but cameras. Nest Labs holds only 2 blocks and current Nest cameras sit under Google's
    // 108 blocks (shared with Pixel, Chromecast, Home) - unusable. Blink rides Amazon
    // Technologies' 209 blocks (Echo, Fire TV, Kindle, eero) - unusable. A lot of budget
    // camera hardware transmits under Espressif's 335 blocks - unusable. Narrowness is the test.

    // Ring LLC. Doorbells and security cameras, i.e. the most street-facing camera class there
    // is. Camera/doorbell-only registrant, so the OUI is a strong vendor read. src: IEEE MA-L.
    { { 0x00, 0xb4, 0x63 }, "Ring", 0 },
    { { 0x18, 0x7f, 0x88 }, "Ring", 0 },
    { { 0x24, 0x2b, 0xd6 }, "Ring", 0 },
    { { 0x34, 0x3e, 0xa4 }, "Ring", 0 },
    { { 0x50, 0xe4, 0x67 }, "Ring", 0 },
    { { 0x54, 0xe0, 0x19 }, "Ring", 0 },
    { { 0x5c, 0x47, 0x5e }, "Ring", 0 },
    { { 0x64, 0x9a, 0x63 }, "Ring", 0 },
    { { 0x90, 0x48, 0x6c }, "Ring", 0 },
    { { 0x9c, 0x76, 0x13 }, "Ring", 0 },
    { { 0xac, 0x9f, 0xc3 }, "Ring", 0 },
    { { 0xb0, 0x09, 0xda }, "Ring", 0 },      // registered as "Ring Solutions"
    { { 0xc4, 0xdb, 0xad }, "Ring", 0 },
    { { 0xcc, 0x3b, 0xfb }, "Ring", 0 },

    // Wyze Labs Inc. Camera-dominant, but they also ship plugs, bulbs, locks and scales, so a
    // hit is "a Wyze device" first and a camera second. CAVEAT to settle in the field: some
    // Wyze models are built on Espressif/Realtek silicon and may transmit under the CHIP
    // vendor's OUI instead of Wyze's, in which case these blocks simply never fire.
    // src: IEEE MA-L.
    { { 0x2c, 0xaa, 0x8e }, "Wyze", 0 },
    { { 0x7c, 0x78, 0xb2 }, "Wyze", 0 },
    { { 0x80, 0x48, 0x2c }, "Wyze", 0 },
    { { 0xd0, 0x3f, 0x27 }, "Wyze", 0 },
    { { 0xf0, 0xc8, 0x8b }, "Wyze", 0 },

    // eufy, via Anker. THE WEAKEST ENTRIES IN THIS TABLE, and labelled to say so. There is no
    // "eufy" or "Anker" registrant in the IEEE registry at all - Anker registers as Fantasia
    // Trading LLC, which covers their ENTIRE catalogue: USB chargers, PowerCore banks,
    // Soundcore speakers, Nebula projectors, eufy vacuums and locks, and eufy cameras. So this
    // OUI means "an Anker product", NOT "a camera", and plenty of Anker WiFi gear is not one.
    // The vendor label deliberately reads "Anker/eufy" so the app's detail string carries that
    // ambiguity to the user rather than hiding it behind a camera claim. If a capture shows
    // these firing mostly on vacuums and speakers, delete them. src: IEEE MA-L.
    { { 0x00, 0x7f, 0x1d }, "Anker/eufy", 0 },
    { { 0x7c, 0xe9, 0x13 }, "Anker/eufy", 0 },
    { { 0xac, 0x12, 0x2f }, "Anker/eufy", 0 },
    { { 0xe8, 0xee, 0xcc }, "Anker/eufy", 0 },
    { { 0xf4, 0x9d, 0x8a }, "Anker/eufy", 0 },
};
static const size_t CAMERA_VENDOR_OUI_COUNT = sizeof(CAMERA_VENDOR_OUI) / sizeof(CAMERA_VENDOR_OUI[0]);

// FIRST FIELD VALIDATION 2026-07-23. An airport capture returned 8 network-camera rows across
// four OUIs (Dahua 4C:11:BF x2, BC:32:5F x2, E0:50:8B x1; Reolink EC:71:DB x3) and the user
// confirmed all 8 were real network cameras. So both halves held: the OUI named the vendor
// correctly AND the device really was a camera. The other 39 OUIs in this table remain
// REGISTRY-SOURCED ONLY and unconfirmed.
//
// The confidence below is deliberately NOT raised on that result, and this is the important
// part: 8 hits at ONE site is exactly the evidence shape that made POLICE_OUI's "3 distinct
// MACs at one site" comment overstate its case, and that vendor turned out to be 0/27 when it
// was finally measured (see police_signatures.h). One venue's ceiling cameras do not establish
// what a Dahua OUI means in a house, an office, or a parking garage. Raise this only on
// captures from materially different environments.
//
// Confidence for a network-camera OUI match. Moderate: the OUI reliably names the vendor
// (these brands use public, non-randomized MACs), but a match is "a <vendor> device is on
// the network", NOT "a hidden camera" - it could be an NVR / doorbell / disclosed camera.
// Below the field-validated Axon tier (75) and Flock SSID (88); above the raw drone-OUI
// fallback (60). Honesty over alarm.
#define NETCAM_OUI_CONFIDENCE  65
// A field-validated block earns the same tier as the field-validated Axon OUI (75). Only the
// four entries flagged validated=1 get it; the other 39 stay registry-only at 65.
#define NETCAM_OUI_CONFIDENCE_VALIDATED  75

#endif // ACAB_NETCAM_SIGNATURES_H
