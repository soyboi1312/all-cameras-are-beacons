/*
 * ACAB - Offline detection buffer (det_log).
 *
 * Captures detections to a raw-flash ring while the app is disconnected, then
 * replays them (unacknowledged NOTIFY; seq + hist:end count let the app spot drops
 * and re-sync) when the app reconnects. Locked design
 * decisions (2026-06-20, after a full validation pass - see docs/ble-protocol.md):
 *
 *   - OPT-IN: default OFF, master switch persisted to NVS. The app turns it on.
 *     The project's posture is "collects nothing"; a flash of geotagged sightings is
 *     a new at-rest exposure, so it is off until the user opts in.
 *   - ENCRYPTED AT REST: the sensitive payload is AES-CTR encrypted with a 32-byte key
 *     the app pushes on connect. The key is PERSISTED to NVS while buffering is enabled
 *     (and erased when it's turned off), so a deploy-and-leave board keeps buffering
 *     across reboots instead of going keyless. TRADEOFF: a seized board's flash now
 *     yields the key, so the at-rest buffer is decryptable - it is NOT ciphertext-only.
 *     The remaining guards are the opt-in default (off) + the auto-wipe of records left
 *     undrained across reboots; flash-encryption / encrypted NVS would restore the
 *     seized-board protection.
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
    uint16_t gpsAgeSec;    // age (s) of the GPS fix used for lat/lon (cleartext; 0 = fresh/none)
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
    bool     approx;       // true => this boot was never anchored; the app brackets it
    // Always populated, even when approx. The board has no RTC, so an absolute time is ALWAYS
    // reconstructed as anchor.epochUnix - (anchor.atMs - whenMs). Sending the raw inputs lets the
    // app verify that reconstruction, redo it against its own anchor history (which survives board
    // reboots and factory resets), and bracket an unanchored boot between the neighbouring
    // anchored ones instead of showing a bare "time unknown".
    uint32_t whenMs;       // millis() at capture, relative to bootCount's boot
    uint32_t bootCount;    // which boot session captured it
};

// --- lifecycle ---
void     detLogBegin();             // mount ring, scan for head (generation window),
                                    // bump+persist bootCount, run auto-wipe of stale records
void     detLogSetEnabled(bool on); // opt-in master switch (persisted to NVS)
bool     detLogEnabled();

// --- at-rest key: app-pushed on connect. Held in RAM, and persisted to NVS while buffering
// is enabled so a deploy-and-leave board survives a reboot (the TRADEOFF above). A truncated
// SHA-256 of it is persisted UNCONDITIONALLY: buffered records outlive the key (a disable
// erases the key but not the ring), and the fingerprint is what detects a different phone's
// key arriving for them, which would otherwise decrypt them to noise that passes the CRC. ---
void     detLogSetKey(const uint8_t key[32]);
void     detLogClearKey();          // forget the key (e.g. when buffering is disabled); keeps the fingerprint
bool     detLogHaveKey();

// --- wall-clock anchor: app-pushed epoch for this boot (mirrors the GPS push) ---
void     detLogSetEpoch(uint32_t unixSec);

// --- capture: called from acab_scanner.cpp handleDetection while disconnected.
// No-op unless enabled AND a key is present AND this is the device's first sighting
// this boot (e->count == 0). ---
void     detLogAppend(const AcabDetection& d);

// --- replay: the BLE service owns the NOTIFY stream and pulls records from here.
// Delivery is UNACKNOWLEDGED notify; reliability is the per-record seq plus the {"hist":"end","n"}
// count, which let the app spot a gap and re-sync (it is NOT an acknowledged INDICATE stream).
// detLogStartDrain sets the cursor to the app's lastSeq; detLogNextForDrain decrypts
// and unpacks the next record (returns false when the drain is complete). ---
void     detLogStartDrain(uint32_t lastSeq);
bool     detLogDraining();
void     detLogStopDrain();   // abort an in-flight drain on a link drop; next {sync} re-arms it
bool     detLogNextForDrain(DetLogReplay* out);

// --- maintenance ---
void     detLogClear();             // logical clear now; REAL erase of the whole ring deferred, chunked across loop ticks
uint32_t detLogCount();             // stored record count (surfaced as status "buf")
uint32_t detLogPendingDrain();      // records queued for the CURRENT drain (valid after
                                    // detLogStartDrain; = what the replay will actually send)

#endif // ACAB_DET_LOG_H
