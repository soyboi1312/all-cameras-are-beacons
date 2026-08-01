/*
 * ACAB - Unified scanner implementation.
 *
 * Concurrency (same WiFi-promiscuous + NimBLE combo sky-spy proved out on the
 * XIAO ESP32-S3):
 *   - BLE scan runs in its own FreeRTOS task (bleScanTask).
 *   - The WiFi promiscuous RX callback runs in the WiFi driver task.
 *   - Both funnel through handleDetection(), which grabs a short critical
 *     section just to touch the dedup table, then calls the sink outside it.
 */
#include "acab_scanner.h"
#include "flock_detect.h"
#include "axon_detect.h"
#include "drone_detect.h"
#include "tracker_detect.h"
#include "glasses_detect.h"
#include "police_detect.h"
#include "netcam_detect.h"
#include "desert_detect.h"
#include "det_log.h"
#include "acab_ble_service.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <atomic>
#include <stdlib.h>   // qsort for the sorted ignore/watch lists

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static AcabScannerConfig  gCfg;
static AcabDetectionSink  gSink = nullptr;
static AcabCmdSink        gCmdSink = nullptr;   // dual-radio: mirror radio cmds to the co-processor
static NimBLEScan*        gScan = nullptr;
static QueueHandle_t      gSinkQ = nullptr;   // detections handed off to sinkTask

static portMUX_TYPE       gDedupMux = portMUX_INITIALIZER_UNLOCKED;
static std::atomic<uint32_t> gTotal{0};      // both radios write it, so atomic
static std::atomic<uint32_t> gBleSeen{0};    // raw BLE adverts seen (diagnostic)
static std::atomic<uint32_t> gWifiSeen{0};   // raw 802.11 mgmt frames seen (diagnostic)
static volatile bool      gBleEnabled = true;   // app-toggleable BLE scan
static volatile bool      gWifiEnabled = true;  // app-toggleable WiFi scan

static double gSelfLat = 0, gSelfLon = 0;
static bool   gSelfGPSValid = false;

// Dedup table -------------------------------------------------------------
// One entry per device we've recently seen, so we don't re-report it every advert.
struct DedupEntry {
    bool          used;
    AcabDeviceType type;
    uint8_t       mac[6];
    uint32_t      firstSeen;
    uint32_t      lastSeen;
    uint16_t      count;
    uint32_t      loggedGen;   // capture generation this entry last buffered in (0 = never)
    bool          alerted;     // tracker buzzer debounce: has the post-debounce alert fired yet
    int16_t       hnext;       // next entry index in this slot's hash bucket chain (-1 = end)
};
// NOT sized to hold every device Desert mode sees, and it cannot be: entries are only ever
// dropped by eviction (there is no time-based expiry), and phones rotate their randomized MAC
// every ~15 min, so the key population is unbounded over a deploy and no fixed table survives
// it. The table is a recent-sighting cache that thrashes by design in a dense area; what makes
// that safe is the eviction priority in dedupFind() plus the type gate on buffering, NOT the
// size. Raising this only moves the thrash point.
#define ACAB_DEDUP_MAX     256
#define ACAB_DEDUP_BUCKETS 256   // power of two; MAC-keyed hash index for O(1)-avg lookup
static DedupEntry gDedup[ACAB_DEDUP_MAX];
static int16_t    gDedupBucket[ACAB_DEDUP_BUCKETS];   // per-bucket head index into gDedup (-1 = empty)

// FNV-1a over (type, 6-byte mac). Computed OFF the lock (touches no shared state) so the
// interrupt-disabled critical section only does the short chain walk + slot mutation, not
// the old O(256) linear memcmp scan.
static inline uint32_t dedupHash(AcabDeviceType type, const uint8_t mac[6]) {
    uint32_t h = 2166136261u;
    h ^= (uint8_t)type; h *= 16777619u;
    for (int i = 0; i < 6; i++) { h ^= mac[i]; h *= 16777619u; }
    return h;
}

// BUZZER DEBOUNCE ONLY. This does NOT decide whether a tracker is following you, and the board
// cannot decide that: judging "following" needs your LOCATION OVER TIME and this board has no GPS
// and no wall clock. That call is made in the app, which has both. See docs/ble-protocol.md.
//
// What this does: hold the buzzer for the first minute of a tracker's life so a tag you drift past
// in a parking lot stays quiet, while the detection is still DELIVERED to the app immediately.
// Delivery and alerting are deliberately decoupled (see the gate below) , the app needs the early
// sightings to build its location trail, so suppressing delivery would blind the very thing that
// makes the judgement. The old code returned early here and the phone never saw those sightings.
//
// 60s, not the old 5s: five seconds silences nothing real. It is also not an attempt at a
// follow-me threshold, since Apple's own equivalent runs 8 hours by day and ~30 minutes at night
// against signals we do not have. 60s is simply longer than a traffic light next to a parked car.
// Trackers ONLY: other surveillance gear alerts on first sight, since a Flock/drone/body-cam you
// pass is worth knowing about immediately.
static const uint32_t TRACKER_ALERT_DEBOUNCE_MS = 60000;
// Offline-capture generation: bumped on each BLE disconnect so the first sighting of
// every device AFTER the app leaves buffers once more, not just once per boot.
static volatile uint32_t gCaptureGen = 1;

// Whitelist (app-pushed): MACs we drop silently - no report, beep, or mesh.
#define ACAB_IGNORE_MAX 256
static uint8_t      gIgnore[ACAB_IGNORE_MAX][6];
static volatile int gIgnoreCount = 0;
static portMUX_TYPE gIgnoreMux = portMUX_INITIALIZER_UNLOCKED;

// Ignore/watch MACs are kept sorted (memcmp order over the 6 bytes) so the radio path can
// binary-search them - O(log n) comparisons inside the spinlock instead of a linear O(256)
// memcmp scan with interrupts disabled on every advert. Writers (the config path) sort a
// scratch copy off the lock and publish it under the mux, so the sorted invariant holds for
// every locked read.
static int macCmp(const void* a, const void* b) { return memcmp(a, b, 6); }
static bool macInSorted(const uint8_t list[][6], int count, const uint8_t mac[6]) {
    int lo = 0, hi = count - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        int c = memcmp(list[mid], mac, 6);
        if (c == 0) return true;
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return false;
}
// Scratch for building a sorted list off the lock before publishing it under the mux. The
// config-write path (BLE GATT) is single-threaded, so one buffer serves both setters.
static uint8_t gMacSortScratch[ACAB_IGNORE_MAX][6];

static bool isIgnored(const uint8_t mac[6]) {
    bool hit;
    portENTER_CRITICAL(&gIgnoreMux);
    hit = macInSorted(gIgnore, gIgnoreCount, mac);   // sorted -> binary search, short ISR-off window
    portEXIT_CRITICAL(&gIgnoreMux);
    return hit;
}

// Watchlist (app-pushed): the inverse of the ignore list. A starred MAC alerts every time
// it is seen even with no signature match. Mirrors the ignore storage exactly.
#define ACAB_WATCH_MAX 256
static uint8_t      gWatch[ACAB_WATCH_MAX][6];
static volatile int gWatchCount = 0;
static portMUX_TYPE gWatchMux = portMUX_INITIALIZER_UNLOCKED;

static bool isWatched(const uint8_t mac[6]) {
    bool hit;
    portENTER_CRITICAL(&gWatchMux);
    hit = macInSorted(gWatch, gWatchCount, mac);   // sorted -> binary search, short ISR-off window
    portEXIT_CRITICAL(&gWatchMux);
    return hit;
}

