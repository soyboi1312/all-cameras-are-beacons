// Host regression test for the nRF co-processor's forward window (nrf_dedup.h).
//
// WHY THIS SUITE EXISTS. The beacon board hears BLE only through the nRF, and this table decides
// which adverts the S3 ever sees. It runs inside the scan callback with the radio paused, so its
// probe length IS the scan duty cycle. The table it replaced never emptied a slot and walked to the
// first empty one, so after an hour of ordinary churn every first-seen MAC probed all 2048 slots
// with the radio off (about 1 ms each). Its eviction fallback also compared raw millis() stamps,
// which picks the wrong victim across the 49.7-day wrap. These cases pin the bound, the wrap and
// the forward semantics the S3 depends on (window restart, per-window peak, in-place reuse), then
// the Remote ID bypass of that window: the message-type byte must be the one the S3's droneRidBLE
// decodes, one advertiser repeating a Remote ID stub must no longer forward on every advert, and a
// drone's two BasicIDs (serial plus CAA/session ID, both message type 0) must both keep reaching
// the S3, which consumes both (trackAddId in drone_detect.cpp).
#include "../../lib/acab_core/nrf_dedup.h"
#include "host_check.h"
#include <cstdint>
#include <cstdio>
#include <cstring>

// Mirrors nrf-ble-scan/src/main.cpp: DEDUP_TBL 2048, DEDUP_WINDOW_MS 20000, PEAK_JUMP_DB 6,
// DEDUP_PROBE 16. That directory is gitignored, so this is the public pin of those numbers.
static const uint32_t TBL = 2048, WIN = 20000, PROBE = 16;
typedef NrfDedup<TBL, WIN, 6, PROBE> Table;

static uint32_t gRng = 0x9E3779B9u;
static uint32_t rnd() { gRng ^= gRng << 13; gRng ^= gRng >> 17; gRng ^= gRng << 5; return gRng; }
static void rndMac(uint8_t m[6]) { uint32_t a = rnd(), b = rnd(); memcpy(m, &a, 4); memcpy(m + 4, &b, 2); }

// Slots a lookup of mac walks before finding it, or 0 when it is not within PROBE of home.
static uint32_t lookupDistance(const Table& t, const uint8_t* mac) {
    const uint32_t h = nrfMacHash(mac);
    for (uint32_t n = 0; n < PROBE; n++) {
        const NrfSeen& e = t.tbl[(h + n) & (TBL - 1)];
        if (!e.used) return 0;
        if (memcmp(e.mac, mac, 6) == 0) return n + 1;
    }
    return 0;
}

// Draws random MACs until `want` of them hash to home slot `home`.
static void macsWithHome(uint32_t home, uint8_t out[][6], int want) {
    for (int got = 0; got < want;) {
        rndMac(out[got]);
        if ((nrfMacHash(out[got]) & (TBL - 1)) == home) got++;
    }
}

static const int8_t R = -60;   // a mid-range RSSI

