// ---------------------------------------------------------------------------
// odid-sim: synthetic ASTM F3411 / OpenDroneID Remote ID BLE beacon (LEGACY)
// ---------------------------------------------------------------------------
// WHY this exists: it is a BENCH TEST TOOL. Flash it onto a spare XIAO ESP32-S3
// and it pretends to be a Remote-ID-broadcasting drone so we can exercise the
// project's own OpenDroneID receiver (lib/acab_core/drone_detect.cpp) end to end
// without a real aircraft. It reuses the project's vendored ODID encoder so the
// 25-byte message bodies are correct by construction, then wraps each in the
// exact legacy Service-Data AD framing droneRidBLE() scans for.
//
// Wire framing of every advert (single Service-Data AD structure, 31 bytes):
//   [1E][16][FA FF][0D][msgCounter][25-byte encoded ODID message]
//    len  type uuid  app  counter    message body
// AD type 0x16 = Service Data (16-bit UUID); UUID 0xFFFA little-endian (FA FF);
// 0x0D = ODID app code; adLen = 1+2+1+1+25 = 30 = 0x1E. We deliberately do NOT
// prepend a Flags AD (02 01 06): 3 + 31 = 34 blows the 31-byte legacy advert
// budget. Real drones omit it here and so do we (non-connectable adverts do not
// need AD flags anyway).
//
// Broadcast: round-robin one message type per advert every ~700 ms, forever, in
// the order BasicID, Location, System. Non-connectable + non-scannable legacy
// adverts (ADV_NONCONN_IND) so it reads as a pure broadcast beacon. A fixed
// random-static advertiser address keeps the receiver's pre-BasicID MAC keying
// stable for the whole session.
//
// BAKED-IN TEST VALUES (the downstream verifier looks for exactly these):
//   Advertiser MAC (random static): FA:F3:11:0D:1D:01
//   BasicID : IDType SERIAL_NUMBER(1), UAType HELI/MULTIROTOR(1),  <-- see note
//             UAS ID "SIM-OP-TEST-00000001" (20 ASCII chars)
//   Location: lat 32.91570, lon -117.17110, AltGeo 120.0 m, Height 45.0 m AGL,
//             Direction 90.0 deg, SpeedH 5.0 m/s, SpeedV 0.0, status AIRBORNE
//   System  : Operator lat 32.72000, lon -117.18500, OperatorAltGeo 55.0 m
//             (deliberately OFFSET from the drone Location so the downstream
//              test can tell operator-vs-drone apart)
//
// NOTE on UAType: the task text labelled UATYPE_HELICOPTER_OR_MULTIROTOR as "= 1",
// but in opendroneid.h that enumerator is value 2 (value 1 is AEROPLANE). We use
// the *named enum* ODID_UATYPE_HELICOPTER_OR_MULTIROTOR so the aircraft really is
// a multirotor; the raw byte therefore carries 2 in the UAType nibble.
//
// no em-dashes in this file by house style.
// ---------------------------------------------------------------------------

#include <Arduino.h>
#include <NimBLEDevice.h>
// ble_hs_id_set_rnd() lives in the NimBLE host API. Include it by the same
// in-library relative path NimBLEAddress.h uses, so it resolves without needing
// the ESP-IDF host/ dir on the include path.
#include "nimble/nimble/host/include/host/ble_hs.h"
#include <string>

extern "C" {
#include "opendroneid.h"
}

// --- baked-in identity / telemetry -----------------------------------------
static const char*  kUasId          = "SIM-OP-TEST-00000001";   // exactly 20 chars
static const double kDroneLat       =   32.91570;
static const double kDroneLon       = -117.17110;
static const float  kDroneAltGeo    =  120.0f;   // m WGS84-HAE
static const float  kDroneHeight    =   45.0f;   // m AGL
static const float  kDroneDir       =   90.0f;   // deg true north
static const float  kDroneSpeedH    =    5.0f;   // m/s
static const float  kDroneSpeedV    =    0.0f;   // m/s
static const double kOperatorLat    =   32.72000;
static const double kOperatorLon    = -117.18500;
static const float  kOperatorAltGeo =   55.0f;   // m WGS84-HAE

