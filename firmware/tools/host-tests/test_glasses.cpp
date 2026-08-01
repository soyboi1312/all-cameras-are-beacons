// Host regression test for the glasses classifier, targeting the 2026-07-31 rewrite from
// return-on-first-match to score-and-keep. That change is invisible to the compiler and would
// only show up in the field as "it stopped detecting glasses".
#include "glasses_detect.h"
#include "glasses_signatures.h"
#include <cstdio>
#include <cstring>
#include <vector>
bool desertIsEnabled() { return false; }   // desert off, so only real matches fire

static int failures = 0;
static void chk(const char* name, bool got, bool wantHit,
                int gotConf = -1, int wantConf = -1, const char* gotDetail = "", const char* wantDetail = nullptr) {
    bool ok = (got == wantHit);
    if (ok && wantHit && wantConf >= 0) ok = (gotConf == wantConf);
    if (ok && wantHit && wantDetail)    ok = (strcmp(gotDetail, wantDetail) == 0);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got hit=%d conf=%d detail=\"%s\"", got, gotConf, gotDetail); failures++; }
    printf("\n");
}

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
static void addHeyCyan(std::vector<uint8_t>& a) {
    a.push_back(17); a.push_back(0x07);
    for (int i = 0; i < 16; i++) a.push_back(GLASSES_HEYCYAN_UUID_LE[i]);
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

    { std::vector<uint8_t> a; addMfg(a, 0x01AB);
      chk("0x01AB alone (the un-gated Meta ID)", run(a,&d), true, d.confidence, 45, d.detail); }
    { std::vector<uint8_t> a; addMfg(a, 0x0D53);
      chk("0x0D53 Luxottica alone", run(a,&d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> a; addMfg(a, 0x058E);
      chk("0x058E alone -> GATED, no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x05D6);
      chk("0x05D6 Jieli alone -> GATED, no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7);
      chk("member UUID 0xFEB7 alone, no mfg data", run(a,&d), true, d.confidence, 45, d.detail); }
    { std::vector<uint8_t> a; addU16List(a, 0xFE45);
      chk("member UUID 0xFE45 Snap alone", run(a,&d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> a; addU16List(a, 0xFD5F);
      chk("member UUID 0xFD5F -> GATED, no hit", run(a,&d), false); }
    { std::vector<uint8_t> a; addHeyCyan(a);
      chk("HeyCyan UUID alone, no mfg data", run(a,&d), true, d.confidence, 68, d.detail, "HeyCyan glasses UUID"); }

    // THE CASE THE REWRITE EXISTS FOR: a weak member UUID must not preempt the token tier.
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x058E, "META_RB_GLASS");
      chk("FEB7(45) + 0x058E+token(72) -> keeps 72", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    { std::vector<uint8_t> a; addU16List(a, 0xFEB7); addMfg(a, 0x01AB, "META_RB_GLASS");
      chk("FEB7(45) + 0x01AB+token(72) -> keeps 72", run(a,&d), true, d.confidence, 72, d.detail,
          "Ray-Ban Meta: recording glasses"); }
    { std::vector<uint8_t> a; addHeyCyan(a); addU16List(a, 0xFEB7);
      chk("HeyCyan(68) + FEB7(45) -> keeps 68", run(a,&d), true, d.confidence, 68, d.detail,
          "HeyCyan glasses UUID"); }
    { std::vector<uint8_t> a; addU16List(a, 0xFE45); addHeyCyan(a);
      chk("FE45(70) + HeyCyan(68) -> keeps 70", run(a,&d), true, d.confidence, 70, d.detail); }

    // negatives
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

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
