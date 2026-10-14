// Host regression for the beacon-board's real alert implementation.
//
// Alert mode and Desert mode both persist buzzer=false. That must silence EVERY sound the board
// can make: detection/session patterns, the boot jingle (2026-08-24: on button-less deploys a
// power restore reads as ESP_RST_POWERON, so a mute bypass there would let an unattended outage
// voice a muted covert board) and, since 2026-10-11, the power cues too (the hold-to-start ack
// and the slide/button/app shutdown motif used to bypass mute, which voiced a muted board on its
// way off). The boot jingle additionally plays on a PHYSICAL start only, so a warm reboot (panic,
// watchdog, brownout, OTA) is silent even unmuted, and the idle LED heartbeat stays dark until
// the soft-power gate commits. Include the real implementation so the test observes actual PWM
// and GPIO decisions rather than a copied policy function.
//
// TWO HALVES, observed two ways. The mute/volume/LED policy above plays straight through the tone
// helpers, so those cases assert on the PWM and GPIO spies. The four PRODUCT entry points
// (alertsSignal / alertsConnected / alertsBeepTest / alertsPowerOnAck) only ENQUEUE - alertTask is
// an infinite loop that no host test can step - so the queued block at the end of main() asserts
// on the alert queue itself. Both are the real implementation's real output; neither is a copy of
// its policy. Before the queue stub became a real FIFO (stubs/freertos/queue.h) that second half
// was invisible, and deleting the coalesce guard or the first-catch reveal kept this suite green.
#include "../../src/beacon-board/alerts.cpp"

#include <cstdio>
#include <string>

static int gFail = 0;
static int gRun = 0;

static void check(const char* name, bool pass) {
    gRun++;
    if (!pass) gFail++;
    printf("  %-66s %s\n", name, pass ? "PASS" : "**FAIL**");
}

// Pop the next thing alerts.cpp put on its own queue. This is exactly what alertTask consumes.
static bool nextQueued(AcabDeviceType* out) {
    return xQueueReceive(gAlertQ, out, 0) == pdTRUE;
}

static void resetAudio(bool enabled, uint8_t volume, bool ledEnabled = true) {
    gBuzzer = enabled;
    gVolume = volume;
    gLedEnabled = ledEnabled;
    gAlertTask = nullptr;
    acabHostResetOutputs();
    acabHostResetTaskSpies();
}

