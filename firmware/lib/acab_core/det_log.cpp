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

static bool     gEnabled  = false;
static uint8_t  gKey[32];
static bool     gHaveKey  = false;
static uint32_t gEpochUnix = 0;    // app-pushed wall clock for this boot
static uint32_t gEpochAtMs = 0;    // millis() when that epoch arrived

// Serializes the seq-claim + ring-head update in detLogAppend, which runs from BOTH
// radio tasks (BLE on core 1, WiFi RX on core 0). Short critical section only - the
// encrypt + flash write happen outside it (flash ops must never run under a spinlock).
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
    d->lastSeen = s->whenMs;
    memcpy(d->id,   s->uasid, sizeof(s->uasid)); d->id[sizeof(s->uasid)]   = '\0';
    memcpy(d->name, s->name,  sizeof(s->name));  d->name[sizeof(s->name)]  = '\0';
}

// ---- public API ----
void detLogBegin() {
    gPart = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, PART_LABEL);
    if (!gPart) { gSlots = 0; return; }              // no data partition -> buffering unavailable
    gSlots = gPart->size / SLOT;

    // Boot scan: find the highest valid seq. Live window is the last gSlots seqs.
    uint32_t maxSeq = 0;
    StoredDet s;
    for (uint32_t i = 0; i < gSlots; i++) {
        if (!readSlot(i, &s)) continue;
        if (!slotValid(&s, i)) continue;
        if (s.seq > maxSeq) maxSeq = s.seq;
    }
    gHead   = maxSeq + 1;
    gOldest = (maxSeq > gSlots) ? (maxSeq - gSlots + 1) : 1;
    gDrain  = (gOldest > 0) ? gOldest - 1 : 0;

    // Persisted opt-in flag + monotonic boot counter, and the last-connect boot for auto-wipe.
    Preferences p; p.begin(NVS_NS, false);
    gEnabled = p.getBool("on", false);
    gBoot    = p.getUInt("boot", 0) + 1;
    p.putUInt("boot", gBoot);
    uint32_t lastConn = p.getUInt("lastconn", gBoot);
    p.end();

    // Auto-wipe: undrained across too many reboots -> erase.
    if (maxSeq > 0 && (gBoot - lastConn) >= WIPE_AFTER_BOOTS) detLogClear();
}

void detLogSetEnabled(bool on) {
    if (on == gEnabled) return;
    gEnabled = on;
    Preferences p; p.begin(NVS_NS, false); p.putBool("on", on); p.end();
    if (!on) detLogClearKey();                       // stop capturing; forget the key
}
bool detLogEnabled() { return gEnabled; }

void detLogSetKey(const uint8_t key[32]) { memcpy(gKey, key, 32); gHaveKey = true; }
void detLogClearKey() { memset(gKey, 0, 32); gHaveKey = false; }
bool detLogHaveKey() { return gHaveKey; }

void detLogSetEpoch(uint32_t unixSec) { gEpochUnix = unixSec; gEpochAtMs = millis(); }

void detLogAppend(const AcabDetection& d) {
    if (!gEnabled || !gHaveKey || gSlots == 0) return;
    if (acabBleClientConnected()) return;            // only buffer while the app is away

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
    s.count  = d.count;
    strncpy(s.uasid, d.id,   sizeof(s.uasid));       // drone identity (truncated)
    strncpy(s.name,  d.name, sizeof(s.name));

    cryptPayload(&s);                                // encrypt payload in place
    s.crc = crc16((const uint8_t*)&s + ENC_OFF, ENC_LEN);   // CRC over ciphertext
    writeSlot(slotOf(seq), &s);
}

void detLogStartDrain(uint32_t lastSeq) {
    if (gSlots == 0) return;
    // Resume from the app's cursor, but never before the oldest record still in the ring.
    uint32_t floor = (gOldest > 0) ? gOldest - 1 : 0;
    gDrain    = (lastSeq > floor) ? lastSeq : floor;
    gDraining = (gDrain + 1 < gHead);
    Preferences p; p.begin(NVS_NS, false); p.putUInt("lastconn", gBoot); p.end();  // reset auto-wipe timer
}

bool detLogDraining() { return gDraining; }

bool detLogNextForDrain(DetLogReplay* out) {
    if (!gDraining || gSlots == 0) { gDraining = false; return false; }
    while (gDrain + 1 < gHead) {
        uint32_t seq = ++gDrain;
        if (seq < gOldest) continue;                 // evicted since the cursor was set
        StoredDet s;
        if (!readSlot(slotOf(seq), &s)) continue;
        if (!slotValid(&s, slotOf(seq)) || s.seq != seq) continue;  // empty / overwritten

        cryptPayload(&s);                            // decrypt in place
        unpackToDetection(&s, &out->d);
        out->seq = seq;
        // Absolute time only for same-boot records once we have this boot's epoch anchor.
        if (s.bootCount == gBoot && gEpochUnix && gEpochAtMs) {
            uint32_t agoMs = (gEpochAtMs > s.whenMs) ? (gEpochAtMs - s.whenMs) : 0;
            out->atUnix = gEpochUnix - agoMs / 1000;
            out->approx = false;
        } else {
            out->atUnix = 0;
            out->approx = true;                      // prior boot / no epoch -> order by seq
        }
        return true;
    }
    gDraining = false;
    return false;                                    // drain complete
}

void detLogClear() {
    if (gSlots == 0) return;
    esp_partition_erase_range(gPart, 0, gPart->size);   // REAL erase of the whole ring
    gHead = 1; gOldest = 1; gDrain = 0; gDraining = false;
    // Advance the generation so post-clear records (which restart at seq=1) never reuse an
    // AES-CTR nonce (bootCount:seq) from the records we just erased - reuse would XOR two
    // plaintexts under one keystream. Each record stores its own bootCount cleartext, so
    // replay still decrypts. Matters for the runtime {clearlog} command; harmless on the
    // boot-time auto-wipe path (no key/records present yet).
    gBoot++;
    Preferences p; p.begin(NVS_NS, false); p.putUInt("boot", gBoot); p.end();
}

uint32_t detLogCount() { return (gHead > gOldest) ? (gHead - gOldest) : 0; }
