// Host regression test for the network-camera classifier: 59 branded IP-camera vendor OUIs matched
// off an 802.11 source MAC.
//
// WHY THIS FILE EXISTS. Three separate contracts run through netcam_detect.cpp, and none of them is
// checked by the compiler:
//   1. THE DETAIL STRING. Both apps parse "<Vendor> on wifi" and split on the " on wifi" suffix to
//      show the maker. Change the format string, drop the space, capitalise the "W", and the board
//      still detects the camera while the app shows a blank or garbled vendor. "Anker/eufy" keeps
//      its slash on purpose (see netcam_signatures.h): the block is Fantasia Trading's whole
//      catalogue, so the slash is the ambiguity being handed to the user, NOT a typo to clean up.
//   2. THE CONFIDENCE TIER. 65 registry-only vs 75 field-validated. The apps sort and colour by it.
//   3. THE OPT-IN. Default OFF is the zero-cost-when-off promise. A regression that defaults it ON
//      widens the WiFi promiscuous filter to DATA frames on every board that boots.
// Every assertion below locks in what the code does TODAY. Where behaviour looked surprising it is
// still asserted as-is, with the surprise written down next to it rather than "fixed" in the test.
#include "netcam_detect.h"
#include "netcam_signatures.h"
#include <cstdio>
#include <cstring>
#include <vector>

// The classifier's ONE cross-translation-unit call. netcamSetEnabled() asks the scanner to widen
// the promiscuous filter to DATA frames when it turns on and narrow back to MGMT-only when it turns
// off; acab_scanner.cpp is not part of this build, so the definition lives here exactly as
// test_glasses.cpp defines desertIsEnabled(). Counting the calls is deliberate: "the toggle
// refreshed the filter" and "a redundant set did NOT" are the two halves of the zero-cost promise,
// and both are otherwise invisible from outside the module.
static int gFilterRefreshes = 0;
void acabScannerRefreshWifiFilter() { gFilterRefreshes++; }

static int failures = 0;
static void chk_impl(const char* name, bool got, bool wantHit,
                int gotConf = -1, int wantConf = -1, const char* gotDetail = "", const char* wantDetail = nullptr) {
    bool ok = (got == wantHit);
    if (ok && wantHit && wantConf >= 0) ok = (gotConf == wantConf);
    if (ok && wantHit && wantDetail)    ok = (strcmp(gotDetail, wantDetail) == 0);
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got hit=%d conf=%d detail=\"%s\"", got, gotConf, gotDetail); failures++; }
    printf("\n");
}
// For facts that are not a classify() call: toggle state, table invariants, copied fields.
static void chkBool_impl(const char* name, bool ok, const char* note = "") {
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   %s", note); failures++; }
    printf("\n");
}

// ---- ARGUMENT-EVALUATION SEQUENCING (do not remove) ------------------------------------------
// Every assertion below is written as
//     chk("name", classify(..., &d), true, d.confidence, 90, d.detail, "...");
// so the call that FILLS `d` and the reads of `d` are arguments to the SAME call. C++ leaves the
// evaluation order of function arguments UNSPECIFIED. Clang evaluates left to right, so the
// classifier runs before the reads and every assertion sees fresh values; GCC evaluates right to
// left, so it reads `d` BEFORE the classifier fills it - yielding the PREVIOUS test's values, and
// uninitialised stack on the first assertion (that is where the impossible `conf=153` came from).
// The suite therefore passed on macOS and failed in CI, on identical source.
//
// These macros complete the classifier call in a statement of its own before any argument to the
// reporting function is evaluated, so correctness no longer depends on the compiler. Keep the
// assertions in their current one-line form; the macro is what makes that form safe.
#define chk(name, hitexpr, ...) do { const bool acab_hit_ = (hitexpr); chk_impl((name), acab_hit_, ##__VA_ARGS__); } while (0)
#define chkBool(name, okexpr, ...) do { const bool acab_ok_ = (okexpr); chkBool_impl((name), acab_ok_, ##__VA_ARGS__); } while (0)
static void chkStr(const char* name, const char* got, const char* want) {
    bool ok = got && strcmp(got, want) == 0;
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got \"%s\" want \"%s\"", got ? got : "(null)", want); failures++; }
    printf("\n");
}

