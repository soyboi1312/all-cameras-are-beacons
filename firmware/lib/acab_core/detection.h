/*
 * ACAB - All Cameras Are Beacons
 * Shared detection model (firmware-agnostic core).
 *
 * Every detector produces one of these, and every output path consumes it:
 *   - OUI-Spy build  -> streamed over the ACAB BLE GATT service to the iOS app
 *   - Mesh-Detect build -> formatted as a labelled line for the Meshtastic node
 *
 * Keep it POD and self-contained - it gets memcpy'd across FreeRTOS queues and
 * packed onto the wire. No std::string, no heap.
 */
#ifndef ACAB_DETECTION_H
#define ACAB_DETECTION_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>

// ---------------------------------------------------------------------------
// The device classes ACAB looks for (+ an unknown sentinel).
// ---------------------------------------------------------------------------
enum AcabDeviceType : uint8_t {
    ACAB_UNKNOWN       = 0,
    ACAB_FLOCK_CAMERA  = 1,   // Flock Safety ALPR camera (BLE or WiFi signature)
    ACAB_FLOCK_RAVEN   = 2,   // Flock "Raven" audio / gunshot detector
    ACAB_AXON_BODYCAM  = 3,   // body-worn camera (Axon 00:25:DF signature, field-validated)
    ACAB_DRONE         = 4,   // FAA Remote ID broadcasting UAS
    ACAB_TRACKER       = 5,   // BLE item tracker (AirTag/Find My, Tile, Samsung SmartTag)
    ACAB_POLICE_GEAR   = 6,   // Motorola Solutions WiFi/BLE device (LE-equipment proxy; OUI match)
    ACAB_TYPE_COUNT    = 7
};

// How we saw it on the radio.
enum AcabSource : uint8_t {
    SRC_BLE      = 0,   // BLE advertisement
    SRC_WIFI     = 1,   // 802.11 management frame (promiscuous)
    SRC_REMOTEID = 2    // OpenDroneID payload (over BLE or WiFi)
};

// Why it matched - handy to surface in the app/mesh.
enum AcabMethod : uint8_t {
    M_NONE        = 0,
    M_OUI         = 1,   // MAC OUI / prefix table hit
    M_NAME        = 2,   // advertised-name substring
    M_MFG_ID      = 3,   // BLE manufacturer company ID
    M_SERVICE_UUID= 4,   // service UUID (Raven services)
    M_SSID        = 5,   // WiFi SSID pattern
    M_PROBE       = 6,   // empty-SSID probe from a known OUI
    M_REMOTE_ID   = 7    // decoded OpenDroneID message
};

// ---------------------------------------------------------------------------
// The detection event. ~160 bytes, fine to pass by value through queues.
// ---------------------------------------------------------------------------
struct AcabDetection {
    AcabDeviceType type;
    AcabSource     src;
    AcabMethod     method;
    uint8_t        confidence;     // 0..100

    uint8_t        mac[6];         // transmitter address
    int16_t        rssi;

    char           id[40];         // RID UAS serial / operator id
    char           name[40];       // advertised device name (if any)
    char           detail[48];     // free-form: raven fw, ssid, drone op-id, etc.

    // Location. For drones, the broadcast UAS coordinates; for fixed devices,
    // our own GPS fix (0 if we don't have one).
    double         lat, lon;
    double         pilotLat, pilotLon;   // drone operator location (0 if n/a)
    int32_t        altitude;             // metres MSL (drones)

    // Drone Remote ID flight telemetry (0 / unset for everything else).
    float          speedH;               // horizontal speed (m/s)
    float          speedV;               // vertical speed (m/s)
    float          heading;              // track direction (deg, 0..360)
    float          heightAGL;            // height above takeoff (m)
    int32_t        pilotAlt;             // operator altitude (m MSL)
    uint8_t        ridStatus;            // ODID op status: 1 ground, 2 airborne, 3 emergency, 4 fault

    uint32_t       firstSeen;      // millis() we first saw it
    uint32_t       lastSeen;       // millis() we last saw it
    uint16_t       count;          // sightings this session
};

// ---------------------------------------------------------------------------
// Human-readable labels for serial + mesh output.
// ---------------------------------------------------------------------------
static inline const char* acabTypeLabel(AcabDeviceType t) {
    switch (t) {
        case ACAB_FLOCK_CAMERA: return "ALPR camera";
        case ACAB_FLOCK_RAVEN:  return "Flock Raven";
        case ACAB_AXON_BODYCAM: return "Body camera";
        case ACAB_DRONE:        return "Drone";
        case ACAB_TRACKER:      return "Tracker";
        case ACAB_POLICE_GEAR:  return "Police gear";
        default:                return "Unknown";
    }
}

// Short tag for compact UIs / log prefixes.
static inline const char* acabTypeTag(AcabDeviceType t) {
    switch (t) {
        case ACAB_FLOCK_CAMERA: return "FLOCK";
        case ACAB_FLOCK_RAVEN:  return "RAVEN";
        case ACAB_AXON_BODYCAM: return "BODYCAM";
        case ACAB_DRONE:        return "DRONE";
        case ACAB_TRACKER:      return "TRACKER";
        case ACAB_POLICE_GEAR:  return "POLICE";
        default:                return "UNK";
    }
}

static inline const char* acabSourceLabel(AcabSource s) {
    switch (s) {
        case SRC_BLE:      return "BLE";
        case SRC_WIFI:     return "WiFi";
        case SRC_REMOTEID: return "RID";
        default:           return "?";
    }
}

static inline const char* acabMethodLabel(AcabMethod m) {
    switch (m) {
        case M_OUI:          return "oui";
        case M_NAME:         return "name";
        case M_MFG_ID:       return "mfg-id";
        case M_SERVICE_UUID: return "svc-uuid";
        case M_SSID:         return "ssid";
        case M_PROBE:        return "probe";
        case M_REMOTE_ID:    return "remote-id";
        default:             return "none";
    }
}

// Zero out a detection and stamp the basics.
static inline void acabInit(AcabDetection* d, AcabDeviceType type, AcabSource src,
                            const uint8_t mac[6], int16_t rssi) {
    memset(d, 0, sizeof(*d));
    d->type = type;
    d->src  = src;
    d->rssi = rssi;
    if (mac) memcpy(d->mac, mac, 6);
}

// Format a MAC into "aa:bb:cc:dd:ee:ff". buf needs >= 18 bytes.
static inline void acabFormatMac(const uint8_t mac[6], char* buf) {
    snprintf(buf, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

// ---------------------------------------------------------------------------
// Detection sink: the firmware registers one of these with the scanner, and it
// fires whenever a target is (re)seen. `isNew` is true only on the first
// sighting within the dedup window.
// ---------------------------------------------------------------------------
typedef void (*AcabDetectionSink)(const AcabDetection& det, bool isNew);

#endif // ACAB_DETECTION_H
