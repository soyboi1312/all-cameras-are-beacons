/*
 * ACAB - official vendor BLE identifiers, capture builds only (pure decisions, no platform deps).
 *
 * WHY THIS IS A HEADER. Everything here used to live inside acab_scanner.cpp's ACAB_CAPTURE_BUILD
 * block, which cannot be compiled on a laptop: that translation unit pulls in Arduino, NimBLE,
 * WiFi, Preferences and FreeRTOS. So the routing table, the identifier scan and the per-MAC
 * reservation had ZERO host coverage - `grep -rl VENDOR_BLE_ID firmware/tools/host-tests/`
 * returned nothing - while the routing was being rewritten. Same reasoning as sink_claim.h: the
 * DECISION is pure, so it moves somewhere the host tests can reach it, and the state it decides
 * over stays behind in the scanner. test_vendor_capture.cpp is that coverage.
 *
 * Nothing here classifies. These identifiers are logged, counted and bracketed by marker windows;
 * they never fill AcabDetection and never reach the apps.
 *
 * COST TO SHIPPING IMAGES IS ZERO. acab_scanner.cpp includes this file only inside its
 * ACAB_CAPTURE_BUILD guard, and every use of the table and routines sits inside the same guarded
 * regions, so no production translation unit references any of it. Keep the include inside the
 * guard so no production translation unit can grow a reference to it. That is the mechanism,
 * stated precisely: the table has internal linkage and every routine is inline, so an include
 * that references nothing emits nothing by itself; the guard is what keeps capture code out of
 * the production build by construction, rather than by trusting the linker to discard it.
 *
 * ---------------------------------------------------------------------------------------------
 * OFFICIAL VENDOR BLE IDENTIFIERS - capture builds only, and deliberately NOT a classifier.
 *
 * These are Bluetooth SIG ASSIGNED NUMBERS, i.e. registered to a named company, which makes them
 * a categorically better class of evidence than the MAC OUI lists this project has been burned by.
 * An OUI names whoever made the radio module (Liteon, Espressif, Murata) and is shared across
 * millions of unrelated devices. A SIG company ID or a 16-bit service UUID is issued to the
 * product vendor. Matching one says "this is that company's equipment" with far less ambiguity.
 *
 * WHAT IT STILL DOES NOT SAY IS *WHICH* PRODUCT. Axon's own Device Manager compatibility list
 * spans Body 2/3/4 and Body Mini, Flex, Signal Sidearm holster sensors, Signal Vehicle and Fleet
 * gear, and TASER 7/10 handles and batteries. Motorola Solutions covers APX radios, V500/V700/
 * VB400 cameras, M500 in-car video, Holster Aware sensors and accessories - and the same vendor
 * identifiers are carried by fire, EMS, security and retail hardware. So the eventual shipping
 * label is "<vendor> equipment, device type unknown", never "Body camera". This build exists to
 * find out which values map to which products BEFORE any of that is written.
 *
 * THE LOCAL NAME IS THE PAYLOAD THAT MATTERS. The identifier tells you the vendor; the advertised
 * name is the only field likely to separate a Body 4 from a TASER 10 battery. It is logged beside
 * every hit for exactly that reason.
 *
 * Sources: Bluetooth SIG Assigned Numbers (company identifiers + 16-bit UUIDs). Both vendors are
 * live locally, which is why this is worth the flash: San Diego has an active Axon body-camera
 * contract and a five-year TASER 10 agreement.
 */
#ifndef ACAB_VENDOR_CAPTURE_H
#define ACAB_VENDOR_CAPTURE_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "ble_adv16.h"   // structural 16-bit UUID / company-ID decoding, ONE implementation

// Which per-vendor table and counter a row feeds. This used to be inferred from the tag's first
// letter (`tag[0] == 'A'` meant Axon, anything else meant Motorola), which held only while the
// list carried exactly two vendors whose names began with different letters. The first row added
// outside that pair would have landed in the Motorola table and inflated moto_ble - the one
// counter whose ZERO is currently a result worth quoting. The group is stated per row now, so the
// routing cannot go wrong by accident.
enum VendorGroup : uint8_t { VG_AXON = 0, VG_MOTO = 1, VG_PCAM = 2, VG_N = 3 };

