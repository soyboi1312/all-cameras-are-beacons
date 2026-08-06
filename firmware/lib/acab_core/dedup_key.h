/*
 * ACAB - dedup table key derivation (pure, no platform deps).
 *
 * Extracted from acab_scanner.cpp 2026-08-06 so the offline-buffer rollback tests can exercise the
 * REAL function instead of a copy. It was previously mirrored byte-for-byte inside a host test,
 * which is the "one decision written in two places" shape this codebase keeps getting bitten by.
 *
 * WHY THE KEY IS NOT ALWAYS THE MAC, which is the whole reason this matters: a Remote ID drone is
 * keyed by a hash of its UAS ID, deliberately, because drones rotate MACs across both radios and a
 * MAC-keyed entry would treat one aircraft as an endless stream of new devices.
 *
 * That special case caused a real evidence-loss bug. Offline-buffer claims are made under THIS key,
 * but the queue-failure rollback looked the entry up by d.mac. For drones the two never match, so
 * the rollback silently refused and the record stayed marked "already buffered" for the whole
 * capture generation - the exact loss the rollback exists to prevent, surviving for exactly the
 * device class the key was special-cased for. The fix copies the key at claim time; see
 * acab_scanner.cpp. If you change the derivation here, the claim and rollback stay consistent
 * automatically, which is the point of having one function.
 */
#ifndef ACAB_DEDUP_KEY_H
#define ACAB_DEDUP_KEY_H

#include <stdint.h>
#include "detection.h"

/// The 6-byte dedup key for a detection. Returns either `d.mac` or `scratch` (filled in), so the
/// caller must keep `scratch` alive as long as it uses the result - or copy the bytes out, which is
/// what the claim path does.
inline const uint8_t* acabDedupKey(const AcabDetection& d, uint8_t scratch[6]) {
    if (d.type == ACAB_DRONE && d.id[0]) {
        uint32_t h = 2166136261u;                  // FNV-1a over the UAS-ID
        for (const char* p = d.id; *p; ++p) { h ^= (uint8_t)*p; h *= 16777619u; }
        scratch[0] = (uint8_t)h;          scratch[1] = (uint8_t)(h >> 8);
        scratch[2] = (uint8_t)(h >> 16);  scratch[3] = (uint8_t)(h >> 24);
        scratch[4] = (uint8_t)d.id[0];    scratch[5] = 0xDD;   // tag byte, avoid MAC overlap
        return scratch;
    }
    return d.mac;
}

#endif // ACAB_DEDUP_KEY_H