// Fixed random-static advertiser address. ble_hs_id_set_rnd() wants the 6 bytes
// little-endian (val[0] = LSB, val[5] = MSB). MSB 0xFA has its top two bits set
// (0xFA & 0xC0 == 0xC0), which is what makes it a valid *static* random address.
// Human-readable MAC: FA:F3:11:0D:1D:01
static const uint8_t kRndAddrLE[6] = {0x01, 0x1D, 0x0D, 0x11, 0xF3, 0xFA};

// ODID legacy BLE framing constants (all straight from the public spec).
static const uint8_t kAdLen   = 0x1E;   // 30 = type + uuid(2) + appcode + counter + 25
static const uint8_t kAdType  = 0x16;   // Service Data, 16-bit UUID
static const uint8_t kUuidLo  = 0xFA;   // 0xFFFA little-endian
static const uint8_t kUuidHi  = 0xFF;
static const uint8_t kAppCode = 0x0D;   // OpenDroneID

static const uint32_t kCycleMs = 700;   // ~700 ms between adverts, per the task

static NimBLEAdvertising* gAdv     = nullptr;
static uint8_t            gCounter = 0;  // 1-byte msg counter, ++ every advert

// Assemble the 31-byte legacy advert from a 25-byte encoded ODID message.
// out must hold 31 bytes. Returns the total length (31).
static size_t buildAdvert(const uint8_t* msg25, uint8_t* out) {
    size_t n = 0;
    out[n++] = kAdLen;
    out[n++] = kAdType;
    out[n++] = kUuidLo;
    out[n++] = kUuidHi;
    out[n++] = kAppCode;
    out[n++] = gCounter++;                 // increments each advert
    memcpy(out + n, msg25, ODID_MESSAGE_SIZE);
    n += ODID_MESSAGE_SIZE;
    return n;                               // 6 + 25 = 31
}

// Encode a BasicID message body (25 bytes) into msg25.
static bool encodeBasicID(uint8_t* msg25) {
    ODID_BasicID_data d;
    odid_initBasicIDData(&d);
    d.IDType = ODID_IDTYPE_SERIAL_NUMBER;               // serial number
    d.UAType = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR;    // multirotor
    // UASID is char[21]; encoder strncpy's 20 bytes into the on-wire field.
    strncpy(d.UASID, kUasId, sizeof(d.UASID));
    ODID_BasicID_encoded enc;
    if (encodeBasicIDMessage(&enc, &d) != ODID_SUCCESS) return false;
    memcpy(msg25, &enc, ODID_MESSAGE_SIZE);
    return true;
}

// Encode a Location/Vector message body (25 bytes) into msg25.
static bool encodeLocation(uint8_t* msg25) {
    ODID_Location_data d;
    odid_initLocationData(&d);                          // sets invalid sentinels first
    d.Status          = ODID_STATUS_AIRBORNE;
    d.Direction       = kDroneDir;                      // < 361 so receiver keeps it
    d.SpeedHorizontal = kDroneSpeedH;                   // < 255 so receiver keeps it
    d.SpeedVertical   = kDroneSpeedV;
    d.Latitude        = kDroneLat;
    d.Longitude       = kDroneLon;
    d.AltitudeGeo     = kDroneAltGeo;
    d.AltitudeBaro    = kDroneAltGeo;                   // sane, not the -1000 sentinel
    d.HeightType      = ODID_HEIGHT_REF_OVER_GROUND;
    d.Height          = kDroneHeight;                   // > -1000 so receiver keeps it
    // Sane accuracy + timestamp so nothing decodes as "no value".
    d.HorizAccuracy   = ODID_HOR_ACC_3_METER;
    d.VertAccuracy    = ODID_VER_ACC_3_METER;
    d.BaroAccuracy    = ODID_VER_ACC_UNKNOWN;
    d.SpeedAccuracy   = ODID_SPEED_ACC_1_METERS_PER_SECOND;
    d.TSAccuracy      = ODID_TIME_ACC_0_1_SECOND;
    d.TimeStamp       = fmodf(millis() / 1000.0f, 3600.0f);  // seconds past the hour, 0..3600
    ODID_Location_encoded enc;
    if (encodeLocationMessage(&enc, &d) != ODID_SUCCESS) return false;
    memcpy(msg25, &enc, ODID_MESSAGE_SIZE);
    return true;
}

