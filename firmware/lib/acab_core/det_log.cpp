/*
 * ACAB - Offline detection buffer (det_log) implementation. See det_log.h.
 *
 * Storage: a raw esp_partition ring over the 1.5MB "spiffs" data partition (NOT a
 * LittleFS file - LittleFS's copy-on-write fights fixed-offset slots). 64B slots,
 * slot index = (seq-1) % gSlots. APPEND-ONLY: each device is captured once per boot
 * (its true first sighting), so slots are never rewritten in place.
 *
 * Erase granularity is a 4KB sector (64 slots). When the write cursor enters a new
 * sector it erases it, evicting the oldest 64 records at once - acceptable for a
 * ring. Write order is payload-then-header so a torn write leaves seq=0xFFFFFFFF
 * (an empty slot), never a half-valid record.
 *
 * At rest the payload (whenMs..name) is AES-CTR encrypted with the app-pushed key;
 * seq/bootCount/crc stay cleartext so the boot scan works without the key. The CRC
 * is computed over the CIPHERTEXT, so torn writes are caught before any decrypt.
 */
#include "det_log.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_partition.h>
#include <mbedtls/aes.h>
#include <mbedtls/md.h>
#include <string.h>
#include <stddef.h>
#include "acab_ble_service.h"   // acabBleClientConnected()

static_assert(sizeof(StoredDet) == 64, "StoredDet must pack to exactly 64 bytes");

// ---- config ----
static const char*    NVS_NS     = "acab-buf";
static const char*    PART_LABEL = "spiffs";                 // reuse the 1.5MB data slot (v1)
static const size_t   SLOT       = sizeof(StoredDet);        // 64
static const size_t   SECTOR     = 4096;
static const size_t   PER_SECTOR = SECTOR / SLOT;            // 64 slots / sector
static const size_t   ENC_OFF    = offsetof(StoredDet, whenMs);
static const size_t   ENC_LEN    = SLOT - ENC_OFF;           // 52 encrypted bytes
// Boot-based auto-wipe: if the buffer sits across this many reboots without the app
// ever connecting to drain it, erase it (a board out of its owner's hands self-cleans).
// This is a no-RTC proxy for the "N hours" decision; an epoch-time refinement is a TODO.
static const uint32_t WIPE_AFTER_BOOTS = 6;

// ---- state ----
static const esp_partition_t* gPart = nullptr;
static uint32_t gSlots    = 0;     // total slots in the partition
static uint32_t gHead     = 1;     // next seq to write (seq starts at 1; 0/0xFFFFFFFF = empty slot)
static uint32_t gOldest   = 1;     // oldest live seq still in the ring
static uint32_t gBoot     = 0;     // persisted monotonic boot counter
static uint32_t gDrain    = 0;     // drain cursor: the next record sent has seq > gDrain
static bool     gDraining = false;

// Deferred physical wipe (see detLogClear): the logical clear is instant, then loop()
// (detLogEraseTick, pumped via acabBleDrainTick) erases the ring one 64KB block per pass so
// the NimBLE host task never eats the multi-second full-partition erase. The pending flag is
// ALSO persisted to NVS ("wipe") so a power loss mid-sweep resumes at boot instead of letting
// the boot scan resurrect not-yet-erased old-generation records (their seq/CRC still validate).
static volatile bool     gWipePending = false;
static volatile uint32_t gWipeNext    = 0;         // next partition offset to erase
static volatile uint32_t gWipeGen     = 0;         // bumped per detLogClear so a re-latch restarts the sweep
static portMUX_TYPE      gWipeMux     = portMUX_INITIALIZER_UNLOCKED;
static const uint32_t    WIPE_BLOCK   = 64 * 1024; // one flash block erase (~100-250ms) per tick

static bool     gEnabled  = false;
static uint8_t  gKey[32];
static bool     gHaveKey  = false;