struct VendorBleId {
    uint8_t     kind;    // 0 = manufacturer company ID (AD 0xFF), 1 = 16-bit service UUID
    uint16_t    val;
    const char* tag;
    VendorGroup group;   // which table and counter this row feeds. Typed: a bare integer here is
                         // a compile error, and the static_assert below VENDOR_BLE_ID_N rejects
                         // VG_N itself.
};

// constexpr rather than const so the group-range static_assert below can read the rows.
static constexpr VendorBleId VENDOR_BLE_ID[] = {
    // --- Axon / TASER. FIRST validation target: locally deployed, and the narrower vendor. ---
    { 0, 0x034D, "AXON-CID", VG_AXON },   // TASER International, manufacturer company ID
    { 1, 0xFC81, "AXON-SVC", VG_AXON },   // Axon Enterprise, 16-bit service UUID
    { 1, 0xFE6B, "AXON-SVC", VG_AXON },   // TASER International
    { 1, 0xFE6C, "AXON-SVC", VG_AXON },   // TASER International
    // --- Motorola Solutions. Second in the SHIPPING order, but riding along in capture from the
    // start on purpose: a drive not instrumented today cannot be re-taken retroactively, and the
    // cost of carrying three more comparisons is nil. Kept tagged separately so the analysis can
    // hold them apart, and so the Axon work is never blocked on Motorola data. ---
    { 0, 0x04EC, "MOTO-CID", VG_MOTO },   // Motorola Solutions, manufacturer company ID
    { 1, 0xFD8E, "MOTO-SVC", VG_MOTO },   // Motorola Solutions
    { 1, 0xFE04, "MOTO-SVC", VG_MOTO },   // Motorola Solutions
    // --- Company ID 0x087F, tagged "PCAM-CID". This row is in for a different question from
    // the two vendors above. Those name a company already suspected and ask WHICH of its products
    // carry the identifier. This one was added because a device family kept turning up that could
    // not be attributed at all, and asked WHO MAKES IT.
    //
    // THAT QUESTION IS NOW ANSWERED, and the answer is not a camera vendor. 0x087F (2175) is
    // registered to Phillips Connect Technologies LLC in the Bluetooth SIG published
    // company-identifier list. Our own capture corroborates it independently: one device in the
    // same population advertises PCTGW_83955, which reads as Phillips Connect Technologies
    // GateWay. Phillips Connect sells trailer telematics - smart-trailer gateways, cargo sensors
    // and trailer cameras - and the other name families in the population (CFQU*, GV*, W26466,
    // F11123) are consistent with fleet-asset hardware. The resolution is from an external
    // registry; no copy of the SIG list exists in this repo, so re-confirm it against the
    // assigned-numbers list before this row is promoted anywhere out of capture. WHETHER A
    // TRAILER-TELEMATICS FAMILY BELONGS IN THIS LIST AT ALL IS AN OPEN PRODUCT QUESTION.
    //
    // "PCAM" is a vendor-chosen advertised name and that is ALL it is. Keep the string out of any
    // category decision: a vendor picks its own name, it costs nothing to choose, and reading a
    // product from a broadcast label is a mistake this project has already paid for once. The name
    // is LOGGED, not believed. The tag "PCAM-CID" records the row's history, not its vendor.
    //
    // FIELD SHAPE - TWO shapes, not one. Measured by walking AD structures over every advert in
    // the logs that carry advert bytes:
    //   A: 02 01 06 | 09 FF 7F08 0A 01 <4 varying> | 0C 09 "PCAM_" + last 3 MAC bytes  12 devices
    //   B: 02 01 06 | 0E FF 7F08 00 00 00 <8 BCD bytes> | <len> 09 <name>              12 devices
    // The 0x09 length byte settles the varying-byte count at FOUR (1 type + 2 company ID + 2
    // lead-in + 4 = 9). Shape A carries the PCAM_ name in 12 of 12 cases; shape B carries the
    // other name families. The bytes are NOT byte-identical across sightings, not even within one
    // device: EF:19:4C:DE:76:BF sent 0A 01 27 1B 67 16 and then 0A 01 28 1B 67 16 within a second.
    //
    // EVIDENCE BASE: 24 distinct MACs across the three logs that record advert bytes
    // (drive_home_9-4 holds 19 of them, aug-9-drive2 and compare-dual the rest). camarillo_drive
    // and santabarbara are PRODUCT-image logs with no adv= hex at all, so they can only ever have
    // matched the name string and cannot support a byte-level claim. Best sighting -56 dBm,
    // CC:FE:BA:21:16:72, on a six-sighting ramp from -93 over 13 seconds.
    //
    // EVERY ADDRESS SEEN SO FAR IS BLE RANDOM-STATIC (top two bits set), 24 of 24, so there is no
    // OUI to take and no registry lookup to run on the address. The company ID is the only durable
    // vendor evidence this family emits, which is precisely the case this capture list exists for.
    // It is also why the shipping classifier labels some of these "hardware OUI": the
    // locally-administered-bit test cannot tell a random-static address from a public one. That
    // defect is tracked separately and this row does not depend on it either way.
    //   src: own field capture, extracted to
    //        docs/captures/vendor-cid-087f-2026-09-04.txt
    { 0, 0x087F, "PCAM-CID", VG_PCAM },
};
#define VENDOR_BLE_ID_N (sizeof(VENDOR_BLE_ID) / sizeof(VENDOR_BLE_ID[0]))

