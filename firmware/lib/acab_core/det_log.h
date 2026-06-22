/*
 * ACAB - Offline detection buffer (det_log).
 *
 * Captures detections to a raw-flash ring while the app is disconnected, then
 * replays them (acknowledged, via INDICATE) when the app reconnects. Locked design
 * decisions (2026-06-20, after a full validation pass - see docs/ble-protocol.md):
 *
 *   - OPT-IN: default OFF, master switch persisted to NVS. The app turns it on.
 *     The project's posture is "collects nothing"; a flash of geotagged sightings is
 *     a new at-rest exposure, so it is off until the user opts in.
 *   - ENCRYPTED AT REST: the sensitive payload is AES-CTR encrypted with a 32-byte
 *     key the app pushes on connect. The board holds the key in RAM ONLY and never
 *     persists it, so a seized board's flash dump is ciphertext. A reboot loses the
 *     key, so buffering pauses until the app reconnects and re-pushes it; records
 *     written under the same app key (across boots) stay decryptable on replay.
 *   - AUTO-WIPE: records left undrained past a threshold are really erased, so a
 *     board out of its owner's hands self-cleans (clearlog needs the bonded phone in
 *     hand, which you do not have during a seizure).
 *   - RAW esp_partition RING (not a LittleFS file - LittleFS's copy-on-write fights
 *     fixed-offset slots): fixed 64B slots, slot = seq % N, APPEND-ONLY (one record
 *     per device per boot, gated on true first sighting, not on isNew which re-fires
 *     every 60s dedup gap).
 *
 * The append hook lives in the shared scanner funnel (acab_scanner.cpp
 * handleDetection), NOT in either build's onDetection, so it covers oui-spy AND
 * mesh-detect from one place. Both builds run the GATT service and are connectable.
 */
#ifndef ACAB_DET_LOG_H
#define ACAB_DET_LOG_H

#include "detection.h"
#include <stdint.h>
#include <stddef.h>

// One ring slot, fixed 64 bytes (static_assert enforced in det_log.cpp). seq,
// bootCount, and crc are CLEARTEXT so the boot scan can find the head and validate
// torn writes without the key; everything from whenMs down is the AES-CTR encrypted
// payload (nonce = bootCount:seq, unique per record).
struct __attribute__((packed)) StoredDet {
    uint32_t seq;          // monotonic: ring order + the app's sync cursor (cleartext)
    uint32_t bootCount;    // persisted monotonic boot counter, NOT random (cleartext)
    uint16_t crc;          // CRC16 over the encrypted payload; written LAST (cleartext)
    uint16_t pad;          // reserved / alignment
    // ---- encrypted payload (52 bytes) ----
    uint32_t whenMs;       // millis() at last sighting, this boot
    uint8_t  type, src, method, conf;
    uint8_t  mac[6];
    int16_t  rssi;
    int32_t  lat_e7, lon_e7;   // lat/lon * 1e7 (compact vs the live double)
    uint16_t count;
    char     uasid[20];        // drone UAS-ID: preserves drone identity on replay
    char     name[6];          // truncated label for non-drones (type carries the class)
};

// A decrypted record handed back to the BLE layer for one replay frame.
struct DetLogReplay {
    AcabDetection d;       // unpacked back into the live detection shape
    uint32_t seq;          // wire "seq"
    uint32_t atUnix;       // absolute capture time (unix seconds), or 0 when approx
    bool     approx;       // true => time unknown (prior boot / no epoch); order by seq
};

// --- lifecycle ---
void     detLogBegin();             // mount ring, scan for head (generation window),
                                    // bump+persist bootCount, run auto-wipe of stale records
void     detLogSetEnabled(bool on); // opt-in master switch (persisted to NVS)
bool     detLogEnabled();

// --- at-rest key: app-pushed on connect, RAM only, never persisted ---
void     detLogSetKey(const uint8_t key[32]);
void     detLogClearKey();          // forget the key (e.g. when buffering is disabled)
bool     detLogHaveKey();

// --- wall-clock anchor: app-pushed epoch for this boot (mirrors the GPS push) ---
void     detLogSetEpoch(uint32_t unixSec);

// --- capture: called from acab_scanner.cpp handleDetection while disconnected.
// No-op unless enabled AND a key is present AND this is the device's first sighting
// this boot (e->count == 0). ---
void     detLogAppend(const AcabDetection& d);

// --- replay: the BLE service owns the INDICATE stream and pulls records from here.
// detLogStartDrain sets the cursor to the app's lastSeq; detLogNextForDrain decrypts
// and unpacks the next record (returns false when the drain is complete). ---
void     detLogStartDrain(uint32_t lastSeq);
bool     detLogDraining();
bool     detLogNextForDrain(DetLogReplay* out);

// --- maintenance ---
void     detLogClear();             // REAL sector erase of the whole ring region
uint32_t detLogCount();             // stored record count (surfaced as status "buf")

#endif // ACAB_DET_LOG_H