// Truncated SHA-256 of the at-rest key, persisted to NVS INDEPENDENT of both gEnabled and the
// key itself, because the key-change wipe guard (detLogSetKey) has to fire in exactly the state
// where no key is held. Turning buffering off drops the key from RAM AND NVS but leaves every
// record in the ring, and a reboot reloads the key only while enabled - so a guard that compares
// against gKey is disarmed precisely when records outlive their key. A second or reinstalled
// phone then arrives with a NEW key, and since the slot CRC covers the CIPHERTEXT its records
// decrypt to noise that still validates. The fingerprint outlives both the disable and the
// reboot, and being a preimage-resistant hash that never leaves the board it discloses nothing
// a seized flash does not already have.
static uint8_t  gKeyFp[8];
static bool     gHaveKeyFp = false;
static uint32_t gEpochUnix = 0;    // app-pushed wall clock for this boot
static uint32_t gEpochAtMs = 0;    // millis() when that epoch arrived

// --- per-boot wall-clock anchors, PERSISTED ---------------------------------------------
// A buffered record stores whenMs (uptime at capture) + bootCount, never absolute time: the
// board has no RTC. Absolute time is reconstructed as anchor.epochUnix - (anchor.atMs - whenMs).
//
// The anchor used to live only in RAM, so it died at every reboot and EVERY record from a prior
// boot replayed as "time unknown". That is exactly the case that matters for evidence: a board
// left running unattended, whose battery dies or which power-cycles before you collect it.
// Persisting a small ring of anchors makes any boot the app ever connected during exactly
// datable, across any number of reboots in between.
//
// One anchor per boot, newest wins (a later connect in the same boot has accumulated less
// crystal drift, so overwriting is strictly better). Written once per connect, so NVS wear is
// a non-issue. 8 entries x 12 bytes = 96 bytes.
#define ANCHOR_SLOTS 8
// Largest anchor-to-capture span we will still date. Deliberately TIGHT, at 7 days.
//
// millis() wraps every 49.7 days and the unsigned-subtract-then-cast below recovers the true signed
// delta only inside the +/-24.85-day signed range. Past that, a long POSITIVE span aliases to a
// negative one: +30 days reads as -19.7 days, which a loose bound would happily accept and date
// nineteen days before the anchor. A tight bound rejects those aliases, because their magnitude
// still lands outside the window even after wrapping.
//
// 7 days is far past any realistic collect-it-later interval, and erring tight is the safe
// direction: rejecting a legitimate long span merely drops the record to approx and lets the app
// BRACKET it, which is honest, whereas accepting an aliased one prints a wrong time and calls it
// measured. For an evidence log those two failures are not remotely equal.
//
// RESIDUAL, unfixable here: a span of very nearly a full 49.7-day wrap aliases to approximately
// zero and is indistinguishable from a fresh capture. No bound catches that. It needs a board up
// for seven straight weeks with undrained records, and the app-side bracketing is the backstop.
#define ANCHOR_SPAN_MAX_MS (7L * 24L * 60L * 60L * 1000L)
struct BootAnchor { uint32_t boot; uint32_t epochUnix; uint32_t atMs; };
static BootAnchor gAnchors[ANCHOR_SLOTS];
static uint8_t    gAnchorNext = 0;   // round-robin write cursor

static void anchorsLoad() {
    Preferences p; p.begin(NVS_NS, true);
    if (p.getBytesLength("anch") == sizeof(gAnchors)) p.getBytes("anch", gAnchors, sizeof(gAnchors));
    gAnchorNext = p.getUChar("anchn", 0) % ANCHOR_SLOTS;
    p.end();
}

static void anchorsSave() {
    Preferences p; p.begin(NVS_NS, false);
    p.putBytes("anch", gAnchors, sizeof(gAnchors));
    p.putUChar("anchn", gAnchorNext);
    p.end();
}

