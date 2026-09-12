// Host regression test for the SIG vendor identifier capture table (vendor_capture.h).
//
// WHY THIS SUITE EXISTS. The vendor table, its group routing and its per-MAC reservation lived
// inside acab_scanner.cpp's ACAB_CAPTURE_BUILD block, which no host test can compile: that
// translation unit needs Arduino, NimBLE, WiFi, Preferences and FreeRTOS. So when the routing was
// rewritten - the `tag[0] == 'A'` inference replaced by an explicit per-row group - the change
// went in with a PlatformIO compile as its only evidence. The decisions moved into a header for
// the same reason sink_claim.h did, and this file is the coverage.
//
// THE BUG THE REWRITE WAS FOR. Routing used to read the tag's first letter: 'A' meant Axon,
// anything else meant Motorola. That held only while the list carried exactly two vendors whose
// names began with different letters. The first row added outside that pair - PCAM-CID, whose tag
// begins with 'P' - would have landed in the MOTOROLA table and incremented moto_ble, the one
// counter whose ZERO is currently a result worth quoting. `theOldTagLetterRuleWouldHaveMisrouted`
// below is the anchor for that: it scans the PCAM field-shape advert through the live entry points
// (acabVendorScanAdv, then acabVendorGroupMask / acabVendorSlotGroup) and fails if the live routing
// ever lands where the retired rule sent that row.
//
// Read vendor_capture.h first. Every assertion here maps to a stated decision there.
#include "../../lib/acab_core/vendor_capture.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>

static int failures = 0;

static void check(bool ok, const char* what) {
    printf("  %-58s %s\n", what, ok ? "PASS" : "FAIL");
    if (!ok) failures++;
}

// Build an advert buffer from a hex string, the way the drive logs record them.
static size_t fromHex(const char* hex, uint8_t* out, size_t cap) {
    size_t n = 0;
    for (const char* p = hex; p[0] && p[1] && n < cap; p += 2) {
        auto nib = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = nib(p[0]), lo = nib(p[1]);
        if (hi < 0 || lo < 0) break;
        out[n++] = (uint8_t)((hi << 4) | lo);
    }
    return n;
}

// Index of the single row carrying a given (kind, value). Fails the suite if the table stops
// holding exactly one, which is itself worth catching: a duplicated row would double-count.
static int rowIndex(uint8_t kind, uint16_t val) {
    int found = -1;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
        if (VENDOR_BLE_ID[k].kind == kind && VENDOR_BLE_ID[k].val == val) {
            if (found >= 0) return -2;   // duplicate
            found = (int)k;
        }
    }
    return found;
}

// The PCAM field shape, taken structurally from the 2026-09-04 drive log and re-synthesised with
// a placeholder name and payload bytes (no captured address is committed here):
//   02 01 06                        flags
//   09 FF 7F08 0A01 <4 varying>     company ID 0x087F, 0x0A 0x01 lead-in, 4 varying bytes
//   0C 09 "PCAM_XXXXXX"             complete local name restating the address
// NOTE the manufacturer structure is length 0x09, which is type + 2 company-ID bytes + the
// 0x0A 0x01 lead-in + FOUR varying bytes. vendor_capture.h's FIELD SHAPE block records the same
// four; the 0x09 length byte is what settles it. One fixture, shared by the retired-rule section
// and the scan section, so both route the same bytes.
static const char* const PCAM_ADV_HEX = "02010609FF7F080A01AABBCCDD0C095043414D5F414141414141";
static const size_t      PCAM_ADV_LEN = 26;

