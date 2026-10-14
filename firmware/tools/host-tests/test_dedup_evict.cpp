// Host regression test for the dedup eviction tenure tiers (dedup_evict.h).
//
// dedupFind in acab_scanner.cpp is never host-compiled, so the ORDER is pinned here: nearby devices
// leave the table first, then trackers, then (by age alone) everything that carries a signature. The
// bug this guards is the old flat LRU, under which a crowd of rotating tracker keys evicted a real
// camera between its sightings and re-admitted every tracker before its 60 s dwell completed.
// test_sink_claim.cpp pins that dedupFind actually compares acabDedupEvictRank.
#include "../../lib/acab_core/dedup_evict.h"
#include <cstdio>

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool got, bool want) {
    gRun++; if (got != want) gFail++;
    printf("  %-58s %s\n", name, got == want ? "PASS" : "**FAIL**");
}

int main() {
    printf("\n=== dedup eviction tiers ===\n");
    const uint8_t nearby  = acabDedupEvictRank(ACAB_NEARBY_DEVICE);
    const uint8_t tracker = acabDedupEvictRank(ACAB_TRACKER);
    const uint8_t sig     = acabDedupEvictRank(ACAB_FLOCK_CAMERA);
    chk("a nearby device leaves before a tracker", nearby < tracker, true);
    chk("a tracker leaves before a Flock camera", tracker < sig, true);

    // Every other value of the enum, ACAB_UNKNOWN and the retired 6 included, outlives a tracker,
    // and all of them share ONE rank so age alone decides among signature entries: a Flock must not
    // silently outrank a drone or a body cam, or the other way round.
    bool allOutliveTracker = true, allOutliveNearby = true, allShareOneRank = true;
    for (int t = 0; t < ACAB_TYPE_COUNT; t++) {
        const AcabDeviceType type = (AcabDeviceType)t;
        if (type == ACAB_NEARBY_DEVICE || type == ACAB_TRACKER) continue;
        const uint8_t r = acabDedupEvictRank(type);
        if (!(r > tracker)) allOutliveTracker = false;
        if (!(r > nearby))  allOutliveNearby  = false;
        if (r != sig)       allShareOneRank   = false;
    }
    chk("every signature type outlives a tracker", allOutliveTracker, true);
    chk("every signature type outlives a nearby device", allOutliveNearby, true);
    chk("signature types share one rank (age decides among them)", allShareOneRank, true);
    chk("the three tiers are exactly 0 / 1 / 2", nearby == 0 && tracker == 1 && sig == 2, true);

    printf(gFail ? "\n  REGRESSION DETECTED (%d of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
