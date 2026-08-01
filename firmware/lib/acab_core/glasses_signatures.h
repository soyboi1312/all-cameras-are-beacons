/*
 * ACAB - Smart / recording-glasses signature table (clean-room).
 *
 * Every entry is a Bluetooth SIG company identifier sourced from the public SIG
 * assigned-numbers registry (the same registry maclookup / Nordic mirror), NOT from
 * any upstream detection code. Recording glasses are BLE devices that advertise their
 * vendor's company ID in the manufacturer-specific data (AD type 0xFF); the ID rides
 * in the PAYLOAD, so it survives the BLE MAC randomization that breaks OUI matching -
 * which is the whole point of keying on it. See docs/signatures.md.
 *
 * CONFIDENCE is graded by how eyewear-specific the registrant is:
 *   - Luxottica / Snapchat only ship eyewear (or, for Snap, only Spectacles), so a hit
 *     is glasses with high confidence.
 *   - The Meta corporate IDs are SHARED across Meta's whole hardware line, most notably
 *     the Meta Quest VR headset. A passer-by carrying a Quest advertises the SAME
 *     company ID as the Ray-Ban / Oakley Meta glasses, so those IDs are only WEAK
 *     evidence and the detail string must say "may be a Quest, not glasses".
 *   - TCL ships phones, tablets and TVs as well as the RayNeo AR-glasses sub-brand, so
 *     its ID is the weakest signal here.
 *
 * SHARED-ID GATE (sharedId flag): the shared IDs 0x058E, 0x0BC6 and 0x05D6 DO NOT match in
 * shipped builds. The first two are the Quest / TCL-phone overlap described below; 0x05D6 is
 * a Bluetooth AUDIO SoC vendor (Jieli) whose chips sit in a huge population of cheap earbuds,
 * so a bare match would flag headphones as glasses.
 * The Quest case is the sharpest: one in a living room advertises 0x058E from a rotating private
 * address, so a bare shared-ID match beeps on every rotation and the per-MAC Ignore can never
 * silence it - a permanent false alarm on hardware with tens of millions of units. A Meta-ID advert carrying the META_RB_GLASS token still emits as confirmed
 * glasses even while the bare match is gated (see glasses_detect.cpp).
 *
 * 0x01AB WAS UN-GATED 2026-07-31 ON FIELD GROUND TRUTH. Three Meta glasses (Ray-Ban and
 * Oakley) were worn through a 70-minute / 1568-row capture. Results:
 *   - 0x01AB appeared EXACTLY TWICE, 12:25:50 and 12:26:15 local, both inside the known
 *     window and nowhere else in the file. Clean correlation with ground truth.
 *   - 0x0D53 (Luxottica) appeared ZERO times. That fallback was the whole justification
 *     for gating the Meta IDs ("Ray-Ban Meta coverage survives via Luxottica"), and it is
 *     now disproven: with the gate on and Luxottica silent, Ray-Ban Meta had NO coverage.
 *   - 0x058E appeared ZERO times while glasses were present, which is consistent with the
 *     documented split (glasses on the corporate 0x01AB, Quest on 0x058E). That is why
 *     0x058E STAYS GATED and only 0x01AB was released.
 * Confidence stays at 45, below 50, so this lands in the apps' weak-match "verify this"
 * band and never a calm partial match, and the detail keeps its Quest caveat because
 * 0x01AB is still a corporate ID rather than an eyewear-only one.
 * ACCEPTED RISK: other Meta hardware advertising 0x01AB from a rotating address will
 * produce a repeating weak match that per-MAC Ignore cannot silence. If that proves noisy
 * indoors, set sharedId back to true - that one flag restores the old behaviour.
 * NOTE the glasses used RESOLVABLE PRIVATE ADDRESSES (0x41.., 0x5f.., top bits 01), so
 * they ROTATE. No OUI list can ever detect these; the payload company ID is the only
 * durable handle. See the OUI warning below.
 *
 * QUEST DISCRIMINATOR (CAPTURE-PENDING): reporting on the "nearby glasses" project and
 * the Spectacle keychain says the Ray-Ban / Oakley Meta glasses carry the ASCII token
 * "META_RB_GLASS" inside their manufacturer data, which separates them from a Quest
 * under the shared 0x058E ID. We check for it (GLASSES_META_TOKEN below) and, when
 * present, upgrade a Meta-ID hit to a confirmed-glasses confidence and drop the Quest
 * caveat. The exact on-wire framing is UNVERIFIED here.
 *   CAPTURE-PENDING: confirm the glasses actually advertise their company ID (and the
 *   META_RB_GLASS token) while WORN in the field, and confirm the token's byte framing,
 *   before trusting these confidences. The advertised device NAME also identifies the
 *   glasses but is generally only exposed during pairing, so it is rarely visible in the
 *   field and is deliberately not matched here.
 *   src: Bluetooth SIG assigned-numbers company-identifier registry; Help Net Security /
 *   "nearby glasses" (nearbyglasses) reporting on the Meta-ID Quest overlap.
 */