// EVERY ROW'S GROUP IS BELOW VG_N, enforced at compile time. The ingest site in acab_scanner.cpp
// indexes its gVendorTab[VG_N] with acabVendorSlotGroup's answer and relies on this: a row whose
// group were VG_N would make acabVendorGroupMask set a bit no table owns, acabVendorSlotGroup
// would return VG_N, and the scanner would index one past a three-entry array inside the scan
// task, mid-drive. The typed field already rejects a bare integer; this rejects VG_N itself. One
// recursive return rather than a loop because the Arduino-ESP32 core builds the S3 envs at
// -std=gnu++11, where a constexpr function is a single return statement; the host suite compiles
// the same header at -std=c++17.
constexpr bool acabVendorGroupsInRange(size_t k) {
    return k >= VENDOR_BLE_ID_N
        || (VENDOR_BLE_ID[k].group < VG_N && acabVendorGroupsInRange(k + 1));
}
static_assert(acabVendorGroupsInRange(0),
              "every VENDOR_BLE_ID row must name a VendorGroup below VG_N: the scanner indexes "
              "gVendorTab[VG_N] with it");

// THE HIT MASK IS A uint8_t EVERYWHERE, so a ninth row would shift straight out of every carrier
// and read as no hit at all, silently. The named fields are only where it comes to REST -
// AcabVendorRec::hits here, and AcabMarkRec::vendorMask / ::solicitMask in mark_table.h - and
// widening those three alone is not enough, because the mask is a uint8_t at every carrier
// between them, including: AcabVendorScanCtx::mask and ::solicit, and the (uint8_t)(1u << k)
// casts the two callbacks below write through; the out-params of acabVendorScanAdv; the `hit`
// parameter of acabVendorGroupMask; at the ingest site in acab_scanner.cpp both the block-scoped
// `hit`/`sol` and the function-scoped `vendorHit`/`vendorSol` the marker window is fed from; the
// scanner's file-static markNote wrapper; the acabMarkNote parameters in mark_table.h; and the
// host tests' own locals. No build here carries -Wconversion (platformio.ini sets none, and
// tools/host-tests/run.sh compiles with -Wall alone), so a carrier missed while widening narrows
// silently and drops the ninth bit somewhere between the scan and the mark table. Widen the
// whole path, or stop at eight. Treat this list as a starting point and the grep as the checklist:
//     grep -n 'uint8_t.*\(hit\|sol\|[Mm]ask\)\|vendorHit\|vendorSol' vendor_capture.h mark_table.h acab_scanner.cpp
// The static_assert is what stops a ninth row from being added quietly; it is evaluated by the
// host suite as well as by a capture build, which is the point of this header.
static_assert(VENDOR_BLE_ID_N <= 8,
              "VENDOR_BLE_ID is indexed by a uint8_t bitmask (AcabVendorRec::hits, "
              "AcabMarkRec::vendorMask/solicitMask, and the whole scan/ingest carry path); "
              "widen those before adding a ninth row");

/// One captured MAC's running tally. Owned by the scanner's per-group tables; declared here so the
/// reservation decision below can be exercised without them.
struct AcabVendorRec {
    uint8_t  mac[6];
    uint32_t n;
    int8_t   best;
    uint8_t  hits;        // bitmask over VENDOR_BLE_ID, accumulated from the packets routed to THIS
                          // table (GROUP ROUTING below): identifiers a device sends in separate
                          // packets that route to different groups land in different rows
    uint32_t firstMs;
    uint32_t lastLogMs;
    bool     used;
};