int main() {
    printf("\n=== alert mute vs power-state cues ===\n");

    resetAudio(false, 80);
    alertsBootJingle(true);
    check("muted board boots silent even on a deliberate physical start",
          acabHostNonzeroPwmWrites == 0);

    resetAudio(false, 80);
    alertsBootJingle(false);
    check("muted warm restart stays quiet", acabHostNonzeroPwmWrites == 0);

    resetAudio(true, 80);
    alertsBootJingle(true);
    check("unmuted physical start still voices the startup jingle",
          acabHostNonzeroPwmWrites > 0 && acabHostLastPwmDuty == 0);

    // A warm continuation is nothing the user did: no sound AND no light, whatever the mute state,
    // so a crash loop or a radio-induced panic cannot make the board announce itself.
    resetAudio(true, 80);
    alertsBootJingle(false);
    check("unmuted warm restart (panic, WDT, brownout, OTA) plays and lights nothing",
          acabHostNonzeroPwmWrites == 0 && acabHostLedLowWrites == 0);

    resetAudio(false, 80);
    playPowerOnAck();
    check("muted hold-to-start ack is LED-only: zero PWM, one LED flash",
          acabHostNonzeroPwmWrites == 0 && acabHostLedLowWrites == 1);

    resetAudio(true, 80);
    playPowerOnAck();
    check("unmuted hold-to-start ack still sounds (anti-vacuity)",
          acabHostNonzeroPwmWrites > 0 && acabHostLastPwmDuty == 0);

    resetAudio(false, 80);
    alertsPowerDown();
    check("muted shutdown (slide off, button hold, app power-off) stays silent",
          acabHostNonzeroPwmWrites == 0);

    resetAudio(true, 80);
    alertsPowerDown();
    check("unmuted deliberate shutdown voices the power-down jingle",
          acabHostNonzeroPwmWrites > 0 && acabHostLastPwmDuty == 0);
    // Band, not an exact melody sum: the cue must audibly play (>= 300 ms)
    // yet finish inside 1000 ms so deep sleep entry never clips it.
    check("power-down cue plays and finishes before deep sleep",
          acabHostTaskDelayTicks >= 300 && acabHostTaskDelayTicks < 1000);

    resetAudio(false, 80);
    playPattern(ACAB_AXON_BODYCAM);
    check("muted detection pattern remains silent", acabHostNonzeroPwmWrites == 0);

    resetAudio(true, 80);
    playPattern(ACAB_AXON_BODYCAM);
    check("enabled detection pattern still sounds (anti-vacuity)",
          acabHostNonzeroPwmWrites > 0);

    resetAudio(false, 80);
    playConnect();
    playReveal();
    beep(3000, 130);   // the volume-preview path uses this default UserAlert policy
    check("muted connect, reveal and volume-preview sounds stay silent",
          acabHostNonzeroPwmWrites == 0);

    // Unmuted, so the jingle's silence here comes from the volume gate alone, not the mute gate.
    resetAudio(true, 0);
    alertsBootJingle(true);
    alertsPowerDown();
    playPowerOnAck();
    check("volume zero remains absolute silence for every power cue",
          acabHostNonzeroPwmWrites == 0);

    resetAudio(true, 80, false);
    alertsBootJingle(true);
    check("lights out keeps the LED dark while unmuted boot audio still plays",
          acabHostNonzeroPwmWrites > 0 && acabHostLedLowWrites == 0);

    resetAudio(false, 80);
    alertsPowerDown();
    check("a muted shutdown cue never changes the alert-mute state",
          !alertsBuzzerEnabled());

    // ---- idle LED heartbeat vs the soft-power gate ------------------------------------------
    // heartbeatPulse is the exact branch alertTask runs on its queue timeout. The task is created
    // in alertsInit, BEFORE the gate (the gate needs the queue for its ack chirp), so a pocket-bump
    // wake or a charge-while-off boot sits in the park handshake for seconds with the task running:
    // it must produce no LED write until main.cpp arms it at the gate's commit.
    resetAudio(true, 80);
    heartbeatPulse();
    check("idle heartbeat stays dark before the soft-power gate commits",
          acabHostLedLowWrites == 0);
    alertsArmHeartbeat();
    heartbeatPulse();
    check("idle heartbeat pulses once the gate has committed (anti-vacuity)",
          acabHostLedLowWrites == 1);

    // ---- queued dispatch: reveal arming and per-type burst coalescing ----------------------
    // Nothing below touches the PWM spies: alertsSignal() hands the alert task a type and returns,
    // so the queue IS its output. The two decisions it makes on the way - spend the reveal on the
    // first real surveillance hit of a session, then hold the buzzer for ALERT_COALESCE_MS per
    // type - had no coverage at all before this block.
    //
    // NOT millis() == 0: gLastAlertMs stores 0 to mean "this type has never alerted", so with the
    // clock at zero every window it opens reads back as never-opened and the coalesce cases below
    // would fail for a reason that has nothing to do with the code under test.
    acabHostSetMillis(10000);
    alertsInit();            // makes the queue and arms the first-catch reveal, exactly as at boot
    resetAudio(true, 80);    // alertsInit re-read NVS defaults; pin the state these cases want

    AcabDeviceType queued = ACAB_NEARBY_DEVICE;
    alertsSignal(ACAB_TRACKER, true);
    check("a tracker is queued but never spends the session reveal",
          nextQueued(&queued) && queued == ACAB_TRACKER);

    alertsSignal(ACAB_AXON_BODYCAM, true);
    check("the first real surveillance hit of a session spends the reveal",
          nextQueued(&queued) && queued == ACAB_ALERT_REVEAL);

    alertsSignal(ACAB_AXON_BODYCAM, true);
    check("a second body cam inside the coalesce window is held back",
          !nextQueued(&queued));

    alertsSignal(ACAB_FLOCK_CAMERA, true);
    check("a DIFFERENT class inside that same window still alerts",
          nextQueued(&queued) && queued == ACAB_FLOCK_CAMERA);

    acabHostAdvanceMillis(ALERT_COALESCE_MS);
    alertsSignal(ACAB_AXON_BODYCAM, true);
    check("the same class alerts again once its window has expired",
          nextQueued(&queued) && queued == ACAB_AXON_BODYCAM);

    alertsSignal(ACAB_DRONE, false);
    check("a repeat sighting (isNew false) is never queued", !nextQueued(&queued));

    alertsConnected();
    check("linking the app queues the connect chirp",
          nextQueued(&queued) && queued == ACAB_ALERT_CONNECT);
    alertsSignal(ACAB_FLOCK_CAMERA, true);
    check("connecting re-arms the reveal for the new session",
          nextQueued(&queued) && queued == ACAB_ALERT_REVEAL);

    alertsBeepTest();
    check("the volume preview rides the queue as its own sentinel",
          nextQueued(&queued) && queued == ACAB_ALERT_TEST);
    alertsPowerOnAck();
    check("the hold-to-start ack rides the queue as its own sentinel",
          nextQueued(&queued) && queued == ACAB_ALERT_POWER_ON);
    check("nothing else was queued along the way", acabHostQueueDepth(gAlertQ) == 0);

    // ---- the [diag] line renders the sink-drop counters ------------------------------------
    // acabScannerSinkDropsFirehose/Signature exist for the serial [diag] line and nothing else
    // (acab_scanner.h), so a main.cpp that stops printing them from that printf leaves the one
    // telemetry item they feed written but never rendered. Text pin on the real source, read
    // relative to firmware/tools/host-tests like test_acab_ble_service.cpp's lifecycle pins; an
    // unreadable file fails the check rather than passing it.
    {
        std::string m;
        if (FILE* f = fopen("../../src/beacon-board/main.cpp", "rb")) {
            char b[8192]; size_t n;
            while ((n = fread(b, 1, sizeof(b), f)) > 0) m.append(b, n);
            fclose(f);
        }
        const size_t at  = m.find("\"[diag] wifi_seen=");
        const size_t end = at == std::string::npos ? at : m.find(");", at);
        const std::string stmt = end == std::string::npos ? std::string() : m.substr(at, end - at);
        check("beacon-board [diag] renders both sink-drop counters (sinkdrop=f/s)",
              stmt.find("sinkdrop=%lu/%lu") != std::string::npos &&
              stmt.find("acabScannerSinkDropsFirehose()") != std::string::npos &&
              stmt.find("acabScannerSinkDropsSignature()") != std::string::npos);
    }

    printf(gFail ? "\n  REGRESSION DETECTED (%d failure%s of %d)\n\n"
                 : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail == 1 ? "" : "s", gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
