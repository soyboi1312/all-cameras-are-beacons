#pragma once
// Wake-cause seam for otaBootCheck: an EXT0 wake (the owner toggled the board back on inside the
// trial window) must not count as a failed trial boot. Values match esp_sleep.h.
typedef enum {
    ESP_SLEEP_WAKEUP_UNDEFINED = 0,
    ESP_SLEEP_WAKEUP_ALL       = 1,
    ESP_SLEEP_WAKEUP_EXT0      = 2,
} esp_sleep_source_t;

inline esp_sleep_source_t acabHostWakeupCause = ESP_SLEEP_WAKEUP_UNDEFINED;
inline esp_sleep_source_t esp_sleep_get_wakeup_cause() { return acabHostWakeupCause; }
