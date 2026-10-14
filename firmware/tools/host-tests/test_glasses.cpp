// Host regression test for the glasses classifier, targeting the 2026-07-31 rewrite from
// return-on-first-match to score-and-keep. That change is invisible to the compiler and would
// only show up in the field as "it stopped detecting glasses".
//
// Every hit pins THREE things: confidence, the exact detail string, and the method. Confidence
// drives the apps' weak-match treatment at the 50 line, detail is rendered verbatim, and method
// (`meth` on the wire) is the only field that shows WHICH of the three surfaces fired when two of
// them carry the same detail text. docs/signatures.md publishes the evaluation order (HeyCyan,
// then 16-bit member UUID, then company ID) as a contract because it decides equal-confidence
// ties, so the tie cases below are the tripwire for a reordered loop or a `<=` turned into `<`.
#include "glasses_detect.h"
#include "glasses_signatures.h"
#include <cstdio>
#include <cstring>
#include <vector>
bool desertIsEnabled() { return false; }   // desert off, so only real matches fire

#include "host_check.h"   // failures, chk_impl, the chk macro (and why it must stay a macro), chkInt

// ---- advert builders (BLE AD structures: [len][type][data...]) ----
static void addMfg(std::vector<uint8_t>& a, uint16_t cid, const char* tail = nullptr) {
    size_t tl = tail ? strlen(tail) : 0;
    a.push_back((uint8_t)(1 + 2 + tl)); a.push_back(0xFF);
    a.push_back(cid & 0xFF); a.push_back(cid >> 8);
    for (size_t i = 0; i < tl; i++) a.push_back((uint8_t)tail[i]);
}
static void addU16List(std::vector<uint8_t>& a, uint16_t uuid) {
    a.push_back(3); a.push_back(0x03); a.push_back(uuid & 0xFF); a.push_back(uuid >> 8);
}
// The HeyCyan UUID in a 128-bit UUID list (AD 0x07) or as 128-bit service DATA (AD 0x21), in
// either byte order. Both AD types and both orders are shipped paths, so each gets a case.
static void addHeyCyan(std::vector<uint8_t>& a, uint8_t adType = 0x07, const uint8_t* uuid = GLASSES_HEYCYAN_UUID_LE) {
    a.push_back(17); a.push_back(adType);
    for (int i = 0; i < 16; i++) a.push_back(uuid[i]);
}
static bool run(std::vector<uint8_t>& a, AcabDetection* out) {
    const uint8_t mac[6] = {0x41, 0xbc, 0xbc, 0x7d, 0xe0, 0x53};   // a real captured RPA
    memset(out, 0, sizeof(*out));
    return glassesClassifyBLE(mac, a.data(), a.size(), -84, out);
}

