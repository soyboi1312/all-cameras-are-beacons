// Host regression test for the nRF advert-line parser (nrf_line.h).
//
// WHY THIS SUITE EXISTS. The beacon board hears BLE only through the nRF, one ASCII line per
// advert. When the S3's UART buffer overflows, the head of one line fuses with the tail of a later
// one. The old parser kept whatever hex it could read, so a fused line could pin another device's
// payload on an intact MAC. These cases pin the rule that replaced it: a line the nRF could not
// have printed is dropped whole. Two layers: the lexical check (every field in the nRF's print
// format) and, since 2026-10-11, the structural one (the AD structures must tile the payload),
// which is what catches a splice that lands inside hex on both sides with an even nibble count.
// Every positive fixture therefore carries a payload that tiles.
#include "../../lib/acab_core/nrf_line.h"
#include <cstdio>
#include <cstring>
#include <cstdint>

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool got, bool want) {
    gRun++;
    bool ok = (got == want);
    if (!ok) gFail++;
    printf("  %-58s %s\n", name, ok ? "PASS" : "**FAIL**");
    if (!ok) printf("      got %s, wanted %s\n", got ? "true" : "false", want ? "true" : "false");
}

static bool parse(const char* line, size_t cap = 256) {
    uint8_t mac[6], payload[256];
    int rssi;
    size_t plen;
    return nrfParseAdvLine(line, mac, &rssi, payload, cap, &plen);
}

int main() {
    printf("\n=== nRF advert-line parser ===\n");

    { uint8_t mac[6], payload[256]; int rssi = 0; size_t plen = 0;
      bool ok = nrfParseAdvLine("A 001122AABBCC -85 02010603FF4C00", mac, &rssi, payload, 256, &plen);
      const uint8_t wantMac[6] = {0x00, 0x11, 0x22, 0xAA, 0xBB, 0xCC};
      const uint8_t wantPl[7]  = {0x02, 0x01, 0x06, 0x03, 0xFF, 0x4C, 0x00};
      chk("well-formed line decodes MAC, RSSI and payload exactly",
          ok && !memcmp(mac, wantMac, 6) && rssi == -85 && plen == 7 && !memcmp(payload, wantPl, 7),
          true); }
    { uint8_t mac[6], payload[256]; int rssi = 0; size_t plen = 99;
      chk("zero-length advert (the nRF still prints the space) is kept",
          nrfParseAdvLine("A 001122AABBCC -85 ", mac, &rssi, payload, 256, &plen) && plen == 0, true); }
    { char line[600] = "A 001122AABBCC -60 FEFF";   // one 254-byte mfg structure = 255 bytes
      for (int i = 0; i < 253; i++) strcat(line, "AB");
      chk("255-byte payload fits a 256-byte buffer", parse(line), true); }
    chk("int8 extremes -128 and 127 both parse",
        parse("A 001122AABBCC -128 020106") && parse("A 001122AABBCC 127 020106"), true);

    // Fused lines: the head of one line plus the tail of a later one.
    chk("fused into the next line's MAC/RSSI (space in payload) -> drop",
        parse("A 001122AABBCC -85 0201061AAABBCC -70 0201"), false);
    chk("fused mid-byte (odd nibble count) -> drop",
        parse("A 001122AABBCC -85 0201061"), false);
    chk("trailing non-hex character -> drop", parse("A 001122AABBCC -85 0201FF#"), false);

    // Structural check: these pass every lexical rule (whole hex bytes, even nibble count) and
    // are exactly the splices the lexical layer lets through.
    chk("fused: AD length runs past the end of the payload -> drop",
        parse("A 001122AABBCC -85 0201061AFF4C00"), false);          // 0x1A claims 26, 3 remain
    chk("fused: cut inside one structure, tail of another spliced on -> drop",
        parse("A 001122AABBCC -85 0201060303AAFE1216AAFE00"), false);   // 0x12 claims 18, 5 remain
    chk("fused: length one past the end -> drop",
        parse("A 001122AABBCC -85 02010604FF4C00"), false);          // 0x04 claims 4, 3 remain
    chk("non-zero bytes after a 0x00 length byte -> drop",
        parse("A 001122AABBCC -85 02010600FF"), false);
    chk("zero padding after a 0x00 length byte is kept (31-byte legacy pad)",
        parse("A 001122AABBCC -85 0201060000"), true);
    chk("structures that tile exactly are kept",
        parse("A 001122AABBCC -85 0201060303AAFE0616AAFE010203"), true);   // 3 + 4 + 7 bytes

    chk("payload longer than the buffer -> drop, not truncate",
        parse("A 001122AABBCC -85 0102030405", 4), false);
    chk("RSSI with four digits -> drop", parse("A 001122AABBCC -1234 020106"), false);
    chk("RSSI outside int8 -> drop", parse("A 001122AABBCC -129 020106"), false);
    chk("RSSI with no digits -> drop", parse("A 001122AABBCC - 020106"), false);
    chk("RSSI with a stray character -> drop", parse("A 001122AABBCC -8x5 020106"), false);
    chk("MAC one digit short -> drop", parse("A 001122AABBC -85 020106"), false);
    chk("MAC with a non-hex digit -> drop", parse("A 001122AABBGG -85 020106"), false);
    chk("no space after the MAC -> drop", parse("A 001122AABBCC-85 020106"), false);
    chk("line cut inside the MAC -> drop (no read past the NUL)", parse("A 0011"), false);
    chk("line cut after the RSSI -> drop", parse("A 001122AABBCC -85"), false);
    chk("not an advert line -> drop", parse("D 10 9 1 0"), false);

    printf(gFail ? "\n  REGRESSION DETECTED (%d failure%s of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail == 1 ? "" : "s", gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