// ---------------------------------------------------------------------------------------------
// IDENTIFIER SCAN
//
// Decoding lives in ble_adv16.h so there is ONE implementation: whatever proves out in a field
// capture is byte-for-byte what a shipping classifier would later match on. An inline copy here
// would drift from the shipping path, and the whole point of the capture is to justify that path.
// It walks AD 0x02/0x03 (service UUID lists), 0x14 (solicitation) and 0x16 (service data, UUID in
// the first two bytes only), and reads EVERY 0xFF structure rather than latching the first.
// SOLICITATION IS KEPT APART FROM CONFIRMATION, and the distinction is not pedantic.
//
// AD 0x02/0x03 (service UUID lists) and 0x16 (service data) are a device SAYING WHAT IT IS. AD
// 0x14 is service SOLICITATION: per the Core Specification Supplement it is a peripheral inviting
// centrals that PROVIDE the named service. So an Axon UUID in 0x14 is a device looking FOR Axon
// equipment - plausibly a phone running Axon's app, or an accessory hunting for a camera. Folding
// it into the same mask would let a bystander's handset be counted as vendor equipment, which is
// the precise failure mode this whole capture-first approach exists to avoid.
//
// It is still worth recording. "Something here was looking for an Axon service" is a real
// observation, and near a confirmed device the two together are more informative than either. It
// just never counts as vendor-confirmed, and it is rendered on its own axis.
struct AcabVendorScanCtx { uint8_t mask; uint8_t solicit; };

inline void acabVendorUuidCb(uint16_t u, uint8_t adType, void* ctx) {
    AcabVendorScanCtx* c = (AcabVendorScanCtx*)ctx;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
        if (VENDOR_BLE_ID[k].kind != 1 || VENDOR_BLE_ID[k].val != u) continue;
        if (adType == ACAB_AD_UUID16_SOLICIT) c->solicit |= (uint8_t)(1u << k);
        else                                  c->mask    |= (uint8_t)(1u << k);
    }
}

inline void acabVendorCidCb(uint16_t cid, void* ctx) {
    AcabVendorScanCtx* c = (AcabVendorScanCtx*)ctx;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++)
        if (VENDOR_BLE_ID[k].kind == 0 && VENDOR_BLE_ID[k].val == cid) c->mask |= (uint8_t)(1u << k);
}

/// Bitmask of VENDOR_BLE_ID entries this advert structurally carries, confirmation and
/// solicitation kept apart.
inline void acabVendorScanAdv(const uint8_t* adv, size_t len, uint8_t* mask, uint8_t* solicit) {
    AcabVendorScanCtx c; c.mask = 0; c.solicit = 0;
    acabAdvForEachUuid16(adv, len, acabVendorUuidCb, &c);
    acabAdvForEachCompanyId(adv, len, acabVendorCidCb, &c);
    *mask = c.mask; *solicit = c.solicit;
}

// ---------------------------------------------------------------------------------------------
// GROUP ROUTING
//
// DECIDED PER ADVERT, from the identifiers THAT PACKET carries. Every group the packet names is
// COUNTED (the per-advert gVendorAxon / gVendorMoto / gVendorPcam counters in acab_scanner.cpp,
// printed as axon_ble / moto_ble / pcam_ble on the wifi_diag line), and the packet is then slotted
// into ONE table, the lowest-numbered group present. So one advert carrying two groups'
// identifiers bumps both counters and takes at most one slot, and a Motorola-only or PCAM-only
// advert never touches the Axon table.
//
// WHAT THIS DOES NOT ENFORCE: one row per DEVICE. Nothing here or at the ingest site looks a MAC
// up across tables before slotting it, so the table an advert reaches depends on its lowest group
// alone. Adverts from one MAC that share a lowest group reach the same table and, once the MAC
// holds a row there, the same row: a company ID in one advert and the same vendor's service UUID
// in the next both accumulate in it, which is what the `packet=` / `seen=` pair on the vendor log
// line in acab_scanner.cpp exists to show. Adverts from one MAC whose lowest groups differ (an
// Axon identifier in one, only a Motorola one in the next) hold a row in each table that still had
// a free slot when the MAC FIRST reached it: acabVendorFind never evicts, and once a MAC holds a
// row it keeps resolving to that row even after the table fills. Each row's `hits` accumulates
// only that MAC's adverts that reached that table. One row per device was the intent; it is not
// what ships, and making it so (a cross-table lookup before every slot) is a routing change, not
// a comment fix.
// test_vendor_capture.cpp pins what this header can: reservation() fails if acabVendorFind
// carries a row or its tally from one table to another. The ingest site in acab_scanner.cpp is
// not host-compiled, so no host test would catch a cross-table lookup added there.
//
// The moto_ble note above (the counter whose ZERO is worth quoting) is unaffected: it is the
// per-advert counter, which this routing keeps honest packet by packet.