// Record (or refresh) the anchor for `boot`. Reuses an existing slot for the same boot so one
// long session cannot evict the other seven boots' anchors.
static void anchorPut(uint32_t boot, uint32_t epochUnix, uint32_t atMs) {
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++) {
        if (gAnchors[i].boot == boot && gAnchors[i].epochUnix) {
            gAnchors[i].epochUnix = epochUnix; gAnchors[i].atMs = atMs;
            anchorsSave(); return;
        }
    }
    gAnchors[gAnchorNext] = { boot, epochUnix, atMs };
    gAnchorNext = (uint8_t)((gAnchorNext + 1) % ANCHOR_SLOTS);
    anchorsSave();
}

static const BootAnchor* anchorFor(uint32_t boot) {
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++)
        if (gAnchors[i].boot == boot && gAnchors[i].epochUnix) return &gAnchors[i];
    return nullptr;
}

// Serializes the seq-claim + ring-head update in detLogAppend. As of the PERF-2 hardening
// pass the append is driven from the single scanner sink task (the flash write moved off the
// radio hot path), so this is effectively uncontended now; it is kept as a cheap guard in
// case a second caller is ever added. Short critical section only - the encrypt + flash write
// happen outside it (flash ops must never run under a spinlock).
static portMUX_TYPE gAppendMux = portMUX_INITIALIZER_UNLOCKED;

// ---- low-level helpers ----
static uint16_t crc16(const uint8_t* p, size_t n) {       // CRC-16/CCITT-FALSE
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++) c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

// AES-CTR over the encrypted payload, in place. CTR is symmetric, so the same call
// encrypts and decrypts. Nonce = bootCount(4):seq(4):0(8), unique per record.
static void cryptPayload(StoredDet* s) {
    if (!gHaveKey) return;
    uint8_t nc[16]; memset(nc, 0, sizeof(nc));
    memcpy(nc,     &s->bootCount, 4);
    memcpy(nc + 4, &s->seq,       4);
    mbedtls_aes_context ctx; mbedtls_aes_init(&ctx);
    mbedtls_aes_setkey_enc(&ctx, gKey, 256);   // CTR always uses the encrypt key
    uint8_t strm[16]; size_t off = 0;
    uint8_t* p = (uint8_t*)s + ENC_OFF;
    mbedtls_aes_crypt_ctr(&ctx, ENC_LEN, &off, nc, strm, p, p);
    mbedtls_aes_free(&ctx);
}

// SHA-256 of the key, truncated to gKeyFp. Uses the generic mbedtls_md API, which is stable
// across the mbedtls 2.x/3.x rename the ESP32 cores straddle (same reason ota_update.cpp does).
// False on a crypto failure, in which case the caller leaves the stored fingerprint alone
// rather than overwriting a good one with nothing.
static bool keyFingerprint(const uint8_t key[32], uint8_t out[8]) {
    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    uint8_t digest[32];
    if (!info || mbedtls_md(info, key, 32, digest) != 0) return false;
    memcpy(out, digest, 8);
    return true;
}

// Last line of defence on the drain. The slot CRC is over the CIPHERTEXT, so a record written
// under a DIFFERENT key passes validation and only turns to noise after cryptPayload. The
// fingerprint wipe in detLogSetKey should have erased those already; if anything ever slips
// through, noise must not reach the app, which files and maps whatever it is handed (random
// MACs, +/-214 degrees). So drop records whose decrypted fields cannot be real. Free on a good
// record, and it catches garbage with probability ~1 - 1e-6.
static bool plausibleRecord(const StoredDet* s) {
    if (s->type >= ACAB_TYPE_COUNT) return false;
    if (s->src > SRC_REMOTEID) return false;
    if (s->method > M_WATCHLIST) return false;
    if (s->conf > 100) return false;
    if (s->lat_e7 < -900000000  || s->lat_e7 > 900000000)  return false;
    if (s->lon_e7 < -1800000000 || s->lon_e7 > 1800000000) return false;
    return true;
}

