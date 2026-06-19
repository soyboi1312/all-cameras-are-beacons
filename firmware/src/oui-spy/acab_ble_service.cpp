/*
 * ACAB OUI-Spy - BLE GATT service implementation (NimBLE-Arduino 1.4 API).
 */
#include "acab_ble_service.h"
#include "axon_detect.h"
#include "tracker_detect.h"
#include "acab_scanner.h"
#include "alerts.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <ArduinoJson.h>

static NimBLEServer*         gServer = nullptr;
static NimBLECharacteristic* gDetChar = nullptr;
static NimBLECharacteristic* gCfgChar = nullptr;
static NimBLECharacteristic* gStatChar = nullptr;
static volatile bool         gConnected = false;

// ---- server connection lifecycle ----
class ServerCb : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer*) override { gConnected = true; }
    void onDisconnect(NimBLEServer*) override {
        gConnected = false;
        NimBLEDevice::getAdvertising()->start();   // become discoverable again
    }
};

// Parse "aa:bb:cc:dd:ee:ff" into 6 bytes. Returns false if malformed.
static bool parseMac6(const char* s, uint8_t out[6]) {
    unsigned b[6];
    if (!s || sscanf(s, "%x:%x:%x:%x:%x:%x",
                     &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) return false;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)b[i];
    return true;
}

// ---- config writes from the app ----
class CfgCb : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        if (v.empty()) return;
        JsonDocument doc;
        if (deserializeJson(doc, v) != DeserializationError::Ok) return;

        // Body-cam detector (Axon 00:25:DF). Accept both the new "bodycam" key and
        // the legacy "axon" key, so older app builds keep working.
        if (doc["bodycam"].is<bool>() || doc["axon"].is<bool>()) {
            bool on = doc["bodycam"].is<bool>() ? doc["bodycam"].as<bool>()
                                                : doc["axon"].as<bool>();
            if (on) axonUseRegistryCandidate();   // load 00:25:DF so it actually fires
            axonSetEnabled(on);
            Serial.printf("[ACAB] Body-cam detector %s\n", on ? "ENABLED" : "disabled");
        }
        if (doc["tracker"].is<bool>()) {
            bool on = doc["tracker"].as<bool>();
            trackerSetEnabled(on);
            Serial.printf("[ACAB] Tracker detector %s\n", on ? "on" : "off");
        }
        if (doc["buzzer"].is<bool>()) {
            bool on = doc["buzzer"].as<bool>();
            alertsSetBuzzerEnabled(on);
            Serial.printf("[ACAB] Buzzer %s\n", on ? "on" : "off");
        }
        if (doc["volume"].is<int>()) {
            int v = doc["volume"].as<int>();
            if (v < 0) v = 0;
            if (v > 100) v = 100;
            alertsSetVolume((uint8_t)v);
            Serial.printf("[ACAB] Volume %d\n", v);
        }
        if (doc["ble"].is<bool>()) {
            bool on = doc["ble"].as<bool>();
            acabScannerSetBLE(on);
            Serial.printf("[ACAB] BLE scan %s\n", on ? "on" : "off");
        }
        if (doc["wifi"].is<bool>()) {
            bool on = doc["wifi"].as<bool>();
            acabScannerSetWiFi(on);
            Serial.printf("[ACAB] WiFi scan %s\n", on ? "on" : "off");
        }
        if (doc["beep"].is<bool>() && doc["beep"].as<bool>()) {
            alertsBeepTest();             // volume preview at the level just set above
        }
        if (doc["ignore"].is<JsonArray>()) {
            uint8_t macs[32][6];
            int n = 0;
            for (JsonVariant v : doc["ignore"].as<JsonArray>()) {
                if (n >= 32) break;
                if (parseMac6(v.as<const char*>(), macs[n])) n++;
            }
            acabScannerSetIgnoreList(macs, n);
            Serial.printf("[ACAB] ignore list: %d device(s)\n", n);
        }
        acabBleUpdateStatus();
    }
};