// ---------------------------------------------------------------------------------------------
// TABLE SHAPE
// ---------------------------------------------------------------------------------------------
static void tableShape() {
    printf("\n== table shape ==\n");

    // The header's two static_asserts (row count, group range) are compile-time, so a host build
    // proves them too - but only if this file actually includes the header, which these runtime
    // restatements make visible.
    check(VENDOR_BLE_ID_N <= 8,
          "the table fits in the uint8_t hit mask (<= 8 rows)");
    check(VENDOR_BLE_ID_N == 8,
          "the table holds the 8 rows this suite was written against");

    bool groupsValid = true, tagsValid = true, kindsValid = true;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
        if (VENDOR_BLE_ID[k].group >= VG_N) groupsValid = false;
        if (!VENDOR_BLE_ID[k].tag || !VENDOR_BLE_ID[k].tag[0]) tagsValid = false;
        if (VENDOR_BLE_ID[k].kind > 1) kindsValid = false;
    }
    check(groupsValid, "every row names a group below VG_N (restates the static_assert)");
    check(tagsValid,   "every row carries a non-empty tag");
    check(kindsValid,  "every row is a company ID (0) or a 16-bit UUID (1)");

    // Every row pinned by (kind, value) to its declared group. The three company IDs are what the
    // routing is about; the five UUID rows are pinned the same way because nothing else holds
    // their groups - the retired-rule check below is about history and deliberately does not.
    struct { uint8_t kind; uint16_t val; VendorGroup group; const char* what; } pin[] = {
        { 0, 0x034D, VG_AXON, "0x034D (TASER company ID) is exactly one row, in VG_AXON" },
        { 0, 0x04EC, VG_MOTO, "0x04EC (Motorola company ID) is exactly one row, in VG_MOTO" },
        { 0, 0x087F, VG_PCAM, "0x087F is exactly one row, in VG_PCAM" },
        { 1, 0xFC81, VG_AXON, "0xFC81 (Axon Enterprise UUID) is exactly one row, in VG_AXON" },
        { 1, 0xFE6B, VG_AXON, "0xFE6B (TASER UUID) is exactly one row, in VG_AXON" },
        { 1, 0xFE6C, VG_AXON, "0xFE6C (TASER UUID) is exactly one row, in VG_AXON" },
        { 1, 0xFD8E, VG_MOTO, "0xFD8E (Motorola UUID) is exactly one row, in VG_MOTO" },
        { 1, 0xFE04, VG_MOTO, "0xFE04 (Motorola UUID) is exactly one row, in VG_MOTO" },
    };
    for (const auto& p : pin) {
        int r = rowIndex(p.kind, p.val);
        check(r >= 0 && VENDOR_BLE_ID[r].group == p.group, p.what);
    }
}

// ---------------------------------------------------------------------------------------------
// THE RETIRED RULE
// ---------------------------------------------------------------------------------------------
static void theOldTagLetterRuleWouldHaveMisrouted() {
    printf("\n== the routing rewrite this cut is for ==\n");

    // Reconstruct the retired inference exactly: tag[0] == 'A' meant Axon, everything else
    // Motorola. It is applied to the tags the rows carried WHEN THE RULE WAS RETIRED, held here
    // as fixture strings, not to today's tags: this section records what the old rule did, and
    // renaming a row today (0x034D to "TASER-CID", say) does not change that history. The live
    // side is never read from the table's `group` field: it is the real routing, acabVendorScanAdv
    // over the PCAM field-shape advert and then acabVendorGroupMask / acabVendorSlotGroup over
    // the mask that produced, so a routing that went back to reading the tag letter fails here
    // instead of a literal being compared with itself.
    auto retiredRule = [](const char* tagThen) -> uint8_t {
        return tagThen[0] == 'A' ? (uint8_t)VG_AXON : (uint8_t)VG_MOTO;
    };

    int pcam = rowIndex(0, 0x087F);
    check(pcam >= 0, "the PCAM row is present to route");
    if (pcam < 0) return;

    uint8_t buf[64], mask = 0, sol = 0;
    size_t n = fromHex(PCAM_ADV_HEX, buf, sizeof buf);
    acabVendorScanAdv(buf, n, &mask, &sol);
    check(n == PCAM_ADV_LEN && mask == (uint8_t)(1u << pcam),
          "the PCAM field-shape advert confirms exactly the 0x087F row");
    const uint8_t live = acabVendorSlotGroup(acabVendorGroupMask(mask));
    const uint8_t then = retiredRule("PCAM-CID");   // VG_MOTO: 'P' is not 'A'
    check(live == VG_PCAM,
          "the live routing slots that advert into VG_PCAM");
    check(live != then,
          "...not into VG_MOTO, where the retired rule sent it - the regression is pinned");

    // And the reason the old rule survived as long as it did: on the seven rows that existed
    // when it was retired it agreed with where the live routing sends each row now, so nothing
    // tripped until a row outside the Axon/Motorola pair arrived. Scoped to those seven by
    // (kind, value): a row that is no longer in the table has nothing to say here (tableShape
    // pins presence), and a row in any future group is not part of this history and cannot turn
    // it red.
    struct { uint8_t kind; uint16_t val; const char* tagThen; } legacy[] = {
        { 0, 0x034D, "AXON-CID" }, { 1, 0xFC81, "AXON-SVC" }, { 1, 0xFE6B, "AXON-SVC" },
        { 1, 0xFE6C, "AXON-SVC" }, { 0, 0x04EC, "MOTO-CID" }, { 1, 0xFD8E, "MOTO-SVC" },
        { 1, 0xFE04, "MOTO-SVC" },
    };
    bool agreesOnLegacyRows = true;
    for (const auto& l : legacy) {
        int r = rowIndex(l.kind, l.val);
        if (r < 0) continue;
        const uint8_t hit = (uint8_t)(1u << r);
        if (retiredRule(l.tagThen) != acabVendorSlotGroup(acabVendorGroupMask(hit)))
            agreesOnLegacyRows = false;
    }
    check(agreesOnLegacyRows,
          "the retired rule agreed with live routing on every row that existed then (why it hid)");
}

