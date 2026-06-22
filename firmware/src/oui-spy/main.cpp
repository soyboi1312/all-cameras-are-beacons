/*
 * ACAB - All Cameras Are Beacons
 * OUI-Spy build (Colonel Panic OUI-Spy / XIAO ESP32-S3).
 *
 * App-controlled counter-surveillance scanner. Runs Flock (BLE + WiFi), drone
 * Remote ID, and Axon detection at once; streams every hit to the
 * ACAB iOS app over BLE and beeps a per-class signature.
 *
 * Passive detect-and-report only - no transmit beyond BLE advertising, no
 * jamming, no spoofing.
 */
#include <Arduino.h>
#include "acab_scanner.h"
#include "axon_detect.h"
#include "police_detect.h"
#include "tracker_detect.h"
#include "acab_ble_service.h"
#include "alerts.h"
#include "det_log.h"

// Scanner sink: send each detection to the app, the buzzer, and serial.
static void onDetection(const AcabDetection& d, bool isNew) {
    acabBleNotifyDetection(d, isNew);
    alertsSignal(d.type, isNew);

    if (isNew) {
        char mac[18];
        acabFormatMac(d.mac, mac);
        Serial.printf("[ACAB] %-16s %-4s %s rssi=%d conf=%d %s%s\n",
                      acabTypeLabel(d.type), acabSourceLabel(d.src), mac,
                      d.rssi, d.confidence,
                      d.name[0] ? d.name : "", d.detail[0] ? d.detail : "");
    }
}

void setup() {
    Serial.begin(115200);
    delay(200);
    Serial.println("\n=== ACAB OUI-Spy " ACAB_FW_VERSION " ===");

    alertsInit();
    alertsBootJingle();

    // BLE service inits NimBLE + starts advertising for the app.
    acabBleBegin("ACAB");

    // Offline detection buffer: mount the flash ring + bump the boot counter. Stays
    // inert (no capture) until the app enables it and pushes an at-rest key.
    detLogBegin();

    // Scanner reuses the NimBLE stack we just inited (initNimBLE=false) and adds
    // WiFi promiscuous on top.
    AcabScannerConfig cfg = acabScannerDefaults();
    cfg.initNimBLE = false;
    cfg.bleDeviceName = "ACAB";

    // Axon body-cam detection on OUI 00:25:DF. Field-validated 2026-06-17: real
    // Axon body cams advertise this public OUI (payload reads "...BWC DEVICE").
    // See axon_detect.cpp.
    axonUseRegistryCandidate();
    axonSetEnabled(true);

    // Motorola Solutions / LE-gear detection (OUI 4C:CC:34): a broad LE-equipment proxy
    // (see police_detect.cpp), now folded into the body-cam category and tied to the
    // body-cam toggle. On at boot for the app build; the toggle controls it thereafter.
    policeSetEnabled(true);

    // Item-tracker detection: restore the persisted app toggle (default OFF), so a
    // tracker scan you enabled in the app survives a reboot. Off by default because
    // AirTags / Tiles are everywhere and would otherwise bury the surveillance hits.
    trackerRestoreEnabled(false);

    acabScannerBegin(cfg, onDetection);

    Serial.println("[ACAB] scanning: Flock BLE/WiFi + drone RID + Axon (OUI 00:25:DF)");
}

void loop() {
    // push a status notify every 5s to keep the app's uptime/count current
    static uint32_t lastStatus = 0;
    uint32_t now = millis();
    if (now - lastStatus > 5000) {
        lastStatus = now;
        acabBleUpdateStatus();
    }
    acabBleDrainTick();   // stream buffered detections back on the app's sync request
    delay(20);
}