int main() {
    printf("\n=== nRF forward window ===\n");

    // ---- probe bound: 1e6 random MACs at rates from 1/s to 1000/s, with re-sightings mixed in
    {
        static Table t;   // zero-initialised: no entry is `used`
        static uint8_t recent[64][6];
        const uint32_t stepsMs[] = { 1000, 200, 20, 4, 1 };    // per-insert clock advance per phase
        uint32_t now = 0, maxProbe = 0, forwards = 0;
        for (uint32_t i = 0; i < 1000000; i++) {
            uint8_t m[6];
            if (i % 3 == 2) memcpy(m, recent[rnd() & 63], 6);  // a device still in range
            else { rndMac(m); memcpy(recent[i & 63], m, 6); }
            now += stepsMs[(i / 200000) % 5];
            uint32_t p = 0;
            if (!t.seen(m, now, (int8_t)(-40 - (rnd() % 50)), &p)) forwards++;
            if (p > maxProbe) maxProbe = p;
        }
        chkInt("max probe over 1e6 inserts (capped at PROBE)", maxProbe > PROBE ? maxProbe : PROBE, PROBE);
        printf("      (max probe %u, forwards %u)\n", (unsigned)maxProbe, (unsigned)forwards);
        // The bound is exact only because nothing is placed beyond PROBE of its home.
        uint32_t beyond = 0, used = 0;
        for (uint32_t i = 0; i < TBL; i++) {
            if (!t.tbl[i].used) continue;
            used++;
            if (lookupDistance(t, t.tbl[i].mac) == 0) beyond++;
        }
        chkInt("every resident MAC sits within PROBE of its home", beyond, 0);
        chkInt("table reached saturation during the run (used slots)", used, TBL);
    }

    // ---- millis() wrap: the window compare and the eviction order both use ages
    {
        static Table t;   // zero-initialised: no entry is `used`
        uint8_t x[6]; rndMac(x);
        const uint32_t t0 = 0xFFFFFFFFu - 1000;
        chk("first sighting just before the wrap forwards", t.seen(x, t0, R), false);
        chk("re-sighting 1.5 s later, across the wrap, is suppressed", t.seen(x, t0 + 1500, R), true);
        chk("re-sighting one window later, across the wrap, forwards", t.seen(x, t0 + WIN, R), false);
    }
    {
        static Table t;   // zero-initialised: no entry is `used`
        static uint8_t m[PROBE + 1][6];
        const uint32_t home = 777;
        macsWithHome(home, m, PROBE + 1);
        // m[0] is the oldest by age (seen 456 ms before `now`) but has the LARGEST raw stamp.
        t.seen(m[0], 0xFFFFFF00u, R);
        for (uint32_t i = 1; i < PROBE; i++) t.seen(m[i], 100, R);
        chk("window full of live MACs: the newcomer still forwards", t.seen(m[PROBE], 200, R), false);
        chk("the victim is the oldest by age, not by raw stamp (re-forwards)", t.seen(m[0], 200, R), false);
        chk("the youngest entry survived the eviction", t.seen(m[PROBE - 1], 200, R), true);
    }

    // ---- forward semantics the S3 relies on (unchanged from the old table)
    {
        static Table t;   // zero-initialised: no entry is `used`
        uint8_t a[6]; rndMac(a);
        chk("first sighting forwards", t.seen(a, 0, -80), false);
        chk("same reading inside the window is suppressed", t.seen(a, 100, -80), true);
        chk("+5 dB on the window's best is still suppressed", t.seen(a, 200, -75), true);
        chk("+6 dB on the window's best forwards (closest approach)", t.seen(a, 300, -74), false);
        chk("the forward re-seeded the peak: same reading suppressed", t.seen(a, 400, -74), true);
        chk("the forward restarted the window: suppressed at 19.999 s", t.seen(a, 300 + WIN - 1, -74), true);
        chk("window expiry forwards", t.seen(a, 300 + WIN, -74), false);
    }
    {
        static Table t;   // zero-initialised: no entry is `used`
        uint8_t b[6]; rndMac(b);
        t.seen(b, 0, -60);
        chk("expired entry forwards at a weak reading", t.seen(b, 25000, -90), false);
        chk("new window seeds its own peak: +5 dB suppressed", t.seen(b, 25100, -85), true);
        chk("new window seeds its own peak: +6 dB forwards (old peak -60 would hide it)",
            t.seen(b, 25200, -84), false);
    }
    {
        static Table t;   // zero-initialised: no entry is `used`
        static uint8_t m[3][6];
        macsWithHome(1234, m, 3);
        t.seen(m[0], 0, R);           // home slot
        t.seen(m[1], 10000, R);       // probes past m[0] to home+1
        chk("a third MAC on the chain reclaims the expired home slot in place",
            t.seen(m[2], 25000, R), false);
        chkInt("reclaim landed on the home slot", lookupDistance(t, m[2]), 1);
        chk("the live MAC behind the reclaimed slot is still found", t.seen(m[1], 25000, R), true);
        uint32_t p = 0;
        t.seen(m[1], 25001, R, &p);
        chkInt("that hit cost two probes", p, 2);
    }

    // ---- Remote ID bypass: the type nibble comes from the byte droneRidBLE reads as msg[0], and a
    //      BasicID is keyed by its IDType (msg[1] high nibble) so a drone's two IDs are two keys
    {
        // Flags AD, then the ODID service-data AD: len 0x1E, 0x16, FA FF, app 0x0D, counter, 25-byte message
        uint8_t adv[34] = { 0x02, 0x01, 0x06, 0x1E, 0x16, 0xFA, 0xFF, 0x0D, 0x00, 0x02, 0x10 };
        chkInt("BasicID (0x02) IDType serial (0x1x) behind Flags reads 17", nrfOdidMsgType(adv, sizeof(adv)), 17);
        adv[10] = 0x20; chkInt("BasicID IDType CAA registration (0x2x) reads 18", nrfOdidMsgType(adv, sizeof(adv)), 18);
        adv[9] = 0x12; chkInt("Location (0x12) reads type 1", nrfOdidMsgType(adv, sizeof(adv)), 1);
        adv[9] = 0x42; chkInt("System (0x42) reads type 4", nrfOdidMsgType(adv, sizeof(adv)), 4);
        adv[9] = 0x52; chkInt("OperatorID (0x52) reads type 5", nrfOdidMsgType(adv, sizeof(adv)), 5);
        adv[9] = 0xF2; chkInt("message pack (0xF2) reads type 15", nrfOdidMsgType(adv, sizeof(adv)), 15);
        chkInt("AD length running past the payload is not Remote ID", nrfOdidMsgType(adv, 20), -1);
        uint8_t stub[9] = { 0x02, 0x01, 0x06, 0x05, 0x16, 0xFA, 0xFF, 0x0D, 0x00 };
        chkInt("signature with no message byte is not Remote ID", nrfOdidMsgType(stub, sizeof(stub)), -1);
        uint8_t cut[7] = { 0x06, 0x16, 0xFA, 0xFF, 0x0D, 0x00, 0x02 };   // BasicID cut after msg[0]: no IDType byte to read
        chkInt("BasicID with no IDType byte reads plain type 0", nrfOdidMsgType(cut, sizeof(cut)), 0);
        uint8_t other[7] = { 0x06, 0x16, 0xFB, 0xFF, 0x0D, 0x00, 0x12 };
        chkInt("another service UUID is not Remote ID", nrfOdidMsgType(other, sizeof(other)), -1);
        uint8_t plain[7] = { 0x02, 0x01, 0x06, 0x03, 0xFF, 0x4C, 0x00 };
        chkInt("a plain manufacturer advert is not Remote ID", nrfOdidMsgType(plain, sizeof(plain)), -1);
    }
    {
        static NrfOdidGate<8, 250> g;   // mirrors main.cpp: 8 slots, ODID_REPEAT_MS 250
        uint8_t a[6], b[6]; rndMac(a); rndMac(b);
        chk("first Location from a MAC forwards", g.forward(a, 1, 0), true);
        chk("same type again inside 250 ms is held", g.forward(a, 1, 100), false);
        chk("a different type (BasicID) forwards at once", g.forward(a, 0, 120), true);
        chk("Location again differs from the last forwarded type: forwards", g.forward(a, 1, 140), true);
        chk("same type 110 ms after its forward is held", g.forward(a, 1, 250), false);
        chk("same type 250 ms after its forward goes through", g.forward(a, 1, 390), true);
        chk("another MAC is gated on its own", g.forward(b, 1, 100), true);
        uint32_t fwd = 0;
        for (uint32_t t = 1000; t < 2000; t += 20) if (g.forward(a, 1, t)) fwd++;
        chkInt("one MAC repeating one type at 20 ms: lines per second", fwd, 4);
        static uint8_t many[9][6];
        for (int i = 0; i < 9; i++) { rndMac(many[i]); g.forward(many[i], 1, 3000); }
        chk("a ninth MAC recycled the oldest slot: that MAC reads as new again", g.forward(many[0], 1, 3010), true);
    }
    {
        // A drone's reference cycle on one MAC at a 100 ms advert interval: BasicID serial, BasicID
        // CAA, then eight Locations. Both IDs must reach the S3 every cycle; keyed on message type
        // alone the CAA one is held on every cycle for ever (same type 0, 100 ms after the serial).
        static NrfOdidGate<8, 250> g;
        uint8_t d[6]; rndMac(d);
        uint8_t b1[34] = { 0x02, 0x01, 0x06, 0x1E, 0x16, 0xFA, 0xFF, 0x0D, 0x00, 0x02, 0x10 };
        uint8_t b2[34] = { 0x02, 0x01, 0x06, 0x1E, 0x16, 0xFA, 0xFF, 0x0D, 0x00, 0x02, 0x20 };
        uint8_t loc[34] = { 0x02, 0x01, 0x06, 0x1E, 0x16, 0xFA, 0xFF, 0x0D, 0x00, 0x12, 0x00 };
        uint32_t n1 = 0, n2 = 0, nl = 0;
        for (uint32_t c = 0; c < 10; c++) {
            const uint32_t t = c * 1000;
            if (g.forward(d, nrfOdidMsgType(b1, sizeof(b1)), t))       n1++;
            if (g.forward(d, nrfOdidMsgType(b2, sizeof(b2)), t + 100)) n2++;
            for (uint32_t k = 2; k < 10; k++)
                if (g.forward(d, nrfOdidMsgType(loc, sizeof(loc)), t + k * 100)) nl++;
        }
        chkInt("serial BasicID forwards every cycle (10 of 10)", n1, 10);
        chkInt("CAA BasicID forwards every cycle too (10 of 10)", n2, 10);
        chkInt("Location at 10 Hz is decimated to one per 250 ms (3 per cycle)", nl, 30);
    }

    printf(failures ? "\n  REGRESSION DETECTED (%d failure%s)\n\n" : "\n  all good (0 failures)\n\n",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