// Persist the whitelist to NVS so it survives reboots - the app doesn't have to
// re-push it, and a board keeps ignoring known-friendly tags on its own.
static void saveIgnoreList() {
    Preferences p;
    p.begin("acab-ignore", false);
    p.putInt("n", gIgnoreCount);
    if (gIgnoreCount > 0) p.putBytes("macs", gIgnore, (size_t)gIgnoreCount * 6);
    p.end();
}

static void loadIgnoreList() {
    Preferences p;
    p.begin("acab-ignore", true);
    int n = p.getInt("n", 0);
    if (n < 0) n = 0;
    if (n > ACAB_IGNORE_MAX) n = ACAB_IGNORE_MAX;
    if (n > 0) p.getBytes("macs", gIgnore, (size_t)n * 6);
    p.end();
    gIgnoreCount = n;
    qsort(gIgnore, n, 6, macCmp);   // keep sorted for binary-search isIgnored (old blobs may be unsorted)
}

// Persist the watchlist to NVS so starred devices survive reboots (own namespace).
static void saveWatchList() {
    Preferences p;
    p.begin("acab-watch", false);
    p.putInt("n", gWatchCount);
    if (gWatchCount > 0) p.putBytes("macs", gWatch, (size_t)gWatchCount * 6);
    p.end();
}

static void loadWatchList() {
    Preferences p;
    p.begin("acab-watch", true);
    int n = p.getInt("n", 0);
    if (n < 0) n = 0;
    if (n > ACAB_WATCH_MAX) n = ACAB_WATCH_MAX;
    if (n > 0) p.getBytes("macs", gWatch, (size_t)n * 6);
    p.end();
    gWatchCount = n;
    qsort(gWatch, n, 6, macCmp);   // keep sorted for binary-search isWatched (old blobs may be unsorted)
}

// The entry for (type, mac), creating/evicting as needed. Caller holds gDedupMux and passes
// the precomputed bucket (dedupHash & mask). The common case (device already tracked) is an
// O(1)-average bucket-chain walk instead of the old O(256) linear memcmp scan, so far less
// runs with interrupts disabled; only a genuinely new device pays the O(256) free/oldest
// search (and only that path mutates the hash chains).
static DedupEntry* dedupFind(AcabDeviceType type, const uint8_t mac[6], uint32_t bucket) {
    // fast path: already tracked -> walk just this bucket's chain
    for (int16_t i = gDedupBucket[bucket]; i >= 0; i = gDedup[i].hnext) {
        DedupEntry* e = &gDedup[i];
        if (e->type == type && memcmp(e->mac, mac, 6) == 0) return e;
    }
    // not tracked yet: take a free slot, else evict the least-recently-seen entry. A signature
    // match outranks Desert's ACAB_NEARBY_DEVICE for tenure: Desert keys every phone in range
    // and each MAC rotation mints a fresh key, so an unfiltered LRU would spend the whole table
    // on one-shot phone entries and keep re-admitting (and so re-arming) the cameras/trackers
    // this exists to track. Evict the oldest NEARBY_DEVICE first, and only fall back to the
    // oldest entry overall once the table holds nothing but real matches.
    int freeIdx = -1, oldestIdx = -1, oldestNearbyIdx = -1;
    for (int i = 0; i < ACAB_DEDUP_MAX; i++) {
        DedupEntry* e = &gDedup[i];
        if (!e->used) { freeIdx = i; break; }
        if (oldestIdx < 0 || e->lastSeen < gDedup[oldestIdx].lastSeen) oldestIdx = i;
        if (e->type == ACAB_NEARBY_DEVICE &&
            (oldestNearbyIdx < 0 || e->lastSeen < gDedup[oldestNearbyIdx].lastSeen)) oldestNearbyIdx = i;
    }
    int idx = (freeIdx >= 0) ? freeIdx : (oldestNearbyIdx >= 0 ? oldestNearbyIdx : oldestIdx);
    DedupEntry* slot = &gDedup[idx];
    if (slot->used) {                                   // evicting: unlink from its old bucket chain
        uint32_t ob = dedupHash(slot->type, slot->mac) & (ACAB_DEDUP_BUCKETS - 1);
        int16_t* pp = &gDedupBucket[ob];
        while (*pp >= 0 && *pp != idx) pp = &gDedup[*pp].hnext;
        if (*pp == idx) *pp = slot->hnext;
    }
    slot->used = true;
    slot->type = type;
    memcpy(slot->mac, mac, 6);
    slot->firstSeen = 0;
    slot->lastSeen = 0;
    slot->count = 0;
    slot->loggedGen = 0;   // a reused slot re-arms capture for the new device
    slot->alerted = false; // and re-arms the tracker dwell gate
    slot->hnext = gDedupBucket[bucket];                 // link at the head of its bucket
    gDedupBucket[bucket] = (int16_t)idx;
    return slot;
}

// The sink runs on its own task so heavy work (serial, BLE notify, mesh UART) never runs
// inside the WiFi driver callback or the BLE scan task - the radios just enqueue and move
// on. The offline-buffer flash write rides the same task (PERF-2): its 4KB sector erase
// every 64 records used to run INLINE on the radio path and stall scanning, so it moved
// here. `buffer` = append this record to det_log; `deliver` = call the firmware sink. The two
// are separate flags because they gate on different things, not because both can be set at
// once in every combination: only a Desert ACAB_NEARBY_DEVICE is ever throttled to
// deliver=false, and that type is exactly the one the buffer refuses (see shouldBuffer), so a
// deliver=false item is now always buffer=false too and is dropped before the enqueue.
struct SinkItem { AcabDetection d; bool isNew; bool deliver; bool buffer; };

static void sinkTask(void*) {
    SinkItem it;
    for (;;) {
        if (xQueueReceive(gSinkQ, &it, portMAX_DELAY) != pdTRUE) continue;
        // flash write happens HERE, off both radio tasks. det_log no-ops when the app is
        // connected / buffering is disabled / no key - same guards as before, just now
        // evaluated on the sink task a beat later than at ingest.
        if (it.buffer) detLogAppend(it.d);
        if (it.deliver && gSink) gSink(it.d, it.isNew);
    }
}

