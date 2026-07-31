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
 * SHARED-ID GATE (sharedId flag): the shared corporate IDs (0x058E, 0x01AB, 0x0BC6) DO
 * NOT match in shipped builds. A Quest in the living room advertises 0x058E from a
 * rotating private address, so a bare shared-ID match beeps on every address rotation
 * and the per-MAC Ignore can never silence it - a permanent false alarm on hardware
 * with tens of millions of units. The eyewear-only IDs stay on by default (Ray-Ban Meta
 * coverage survives via Luxottica 0x0D53), and a Meta-ID advert that carries the
 * META_RB_GLASS token still emits as confirmed glasses even while the bare match is
 * gated (see glasses_detect.cpp). Re-enable the bare shared-ID match only after a
 * field-verified payload discriminator separates glasses from a Quest / TCL phone.
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
    //   appears across Meta hardware (Quest included). Same shared-ID gate + sub-50 cap.
    //   src: Bluetooth SIG company-identifier registry.
    { 0x01AB, 45, true,  true,  "Meta: possible recording glasses or Quest" },

    // 0x0BC6  TCL COMMUNICATION EQUIPMENT CO.,LTD.  - TCL ships phones, tablets and TVs; the
    //   RayNeo AR / smart-glasses sub-brand advertises under this SHARED ID (or a silicon-vendor
    //   ID), so a hit is NOT glasses-specific. GATED OFF (sharedId) with no token to rescue it;
    //   RayNeo has no eyewear-only SIG ID, so RayNeo detection waits on a field capture.
    //   src: Bluetooth SIG company-identifier registry (decimal 3014).
    { 0x0BC6, 45, true,  false, "TCL/RayNeo? possible recording glasses" },
};
static const size_t GLASSES_SIG_COUNT = sizeof(GLASSES_SIGS) / sizeof(GLASSES_SIGS[0]);

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
