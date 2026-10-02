#include "coredump_report.h"
#include <Arduino.h>
#include <string.h>

// esp_core_dump_* is only present when the IDF coredump-to-flash option is compiled in, which is
// the case for the shipped 8 MB partition layout. Guard anyway so a stripped or third-party build
// still links: the whole feature degrades to "no dump reported", never to a build break.
#if __has_include(<esp_core_dump.h>)
  #include <esp_core_dump.h>
  #include <esp_partition.h>
  #define ACAB_HAVE_COREDUMP 1
#endif
#include <esp_system.h>
#include "det_log.h"   // durable explicit erase-generation token + ring sweep state

static AcabCoredumpInfo gInfo{};
static bool gProbed = false;

const AcabCoredumpInfo& acabCoredumpInfo() { return gInfo; }

#ifdef ACAB_HAVE_COREDUMP
// EMPTINESS IS PROVEN BY READING THE PARTITION, never by an IDF return code. The pinned IDF
// (v4.4.7, esp_core_dump_partition_and_size_get) answers ESP_ERR_INVALID_SIZE for a blank
// partition, the same code it gives a garbage size word, and ESP_ERR_NOT_FOUND only when the
// partition table has no coredump partition; esp_core_dump.h documents NOT_FOUND for "no core
// dump stored", which this IDF does not do. True only when no stack byte can be retained:
//   - there is no coredump partition, or
//   - every byte is 0xFF, apart from bytes 4..15, which may be the 0x00 pad of the 16-byte
//     {0xFFFFFFFF, 0, 0, 0} marker esp_core_dump_image_erase() writes after its erase.
// A blank size word alone is NOT proof: a panic write erases only the sectors the new dump
// needs, so a write interrupted before its header lands leaves a blank head in front of an
// older, larger dump's stack bytes. A read error proves nothing either.
// Clean-boot cost: one pass over the 64 KB partition in sizeof(buf) pieces, from setup() before
// the radios start. IDF takes the flash guard (cache off, other core parked) once per
// esp_partition_read call, not for the whole pass. Measured 13-14 ms on a rev-A board
// (2026-10-02, three boots, serial gap around the probe; the pre-fix probe measured ~0 ms).
static bool coredumpPartitionBlank() {
    const esp_partition_t* part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_COREDUMP, nullptr);
    if (!part) return true;
    uint8_t buf[1024];   // loop task stack is 8 KB and nearly empty this early in setup()
    for (size_t off = 0; off < part->size; off += sizeof(buf)) {
        const size_t left = part->size - off;
        const size_t n = left < sizeof(buf) ? left : sizeof(buf);
        if (esp_partition_read(part, off, buf, n) != ESP_OK) return false;
        for (size_t i = 0; i < n; i++) {
            const size_t at = off + i;
            const bool markerPad = at >= 4 && at < 16 && buf[i] == 0x00;
            if (buf[i] != 0xFF && !markerPad) return false;
        }
    }
    return true;
}
#endif

void acabCoredumpProbe() {
    memset(&gInfo, 0, sizeof(gInfo));
#ifdef ACAB_HAVE_COREDUMP
    // image_check() validates a stored dump end to end. When it finds no valid image, the
    // ordinary "clean boot, nothing retained" case is a partition coredumpPartitionBlank() can
    // prove blank, and that proof is the ONLY thing that means empty. Any other check or
    // metadata-access failure is not permission to acknowledge a destructive request: the
    // partition can still contain sensitive stack bytes even when IDF cannot describe them.
    const esp_err_t chk = esp_core_dump_image_check();
    if (chk != ESP_OK && coredumpPartitionBlank()) {
        gProbed = true;
        return;
    }

    // Fail closed until the complete valid-image path below proves otherwise. `corrupt` is also
    // the public "erase required / dump unreadable" state used by diagnostics and WipeTick; it
    // includes a failed image_get and an impossible zero-size result, not just a bad checksum.
    gInfo.corrupt = true;
    size_t addr = 0, size = 0;
    const esp_err_t got = esp_core_dump_image_get(&addr, &size);
    if (got == ESP_OK && size > 0) {
        gInfo.sizeBytes = (uint32_t)size;
        if (chk == ESP_OK) {
            gInfo.present = true;
            gInfo.corrupt = false;
            esp_core_dump_summary_t* sum = (esp_core_dump_summary_t*)malloc(sizeof(*sum));
            if (sum) {
                if (esp_core_dump_get_summary(sum) == ESP_OK) {
                    gInfo.pc = sum->exc_pc;
                    gInfo.dumpVersion = sum->core_dump_version;
                    strncpy(gInfo.task, sum->exc_task, sizeof(gInfo.task) - 1);
                    // app_elf_sha256 is the ONLY identity in the summary. There is no firmware
                    // version here, and stamping the running ACAB_FW_VERSION would be a lie
                    // whenever the dump predates an OTA - which is exactly when it matters.
                    strncpy(gInfo.elfSha, (const char*)sum->app_elf_sha256, sizeof(gInfo.elfSha) - 1);
                }
                free(sum);
            }
        }
    }
#else
    // Without the IDF API there is no positive empty result and no erase primitive. Keep explicit
    // wipe requests pending rather than claiming success over a partition we could not inspect.
    gInfo.corrupt = true;
#endif
    // WipeTick must not interpret the zero-initialized cache as "nothing retained" before the
    // partition has actually been checked. Every shipped main probes before entering loop().
    gProbed = true;
}

