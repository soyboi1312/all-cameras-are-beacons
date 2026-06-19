/*
 * ACAB - Unified scanner implementation.
 *
 * Concurrency (same WiFi-promiscuous + NimBLE combo sky-spy proved out on the
 * XIAO ESP32-S3):
 *   - BLE scan runs in its own FreeRTOS task (bleScanTask).
 *   - The WiFi promiscuous RX callback runs in the WiFi driver task.
 *   - Both funnel through handleDetection(), which grabs a short critical
 *     section just to touch the dedup table, then calls the sink outside it.
 */
#include "acab_scanner.h"
#include "flock_detect.h"
#include "axon_detect.h"
#include "drone_detect.h"
#include "tracker_detect.h"
#include "police_detect.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <freertos/queue.h>
#include <atomic>

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static AcabScannerConfig  gCfg;
static AcabDetectionSink  gSink = nullptr;
static NimBLEScan*        gScan = nullptr;
static QueueHandle_t      gSinkQ = nullptr;   // detections handed off to sinkTask

static portMUX_TYPE       gDedupMux = portMUX_INITIALIZER_UNLOCKED;
static std::atomic<uint32_t> gTotal{0};      // both radios write it, so atomic
static std::atomic<uint32_t> gBleSeen{0};    // raw BLE adverts seen (diagnostic)
static std::atomic<uint32_t> gWifiSeen{0};   // raw 802.11 mgmt frames seen (diagnostic)
static volatile bool      gBleEnabled = true;   // app-toggleable BLE scan
static volatile bool      gWifiEnabled = true;  // app-toggleable WiFi scan

static double gSelfLat = 0, gSelfLon = 0;
static bool   gSelfGPSValid = false;

// Dedup table -------------------------------------------------------------
// One entry per device we've recently seen, so we don't re-report it every advert.
struct DedupEntry {
    bool          used;
    AcabDeviceType type;
    uint8_t       mac[6];
    uint32_t      firstSeen;
    uint32_t      lastSeen;
    uint16_t      count;
};
#define ACAB_DEDUP_MAX 96
static DedupEntry gDedup[ACAB_DEDUP_MAX];

// Whitelist (app-pushed): MACs we drop silently - no report, beep, or mesh.
#define ACAB_IGNORE_MAX 32
static uint8_t      gIgnore[ACAB_IGNORE_MAX][6];
static volatile int gIgnoreCount = 0;
static portMUX_TYPE gIgnoreMux = portMUX_INITIALIZER_UNLOCKED;

static bool isIgnored(const uint8_t mac[6]) {
    bool hit = false;
    portENTER_CRITICAL(&gIgnoreMux);
    for (int i = 0; i < gIgnoreCount; i++)
        if (memcmp(gIgnore[i], mac, 6) == 0) { hit = true; break; }
    portEXIT_CRITICAL(&gIgnoreMux);
    return hit;
}

// Persist the whitelist to NVS so it survives reboots - the app doesn't have to
// re-push it, and a board keeps ignoring known-friendly tags on its own.
static void saveIgnoreList() {
    Preferences p;
    p.begin("acab-ignore", false);
    p.putInt("n", gIgnoreCount);
    if (gIgnoreCount > 0) p.putBytes("macs", gIgnore, (size_t)gIgnoreCount * 6);
    p.end();
}

static void loadIgnoreList() {
    Preferences p;
    p.begin("acab-ignore", true);
    int n = p.getInt("n", 0);
    if (n < 0) n = 0;
    if (n > ACAB_IGNORE_MAX) n = ACAB_IGNORE_MAX;
    if (n > 0) p.getBytes("macs", gIgnore, (size_t)n * 6);
    p.end();
    gIgnoreCount = n;
}

// The entry for (type, mac), creating/evicting as needed. Caller holds the mux.
static DedupEntry* dedupFind(AcabDeviceType type, const uint8_t mac[6]) {
    DedupEntry* freeSlot = nullptr;
    DedupEntry* oldest = nullptr;
    for (int i = 0; i < ACAB_DEDUP_MAX; i++) {
        DedupEntry* e = &gDedup[i];
        if (e->used && e->type == type && memcmp(e->mac, mac, 6) == 0) return e;
        if (!e->used && !freeSlot) freeSlot = e;
        if (e->used && (!oldest || e->lastSeen < oldest->lastSeen)) oldest = e;
    }
    DedupEntry* slot = freeSlot ? freeSlot : oldest;
    slot->used = true;
    slot->type = type;
    memcpy(slot->mac, mac, 6);
    slot->firstSeen = 0;
    slot->lastSeen = 0;
    slot->count = 0;
    return slot;
}