#ifndef ACAB_GLASSES_SIGNATURES_H
#define ACAB_GLASSES_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// One BLE manufacturer company ID we treat as a recording-glasses signal.
struct GlassesSig {
    uint16_t    companyId;    // BLE SIG company identifier (little-endian on the wire)
    uint8_t     confidence;   // 0..100, graded by how eyewear-specific the registrant is
    bool        sharedId;     // true = ID shared with non-glasses hardware (Quest/TCL): bare match gated OFF
    bool        metaShared;   // true = corporate Meta ID (META_RB_GLASS token can confirm glasses)
    const char* detail;       // vendor + "possible recording glasses" (+ Quest caveat), <= 47 chars
};

// The verified table. Confidences: eyewear-only registrants (Luxottica/Snap) high;
// the shared corporate IDs (Meta/TCL) below 50 so that even a build that re-enables
// them lands in the apps' weak-match "verify this" band, never a calm partial match.
static const GlassesSig GLASSES_SIGS[] = {
    // 0x0D53  Luxottica Group S.p.A  - eyewear-ONLY registrant (Luxottica / EssilorLuxottica),
    //   associated with the Ray-Ban Meta frames. Confirmed present in the Nordic SIG mirror.
    //   Eyewear-specific, so no payload discriminator is needed. Highest of the glasses tier,
    //   but CAPTURE-PENDING, so still below the field-validated Axon OUI (75).
    //   src: Bluetooth SIG company-identifier registry.
    { 0x0D53, 70, false, false, "Luxottica: possible recording glasses" },

    // 0x03C2  Snapchat Inc  - Snap Spectacles camera glasses. Snap's only BLE hardware is
    //   Spectacles, so this is effectively eyewear-only for detection. HIGHER confidence.
    //   src: Bluetooth SIG company-identifier registry.
    { 0x03C2, 70, false, false, "Snap Spectacles: recording glasses" },

    // 0x060C  Vuzix Corporation  - AR-eyewear-ONLY maker whose products (Blade, M400,
    //   Shield, Z100) carry on-board cameras. No phones / VR headsets / shared hardware
    //   line, so a hit is glasses with no Quest-style caveat. Eyewear-specific = HIGHER
    //   confidence, no payload discriminator needed. Not shared, not Meta.
    //   src: Bluetooth SIG company-identifier registry.
    { 0x060C, 70, false, false, "Vuzix: possible recording glasses" },

    // 0x058E  Meta Platforms Technologies, LLC  - Ray-Ban / Oakley Meta AI glasses AND the
    //   Meta Quest VR headset (former Oculus / Facebook Technologies). SHARED hardware ID =
    //   the Quest false-positive source, so the bare match is GATED OFF (sharedId); only a
    //   META_RB_GLASS token hit emits (as confirmed glasses). Confidence kept below 50 so a
    //   re-enabled bare match still draws the apps' weak-match treatment.
    //   src: Bluetooth SIG company-identifier registry.
    { 0x058E, 49, true,  true,  "Meta: possible recording glasses or Quest" },

    // 0x01AB  Meta Platforms, Inc.  - Meta corporate / parent BLE ID, not eyewear-specific;
    //   appears across Meta hardware. UN-GATED 2026-07-31 on the ground-truth capture (see the
    //   header); the sub-50 cap stays, so it lands in the apps' weak-match band. A confirmed
    //   non-glasses Meta device was seen on it the same day, which is what conf 45 is for.
    //   src: Bluetooth SIG company-identifier registry.
    { 0x01AB, 45, false, true,  "Meta: possible recording glasses or Quest" },   // UN-GATED 2026-07-31, see header

    // 0x0BC6  TCL COMMUNICATION EQUIPMENT CO.,LTD.  - TCL ships phones, tablets and TVs; the
    //   RayNeo AR / smart-glasses sub-brand advertises under this SHARED ID (or a silicon-vendor
    //   ID), so a hit is NOT glasses-specific. GATED OFF (sharedId) with no token to rescue it;
    //   RayNeo has no eyewear-only SIG ID, so RayNeo detection waits on a field capture.
    //   src: Bluetooth SIG company-identifier registry (decimal 3014).
    { 0x0BC6, 45, true,  false, "TCL/RayNeo? possible recording glasses" },

    // 0x05D6  Zhuhai Jieli Technology Co. - associated with Rogbird VisionPro / Rollme
    //   VistaView camera glasses. GATED OFF, and it must stay that way unless a capture
    //   proves otherwise: Jieli is a Bluetooth AUDIO SoC vendor, not an eyewear brand. Their
    //   JL-series chips sit inside an enormous population of cheap TWS earbuds, speakers and
    //   dongles, all of which advertise this same company ID. This is the Espressif problem
    //   in miniature - the ID identifies the SILICON, not the product - so a bare match would
    //   flag every knock-off earbud in a train carriage. No token exists to rescue it.
    //   Listed so the ID is on record with its reasoning rather than being rediscovered and
    //   added unguarded later. src: Bluetooth SIG registry; yj_nearbyglasses README.
    { 0x05D6, 40, true,  false, "Jieli chipset? possible recording glasses" },
};
static const size_t GLASSES_SIG_COUNT = sizeof(GLASSES_SIGS) / sizeof(GLASSES_SIGS[0]);

