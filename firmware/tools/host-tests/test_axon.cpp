// Host regression test for the body-cam classifier (axon_detect.cpp), covering BOTH entry points:
// axonClassifyBLE and the newer axonClassifyWiFi.
//
// WHY THIS EXISTS: the four detail strings this file emits ("Axon OUI", "BWC DEVICE",
// "Axon Bluetooth ID", "Utility BodyWorn") are a WIRE CONTRACT. Both apps resolve the body-cam
// vendor by EXACT string match, so any edit to one of them (a suffix, a case change, a space)
// silently degrades the detail screen instead of failing a build. That contract broke once already
// when a " on wifi" suffix was added to the WiFi path, so every assertion below compares the string
// VERBATIM rather than checking "contains Axon". The confidence tiers (90 tag / 85 name / 75 SIG ID /
// 75 BLE OUI / 70 Utility OUI / 65 WiFi) are consumed downstream too, for alert thresholds and sort
// order, so they are asserted as exact numbers.
//
// These tests lock in what the code does TODAY. Where behaviour looked questionable it is still
// asserted as-is and flagged with a CONCERN comment, never "corrected" here.
#include "axon_detect.h"
#include "axon_signatures.h"
#include <Preferences.h>   // wipeAll(): the stub stores for real now, so "no saved value" must be made true
#include <cstdio>
#include <cstring>
#include <vector>

// ---- stub for the one symbol axon_detect.cpp calls into another translation unit -----------
// Desert mode lives in desert_detect.cpp, which the harness never compiles. It is a real branch
// here (`if (!gEnabled.on && !desertIsEnabled()) return false;`), so unlike the glasses test this is
// a settable flag, not a hard false: the "off but Desert forces it on" case is tested below.
// (acabSanitizeAscii needs no stub: it is inline in acab_scanner.h, so this suite runs the
// real clamp.)
static bool gDesertOn = false;
bool desertIsEnabled() { return gDesertOn; }

// failures, chk_impl, the chk macro (and why it must stay a macro), and chkInt, which this suite
// uses for method / source / MAC-byte / table-size checks.
#include "host_check.h"

// ---- advert builders (BLE AD structures: [len][type][data...]) -----------------------------
static void addName(std::vector<uint8_t>& a, const char* s, uint8_t adType = 0x09) {
    size_t n = strlen(s);
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (size_t i = 0; i < n; i++) a.push_back((uint8_t)s[i]);
}
static void addNameRaw(std::vector<uint8_t>& a, const uint8_t* b, size_t n) {
    a.push_back((uint8_t)(1 + n)); a.push_back(0x09);
    for (size_t i = 0; i < n; i++) a.push_back(b[i]);
}
static void addMfg(std::vector<uint8_t>& a, uint16_t cid, const uint8_t* tail = nullptr, size_t tl = 0) {
    a.push_back((uint8_t)(1 + 2 + tl)); a.push_back(0xFF);
    a.push_back(cid & 0xFF); a.push_back(cid >> 8);
    for (size_t i = 0; i < tl; i++) a.push_back(tail[i]);
}
static void addMfgStr(std::vector<uint8_t>& a, uint16_t cid, const char* tail) {
    addMfg(a, cid, (const uint8_t*)tail, strlen(tail));
}
// Service data / 128-bit UUID AD. adType 0x21 is where the real 2026-06 field capture carried the
// tag; 0x16 / 0x07 are the other types parseAdv folds into the same svc buffer.
static void addSvcStr(std::vector<uint8_t>& a, uint8_t adType, const char* s) {
    size_t n = strlen(s);
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (size_t i = 0; i < n; i++) a.push_back((uint8_t)s[i]);
}
static void addSvcFill(std::vector<uint8_t>& a, uint8_t adType, uint8_t byte, uint8_t n) {
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (uint8_t i = 0; i < n; i++) a.push_back(byte);
}

// MACs. Every OUI in the Utility table and Axon's registry block starts with 0x00, so those are
// plainly public addresses; MAC_RANDOM has its locally-administered bit set.
//
// MAC_AXON_FIELD (D8:1F:65) needs its own note, because 0xD8 LOOKS like a random address and is
// not. BLE random-static addresses carry 11 in the top two bits, and 0xD8 is 1101_1000, so the
// prefix falls inside that range. What settles it is the LOCALLY-ADMINISTERED bit (0x02), which is
// CLEAR here: this is a globally-administered unicast address, i.e. a real allocated block, and
// the address TYPE field (not the bytes) is what tells a public address from a random one on air.
// The field evidence agrees: nine distinct MACs shared these exact three bytes across two captures
// six weeks apart in different cities, which no random-address generator produces. See the
// AXON_OUI_BWC_FIELD block in axon_signatures.h.
static const uint8_t MAC_AXON[6]      = {0x00,0x25,0xdf,0x11,0x22,0x33};   // Axon Enterprise
static const uint8_t MAC_AXON_LO[6]   = {0x00,0x25,0xde,0x11,0x22,0x33};   // neighbouring block
static const uint8_t MAC_AXON_HI[6]   = {0x00,0x25,0xe0,0x11,0x22,0x33};   // neighbouring block
static const uint8_t MAC_AXON_FIELD[6]= {0xd8,0x1f,0x65,0x04,0xa2,0x57};   // field-observed Axon block
static const uint8_t MAC_AXFIELD_LO[6]= {0xd8,0x1f,0x64,0x04,0xa2,0x57};   // neighbouring block
static const uint8_t MAC_AXFIELD_HI[6]= {0xd8,0x1f,0x66,0x04,0xa2,0x57};   // neighbouring block
static const uint8_t MAC_UTIL_A[6]    = {0x00,0x09,0xbc,0x0a,0x0b,0x0c};   // Utility Inc.
static const uint8_t MAC_UTIL_B[6]    = {0x00,0x16,0xed,0x0a,0x0b,0x0c};   // Utility Inc.
static const uint8_t MAC_UTIL_NEAR[6] = {0x00,0x16,0xee,0x0a,0x0b,0x0c};   // one byte off Utility
static const uint8_t MAC_RANDOM[6]    = {0x7a,0x11,0x22,0x33,0x44,0x55};   // BLE private address
static const uint8_t MAC_PHONE[6]     = {0x3c,0x2e,0xf9,0x01,0x02,0x03};   // in no table at all