// Drones rotate their MAC and broadcast on both radios, so key them by UAS-ID
// instead - the stable "one drone = one entry" identity. Everything else keys by
// MAC. Returns d.mac, or a hashed 6-byte key written into scratch.
static const uint8_t* dedupKey(const AcabDetection& d, uint8_t scratch[6]) {
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

// Desert-mode notify gate. Desert mode reports every device in range, so it
// emits a detection for every advert of every nearby device. Streaming all of
// them saturates the single BLE link and starves the inbound config-write path,
// so the app can't even turn the mode back off and the board looks locked up.
// Let a nearby device through only on its isNew edge (first sighting or a
// dedup-window refresh) and cap the burst rate, leaving the link headroom for
// commands. Real detections (Flock/drone/Axon/...) are rare and never gated.
#define ACAB_DESERT_MAX_NOTIFY_PER_SEC 20
static portMUX_TYPE gDesertMux = portMUX_INITIALIZER_UNLOCKED;
// Shared notify token bucket for the per-frame firehoses (Desert's every-advert path and the
// netcam opt-in's every-data-frame path). Repeat sightings never notify; new ones are capped.
static bool desertNotifyAllowed(bool isNew, uint32_t now) {
    if (!isNew) return false;   // repeat sighting inside the dedup window: don't stream it
    static uint32_t windowStart = 0;
    static uint16_t inWindow = 0;
    bool allow;
    portENTER_CRITICAL(&gDesertMux);
    if (now - windowStart >= 1000) { windowStart = now; inWindow = 0; }
    allow = inWindow < ACAB_DESERT_MAX_NOTIFY_PER_SEC;
    if (allow) inWindow++;
    portEXIT_CRITICAL(&gDesertMux);
    return allow;
}

// Where both radios converge.
static void handleDetection(AcabDetection& d, bool isReplay = false) {
    // Watchlist beats the ignore drop for the synthesized ACAB_WATCHED path: a starred
    // device alerts even if its MAC is also on the ignore list. A watched MAC that ALSO
    // matches a built-in signature keeps its specific type and so still honors the ignore
    // drop; the apps prevent that overlap by enforcing star/ignore exclusivity.
    if (d.type != ACAB_WATCHED && isIgnored(d.mac)) return;   // whitelisted by the app - drop silently
    acabApplyDurability(&d);        // cap an OUI-only hit on a randomized MAC (durability policy)

    // nRF black-box replay: deliver the recovered record to the app, but keep it OUT of
    // the live pipeline - no buzzer (onDetection skips it), no live dedup-table / gTotal
    // pollution, no re-buffering. See AcabDetection::replay.
    if (isReplay) {
        d.replay = true;
        // replay delivers to the app but never buffers (no re-buffering of recovered records)
        if (gSinkQ) { SinkItem it{d, false, true, false}; xQueueSend(gSinkQ, &it, 0); }
        return;
    }
    uint32_t now = millis();
    bool isNew;

    uint8_t keyScratch[6];
    const uint8_t* key = dedupKey(d, keyScratch);
    // hash the key OFF the lock (no shared state) so the critical section stays short
    uint32_t bucket = dedupHash(d.type, key) & (ACAB_DEDUP_BUCKETS - 1);

    portENTER_CRITICAL(&gDedupMux);
    DedupEntry* e = dedupFind(d.type, key, bucket);
    isNew = (e->count == 0) || (now - e->lastSeen > gCfg.dedupWindowMs);
    if (e->count == 0) e->firstSeen = now;
    e->lastSeen = now;
    if (e->count < 0xFFFF) e->count++;
    // Tracker BUZZER debounce. Silences the piezo for the first TRACKER_ALERT_DEBOUNCE_MS of a
    // tracker's life, and NOTHING ELSE , the detection is still delivered to the app on every
    // sighting from the very first one.
    //
    // This used to `return` early (see the deleted line below the critical section), which also
    // skipped the GPS stamp and the sink enqueue, so the phone never saw a sub-dwell tracker at
    // all. That was backwards: the app is the thing that decides whether a tag is FOLLOWING you,
    // it needs location-over-time to do it, and the early sightings are exactly the data it needs.
    // Suppressing delivery blinded the judgement it was meant to support.
    //
    // Mechanism: clear isNew while debouncing (the sink buzzes on isNew), so the row is delivered
    // silently. shouldBuffer stays gated on it so the offline flash ring does not fill with tags
    // you merely walked past.
    bool debouncing = false;
    if (d.type == ACAB_TRACKER) {
        if (now - e->firstSeen < TRACKER_ALERT_DEBOUNCE_MS) { debouncing = true; isNew = false; }
        else if (!e->alerted) { e->alerted = true; isNew = true; }
    }
    // Buffer a device once per capture generation: its first sighting this boot AND its
    // first sighting after each link drop (gCaptureGen bumps on disconnect), so capture
    // re-arms when the app leaves instead of firing only once per boot.
    // NEVER buffer a Desert ACAB_NEARBY_DEVICE. The offline buffer exists to capture
    // surveillance hits while the phone is away, and the ring is append-only with no
    // type filter of its own, so letting phones in lets them WRAP it: a dense area churns
    // the dedup table, every re-admitted phone comes back with loggedGen reset to 0 and so
    // reads as a first sighting again, and the resulting flood of duplicate phone records
    // evicts the real ALPR / body-cam records the user synced to get. Live delivery of
    // nearby devices is unaffected; only the flash ring is gated.
    bool shouldBuffer = !debouncing && d.type != ACAB_NEARBY_DEVICE && (e->loggedGen != gCaptureGen);
    if (shouldBuffer) e->loggedGen = gCaptureGen;
    d.firstSeen = e->firstSeen;
    d.lastSeen  = e->lastSeen;
    d.count     = e->count;
    portEXIT_CRITICAL(&gDedupMux);
    // (No early return for a debouncing tracker. It falls through to the GPS stamp and the sink
    // exactly like any other detection, just with isNew cleared so the buzzer stays quiet.)

    // Stamp non-drone hits with a GPS fix so buffered/offline records carry a location
    // (drones broadcast their own). Prefer a fresh onboard/forwarded fix; else fall back
    // to the LAST known phone fix however old, recording its age so the app can show
    // "location as of N ago".
    if (d.type != ACAB_DRONE && d.lat == 0 && d.lon == 0) {
        if (gSelfGPSValid) {
            d.lat = gSelfLat;
            d.lon = gSelfLon;
        } else {
            double la, lo; uint32_t ageMs = 0;
            if (acabBleGetPhoneGps(&la, &lo, 0xFFFFFFFFu, &ageMs)) {
                d.lat = la;
                d.lon = lo;
                d.gpsAgeMs = ageMs;
            }
        }
    }

    gTotal++;

    // Throttle the two per-frame firehoses so they can't saturate the BLE link. This is a
    // NOTIFY gate only: a throttled device is simply not delivered to the app. A nearby device
    // never sets shouldBuffer (see the type gate above), so a throttled one has nothing left to
    // do and drops out of the queue entirely below, which is also what keeps Desert's volume off
    // the buffer-bearing backpressure path. gTotal above still counts it either way.
    //
    // ACAB_NETCAM joins Desert here (2026-07-23). The netcam opt-in widens the promiscuous
    // filter to DATA frames and classifies EVERY delivered one, so a single streaming IP camera
    // produced one detection + one BLE notify per frame, orders of magnitude more than any
    // advert-based source. desertNotifyAllowed is the right gate for both: it drops repeat
    // sightings inside the dedup window outright and caps new ones at ACAB_DESERT_MAX_NOTIFY_PER_SEC.
    // A netcam loses nothing by it, since its OUI and vendor label are identical on every frame,
    // and the dedup window still lets it refresh (so the closest-approach pin keeps improving).
    // Buffering is deliberately NOT gated: a throttled netcam still records to the offline log.
    bool firehose = (d.type == ACAB_NEARBY_DEVICE || d.type == ACAB_NETCAM);
    bool deliver = !(firehose && !desertNotifyAllowed(isNew, now));

    // Hand off to the sink task: it (not this radio path) does the det_log flash write
    // (PERF-2) and calls the firmware sink. Only queue when there is something to do.
    if (gSinkQ && (deliver || shouldBuffer)) {
        SinkItem it{d, isNew, deliver, shouldBuffer};
        // buffer-bearing items get brief backpressure (~10ms) rather than a silent drop: shouldBuffer
        // committed loggedGen at ingest, so a dropped buffer item would be a non-retryable evidence
        // loss for this capture generation. deliver-only items still drop on overflow (a missed live
        // notify just re-arrives). the block only bites while the sink task is mid flash-erase.
        xQueueSend(gSinkQ, &it, shouldBuffer ? pdMS_TO_TICKS(10) : 0);
    }
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
// Clamp an attacker-sourced byte string to printable ASCII on copy (see the header).
// A crafted advert name / SSID / ODID id cannot smuggle control bytes into the JSON.
void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap) {
    if (!dst || cap == 0) return;
    size_t m = n;
    if (m > cap - 1) m = cap - 1;
    size_t j = 0;
    for (; j < m; j++) {
        uint8_t c = src ? src[j] : 0;
        dst[j] = (c >= 0x20 && c <= 0x7E) ? (char)c : '.';
    }
    dst[j] = 0;
}

// Pull the advertised local name (AD type 0x08 short / 0x09 complete) out of a BLE
// advert into name[outSz] for a synthesized watchlist hit. Empty if there is none.
static void bleWatchName(const uint8_t* adv, size_t advLen, char* name, size_t outSz) {
    name[0] = 0;
    if (!adv || !advLen) return;
    for (size_t i = 0; i + 1 < advLen; ) {
        uint8_t l = adv[i];
        if (l == 0 || i + 1 + (size_t)l > advLen) break;
        uint8_t t = adv[i + 1];
        if (t == 0x08 || t == 0x09) {                 // shortened / complete local name
            size_t n = (size_t)l - 1;
            if (n >= outSz) n = outSz - 1;
            acabSanitizeAscii(name, adv + i + 2, n, outSz);   // clamp to printable ASCII on ingest
            return;
        }
        i += (size_t)l + 1;
    }
}

// Is this advert one of OUR OWN boards? Two beacons in the same room (a test rig, or a
// user who owns two) otherwise flag each other forever as the strongest nearby device in
// range, burying real hits under a -20 dBm neighbour. Matched on our own advertising name
// rather than an OUI, because the OUI here is Espressif's and is shared with a vast amount
// of unrelated hardware. Only ever consulted AFTER the signature chain, see the call site.
// Covers the whole product family, not just this build's own name: the SKUs advertise
// different names ("beacon" on the dual-radio board, "ACAB" on oui-spy), so matching only
// gCfg.bleDeviceName would still leave a user who owns both, or a bench with both on it,
// staring at the other one pinned at the top of the nearby list.
static const char* const SELF_BLE_NAMES[] = { "beacon", "ACAB" };

static bool isSiblingBoard(const uint8_t* adv, size_t advLen) {
    char name[32];
    bleWatchName(adv, advLen, name, sizeof(name));
    if (!name[0]) return false;
    for (size_t i = 0; i < sizeof(SELF_BLE_NAMES) / sizeof(SELF_BLE_NAMES[0]); i++)
        if (strcmp(name, SELF_BLE_NAMES[i]) == 0) return true;
    // Belt and braces: a build configured with some other advertising name still filters itself.
    const char* self = gCfg.bleDeviceName;
    return self && *self && strcmp(name, self) == 0;
}

// Shared BLE classifier funnel: run every BLE detector on one advert (most-
// specific first) and push any match into handleDetection(). Called by the
// NimBLE scan callback below, and by a dual-radio build for adverts forwarded
// from a companion nRF52840 over UART. Counts toward acabScannerBleSeen().
void acabScannerIngestBLE(const uint8_t mac[6], const uint8_t* payload, size_t plen, int rssi, bool isReplay) {
    gBleSeen++;
#ifdef ACAB_DIAG
    // Ground-truth trace (bench/drive builds only): one line per LIVE advert, matched or not, with
    // the decoded local name if the advert carries one (AD 0x08/0x09) - the nRF-Connect-style name.
    // This is the SHARED path, so it fires for BOTH the S3's own scan (oui-spy) AND the nRF-
    // forwarded adverts (dual-radio board over UART) - the S3 onResult diag block does not.
    // Scan-response-only names appear here only in a -DACAB_ACTIVE_SCAN capture build (RF-loud).
    if (!isReplay) {
        char nm[32]; bleWatchName(payload, plen, nm, sizeof(nm));
        char line[240];
        int p = snprintf(line, sizeof(line),
                         "[ble] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\" adv=",
                         mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, nm);
        for (size_t k = 0; k < plen && p < (int)sizeof(line) - 3; k++)
            p += snprintf(line + p, sizeof(line) - p, "%02X", payload[k]);
        Serial.println(line);
    }
#endif
    AcabDetection d;
    // The BLE mfg company ID (SIG assigned #) rides in the advert payload, MAC-independent, so
    // grab it once and stamp it on whatever matches. It's the field the glasses/tracker detectors
    // key on; surfacing it lets the app show/log why a device did (or didn't) classify.
    const uint16_t companyId = acabBleCompanyId(payload, plen);
    // Try most-specific first: drone (standardised) -> Flock -> tracker -> glasses -> Axon, then
    // the broad Motorola/LE-gear OUI last so it never preempts a real match. The || chain
    // short-circuits at the first match, preserving that priority (only the winner fills `d`).
    bool matched = droneClassifyBLE(mac, payload, plen, rssi, &d)
                || flockClassifyBLE(mac, payload, plen, rssi, &d)
                || trackerClassifyBLE(mac, payload, plen, rssi, &d)
                || glassesClassifyBLE(mac, payload, plen, rssi, &d)
                || axonClassifyBLE(mac, payload, plen, rssi, &d)
                || policeClassifyBLE(mac, payload, plen, rssi, &d);
    // Watchlist (AFTER the built-in signatures so a real match keeps its specific type,
    // BEFORE desert): a user-starred MAC alerts even with no signature. Synthesize a
    // ACAB_WATCHED hit and run it through the normal pipeline. Carry the advert name.
    if (!matched && isWatched(mac)) {
        acabInit(&d, ACAB_WATCHED, SRC_BLE, mac, (int16_t)rssi);
        d.method     = M_WATCHLIST;   // exact-MAC user rule; NOT M_OUI, so durability leaves it at 100
        d.confidence = 100;
        bleWatchName(payload, plen, d.name, sizeof(d.name));
        matched = true;
    }
    // Our own sibling board, if any: drop it before Desert synthesises a nearby-device row.
    // Deliberately AFTER the whole signature chain and the watchlist, so a device that merely
    // names itself "beacon" is still fully classified by every real signature and can still be
    // starred; this only suppresses the generic Desert row. See isSiblingBoard().
    if (!matched && isSiblingBoard(payload, plen)) return;
    // Desert mode (LAST): catch every remaining device as a generic "nearby device".
    if (!matched) matched = desertClassifyBLE(mac, payload, plen, rssi, &d);
    if (!matched) return;
    if (companyId) d.companyId = companyId;   // stamp the BLE mfg company ID on the match
    handleDetection(d, isReplay);
}

class AcabAdvCallbacks : public NimBLEAdvertisedDeviceCallbacks {
public:
    void onResult(NimBLEAdvertisedDevice* dev) override {
        // NimBLE keeps the address little-endian and getNative() points at a
        // temporary, so copy it AND flip to human order (mac[0] = OUI byte), which
        // is what our OUI tables expect.
        NimBLEAddress addr = dev->getAddress();
        const uint8_t* nat = addr.getNative();
        if (!nat) return;
        uint8_t mac[6];
        for (int i = 0; i < 6; i++) mac[i] = nat[5 - i];

        int rssi = dev->getRSSI();
        uint8_t* payload = dev->getPayload();
        size_t   plen    = dev->getPayloadLength();

        // The per-advert "[ble] ... name=... adv=..." diag line now lives in the SHARED
        // acabScannerIngestBLE (below), so it covers the dual-radio UART path too, not just
        // this S3-only scan. It decodes the local name there. Nothing to log here.

#ifdef ACAB_DIAG
        // Watchlist (diag only): "Pigvision" is a candidate Flock BLE name we have not
        // field-confirmed yet, so it is deliberately NOT in the production name table.
        // Flag it loudly here; a real sighting is the signal to promote it into
        // FLOCK_NAME_PATTERNS (flock_signatures.h). Case-insensitive substring, no deps.
        {
            std::string nm = dev->getName();
            bool pig = false;
            for (const char* p = nm.c_str(); *p && !pig; p++) {
                const char* a = p; const char* w = "pigvision";
                while (*w) { char c = *a; if (c >= 'A' && c <= 'Z') c += 32; if (c != *w) break; a++; w++; }
                if (!*w) pig = true;
            }
            if (pig)
                Serial.printf("[ble] *** PIGVISION CANDIDATE *** %02X:%02X:%02X:%02X:%02X:%02X rssi=%d name=\"%s\"\n",
                              mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi, nm.c_str());
        }
#endif

        // Hand the advert to the shared classifier chain (kept in one place so the
        // dual-radio UART path runs the exact same detectors).
        acabScannerIngestBLE(mac, payload, plen, rssi);
    }
};

static void bleScanTask(void*) {
    for (;;) {
        if (gScan && gBleEnabled) {
            gScan->start(2, false);   // 2 s windows, then clear results and go again
            gScan->clearResults();
        } else {
            vTaskDelay(pdMS_TO_TICKS(200));
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// ---------------------------------------------------------------------------
// WiFi
// ---------------------------------------------------------------------------
#ifdef ACAB_DIAG_WIFI
// Bench diagnostic: log every beacon / probe-response (BSSID + SSID + RSSI), so a
// field test next to a pole-mounted camera can spot its WiFi presence, if any.
// Parsing + serial run off the promiscuous callback via a queue and task.
struct WifiDiagItem { uint8_t bssid[6]; int8_t rssi; char ssid[33]; };
static QueueHandle_t gWifiDiagQ = nullptr;
static void wifiDiagTask(void*) {
    WifiDiagItem it;
    for (;;)
        if (xQueueReceive(gWifiDiagQ, &it, portMAX_DELAY) == pdTRUE)
            Serial.printf("[wifi] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d ssid=\"%s\"\n",
                          it.bssid[0], it.bssid[1], it.bssid[2], it.bssid[3], it.bssid[4],
                          it.bssid[5], it.rssi, it.ssid);
}

// Flock Falcon Wi-Fi OUIs seen in the field (own captures, 2026-06),
// all Liteon allocations. Liteon is shared silicon = FP-prone (bench only); a
// production match needs the specific Falcon sub-OUI range, not the whole block.
static inline bool falconOui(const uint8_t* m) {
    return (m[0]==0xD8 && m[1]==0xF3 && m[2]==0xBC) ||   // D8:F3:BC
           (m[0]==0xC0 && m[1]==0x35 && m[2]==0x32) ||   // C0:35:32
           (m[0]==0x24 && m[1]==0xB2 && m[2]==0xB9) ||   // 24:B2:B9
           (m[0]==0xF4 && m[1]==0x6A && m[2]==0xDD);     // F4:6A:DD
}
#endif

// Compute + install the promiscuous frame filter. Production is MGMT-only (beacons + probe
// req/resp): data frames are a firehose whose CPU + 2.4GHz-coexistence cost we refuse to pay
// by default. We widen to DATA ONLY when the network-camera opt-in is on (its source-MAC OUI
// match needs data frames) or in a bench diag build. When the opt-in is off the driver never
// delivers a data frame at all, so the OFF path is genuinely zero-cost. Callable at runtime:
// netcamSetEnabled() invokes acabScannerRefreshWifiFilter() on every flip.
static void applyWifiPromiscFilter() {
    wifi_promiscuous_filter_t pf;
    uint32_t mask = WIFI_PROMIS_FILTER_MASK_MGMT;
    if (netcamIsEnabled()) mask |= WIFI_PROMIS_FILTER_MASK_DATA;   // opt-in camera data-frame OUI match
#ifdef ACAB_DIAG_WIFI
    mask |= WIFI_PROMIS_FILTER_MASK_DATA;                          // bench: also capture data frames
#endif
    pf.filter_mask = mask;
    esp_wifi_set_promiscuous_filter(&pf);
}

static void IRAM_ATTR wifiRxCallback(void* buf, wifi_promiscuous_pkt_type_t type) {
    if (!gWifiEnabled) return;
    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    const uint8_t* payload = pkt->payload;
    int len  = pkt->rx_ctrl.sig_len;
    int rssi = pkt->rx_ctrl.rssi;
    if (len < 24) return;

#ifdef ACAB_DIAG_WIFI
    // DATA frames: Falcon cams ride as WiFi clients (no "Flock-" beacon), so look for
    // a Falcon MAC OUI in any of the three address fields (addr1 @+4, addr2 @+10,
    // addr3 @+16) and log it. PROVISIONAL OUIs from own captures; Liteon is shared
    // silicon so this is FP-prone - bench validation only.
    if (type == WIFI_PKT_DATA && gWifiDiagQ) {
        static uint32_t gDataN = 0; gDataN++;
        const uint8_t* aa[3] = { payload + 4, payload + 10, payload + 16 };
        bool matched = false;
        for (int k = 0; k < 3; k++) {
            const uint8_t* m = aa[k];
            if (falconOui(m)) {
                WifiDiagItem it;
                memcpy(it.bssid, m, 6);
                it.rssi = (int8_t)rssi;
                memcpy(it.ssid, "DATA-FALCON", 12);
                xQueueSend(gWifiDiagQ, &it, 0);
                matched = true;
                break;
            }
        }
        if (!matched && (gDataN % 300) == 0) {   // sample: proves data frames are arriving
            WifiDiagItem it;
            memcpy(it.bssid, aa[1], 6);           // addr2 = source
            it.rssi = (int8_t)rssi;
            memcpy(it.ssid, "DATA-sample", 12);
            xQueueSend(gWifiDiagQ, &it, 0);
        }
    }
#endif

    // Production data-frame path: the ONLY thing we do with a data frame is the opt-in
    // network-camera OUI match. It is unreachable unless the user turned the toggle on
    // (the filter above is MGMT-only otherwise, so no data frame is ever delivered), and
    // even then the work is one cheap source-MAC OUI compare. We NEVER serial-log a data
    // frame in production (privacy + firehose). netcamClassifyWiFi self-gates on the toggle.
    if (type == WIFI_PKT_DATA) {
        AcabDetection dc;
        if (netcamClassifyWiFi(payload, len, /*isDataFrame=*/true, rssi, &dc)) handleDetection(dc);
        return;   // data frames never fall through to the mgmt classifiers
    }
    if (type != WIFI_PKT_MGMT) return;
    gWifiSeen++;

#ifdef ACAB_DIAG_WIFI
    // probe request (0x40): Falcon cams scan for networks as WiFi clients - match
    // their OUI in addr2 (the prober). Lighter path: we already receive mgmt frames.
    if (gWifiDiagQ && payload[0] == 0x40 && falconOui(payload + 10)) {
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);
        it.rssi = (int8_t)rssi;
        memcpy(it.ssid, "PROBE-FALCON", 13);
        xQueueSend(gWifiDiagQ, &it, 0);
    }
    // beacon (0x80) or probe-response (0x50): grab BSSID + SSID for the bench log
    if (gWifiDiagQ && (payload[0] == 0x80 || payload[0] == 0x50) && len >= 38) {
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);   // addr2 = transmitter / BSSID
        it.rssi = (int8_t)rssi;
        it.ssid[0] = 0;
        uint8_t sl = payload[37];            // SSID IE: tag at [36]==0, len at [37]
        if (payload[36] == 0x00 && sl <= 32 && 38 + sl <= len) {
            memcpy(it.ssid, payload + 38, sl); it.ssid[sl] = 0;
        }
        xQueueSend(gWifiDiagQ, &it, 0);      // non-blocking: drop on overflow
    }
#endif

    AcabDetection d;
    if (droneClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (flockClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    // Axon OUI on a mgmt frame (2026-07-31). Ordered BEFORE the Motorola proxy so that when a
    // frame could satisfy both, the specific named vendor wins over the broad gear guess.
    // In-car video (Axon Fleet) is a WiFi device, so before this an in-car system could only
    // ever land as a generic Nearby Device. Registry-sourced, UNVALIDATED on WiFi - the
    // rationale and the deliberately-lower confidence are documented in axon_detect.h.
    if (axonClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (policeClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    // Network-camera OUI on a mgmt frame (BONUS, opt-in): a branded IP camera acting as its
    // own AP (beacon/probe-resp BSSID) or probing (probe-req) shows its vendor OUI here on the
    // mgmt path we already inspect in production. Self-gates on the opt-in, so it is zero-cost
    // when off. The primary camera signal is the data-frame path above.
    if (netcamClassifyWiFi(payload, len, /*isDataFrame=*/false, rssi, &d)) { handleDetection(d); return; }
    // Watchlist (AFTER the built-in signatures, BEFORE desert): a user-starred MAC alerts
    // even with no signature. addr2 (payload+10) is the transmitter address. No name parse
    // is available on this path, so leave it empty. Runs through the normal pipeline.
    {
        const uint8_t* addr2 = payload + 10;
        if (isWatched(addr2)) {
            acabInit(&d, ACAB_WATCHED, SRC_WIFI, addr2, (int16_t)rssi);
            d.method     = M_WATCHLIST;   // exact-MAC user rule; NOT M_OUI, so durability leaves it at 100
            d.confidence = 100;
            handleDetection(d);
            return;
        }
    }
    // Desert mode (LAST): catch every remaining mgmt-frame source as a "nearby device".
    if (desertClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
}

// Channel 6 is the OpenDroneID Wi-Fi "social" channel - Remote-ID NAN/beacon
// frames live there, and sky-spy just parks on it for drones. A plain 1..13 sweep
// would sit on ch6 only ~8% of the time and miss a drone we drive past. So this
// sequence comes back to ch6 between every step (~50% dwell) while still touching
// all 13 (and favouring the 1/6/11 non-overlappers). That keeps Flock Wi-Fi
// covered too, since it can sit anywhere.
static const uint8_t WIFI_HOP_SEQ[] = {
    6, 1, 6, 11, 6, 2, 6, 3, 6, 4, 6, 5, 6, 7, 6, 8, 6, 9, 6, 10, 6, 12, 6, 13
};
static const int WIFI_HOP_SEQ_LEN = sizeof(WIFI_HOP_SEQ) / sizeof(WIFI_HOP_SEQ[0]);

// WiFi eco: seconds of promiscuous-OFF sleep inserted after each full channel sweep. 0 = off
// (continuous). Only 0/3/7/15 are offered; the setter snaps a stray value to the ladder so a bad
// write can't make a weird duty cycle. See the header for the tradeoff.
static volatile int gWifiEcoSec = 0;
static const char* WIFI_ECO_NS = "acab-wifi";
void acabScannerSetWifiEco(int sec) {
    int v = (sec <= 0) ? 0 : (sec <= 5) ? 3 : (sec <= 11) ? 7 : 15;
    gWifiEcoSec = v;
    Preferences p; p.begin(WIFI_ECO_NS, false); p.putInt("eco", v); p.end();
}
int acabScannerWifiEco() { return gWifiEcoSec; }
static void restoreWifiEco() {
    Preferences p; p.begin(WIFI_ECO_NS, true); gWifiEcoSec = p.getInt("eco", 0); p.end();
}

static void wifiHopTask(void*) {
    int idx = 0;
    for (;;) {
        if (gCfg.wifiChannelHop) {
            esp_wifi_set_channel(WIFI_HOP_SEQ[idx], WIFI_SECOND_CHAN_NONE);
            idx++;
            if (idx >= WIFI_HOP_SEQ_LEN) {
                idx = 0;
                // A full channel sweep just finished. If eco is on, drop the WiFi RX for
                // gWifiEcoSec before the next sweep - this is where the battery is saved (the
                // promiscuous RX is the board's biggest single draw). BLE keeps running throughout.
                // Skip while the WiFi toggle is off (its own promiscuous(false) owns the radio then),
                // and re-check both flags every 100ms so a config change interrupts the sleep early.
                int eco = gWifiEcoSec;
                if (eco > 0 && gWifiEnabled) {
                    esp_wifi_set_promiscuous(false);
                    uint32_t until = millis() + (uint32_t)eco * 1000;
                    while ((int32_t)(millis() - until) < 0 && gWifiEcoSec > 0 && gWifiEnabled)
                        vTaskDelay(pdMS_TO_TICKS(100));
                    if (gWifiEnabled) esp_wifi_set_promiscuous(true);   // never re-arm over a WiFi-off
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(gCfg.wifiHopIntervalMs));
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
AcabScannerConfig acabScannerDefaults() {
    AcabScannerConfig c;
    c.enableBLE        = true;
    c.enableWiFi       = true;
    c.initNimBLE       = true;
    c.bleDeviceName    = "ACAB";
    c.wifiChannelHop   = true;
    c.wifiFixedChannel = 6;
    c.wifiHopIntervalMs= 300;
    c.dedupWindowMs    = 60000;
    return c;
}

void acabScannerSetSelfGPS(double lat, double lon, bool valid) {
    gSelfLat = lat; gSelfLon = lon; gSelfGPSValid = valid;
}

// Re-arm offline capture: bump the generation so the next sighting of every device
// buffers once more. Called from the BLE disconnect callback (the app just left).
void acabScannerReArmCapture() {
    portENTER_CRITICAL(&gDedupMux);
    gCaptureGen++;
    portEXIT_CRITICAL(&gDedupMux);
}

// Single-writer discipline for the co-processor UART line stream. gCmdSink lines are emitted
// from the NimBLE host task (S0/S1 via config writes, DUMP/BCLR) AND the loop task (the
// deferred ignore mirror below, otaQuiesce's radio restore via the OTA watchdog), and two
// tasks inside Serial1.println at once can interleave bytes mid-line. Held per line only.
static SemaphoreHandle_t gCmdSinkMux = nullptr;
static void cmdSinkLine(const char* line) {
    if (!gCmdSink) return;
    if (gCmdSinkMux) xSemaphoreTake(gCmdSinkMux, portMAX_DELAY);
    gCmdSink(line);
    if (gCmdSinkMux) xSemaphoreGive(gCmdSinkMux);
}

// Deferred nRF ignore-list mirror (dual-radio). acabScannerSetIgnoreList runs inside the GATT
// config-write callback on the NimBLE host task, and streaming one paced 'IA' line per MAC
// there stalled every GATT op ~300ms on a full 256-entry list (the apps re-push the whole
// list on every single toggle). The commit now snapshots the sorted list here (its own buffer:
// gMacSortScratch is reused by the watchlist path) and acabScannerMirrorTick streams it from
// the loop task. A re-commit mid-stream atomically replaces the snapshot and restarts with a
// fresh 'IC', so a quick ignore-then-unignore never leaves the nRF filtering (= not
// forwarding) a MAC the user just un-ignored.
static uint8_t       gMirrorList[ACAB_IGNORE_MAX][6];
static int           gMirrorCount  = 0;
static int           gMirrorPos    = -1;    // -1 = 'IC' not yet sent; else next gMirrorList index
static volatile bool gMirrorActive = false;
static portMUX_TYPE  gMirrorMux    = portMUX_INITIALIZER_UNLOCKED;
static const int     MIRROR_LINES_PER_TICK = 8;   // ~160B/pass: well inside the nRF's 2KB ring

// Pump the deferred mirror: a few lines per loop pass (via acabBleDrainTick). No-op unless a
// commit is in flight, so single-radio builds pay one flag test.
void acabScannerMirrorTick() {
    if (!gCmdSink || !gMirrorActive) return;
    for (int i = 0; i < MIRROR_LINES_PER_TICK; i++) {
        bool ic = false, ia = false;
        uint8_t mac[6];
        portENTER_CRITICAL(&gMirrorMux);
        if (gMirrorActive) {
            if (gMirrorPos < 0)                 { ic = true; gMirrorPos = 0; }
            else if (gMirrorPos < gMirrorCount) { memcpy(mac, gMirrorList[gMirrorPos], 6); gMirrorPos++; ia = true; }
            else                                gMirrorActive = false;   // snapshot fully mirrored
        }
        portEXIT_CRITICAL(&gMirrorMux);
        if (ic) cmdSinkLine("IC");
        else if (ia) {
            char line[24];
            snprintf(line, sizeof(line), "IA %02X%02X%02X%02X%02X%02X",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
            cmdSinkLine(line);
        } else return;
        // pace the burst: a back-to-back 256-line stream can outrun the nRF's 2 KB RX
        // ring before its loop drains it. delay(1) opens a wire gap between lines;
        // Serial1.flush() would NOT help (it only waits on local TX, adds no gap).
        delay(1);
    }
}

void acabScannerSetIgnoreList(const uint8_t macs[][6], int count) {
    if (count < 0) count = 0;
    if (count > ACAB_IGNORE_MAX) count = ACAB_IGNORE_MAX;
    // sort a scratch copy OFF the lock (qsort must not run with interrupts disabled), then
    // publish it under the mux with one memcpy - same lock cost as before, but the radio
    // path can now binary-search it.
    for (int i = 0; i < count; i++) memcpy(gMacSortScratch[i], macs[i], 6);
    qsort(gMacSortScratch, count, 6, macCmp);
    portENTER_CRITICAL(&gIgnoreMux);
    if (count > 0) memcpy(gIgnore, gMacSortScratch, (size_t)count * 6);
    gIgnoreCount = count;
    portEXIT_CRITICAL(&gIgnoreMux);
    saveIgnoreList();   // persist outside the critical section - NVS writes are slow

    // Dual-radio: mirror the whitelist to the co-processor so it can skip forwarding
    // ignored MACs (the ESP32 still filters them regardless - this only trims UART).
    // DEFERRED to acabScannerMirrorTick (see above): pacing the burst here, on the NimBLE
    // host task, stalled all GATT traffic for the whole stream.
    if (gCmdSink) {
        portENTER_CRITICAL(&gMirrorMux);
        if (count > 0) memcpy(gMirrorList, gMacSortScratch, (size_t)count * 6);
        gMirrorCount  = count;
        gMirrorPos    = -1;      // restart: fresh 'IC', then the new snapshot
        gMirrorActive = true;
        portEXIT_CRITICAL(&gMirrorMux);
    }
}

void acabScannerSetWatchList(const uint8_t macs[][6], int count) {
    if (count < 0) count = 0;
    if (count > ACAB_WATCH_MAX) count = ACAB_WATCH_MAX;
    // sort off the lock, then publish under the mux (see acabScannerSetIgnoreList) so the
    // radio path can binary-search the watchlist.
    for (int i = 0; i < count; i++) memcpy(gMacSortScratch[i], macs[i], 6);
    qsort(gMacSortScratch, count, 6, macCmp);
    portENTER_CRITICAL(&gWatchMux);
    if (count > 0) memcpy(gWatch, gMacSortScratch, (size_t)count * 6);
    gWatchCount = count;
    portEXIT_CRITICAL(&gWatchMux);
    saveWatchList();   // persist outside the critical section - NVS writes are slow
    // No co-processor mirror: the watch check runs on the ESP32 over the same classifier
    // chain the dual-radio UART path feeds, so a forwarded advert is matched regardless.
    // (The co-proc only needs the ignore list, to trim what it forwards.)
}

uint32_t acabScannerTotalDetections() { return gTotal; }
uint32_t acabScannerBleSeen()  { return gBleSeen; }
uint32_t acabScannerWifiSeen() { return gWifiSeen; }

// Co-processor (nRF) stats, fed by the dual-radio UART path.
static std::atomic<uint32_t> gCoAdv{0}, gCoFwd{0}, gCoBb{0};
static std::atomic<uint32_t> gCoLastRx{0};   // millis() of the last nRF UART line (0 = never)
static volatile bool gCoScan = false, gHasCo = false;
// Liveness window: the nRF sends a "D" heartbeat every 5s plus adverts, so ~15s of total
// silence means the co-processor radio is dead and the BLE-detection half has gone dark.
static const uint32_t kCoProcTimeoutMs = 15000;
// Startup grace after an S3 boot (millis() from reset). Right after a reboot - most importantly the
// reboot at the END of an OTA - the nRF still has to reset, boot and send its first UART line (the
// S3 pulses its RESET on boot), so gCoLastRx is legitimately 0 for a few seconds. Report the
// co-processor as alive through this window so a normal reboot never flashes the "nRF radio fault"
// banner on a healthy board (it reads as "my device broke" right after an update). Only a nRF still
// silent PAST the grace - one that never came up - is treated as a real fault. 20s comfortably
// covers S3 boot + nRF reset + nRF boot + its 5s heartbeat interval, with margin for untested
// real-PCB timing (erring long here just delays a genuine dead-nRF warning by a few seconds; erring
// short reintroduces the exact false banner we are killing).
static const uint32_t kCoProcBootGraceMs = 20000;
void acabScannerSetCoProcStats(uint32_t a, uint32_t f, bool s, uint32_t bb) { gCoAdv = a; gCoFwd = f; gCoScan = s; gCoBb = bb; gHasCo = true; }
void     acabScannerNoteCoProcRx()    { gCoLastRx = millis(); }
bool     acabScannerHasCoProc()       { return gHasCo; }
bool     acabScannerCoProcAlive() {
    // A dead nRF used to look alive: gHasCo latched true on the first stats line and never
    // cleared. Gate on recency instead - once heard, going silent past the timeout reads as a fault.
    uint32_t last = gCoLastRx;
    if (!gHasCo || last == 0) {
        // Never heard from the co-processor yet. Hold "alive" through the boot grace so a fresh S3
        // reboot (notably the one at the end of an OTA) does not flash a radio-fault banner while
        // the nRF is still resetting/booting/re-syncing. A nRF that never speaks by the end of the
        // grace is a genuine fault and falls through to false below.
        if (millis() < kCoProcBootGraceMs) return true;
        return false;
    }
    return (millis() - last) <= kCoProcTimeoutMs;
}
uint32_t acabScannerCoProcAdvSeen()   { return gCoAdv; }
uint32_t acabScannerCoProcForwarded() { return gCoFwd; }
bool     acabScannerCoProcScanning()  { return gCoScan; }
uint32_t acabScannerCoProcBbCount()   { return gCoBb; }
void     acabScannerSendCoProcCmd(const char* cmd) { cmdSinkLine(cmd); }

// Re-assert everything the co-processor holds only in RAM. The nRF loses its scan on/off state
// and its whole ignore-list mirror on ANY reset (power blip, WDT, and most visibly a BLE DFU),
// and we used to push both exactly once, so it came back scanning at its default with an empty
// ignore list and nothing ever corrected it. The nRF announces "V<n>" on every boot, so the
// dual-radio UART parser calls this from that branch: cheap, idempotent, and it also covers the
// first boot, where the ignore list is restored from NVS and was never mirrored at all.
// Single-radio builds have no cmd sink, so this is a no-op there.
void acabScannerResyncCoProc() {
    if (!gCmdSink) return;
    cmdSinkLine(gBleEnabled ? "S1" : "S0");   // same line acabScannerSetBLE emits
    // Re-seed the mirror snapshot from the live ignore list (NOT from gMirrorList, which is empty
    // until the app pushes a list) and restart the deferred stream: gMirrorPos = -1 makes
    // acabScannerMirrorTick send a fresh 'IC' and then the paced 'IA' burst from the loop task.
    portENTER_CRITICAL(&gIgnoreMux);
    int n = gIgnoreCount;
    portENTER_CRITICAL(&gMirrorMux);
    if (n > 0) memcpy(gMirrorList, gIgnore, (size_t)n * 6);
    gMirrorCount  = n;
    gMirrorPos    = -1;
    gMirrorActive = true;
    portEXIT_CRITICAL(&gMirrorMux);
    portEXIT_CRITICAL(&gIgnoreMux);
}

uint32_t acabScannerIgnoreCount() { return (uint32_t)gIgnoreCount; }
uint32_t acabScannerWatchCount()  { return (uint32_t)gWatchCount; }

void acabScannerSetBLE(bool on) {
    gBleEnabled = on;
    if (gScan && !on) gScan->stop();    // cut the in-flight 2 s window short
    cmdSinkLine(on ? "S1" : "S0");      // dual-radio: tell the nRF to scan / stop
}
void acabScannerSetWiFi(bool on) {
    gWifiEnabled = on;
    esp_wifi_set_promiscuous(on);        // stop feeding the RX callback at all
}
// Recompute + reinstall the promiscuous filter (see applyWifiPromiscFilter). Called by
// netcamSetEnabled() when the camera opt-in flips, so the data-frame firehose is delivered
// only while the toggle is on. Guarded on WiFi being configured: before acabScannerBegin
// (netcam restore/config can run first) there is no promiscuous mode yet, so skip - Begin
// installs the filter from the current toggle state itself.
void acabScannerRefreshWifiFilter() {
    if (!gCfg.enableWiFi) return;
    applyWifiPromiscFilter();
}
bool acabScannerBLEEnabled()  { return gBleEnabled; }
bool acabScannerWiFiEnabled() { return gWifiEnabled; }
void acabScannerSetCmdSink(AcabCmdSink sink) {
    if (sink && !gCmdSinkMux) gCmdSinkMux = xSemaphoreCreateMutex();   // per-line writer lock (see cmdSinkLine)
    gCmdSink = sink;
}

// Bring up both radios per cfg, register the sink, and launch the scanner tasks.
void acabScannerBegin(const AcabScannerConfig& cfg, AcabDetectionSink sink) {
    gCfg  = cfg;
    gSink = sink;
    memset(gDedup, 0, sizeof(gDedup));
    memset(gDedupBucket, 0xFF, sizeof(gDedupBucket));   // all buckets empty (-1); no chain refs the zeroed entries
    gTotal = gBleSeen = gWifiSeen = 0;
    gBleEnabled = gWifiEnabled = true;
    restoreWifiEco();   // honor a persisted eco level from the first sweep
    loadIgnoreList();   // restore the persisted whitelist before any frame arrives
    loadWatchList();    // restore the persisted starred-device watchlist too

    // One sink task drains detections from both radios (see SinkItem above).
    gSinkQ = xQueueCreate(32, sizeof(SinkItem));
    xTaskCreatePinnedToCore(sinkTask, "acabSink", 8192, nullptr, 1, nullptr, 1);

    if (cfg.enableWiFi) {
        WiFi.mode(WIFI_STA);
        WiFi.disconnect();
        esp_wifi_set_promiscuous(true);
        // Install the frame filter: MGMT-only in production, widened to DATA only when the
        // network-camera opt-in is on (or a diag build). netcamRestoreEnabled() already ran
        // in main() before this, so a persisted opt-in is honored from the first frame.
        applyWifiPromiscFilter();
        esp_wifi_set_promiscuous_rx_cb(&wifiRxCallback);
        esp_wifi_set_channel(cfg.wifiChannelHop ? 6 : cfg.wifiFixedChannel,
                             WIFI_SECOND_CHAN_NONE);
        xTaskCreatePinnedToCore(wifiHopTask, "acabWifiHop", 4096, nullptr, 1, nullptr, 0);
#ifdef ACAB_DIAG_WIFI
        gWifiDiagQ = xQueueCreate(64, sizeof(WifiDiagItem));
        xTaskCreatePinnedToCore(wifiDiagTask, "acabWifiDiag", 4096, nullptr, 1, nullptr, 0);
#endif
    }

    if (cfg.enableBLE) {
        if (cfg.initNimBLE && !NimBLEDevice::getInitialized()) {
            NimBLEDevice::init(cfg.bleDeviceName ? cfg.bleDeviceName : "ACAB");
        }
        // hush the lib's warnings about zero-length adverts we ignore anyway
        esp_log_level_set("NimBLEAdvertisedDevice", ESP_LOG_NONE);

        gScan = NimBLEDevice::getScan();
        gScan->setAdvertisedDeviceCallbacks(new AcabAdvCallbacks(), /*wantDuplicates=*/true);
        // PERF-1: don't RETAIN scanned devices. wantDuplicates=true already feeds the callback
        // every advert (which is all we consume), but the library ALSO stores each distinct
        // device in its results vector; at the default maxResults (0xFF) that vector grows and
        // pins memory over a long session. 0 = keep nothing - the callback consumed it already.
        gScan->setMaxResults(0);
        // PASSIVE scan by default: active scanning transmits a SCAN_REQ (carrying our own
        // address) to every advertiser heard , including the gear being detected , which
        // contradicts the passive product claim. Detectors key on primary-advert payloads;
        // only scan-response device names are lost. Field-capture/dev builds may re-enable
        // with -DACAB_ACTIVE_SCAN (never ship it).
#ifdef ACAB_ACTIVE_SCAN
        gScan->setActiveScan(true);      // CAPTURE BUILD: RF-loud, fingerprintable
#else
        gScan->setActiveScan(false);
#endif
        gScan->setInterval(131);  // ~82 ms, prime to dodge sync; ~51% duty (down from 97/69%)
        gScan->setWindow(67);     // so WiFi promiscuous isn't starved on the shared radio
        xTaskCreatePinnedToCore(bleScanTask, "acabBleScan", 12288, nullptr, 1, nullptr, 1);
    }
}
