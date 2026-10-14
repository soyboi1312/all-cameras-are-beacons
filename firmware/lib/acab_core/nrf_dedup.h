/*
 * ACAB - the nRF52840 co-processor's per-MAC forward window (pure, host-tested).
 *
 * The dual-radio board hears BLE only through the nRF, and this table is the ONLY BLE dedup on
 * that board: a MAC the window suppresses never reaches the S3. It runs inside the Bluefruit scan
 * callback with the radio paused, once per advert the air delivers, so its cost per call is the
 * scan duty cycle. nrf-ble-scan/src/main.cpp owns the sizes (DEDUP_TBL, DEDUP_WINDOW_MS,
 * PEAK_JUMP_DB, DEDUP_PROBE) and the long note on why the window must stay keyed on the MAC alone.
 * The template parameters carry k-names so those macros cannot expand into them.
 *
 * Open addressing, linear probe from the FNV-1a home slot, at most kProbe slots per call:
 *   - a hit inside the window suppresses unless the reading beat this window's best by
 *     kPeakJumpDb; every forward restarts the window and re-seeds the peak;
 *   - a miss inserts at the first empty-or-expired slot within kProbe of home, else evicts the
 *     oldest BY AGE (now - lastMs, so the millis() wrap at 49.7 days is harmless) within kProbe.
 * Nothing is ever placed beyond kProbe from its home, so a lookup that stops there is exact, and
 * an empty slot still ends a chain because slots are reused in place and never emptied. The old
 * table walked to the first empty slot, which after modest churn was never: every first-seen
 * MAC then probed all 2048 slots with the radio paused.
 *
 * ponytail: a window whose kProbe slots are all live evicts a live MAC, which then forwards once
 * more on its next advert (one extra line, no loss). That needs kProbe MACs seen inside one window
 * hashing into the same kProbe-slot run; raise kProbe or kTbl if a dense capture shows the
 * forwarded count climbing faster than the distinct-MAC count.
 *
 * Below the table: the Remote ID bypass of that window (nrfOdidMsgType + NrfOdidGate), which is
 * the other forward decision the scan callback makes, and the only one that can be forced by a
 * hostile advertiser.
 */
#ifndef ACAB_NRF_DEDUP_H
#define ACAB_NRF_DEDUP_H

#include <stdint.h>
#include <string.h>

struct NrfSeen { uint8_t mac[6]; uint32_t lastMs; int8_t peak; bool used; };

// FNV-1a over the 6 MAC bytes; the caller masks it to the pow2 table size for the home slot.
static inline uint32_t nrfMacHash(const uint8_t* mac) {
    uint32_t h = 2166136261u;
    for (int i = 0; i < 6; i++) { h ^= mac[i]; h *= 16777619u; }
    return h;
}

template <uint32_t kTbl, uint32_t kWindowMs, int kPeakJumpDb, uint32_t kProbe>
struct NrfDedup {
    static_assert((kTbl & (kTbl - 1)) == 0, "kTbl must be a power of two (home slot is a mask)");
    static_assert(kProbe >= 1 && kProbe <= kTbl, "kProbe must fit the table");

    NrfSeen tbl[kTbl];

    // True = mac was forwarded within the window and has not gained kPeakJumpDb on its best
    // reading since (skip it). False = forward; the entry is recorded or refreshed first.
    // probes (optional) receives the number of slots examined, for the host suite's bound check;
    // the device call passes nothing and the inlined branch folds away.
    bool seen(const uint8_t* mac, uint32_t now, int8_t rssi, uint32_t* probes = 0) {
        const uint32_t h = nrfMacHash(mac);
        int      slot = -1;         // first empty-or-expired slot in the window (insert point)
        int      oldest = -1;       // oldest live slot in the window (eviction fallback)
        uint32_t oldestAge = 0;
        uint32_t n = 0;
        while (n < kProbe) {
            const int idx = (int)((h + n) & (kTbl - 1));
            NrfSeen& e = tbl[idx];
            n++;
            if (!e.used) {                      // empty slot ends the chain: nothing is placed past one
                if (slot < 0) slot = idx;
                break;
            }
            if (memcmp(e.mac, mac, 6) == 0) {
                if (probes) *probes = n;
                if (now - e.lastMs < kWindowMs && rssi - e.peak < kPeakJumpDb) return true;
                e.lastMs = now;                 // forward: restart the window
                e.peak   = rssi;                // new window, new approach: never hold an old pass's peak
                return false;
            }
            const uint32_t age = now - e.lastMs;
            if (slot < 0 && age >= kWindowMs) slot = idx;              // reclaim an expired slot in place
            if (oldest < 0 || age > oldestAge) { oldest = idx; oldestAge = age; }
        }
        if (probes) *probes = n;
        NrfSeen& e = tbl[slot >= 0 ? slot : oldest];   // window full of live MACs: evict the oldest by age
        memcpy(e.mac, mac, 6);
        e.lastMs = now;
        e.peak   = rssi;
        e.used   = true;
        return false;
    }
};

