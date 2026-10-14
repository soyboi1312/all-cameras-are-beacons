#pragma once
// Two-slot OTA layout for test_ota_update.cpp: the running slot and the inactive one Update
// writes into. The test says which slot runs and what each slot's app descriptor reads; the
// boot-partition switch and esp_restart() are recorded, never performed.
#include <esp_partition.h>
#include <esp_app_format.h>
#include <stdint.h>

inline esp_partition_t acabHostOtaSlot0 = { 0x100000, 0x010000 };   // size, address
inline esp_partition_t acabHostOtaSlot1 = { 0x100000, 0x330000 };
inline const esp_partition_t* acabHostRunningSlot = &acabHostOtaSlot0;

inline esp_app_desc_t acabHostRunningDesc = {};   // what the running image's header says
inline esp_app_desc_t acabHostPendingDesc = {};   // what the inactive slot's header says after a write
inline bool acabHostPendingDescReadable = true;

inline const esp_partition_t* acabHostBootPartition = nullptr;   // last successful set_boot_partition
inline uint32_t acabHostSetBootCalls = 0;
inline uint32_t acabHostRestarts = 0;

inline void acabHostOtaReset() {
    acabHostRunningSlot = &acabHostOtaSlot0;
    acabHostRunningDesc = {};
    acabHostPendingDesc = {};
    acabHostPendingDescReadable = true;
    acabHostBootPartition = nullptr;
    acabHostSetBootCalls = 0;
    acabHostRestarts = 0;
}

inline const esp_partition_t* esp_ota_get_running_partition() { return acabHostRunningSlot; }
inline const esp_partition_t* esp_ota_get_next_update_partition(const esp_partition_t*) {
    return acabHostRunningSlot == &acabHostOtaSlot0 ? &acabHostOtaSlot1 : &acabHostOtaSlot0;
}
// IDF 4.4 getter (the S3 envs); ota_update.cpp maps the IDF 5 name onto the same struct.
inline const esp_app_desc_t* esp_ota_get_app_description() { return &acabHostRunningDesc; }
inline esp_err_t esp_ota_get_partition_description(const esp_partition_t* p, esp_app_desc_t* out) {
    if (!p || !out || p == acabHostRunningSlot || !acabHostPendingDescReadable) return ESP_FAIL;
    *out = acabHostPendingDesc;
    return ESP_OK;
}
inline esp_err_t esp_ota_set_boot_partition(const esp_partition_t* p) {
    acabHostSetBootCalls++;
    if (!p) return ESP_FAIL;
    acabHostBootPartition = p;
    return ESP_OK;
}
// On the board this never returns; otaBootCheck's own code after it is a bare p.end()/return, so
// a counting stub is safe. Declared here rather than in esp_system.h, which is another suite's
// seam and which ota_update.cpp does not include.
inline void esp_restart() { acabHostRestarts++; }
