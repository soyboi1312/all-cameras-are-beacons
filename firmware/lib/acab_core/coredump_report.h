/*
 * ACAB - surface the ESP-IDF core dump that the board is ALREADY capturing.
 *
 * WHY THIS EXISTS. The shipped partition table (`default_8MB.csv`) already carries
 * `coredump @ 0x7F0000, 64 KB`, and IDF's espcoredump (flash target, ELF format) is already
 * compiled into the image. Nothing in ACAB has ever read it. So every panic this product has had
 * in the field wrote a full post-mortem to flash and then sat there, invisible, until the next
 * flash erase took it. This header is the smallest thing that changes that: one line on the serial
 * console at boot, and the same fields in the {"diag":true} reply.
 *
 * DELIBERATELY NOT TOUCHING THE PARTITION TABLE. A resize would invalidate every board in the
 * field (the table is flashed once, and a mismatched table bricks the OTA layout), and truncation
 * has not been PROVEN yet - it is expected around ~9 tasks. The boot check reports a truncated or
 * invalid dump as such rather than pretending, which is the honest handling either way.
 *
 * WHAT THE SUMMARY ACTUALLY CONTAINS - this trips people up. esp_core_dump_summary_t carries the
 * excepting task, PC, backtrace, dump version, and the APP ELF SHA256. It does NOT carry a
 * semantic firmware version. So:
 *   - print the ELF SHA, and let the release provenance map SHA -> version;
 *   - NEVER label a dump with the running ACAB_FW_VERSION. A retained dump can predate the current
 *     boot and SURVIVES AN OTA, so the running version is frequently not the version that crashed;
 *   - label the current boot's esp_reset_reason() as `last_reset`, not `dump_reset`, for the same
 *     reason: it describes this boot, not necessarily the dump.
 */
#ifndef ACAB_COREDUMP_REPORT_H
#define ACAB_COREDUMP_REPORT_H

#include <stdint.h>
#include <stdbool.h>

/// Cached, printable view of the retained dump. Read once at boot (the flash read is not free and
/// the contents cannot change while we run) and reused by the diag reply.
struct AcabCoredumpInfo {
    bool     present;        ///< a dump was found AND passed esp_core_dump_image_check()
    bool     corrupt;        ///< a dump region exists but failed the integrity check
    uint32_t sizeBytes;      ///< image size as reported by the check
    char     task[24];       ///< crashing task name, empty when unavailable
    uint32_t pc;             ///< program counter at the exception
    char     elfSha[41];     ///< app ELF SHA256, hex; maps to a version via release provenance
    uint32_t dumpVersion;    ///< core-dump format version
};

/// Read + cache the retained dump's summary. Safe to call when no dump exists (sets present=false)
/// and on builds where the coredump partition is absent. Call once, early in setup(), after
/// Serial is up so the one-line report is visible.
void acabCoredumpProbe();

/// The cached result. Zeroed until acabCoredumpProbe() runs.
const AcabCoredumpInfo& acabCoredumpInfo();

/// Print the one-line `[coredump]` report (or nothing when there is no dump and no corruption).
void acabCoredumpPrint();

#endif // ACAB_COREDUMP_REPORT_H
