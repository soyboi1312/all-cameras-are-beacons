/*
 * ACAB OUI-Spy - local alert feedback (buzzer + onboard LED).
 * Each target class gets its own audible signature, so you can tell what was
 * detected without looking at the phone. Buzzer volume and on/off come from the
 * app and persist across reboots.
 */
#ifndef ACAB_ALERTS_H
#define ACAB_ALERTS_H

#include "detection.h"

// XIAO ESP32-S3 pins (override via build flags if your board differs).
#ifndef ACAB_BUZZER_PIN
#define ACAB_BUZZER_PIN 3
#endif
#ifndef ACAB_LED_PIN
#define ACAB_LED_PIN 21      // onboard orange LED, inverted (LOW = on)
#endif

void alertsInit();
void alertsBootJingle();

// Queue a non-blocking alert for a detection. Only `isNew` hits beep.
void alertsSignal(AcabDeviceType type, bool isNew);

// Master audio on/off. Persisted to NVS.
void alertsSetBuzzerEnabled(bool on);
bool alertsBuzzerEnabled();

// Buzzer loudness, 0..100. 0 is silent (LED still flashes). Persisted to NVS.
void alertsSetVolume(uint8_t volume);
uint8_t alertsVolume();

// Short preview beep at the current volume, so you can hear the level (the app
// fires this when the volume slider is released). Silent while muted.
void alertsBeepTest();

#endif // ACAB_ALERTS_H
