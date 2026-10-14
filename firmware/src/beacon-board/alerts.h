/*
 * ACAB OUI-Spy - local alert feedback (buzzer + onboard LED).
 * Each target class gets its own audible signature, so you can tell what was
 * detected without looking at the phone. Detection-alert audio and volume come
 * from the app and persist across reboots. MUTE WINS FOR EVERY SOUND (2026-10-11): the boot
 * motif, the hold-to-start ack and the power-down cue all stay silent while detection alerts
 * are muted, exactly like a detection pattern. A muted board emitting sound ranks above a crash
 * in this repo's defect order, and every power cue already has a silent twin: the LED flash
 * (governed by lights out), the slide switch's own position, the app's {"pwr":"off"} notify.
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
// Startup motif. Plays ONLY on a physical start (power applied, button held, switch on: the one
// host-tested acabPhysicalStart decision the call site also feeds the pairing gate) and never on
// a warm continuation (OTA restart, panic, watchdog, brownout), so nothing that can induce a
// crash from radio range can make the board announce itself. Honors detection-alert mute in
// EVERY case on top of that: on the button-less deploys ESP_RST_POWERON cannot be told apart from
// an unattended power restore (see alertsBootJingle).
void alertsBootJingle(bool physicalStart);

// Queued confirmation that the hold-to-start gate committed to ON. Honors detection-alert mute
// like every other sound; while muted the cue is its LED flash alone (lights out governs that).
void alertsPowerOnAck();

// The mirror image of the boot jingle: a short DESCENDING "powering down" motif that ENDS LOW,
// where boot rises and ends high ("...alive?"). Play it on a real running->off transition (slide
// to 'off', button hold, app power-off) so the user can HEAR off from on - the faint 25ms
// heartbeat LED never made that legible, and the red light is the charger's, not ours. Blocking
// (~0.7s), safe to call right before deep sleep. Suspends the alert task first (alertsQuiesce),
// so this is the last thing heard. Honors detection-alert mute: a muted board goes off silently,
// and the switch position or the app's {"pwr":"off"} notify is the confirmation. The LED still
// honors lights out, and volume 0 remains fully silent.
void alertsPowerDown();

// Stop the alert task and every output, for a park path that must emit nothing more: the silent
// boot-gate re-sleeps (a pocket bump, charge-while-off) call this at the top of powerOffDeepSleep
// so the task cannot pulse the LED while the nRF park handshake runs. Never resumes; the only
// callers are about to deep-sleep.
void alertsQuiesce();

// Let the idle LED heartbeat run. The alert task is created in alertsInit, BEFORE the soft-power
// gate (the gate needs the queue for its ack chirp), and until this is called its idle timeout
// produces no LED write, so a boot that only wakes to conclude it should sleep stays dark. Call
// it once, right after the gate commits to staying on.
void alertsArmHeartbeat();

// Play the "app linked" chirp once when the BLE connection comes up, and arm the
// first-contact "reveal" sting for this session. Call on the rising edge of a link.
void alertsConnected();

// Queue a non-blocking alert for a detection. Only `isNew` hits beep.
void alertsSignal(AcabDeviceType type, bool isNew);

// Detection/session alert audio on/off. Persisted to NVS. Off silences every sound the board
// can make, the power cues included; only the LED paths keep running (see alertsSetLedEnabled).
void alertsSetBuzzerEnabled(bool on);
bool alertsBuzzerEnabled();

// Buzzer loudness, 0..100. 0 is silent (LED still flashes). Persisted to NVS.
void alertsSetVolume(uint8_t volume);
uint8_t alertsVolume();

// Short preview beep at the current volume, so you can hear the level (the app
// fires this when the volume slider is released). Silent while muted.
void alertsBeepTest();

// Onboard LED master on/off. On (default) = a slow idle "alive" heartbeat + the
// detection flashes + the boot sweep, so a first-time board never looks dead. Off
// ("lights out") = fully dark, for covert/stationary deploys. Persisted to NVS.
void alertsSetLedEnabled(bool on);
bool alertsLedEnabled();

#endif // ACAB_ALERTS_H
