#include "coredump_report.h"
#include <Arduino.h>
#include <string.h>

// esp_core_dump_* is only present when the IDF coredump-to-flash option is compiled in, which is
// the case for the shipped 8 MB partition layout. Guard anyway so a stripped or third-party build
// still links: the whole feature degrades to "no dump reported", never to a build break.
#if __has_include(<esp_core_dump.h>)
  #include <esp_core_dump.h>
  #define ACAB_HAVE_COREDUMP 1
#endif
#include <esp_system.h>

static AcabCoredumpInfo gInfo{};

const AcabCoredumpInfo& acabCoredumpInfo() { return gInfo; }

void acabCoredumpProbe() {
    memset(&gInfo, 0, sizeof(gInfo));
#ifdef ACAB_HAVE_COREDUMP
    size_t addr = 0, size = 0;
    // image_check() validates the stored dump end to end. ESP_ERR_NOT_FOUND is the ordinary
    // "clean boot, nothing retained" case and is NOT an error worth reporting.
    esp_err_t chk = esp_core_dump_image_check();
    if (esp_core_dump_image_get(&addr, &size) == ESP_OK && size > 0) {
        gInfo.sizeBytes = (uint32_t)size;
        if (chk == ESP_OK) {
            gInfo.present = true;
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
        } else {
            // A dump region exists but does not validate: truncated (the 64 KB partition is a hard
            // ceiling, ~9 tasks is the expected edge) or corrupted. Report it as such - silently
            // treating it as "no crash" is how a crashing board looks healthy.
            gInfo.corrupt = true;
        }
    }
#endif
}

void acabCoredumpPrint() {
    if (!gInfo.present && !gInfo.corrupt) return;   // clean boot: say nothing
    // last_reset is THIS boot's reason, deliberately not called dump_reset: a retained dump can
    // predate this boot entirely (it survives resets and OTAs), so the two are different facts.
    const int rr = (int)esp_reset_reason();
    if (gInfo.corrupt) {
        Serial.printf("[coredump] retained dump present but INVALID (%u B, likely truncated at the "
                      "64KB partition) last_reset=%d\n", (unsigned)gInfo.sizeBytes, rr);
        return;
    }
    Serial.printf("[coredump] task=%s pc=0x%08x size=%uB v%u elf=%s last_reset=%d\n",
                  gInfo.task[0] ? gInfo.task : "?", (unsigned)gInfo.pc,
                  (unsigned)gInfo.sizeBytes, (unsigned)gInfo.dumpVersion,
                  gInfo.elfSha[0] ? gInfo.elfSha : "?", rr);
    Serial.println("[coredump] decode against the ELF with THAT sha (release provenance maps "
                   "sha -> version); the running version is not necessarily the one that crashed");
}