// ---------------------------------------------------------------------------------------------
// GROUP MASK AND SLOTTING
// ---------------------------------------------------------------------------------------------
static void groupRouting() {
    printf("\n== group mask and slotting ==\n");

    int axon = rowIndex(0, 0x034D), moto = rowIndex(0, 0x04EC), pcam = rowIndex(0, 0x087F);
    if (axon < 0 || moto < 0 || pcam < 0) { check(false, "table rows resolvable"); return; }

    const uint8_t axonHit = (uint8_t)(1u << axon);
    const uint8_t motoHit = (uint8_t)(1u << moto);
    const uint8_t pcamHit = (uint8_t)(1u << pcam);

    check(acabVendorGroupMask(0) == 0, "no identifiers -> no groups");
    check(acabVendorSlotGroup(0) == VG_N, "no groups -> slot group is VG_N (do not slot)");

    check(acabVendorGroupMask(axonHit) == (1u << VG_AXON), "an Axon identifier names only VG_AXON");
    check(acabVendorGroupMask(motoHit) == (1u << VG_MOTO), "a Motorola identifier names only VG_MOTO");
    check(acabVendorGroupMask(pcamHit) == (1u << VG_PCAM), "a PCAM identifier names only VG_PCAM");

    check(acabVendorSlotGroup(acabVendorGroupMask(pcamHit)) == VG_PCAM,
          "a PCAM-only device slots into the PCAM table");
    check(acabVendorSlotGroup(acabVendorGroupMask(motoHit)) == VG_MOTO,
          "a Motorola-only device slots into the Motorola table");

    // CO-OCCURRENCE WITHIN ONE ADVERT. Every group the packet names is counted, and the packet is
    // slotted ONCE, lowest group first, so one advert cannot take a slot in more than one table.
    // That is the whole guarantee: routing is per advert, and a device that splits its
    // identifiers across packets is routed packet by packet (vendor_capture.h, GROUP ROUTING;
    // the per-table lookup that makes it so is pinned in reservation() below).
    const uint8_t both = (uint8_t)(axonHit | motoHit);
    check(acabVendorGroupMask(both) == ((1u << VG_AXON) | (1u << VG_MOTO)),
          "a dual-vendor advert names BOTH groups (counters stay honest)");
    check(acabVendorSlotGroup(acabVendorGroupMask(both)) == VG_AXON,
          "...but the packet slots once, biased to Axon");

    const uint8_t motoPcam = (uint8_t)(motoHit | pcamHit);
    check(acabVendorSlotGroup(acabVendorGroupMask(motoPcam)) == VG_MOTO,
          "Motorola+PCAM slots into Motorola (lowest group present, not Axon)");

    const uint8_t all = (uint8_t)(axonHit | motoHit | pcamHit);
    check(acabVendorGroupMask(all) == ((1u << VG_AXON) | (1u << VG_MOTO) | (1u << VG_PCAM)),
          "a three-way advert names all three groups");
    check(acabVendorSlotGroup(acabVendorGroupMask(all)) == VG_AXON,
          "...and the packet still slots exactly once");
}