static inline uint32_t slotOf(uint32_t seq) { return (seq - 1) % gSlots; }

static bool readSlot(uint32_t idx, StoredDet* s) {
    return esp_partition_read(gPart, (size_t)idx * SLOT, s, SLOT) == ESP_OK;
}

// A slot holds a valid current-generation record iff: seq is set, it maps back to
// this physical slot, and the CRC over the (still-encrypted) payload matches.
static bool slotValid(const StoredDet* s, uint32_t idx) {
    if (s->seq == 0 || s->seq == 0xFFFFFFFF) return false;
    if (slotOf(s->seq) != idx) return false;
    return crc16((const uint8_t*)s + ENC_OFF, ENC_LEN) == s->crc;
}

// Payload first, then the 12B header (seq/bootCount/crc/pad). A torn write leaves
// the header erased (seq=0xFFFFFFFF), so the slot reads as empty rather than half-valid.
static void writeSlot(uint32_t idx, const StoredDet* s) {
    if (idx % PER_SECTOR == 0)                              // entering a sector: erase it first
        esp_partition_erase_range(gPart, (size_t)idx * SLOT, SECTOR);
    esp_partition_write(gPart, (size_t)idx * SLOT + ENC_OFF, (const uint8_t*)s + ENC_OFF, ENC_LEN);
    esp_partition_write(gPart, (size_t)idx * SLOT,           s,                           ENC_OFF);
}

// Decrypt-in-place must already have happened; map the stored fields back to a live
// detection so the BLE layer can serialize it exactly like a fresh hit.
static void unpackToDetection(const StoredDet* s, AcabDetection* d) {
    acabInit(d, (AcabDeviceType)s->type, (AcabSource)s->src, s->mac, s->rssi);
    d->method     = (AcabMethod)s->method;
    d->confidence = s->conf;
    d->lat   = (double)s->lat_e7 / 1e7;
    d->lon   = (double)s->lon_e7 / 1e7;
    d->count = s->count;
    d->gpsAgeMs = (uint32_t)s->gpsAgeSec * 1000;
    d->lastSeen = s->whenMs;
    memcpy(d->id,   s->uasid, sizeof(s->uasid)); d->id[sizeof(s->uasid)]   = '\0';
    memcpy(d->name, s->name,  sizeof(s->name));  d->name[sizeof(s->name)]  = '\0';
}

// ---- public API ----
void detLogBegin() {
    gPart = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, PART_LABEL);
    if (!gPart) { gSlots = 0; return; }              // no data partition -> buffering unavailable
    gSlots = gPart->size / SLOT;

    // A wipe latched by detLogClear() but cut short by a power loss must be honoured BEFORE
    // trusting the boot scan: not-yet-erased old-generation slots still carry a valid seq/CRC,
    // so the scan would resurrect exactly the records the wipe promised to destroy (the
    // seizure posture in det_log.h). Re-arm the deferred sweep and skip the scan - the ring's
    // contents are condemned either way, and detLogAppend holds off until the sweep completes.
    {
        Preferences p; p.begin(NVS_NS, true);
        if (p.getBool("wipe", false)) { gWipeNext = 0; gWipePending = true; }
        p.end();
    }

    // Boot scan: find the highest valid seq. Live window is the last gSlots seqs.
    uint32_t maxSeq = 0;
    if (!gWipePending) {
        StoredDet s;
        for (uint32_t i = 0; i < gSlots; i++) {
            if (!readSlot(i, &s)) continue;
            if (!slotValid(&s, i)) continue;
            if (s.seq > maxSeq) maxSeq = s.seq;
        }
    }
    gHead   = maxSeq + 1;
    gOldest = (maxSeq > gSlots) ? (maxSeq - gSlots + 1) : 1;
    gDrain  = (gOldest > 0) ? gOldest - 1 : 0;

    // Persisted opt-in flag + monotonic boot counter, and the last-connect boot for auto-wipe.
    Preferences p; p.begin(NVS_NS, false);
    gEnabled = p.getBool("on", false);
    // Reload a persisted at-rest key so deploy-and-leave buffering survives a reboot
    // instead of going keyless until the app reconnects (see the SECURITY note in det_log.h).
    if (gEnabled && p.getBytesLength("key") == 32) { p.getBytes("key", gKey, 32); gHaveKey = true; }
    // The fingerprint reload is deliberately NOT gated on gEnabled or on the key above: the
    // records it protects survive a disable and a reboot, so the guard must too (see gKeyFp).
    if (p.getBytesLength("keyfp") == sizeof(gKeyFp)) {
        p.getBytes("keyfp", gKeyFp, sizeof(gKeyFp));
        gHaveKeyFp = true;
    }
    gBoot    = p.getUInt("boot", 0) + 1;
    p.putUInt("boot", gBoot);
    uint32_t lastConn = p.getUInt("lastconn", gBoot);
    p.end();
    // Reload the persisted per-boot wall-clock anchors. This is what lets a record captured in an
    // EARLIER boot still replay with an exact time, which is the whole point of persisting them.
    anchorsLoad();

    // Auto-wipe: undrained across too many reboots -> erase.
    if (maxSeq > 0 && (gBoot - lastConn) >= WIPE_AFTER_BOOTS) detLogClear();
}