// The sink runs on its own task so heavy work (serial, BLE notify, mesh UART)
// never runs inside the WiFi driver callback or the BLE scan task - the radios
// just enqueue and move on.
struct SinkItem { AcabDetection d; bool isNew; };

static void sinkTask(void*) {
    SinkItem it;
    for (;;)
        if (xQueueReceive(gSinkQ, &it, portMAX_DELAY) == pdTRUE && gSink)
            gSink(it.d, it.isNew);
}

// Drones rotate their MAC and broadcast on both radios, so key them by UAS-ID
// instead - the stable "one drone = one entry" identity. Everything else keys by
// MAC. Returns d.mac, or a hashed 6-byte key written into scratch.
static const uint8_t* dedupKey(const AcabDetection& d, uint8_t scratch[6]) {
    if (d.type == ACAB_DRONE && d.id[0]) {
        uint32_t h = 2166136261u;                  // FNV-1a over the UAS-ID
        for (const char* p = d.id; *p; ++p) { h ^= (uint8_t)*p; h *= 16777619u; }
        scratch[0] = (uint8_t)h;          scratch[1] = (uint8_t)(h >> 8);
        scratch[2] = (uint8_t)(h >> 16);  scratch[3] = (uint8_t)(h >> 24);
        scratch[4] = (uint8_t)d.id[0];    scratch[5] = 0xDD;   // tag byte, avoid MAC overlap
        return scratch;
    }
    return d.mac;
}

// Where both radios converge.
static void handleDetection(AcabDetection& d) {
    if (isIgnored(d.mac)) return;   // whitelisted by the app - drop silently
    uint32_t now = millis();
    bool isNew;

    uint8_t keyScratch[6];
    const uint8_t* key = dedupKey(d, keyScratch);

    portENTER_CRITICAL(&gDedupMux);
    DedupEntry* e = dedupFind(d.type, key);
    isNew = (e->count == 0) || (now - e->lastSeen > gCfg.dedupWindowMs);
    if (e->count == 0) e->firstSeen = now;
    e->lastSeen = now;
    if (e->count < 0xFFFF) e->count++;
    d.firstSeen = e->firstSeen;
    d.lastSeen  = e->lastSeen;
    d.count     = e->count;
    portEXIT_CRITICAL(&gDedupMux);

    // Stamp fixed devices with our own GPS fix (drones already carry theirs).
    if (d.type != ACAB_DRONE && gSelfGPSValid && d.lat == 0 && d.lon == 0) {
        d.lat = gSelfLat;
        d.lon = gSelfLon;
    }

    gTotal++;
    if (gSinkQ) {
        SinkItem it{d, isNew};
        xQueueSend(gSinkQ, &it, 0);   // non-blocking: drop on overflow rather than stall a radio
    }
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
class AcabAdvCallbacks : public NimBLEAdvertisedDeviceCallbacks {
public:
    void onResult(NimBLEAdvertisedDevice* dev) override {
        gBleSeen++;
        // NimBLE keeps the address little-endian and getNative() points at a
        // temporary, so copy it AND flip to human order (mac[0] = OUI byte), which
        // is what our OUI tables expect.
        NimBLEAddress addr = dev->getAddress();
        const uint8_t* nat = addr.getNative();
        if (!nat) return;
        uint8_t mac[6];
        for (int i = 0; i < 6; i++) mac[i] = nat[5 - i];

        int rssi = dev->getRSSI();
        uint8_t* payload = dev->getPayload();
        size_t   plen    = dev->getPayloadLength();

#ifdef ACAB_DIAG
        // Log EVERY advert, matched or not. On the bench next to a real camera,
        // this shows whether its advert arrives at all and what it carries
        // (name / mfg id / OUI), to compare against the signature tables.
        {
            char line[200];
            int p = snprintf(line, sizeof(line),
                             "[ble] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d adv=",
                             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], rssi);
            for (size_t k = 0; k < plen && p < (int)sizeof(line) - 3; k++)
                p += snprintf(line + p, sizeof(line) - p, "%02X", payload[k]);
            Serial.println(line);
        }
#endif

        AcabDetection d;
        // Try most-specific first: drone (standardised) -> Flock -> tracker -> Axon,
        // then the broad Motorola/police OUI last so it never preempts a real match.
        if (droneClassifyBLE(mac, payload, plen, rssi, &d)) { handleDetection(d); return; }
        if (flockClassifyBLE(mac, payload, plen, rssi, &d)) { handleDetection(d); return; }
        if (trackerClassifyBLE(mac, payload, plen, rssi, &d)) { handleDetection(d); return; }
        if (axonClassifyBLE(mac, payload, plen, rssi, &d))  { handleDetection(d); return; }
        if (policeClassifyBLE(mac, payload, plen, rssi, &d)) { handleDetection(d); return; }
    }
};