int main() {
    glassesSetEnabled(true);
    AcabDetection d;
    printf("\n=== glasses classifier regression ===\n");

    // -- single surface, company ID -----------------------------------------------------
    // Every bare company ID sits below 50 (glasses_signatures.h CONFIDENCE ladder): a SIG company
    // ID names the vendor, never the type. The uncaptured eyewear registrants were 70 until
    // 2026-10-11, ranking an ID no capture had ever heard above the one ID real glasses proved.
    printf("\n  -- company ID --\n");
    { std::vector<uint8_t> a; addMfg(a, 0x01AB);
      chk("0x01AB alone (the un-gated Meta ID)", run(a,&d), true, d.confidence, 45, d.detail,
          "Meta: possible recording glasses or Quest"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    chkInt("  ...type is ACAB_GLASSES", d.type, ACAB_GLASSES);
    { std::vector<uint8_t> a; addMfg(a, 0x0D53);
      chk("0x0D53 Luxottica alone -> 49, vendor wording", run(a,&d), true, d.confidence, 49, d.detail,
          "Luxottica device, possible glasses"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addMfg(a, 0x03C2);
      chk("0x03C2 Snap alone -> 49, vendor wording", run(a,&d), true, d.confidence, 49, d.detail,
          "Snap device, possible glasses"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addMfg(a, 0x060C);
      chk("0x060C Vuzix alone -> 49, type unknown", run(a,&d), true, d.confidence, 49, d.detail,
          "Vuzix equipment, type unknown"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addMfg(a, 0x058E);
      chk("0x058E alone -> GATED, no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x0BC6);
      chk("0x0BC6 TCL alone -> GATED, no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x05D6);
      chk("0x05D6 Jieli alone -> GATED, no hit", run(a,&d), false); }
    // The token is not a standalone match (it needs a Meta company ID in the same record), but it
    // UN-GATES the shared 0x058E: this advert carries nothing else and still emits at 72.
    { std::vector<uint8_t> a; addMfg(a, 0x058E, "META_RB_GLASS");
      chk("0x058E + token, nothing else -> 72 (un-gated)", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addMfg(a, 0x0D53, "META_RB_GLASS");
      chk("token on a non-Meta ID does nothing (49)", run(a,&d), true, d.confidence, 49, d.detail,
          "Luxottica device, possible glasses"); }

    // -- single surface, 16-bit member UUID ---------------------------------------------
    printf("\n  -- 16-bit member UUID --\n");
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7);
      chk("member UUID 0xFEB7 alone, no mfg data", run(a,&d), true, d.confidence, 45, d.detail,
          "Meta: possible recording glasses or Quest"); }
    chkInt("  ...method is M_SERVICE_UUID", d.method, M_SERVICE_UUID);
    { std::vector<uint8_t> a; addU16List(a, 0xFE45);
      chk("member UUID 0xFE45 Snap alone -> 49", run(a,&d), true, d.confidence, 49, d.detail,
          "Snap device, possible glasses"); }
    chkInt("  ...method is M_SERVICE_UUID", d.method, M_SERVICE_UUID);
    { std::vector<uint8_t> a; addU16List(a, 0xFD5F);
      chk("member UUID 0xFD5F -> GATED, no hit", run(a,&d), false); }

    // -- single surface, HeyCyan 128-bit UUID -------------------------------------------
    printf("\n  -- HeyCyan UUID --\n");
    { std::vector<uint8_t> a; addHeyCyan(a);
      chk("HeyCyan UUID (AD 0x07, LE) alone, no mfg data", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    chkInt("  ...method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);
    { std::vector<uint8_t> a; addHeyCyan(a, 0x07, GLASSES_HEYCYAN_UUID_BE);
      chk("HeyCyan UUID big-endian also matches", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    chkInt("  ...method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);
    { std::vector<uint8_t> a; addHeyCyan(a, 0x21);
      chk("HeyCyan UUID as AD 0x21 service data", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    chkInt("  ...method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);

    // -- two surfaces, unequal: the best wins, never the first --------------------------
    printf("\n  -- best-of, unequal --\n");
    // THE CASE THE REWRITE EXISTS FOR: a weak member UUID must not preempt the token tier.
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x058E, "META_RB_GLASS");
      chk("FEB7(45) + 0x058E+token(72) -> keeps 72", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    chkInt("  ...method is M_MFG_ID (surface 3 displaced 2)", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x01AB, "META_RB_GLASS");
      chk("FEB7(45) + 0x01AB+token(72) -> keeps 72", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addHeyCyan(a); addU16List(a, 0xFEB7);
      chk("HeyCyan(68) + FEB7(45) -> keeps 68", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    chkInt("  ...method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);
    // Was "FE45(70) + HeyCyan(68) -> keeps 70" while Snap sat at 70; with FE45 at 49 the SDK
    // UUID is the stronger surface and must now win.
    { std::vector<uint8_t> a; addU16List(a, 0xFE45); addHeyCyan(a);
      chk("FE45(49) + HeyCyan(68) -> keeps 68", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    chkInt("  ...method is M_SERVICE_DATA (surface 1 displaced 2)", d.method, M_SERVICE_DATA);
    // A later, higher surface still displaces surface 1: the token tier over HeyCyan.
    { std::vector<uint8_t> a; addHeyCyan(a); addMfg(a, 0x01AB, "META_RB_GLASS");
      chk("HeyCyan(68) + 0x01AB+token(72) -> keeps 72", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    chkInt("  ...method is M_MFG_ID (surface 3 displaced 1)", d.method, M_MFG_ID);
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x0D53);
      chk("FEB7(45) + 0x0D53(49) -> keeps 49", run(a,&d), true, d.confidence, 49, d.detail,
          "Luxottica device, possible glasses"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);

    // -- two surfaces, EQUAL: first-listed wins the tie (the `<=` contract) ------------
    // The detail text is identical on both paths of each pair, so `meth` is the only field that
    // shows which surface fired, and it is what docs/signatures.md promises. Surface 1 (HeyCyan,
    // 68) has no equal-confidence partner in the shipped table, so only the 2-vs-3 pair can tie.
    printf("\n  -- ties --\n");
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x01AB);
      chk("FEB7(45) + 0x01AB(45) tie -> 45", run(a,&d), true, d.confidence, 45, d.detail,
          "Meta: possible recording glasses or Quest"); }
    chkInt("  ...method stays M_SERVICE_UUID (surface 2 listed first)", d.method, M_SERVICE_UUID);
    { std::vector<uint8_t> a; addMfg(a, 0x01AB); addU16List(a, 0xFEB7);
      chk("same pair, mfg record first in the advert -> 45", run(a,&d), true, d.confidence, 45, d.detail,
          "Meta: possible recording glasses or Quest"); }
    chkInt("  ...AD order does not matter, still M_SERVICE_UUID", d.method, M_SERVICE_UUID);
    { std::vector<uint8_t> a; addU16List(a, 0xFE45); addMfg(a, 0x03C2);
      chk("FE45(49) + 0x03C2(49) tie -> 49", run(a,&d), true, d.confidence, 49, d.detail,
          "Snap device, possible glasses"); }
    chkInt("  ...method stays M_SERVICE_UUID (the documented example)", d.method, M_SERVICE_UUID);

    // -- negatives ----------------------------------------------------------------------
    printf("\n  -- negatives --\n");
    { std::vector<uint8_t> a; addMfg(a, 0x004C);
      chk("Apple 0x004C -> no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addU16List(a, 0xFEB6);
      chk("neighbouring UUID 0xFEB6 -> no hit", run(a,&d), false); }
    { std::vector<uint8_t> a;
      chk("empty advert -> no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; a.push_back(200); a.push_back(0xFF); a.push_back(0xAB);
      chk("malformed: length overruns buffer", run(a,&d), false); }
    { std::vector<uint8_t> a; for (int i=0;i<40;i++) addU16List(a, 0xFEB6);
      chk("u16 overflow: 40 UUIDs into a 12 slot array", run(a,&d), false); }
    { // ANCS lookalike must NOT match (differs in 2 of 16 bytes)
      std::vector<uint8_t> a; a.push_back(17); a.push_back(0x07);
      uint8_t ancs[16]; memcpy(ancs, GLASSES_HEYCYAN_UUID_LE, 16);
      ancs[13] = 0x31; ancs[12] = 0xF4;   // FFF0 -> F431, i.e. Apple's ANCS
      for (int i=0;i<16;i++) a.push_back(ancs[i]);
      chk("Apple ANCS lookalike -> NO hit", run(a,&d), false); }
    glassesSetEnabled(false);
    { std::vector<uint8_t> a; addMfg(a, 0x01AB);
      chk("disabled: 0x01AB -> no hit", run(a,&d), false); }
    glassesSetEnabled(true);

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
