#pragma once
// Host seam for esp_reset_reason(). The enum mirrors the pinned esp-idf esp_system.h: v4.4 on the
// S3 envs ends at SDIO; the C5's v5.x appends USB/JTAG/EFUSE/PWR_GLITCH/CPU_LOCKUP after it, none
// of which counts as a physical start, so the suite does not need them. coredump_report.cpp is the
// source that calls esp_reset_reason(); det_log takes the physical-start decision as a parameter,
// and test_det_log maps acabHostResetReason through physicalStartFor into detLogBegin(bool) before
// each simulated boot. The default is a power-on, which is what the reboot fixtures already
// modelled.
typedef enum {
    ESP_RST_UNKNOWN = 0,
    ESP_RST_POWERON,
    ESP_RST_EXT,
    ESP_RST_SW,
    ESP_RST_PANIC,
    ESP_RST_INT_WDT,
    ESP_RST_TASK_WDT,
    ESP_RST_WDT,
    ESP_RST_DEEPSLEEP,
    ESP_RST_BROWNOUT,
    ESP_RST_SDIO,
} esp_reset_reason_t;

inline esp_reset_reason_t acabHostResetReason = ESP_RST_POWERON;
inline esp_reset_reason_t esp_reset_reason() { return acabHostResetReason; }
