/*
 * ACAB OUI-Spy - alert feedback implementation.
 *
 * The buzzer runs off an LEDC PWM channel so loudness is adjustable: tone
 * frequency sets the pitch, PWM duty sets the volume (0 = silent, ~50% duty =
 * loudest for a piezo). A dedicated FreeRTOS task drains the alert queue, so the
 * tone delays never stall the BLE/WiFi scanners.
 */
#include "alerts.h"
#include <Arduino.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#define BUZZER_LEDC_CHANNEL 0
#define BUZZER_LEDC_RES     8       // 8-bit duty (0..255)
#define BUZZER_DUTY_MAX     128     // ~50% duty = loudest into a piezo

static QueueHandle_t gAlertQ = nullptr;
static volatile bool    gBuzzer = true;
static volatile uint8_t gVolume = 80;   // 0..100

// Queue sentinel: a volume-preview beep rather than a detection pattern.
static const AcabDeviceType ACAB_ALERT_TEST = (AcabDeviceType)0xFE;

// --- persistence (NVS) ---
static void loadAudio() {
    Preferences p;
    p.begin("acab-audio", true);
    gBuzzer = p.getBool("buzz", true);
    gVolume = p.getUChar("vol", 80);
    p.end();
}
static void saveAudio() {
    Preferences p;
    p.begin("acab-audio", false);
    p.putBool("buzz", gBuzzer);
    p.putUChar("vol", gVolume);
    p.end();
}

void alertsSetBuzzerEnabled(bool on) { gBuzzer = on; saveAudio(); }
bool alertsBuzzerEnabled() { return gBuzzer; }

void alertsSetVolume(uint8_t v) {
    if (v > 100) v = 100;
    gVolume = v;
    saveAudio();
}
uint8_t alertsVolume() { return gVolume; }

// --- low-level output ---
static inline void ledOn()  { digitalWrite(ACAB_LED_PIN, LOW);  }
static inline void ledOff() { digitalWrite(ACAB_LED_PIN, HIGH); }

static void buzzerOff() { ledcWrite(BUZZER_LEDC_CHANNEL, 0); }

// Start a tone at `freq`, scaled to the current volume. Stays silent (LED-only
// alerts still work) when audio is off or volume is 0.
static void buzzerTone(int freq) {
    if (!gBuzzer || gVolume == 0 || freq <= 0) { buzzerOff(); return; }
    ledcWriteTone(BUZZER_LEDC_CHANNEL, freq);
    uint32_t duty = (uint32_t)gVolume * BUZZER_DUTY_MAX / 100;
    ledcWrite(BUZZER_LEDC_CHANNEL, duty);
}

static void beep(int freq, int durMs) {
    buzzerTone(freq);
    ledOn();
    vTaskDelay(pdMS_TO_TICKS(durMs));
    ledOff();
    buzzerOff();
}

// Harsh descending sweep - the crow "caw" used for Flock.
static void caw(int startF, int endF, int durMs) {
    int steps = durMs / 8;
    if (steps < 1) steps = 1;
    float fStep = (float)(endF - startF) / steps;
    ledOn();
    for (int i = 0; i < steps; i++) {
        int f = startF + (int)(fStep * i);
        if (f < 100) f = 100;
        buzzerTone(f);
        vTaskDelay(pdMS_TO_TICKS(8));
    }
    buzzerOff();
    ledOff();
}

// A different sound per target class.
static void playPattern(AcabDeviceType type) {
    switch (type) {
        case ACAB_FLOCK_CAMERA:           // two sharp caws
            caw(850, 380, 160); vTaskDelay(pdMS_TO_TICKS(60)); caw(820, 350, 160);
            break;
        case ACAB_FLOCK_RAVEN:            // rising alarm + caw (audio sensor)
            caw(400, 900, 110); vTaskDelay(pdMS_TO_TICKS(40)); caw(900, 350, 200);
            break;
        case ACAB_AXON_BODYCAM:           // three quick equal blips
            beep(1200, 90); vTaskDelay(pdMS_TO_TICKS(60));
            beep(1200, 90); vTaskDelay(pdMS_TO_TICKS(60));
            beep(1200, 90);
            break;
        case ACAB_DRONE:                  // Close Encounters mini-motif
            beep(587, 120); beep(659, 120); beep(523, 120);
            beep(262, 120); beep(392, 180);
            break;
        case ACAB_TRACKER:                // silent: opt-in and can flood, so no beep
            break;
        default:
            beep(800, 120);
            break;
    }
}

// FreeRTOS task: drain the alert queue and play patterns, off the callers' path.
static void alertTask(void*) {
    AcabDeviceType type;
    for (;;) {
        if (xQueueReceive(gAlertQ, &type, portMAX_DELAY) == pdTRUE) {
            if (type == ACAB_ALERT_TEST) beep(1500, 130);   // volume preview
            else                         playPattern(type);
        }
    }
}

// Set up the LED pin, the LEDC PWM for the buzzer, and the alert task.
void alertsInit() {
    pinMode(ACAB_LED_PIN, OUTPUT);
    ledOff();

    ledcSetup(BUZZER_LEDC_CHANNEL, 2000, BUZZER_LEDC_RES);
    ledcAttachPin(ACAB_BUZZER_PIN, BUZZER_LEDC_CHANNEL);
    buzzerOff();

    loadAudio();

    gAlertQ = xQueueCreate(16, sizeof(AcabDeviceType));
    xTaskCreatePinnedToCore(alertTask, "acabAlert", 4096, nullptr, 1, nullptr, 1);
}

void alertsBootJingle() {
    // Short ascending "armed" chirp.
    beep(784, 120); beep(988, 120); beep(1318, 200);
}

void alertsSignal(AcabDeviceType type, bool isNew) {
    if (!isNew || !gAlertQ) return;       // only beep on the first sighting
    xQueueSend(gAlertQ, &type, 0);        // drop if the queue is full, never block
}

void alertsBeepTest() {
    if (!gAlertQ) return;
    AcabDeviceType t = ACAB_ALERT_TEST;
    xQueueSend(gAlertQ, &t, 0);
}