// ---- 802.11 frame builders -------------------------------------------------------------------
// The classifier reads exactly two things: frame[1] (the ToDS/FromDS bits) and the 6 bytes at the
// source-address offset those bits select. Everything else is padding, so the padding is 0x11:
// a well-formed PUBLIC OUI shape (locally-administered bit clear) that is not in the camera table.
// That matters. Padding of 0xAA or 0xFF would be rejected by the randomized-MAC gate, which would
// silently hide an off-by-one that read the wrong offset. 0x11 lets a wrong read fail loudly.
static std::vector<uint8_t> frame(size_t len, uint8_t fc1) {
    std::vector<uint8_t> f(len, 0x11);
    if (len > 0) f[0] = 0x08;   // frame-control byte 0. The classifier never reads it; the CALLER
                                // decides data vs mgmt via the isDataFrame argument.
    if (len > 1) f[1] = fc1;
    return f;
}
static void putMac(std::vector<uint8_t>& f, size_t off, const uint8_t* mac, size_t n = 6) {
    for (size_t i = 0; i < n && off + i < f.size(); i++) f[off + i] = mac[i];
}
static bool run(std::vector<uint8_t>& f, bool isData, AcabDetection* out, int rssi = -57) {
    memset(out, 0, sizeof(*out));
    return netcamClassifyWiFi(f.data(), f.size(), isData, rssi, out);
}
// A 32-byte data frame with ToDS=1/FromDS=0 (a camera uploading its stream to the AP: SA = addr2,
// offset 10). This is the primary real-world shape, so it is the default for the vendor positives.
static std::vector<uint8_t> uplink(const uint8_t* mac) {
    std::vector<uint8_t> f = frame(32, 0x01);
    putMac(f, 10, mac);
    return f;
}

// Table OUIs, each with distinct trailing bytes so a copied MAC is checkable.
static const uint8_t MAC_HIK[6]    = { 0x18, 0x68, 0xcb, 0x0a, 0x0b, 0x0c };   // Hikvision, registry-only
static const uint8_t MAC_DAHUA[6]  = { 0x3c, 0xef, 0x8c, 0x11, 0x22, 0x33 };   // Dahua, registry-only
static const uint8_t MAC_DAHUAV[6] = { 0x4c, 0x11, 0xbf, 0xde, 0xad, 0x01 };   // Dahua, FIELD-VALIDATED
static const uint8_t MAC_REOLNK[6] = { 0xec, 0x71, 0xdb, 0x44, 0x55, 0x66 };   // Reolink, FIELD-VALIDATED
static const uint8_t MAC_AMCRST[6] = { 0x9c, 0x8e, 0xcd, 0x01, 0x02, 0x03 };   // Amcrest
static const uint8_t MAC_AXIS[6]   = { 0x00, 0x40, 0x8c, 0x77, 0x88, 0x99 };   // Axis (leading 0x00)
static const uint8_t MAC_RING[6]   = { 0x00, 0xb4, 0x63, 0x0d, 0x0e, 0x0f };   // Ring (leading 0x00)
static const uint8_t MAC_WYZE[6]   = { 0x2c, 0xaa, 0x8e, 0x31, 0x32, 0x33 };   // Wyze
static const uint8_t MAC_ANKER[6]  = { 0xe8, 0xee, 0xcc, 0x5a, 0x5b, 0x5c };   // Anker/eufy