void acabBleBegin(const char* deviceName) {
    NimBLEDevice::init(deviceName ? deviceName : "ACAB");
    NimBLEDevice::setMTU(247);   // fit a detection JSON in one notify
    // Encrypted, bonded link for the whole service - so a stranger can't silence
    // the scanner (config write) or watch what you're detecting (detection/status
    // stream). "Just works" pairing, no passkey, since the board has no I/O.
    NimBLEDevice::setSecurityAuth(true, false, true);            // bonding, no MITM, LE Secure Connections
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
#ifdef ESP_PWR_LVL_P9
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
#endif

    gServer = NimBLEDevice::createServer();
    gServer->setCallbacks(new ServerCb());

    NimBLEService* svc = gServer->createService(ACAB_BLE_SVC_UUID);
    gDetChar  = svc->createCharacteristic(ACAB_BLE_DET_UUID,
                    NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
    gCfgChar  = svc->createCharacteristic(ACAB_BLE_CFG_UUID,
                    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC);
    gStatChar = svc->createCharacteristic(ACAB_BLE_STAT_UUID,
                    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
    gCfgChar->setCallbacks(new CfgCb());
    svc->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(ACAB_BLE_SVC_UUID);
    adv->setScanResponse(true);

    // Stick the firmware version in the scan response (name + manufacturer data),
    // so the app can show it in the device list before connecting.
    NimBLEAdvertisementData scanResp;
    scanResp.setName(deviceName ? deviceName : "ACAB");
    std::string verData;
    verData.push_back((char)0xAB);          // company id 0xACAB (LE) - our own marker
    verData.push_back((char)0xAC);
    verData += ACAB_FW_VERSION;             // e.g. "0.2.3"
    scanResp.setManufacturerData(verData);
    adv->setScanResponseData(scanResp);

    adv->start();

    acabBleUpdateStatus();
    Serial.printf("[ACAB] BLE service up, advertising as '%s'\n", deviceName);
}

// Pack one detection into compact JSON and NOTIFY the connected app.
void acabBleNotifyDetection(const AcabDetection& d, bool isNew) {
    if (!gDetChar || !gConnected) return;

    char macStr[18];
    acabFormatMac(d.mac, macStr);

    JsonDocument doc;
    doc["t"]    = (int)d.type;
    doc["s"]    = (int)d.src;
    doc["meth"] = (int)d.method;
    doc["c"]    = d.confidence;
    doc["mac"]  = macStr;
    doc["rssi"] = d.rssi;
    if (d.name[0])   doc["name"] = d.name;
    if (d.id[0])     doc["id"]   = d.id;
    if (d.detail[0]) doc["det"]  = d.detail;
    if (d.lat || d.lon)           { doc["lat"]  = d.lat;  doc["lon"]  = d.lon; }
    if (d.pilotLat || d.pilotLon) { doc["plat"] = d.pilotLat; doc["plon"] = d.pilotLon; }
    if (d.altitude)  doc["alt"]  = d.altitude;
    if (d.speedH)    doc["spd"]  = (int)d.speedH;
    if (d.speedV)    doc["vspd"] = (int)d.speedV;
    if (d.heading)   doc["hdg"]  = (int)d.heading;
    if (d.heightAGL) doc["hgt"]  = (int)d.heightAGL;
    if (d.pilotAlt)  doc["palt"] = d.pilotAlt;
    if (d.ridStatus) doc["sta"]  = d.ridStatus;
    doc["n"]   = d.count;
    doc["new"] = isNew;

    char buf[244];
    size_t len = serializeJson(doc, buf, sizeof(buf));
    gDetChar->setValue((uint8_t*)buf, len);
    gDetChar->notify();
}

// Rebuild the status JSON and update the characteristic (notify if connected).
void acabBleUpdateStatus() {
    if (!gStatChar) return;
    JsonDocument doc;
    doc["fw"]     = "ACAB-ouispy " ACAB_FW_VERSION;
    doc["up"]     = (uint32_t)(millis() / 1000);
    doc["total"]  = acabScannerTotalDetections();
    doc["ble"]    = acabScannerBLEEnabled();
    doc["wifi"]   = acabScannerWiFiEnabled();
    doc["axon"]   = axonIsEnabled();
    doc["bodycam"]= axonIsEnabled();
    doc["tracker"]= trackerIsEnabled();
    doc["buzzer"] = alertsBuzzerEnabled();
    doc["vol"]    = alertsVolume();
    doc["gps"]    = false;

    char buf[200];
    size_t len = serializeJson(doc, buf, sizeof(buf));
    gStatChar->setValue((uint8_t*)buf, len);
    if (gConnected) gStatChar->notify();
}

bool acabBleClientConnected() { return gConnected; }