// ---------------------------------------------------------------------------------------------
// IDENTIFIER SCAN OVER REAL ADVERT SHAPES
// ---------------------------------------------------------------------------------------------
static void scanRealAdverts() {
    printf("\n== identifier scan ==\n");
    uint8_t buf[64], mask = 0, sol = 0;
    size_t n;

    // The PCAM field shape (PCAM_ADV_HEX above, shared with the retired-rule section).
    n = fromHex(PCAM_ADV_HEX, buf, sizeof buf);
    check(n == PCAM_ADV_LEN, "PCAM fixture decodes to the expected length");
    acabVendorScanAdv(buf, n, &mask, &sol);
    int pcam = rowIndex(0, 0x087F);
    check(pcam >= 0 && mask == (uint8_t)(1u << pcam),
          "the PCAM advert confirms exactly the 0x087F row");
    check(sol == 0, "...and solicits nothing");
    check(acabVendorSlotGroup(acabVendorGroupMask(mask)) == VG_PCAM,
          "...and routes to VG_PCAM, not VG_MOTO");

    // A manufacturer structure carrying the TASER company ID 0x034D (little-endian 4D 03).
    n = fromHex("02010604FF4D0300", buf, sizeof buf);
    acabVendorScanAdv(buf, n, &mask, &sol);
    int axon = rowIndex(0, 0x034D);
    check(axon >= 0 && (mask & (1u << axon)) != 0,
          "a 0x034D manufacturer structure confirms the Axon company-ID row");

    // SOLICITATION IS NOT CONFIRMATION. AD 0x14 is a device asking FOR a service, so an Axon UUID
    // there must land in `solicit` and never in `mask` - otherwise a bystander's handset running
    // Axon's app is counted as Axon equipment, the exact failure this capture design avoids.
    n = fromHex("020106031481FC", buf, sizeof buf);    // AD 0x14, UUID 0xFC81 little-endian
    acabVendorScanAdv(buf, n, &mask, &sol);
    int axonSvc = rowIndex(1, 0xFC81);
    check(axonSvc >= 0 && sol == (uint8_t)(1u << axonSvc),
          "an Axon UUID in AD 0x14 sets ONLY the solicitation mask");
    check(mask == 0, "...and never the confirmation mask");

    // The same UUID in a complete-list (AD 0x03) IS the device saying what it is.
    n = fromHex("020106030381FC", buf, sizeof buf);
    acabVendorScanAdv(buf, n, &mask, &sol);
    check(axonSvc >= 0 && mask == (uint8_t)(1u << axonSvc),
          "the same UUID in AD 0x03 confirms instead");
    check(sol == 0, "...and solicits nothing");

    // An unrelated vendor must produce nothing at all.
    n = fromHex("02010604FF7500AA", buf, sizeof buf);  // Samsung company ID 0x0075
    acabVendorScanAdv(buf, n, &mask, &sol);
    check(mask == 0 && sol == 0, "an unrelated company ID (0x0075) produces no hit");

    // Truncated / empty input must not read past the buffer or invent a hit.
    acabVendorScanAdv(nullptr, 0, &mask, &sol);
    check(mask == 0 && sol == 0, "an empty advert produces no hit");
    n = fromHex("02010609FF7F08", buf, sizeof buf);    // length byte promises 9, only 3 present
    acabVendorScanAdv(buf, n, &mask, &sol);
    check(mask == 0 && sol == 0, "a truncated structure is not decoded as a hit");
}