// The eleven vendor labels the apps are allowed to see. Exact strings: casing and the slash are
// part of the wire contract, not cosmetics. Ezviz/Lorex/Swann added 2026-08-02.
static const char* const KNOWN_VENDORS[] = {
    "Hikvision", "Dahua", "Amcrest", "Axis", "Reolink", "Ring", "Wyze", "Anker/eufy",
    "Ezviz", "Lorex", "Swann"
};

int main() {
    AcabDetection d;
    char note[192];
    printf("\n=== network-camera classifier regression ===\n");

    // ---- opt-in: default OFF, and OFF really means no work -----------------------------------
    // NOTE ON THE STUB: the host Preferences stub returns the caller's default from getBool(), so
    // NVS is a pass-through here. These assertions lock the FLAG LOGIC (default, gating, when the
    // filter is refreshed), not the persistence itself, which needs a board.
    chkBool("netcamIsEnabled() defaults OFF at boot", !netcamIsEnabled());
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("OFF: a real Hikvision uplink frame -> no hit", run(f, true, &d), false); }
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("OFF: same frame as a mgmt frame -> no hit", run(f, false, &d), false); }
    // The OUI table lookup is NOT gated: only the classifier is. The scanner reuses this helper on
    // the BLE path, so gating it would break a caller that has nothing to do with the WiFi filter.
    chkStr("OFF: netcamVendorOui() still resolves (helper is un-gated)",
           netcamVendorOui(MAC_HIK), "Hikvision");
    chkBool("OFF: no filter refresh has happened yet", gFilterRefreshes == 0);

    netcamSetEnabled(true);
    chkBool("setEnabled(true) flips the flag", netcamIsEnabled());
    chkBool("setEnabled(true) refreshed the WiFi filter exactly once", gFilterRefreshes == 1);
    netcamSetEnabled(true);
    chkBool("redundant setEnabled(true) is a no-op, no 2nd refresh", gFilterRefreshes == 1);

    // ---- one positive per vendor: the detail string and the confidence tier ------------------
    // Both fields are consumed downstream (the app splits the detail on " on wifi" for the maker
    // and sorts/colours by confidence), so both are asserted literally, not against the macro.
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("Hikvision 18:68:cb", run(f, true, &d), true, d.confidence, 65, d.detail, "Hikvision on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_DAHUA);
      chk("Dahua 3c:ef:8c (registry-only tier)", run(f, true, &d), true, d.confidence, 65, d.detail, "Dahua on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("Dahua 4c:11:bf FIELD-VALIDATED -> 75 not 65", run(f, true, &d), true, d.confidence, 75, d.detail, "Dahua on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_REOLNK);
      chk("Reolink ec:71:db FIELD-VALIDATED -> 75", run(f, true, &d), true, d.confidence, 75, d.detail, "Reolink on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_AMCRST);
      chk("Amcrest 9c:8e:cd", run(f, true, &d), true, d.confidence, 65, d.detail, "Amcrest on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_AXIS);
      chk("Axis 00:40:8c (leading 0x00 byte)", run(f, true, &d), true, d.confidence, 65, d.detail, "Axis on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_RING);
      chk("Ring 00:b4:63", run(f, true, &d), true, d.confidence, 65, d.detail, "Ring on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_WYZE);
      chk("Wyze 2c:aa:8e", run(f, true, &d), true, d.confidence, 65, d.detail, "Wyze on wifi"); }
    // THE SLASH IS LOAD-BEARING. "Anker/eufy" says the block is Fantasia Trading's entire catalogue
    // (chargers, speakers, vacuums, cameras), so the hit is "an Anker product" and the user is told
    // so. Anyone tidying this to "Anker" or "eufy" is deleting a deliberate honesty signal.
    { std::vector<uint8_t> f = uplink(MAC_ANKER);
      chk("Anker/eufy e8:ee:cc keeps its slash in the detail", run(f, true, &d), true, d.confidence, 65,
          d.detail, "Anker/eufy on wifi"); }
    chkStr("netcamVendorOui() label keeps the slash too", netcamVendorOui(MAC_ANKER), "Anker/eufy");

    // ---- the whole table, in one sweep --------------------------------------------------------
    // Every entry must hit, format identically, and land on the tier its validated flag claims.
    // This is what catches a new OUI pasted in with a typo'd label or a stray validated=1.
    { note[0] = 0; int validated = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++) {
          const NetcamOui& e = CAMERA_VENDOR_OUI[i];
          uint8_t m[6] = { e.oui[0], e.oui[1], e.oui[2], 0x01, 0x02, 0x03 };
          std::vector<uint8_t> f = uplink(m);
          char want[64]; snprintf(want, sizeof(want), "%s on wifi", e.vendor);
          int wantConf = e.validated ? 75 : 65;
          if (e.validated) validated++;
          bool hit = run(f, true, &d);
          if ((!hit || strcmp(d.detail, want) || d.confidence != wantConf) && !note[0])
              snprintf(note, sizeof(note), "idx %zu %02x:%02x:%02x hit=%d conf=%d detail=\"%s\" want=\"%s\"",
                       i, e.oui[0], e.oui[1], e.oui[2], hit, d.confidence, d.detail, want);
      }
      chkBool("all table OUIs hit as \"<Vendor> on wifi\" at 65/75", note[0] == 0, note);
      chkBool("exactly 4 entries are flagged field-validated", validated == 4); }
    // A TRIPWIRE, not a fact: it exists so nobody grows this table without re-confirming the
    // blocks against the IEEE registry and thinking about the false-positive cost. 43 -> 59 on
    // 2026-08-02 (Ezviz 14, Lorex 1, Swann 1), all re-confirmed against a fresh
    // standards-oui.ieee.org pull. If you are here because this failed, go read the DELIBERATELY
    // ABSENT block at the bottom of netcam_signatures.h before you bump the number.
    chkBool("table still holds exactly 59 OUIs", CAMERA_VENDOR_OUI_COUNT == 59);
    { note[0] = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++) {
          bool known = false;
          for (size_t v = 0; v < sizeof(KNOWN_VENDORS)/sizeof(KNOWN_VENDORS[0]); v++)
              if (!strcmp(CAMERA_VENDOR_OUI[i].vendor, KNOWN_VENDORS[v])) known = true;
          if (!known && !note[0]) snprintf(note, sizeof(note), "idx %zu unknown label \"%s\"", i,
                                           CAMERA_VENDOR_OUI[i].vendor);
      }
      chkBool("every label is one of the 11 exact known vendor strings", note[0] == 0, note); }
    // A table OUI with the locally-administered bit set could never match, because netcamEntry()
    // rejects LA addresses before it looks at the table. Such an entry would be dead weight and a
    // sign the block was transcribed wrong, so assert none exists.
    { note[0] = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++)
          if ((CAMERA_VENDOR_OUI[i].oui[0] & 0x02) && !note[0])
              snprintf(note, sizeof(note), "idx %zu oui[0]=%02x has the LA bit set (unmatchable)",
                       i, CAMERA_VENDOR_OUI[i].oui[0]);
      chkBool("no table OUI has the locally-administered bit set", note[0] == 0, note); }
    chkBool("confidence macros still read 65 / 75",
            NETCAM_OUI_CONFIDENCE == 65 && NETCAM_OUI_CONFIDENCE_VALIDATED == 75);

    // ---- the rest of the detection record, which the app and the log both read ----------------
    { std::vector<uint8_t> f = uplink(MAC_REOLNK); bool hit = run(f, true, &d, -57);
      chkBool("type/src/method = ACAB_NETCAM / SRC_WIFI / M_OUI",
              hit && d.type == ACAB_NETCAM && d.src == SRC_WIFI && d.method == M_OUI);
      chkBool("MAC copied from the source-address offset, rssi kept",
              hit && !memcmp(d.mac, MAC_REOLNK, 6) && d.rssi == -57);
      chkBool("companyId stays 0 (this is a WiFi path, not BLE)", hit && d.companyId == 0);
      // randomAddr is false because LA addresses never reach here, so the central durability
      // down-cap (M_OUI + randomAddr -> 25) can never touch a netcam hit. Assert that, because a
      // future "match randomized MACs too" change would silently collapse 75 to 25.
      chkBool("randomAddr false, so durability leaves the 75 alone",
              hit && !d.randomAddr && (acabApplyDurability(&d), d.confidence == 75)); }

    // ---- which address the DS bits select ------------------------------------------------------
    // Decoy layout: Hikvision at addr2 (10), Reolink at addr3 (16), Wyze at addr4 (24). Whichever
    // vendor comes back names the offset the classifier actually read.
    { std::vector<uint8_t> f = frame(40, 0x00);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS=0/FromDS=0 (ad-hoc) -> addr2", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x01);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS=1 (camera uploading) -> addr2", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x02);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data FromDS=1 (AP relay) -> addr3, not addr2", run(f, true, &d), true, d.confidence, 75, d.detail,
          "Reolink on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x03);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS+FromDS (WDS 4-address) -> addr4", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Wyze on wifi"); }
    // Mgmt frames have no DS semantics: addr2 is always the transmitter. So the same buffer that
    // resolved to Reolink as a data frame must resolve to Hikvision as a mgmt frame.
    { std::vector<uint8_t> f = frame(40, 0x03);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("mgmt frame ignores the DS bits -> always addr2", run(f, false, &d), true, d.confidence, 65,
          d.detail, "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(16, 0x00); putMac(f, 10, MAC_RING);
      chk("mgmt frame of exactly 16 bytes (the minimum) still hits", run(f, false, &d), true,
          d.confidence, 65, d.detail, "Ring on wifi"); }

    // ---- adversarial input ---------------------------------------------------------------------
    { std::vector<uint8_t> f;
      chk("empty buffer (len 0) -> no hit, no read", run(f, true, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("null frame pointer with a plausible len -> no hit",
          netcamClassifyWiFi(nullptr, 64, true, -50, &d), false); }
    { std::vector<uint8_t> f = frame(15, 0x01); putMac(f, 10, MAC_HIK, 5);
      chk("len 15 truncates the OUI -> below the 16-byte floor", run(f, true, &d), false); }
    // THE OVERRUN CASE: the frame-control bits DECLARE a 4-address WDS frame, so the source MAC is
    // claimed to be at offset 24, but the buffer is only 20 bytes long. The classifier must refuse,
    // and must NOT quietly fall back to the perfectly good Hikvision OUI sitting at offset 10.
    // Reading addr4 out of a 20-byte buffer is the read-past-the-end this test is here to prevent.
    { std::vector<uint8_t> f = frame(20, 0x03); putMac(f, 10, MAC_HIK);
      chk("FC claims addr4 but buffer is 20 bytes -> no hit, no fallback", run(f, true, &d), false); }
    { std::vector<uint8_t> f = frame(20, 0x02); putMac(f, 10, MAC_HIK);
      chk("FC claims addr3 at 16 in a 20-byte buffer -> no hit", run(f, true, &d), false); }
    // Near misses. One byte off a real block must not match: the compare is all three bytes.
    { uint8_t m[6] = { 0x18, 0x68, 0xcc, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("neighbouring OUI 18:68:cc (Hikvision is ..cb) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x4c, 0x11, 0xbe, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("neighbouring OUI 4c:11:be (Dahua is ..bf) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x18, 0x00, 0x00, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("first byte matches Hikvision, rest does not -> no hit", run(f, true, &d), false); }
    // Vendors the signature header EXCLUDES on purpose, because the registrant is too broad. If one
    // of these ever starts matching, someone widened the table past the narrowness rule.
    { uint8_t m[6] = { 0x24, 0x0a, 0xc4, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Espressif 24:0a:c4 (shared silicon, excluded) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x44, 0x65, 0x0d, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Amazon 44:65:0d (Blink rides it, excluded) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x18, 0xb4, 0x30, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Nest 18:b4:30 (excluded) -> no hit", run(f, true, &d), false); }
    // Randomized / locally-administered source MACs: the OUI means nothing there, so they are
    // dropped before the table is consulted, even when the remaining bytes spell a real block.
    { uint8_t m[6] = { 0x1a, 0x68, 0xcb, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Hikvision block with the LA bit set (1a:68:cb) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x02, 0xb4, 0x63, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Ring block with the LA bit set (02:b4:63) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }; std::vector<uint8_t> f = uplink(m);
      chk("broadcast ff:ff:ff:ff:ff:ff -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; std::vector<uint8_t> f = uplink(m);
      chk("all-zero MAC -> no hit (3 vendors start with 0x00)", run(f, true, &d), false); }
    { const uint8_t unlisted[6] = { 0x24, 0x0a, 0xc4, 0, 0, 0 };
      chkBool("netcamVendorOui() returns nullptr for an unlisted OUI",
              netcamVendorOui(unlisted) == nullptr); }
    { const uint8_t randomized[6] = { 0x1a, 0x68, 0xcb, 0, 0, 0 };
      chkBool("netcamVendorOui() returns nullptr for a randomized MAC",
              netcamVendorOui(randomized) == nullptr); }
    // On a miss the output record must be left completely alone: the caller reuses one AcabDetection
    // across every classifier in the chain, so a partial write here would leak a phantom camera
    // detail onto whichever detector matches next.
    { AcabDetection sentinel; memset(&sentinel, 0xEE, sizeof(sentinel));
      uint8_t m[6] = { 0x18, 0x68, 0xcc, 0x01, 0x02, 0x03 };
      std::vector<uint8_t> f = uplink(m);
      bool hit = netcamClassifyWiFi(f.data(), f.size(), true, -50, &sentinel);
      bool untouched = true;
      for (size_t i = 0; i < sizeof(sentinel); i++) if (((const uint8_t*)&sentinel)[i] != 0xEE) untouched = false;
      chkBool("a miss writes NOTHING into the caller's record", !hit && untouched); }

    // ---- turning it back off, and the restore path ---------------------------------------------
    netcamSetEnabled(false);
    chkBool("setEnabled(false) clears the flag", !netcamIsEnabled());
    chkBool("setEnabled(false) refreshed the filter (narrow to mgmt)", gFilterRefreshes == 2);
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("OFF again: field-validated Dahua frame -> no hit", run(f, true, &d), false); }
    netcamSetEnabled(false);
    chkBool("redundant setEnabled(false) is a no-op, still 2 refreshes", gFilterRefreshes == 2);

    // netcamRestoreEnabled() reads NVS on boot and, BY DESIGN, does not refresh the filter: it runs
    // before the scanner starts, and acabScannerBegin() reads netcamIsEnabled() when it installs the
    // filter. Asserted as-is. CONCERN worth knowing: because restore bypasses the setter, a later
    // setEnabled(true) on an already-restored-true flag early-returns and never refreshes either, so
    // anything that restores true AFTER the scanner is up depends on that boot-time read having
    // happened. Only boot calls this today, so it holds.
    netcamRestoreEnabled(true);
    chkBool("restoreEnabled(true) sets the flag", netcamIsEnabled());
    chkBool("restoreEnabled() does NOT refresh the filter (by design)", gFilterRefreshes == 2);
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("restored ON: classifier live again at tier 75", run(f, true, &d), true, d.confidence, 75,
          d.detail, "Dahua on wifi"); }
    netcamSetEnabled(true);
    chkBool("setEnabled(true) after restore(true) is a no-op", gFilterRefreshes == 2);
    netcamRestoreEnabled(false);
    chkBool("restoreEnabled(false) restores the default-OFF state", !netcamIsEnabled());
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("restored OFF: no hit", run(f, true, &d), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