// run() is split out from the chk() call on purpose: C++ leaves function-argument evaluation order
// unspecified, so passing run(...) and d.confidence as siblings would read the confidence of the
// PREVIOUS detection on a compiler that evaluates right to left. Call first, assert second.
static AcabDetection d;
static bool runBLE(const uint8_t mac[6], std::vector<uint8_t>& a) {
    memset(&d, 0, sizeof(d));
    return axonClassifyBLE(mac, a.data(), a.size(), -71, &d);
}
// 802.11 management frame: [fc0][fc1][dur x2][addr1 x6][addr2 x6][addr3 x6] = 24 bytes.
// fc0 0x80 is a beacon (type bits 00 = management), which is what the classifier accepts.
static std::vector<uint8_t> mgmtFrame(const uint8_t* addr2, const uint8_t* addr3, uint8_t fc0 = 0x80) {
    std::vector<uint8_t> f(24, 0x00);
    f[0] = fc0;
    memcpy(&f[10], addr2, 6);
    memcpy(&f[16], addr3, 6);
    return f;
}
static bool runWiFi(std::vector<uint8_t>& f) {
    memset(&d, 0, sizeof(d));
    return axonClassifyWiFi(f.data(), f.size(), -63, &d);
}

int main() {
    printf("\n=== body-cam classifier regression (axon_detect) ===\n");

    // -- defaults ----------------------------------------------------------------------------
    // The module ships ENABLED (field-validated 2026-06-17).
    printf("\n-- defaults --\n");
    chkInt("enabled by default", axonIsEnabled() ? 1 : 0, 1);
    // Lock the signature tables themselves. A silent edit here changes what ships.
    chkInt("Utility OUI table still has 2 blocks", (long)UTIL_BWC_OUI_COUNT, 2);
    chkInt("UTIL_BWC_OUI[0] is 00:09:bc", (UTIL_BWC_OUI[0][0]<<16)|(UTIL_BWC_OUI[0][1]<<8)|UTIL_BWC_OUI[0][2], 0x0009bc);
    chkInt("UTIL_BWC_OUI[1] is 00:16:ed", (UTIL_BWC_OUI[1][0]<<16)|(UTIL_BWC_OUI[1][1]<<8)|UTIL_BWC_OUI[1][2], 0x0016ed);
    chkInt("tag constant is exactly \"BWCDEVICE\"", strcmp(AXON_BWC_PAYLOAD, "BWCDEVICE"), 0);
    // Lock the two Axon OUI macros the same way. These are the values the shipped AXON_OUI table
    // is built from, so an edit to either changes what the board matches in the field.
    { const uint8_t reg[3] = AXON_OUI_REGISTERED;
      chkInt("AXON_OUI_REGISTERED is 00:25:df", (reg[0]<<16)|(reg[1]<<8)|reg[2], 0x0025df); }
    { const uint8_t fld[3] = AXON_OUI_BWC_FIELD;
      chkInt("AXON_OUI_BWC_FIELD is d8:1f:65", (fld[0]<<16)|(fld[1]<<8)|fld[2], 0xd81f65);
      chkInt("  ^ and its locally-administered bit is CLEAR (a public block, not a random addr)",
             fld[0] & 0x02, 0); }

    // -- BLE: the registry block (OUI 00:25:DF) ---------------------------------------------
    printf("\n-- BLE: Axon OUI 00:25:df --\n");
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_AXON, a);
      chk("OUI hit, empty advert (OUI needs no payload)", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ method is M_OUI", d.method, M_OUI);
      chkInt("  ^ source is SRC_BLE", d.src, SRC_BLE);
      chkInt("  ^ type is ACAB_AXON_BODYCAM", d.type, ACAB_AXON_BODYCAM);
      chkInt("  ^ rssi passed through", d.rssi, -71); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI 00:25:de -> NO hit", runBLE(MAC_AXON_LO, a), false); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI 00:25:e0 -> NO hit", runBLE(MAC_AXON_HI, a), false); }

    // -- BLE: the field-observed Axon block (OUI D8:1F:65) ----------------------------------
    // Added 2026-09-19 on nine distinct MACs carrying two independent Axon identifiers; the
    // provenance, and what is still unverified about it, are in axon_signatures.h.
    printf("\n-- BLE: Axon OUI d8:1f:65 (field-observed block) --\n");
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_AXON_FIELD, a);
      chk("field OUI hit, empty advert", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ method is M_OUI", d.method, M_OUI);
      chkInt("  ^ type is ACAB_AXON_BODYCAM", d.type, ACAB_AXON_BODYCAM); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI d8:1f:64 -> NO hit", runBLE(MAC_AXFIELD_LO, a), false); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI d8:1f:66 -> NO hit", runBLE(MAC_AXFIELD_HI, a), false); }
    // THE CASE THIS ENTRY EXISTS FOR, replayed from the real advert. d8:1f:65:04:a2:57 in
    // aug-9-flock-o.log sends no BWCDEVICE tag - it carries Axon's own SIG service UUID 0xFE6B
    // (AD 0x16) with ASCII "D01AT522D" - and so scored conf 0 "hardware OUI" before this block
    // landed. Byte-for-byte the service data from that capture. Since 2026-10-20 the SIG-ID rule
    // claims it first, so the detail names the stronger evidence; the empty-advert case above is
    // what still proves the OUI on its own.
    { std::vector<uint8_t> a;
      static const uint8_t sd[] = {0x6b,0xfe,0x02,0x02,0xa3,0x1e,0x95,0xc4,0x70,0x98,0xbd,0x76,
                                   0x96,0x02,0x00,0x00,0x44,0x30,0x31,0x41,0x54,0x35,0x32,0x32,0x44};
      a.push_back((uint8_t)(1 + sizeof(sd))); a.push_back(0x16);
      for (size_t i = 0; i < sizeof(sd); i++) a.push_back(sd[i]);
      bool h = runBLE(MAC_AXON_FIELD, a);
      chk("real FE6B advert on the field block -> SIG ID beats the OUI", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID");
      chkInt("  ^ method is M_SERVICE_DATA, not M_OUI", d.method, M_SERVICE_DATA); }
    // ...and the same advert on a MAC in no table now classifies too: the SIG number rides in the
    // payload, so it needs no OUI. Before 2026-10-20 this case asserted NO hit.
    { std::vector<uint8_t> a;
      static const uint8_t sd[] = {0x6b,0xfe,0x02,0x02,0xa3,0x1e,0x95,0xc4,0x70,0x98,0xbd,0x76,
                                   0x96,0x02,0x00,0x00,0x44,0x30,0x31,0x41,0x54,0x35,0x32,0x32,0x44};
      a.push_back((uint8_t)(1 + sizeof(sd))); a.push_back(0x16);
      for (size_t i = 0; i < sizeof(sd); i++) a.push_back(sd[i]);
      bool h = runBLE(MAC_PHONE, a);
      chk("  ^ same advert on a foreign MAC -> hit on the SIG ID alone", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    { std::vector<uint8_t> a; addName(a, "AXON BODY 3");
      // CONCERN (asserted as-is): the advertised name is NOT a match source in the shipped
      // signature, so an Axon-branded name on a foreign MAC is invisible. Deliberate: names are
      // spoofable and the OUI is the field-validated signal.
      chk("\"AXON BODY 3\" name on a foreign MAC -> NO hit", runBLE(MAC_PHONE, a), false); }

    // -- BLE: the BWCDEVICE service-data tag -------------------------------------------------
    printf("\n-- BLE: BWCDEVICE service-data tag --\n");
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_AXON, a);
      chk("tag in AD 0x21 -> \"BWC DEVICE\" at 90", h, true, d.confidence, 90, d.detail, "BWC DEVICE");
      chkInt("  ^ method is M_SERVICE_DATA, not M_OUI", d.method, M_SERVICE_DATA); }
    // The real capture: the tag rode inside a little-endian 128-bit UUID, so it only reads
    // "AXJANUSBWCDEVICE" when the bytes are reversed. This is the exact shape seen in the field.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "ECIVEDCWBSUNAJXA");
      bool h = runBLE(MAC_AXON, a);
      chk("tag reversed (little-endian UUID) -> hit", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x16, "xxBWCDEVICExx");
      chk("tag in 16-bit service data (AD 0x16)", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x07, "bwcdevice");
      chk("tag match is case-insensitive", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    // The tag survives MAC randomization, which is the whole reason it is a standalone match.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_RANDOM, a);
      chk("tag on a RANDOM MAC -> still hits at 90", h, true, d.confidence, 90, d.detail, "BWC DEVICE");
      chkInt("  ^ randomAddr flagged", d.randomAddr ? 1 : 0, 1);
      AcabDetection dd = d; acabApplyDurability(&dd);
      chkInt("  ^ durability leaves 90 (not an OUI match)", dd.confidence, 90); }
    // Tag beats OUI when both are present: highest-confidence, MAC-independent evidence wins.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE"); addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_AXON, a);
      chk("tag + OUI + Utility name -> tag wins", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    // Near-misses on the tag. Note the emitted detail has a space ("BWC DEVICE") but the matched
    // constant does NOT ("BWCDEVICE"); a spaced payload must not match.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWC DEVICE");
      chk("\"BWC DEVICE\" (spaced) in svc data -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVIC");
      chk("truncated \"BWCDEVIC\" -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Only 0x06/0x07/0x16/0x20/0x21 are folded into the svc buffer. The tag inside manufacturer
    // data is NOT a service-data tag and must not match.
    { std::vector<uint8_t> a; addMfgStr(a, 0x004C, "BWCDEVICE");
      chk("tag inside mfg data (AD 0xFF) -> NO hit", runBLE(MAC_PHONE, a), false); }

    // -- BLE: Axon's Bluetooth SIG numbers (0xFE6B service data, 0x034D company ID) -----------
    // Added 2026-10-20 on own field capture; the counts and what they do and do not prove are on
    // AXON_SIG_* in axon_signatures.h. Both are MAC-independent, so they must hit on addresses that
    // carry no OUI at all, and they must hit ONLY as the AD type they were captured in.
    printf("\n-- BLE: Axon SIG numbers (0xFE6B / 0x034D) --\n");
    chkInt("AXON_SIG_SVC_UUID is 0xFE6B", AXON_SIG_SVC_UUID, 0xFE6B);
    chkInt("AXON_SIG_COMPANY_ID is 0x034D", AXON_SIG_COMPANY_ID, 0x034D);
    // Synthetic addresses with the real address types. 0x20 = top bits 00, a BLE non-resolvable
    // private address; 0xF4 = top bits 11, random static. Neither sets the 0x02 bit, so neither is
    // flagged random by the bytes alone, exactly like the two real devices.
    static const uint8_t MAC_NRPA[6]    = {0x20,0x11,0x22,0x33,0x44,0x55};
    static const uint8_t MAC_RSTATIC[6] = {0xf4,0x11,0x22,0x33,0x44,0x55};
    // sep252026.log: the "X7" device on a private address. Byte-for-byte its service data.
    static const uint8_t X7_SD[] = {0x6b,0xfe,0x02,0x01,0x79,0x98,0xc2,0xd9,0xca,0x60,0xbc,0x61,0x9c,
                                    0x04,0x00,0x00,0x58,0x37,0x30,0x35,0x34,0x32,0x43,0x54,0x4e};
    auto addAd = [](std::vector<uint8_t>& a, uint8_t type, const uint8_t* b, size_t n) {
        a.push_back((uint8_t)(1 + n)); a.push_back(type);
        for (size_t i = 0; i < n; i++) a.push_back(b[i]);
    };
    { std::vector<uint8_t> a; static const uint8_t fl[] = {0x06}; addAd(a, 0x01, fl, 1);
      addAd(a, 0x16, X7_SD, sizeof(X7_SD));
      bool h = runBLE(MAC_NRPA, a);
      chk("real FE6B advert on a private address -> \"Axon Bluetooth ID\" at 75", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID");
      chkInt("  ^ method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);
      chkInt("  ^ type is ACAB_AXON_BODYCAM", d.type, ACAB_AXON_BODYCAM);
      chkInt("  ^ source is SRC_BLE", d.src, SRC_BLE); }
    // aug-9-drive.log: the 0x034D device off the Axon blocks. Its payload starts with the device's
    // own address (replaced here by the synthetic one; every other byte is as captured), not the
    // serial shape AXON_SIG_CID_SERIAL_LEN asks for, so since 2026-10-21 it does NOT match.
    { std::vector<uint8_t> a; static const uint8_t fl[] = {0x02}; addAd(a, 0x01, fl, 1);
      static const uint8_t ul[] = {0xf0,0x0a}; addAd(a, 0x03, ul, 2);
      static const uint8_t tail[] = {0xf4,0x11,0x22,0x33,0x44,0x55,0x02,0x01,0x0c,0x01,0x01,0x01};
      addMfg(a, 0x034D, tail, sizeof(tail));
      chk("real off-block 0x034D advert, own address as payload -> NO hit", runBLE(MAC_RSTATIC, a),
          false); }
    // drive_home_9-4.log: the 0x034D device on 00:25:DF. Byte-for-byte its whole advert: flags, then
    // manufacturer data 0x02 + the serial "X870054FW" + 14 more bytes.
    static const uint8_t X8_TAIL[] = {0x02,'X','8','7','0','0','5','4','F','W',0x01,0x02,0x10,0x1b,
                                      0x73,0x00,0x04,0x03,0x01,0x20,0x00,0x00,0x00,0x00};
    { std::vector<uint8_t> a; static const uint8_t fl[] = {0x06}; addAd(a, 0x01, fl, 1);
      addMfg(a, 0x034D, X8_TAIL, sizeof(X8_TAIL));
      static const uint8_t real[] = {0x02,0x01,0x06,0x1b,0xff,0x4d,0x03,0x02,0x58,0x38,0x37,0x30,
                                     0x30,0x35,0x34,0x46,0x57,0x01,0x02,0x10,0x1b,0x73,0x00,0x04,
                                     0x03,0x01,0x20,0x00,0x00,0x00,0x00};
      chkInt("X8 fixture is the captured advert byte for byte",
             a.size() == sizeof(real) && memcmp(a.data(), real, sizeof(real)) == 0 ? 1 : 0, 1);
      bool h = runBLE(MAC_AXON, a);
      chk("real X8 0x034D advert on 00:25:DF -> \"Axon Bluetooth ID\" at 75", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID");
      chkInt("  ^ method is M_MFG_ID, not M_OUI", d.method, M_MFG_ID); }
    { std::vector<uint8_t> a; addMfg(a, 0x034D, X8_TAIL, sizeof(X8_TAIL));
      bool h = runBLE(MAC_RSTATIC, a);
      chk("same X8 payload on a random-static address -> hit at 75", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    // The shape, edge by edge, off the Axon blocks (so no OUI can rescue a miss). Each case changes
    // the X8 payload in one place (one byte, its length, or the serial's characters).
    auto cidHits = [&](std::vector<uint8_t> tail) {
        std::vector<uint8_t> a; addMfg(a, 0x034D, tail.data(), tail.size());
        return runBLE(MAC_RSTATIC, a);
    };
    const std::vector<uint8_t> X8(X8_TAIL, X8_TAIL + sizeof(X8_TAIL));
    { auto t = X8; t[0] = 0x01;
      chk("0x034D, first payload byte 0x01 not 0x02 -> NO hit", cidHits(t), false); }
    { auto t = X8; t[0] = 0x03;
      chk("0x034D, first payload byte 0x03 not 0x02 -> NO hit", cidHits(t), false); }
    { auto t = X8; t[1] = 'x';
      chk("0x034D, lowercase letter in the serial -> NO hit", cidHits(t), false); }
    { auto t = X8; t[AXON_SIG_CID_SERIAL_LEN] = '.';
      chk("0x034D, last serial character not alphanumeric -> NO hit", cidHits(t), false); }
    { auto t = X8; t[AXON_SIG_CID_SERIAL_LEN + 1] = '.';
      bool h = cidHits(t);
      chk("0x034D, the byte after the serial is free -> hit", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    { std::vector<uint8_t> t(X8.begin(), X8.begin() + 1 + AXON_SIG_CID_SERIAL_LEN);
      bool h = cidHits(t);
      chk("0x034D, exactly 0x02 + serial (minimum length) -> hit", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    { std::vector<uint8_t> t(X8.begin(), X8.begin() + AXON_SIG_CID_SERIAL_LEN);
      chk("0x034D, serial one character short -> NO hit", cidHits(t), false); }
    // The same short AD with an alphanumeric byte right after it, so a length guard that is one
    // byte loose reads 'W' and fails here even without the sanitizer.
    { std::vector<uint8_t> t(X8.begin(), X8.begin() + AXON_SIG_CID_SERIAL_LEN);
      std::vector<uint8_t> a; addMfg(a, 0x034D, t.data(), t.size()); a.push_back('W');
      chk("0x034D, serial one short, next byte 'W' -> NO hit", runBLE(MAC_RSTATIC, a), false); }
    { auto t = X8; const uint8_t edge[] = {'0','9','A','Z','0','9','A','Z','0'};
      for (size_t k = 0; k < sizeof(edge); k++) t[1 + k] = edge[k];
      bool h = cidHits(t);
      chk("0x034D, serial of the range edges 0 9 A Z -> hit", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    for (uint8_t bad : {(uint8_t)'/', (uint8_t)':', (uint8_t)'@', (uint8_t)'['}) {
        auto t = X8; t[1] = bad;
        char label[64];
        snprintf(label, sizeof(label), "0x034D, serial character '%c' (just outside a range) -> NO hit",
                 (char)bad);
        chk(label, cidHits(t), false);
    }
    // On the Axon blocks the OUI path still reports a 0x034D device whose payload is not
    // serial-shaped, at the same 75, only with the OUI detail. Full-length payload (the off-block
    // device's, as captured apart from its address), so the shape check itself is what refuses it.
    { std::vector<uint8_t> a;
      static const uint8_t tail[] = {0xf4,0x11,0x22,0x33,0x44,0x55,0x02,0x01,0x0c,0x01,0x01,0x01};
      addMfg(a, 0x034D, tail, sizeof(tail));
      bool h = runBLE(MAC_AXON, a);
      chk("0x034D without the shape on 00:25:DF -> \"Axon OUI\" at 75", h, true,
          d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ method is M_OUI", d.method, M_OUI); }
    // A payload is required: the bare identifier is the cheapest thing a spoofer can send.
    { std::vector<uint8_t> a; static const uint8_t sd[] = {0x6b,0xfe}; addAd(a, 0x16, sd, 2);
      chk("FE6B service data with NO payload -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x034D);
      chk("0x034D manufacturer data with NO payload -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Only the AD type it was captured in counts. A 16-bit UUID LIST entry is not service data.
    { std::vector<uint8_t> a; static const uint8_t ul[] = {0x6b,0xfe}; addAd(a, 0x03, ul, 2);
      chk("FE6B in a UUID list (AD 0x03) -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Byte order: the UUID is little-endian on the wire, so FE 6B is a different number.
    { std::vector<uint8_t> a; static const uint8_t sd[] = {0xfe,0x6b,0x02,0x01,0x58,0x37};
      addAd(a, 0x16, sd, sizeof(sd));
      chk("FE6B written big-endian -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Neighbours. 0xFE6C is ALSO a TASER number but has no sighting, so it stays capture-only.
    { std::vector<uint8_t> a; static const uint8_t sd[] = {0x6a,0xfe,0x02,0x01,0x58,0x37};
      addAd(a, 0x16, sd, sizeof(sd));
      chk("service data 0xFE6A -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; static const uint8_t sd[] = {0x6c,0xfe,0x02,0x01,0x58,0x37};
      addAd(a, 0x16, sd, sizeof(sd));
      chk("service data 0xFE6C (unseen TASER UUID) -> NO hit", runBLE(MAC_PHONE, a), false); }
    // The neighbours carry the real X8 payload, so the company ID is the only thing that differs.
    { std::vector<uint8_t> a; addMfg(a, 0x034C, X8_TAIL, sizeof(X8_TAIL));
      chk("company ID 0x034C -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x034E, X8_TAIL, sizeof(X8_TAIL));
      chk("company ID 0x034E -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x044D, X8_TAIL, sizeof(X8_TAIL));
      chk("company ID 0x044D (high byte differs) -> NO hit", runBLE(MAC_PHONE, a), false); }
    // The same two bytes as a SERVICE DATA UUID are not the company ID, and the reverse.
    { std::vector<uint8_t> a; static const uint8_t sd[] = {0x4d,0x03,0x02,0x01}; addAd(a, 0x16, sd, 4);
      chk("0x034D as a service-data UUID -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0xFE6B, X8_TAIL, sizeof(X8_TAIL));
      chk("0xFE6B as a company ID -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Ranking. The tag outranks the SIG number; the SIG number outranks both OUI paths.
    { std::vector<uint8_t> a; addAd(a, 0x16, X7_SD, sizeof(X7_SD)); addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_PHONE, a);
      chk("SIG ID + BWCDEVICE tag -> tag wins at 90", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addMfg(a, 0x034D, X8_TAIL, sizeof(X8_TAIL));
      bool h = runBLE(MAC_AXON, a);
      chk("0x034D on the Axon OUI -> SIG ID names it", h, true, d.confidence, 75, d.detail, "Axon Bluetooth ID");
      chkInt("  ^ method is M_MFG_ID, not M_OUI", d.method, M_MFG_ID); }
    { std::vector<uint8_t> a; addAd(a, 0x16, X7_SD, sizeof(X7_SD)); addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_UTIL_A, a);
      chk("SIG ID + Utility name on a Utility OUI -> Axon SIG ID wins", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    // Read from the AD itself, so a full svc buffer cannot hide it (the tag CAN be pushed out; see
    // the adversarial section).
    { std::vector<uint8_t> a; addSvcFill(a, 0x21, 'Z', 48); addAd(a, 0x16, X7_SD, sizeof(X7_SD));
      bool h = runBLE(MAC_PHONE, a);
      chk("FE6B after a full 48-byte svc buffer -> still hits", h, true,
          d.confidence, 75, d.detail, "Axon Bluetooth ID"); }
    // A random MAC keeps the 75: durability only discounts OUI matches.
    { std::vector<uint8_t> a; addAd(a, 0x16, X7_SD, sizeof(X7_SD));
      bool h = runBLE(MAC_RANDOM, a);
      chk("FE6B on a locally-administered MAC -> hit", h, true, d.confidence, 75, d.detail, "Axon Bluetooth ID");
      chkInt("  ^ randomAddr flagged", d.randomAddr ? 1 : 0, 1);
      AcabDetection dd = d; acabApplyDurability(&dd);
      chkInt("  ^ durability leaves 75 (not an OUI match)", dd.confidence, 75); }

    // -- BLE: Utility Inc. "BodyWorn" -------------------------------------------------------
    printf("\n-- BLE: Utility BodyWorn --\n");
    { std::vector<uint8_t> a; addName(a, "BodyWorn Remote");
      bool h = runBLE(MAC_PHONE, a);
      chk("name \"BodyWorn Remote\" -> 85, M_NAME", h, true, d.confidence, 85, d.detail, "Utility BodyWorn");
      chkInt("  ^ method is M_NAME", d.method, M_NAME);
      chkInt("  ^ advertised name copied out", strcmp(d.name, "BodyWorn Remote"), 0); }
    { std::vector<uint8_t> a; addName(a, "unit 4 bodyworn remote", 0x08);
      chk("name match is case-insensitive + substring", runBLE(MAC_PHONE, a), true, d.confidence, 85, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> a; addName(a, "BodyWorn");
      chk("\"BodyWorn\" alone (no \" Remote\") -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_UTIL_A, a);
      chk("Utility OUI 00:09:bc -> 70, weaker than name", h, true, d.confidence, 70, d.detail, "Utility BodyWorn");
      chkInt("  ^ method is M_OUI", d.method, M_OUI); }
    { std::vector<uint8_t> a;
      chk("Utility OUI 00:16:ed -> 70", runBLE(MAC_UTIL_B, a), true, d.confidence, 70, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> a;
      chk("near-miss OUI 00:16:ee -> NO hit", runBLE(MAC_UTIL_NEAR, a), false); }
    // Axon is checked before Utility, so a device matching both is attributed to Axon.
    { std::vector<uint8_t> a; addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_AXON, a);
      chk("Axon OUI + Utility name -> \"Axon OUI\" wins", h, true, d.confidence, 75, d.detail, "Axon OUI"); }
    // Names are sanitized to printable ASCII on ingest, BEFORE matching. A control byte inside the
    // name therefore breaks the match rather than smuggling raw bytes into the detection JSON.
    { std::vector<uint8_t> a;
      const uint8_t raw[] = {'B','o','d','y',0x01,'W','o','r','n',' ','R','e','m','o','t','e'};
      addNameRaw(a, raw, sizeof(raw));
      chk("control byte inside the name -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a;
      const uint8_t raw[] = {'A',0x01,'B'};
      addNameRaw(a, raw, sizeof(raw));
      bool h = runBLE(MAC_AXON, a);
      chk("name sanitized to \"A.B\" on an Axon OUI hit", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ out->name is \"A.B\"", strcmp(d.name, "A.B"), 0); }
    // Only the FIRST name AD is parsed, so a decoy name in front of the real one suppresses the
    // match. Locked in as-is: first-wins is what keeps a crafted advert from stacking claims.
    { std::vector<uint8_t> a; addName(a, "decoy"); addName(a, UTIL_BWC_NAME);
      chk("second name AD ignored (first wins)", runBLE(MAC_PHONE, a), false); }

    // -- the enable toggle + Desert override -------------------------------------------------
    printf("\n-- toggle + Desert override --\n");
    axonSetEnabled(false);
    chkInt("axonIsEnabled() false after setEnabled(false)", axonIsEnabled() ? 1 : 0, 0);
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      chk("disabled: even a tagged Axon -> NO hit", runBLE(MAC_AXON, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x034D, X8_TAIL, sizeof(X8_TAIL));
      chk("disabled: the SIG ID path is off too", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      chk("disabled: WiFi path is off too", runWiFi(f), false); }
    gDesertOn = true;
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_AXON, a);
      chk("disabled + Desert on -> classifies anyway", h, true, d.confidence, 75, d.detail, "Axon OUI"); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      chk("disabled + Desert on -> WiFi classifies too", runWiFi(f), true, d.confidence, 65, d.detail, "Axon OUI"); }
    gDesertOn = false;
    { std::vector<uint8_t> a;
      chk("Desert back off -> silent again", runBLE(MAC_AXON, a), false); }
    // NVS restore, i.e. what setup() does after a power cycle. Preferences::wipeAll() is what
    // MAKES "no saved value" true, and it has to be explicit: the host stub used to discard every
    // write, so this block asserted the default branch by accident rather than by construction.
    // Now that the stub really stores, the axonSetEnabled(false) calls above genuinely persist and
    // a restore reads THAT back instead of the default the case name promises.
    Preferences::wipeAll();
    axonRestoreEnabled(true);
    chkInt("restoreEnabled(true) with no saved value -> on", axonIsEnabled() ? 1 : 0, 1);
    Preferences::wipeAll();
    axonRestoreEnabled(false);
    chkInt("restoreEnabled(false) with no saved value -> off", axonIsEnabled() ? 1 : 0, 0);
    // The other branch, which nothing could observe before: a PERSISTED value beats the
    // compiled-in default. That is the property a deployed board depends on across a brownout,
    // and until the stub stored anything it was untested on every detector in the tree.
    // NOTE the toggle-through: axonSetEnabled early-returns when the value is unchanged, so
    // calling it with the value the flag ALREADY holds writes nothing. After a wipeAll the in-RAM
    // state and NVS have diverged, and only a real transition re-syncs them. Getting this wrong is
    // how the first draft of these two cases asserted the opposite of the truth.
    axonSetEnabled(true); axonSetEnabled(false);          // ends false, and false is now SAVED
    axonRestoreEnabled(true);
    chkInt("restoreEnabled(true) with false SAVED -> stays off", axonIsEnabled() ? 1 : 0, 0);
    axonSetEnabled(true);                                 // transition, so true is SAVED
    axonRestoreEnabled(false);
    chkInt("restoreEnabled(false) with true SAVED -> stays on", axonIsEnabled() ? 1 : 0, 1);
    // Re-enable EXPLICITLY for the WiFi and adversarial cases below. This used to be a bare
    // axonRestoreEnabled(true), which only produced "enabled" because writes vanished; with real
    // storage it reads back whatever was last persisted and silently disables every case after
    // it, which is how 22 assertions failed at once the first time the stub was fixed.
    axonSetEnabled(true);

    // -- WiFi entry point --------------------------------------------------------------------
    printf("\n-- WiFi (802.11 management frames) --\n");
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      bool h = runWiFi(f);
      // 65, NOT the BLE tier's 75: the OUI read is as reliable, but the type claim is weaker and
      // has never been confirmed by a capture in this repo.
      chk("Axon OUI in addr2 -> 65, \"Axon OUI\"", h, true, d.confidence, 65, d.detail, "Axon OUI");
      chkInt("  ^ source is SRC_WIFI", d.src, SRC_WIFI);
      chkInt("  ^ method is M_OUI", d.method, M_OUI);
      chkInt("  ^ reports the transmitter MAC", memcmp(d.mac, MAC_AXON, 6), 0); }
    // THE REGRESSION THIS FILE EXISTS FOR: a " on wifi" suffix was once appended here, which the
    // apps could not match, so the vendor silently vanished from the detail screen. Exact string.
    chkInt("no \" on wifi\" suffix on the WiFi detail", strcmp(d.detail, "Axon OUI"), 0);
    { std::vector<uint8_t> f = mgmtFrame(MAC_PHONE, MAC_AXON);
      bool h = runWiFi(f);
      chk("Axon OUI in addr3 (BSSID) -> hit", h, true, d.confidence, 65, d.detail, "Axon OUI");
      chkInt("  ^ reports the BSSID it matched", memcmp(d.mac, MAC_AXON, 6), 0); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_UTIL_A, MAC_PHONE);
      bool h = runWiFi(f);
      // Attributing Utility hardware to a competitor in the string the user reads was a real bug.
      chk("Utility OUI on WiFi -> \"Utility BodyWorn\"", h, true, d.confidence, 65, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_UTIL_B, MAC_AXON);
      bool h = runWiFi(f);
      chk("addr2 Utility beats addr3 Axon (addr2 first)", h, true, d.confidence, 65, d.detail, "Utility BodyWorn");
      chkInt("  ^ reports addr2, not the BSSID", memcmp(d.mac, MAC_UTIL_B, 6), 0); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON_HI, MAC_UTIL_NEAR);
      chk("near-miss OUIs in both address fields -> none", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE, 0x08);   // data frame
      chk("data frame (type 10) -> rejected, mgmt only", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE, 0xB4);   // control frame (RTS)
      chk("control frame (type 01) -> rejected", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE); f.resize(23);
      chk("23-byte runt frame -> rejected before addr2", runWiFi(f), false); }
    { std::vector<uint8_t> f;
      chk("zero-length frame -> no hit", runWiFi(f), false); }
    chkInt("null frame pointer -> no hit", axonClassifyWiFi(nullptr, 64, -50, &d) ? 1 : 0, 0);

    // -- adversarial adverts -------------------------------------------------------------------
    printf("\n-- adversarial adverts --\n");
    { std::vector<uint8_t> a;
      chk("empty advert on an unknown MAC -> no hit", runBLE(MAC_PHONE, a), false); }
    chkInt("null advert pointer -> no hit", axonClassifyBLE(MAC_PHONE, nullptr, 0, -60, &d) ? 1 : 0, 0);
    { // length field claims 200 bytes in a 12-byte buffer: the parser must bail, not walk off it.
      std::vector<uint8_t> a; a.push_back(200); a.push_back(0x21);
      const char* s = "BWCDEVICE"; for (int i = 0; i < 9; i++) a.push_back((uint8_t)s[i]);
      chk("length overruns buffer -> parse bails, no hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; a.push_back(0); a.push_back(0x21); addSvcStr(a, 0x21, "BWCDEVICE");
      chk("zero-length AD stops the walk (tag after it)", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; a.push_back(4);   // dangling length byte, no type, no data
      chk("truncated AD header (length byte only)", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE"); a.push_back(9);
      chk("valid tag then a dangling length byte", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; a.push_back(1); a.push_back(0xFF);   // mfg AD with 0 data bytes
      chk("mfg AD too short for a company id -> ignored", runBLE(MAC_PHONE, a), false); }
    { // The svc buffer is 48 bytes; anything past it is dropped, so a late tag is missed. Harmless
      // in practice (a legacy advert is 31 bytes total) but this is the documented edge.
      std::vector<uint8_t> a; addSvcFill(a, 0x16, 'Z', 47); addSvcStr(a, 0x16, "BWCDEVICE");
      chk("tag pushed past the 48-byte svc buffer -> lost", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcFill(a, 0x16, 'Z', 30); addSvcStr(a, 0x16, "BWCDEVICE");
      chk("tag still inside the 48-byte svc buffer -> hit", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { // Oversized name: sanitize clamps to the 40-byte field instead of overflowing it.
      std::vector<uint8_t> a; std::vector<uint8_t> raw(60, 'A');
      addNameRaw(a, raw.data(), raw.size());
      bool h = runBLE(MAC_AXON, a);
      chk("60-byte name on an Axon OUI hit", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ name clamped to 39 chars", (long)strlen(d.name), 39); }
    { std::vector<uint8_t> a; addMfgStr(a, 0x004C, "iPhone");
      chk("ordinary Apple advert -> no hit", runBLE(MAC_PHONE, a), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