// ---------------------------------------------------------------------------------------------
// PER-MAC RESERVATION
// ---------------------------------------------------------------------------------------------
static void reservation() {
    printf("\n== per-MAC reservation ==\n");

    // The PCAM table is eight slots. Distinct MACs beyond that get no row, and the overflow is
    // COUNTED rather than silent - that count is what says a table's rows are only a floor on the
    // distinct MACs that reached it, never a count of them (acabScannerVendorMacs in acab_scanner.h
    // owns that rule).
    AcabVendorRec rec[8];
    memset(rec, 0, sizeof rec);
    uint32_t full = 0;

    auto macFor = [](uint8_t i, uint8_t* out) {
        out[0] = 0xC0; out[1] = 0x00; out[2] = 0xFF; out[3] = 0xEE; out[4] = 0x00; out[5] = i;
    };

    uint8_t mac[6];
    bool allSlotted = true;
    for (uint8_t i = 0; i < 8; i++) {
        macFor(i, mac);
        AcabVendorRec* v = acabVendorFind(rec, 8, mac, 1000 + i, &full);
        if (!v) allSlotted = false;
    }
    check(allSlotted, "the first 8 distinct MACs each get a slot");
    check(full == 0, "...with no overflow counted");

    // A repeat of a MAC already holding a slot must return THAT slot, not consume another.
    macFor(3, mac);
    AcabVendorRec* again = acabVendorFind(rec, 8, mac, 5000, &full);
    check(again != nullptr && again == &rec[3], "a repeat sighting returns the existing slot");
    check(again != nullptr && again->firstMs == 1003,
          "...and keeps its original firstMs (the row is not reset)");
    check(full == 0, "...and counts no overflow");

    // The ninth DISTINCT MAC is where a table this size falls short: 19 devices carried 0x087F
    // on the 2026-09-04 drive, and against 8 slots 11 of them would get no aggregate row. That is
    // a projection, not a drive result - the build on that drive had no PCAM row, so nothing
    // overflowed. There is no eviction by design, so the ninth is refused rather than displacing
    // an earlier device.
    macFor(200, mac);
    AcabVendorRec* ninth = acabVendorFind(rec, 8, mac, 6000, &full);
    check(ninth == nullptr, "the 9th distinct MAC gets no slot (no eviction, by design)");
    check(full == 1, "...and the overflow is counted, not silent");

    // The table stays usable for the devices it already holds after it is full.
    macFor(5, mac);
    AcabVendorRec* held = acabVendorFind(rec, 8, mac, 7000, &full);
    check(held == &rec[5], "an already-slotted device still resolves after the table is full");
    check(full == 1, "...without counting a further overflow");

    // Repeated overflow keeps counting, and it counts REFUSED ADVERTS, not refused devices:
    // nothing remembers which MACs were turned away. Distinct MACs cannot tell those two apart,
    // so the same refused MAC is resolved twice more below and must add two. The scanner prints
    // this figure as `dropped=N`; read it as adverts.
    for (uint8_t i = 201; i < 205; i++) { macFor(i, mac); acabVendorFind(rec, 8, mac, 8000, &full); }
    check(full == 5, "every refused advert increments the overflow count");
    macFor(200, mac);
    acabVendorFind(rec, 8, mac, 9000, &full);
    acabVendorFind(rec, 8, mac, 9001, &full);
    check(full == 7, "the same refused MAC heard twice more adds two (adverts, not devices)");

    // THE LOOKUP IS PER TABLE, which is what makes routing per advert rather than per device:
    // acabVendorFind sees one table and one MAC and cannot know the MAC already holds a row in
    // another table. So a device whose packets route to two groups is a distinct MAC in both,
    // and the tally it built in the first table does not travel with it. Pinned because
    // vendor_capture.h states it (GROUP ROUTING, PER-MAC RESERVATION), and because the VendorTable
    // comment in acab_scanner.cpp once said the opposite ("A device carrying BOTH vendors'
    // identifiers lands in the Axon table"). These rows pin acabVendorFind only: a cross-table
    // lookup added inside it would turn them red, but the ingest site in acab_scanner.cpp is not
    // host-compiled, so one added there would not.
    //
    // The free `mo` rows are POISONED (every byte 0xA5, `used` false) rather than zeroed. In the
    // firmware a free slot is always zero, because the scanner's tables are zero-initialised file
    // statics and nothing in the scanner ever clears `used`, so a zeroed fixture passes the
    // fresh-row check even if acabVendorFind stops clearing the slot it hands out. That
    // regression matters the day a row can be freed and reused: stale `hits` would print
    // identifiers this MAC never sent on the scanner's `seen=` field. With the poison that
    // regression reads back n as 0xA5A5A5A5 and hits as 0xA5, and the check fails here.
    AcabVendorRec ax[2], mo[2];
    memset(ax, 0, sizeof ax);
    memset(mo, 0xA5, sizeof mo);
    for (auto& r : mo) r.used = false;
    uint32_t axFull = 0, moFull = 0;
    macFor(9, mac);
    AcabVendorRec* inAxon = acabVendorFind(ax, 2, mac, 100, &axFull);
    if (inAxon) { inAxon->n = 3; inAxon->hits = 0x01; }
    AcabVendorRec* inMoto = acabVendorFind(mo, 2, mac, 101, &moFull);
    check(inAxon != nullptr && inMoto != nullptr && inAxon != inMoto,
          "one MAC routed to two tables holds a row in EACH (per advert, not per device)");
    check(inMoto != nullptr && inMoto->n == 0 && inMoto->hits == 0 && inMoto->firstMs == 101,
          "...and the second row starts fresh: no stale slot bytes, no tally from the first table");
    check(axFull == 0 && moFull == 0,
          "...with no overflow counted in either table");

    // A fresh row starts at the sentinel RSSI so the first real sighting always wins, and with an
    // empty tally. Poisoned for the same reason as `mo` above: `best` and `firstMs` are assigned
    // explicitly, but `n` and `hits` read zero only because acabVendorFind clears the slot.
    memset(rec, 0xA5, sizeof rec);
    for (auto& r : rec) r.used = false;
    full = 0;
    macFor(1, mac);
    AcabVendorRec* fresh = acabVendorFind(rec, 8, mac, 42, &full);
    check(fresh != nullptr && fresh->best == -127, "a fresh row starts at best = -127");
    check(fresh != nullptr && fresh->n == 0 && fresh->hits == 0,
          "...with an empty tally and no identifiers, whatever the slot held");
    check(fresh != nullptr && fresh->firstMs == 42, "...and stamps the caller's clock");
}