/// Bit per VendorGroup: which groups this hit mask names at all. Drives the per-group counters.
inline uint8_t acabVendorGroupMask(uint8_t hit) {
    uint8_t g = 0;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++)
        if (hit & (1u << k)) g |= (uint8_t)(1u << VENDOR_BLE_ID[k].group);
    return g;
}

/// The ONE group whose table THIS ADVERT is slotted into: the lowest-numbered group present in the
/// packet's mask, which biases a packet naming several vendors towards Axon because Axon is what
/// the capture is for. Per advert, not per device (GROUP ROUTING above). Returns VG_N when the
/// mask names no group, which the caller must treat as "do not slot".
inline uint8_t acabVendorSlotGroup(uint8_t groupMask) {
    uint8_t g = VG_AXON;
    while (g < VG_N && !(groupMask & (1u << g))) g++;
    return g;
}

// ---------------------------------------------------------------------------------------------
// PER-MAC RESERVATION
//
// SEPARATE TABLES PER VENDOR, because a shared one is not neutral. Motorola rides along in this
// capture for free in CPU terms, but not in SLOTS: twelve Motorola radios at a station car park
// would fill a shared table and the Axon device the trip was made for would never get a row. Axon
// is the first validation target, so it gets its own reservation and cannot be starved by traffic
// from the vendor that is only here opportunistically. Sizes are deliberately lopsided for the
// same reason.
//
// THE LOOKUP IS PER TABLE. acabVendorFind sees one table and one MAC; it cannot know that the MAC
// already holds a row elsewhere, so "first N distinct MACs" is per table, and a device whose
// packets route to two groups is a distinct MAC in both (GROUP ROUTING above). What the separate
// tables guarantee is narrower than one row per device and is still the property that matters:
// a packet only ever reaches the table of its lowest group, so Motorola-only or PCAM-only traffic
// cannot take an Axon slot.
//
// THERE IS NO EVICTION AND NO AGEING, deliberately: the first N distinct MACs own the table for
// the whole boot, so an early cluster cannot be displaced by a later one and the capture stays
// comparable across a drive. The cost is that a group with more distinct devices than slots loses
// the aggregate row for every device after the Nth. The per-advert group counter still counts
// them, the raw [ble] line still records them under ACAB_DIAG, and the table's `full` count
// records that it happened. READ `full` AS REFUSED ADVERTS, NOT DEVICES: it increments on every
// call that finds no free slot, and THIS FUNCTION remembers no refused MAC, so one unslotted
// device heard thirty times adds thirty. The scanner prints it as `dropped=N` on its TABLE FULL
// notice, and names the MAC of the advert that TRIGGERED that notice - one refused address per
// printed line, never the whole refused set, because nothing here stores one. A non-zero value
// says THIS table's rows are only a floor on the distinct MACs that
// reached it, and that the row total summed over the tables bounds the distinct-MAC count in
// neither direction: a refused MAC holds no row anywhere, and a MAC whose adverts have different
// lowest groups holds one in every table that had a slot for it. Nothing records how many MACs
// got no row at all. acabScannerVendorMacs in acab_scanner.h owns that rule.
inline AcabVendorRec* acabVendorFind(AcabVendorRec* rec, size_t n, const uint8_t* mac,
                                     uint32_t nowMs, uint32_t* full) {
    AcabVendorRec* freeSlot = nullptr;
    for (size_t i = 0; i < n; i++) {
        if (rec[i].used && memcmp(rec[i].mac, mac, 6) == 0) return &rec[i];
        if (!rec[i].used && !freeSlot) freeSlot = &rec[i];
    }
    if (!freeSlot) { if (full) (*full)++; return nullptr; }
    memset(freeSlot, 0, sizeof(*freeSlot));
    memcpy(freeSlot->mac, mac, 6);
    freeSlot->best = -127;
    freeSlot->firstMs = nowMs;
    freeSlot->used = true;
    return freeSlot;
}

