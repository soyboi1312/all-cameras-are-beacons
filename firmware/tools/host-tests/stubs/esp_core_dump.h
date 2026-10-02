#pragma once
// ESP-IDF coredump seam for coredump_report.cpp's fail-closed state machine.
//
// THE PARTITION IS THE STATE. These functions derive their result from the bytes of the fake
// flash in esp_partition.h (in this suite it stands for the coredump partition), the way the
// pinned IDF does. Mirrored from ESP-IDF v4.4.7 components/espcoredump/src/core_dump_flash.c and
// checked against the prebuilt libespcoredump.a that espressif32@6.13.0 links:
//   - esp_core_dump_partition_and_size_get(): no partition -> ESP_ERR_NOT_FOUND; first word
//     0xFFFFFFFF ("Blank core dump partition!") -> ESP_ERR_INVALID_SIZE; a size word under 4 or
//     over the partition size -> ESP_ERR_INVALID_SIZE; a read error is returned as it is.
//   - esp_core_dump_image_erase(): erase the whole partition, then write {0xFFFFFFFF, 0, 0, 0}.
// So on this IDF a blank partition is NOT ESP_ERR_NOT_FOUND, whatever esp_core_dump.h documents.
// An earlier version of this stub returned NOT_FOUND for the empty case; that mirrored the header
// comment, not the implementation. It hid a probe that printed "erase required" on every boot
// and erased the 64 KB partition once per boot on any board a phone connects to.
//
// NOT MODELLED: the checksum pass and the ELF summary. For an image with a plausible size word,
// acabHostCoreCheckResult is the checksum verdict and acabHostCoreSummary* is the summary.
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "esp_partition.h"

static const esp_err_t ESP_ERR_INVALID_SIZE = 0x104;
static const esp_err_t ESP_ERR_NOT_FOUND = 0x105;
static const esp_err_t ESP_ERR_INVALID_CRC = 0x109;

struct esp_core_dump_summary_t {
    uint32_t exc_pc;
    uint32_t core_dump_version;
    char exc_task[24];
    char app_elf_sha256[65];
};

static const size_t ACAB_HOST_CORE_PART_SIZE = 64 * 1024;   // default_8MB.csv: coredump, 0x10000

inline esp_err_t acabHostCoreCheckResult = ESP_OK;     // checksum verdict for a sized image
inline esp_err_t acabHostCoreGetResult = ESP_OK;       // != ESP_OK: image_get faults after the check
inline esp_err_t acabHostCoreSummaryResult = ESP_FAIL;
inline esp_core_dump_summary_t acabHostCoreSummary{};

// A fresh case is a factory-blank partition: every byte 0xFF.
inline void acabHostCoreDumpReset() {
    acabHostPartitionReset(ACAB_HOST_CORE_PART_SIZE);
    acabHostPartitionSubtype = ESP_PARTITION_SUBTYPE_DATA_COREDUMP;
    acabHostCoreCheckResult = ESP_OK;
    acabHostCoreGetResult = ESP_OK;
    acabHostCoreSummaryResult = ESP_FAIL;
    memset(&acabHostCoreSummary, 0, sizeof(acabHostCoreSummary));
}

// Put a dump header in the partition: the first word is the total image length.
inline void acabHostCoreSetSizeWord(uint32_t size) {
    for (size_t i = 0; i < sizeof(size); i++) acabHostPartitionCorrupt(i, (uint8_t)(size >> (8 * i)));
}

inline esp_err_t acabHostCorePartitionAndSize(uint32_t* size) {
    const esp_partition_t* part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_COREDUMP, nullptr);
    if (!part) return ESP_ERR_NOT_FOUND;
    uint32_t word = 0;
    const esp_err_t err = esp_partition_read(part, 0, &word, sizeof(word));
    if (err != ESP_OK) return err;
    if (word == 0xFFFFFFFF) return ESP_ERR_INVALID_SIZE;
    if (word < sizeof(uint32_t) || word > part->size) return ESP_ERR_INVALID_SIZE;
    if (size) *size = word;
    return ESP_OK;
}

inline esp_err_t esp_core_dump_image_check() {
    const esp_err_t err = acabHostCorePartitionAndSize(nullptr);
    return err != ESP_OK ? err : acabHostCoreCheckResult;
}
inline esp_err_t esp_core_dump_image_get(size_t* address, size_t* size) {
    if (acabHostCoreGetResult != ESP_OK) return acabHostCoreGetResult;
    uint32_t word = 0;
    const esp_err_t err = acabHostCorePartitionAndSize(&word);
    if (err != ESP_OK) return err;
    if (address) *address = 0;
    if (size) *size = word;
    return ESP_OK;
}
inline esp_err_t esp_core_dump_get_summary(esp_core_dump_summary_t* out) {
    if (out && acabHostCoreSummaryResult == ESP_OK) *out = acabHostCoreSummary;
    return acabHostCoreSummaryResult;
}
inline esp_err_t esp_core_dump_image_erase() {
    const uint32_t helper[4] = { 0xFFFFFFFF, 0, 0, 0 };
    const esp_partition_t* part = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_COREDUMP, nullptr);
    if (!part) return ESP_ERR_NOT_FOUND;
    const esp_err_t err = esp_partition_erase_range(part, 0, part->size);
    if (err != ESP_OK) return err;
    return esp_partition_write(part, 0, helper, sizeof(helper));
}