void detLogSetEnabled(bool on) {
    if (on == gEnabled) return;
    gEnabled = on;
    Preferences p; p.begin(NVS_NS, false);
    p.putBool("on", on);
    if (on && gHaveKey) p.putBytes("key", gKey, 32);   // persist a key that arrived before enable
    p.end();
    if (!on) detLogClearKey();                         // stop capturing; forget the key (RAM + NVS)
}
bool detLogEnabled() { return gEnabled; }

void detLogSetKey(const uint8_t key[32]) {
    // Records are encrypted under whatever key was active when each was written, and the
    // slot CRC is over CIPHERTEXT, so a mismatched key still passes the CRC and would
    // decrypt old records to GARBAGE on drain. If a DIFFERENT key arrives while records
    // are buffered, those records are no longer decryptable, so wipe them rather than
    // ship garbage. Normal reconnects push the same per-device key (no-op); this fires
    // on a genuine key change (a new / reinstalled phone re-bonding a deployed board).
    //
    // Compared against the PERSISTED FINGERPRINT, never against gKey: gKey is empty in exactly
    // the cases that matter (buffering turned off, or a reboot while off, both of which keep
    // every record), so a gHaveKey-conditioned guard cannot fire there. See gKeyFp. Erasing on
    // disable instead is NOT the answer: the original phone still holds its key, so its records
    // stay legitimately drainable, and a buffer toggled off mid-drain would silently truncate
    // the user's own replay.
    uint8_t fp[8];
    bool haveFp = keyFingerprint(key, fp);
    if (haveFp && gHaveKeyFp && memcmp(gKeyFp, fp, sizeof(fp)) != 0 && detLogCount() > 0) detLogClear();
    memcpy(gKey, key, 32);
    gHaveKey = true;
    Preferences p; p.begin(NVS_NS, false);
    if (haveFp) { memcpy(gKeyFp, fp, sizeof(fp)); gHaveKeyFp = true; p.putBytes("keyfp", gKeyFp, sizeof(gKeyFp)); }
    // Persist the KEY ITSELF only while buffering is enabled, so it never sits in flash while
    // buffering is off (the app pushes the key on every connect, including when off). When
    // on, this is the deploy-and-leave reboot-survival path; SECURITY TRADEOFF: a seized
    // board's flash then yields the key (see det_log.h). A key that arrives before the
    // enable is re-persisted by detLogSetEnabled(true).
    if (gEnabled) p.putBytes("key", gKey, 32);
    p.end();
}
void detLogClearKey() {
    memset(gKey, 0, 32);
    gHaveKey = false;
    // gKeyFp deliberately SURVIVES this, in RAM and in NVS. Dropping the key does not drop the
    // records it encrypted, so the fingerprint is the only thing left that can recognise a
    // different phone's key arriving for them (see gKeyFp).
    Preferences p; p.begin(NVS_NS, false); p.remove("key"); p.end();
}
bool detLogHaveKey() { return gHaveKey; }