// Encode a System message body (25 bytes) into msg25 (carries the OPERATOR pos).
static bool encodeSystem(uint8_t* msg25) {
    ODID_System_data d;
    odid_initSystemData(&d);                            // AreaCount=1, sentinels for the rest
    d.OperatorLocationType = ODID_OPERATOR_LOCATION_TYPE_TAKEOFF;
    d.ClassificationType   = ODID_CLASSIFICATION_TYPE_UNDECLARED;
    d.OperatorLatitude     = kOperatorLat;              // offset from drone Location on purpose
    d.OperatorLongitude    = kOperatorLon;
    d.OperatorAltitudeGeo  = kOperatorAltGeo;
    d.AreaCount            = 1;
    d.AreaRadius           = 0;
    ODID_System_encoded enc;
    if (encodeSystemMessage(&enc, &d) != ODID_SUCCESS) return false;
    memcpy(msg25, &enc, ODID_MESSAGE_SIZE);
    return true;
}

static void printHex(const char* label, const uint8_t* buf, size_t len) {
    Serial.printf("%s [%u]: ", label, (unsigned)len);
    for (size_t i = 0; i < len; i++) Serial.printf("%02X", buf[i]);
    Serial.println();
}

// Load the 31-byte raw payload and (re)start a non-connectable legacy advert.
static void broadcast(const uint8_t* advert, size_t len) {
    gAdv->stop();                                       // set data only while idle
    NimBLEAdvertisementData ad;
    ad.addData(std::string(reinterpret_cast<const char*>(advert), len));  // raw AD bytes
    gAdv->setScanResponse(false);                       // no scan resp => non-scannable
    gAdv->setAdvertisementType(BLE_GAP_CONN_MODE_NON);  // non-connectable => ADV_NONCONN_IND
    gAdv->setAdvertisementData(ad);                     // ble_gap_adv_set_data(raw 31 bytes)
    gAdv->start();
}

void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("odid-sim: fake OpenDroneID Remote ID drone beacon (bench test tool)");

    NimBLEDevice::init("odid-sim");                     // blocks until the host is synced

    // Pin a stable random-static advertiser address so the receiver's pre-BasicID
    // MAC keying does not move under it for the whole session.
    int rc = ble_hs_id_set_rnd(kRndAddrLE);
    if (rc != 0) Serial.printf("ble_hs_id_set_rnd failed rc=%d (falling back to default addr)\n", rc);
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
    Serial.printf("advertiser MAC (random static): %02X:%02X:%02X:%02X:%02X:%02X\n",
                  kRndAddrLE[5], kRndAddrLE[4], kRndAddrLE[3],
                  kRndAddrLE[2], kRndAddrLE[1], kRndAddrLE[0]);

    gAdv = NimBLEDevice::getAdvertising();

    // Print the three message payloads once at boot so the verifier has the exact
    // bytes to expect. Two fields drift at runtime: the counter byte at advert
    // offset 5, and (Location only) the 2-byte TimeStamp at advert offsets 27-28,
    // which tracks seconds past the hour. Everything else is fixed.
    uint8_t msg[ODID_MESSAGE_SIZE], advert[31];
    uint8_t saved = gCounter; gCounter = 0;             // show them with counter 0
    if (encodeBasicID(msg))  { buildAdvert(msg, advert); printHex("BasicID  advert", advert, 31); }
    gCounter = 0;
    if (encodeLocation(msg)) { buildAdvert(msg, advert); printHex("Location advert", advert, 31); }
    gCounter = 0;
    if (encodeSystem(msg))   { buildAdvert(msg, advert); printHex("System   advert", advert, 31); }
    gCounter = saved;

    Serial.println("broadcasting BasicID -> Location -> System, ~700 ms apart, forever");
}

void loop() {
    static uint8_t phase = 0;                           // 0 BasicID, 1 Location, 2 System
    uint8_t msg[ODID_MESSAGE_SIZE], advert[31];
    bool ok = false;
    const char* label = "";

    switch (phase) {
        case 0: ok = encodeBasicID(msg);  label = "BasicID";  break;
        case 1: ok = encodeLocation(msg); label = "Location"; break;
        default: ok = encodeSystem(msg);  label = "System";   break;
    }

    if (ok) {
        size_t len = buildAdvert(msg, advert);
        broadcast(advert, len);
        printHex(label, advert, len);
    } else {
        Serial.printf("%s encode FAILED\n", label);     // should never happen with baked values
    }

    phase = (phase + 1) % 3;
    delay(kCycleMs);
}