bool acabCoredumpErase() {
    // Nothing retained: report success, so a wipe path can call this unconditionally.
    if (!gInfo.present && !gInfo.corrupt) return true;
#ifdef ACAB_HAVE_COREDUMP
    if (esp_core_dump_image_erase() != ESP_OK) return false;
    // Drop the cached summary too. It is what the {"diag":true} reply serves, and a board that
    // kept reporting task/pc/elf for a dump it has just erased would be advertising the exact
    // thing the caller asked it to forget.
    memset(&gInfo, 0, sizeof(gInfo));
    return true;
#else
    // No coredump support compiled in, so gInfo cannot have been set above. Unreachable in
    // practice; return false rather than claiming an erase we did not perform.
    return false;
#endif
}

// Consume det_log's durable EXPLICIT erase token, so "erase what this board stored" reaches both
// at-rest surfaces even when the ring wipe was already pending or power failed between the two
// erases. Call once per loop pass from the LOOP TASK (see the cache-off note in the header).
void acabCoredumpWipeTick() {
    if (!gProbed) return;
    const uint32_t generation = detLogSensitiveErasePending();
    if (generation == 0) return;   // overwhelmingly common path: one locked integer read

    // No retained image means the explicit promise is already satisfied. This also clears a
    // token left behind when the dump erase completed just before power failed.
    if (!gInfo.present && !gInfo.corrupt) {
        detLogSensitiveEraseComplete(generation);
        return;
    }

    const uint32_t now = millis();
    static uint32_t sWaitingGeneration = 0;
    static uint32_t sWaitStartedMs = 0;
    static uint32_t sAttemptedGeneration = 0;

    // A failed flash erase is retried after a reboot (the token survives while these statics do
    // not), or immediately for a NEW explicit generation. Do not hammer a bad 64 KB block every
    // loop pass.
    if (generation == sAttemptedGeneration) return;
    if (generation != sWaitingGeneration) {
        sWaitingGeneration = generation;
        sWaitStartedMs = now;
    }

    // STILL ONE BLOCK ERASE PER PASS. det_log sweeps its ring one 64 KB block per loop pass on
    // purpose: each erase holds the flash cache off ~100-250 ms, and the pass-sized gap keeps
    // GATT, scanning and the sink task live across the sweep. This partition is another whole
    // 64 KB block and detLogEraseTick() runs on the same pass (first thing in acabBleDrainTick),
    // so firing during the sweep would put two block erases back to back and double the stall the
    // chunking exists to bound. Wait for the ring to finish. BOUNDED, so a ring that never
    // finishes cannot strand the dump: the ring is the 1.5 MB data partition = 24 blocks at one
    // per pass, i.e. ~3-7 s including the loop delay, so 15 s is roughly 2x the worst sweep and
    // still fires on a board whose data partition is absent (the latch then stays set forever).
    static const uint32_t kRingSweepWaitMs = 15000;
    if (detLogWipePending() && (uint32_t)(now - sWaitStartedMs) < kRingSweepWaitMs) return;

    const bool erased = acabCoredumpErase();
    sAttemptedGeneration = generation;
    sWaitingGeneration = 0;
    if (erased) detLogSensitiveEraseComplete(generation);
    Serial.println(erased
                   ? "[coredump] retained dump erased for explicit sensitive-data wipe"
                   : "[coredump] retained dump erase FAILED - request retained for reboot/retry");
}

void acabCoredumpPrint() {
    if (!gInfo.present && !gInfo.corrupt) return;   // clean boot: say nothing
    // last_reset is THIS boot's reason, deliberately not called dump_reset: a retained dump can
    // predate this boot entirely (it survives resets and OTAs), so the two are different facts.
    const int rr = (int)esp_reset_reason();
    if (gInfo.corrupt) {
        Serial.printf("[coredump] retained dump state UNREADABLE/INVALID (%u B reported); erase "
                      "required, last_reset=%d\n", (unsigned)gInfo.sizeBytes, rr);
        return;
    }
    Serial.printf("[coredump] task=%s pc=0x%08x size=%uB v%u elf=%s last_reset=%d\n",
                  gInfo.task[0] ? gInfo.task : "?", (unsigned)gInfo.pc,
                  (unsigned)gInfo.sizeBytes, (unsigned)gInfo.dumpVersion,
                  gInfo.elfSha[0] ? gInfo.elfSha : "?", rr);
    Serial.println("[coredump] decode against the ELF with THAT sha (release provenance maps "
                   "sha -> version); the running version is not necessarily the one that crashed");
}