void detLogSetEpoch(uint32_t unixSec) {
    gEpochUnix = unixSec; gEpochAtMs = millis();
    // Persist it against THIS boot, so records captured in this boot stay datable even if the
    // board reboots before the app next connects.
    anchorPut(gBoot, gEpochUnix, gEpochAtMs);
}

void detLogAppend(const AcabDetection& d) {
    if (!gEnabled || !gHaveKey || gSlots == 0) return;
    if (acabBleClientConnected()) return;            // only buffer while the app is away
    if (gWipePending) return;                        // deferred wipe still sweeping: a record written now could be erased moments later

    // Atomically claim this record's seq and advance the ring under a spinlock, so two
    // radio tasks appending at once can't collide on a slot or lose a head update. The
    // encrypt + flash write happen AFTER the lock (flash must not run under a spinlock).
    uint32_t seq;
    portENTER_CRITICAL(&gAppendMux);
    seq = gHead++;
    if (gHead - gOldest > gSlots) gOldest = gHead - gSlots;  // ring evicted the oldest
    portEXIT_CRITICAL(&gAppendMux);

    StoredDet s; memset(&s, 0, sizeof(s));
    s.seq       = seq;
    s.bootCount = gBoot;
    s.whenMs    = d.lastSeen ? d.lastSeen : millis();
    s.type = (uint8_t)d.type; s.src = (uint8_t)d.src;
    s.method = (uint8_t)d.method; s.conf = d.confidence;
    memcpy(s.mac, d.mac, 6);
    s.rssi   = d.rssi;
    s.lat_e7 = (int32_t)(d.lat * 1e7);
    s.lon_e7 = (int32_t)(d.lon * 1e7);
    s.gpsAgeSec = (d.gpsAgeMs / 1000 > 0xFFFF) ? 0xFFFF : (uint16_t)(d.gpsAgeMs / 1000);
    s.count  = d.count;
    strncpy(s.uasid, d.id,   sizeof(s.uasid));       // drone identity (truncated)
    strncpy(s.name,  d.name, sizeof(s.name));

    cryptPayload(&s);                                // encrypt payload in place
    s.crc = crc16((const uint8_t*)&s + ENC_OFF, ENC_LEN);   // CRC over ciphertext
    writeSlot(slotOf(seq), &s);
}

void detLogStartDrain(uint32_t lastSeq) {
    if (gSlots == 0) return;
    // A cursor at/above gHead is exact proof of a generation reset (the board only ever issues
    // seqs < gHead): a board-side wipe the phone never saw (auto-wipe after undrained reboots,
    // or the key-change wipe) restarted seq at 1 while the app kept its old cursor. Without
    // this clamp gDrain = lastSeq arms nothing - no begin/end sentinel, no error - and new
    // records stay undeliverable until the new generation climbs past the stale cursor
    // (months), with status "buf" growing the whole time. Rebase to the ring floor instead;
    // the {"hist":"begin"} sentinel carries "from" so the app can rebase its own cursor.
    if (lastSeq >= gHead) lastSeq = 0;
    // Resume from the app's cursor, but never before the oldest record still in the ring.
    uint32_t floor = (gOldest > 0) ? gOldest - 1 : 0;
    gDrain    = (lastSeq > floor) ? lastSeq : floor;
    gDraining = (gDrain + 1 < gHead);
    Preferences p; p.begin(NVS_NS, false); p.putUInt("lastconn", gBoot); p.end();  // reset auto-wipe timer
}