// ---------------------------------------------------------------------------------------------
// WHEN THE PER-ROW LINE PRINTS
//
// THE ROW'S FINAL MASK ALWAYS RENDERS, which is why this is not a plain time throttle. The ingest
// site ORs each advert's identifiers into the row BEFORE deciding, so under a time-only test a bit
// gained inside the window printed only if that MAC happened to be heard again after the window.
// A device that sent its company ID, got its line, sent its service UUID a second later and drove
// out of range left a row holding both and a log showing one. Nothing walks the tables at capture
// end, and the only other render of the mask is the scanner's marker summary, which needs an
// operator marker that a normal drive does not have. Co-occurrence per device is the single
// product this capture build exists to produce, so a change to the mask emits.
//
// THE EXTRA LINES ARE BOUNDED AT ONE PER IDENTIFIER PER ROW, eight on today's table, for the whole
// boot: `hits` only ever gains bits (the ingest site ORs, nothing clears it, and acabVendorFind
// never evicts a row), so it can change at most VENDOR_BLE_ID_N times. A parked radio re-sending
// the same identifier at advert rate changes nothing and stays throttled, which is what the
// throttle is for.
//
// READING THE LOG BACK, a second line for one MAC is one of TWO things, because the time term
// below is unchanged from the old rule and no mask condition guards it: either the row gained an
// identifier, or the window simply expired on a row that showed nothing new. `seen=` is what
// separates them - a mask that grew is new evidence, an identical mask is the heartbeat. Only
// the first is the co-occurrence this build is for. What the mask term guarantees is the other
// direction, and it holds either way: every change to `hits` emits, so the row's FINAL mask is
// always in the log.
//
// WHAT THIS STILL DOES NOT RE-RENDER inside the window: a better RSSI, a higher `n`, and a name
// that only turns up in a later advert. Those move without changing the mask, so the last line
// printed for a row can understate them until the window expires. That was equally true of the
// time-only rule and is deliberate - they are running tallies, not the identity evidence this
// capture is for, and the marker summary carries best/n when an operator brackets a visit.
//
// everyMs is a parameter rather than a constant here because the period belongs to the scanner
// (VENDOR_LOG_EVERY_MS in acab_scanner.cpp, which also owns the separate TABLE FULL throttle on
// its own stamp). The subtraction is unsigned on purpose: it stays correct across the millis()
// wrap, which a signed comparison would get wrong once every 49.7 days of uptime.
inline bool acabVendorShouldEmit(uint32_t n, uint8_t hitsBefore, uint8_t hitsAfter,
                                 uint32_t nowMs, uint32_t lastLogMs, uint32_t everyMs) {
    return n == 1                                  // first sighting of this MAC in this table
        || hitsAfter != hitsBefore                 // the row learned an identifier: render it
        || (nowMs - lastLogMs) >= everyMs;         // otherwise the noise throttle
}

// ---------------------------------------------------------------------------------------------
// WHEN THE TABLE-FULL NOTICE PRINTS
//
// Same shape as the rule above, and for the same reason: the FIRST event always renders, the rest
// are throttled. `full` is the table's running count of refused adverts and the caller bumps it
// before asking, so full == 1 is the table's very first refusal.
//
// THE FIRST TERM FIXES A REAL HOLE. With a plain time throttle the stamp starts at 0, so
// `nowMs - 0 >= everyMs` is FALSE for the whole first everyMs of uptime and a refusal inside that
// window was swallowed. If the table was never asked again, nothing in the log ever named it and
// vendor_full sat non-zero with no notice anywhere - the reader could see that SOMETHING
// overflowed but not which table. A capture that fills a table in its first seconds is exactly the
// dense environment where the notice matters most, so that was the wrong case to lose.
//
// It does NOT make dropped=N a complete tally. The count keeps rising while the throttle is shut,
// so the LAST printed notice lags the final `full`, and refusals arriving a fraction of a second
// behind a printed one are never named. The authoritative total is vendor_full on the wifi_diag
// line; read the notice for WHICH table and for a sample of WHAT was refused, not for how many.
inline bool acabVendorShouldLogFull(uint32_t full, uint32_t nowMs, uint32_t lastLogMs,
                                    uint32_t everyMs) {
    return full == 1                               // this table's first refusal: always name it
        || (nowMs - lastLogMs) >= everyMs;         // otherwise the same unsigned-safe throttle
}

#endif // ACAB_VENDOR_CAPTURE_H
