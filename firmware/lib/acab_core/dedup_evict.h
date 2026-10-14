/*
 * ACAB - dedup table eviction tenure (pure, no platform deps).
 *
 * dedupFind (acab_scanner.cpp) evicts when the ACAB_DEDUP_MAX-entry table holds no free slot. The
 * rank below decides WHO goes first; elapsed age (now - lastSeen, wrap-correct) breaks ties within a
 * rank. The lowest rank is evicted first:
 *
 *   0  ACAB_NEARBY_DEVICE  Desert keys every phone in range and each MAC rotation mints a fresh key.
 *   1  ACAB_TRACKER        Tile, SmartTag and separated Find My keys rotate too, and a crowd can hold
 *                          more than ACAB_DEDUP_MAX of them. Ranked beside cameras (the old LRU),
 *                          that crowd evicted a real camera between its sightings (re-alerting and
 *                          re-buffering it) and re-admitted every tracker before its
 *                          TRACKER_ALERT_DEBOUNCE_MS dwell completed, so the `alerted` edge never fired.
 *   2  everything else     cameras, drones, body cams, glasses, netcam, watched.
 *
 * So a non-tracker signature entry is never evicted while a tracker entry exists, and a tracker is
 * never evicted while a nearby-device entry exists. Pure so test_dedup_evict.cpp can pin the order;
 * run.sh's header-only branch picks this file up by its stem.
 */
#ifndef ACAB_DEDUP_EVICT_H
#define ACAB_DEDUP_EVICT_H

#include <stdint.h>
#include "detection.h"

inline uint8_t acabDedupEvictRank(AcabDeviceType type) {
    if (type == ACAB_NEARBY_DEVICE) return 0;
    if (type == ACAB_TRACKER)       return 1;
    return 2;
}

#endif // ACAB_DEDUP_EVICT_H