// Remote ID gate key when this advert carries a Remote ID message, else -1. The key is the ASTM
// F3411 / OpenDroneID message type (the high nibble of the first message byte), except that a
// BasicID (type 0) returns 16 + its IDType (the high nibble of the second message byte,
// ODID_BasicID_encoded in opendroneid.h): F3411 lets one drone broadcast TWO BasicIDs, a serial
// number plus a CAA registration or session ID, in consecutive adverts, and the S3's trackAddId
// (drone_detect.cpp) wants both, so the gate must see them as two keys or it holds the second one
// on every cycle. The number never leaves the nRF. The signature is a Service-Data AD (type 0x16)
// for Service UUID 0xFFFA (little-endian FA FF) with app code 0x0D, then a one-byte counter, then
// the message. Walks every AD structure instead of assuming a fixed offset, matching the ESP32's
// droneRidBLE in drone_detect.cpp (which reads the same byte as msg[0] & 0xF0), so a drone whose
// advert opens with a Flags structure is still recognised. Signature bytes are from the public
// spec. Only the signature is read; the decode stays on the ESP32.
static inline int nrfOdidMsgType(const uint8_t* payload, uint16_t len) {
    if (!payload || len < 6) return -1;
    for (uint16_t i = 0; (uint32_t)i + 1 < len; i = (uint16_t)(i + 1u + payload[i])) {
        const uint8_t adLen = payload[i];
        if (adLen == 0 || (uint32_t)i + 1 + adLen > len) break;
        if (payload[i + 1] == 0x16 && adLen >= 6 &&
            payload[i + 2] == 0xFA && payload[i + 3] == 0xFF &&
            payload[i + 4] == 0x0D) {
            const int t = payload[i + 6] >> 4;                       // adLen >= 6 puts byte i+6 inside the AD
            return (t == 0 && adLen >= 7) ? 16 + (payload[i + 7] >> 4) : t;   // adLen >= 7: i+7 inside too
        }
    }
    return -1;
}

// Rate limit on the Remote ID window bypass, per MAC and gate key (nrfOdidMsgType): forward when
// the key differs from the last one forwarded for this MAC or kRepeatMs have passed. A drone's
// interleaved BasicIDs / Location / System / OperatorID all arrive, while one advertiser repeating
// a stub at 20 ms costs the UART one line per kRepeatMs instead of one per advert. Slots recycle
// round-robin.
// ponytail: kSlots MACs, linear scan, last key only. A flood that alternates two keys on one MAC
// still passes every advert, and one that rotates MACs passes once per MAC (as the main window
// already does for any new MAC, so no worse than baseline). A per-key bitmask per slot or a global
// token bucket closes that if a capture ever shows it. The other side of "last key only": a second
// DIFFERENT message of one type inside kRepeatMs is held on every cycle, not merely decimated.
// BasicID, the only such pair the S3 consumes, is keyed by IDType above; what is still held is
// Auth pages (type 2, which the S3's fillFromODID never reads) and same-type refreshes such as
// Location at more than 4 Hz.
template <uint32_t kSlots, uint32_t kRepeatMs>
struct NrfOdidGate {
    struct Last { uint8_t mac[6]; uint8_t type; uint32_t ms; };
    Last     last[kSlots];
    uint32_t next;

    bool forward(const uint8_t* mac, int type, uint32_t now) {
        for (uint32_t i = 0; i < kSlots; i++) {
            Last& e = last[i];
            if (memcmp(e.mac, mac, 6) != 0) continue;
            if (e.type == (uint8_t)type && now - e.ms < kRepeatMs) return false;
            e.type = (uint8_t)type;
            e.ms   = now;
            return true;
        }
        Last& e = last[next++ % kSlots];
        memcpy(e.mac, mac, 6);
        e.type = (uint8_t)type;
        e.ms   = now;
        return true;
    }
};

#endif