// ---- HeyCyan SDK service UUID -------------------------------------------------------
// 7905FFF0-B5CE-4E99-A40F-4B1E122D00D0, the primary service advertised by glasses built on
// the HeyCyan SDK (Nilox Smart AI Glasses and other rebrands). This is the best-shaped
// signal in the table: it identifies the SOFTWARE rather than a corporate registrant, so it
// does not suffer the Quest / earbud ambiguity, and it rides in the payload so it survives
// the resolvable-private-address rotation that makes OUI matching useless for eyewear.
//
// *** READ BEFORE EDITING: THE BASE IS APPLE'S ANCS. ***
// Apple's Notification Center Service is 7905F431-B5CE-4E99-A40F-4B1E122D00D0. This UUID
// shares its ENTIRE 96-bit base and the leading 7905, differing only F431 -> FFF0 (0xFFF0
// being the stock "cheap BLE module" service). A PREFIX or partial match would therefore
// fire on every device that consumes Apple notifications, which is a huge slice of all
// wearables. Only ever match the FULL 16 bytes. Verified against the published ANCS UUID
// 2026-07-31 precisely because the near-collision looked like a transcription error.
//
// Wire order is little-endian (BLE sends 128-bit UUIDs LSB first). Both orders are matched
// because advertisers have been seen to get this wrong, and a 16-byte match is specific
// enough that the reversed form carries no realistic collision risk.
// CAPTURE-PENDING: no device in this repo's captures has ever advertised it.
// src: yj_nearbyglasses README; HeyCyanSmartGlassesSDK.
#define GLASSES_HEYCYAN_UUID_LEN 16
static const uint8_t GLASSES_HEYCYAN_UUID_LE[GLASSES_HEYCYAN_UUID_LEN] = {
    0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4,
    0x99, 0x4E, 0xCE, 0xB5, 0xF0, 0xFF, 0x05, 0x79
};
static const uint8_t GLASSES_HEYCYAN_UUID_BE[GLASSES_HEYCYAN_UUID_LEN] = {
    0x79, 0x05, 0xFF, 0xF0, 0xB5, 0xCE, 0x4E, 0x99,
    0xA4, 0x0F, 0x4B, 0x1E, 0x12, 0x2D, 0x00, 0xD0
};
// Confidence for a HeyCyan UUID hit. ABOVE the corporate-ID tier (it names the glasses
// software, not a parent company) but BELOW the field-validated tier, because unlike the
// 0x01AB un-gate this has no ground-truth capture behind it yet.
#define GLASSES_HEYCYAN_CONF  68