static void bleScanTask(void*) {
    for (;;) {
        if (gScan && gBleEnabled) {
            gScan->start(2, false);   // 2 s windows, then clear results and go again
            gScan->clearResults();
        } else {
            vTaskDelay(pdMS_TO_TICKS(200));
        }
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}

// ---------------------------------------------------------------------------
// WiFi
// ---------------------------------------------------------------------------
#ifdef ACAB_DIAG_WIFI
// Bench diagnostic: log every beacon / probe-response (BSSID + SSID + RSSI), so a
// field test next to a pole-mounted camera can spot its WiFi presence, if any.
// Parsing + serial run off the promiscuous callback via a queue and task.
struct WifiDiagItem { uint8_t bssid[6]; int8_t rssi; char ssid[33]; };
static QueueHandle_t gWifiDiagQ = nullptr;
static void wifiDiagTask(void*) {
    WifiDiagItem it;
    for (;;)
        if (xQueueReceive(gWifiDiagQ, &it, portMAX_DELAY) == pdTRUE)
            Serial.printf("[wifi] %02X:%02X:%02X:%02X:%02X:%02X rssi=%d ssid=\"%s\"\n",
                          it.bssid[0], it.bssid[1], it.bssid[2], it.bssid[3], it.bssid[4],
                          it.bssid[5], it.rssi, it.ssid);
}
#endif

static void IRAM_ATTR wifiRxCallback(void* buf, wifi_promiscuous_pkt_type_t type) {
    if (!gWifiEnabled) return;
    if (type != WIFI_PKT_MGMT) return;
    wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
    const uint8_t* payload = pkt->payload;
    int len  = pkt->rx_ctrl.sig_len;
    int rssi = pkt->rx_ctrl.rssi;
    if (len < 24) return;
    gWifiSeen++;

#ifdef ACAB_DIAG_WIFI
    // beacon (0x80) or probe-response (0x50): grab BSSID + SSID for the bench log
    if (gWifiDiagQ && (payload[0] == 0x80 || payload[0] == 0x50) && len >= 38) {
        WifiDiagItem it;
        memcpy(it.bssid, payload + 10, 6);   // addr2 = transmitter / BSSID
        it.rssi = (int8_t)rssi;
        it.ssid[0] = 0;
        uint8_t sl = payload[37];            // SSID IE: tag at [36]==0, len at [37]
        if (payload[36] == 0x00 && sl <= 32 && 38 + sl <= len) {
            memcpy(it.ssid, payload + 38, sl); it.ssid[sl] = 0;
        }
        xQueueSend(gWifiDiagQ, &it, 0);      // non-blocking: drop on overflow
    }
#endif

    AcabDetection d;
    if (droneClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (flockClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
    if (policeClassifyWiFi(payload, len, rssi, &d)) { handleDetection(d); return; }
}

// Channel 6 is the OpenDroneID Wi-Fi "social" channel - Remote-ID NAN/beacon
// frames live there, and sky-spy just parks on it for drones. A plain 1..13 sweep
// would sit on ch6 only ~8% of the time and miss a drone we drive past. So this
// sequence comes back to ch6 between every step (~50% dwell) while still touching
// all 13 (and favouring the 1/6/11 non-overlappers). That keeps Flock Wi-Fi
// covered too, since it can sit anywhere.
static const uint8_t WIFI_HOP_SEQ[] = {
    6, 1, 6, 11, 6, 2, 6, 3, 6, 4, 6, 5, 6, 7, 6, 8, 6, 9, 6, 10, 6, 12, 6, 13
};
static const int WIFI_HOP_SEQ_LEN = sizeof(WIFI_HOP_SEQ) / sizeof(WIFI_HOP_SEQ[0]);

static void wifiHopTask(void*) {
    int idx = 0;
    for (;;) {
        if (gCfg.wifiChannelHop) {
            esp_wifi_set_channel(WIFI_HOP_SEQ[idx], WIFI_SECOND_CHAN_NONE);
            idx++;
            if (idx >= WIFI_HOP_SEQ_LEN) idx = 0;
        }
        vTaskDelay(pdMS_TO_TICKS(gCfg.wifiHopIntervalMs));
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
AcabScannerConfig acabScannerDefaults() {
    AcabScannerConfig c;
    c.enableBLE        = true;
    c.enableWiFi       = true;
    c.initNimBLE       = true;
    c.bleDeviceName    = "ACAB";
    c.wifiChannelHop   = true;
    c.wifiFixedChannel = 6;
    c.wifiHopIntervalMs= 300;
    c.dedupWindowMs    = 60000;
    return c;
}

void acabScannerSetSelfGPS(double lat, double lon, bool valid) {
    gSelfLat = lat; gSelfLon = lon; gSelfGPSValid = valid;
}

void acabScannerSetIgnoreList(const uint8_t macs[][6], int count) {
    if (count < 0) count = 0;
    if (count > ACAB_IGNORE_MAX) count = ACAB_IGNORE_MAX;
    portENTER_CRITICAL(&gIgnoreMux);
    for (int i = 0; i < count; i++) memcpy(gIgnore[i], macs[i], 6);
    gIgnoreCount = count;
    portEXIT_CRITICAL(&gIgnoreMux);
    saveIgnoreList();   // persist outside the critical section - NVS writes are slow
}

uint32_t acabScannerTotalDetections() { return gTotal; }
uint32_t acabScannerBleSeen()  { return gBleSeen; }
uint32_t acabScannerWifiSeen() { return gWifiSeen; }

void acabScannerSetBLE(bool on) {
    gBleEnabled = on;
    if (gScan && !on) gScan->stop();    // cut the in-flight 2 s window short
}
void acabScannerSetWiFi(bool on) {
    gWifiEnabled = on;
    esp_wifi_set_promiscuous(on);        // stop feeding the RX callback at all
}
bool acabScannerBLEEnabled()  { return gBleEnabled; }
bool acabScannerWiFiEnabled() { return gWifiEnabled; }

// Bring up both radios per cfg, register the sink, and launch the scanner tasks.
void acabScannerBegin(const AcabScannerConfig& cfg, AcabDetectionSink sink) {
    gCfg  = cfg;
    gSink = sink;
    memset(gDedup, 0, sizeof(gDedup));
    gTotal = gBleSeen = gWifiSeen = 0;
    gBleEnabled = gWifiEnabled = true;
    loadIgnoreList();   // restore the persisted whitelist before any frame arrives

    // One sink task drains detections from both radios (see SinkItem above).
    gSinkQ = xQueueCreate(32, sizeof(SinkItem));
    xTaskCreatePinnedToCore(sinkTask, "acabSink", 8192, nullptr, 1, nullptr, 1);

    if (cfg.enableWiFi) {
        WiFi.mode(WIFI_STA);
        WiFi.disconnect();
        esp_wifi_set_promiscuous(true);
        esp_wifi_set_promiscuous_rx_cb(&wifiRxCallback);
        esp_wifi_set_channel(cfg.wifiChannelHop ? 6 : cfg.wifiFixedChannel,
                             WIFI_SECOND_CHAN_NONE);
        xTaskCreatePinnedToCore(wifiHopTask, "acabWifiHop", 4096, nullptr, 1, nullptr, 0);
#ifdef ACAB_DIAG_WIFI
        gWifiDiagQ = xQueueCreate(64, sizeof(WifiDiagItem));
        xTaskCreatePinnedToCore(wifiDiagTask, "acabWifiDiag", 4096, nullptr, 1, nullptr, 0);
#endif
    }

    if (cfg.enableBLE) {
        if (cfg.initNimBLE && !NimBLEDevice::getInitialized()) {
            NimBLEDevice::init(cfg.bleDeviceName ? cfg.bleDeviceName : "ACAB");
        }
        // hush the lib's warnings about zero-length adverts we ignore anyway
        esp_log_level_set("NimBLEAdvertisedDevice", ESP_LOG_NONE);

        gScan = NimBLEDevice::getScan();
        gScan->setAdvertisedDeviceCallbacks(new AcabAdvCallbacks(), /*wantDuplicates=*/true);
        gScan->setActiveScan(true);
        gScan->setInterval(131);  // ~82 ms, prime to dodge sync; ~51% duty (down from 97/69%)
        gScan->setWindow(67);     // so WiFi promiscuous isn't starved on the shared radio
        xTaskCreatePinnedToCore(bleScanTask, "acabBleScan", 12288, nullptr, 1, nullptr, 1);
    }
}
