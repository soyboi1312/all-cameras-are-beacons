/*
 * ACAB OUI-Spy - BLE GATT service implementation (NimBLE-Arduino 1.4 API).
 */
#include "acab_ble_service.h"
#include "axon_detect.h"
#include "police_detect.h"
#include "desert_detect.h"
#include "tracker_detect.h"
#include "acab_scanner.h"
#include "det_log.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <ArduinoJson.h>

// The buzzer (alerts) is OUI-Spy hardware; the Mesh-Detect board has none. These
// weak no-ops let this shared service link on a buzzer-less build - oui-spy's
// alerts.cpp provides the strong overrides; mesh-detect falls through to these.
__attribute__((weak)) void    alertsSetBuzzerEnabled(bool) {}
__attribute__((weak)) bool    alertsBuzzerEnabled()         { return false; }
__attribute__((weak)) void    alertsSetVolume(uint8_t)      {}
__attribute__((weak)) uint8_t alertsVolume()                { return 0; }
__attribute__((weak)) void    alertsBeepTest()              {}

// Latest phone GPS the app pushed over the config characteristic (0 = none yet).
static volatile double   gPhoneLat = 0, gPhoneLon = 0;
static volatile uint32_t gPhoneGpsMs = 0;
// gPhoneLat/Lon are 64-bit: reads/writes aren't atomic on the 32-bit Xtensa core and they
// cross tasks (BLE host writes them, the scanner task reads them), so a snapshot can tear
// (new high word + old low word). Guard the pair with a short spinlock.
static portMUX_TYPE      gGpsMux = portMUX_INITIALIZER_UNLOCKED;

// Build label for the status "fw" string (oui-spy vs mesh-detect). Set in acabBleBegin.
static const char* gFwLabel = "ACAB-ouispy";

static NimBLEServer*         gServer = nullptr;
static NimBLECharacteristic* gDetChar = nullptr;
static NimBLECharacteristic* gCfgChar = nullptr;
static NimBLECharacteristic* gStatChar = nullptr;
static volatile bool         gConnected = false;
static uint32_t              gHistSent  = 0;     // records sent so far in the current replay drain

// Max ATT payload one notify can carry at our negotiated MTU (setMTU(247) -> 247-3). We
// serialize into a larger scratch buffer so a fully-populated drone record never gets
// silently truncated into invalid JSON; if it still exceeds this, we skip that one frame
// (the app sees a seq gap and can re-sync) rather than push something unparseable.
static const size_t          NOTIFY_MAX = 244;

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