// ---------------------------------------------------------------------------------------------
// PER-ROW EMIT DECISION
// ---------------------------------------------------------------------------------------------
static void emitDecision() {
    printf("\n== per-row emit decision ==\n");

    // THE DEFECT THIS PINS. The rule used to be time-only - first sighting, then one line per
    // window - while the ingest site ORed each advert's identifiers into the row before deciding.
    // So a row that gained an identifier inside the window printed it only if that MAC was heard
    // again after the window, and nothing dumps the tables at capture end: the co-occurrence this
    // capture build exists to find could sit in the firmware and never reach the log. The second
    // check below is the one that fails if the rule goes back to time-only.
    const uint32_t every = 5000;   // the scanner's VENDOR_LOG_EVERY_MS

    check(acabVendorShouldEmit(1, 0x00, 0x01, 1000, 0, every),
          "a first sighting always emits");
    check(acabVendorShouldEmit(4, 0x01, 0x03, 1200, 1000, every),
          "a new identifier bit emits inside the throttle window");
    check(!acabVendorShouldEmit(4, 0x03, 0x03, 1200, 1000, every),
          "...but a repeat advert that adds no identifier stays throttled");
    check(acabVendorShouldEmit(9, 0x03, 0x03, 6000, 1000, every),
          "an unchanged row prints again once the window has passed");
    check(!acabVendorShouldEmit(9, 0x03, 0x03, 5999, 1000, every),
          "...and not one millisecond before it");
    check(acabVendorShouldEmit(4, 0x01, 0x05, 1000, 1000, every),
          "a mask change in the same millisecond as the last line still emits");

    // The throttle is an unsigned subtraction so it survives the millis() wrap at 49.7 days, which
    // a capture left running would otherwise hit as either a silent row or a line per advert.
    check(acabVendorShouldEmit(7, 0x03, 0x03, 3000, 0xFFFFF000u, every),
          "the window still expires across the millis() wrap (7096 ms elapsed)");
    check(!acabVendorShouldEmit(7, 0x03, 0x03, 500, 0xFFFFF000u, every),
          "...and an unexpired window across the wrap is still throttled (4596 ms)");

    // THE BOUND THE HEADER CLAIMS, which is what keeps this off the hot path: `hits` only ever
    // gains bits, so mask-change lines are capped at one per identifier per row - eight on today's
    // table - for the whole boot, however long the device is followed.
    uint8_t hits = 0;
    int emits = 0;
    uint32_t stamp = 0;
    for (size_t k = 0; k < VENDOR_BLE_ID_N; k++) {
        const uint8_t before = hits;
        hits |= (uint8_t)(1u << k);
        const uint32_t now = 1000 + (uint32_t)k * 10;   // every step inside one 5 s window
        if (acabVendorShouldEmit((uint32_t)k + 1, before, hits, now, stamp, every)) {
            emits++;
            stamp = now;
        }
    }
    check(emits == (int)VENDOR_BLE_ID_N,
          "a row learning one identifier per advert emits once for each, and no more");
    int extra = 0;
    for (uint32_t i = 0; i < 100; i++)
        if (acabVendorShouldEmit(100 + i, hits, hits, 1100 + i, stamp, every)) extra++;
    check(extra == 0,
          "...then 100 repeats inside the window that add nothing emit nothing");
}

int main() {
    printf("vendor capture table (vendor_capture.h)\n");
    tableShape();
    theOldTagLetterRuleWouldHaveMisrouted();
    groupRouting();
    scanRealAdverts();
    reservation();
    emitDecision();
    printf("\n  %s (%d failures)\n\n", failures ? "FAILURES" : "all good", failures);
    return failures ? 1 : 0;
}