// ---- 16-bit SIG MEMBER service UUIDs -------------------------------------------------
// A SECOND, SEPARATE NAMESPACE from the company IDs above, and easy to confuse with them:
// the SIG allocates 16-bit "member UUIDs" (the 0xFDxx / 0xFExx range) independently of
// company identifiers, so 0xFEB7 is NOT company ID 0xFEB7 - it is a service UUID that a
// device advertises in an AD 0x02/0x03 UUID list or an AD 0x16 service-data record. A
// device can therefore expose its vendor through EITHER namespace, and a detector that
// only reads manufacturer data (as this one did until 2026-07-31) is blind to this half.
//
// All four verified 2026-07-31 against the SIG's own member_uuids.yaml (708 entries,
// pulled from bitbucket.org/bluetooth-SIG/public), not taken on trust from a third-party
// repo. That list contains EXACTLY these Meta/Snap allocations and no others.
//
// The gating rule is identical to the company-ID table and keyed on the same registrant
// split that the 2026-07-31 ground-truth capture established:
//   - "Meta Platforms, Inc."             = the registrant of company ID 0x01AB, the one
//                                          CONFIRMED on real glasses -> ungated.
//   - "Meta Platforms Technologies, LLC" = the registrant of company ID 0x058E, the
//                                          documented Quest ID -> GATED, same as 0x058E.
// This is an inference by registrant, not a capture of these UUIDs specifically. None of
// them has been observed in any capture here; the CSV export carries no service UUIDs, so
// the 2026-07-31 capture could neither confirm nor refute them.
// src: Bluetooth SIG member_uuids.yaml; NullPxl/banrays (which supplied FD5F/FEB7/FEB8 but
// missed Snap's FE45, and cited nothing).
struct GlassesSvcUuid {
    uint16_t    uuid;         // 16-bit SIG member UUID
    uint8_t     confidence;
    bool        sharedId;     // true = registrant also ships the Quest -> bare match gated OFF
    const char* detail;
};
static const GlassesSvcUuid GLASSES_SVC_UUIDS[] = {
    { 0xFEB7, 45, false, "Meta: possible recording glasses or Quest" },
    { 0xFEB8, 45, false, "Meta: possible recording glasses or Quest" },
    // Same registrant as company ID 0x058E (the Quest). Gated for the same reason.
    { 0xFD5F, 49, true,  "Meta: possible recording glasses or Quest" },
    // Snapchat's member UUID, the service-UUID twin of company ID 0x03C2. Snap's only BLE
    // hardware is Spectacles, so eyewear-only = same high confidence as its company ID.
    { 0xFE45, 70, false, "Snap Spectacles: recording glasses" },
};
static const size_t GLASSES_SVC_UUID_COUNT =
    sizeof(GLASSES_SVC_UUIDS) / sizeof(GLASSES_SVC_UUIDS[0]);

// ASCII token the Ray-Ban / Oakley Meta glasses are reported to carry in their
// manufacturer data, used to tell them apart from a Meta Quest under the shared Meta
// IDs. CAPTURE-PENDING (byte framing unverified) - matched in both byte orders via
// acabBytesContainAscii, and only used as a confidence bump, never a standalone match.
#define GLASSES_META_TOKEN  "META_RB_GLASS"

// Confidence a Meta-ID hit is upgraded to once the META_RB_GLASS token confirms glasses
// (drops the Quest caveat). Still CAPTURE-PENDING (token framing unverified), so kept BELOW
// the field-validated tier (Axon OUI = 75) rather than at the top: it's a strong hint, not a
// confirmed field capture.
#define GLASSES_META_CONFIRMED_CONF  72

#endif // ACAB_GLASSES_SIGNATURES_H
