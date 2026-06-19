/*
 * ACAB - All Cameras Are Beacons
 * Mesh-Detect build (Colonel Panic Mesh-Detect: XIAO ESP32-S3 + Heltec V3).
 *
 * The XIAO scans for Flock (BLE + WiFi), drone Remote ID, and
 * Axon body cams, then sends labelled alerts over the wired Heltec V3 Meshtastic
 * node - on a channel index of your choosing, not just the public channel.
 *
 * Passive detect-and-report only.
 */
#include <Arduino.h>
#include "acab_scanner.h"
#include "axon_detect.h"
#include "tracker_detect.h"
#include "police_detect.h"
#include "acab_version.h"
#include "mesh_link.h"

// Onboard LED (XIAO S3, inverted: LOW = on) - brief blink on each new detection.
#ifndef ACAB_LED_PIN
#define ACAB_LED_PIN 21
#endif

// Meshtastic channel we transmit on. 0 = primary/public, sent as a TextMessage
// (matches the stock Mesh-Detect Heltec config, so your node stays on the public
// LongFast mesh). Set a secondary index (e.g. -DACAB_MESH_CHANNEL=1) to send
// detections privately over PROTO instead.
#ifndef ACAB_MESH_CHANNEL
#define ACAB_MESH_CHANNEL 0
#endif

// How often the diagnostic heartbeat fires. With -DACAB_DIAG, the unit pushes a
// radio-health line to the mesh this often, so a drive test is readable without a
// serial cable. ACAB_DIAG also turns on a chatty per-advert serial log (see
// acab_scanner).
#ifndef ACAB_HEARTBEAT_MS
#define ACAB_HEARTBEAT_MS 120000
#endif

// Scanner sink: forward every hit to the mesh, blink the LED on first sighting.
static void onDetection(const AcabDetection& d, bool isNew) {
    meshLinkSend(d, isNew);
    if (isNew) {
        char mac[18];
        acabFormatMac(d.mac, mac);
        Serial.printf("[ACAB] %-16s %-4s %s rssi=%d conf=%d\n",
                      acabTypeLabel(d.type), acabSourceLabel(d.src), mac,
                      d.rssi, d.confidence);
        digitalWrite(ACAB_LED_PIN, LOW);
        delay(40);
        digitalWrite(ACAB_LED_PIN, HIGH);
    }
}

void setup() {
    Serial.begin(115200);
    delay(200);
    Serial.println("\n=== ACAB Mesh-Detect " ACAB_FW_VERSION " ===");

    pinMode(ACAB_LED_PIN, OUTPUT);
    digitalWrite(ACAB_LED_PIN, HIGH);

    MeshLinkConfig mesh = meshLinkDefaults();
    mesh.channelIndex = ACAB_MESH_CHANNEL;
    // Channel 0 = public -> TextMessage (matches the stock Heltec Serial Module
    // config); any other channel needs PROTO to target that specific index.
    mesh.transport = (ACAB_MESH_CHANNEL == 0) ? MESH_TEXT : MESH_PROTO;
    meshLinkBegin(mesh);

    // No GATT server here, so this build owns the BLE stack - let the scanner init it.
    AcabScannerConfig cfg = acabScannerDefaults();
    cfg.initNimBLE = true;
    cfg.bleDeviceName = "ACAB-mesh";

    // Axon body-cam detection on OUI 00:25:DF (field-validated 2026-06-17: real
    // Axon body cams advertise this public OUI). See axon_detect.cpp.
    axonUseRegistryCandidate();
    axonSetEnabled(true);

    // Item-tracker detection stays OFF here: AirTags / Tiles / SmartTags are
    // everywhere, and flooding them over a rate-limited LoRa uplink would bury the
    // surveillance hits. (Already off by default; set it explicitly to lock it in.)
    trackerSetEnabled(false);

    // Police/Motorola-gear detection: OFF on the mesh build too - a broad OUI match
    // would add chatter to the rate-limited LoRa uplink. Flip on if you want it.
    policeSetEnabled(false);

    acabScannerBegin(cfg, onDetection);

    Serial.printf("[ACAB] scanning + meshing on channel %u "
                  "(Flock BLE/WiFi + drone RID + Axon OUI 00:25:DF)\n",
                  meshLinkChannel());
}

void loop() {
    static uint32_t lastBeat = 0;
    static uint32_t lastMeshBeat = 0;
    static bool bootPinged = false;
    uint32_t now = millis();

    // One-time boot self-test: announce on the mesh ~10s after power-up, once the
    // Heltec is up, to check the send path without waiting for a detection.
    if (!bootPinged && now > 10000) {
        bootPinged = true;
        meshLinkSendText("mesh-detect ACAB online");
        lastMeshBeat = now;
    }

    if (now - lastBeat > 60000) {
        lastBeat = now;
        Serial.printf("[ACAB] alive | ble=%lu wifi=%lu det=%lu\n",
                      (unsigned long)acabScannerBleSeen(),
                      (unsigned long)acabScannerWifiSeen(),
                      (unsigned long)acabScannerTotalDetections());
    }

#ifdef ACAB_DIAG
    // Push radio-health counts to the mesh so a drive test is readable without a
    // serial cable. Next to a known camera: rising ble/wifi with det=0 means a
    // signature or range miss; flat ble/wifi means a dead radio or antenna.
    if (bootPinged && now - lastMeshBeat > ACAB_HEARTBEAT_MS) {
        lastMeshBeat = now;
        char hb[96];
        snprintf(hb, sizeof(hb), "ACAB diag | ble=%lu wifi=%lu det=%lu",
                 (unsigned long)acabScannerBleSeen(),
                 (unsigned long)acabScannerWifiSeen(),
                 (unsigned long)acabScannerTotalDetections());
        meshLinkSendText(hb);
    }
#endif

    delay(50);
}