bool detLogDraining() { return gDraining; }

// Abort an in-flight drain (link dropped mid-replay). The next reconnect must re-arm via
// detLogStartDrain (the app's {sync}) rather than resume from a stale cursor with no
// {"hist":"begin"} lead-in. Idempotent; leaves gDrain where it was (the {sync} rebases it).
void detLogStopDrain() { gDraining = false; }

bool detLogNextForDrain(DetLogReplay* out) {
    if (!gDraining || gSlots == 0) { gDraining = false; return false; }
    while (gDrain + 1 < gHead) {
        uint32_t seq = ++gDrain;
        if (seq < gOldest) continue;                 // evicted since the cursor was set
        StoredDet s;
        if (!readSlot(slotOf(seq), &s)) continue;
        if (!slotValid(&s, slotOf(seq)) || s.seq != seq) continue;  // empty / overwritten

        cryptPayload(&s);                            // decrypt in place
        if (!plausibleRecord(&s)) continue;          // wrong-key noise: the CRC is over ciphertext, so it got this far
        unpackToDetection(&s, &out->d);
        out->seq = seq;
        // Absolute time from THIS RECORD'S boot anchor, not just the current boot's. Anchors are
        // persisted (see anchorPut), so a record survives any number of reboots between capture and
        // collection and stays exactly datable, as long as the app connected at least once during
        // the boot that captured it. That is the evidence case: a board left running, whose battery
        // dies before you come back for it.
        // Always hand up whenMs + bootCount regardless, so the app can BRACKET a record from a boot
        // that was never anchored ("after the last anchored time of boot N, before the first of
        // boot N+1") instead of showing a bare "time unknown".
        out->whenMs    = s.whenMs;
        out->bootCount = s.bootCount;
        const BootAnchor* a = anchorFor(s.bootCount);
        if (a) {
            // SIGNED both ways. A capture can sit on EITHER side of its anchor:
            //   BEFORE it, for the boot being drained right now, because the app pushes a fresh
            //     epoch on connect and that refreshed anchor is newer than everything buffered.
            //   AFTER it, for every PRIOR boot. The board only buffers while disconnected, and it
            //     only anchors on a sync push, so a prior boot's records were necessarily captured
            //     after that boot's last sync. This is not the rare case, it is ALL of them.
            // The first version of this only handled the backward direction and clamped the other
            // to zero, which silently dated every prior-boot record AT its anchor and still called
            // it non-approx. A board that collected for eight hours after you walked away and then
            // lost power replayed those eight hours all stamped with the moment you last synced,
            // presented as measured. Strictly worse than the pre-anchor behaviour, which at least
            // reported approx and let the app bracket it.
            // Uptime is monotonic within a boot, so forward reconstruction is exactly as sound as
            // backward; there is no reboot between the anchor and the capture, that is what the
            // bootCount match guarantees.
            // Unsigned subtract then cast is the wrap-correct signed difference, so a millis()
            // rollover between anchor and capture still yields the right delta as long as the true
            // span is under the 24.85-day signed range. Beyond ANCHOR_SPAN_MAX_MS we cannot tell a
            // wrap from a genuinely huge gap, so we decline to date it rather than guess.
            int32_t deltaMs = (int32_t)(s.whenMs - a->atMs);
            if (deltaMs > -ANCHOR_SPAN_MAX_MS && deltaMs < ANCHOR_SPAN_MAX_MS) {
                out->atUnix = (uint32_t)((int64_t)a->epochUnix + (int64_t)deltaMs / 1000);
                out->approx = false;
            } else {
                out->atUnix = 0;
                out->approx = true;                  // uptime span implausible -> let the app bracket
            }
        } else {
            out->atUnix = 0;
            out->approx = true;                      // unanchored boot -> app brackets it by seq/boot
        }
        return true;
    }
    gDraining = false;
    return false;                                    // drain complete
}