// Decode n*2 hex chars into n bytes (for the offline-buffer at-rest key). False on bad input.
static int hexNib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static bool hexToBytes(const char* hex, uint8_t* out, size_t n) {
    if (!hex || strlen(hex) != n * 2) return false;
    for (size_t i = 0; i < n; i++) {
        int hi = hexNib(hex[i * 2]), lo = hexNib(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
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
            policeSetEnabled(on);                 // Motorola/LE-gear rides the body-cam toggle (merged into the body-cam category)
            Serial.printf("[ACAB] Body-cam detector %s\n", on ? "ENABLED" : "disabled");
        }
        if (doc["tracker"].is<bool>()) {
            bool on = doc["tracker"].as<bool>();
            trackerSetEnabled(on);
            Serial.printf("[ACAB] Tracker detector %s\n", on ? "on" : "off");
        }
        if (doc["desert"].is<bool>()) {       // Desert mode: report EVERY device in range
            bool on = doc["desert"].as<bool>();
            desertSetEnabled(on);
            Serial.printf("[ACAB] Desert mode %s\n", on ? "ENABLED" : "disabled");
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
        // Phone GPS from the app: where we are, stamped onto detections + the mesh line.
        if (doc["lat"].is<float>() && doc["lon"].is<float>()) {
            double la = doc["lat"].as<double>(), lo = doc["lon"].as<double>();
            uint32_t now = millis();
            portENTER_CRITICAL(&gGpsMux);
            gPhoneLat = la; gPhoneLon = lo; gPhoneGpsMs = now;
            portEXIT_CRITICAL(&gGpsMux);
        }
        // --- offline detection buffer (det_log) ---
        if (doc["buffer"].is<bool>()) {
            bool on = doc["buffer"].as<bool>();
            detLogSetEnabled(on);
            Serial.printf("[ACAB] Offline buffer %s\n", on ? "ENABLED" : "disabled");
        }
        if (doc["key"].is<const char*>()) {            // 64 hex chars -> 32-byte at-rest key
            uint8_t k[32];
            if (hexToBytes(doc["key"].as<const char*>(), k, 32)) detLogSetKey(k);
        }
        if (doc["epoch"].is<uint32_t>()) detLogSetEpoch(doc["epoch"].as<uint32_t>());
        if (doc["clearlog"].is<bool>() && doc["clearlog"].as<bool>()) {
            detLogClear();
            Serial.println("[ACAB] Offline buffer erased");
        }
        if (doc["sync"].is<uint32_t>()) { gHistSent = 0; detLogStartDrain(doc["sync"].as<uint32_t>()); }
        acabBleUpdateStatus();
    }
};

void acabBleBegin(const char* deviceName, const char* fwLabel) {
    gFwLabel = fwLabel ? fwLabel : "ACAB-ouispy";
    NimBLEDevice::init(deviceName ? deviceName : "ACAB");
    NimBLEDevice::setMTU(247);   // fit a detection JSON in one notify
    // Encrypted, bonded link for the whole service, so a stranger can't silence the
    // scanner (config write) or watch what you're detecting (detection/status stream).
    // Pairing is "Just Works" (no passkey) because the board has no display/keypad, so
    // there is NO MITM protection AT THE ONE-TIME BOND: an active attacker present during
    // that first pairing could interpose. Passive sniffers and later unbonded strangers
    // are fully shut out regardless. THREAT-MODEL NOTE: first-pair the board in a trusted
    // RF environment (not in public) - a no-I/O device can't do better without OOB pairing.
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

// Build a detection record into `buf` (returns length). For replay set hist=true and
// pass seq + atUnix (atUnix==0 -> "approx":true). NOTE: mirrors the field set in
// acabBleNotifyDetection below - keep the two in sync (or consolidate later).
static size_t serializeDetection(const AcabDetection& d, bool isNew, char* buf, size_t bufsz,
                                 bool hist, uint32_t seq, uint32_t atUnix) {
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
    if (hist) {
        doc["hist"] = true;
        doc["seq"]  = seq;
        if (atUnix) doc["at"] = atUnix; else doc["approx"] = true;
    }
    return serializeJson(doc, buf, bufsz);
}

// Drive the offline-buffer replay: one record per call, paced by loop(). On {sync}
// the app starts a drain; we stream each stored record tagged hist/seq/at, then a
// {"hist":"end","n":N} sentinel so the app can spot drops and re-sync from its lastSeq.
void acabBleDrainTick() {
    if (!gDetChar || !gConnected || !detLogDraining()) return;
    char buf[320];
    DetLogReplay r;
    if (detLogNextForDrain(&r)) {
        size_t len = serializeDetection(r.d, false, buf, sizeof(buf), true, r.seq, r.atUnix);
        if (len > 0 && len <= NOTIFY_MAX) {          // skip an over-MTU record; never send truncated JSON
            gDetChar->setValue((uint8_t*)buf, len);
            gDetChar->notify();
            gHistSent++;
        }
    } else {
        JsonDocument doc;
        doc["hist"] = "end";
        doc["n"]    = gHistSent;
        size_t len = serializeJson(doc, buf, sizeof(buf));
        gDetChar->setValue((uint8_t*)buf, len);
        gDetChar->notify();
    }
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

    char buf[320];
    size_t len = serializeJson(doc, buf, sizeof(buf));
    if (len == 0 || len > NOTIFY_MAX) return;        // don't emit a truncated, unparseable frame
    gDetChar->setValue((uint8_t*)buf, len);
    gDetChar->notify();
}

// Rebuild the status JSON and update the characteristic (notify if connected).
void acabBleUpdateStatus() {
    if (!gStatChar) return;
    JsonDocument doc;
    static char fwbuf[40];
    snprintf(fwbuf, sizeof(fwbuf), "%s %s", gFwLabel, ACAB_FW_VERSION);
    doc["fw"]     = fwbuf;
    doc["up"]     = (uint32_t)(millis() / 1000);
    doc["total"]  = acabScannerTotalDetections();
    doc["ble"]    = acabScannerBLEEnabled();
    doc["wifi"]   = acabScannerWiFiEnabled();
    doc["axon"]   = axonIsEnabled();
    doc["bodycam"]= axonIsEnabled();
    doc["tracker"]= trackerIsEnabled();
    doc["buzzer"] = alertsBuzzerEnabled();
    doc["vol"]    = alertsVolume();
    doc["gps"]    = (gPhoneGpsMs != 0) && (millis() - gPhoneGpsMs < 60000);
    doc["buf"]    = detLogCount();          // stored offline records
    doc["bufon"]  = detLogEnabled();        // buffering opt-in state
    doc["desert"] = desertIsEnabled();      // Desert mode (report every device in range)

    char buf[200];
    size_t len = serializeJson(doc, buf, sizeof(buf));
    gStatChar->setValue((uint8_t*)buf, len);
    if (gConnected) gStatChar->notify();
}

bool acabBleClientConnected() { return gConnected; }

// Latest phone GPS the app pushed, if it arrived within maxAgeMs. Returns false
// (leaving lat/lon untouched) when there's no fresh fix.
bool acabBleGetPhoneGps(double* lat, double* lon, uint32_t maxAgeMs) {
    portENTER_CRITICAL(&gGpsMux);
    uint32_t ms = gPhoneGpsMs; double la = gPhoneLat, lo = gPhoneLon;
    portEXIT_CRITICAL(&gGpsMux);
    if (ms == 0 || (millis() - ms) > maxAgeMs) return false;
    if (lat) *lat = la;
    if (lon) *lon = lo;
    return true;
}
