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
// torn writes without the key; everything from whenMs down is the AES-CTR encrypted payload.
// Its counter prefix is derived from an unpredictable durable 128-bit crypto domain plus
// bootCount:seq, separating boards/NVS generations even though the app key is shared.
struct __attribute__((packed)) StoredDet {
    uint32_t seq;          // monotonic: ring order + the app's sync cursor (cleartext)
    uint32_t bootCount;    // persisted monotonic boot counter, NOT random (cleartext)
    uint16_t crc;          // CRC16 over every stored byte except this field; written LAST
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

// Oldest phone fix a stored record may carry a coordinate from, in millis.
//
// It is gpsAgeSec's own uint16 range, in seconds, and NOT an independent policy number: past it
// the age stops fitting the field, so the record would carry a real coordinate beside an age that
// says "18h" no matter how much older it actually is. The apps render that age verbatim
// ("location from a fix N old"), so a saturated one is a claim the board cannot support.
// A board left out longer than this keeps recording WHAT went by and stops claiming WHERE.
//
// ENFORCED AT THE WRITE, inside detLogAppend, and not only at acab_scanner's read. Do NOT read
// this as "the live phone-connected path is fresh by construction" - it is not. handleDetection
// asks acabBleGetPhoneGps for "any age", so a phone that connects, pushes one fix and then stops
// refreshing (backgrounded, location permission revoked, parked) leaves that stamp arbitrarily old
// while the link stays up. Such a row still reaches this ring: it is queued to sinkTask with the
// stamp already on it, the link drops, and the append is accepted a beat later. The write-side
// bound is the only thing between that and a two-day-old coordinate stored beside a saturated age.
static const uint32_t DET_LOG_GPS_MAX_AGE_MS = 0xFFFFu * 1000u;   // 65535 s ~ 18h12m

// A position offered to detLogAppend ALONGSIDE the record instead of inside it, already in the
// storage form StoredDet keeps (e7 fixed point, whole seconds), so nothing is rounded twice.
//
// WHY IT IS NOT SIMPLY SET ON THE AcabDetection: the only position a board can offer while its
// owner is away is the retained phone fix (acabBleGetLastPhoneGps), and that fix must never ride
// the object the sink hands to the BLE notify path. The SAME AcabDetection is both delivered live
// and buffered, and the two happen on opposite sides of a connect: a row stamped while
// disconnected can sit in the sink queue under backpressure, a phone can connect in that window,
// the append is then refused (this ring only accepts rows while the app is away) and the live
// notify goes out carrying the coordinate anyway - to a phone that, after a re-pair, need not even
// be the one that supplied it. Carrying it out of band makes that shape unrepresentable instead of
// merely guarded against.
//
// `valid` false = nothing offered; the record then stores whatever the detection itself carries.
struct DetLogGpsStamp {
    int32_t  lat_e7;
    int32_t  lon_e7;
    uint16_t ageSec;
    bool     valid;
};

// A decrypted record handed back to the BLE layer for one replay frame.
struct DetLogReplay {
    AcabDetection d;       // unpacked back into the live detection shape
    uint32_t seq;          // wire "seq"
    // Private record-layer capability for THIS peek. It never goes on the wire. A stop followed
    // by a new start can legitimately put the cursor back on the same seq, so seq alone cannot
    // distinguish the old peek from the replacement drain (an ABA race). Commit must present
    // both values; start, stop, and clear each invalidate every previously issued capability.
    uint64_t drainGeneration;
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

// Latched storage faults. These are a bitmask so one status value can report every
// failure observed since the last fully successful clear. Faults survive reboot and
// raw-ring integrity faults stop new appends. The NVS bit reports an offline-buffer metadata
// load/save failure (generation, anchors, connection/privacy lifecycle, saturation, or diagnostic
// state), but does not by itself condemn otherwise sound ring geometry. A complete physical wipe
// clears the mask; merely starting a clear does not claim the storage is healthy again.
enum DetLogFault : uint32_t {
    DET_LOG_FAULT_NONE    = 0,
    DET_LOG_FAULT_READ    = 1u << 0,
    DET_LOG_FAULT_ERASE   = 1u << 1,
    DET_LOG_FAULT_WRITE   = 1u << 2,
    DET_LOG_FAULT_CORRUPT = 1u << 3,
    DET_LOG_FAULT_LOCK    = 1u << 4,
    DET_LOG_FAULT_NVS     = 1u << 5,  // offline-buffer metadata could not be loaded or saved
    DET_LOG_FAULT_CRYPTO  = 1u << 6,  // nonce/key hash or AES failed; evidence I/O is incomplete
};

// --- lifecycle ---
void     detLogBegin();             // mount ring, scan for head (generation window),
                                    // bump+persist bootCount, run auto-wipe of stale records
void     detLogSetEnabled(bool on); // opt-in master switch (persisted); false also durably requests
                                    // retained-coredump erasure, even when already disabled
bool     detLogEnabled();

// --- RECORD EVERYTHING (deploy-and-leave). Persisted to NVS, default OFF. ---
// Normally the ring REFUSES ACAB_NEARBY_DEVICE (shouldBuffer in acab_scanner.cpp): it is
// append-only with no type filter of its own, so in a dense area a flood of re-admitted phone
// records wraps it and evicts the real ALPR / body-cam hits the owner synced to get.
//
// That reasoning INVERTS for the case this switch exists for: a board left unattended for days
// in a low-RF area, where the question is whether anything came by at all and an uncategorized
// device IS the finding. There is nothing to crowd out, because almost nothing transmits there.
//
// Turning it on also changes two things that are otherwise wrong for a week-long deployment:
//      1. Re-arm becomes TIME-based (REBUFFER_AFTER_MS in acab_scanner.cpp) instead of firing
//      once per capture generation. Without it a vehicle that passes Monday and again Thursday
//      writes ONE record, because gCaptureGen only advances on an app disconnect and no app is
//      coming. The log would say "this MAC existed" and never "something came by twice".
//      TWO LIMITS ON THAT, both real, and neither may be papered over in user-facing copy:
//        - The interval is BEST EFFORT. Dedup eviction resets loggedGen, so a busy site
//          re-buffers the same device far more often than the interval implies. It governs at a
//          quiet, stationary site, which is the only place this mode belongs.
//        - "Monday and Thursday" needs a CLOCK. The board has no RTC. Times are millis() plus an
//          app-pushed epoch anchor, so a boot that follows an unattended power loss is never
//          anchored and its records replay as approx, bracketed between neighbouring anchored
//          boots (see DetLogReplay.approx). Exact wall-clock is only guaranteed while the board
//          stays powered or that boot received an anchor. Ordering within a boot is always sound.
//   2. The undrained-reboot auto-wipe threshold rises (WIPE_AFTER_BOOTS_DEPLOY). Boot count is a
//      poor proxy for "seized" once the owner has explicitly said they are leaving it unattended,
//      and a discharging battery browning out six times would otherwise erase the whole week.
//      SECURITY TRADEOFF, STATED PLAINLY: this weakens the self-clean guarantee. It does not
//      remove it (the threshold stays finite), but a board recovered inside that window yields
//      more than it would with the switch off. Say so where the user turns it on.
//
// THIS SWITCH ALONE DOES NOT GIVE YOU "DID ANYTHING COME BY". DESERT MODE MUST ALSO BE ON.
// ACAB_NEARBY_DEVICE has exactly two producers, both in desert_detect.cpp and both behind that
// mode's own enable. With Desert off, bufall still buys the revisit/dwell half (the tick re-arms
// EVERY type, so a Flock or body-cam hit gets a record per window instead of one for the whole
// deployment) and the wider wipe threshold, but nothing uncategorized is ever classified, so the
// uncategorized half of the feature produces nothing. The app must turn both on together, and
// firmware deliberately does NOT auto-enable Desert here: the iOS client forces Silent when
// Desert goes on, and bypassing that would arm the buzzer into a firehose.
//
// Once the ring is full, detLogAppend stops accepting ACAB_NEARBY_DEVICE rather than letting
// them evict signature hits. See the guard there for why (a drive home with the board still
// armed will otherwise overwrite the deployment it just collected).
void     detLogSetBufferAll(bool on);
bool     detLogBufferAll();

// --- Stationary-mode capacity / censoring risk ---
// Once Stationary capture reaches ring capacity, detLogAppend refuses further
// ACAB_NEARBY_DEVICE records rather than let them evict signature hits. `bufsat` is raised on the
// exact transition to full (and when bufall is enabled on an already-full ring), so it means later
// nearby rows MAY have been omitted; it is not proof a refusal already occurred. The flag is
// PERSISTED across deployment reboots and cleared only by detLogClear. detLogSatDrops() counts
// actual refusals THIS BOOT for the diag line. Surface the capacity warning beside the log.
bool     detLogSaturated();
uint32_t detLogSatDrops();

// --- CLIENT CONTRACT for this mode. Not yet implemented in either app, ON PURPOSE. ---
// Firmware-only until the UI below exists: nothing in ios/ or android/ writes "bufall", so the
// mode is currently unreachable and cannot be armed by accident.
//
// Present it as ONE experimental switch called "Stationary capture". Do NOT call it "record
// everything": that names the mechanism, invites use as a general logging mode, and buries the
// one thing the user has to understand, which is that this is for a board that STAYS PUT.
//
// Arming it pushes the at-rest key first, then a SINGLE config object:
//     {"buffer":true, "bufall":true, "desert":true, "buzzer":false}
// All four together, in one write. buffer alone records nothing new; bufall without desert gets
// revisit resolution but never classifies an uncategorized device, which is the half the user
// actually wants; and buzzer:false because Desert on a live board is a firehose.
//
// The screen must state, in the user's own terms:
//   1. EXTERNAL USB-C POWER IS REQUIRED. The battery SKU runs ~7h15m quiet against 168h in a
//      week. Without this the deployment simply stops, and the log looks identical to "nothing
//      came by".
//   2. It records nearby radios, INCLUDING BYSTANDERS' PHONES. Say it plainly; this is the
//      disclosure that distinguishes the mode from the rest of the product.
//   3. Storage used, and whether it REACHED CAPACITY (status "bufsat"). Later nearby rows may have
//      been omitted, so the user must not assume a full log is complete. Show this next to the log;
//      `bufdrops` is the separate current-boot count proving actual refusals.
//   4. Whether capture times are EXACT or APPROXIMATE. Any boot after an unattended power loss
//      is unanchored and replays as approx (DetLogReplay.approx). "Monday and Thursday" is only
//      guaranteed while the board stays powered or that boot received an epoch anchor.
//   5. The weakened auto-wipe, in one sentence, at the switch itself and not in a help page.
//
// DISARMING IS AN ORDERED SEQUENCE, and the order is load-bearing. Setting "buffer":false calls
// detLogClearKey(), which drops the at-rest key from RAM and NVS. Do that before the replay has
// finished and the remaining records become undecryptable while still occupying the ring: the
// deployment is destroyed by the act of collecting it. So, on collection:
//   1. Connect and let the replay run to completion.
//   2. Confirm it ended CLEANLY - the {"hist":"end","n":N} sentinel, with N matching the record
//      count received. A gap means re-sync, not proceed.
//   3. Only then write {"bufall":false, "desert":false, "buffer":false}.
//   4. Restore the user's prior alert mode through the existing Desert reconciliation path
//      (reconcileDesert on both platforms). Do NOT blindly re-enable the buzzer: the mode forced
//      Silent, and a mode the user hand-picked while Desert ran has to survive.
//   5. Let the user ERASE the stored log explicitly ({"clearlog":true}). Never automatic. They
//      just collected a week of bystander movements; deleting it is their call and their timing.
//
// STATUS SEMANTICS THE CLIENT MUST IMPLEMENT: "bufall" and "bufsat" are sent ONLY when true, so
// ABSENT MEANS FALSE, and it means false in EVERY fresh status frame, not just the first. Latch
// them per frame, never cumulatively. Get this wrong and a stale saturation warning survives a
// clearlog forever, telling the user their complete log is truncated when it is not.
//
// HARDWARE ACCEPTANCE PASS, required before the switch is exposed in either app. The host suite
// covers the persistence LOGIC; none of it proves the flash ring, the NVS writes and the drain
// behave on a real board across a real power cycle, which is the entire premise of the mode:
//   1. Arm Stationary capture, then disconnect.
//   2. Confirm UNCATEGORIZED and TRACKER records are actually stored (both are new admissions
//      under this mode; the tracker one only works because the debounce term is relaxed).
//   3. Power-cycle the board. Confirm desert, buffer and bufall all come back ARMED.
//   4. Drain, and verify exact vs approximate timestamps behave as documented above: records from
//      an anchored boot exact, records from a boot that followed an unattended power loss approx.
//   5. Force saturation with a TEST BUILD using a tiny slot count, and confirm bufsat persists
//      through a reboot. Do not wait for a real 24576-record ring to fill.
//   6. clearlog, and confirm bufsat disappears from the status frame.

// --- at-rest key: app-pushed on connect. Held in RAM, and persisted to NVS while buffering
// is enabled so a deploy-and-leave board survives a reboot (the TRADEOFF above). A truncated
// SHA-256 of it is persisted UNCONDITIONALLY: buffered records outlive the key (a disable
// erases the key but not the ring), and the fingerprint is what detects a different phone's
// key arriving for them, which would otherwise decrypt them to noise that passes the CRC. ---
// Result of offering an at-rest key for the current authenticated config session. A key is
// ACCEPTED only after its fingerprint is verified and it is either installed or safely staged
// behind an already-authorized transaction. PENDING means startup/raw geometry is not authoritative
// yet, so the caller must not use a retained RAM key to authorize replay. A different key never
// destroys a nonempty/unknown generation unless `allowDestructiveReplacement` accompanies an
// explicit clear request; MISMATCH preserves both the rows and their current key.
enum DetLogKeyResult : uint8_t {
    DET_LOG_KEY_REJECTED = 0,
    DET_LOG_KEY_ACCEPTED = 1,
    DET_LOG_KEY_PENDING  = 2,
    DET_LOG_KEY_MISMATCH = 3,
};
DetLogKeyResult detLogSetKey(const uint8_t key[32],
                             bool allowDestructiveReplacement = false);
void     detLogClearKey();          // forget the key; keeps the fingerprint. Normal disable callers
                                    // use detLogSetEnabled(false), which also requests dump erasure
bool     detLogHaveKey();
// Called after BLE authentication but before config writes are admitted. Durably pins one
// retained-coredump erase generation for the whole physical boot before keys/config can enter
// parser/callback stacks; subsequent sessions reuse it to avoid NVS churn. False means NVS could
// not establish that privacy boundary and the caller must reject/disconnect the session.
bool     detLogPrepareConfigSession();
// Paired with the BLE session gate. If buffering stayed disabled and this link supplied a replay
// key, forget its live/staged copies without NVS writes or another erase generation; the
// boot-lifetime exposure hold and already-durable token remain the panic-dump backstop.
void     detLogEndConfigSession();

// --- wall-clock anchor: app-pushed epoch for this boot (mirrors the GPS push) ---
void     detLogSetEpoch(uint32_t unixSec);

// Start an authenticated-owner OR disconnect boundary before clearing session GPS or doing
// config-session NVS work. This advances the scanner-to-flash epoch and blocks every append/live
// delivery until the corresponding admit. The scanner publishes a zero sentinel on queue claims
// while the block is held, so old and newly queued items are both refused. Returns 0 on lock
// failure, leaving capture fail-closed.
uint32_t detLogBlockCaptureForOwnerSession();

// Finish a reserved boundary after prior-owner state is cleared. Authentication calls this after
// the config-session privacy pre-arm is durable; disconnect calls it after GPS/replay/key teardown
// and keeps its service gate raised until scanner epoch+generation publication. `epoch` must be the
// nonzero token returned above. False leaves capture/delivery fail-closed.
bool     detLogAdmitCaptureForOwnerSession(uint32_t epoch);

// Recover a disconnect boundary when its normal Block reservation was unavailable. The ordinary
// path uses Block before connection teardown and Admit afterward, then publishes that reserved
// epoch with the scanner generation in one critical section. This one-step advance remains the
// fail-closed fallback: it never returns an unchanged token as success. Returns 0 on lock failure;
// 0 is never a live admission token.
uint32_t detLogAdvanceCaptureEpoch();

// Run a queued live-delivery callback only if its scanner-stamped owner epoch is still current.
// Validation and callback execution share a dedicated owner-delivery mutex with authentication /
// disconnect epoch changes, so a prior owner's queued item cannot pass a check and then notify a
// newly admitted owner in the gap afterward. gIoMutex is released before `deliver`, so ordinary
// detLog status reads from the sink are safe; the callback must not recursively call these three
// owner-boundary/delivery APIs. A zero/stale epoch, an authentication-preparation block, or lock
// failure returns false without invoking the callback.
typedef void (*DetLogCaptureDelivery)(void* context);
bool     detLogDeliverIfCaptureEpochCurrent(uint32_t epoch,
                                            DetLogCaptureDelivery deliver,
                                            void* context);

// --- capture: called from acab_scanner.cpp's sinkTask, off both radio paths.
// No-op unless buffering is enabled AND a key is present AND the ring mounted AND no app is
// connected. WHICH detections get here at all is the caller's decision (shouldBuffer in
// handleDetection): once per device per capture generation, no Desert rows unless the owner
// turned on "record everything".
//
// `gps`, when non-null and valid, supplies the position for THIS record only - see DetLogGpsStamp
// for why the retained phone fix arrives beside the detection rather than on it. A detection that
// already carries its own coordinate (a drone's broadcast position, an onboard fix) keeps it. ---
enum DetLogAppendResult : uint8_t {
    DET_LOG_APPEND_STORED,          // row is durably present in the raw ring
    DET_LOG_APPEND_RETRY,           // transient refusal; caller should release its capture claim
    DET_LOG_APPEND_NOT_ARMED,       // stable off/link/key/storage refusal; claim stays consumed
    DET_LOG_APPEND_CAPACITY_DROP,   // intentional full-ring nearby refusal; claim stays consumed
    DET_LOG_APPEND_RATE_LIMITED,    // signature-row flood limit refused it; claim is RELEASED so a
                                    // device that keeps transmitting gets another chance once a
                                    // token refills (see the flood limit below)
};
inline bool detLogAppendReleasesClaim(DetLogAppendResult result) {
    // RATE_LIMITED releases the claim, which on its own would let every later advert of the same
    // device re-enqueue a doomed append. What stops that hot loop is detLogRateGate(), which the
    // scanner reads BEFORE claiming: a refusal closes the gate for its tier until the bucket is
    // due back over that tier's floor.
    return result == DET_LOG_APPEND_RETRY || result == DET_LOG_APPEND_RATE_LIMITED;
}

// --- FLOOD LIMIT on signature rows (every type except ACAB_NEARBY_DEVICE) ---
// THE ATTACK. The ring is strictly FIFO and type-blind, and the scanner writes each fresh dedup
// key once per capture generation. A nearby transmitter that mints fresh identities (beacon frames
// SSID "Flock-..." from random BSSIDs, Flock-named BLE adverts from random addresses, Remote ID
// with random UAS IDs, netcam-OUI data frames from random source MACs) at ~100/s used to overwrite
// all 24,576 slots, the real deployment's Flock/Axon rows included, in about four minutes, with
// nothing to show for it. The precondition is the deploy-and-leave case itself: buffer on, phone
// away.
//
// THE LIMIT. A token bucket inside appendLocked, under gIoMutex, which is the one place a row
// reaches storage. Each stored signature row spends one token. NEARBY rows never touch it: their
// existing full-ring cap (bufsat) already keeps them from evicting anything.
//
// THE NUMBERS, from the densest real signature scenes committed to the repo:
//   - docs/captures/lvt-2026-08-03-summary.txt, netcam ON, residential streets (Ring, Swann, Wyze,
//     Reolink, eufy OUIs). Unique signature first sightings, which is what the ring stores: 83 in
//     one 47-minute segment, at most 34 in any 10 minutes, 10 in any 60 s, 4 in any 1 s.
//   - docs/radio-coverage.md, the c5-lvt capture: 67 camera-vendor MACs in ~27 minutes, 48 of them
//     on 2.4 GHz (the only band the board hears).
//   - docs/captures/drive-to-camarillo-2026-09-07.txt: 45 detections in 2h28m, netcam off.
//   - docs/captures/911-2026-09-11.txt (3h53m): its strongest results are two Remote ID drones
//     and one FS Ext Battery row, beside a handful of low-confidence alerts.
//   The refill, 1 row per DET_LOG_RATE_REFILL_MS = 10 s (60 per 10 minutes), is 1.76x the densest
//   10-minute window above, and the burst absorbs everything the window does not.
//   The burst is DET_LOG_RATE_BURST = 256 rather than a smaller number because of one real event
//   that is denser than any drive: every disconnect bumps the capture generation, which re-arms
//   EVERY entry in the scanner's dedup table at once, and that table holds ACAB_DEDUP_MAX = 256
//   entries (acab_scanner.cpp). Walking away from a board parked beside a camera-heavy building
//   therefore enqueues up to 256 signature rows within seconds, all real. A burst of 256 covers a
//   table full of them (test_det_log.cpp checks the two constants stay in step). 256 slots is 1%
//   of the ring, so the attacker's free burst buys nothing.
//
// WORST CASE, STATED: a sustained flood gets the full burst, then one row per 10 s. Overwriting all
// 24,576 slots takes 256 + (24,576 - 256) x 10 s = 243,200 s, about 67.6 hours (2 days 19.6 h),
// instead of about four minutes. The flood is not silent either: see detLogRateLimited() below.
//
// WHERE THE LIMIT CAN BITE A REAL SCENE, stated rather than hidden. Stationary capture (bufall)
// re-arms every device each REBUFFER_AFTER_MS (15 min in acab_scanner.cpp), so N signature devices
// permanently in range cost N rows per window against 90 refills per window. Up to N = 90 the
// bucket never drains. Above it the bucket drains by (N - 90) per window and, once empty, some
// devices miss a window's re-arm row (they are released, not lost, and the next window re-arms
// them) and the marker is raised. Nothing captured so far comes near 90 concurrently audible
// 2.4 GHz netcams (see the density above). If a real deployment does, the fix is a separate bucket
// per type (netcam being the only type with that volume), not a larger shared one.
//
// FAIRNESS: one-shot random identities must not starve a real device. The last
// DET_LOG_RATE_RESERVE tokens are spendable only by a PERSISTENT row (detLogRatePersistent: seen
// at least twice, first-to-last sighting at least DET_LOG_RATE_PERSIST_MS apart). A real camera
// keeps refreshing its dedup entry, and dedupFind evicts least-recently-seen first, so it survives
// a fresh-identity flood that recycles the table; a one-shot identity is never seen twice. A flood
// of fresh identities therefore drains the bucket only down to the reserve, and a real device that
// was refused while fresh is admitted from the reserve as soon as it has dwelt 10 s. An attacker
// can also make identities persistent by repeating them; that buys them the reserve, and then
// real devices STARVE: a repeating flood (~20 identities/s, each resent once 10 s later, stays
// under the 256-entry dedup table) holds the bucket at zero, and each reopening's single token
// goes to whichever persistent row reaches the sink first, almost always an attacker row. The
// refill rate still bounds what they can OVERWRITE (the ~67.6 h figure holds), and bufrl makes the
// loss visible, but under that attack real rows are refused, not recorded. Per-type buckets or a
// stricter persistence rule are the next lever if a field capture ever shows this shape.
static const uint32_t DET_LOG_RATE_BURST      = 256;
static const uint32_t DET_LOG_RATE_REFILL_MS  = 10000;
static const uint32_t DET_LOG_RATE_RESERVE    = 32;
static const uint32_t DET_LOG_RATE_PERSIST_MS = 10000;

// The persistence rule, shared by the scanner's ingest gate and appendLocked so the two cannot
// disagree about which tier a row is in. Both feed it the dedup entry's own values: count after
// this sighting, and lastSeen - firstSeen (unsigned, so it is millis()-wrap safe).
inline bool detLogRatePersistent(uint16_t count, uint32_t dwellMs) {
    return count >= 2 && dwellMs >= DET_LOG_RATE_PERSIST_MS;
}

// LOCK-FREE ingest gate, read on the per-advert radio path BEFORE a buffer claim is made. It never
// takes gIoMutex (held across multi-ms flash erases): it compares millis() with two volatile
// "closed until" stamps that appendLocked publishes only when it actually refuses a row. So the
// gate closes only after a refusal has already been counted and marked, and it reopens by time
// once the bucket is due back over that tier's floor (one refill for the persistent tier, up to
// RESERVE + 1 refills for the fresh one). A closed gate means "do not claim yet": the device's
// loggedGen stays unclaimed, so an advert after the reopening tries again. While the fresh tier is
// shut, a genuinely one-shot real row (one frame, never seen again) is not claimed at all; that is
// the price of the flood case, and the marker has already been raised by then. Without this, RATE_LIMITED releasing the claim
// would turn a streaming netcam (hundreds of data frames/s) into hundreds of doomed sink items.
struct DetLogRateGate {
    bool freshOpen;        // a non-persistent row may try to claim
    bool persistentOpen;   // a persistent row may try to claim
};
DetLogRateGate detLogRateGate(uint32_t nowMs);

// FLOOD MARKER. Raised on the first rate refusal, PERSISTED to NVS ("bufrl") so it survives the
// reboots a deployment sees, and cleared only where bufsat is cleared (the clearlog/key-rotation/
// auto-wipe arm and the wipe's retirement). Status sends "bufrl":true only while it is set.
// detLogRateDrops() is the this-boot count of refused appends for the [diag] line. It counts rows
// refused AT THE RING; adverts the ingest gate deferred while closed are not rows and are not
// counted. The marker does NOT block further appends: a failed NVS write is retried from the loop
// tick (and latches DET_LOG_FAULT_NVS) instead of stopping evidence capture.
bool     detLogRateLimited();
uint32_t detLogRateDrops();
DetLogAppendResult detLogAppend(const AcabDetection& d,
                                const DetLogGpsStamp* gps = nullptr);
DetLogAppendResult detLogAppendClaimed(const AcabDetection& d,
                                       const DetLogGpsStamp* gps,
                                       uint32_t captureEpoch);

// --- replay: the BLE service owns the NOTIFY stream and pulls records from here.
// Delivery is UNACKNOWLEDGED notify; reliability is the per-record seq plus the {"hist":"end","n"}
// count, which let the app spot a gap and re-sync (it is NOT an acknowledged INDICATE stream).
// detLogStartDrain accepts the cursor only when the app's durable log generation matches the
// board. A missing/zero/mismatched generation rebases to the retained ring floor, because seq
// values overlap after a clear and cannot safely identify a generation by themselves. Replay is
// deliberately two-phase:
// detLogPeekForDrain decrypts/unpacks the next record WITHOUT advancing the cursor, and the BLE
// service calls detLogCommitDrain only after it has built a frame that fits and queued the notify.
// An MTU/schema regression can therefore block a drain and remain visible, but can never consume
// evidence the phone did not receive. A repeated peek before commit returns the same seq. ---
enum DetLogDrainStartResult : uint8_t {
    DET_LOG_DRAIN_STARTED,
    DET_LOG_DRAIN_EMPTY,
    DET_LOG_DRAIN_PENDING,
    DET_LOG_DRAIN_REJECTED,
};
DetLogDrainStartResult detLogStartDrain(uint32_t lastSeq, uint32_t clientLogGeneration);
// Internal/backward-compatible convenience for callers that already share board state. Wire
// parsers must pass the client's explicit generation (zero when absent), never use this overload.
uint32_t detLogGeneration();
inline DetLogDrainStartResult detLogStartDrain(uint32_t lastSeq) {
    return detLogStartDrain(lastSeq, detLogGeneration());
}
bool     detLogDrainStartPending();
bool     detLogDraining();
void     detLogStopDrain();   // abort an in-flight drain on a link drop; next {sync} re-arms it
bool     detLogPeekForDrain(DetLogReplay* out);
bool     detLogCommitDrain(uint32_t seq, uint64_t drainGeneration);
                                    // false unless both values came from the current matching peek

// --- maintenance ---
void     detLogClear();             // logical clear now; ring erase deferred/chunked, plus a durable
                                    // retained-coredump erase generation consumed from loop()
uint32_t detLogCount();             // stored record count (surfaced as status "buf")
uint32_t detLogPendingDrain();      // records queued for the CURRENT drain (valid after
                                    // detLogStartDrain; = what the replay will actually send)
uint32_t detLogFaults();            // latched DetLogFault bitmask; 0 means no known storage fault

// Internal loop/BLE helpers. Declared here so the implementation and its host tests share
// one contract; application mains should continue to reach them through acabBleDrainTick.
void     detLogEraseTick();
bool     detLogWipePending();
uint32_t detLogDrainFrom();

// A retained IDF core dump is a second sensitive at-rest surface: task stacks can contain the
// buffer key, a decrypted record, or phone coordinates. User-driven destructive actions therefore
// persist an independent erase-generation token instead of asking coredump_report to infer intent
// from the shared ring-wipe level (which also represents auto-wipes and resumed sweeps). The token
// survives power loss; completion clears it only if no newer request superseded `generation`.
// Production callers are coredump_report.cpp only. Exposed here so the host persistence suite can
// prove the contract against the real Preferences-backed implementation.
uint32_t detLogSensitiveErasePending();
void     detLogSensitiveEraseComplete(uint32_t generation);

#ifdef ACAB_HOST_TEST
// Drops only process-local state. The host partition and Preferences stores survive,
// which models a reboot without adding production-only reset behavior.
void     detLogHostResetRuntime();
#endif

#endif // ACAB_DET_LOG_H