void detLogClear() {
    if (gSlots == 0) return;
    // LOGICAL clear now, PHYSICAL erase deferred. This runs on the NimBLE host task (the
    // {"clearlog"} config write and detLogSetKey's key-change wipe), where the old synchronous
    // full-partition erase (~24 64KB block erases, each a cache-off stall for BOTH cores) froze
    // GATT and scanning for seconds. Resetting the cursors is microseconds and immediately
    // restores the guarantees that matter: detLogCount() reads 0, and a {"sync"} later in the
    // same handshake arms nothing over the condemned records.
    gHead = 1; gOldest = 1; gDrain = 0; gDraining = false;
    // Advance the generation so post-clear records (which restart at seq=1) never reuse an
    // AES-CTR nonce (bootCount:seq) from the records being erased - reuse would XOR two
    // plaintexts under one keystream. Each record stores its own bootCount cleartext, so
    // replay still decrypts. Matters for the runtime {clearlog} command; harmless on the
    // boot-time auto-wipe path (no key/records present yet).
    gBoot++;
    // Persist the wipe latch BEFORE arming the in-RAM sweep: once this NVS commit lands, a
    // power loss resumes the erase in detLogBegin instead of resurrecting the ring.
    Preferences p; p.begin(NVS_NS, false);
    p.putUInt("boot", gBoot);
    p.putBool("wipe", true);
    p.end();
    portENTER_CRITICAL(&gWipeMux);
    gWipeGen++;          // a sweep already in flight restarts at offset 0 under the new latch
    gWipeNext = 0;
    gWipePending = true;
    portEXIT_CRITICAL(&gWipeMux);
}

// One chunk of a latched wipe: erase a single 64KB flash block per call. Runs on the loop
// task (pumped by acabBleDrainTick), NEVER the NimBLE host task - each block erase disables
// the flash cache for ~100-250ms, and chunking with a loop-pass gap between blocks keeps
// GATT, scanning, and the sink task live across the sweep instead of a device-wide stall.
void detLogEraseTick() {
    if (!gWipePending || gSlots == 0) return;
    portENTER_CRITICAL(&gWipeMux);
    uint32_t gen = gWipeGen;
    uint32_t off = gWipeNext;
    portEXIT_CRITICAL(&gWipeMux);
    uint32_t n = (uint32_t)gPart->size - off;
    if (n > WIPE_BLOCK) n = WIPE_BLOCK;
    if (n) esp_partition_erase_range(gPart, off, n);
    bool done = false;
    portENTER_CRITICAL(&gWipeMux);
    if (gWipeGen == gen) {           // no re-latch landed mid-erase; else the fresh sweep restarts at 0
        gWipeNext = off + n;
        if (gWipeNext >= gPart->size) { gWipePending = false; done = true; }
    }
    portEXIT_CRITICAL(&gWipeMux);
    if (done) { Preferences p; p.begin(NVS_NS, false); p.putBool("wipe", false); p.end(); }
}

bool detLogWipePending() { return gWipePending; }

uint32_t detLogCount() { return (gHead > gOldest) ? (gHead - gOldest) : 0; }

// Records still queued for the current drain (seq in (gDrain, gHead)). Valid after
// detLogStartDrain, which clamps gDrain to >= gOldest-1, so none of these are evicted and this
// equals exactly what the replay will send. 0 when no drain is armed / nothing is queued.
uint32_t detLogPendingDrain() { return (gHead > gDrain + 1) ? (gHead - 1 - gDrain) : 0; }

// Next seq the armed drain will send (gDrain + 1). Carried as "from" in the {"hist":"begin"}
// sentinel so the app can rebase its persisted cursor after a board-side wipe reset the seq
// generation (see the clamp in detLogStartDrain) - otherwise every reconnect re-replays the
// whole ring until the new generation climbs past the stale cursor.
uint32_t detLogDrainFrom() { return gDrain + 1; }
