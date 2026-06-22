/*
 * ACAB - Drone (Remote ID) detector implementation.
 *
 * Two clean pieces: the ODID message decode is the vendored opendroneid-core-c
 * (Apache-2.0, attributed in CREDITS), and the classifiers below are our own
 * implementation of the PUBLIC ASTM F3411 / OpenDroneID broadcast formats. Every
 * signature value here - the BLE Service-Data UUID 0xFFFA and app code 0x0D, the
 * WiFi NAN multicast destination, the beacon vendor OUIs - is published in the
 * standard, not taken from anyone's firmware. See docs/signatures.md.
 */
#include "drone_detect.h"
#include "drone_signatures.h"
#include <Arduino.h>
#include <string.h>
#include <stdio.h>

extern "C" {
#include "opendroneid/opendroneid.h"
#include "opendroneid/odid_wifi.h"
}

// ---------------------------------------------------------------------------
// Gathering a drone's messages into one identity.
//
// A drone splits its Remote ID across separate messages (BasicID, Location,
// System, OperatorID, ...). In BT4 legacy advertising each advert carries just
// ONE of them, so a single frame only decodes to a partial record (e.g. BasicID
// but no position). We keep the fields per drone in a small track table, so each
// detection we emit holds everything seen so far.
//
// Once a BasicID arrives we key the track by UAS-ID (survives MAC rotation, spans
// BLE + WiFi); before that, by MAC. Both radio tasks decode, so a spinlock guards
// the table - same as the scanner's dedup table.
// ---------------------------------------------------------------------------
#define DRONE_TRACK_MAX  16
#define DRONE_TRACK_TTL  60000UL          // forget a track after 60 s of silence

struct DroneTrack {
    bool     used;
    uint8_t  mac[6];                       // most recent transmitter MAC
    char     uasId[ODID_ID_SIZE + 1];      // stable identity once a BasicID arrives
    uint32_t lastSeen;
    bool     haveLoc, haveOp, haveOpId;
    double   lat, lon;  int32_t alt;
    double   pilotLat, pilotLon;
    char     detail[48];
    float    speedH, speedV, heading, heightAGL;   // flight telemetry
    int32_t  pilotAlt;                             // operator altitude (m MSL)
    uint8_t  ridStatus;                            // ODID op status
};

static DroneTrack    gTracks[DRONE_TRACK_MAX];
static portMUX_TYPE  gTrackMux = portMUX_INITIALIZER_UNLOCKED;

// Find this frame's track, creating/evicting as needed. Caller holds gTrackMux.
static DroneTrack* trackFind(const uint8_t mac[6], const char* uasId, uint32_t now) {
    if (uasId && uasId[0]) {
        // match by UAS-ID
        for (int i = 0; i < DRONE_TRACK_MAX; i++)
            if (gTracks[i].used && gTracks[i].uasId[0] &&
                strcmp(gTracks[i].uasId, uasId) == 0) return &gTracks[i];
        // first BasicID for a drone we'd been tracking by MAC: adopt that track
        for (int i = 0; i < DRONE_TRACK_MAX; i++)
            if (gTracks[i].used && !gTracks[i].uasId[0] &&
                memcmp(gTracks[i].mac, mac, 6) == 0) return &gTracks[i];
    } else {
        // no BasicID yet, so correlate by MAC
        for (int i = 0; i < DRONE_TRACK_MAX; i++)
            if (gTracks[i].used && memcmp(gTracks[i].mac, mac, 6) == 0) return &gTracks[i];
    }
    // need a slot: take a free or stale one, otherwise evict the oldest
    DroneTrack* oldest = nullptr;
    for (int i = 0; i < DRONE_TRACK_MAX; i++) {
        DroneTrack* e = &gTracks[i];
        if (!e->used || now - e->lastSeen > DRONE_TRACK_TTL) {
            memset(e, 0, sizeof(*e)); e->used = true; return e;
        }
        if (!oldest || e->lastSeen < oldest->lastSeen) oldest = e;
    }
    memset(oldest, 0, sizeof(*oldest));
    oldest->used = true;
    return oldest;
}

// Merge one decoded frame into its track, then fill `out` from the accumulated
// track. Returns false if the frame carried nothing useful.
static bool fillFromODID(const ODID_UAS_Data* uas, const uint8_t mac[6],
                         int rssi, AcabSource src, AcabDetection* out) {
    bool useful = uas->BasicIDValid[0] || uas->LocationValid ||
                  uas->SystemValid     || uas->OperatorIDValid;
    if (!useful) return false;

    // Pull this frame's fields out before locking - keep string work off the lock.
    char frameId[ODID_ID_SIZE + 1] = {0};
    if (uas->BasicIDValid[0])
        strncpy(frameId, (const char*)uas->BasicID[0].UASID, ODID_ID_SIZE);

    char opDetail[48] = {0};
    if (uas->OperatorIDValid) {
        char op[ODID_ID_SIZE + 1] = {0};
        strncpy(op, (const char*)uas->OperatorID.OperatorId, ODID_ID_SIZE);
        snprintf(opDetail, sizeof(opDetail), "op %s", op);
    }

    acabInit(out, ACAB_DRONE, src, mac, (int16_t)rssi);
    out->method     = M_REMOTE_ID;
    out->confidence = 99;            // RID is a standardised, self-declared broadcast

    uint32_t now = millis();
    portENTER_CRITICAL(&gTrackMux);
    DroneTrack* t = trackFind(mac, frameId, now);
    memcpy(t->mac, mac, 6);          // track follows the latest MAC
    t->lastSeen = now;
    if (frameId[0]) { strncpy(t->uasId, frameId, ODID_ID_SIZE); t->uasId[ODID_ID_SIZE] = 0; }
    if (uas->LocationValid) {
        t->lat = uas->Location.Latitude;  t->lon = uas->Location.Longitude;
        t->alt = (int32_t)uas->Location.AltitudeGeo;  t->haveLoc = true;
        // flight telemetry - skip ODID's "invalid / no value" sentinels
        if (uas->Location.SpeedHorizontal < 255.0f)  t->speedH    = uas->Location.SpeedHorizontal;
        if (uas->Location.SpeedVertical   < 63.0f)   t->speedV    = uas->Location.SpeedVertical;
        if (uas->Location.Direction       < 361.0f)  t->heading   = uas->Location.Direction;
        if (uas->Location.Height          > -1000.0f) t->heightAGL = uas->Location.Height;
        t->ridStatus = (uint8_t)uas->Location.Status;
    }
    if (uas->SystemValid) {
        t->pilotLat = uas->System.OperatorLatitude;
        t->pilotLon = uas->System.OperatorLongitude;  t->haveOp = true;
        if (uas->System.OperatorAltitudeGeo > -1000.0f) t->pilotAlt = (int32_t)uas->System.OperatorAltitudeGeo;
    }
    if (opDetail[0]) { strncpy(t->detail, opDetail, sizeof(t->detail) - 1);  t->haveOpId = true; }

    // snapshot the accumulated track into out (still holding the lock)
    if (t->uasId[0])  strncpy(out->id, t->uasId, sizeof(out->id) - 1);
    if (t->haveLoc) { out->lat = t->lat;  out->lon = t->lon;  out->altitude = t->alt;
                      out->speedH = t->speedH;  out->speedV = t->speedV;
                      out->heading = t->heading;  out->heightAGL = t->heightAGL;
                      out->ridStatus = t->ridStatus; }
    if (t->haveOp)  { out->pilotLat = t->pilotLat;  out->pilotLon = t->pilotLon;  out->pilotAlt = t->pilotAlt; }
    if (t->haveOpId)  strncpy(out->detail, t->detail, sizeof(out->detail) - 1);
    portEXIT_CRITICAL(&gTrackMux);

    return true;
}

// Vendor-OUI fallback (lower confidence, layered UNDER Remote ID): a device not
// broadcasting Remote ID can still show its hand via its MAC OUI (one of the drone
// vendor's own IEEE blocks) - a weak "vendor gear nearby" signal (controller / goggles
// / the aircraft), so it only fires when the RID decode found nothing. drone_signatures.h.
static bool droneVendorOui(const uint8_t mac[6]) {
    for (size_t i = 0; i < DRONE_DJI_OUI_COUNT; i++)
        if (mac[0] == DRONE_DJI_OUI[i][0] && mac[1] == DRONE_DJI_OUI[i][1] &&
            mac[2] == DRONE_DJI_OUI[i][2]) return true;
    return false;
}

static bool emitVendorOui(const uint8_t mac[6], int rssi, AcabSource src,
                          AcabDetection* out) {
    acabInit(out, ACAB_DRONE, src, mac, (int16_t)rssi);
    out->method     = M_OUI;
    out->confidence = DRONE_OUI_CONFIDENCE;
    snprintf(out->detail, sizeof(out->detail), "DJI gear, no Remote ID");
    return true;
}

// ---------------------------------------------------------------------------
// BLE advertisement
// ---------------------------------------------------------------------------
// ASTM F3411 / OpenDroneID over Bluetooth Legacy puts the Remote ID message in a
// Service-Data AD structure: type 0x16, Service UUID 0xFFFA (little-endian FA FF),
// app code 0x0D, a counter byte, then the packed ODID message. We check every AD
// structure for it instead of assuming a fixed offset, so a drone whose advert
// opens with a Flags structure (common on BT5 extended advertising) still gets
// caught. The signature bytes are all from the public spec; the message body goes
// to the Apache-licensed decoder.
static bool droneRidBLE(const uint8_t mac[6], const uint8_t* payload, size_t len,
                        int rssi, AcabDetection* out) {
    if (!payload || len < 6) return false;

    for (size_t i = 0; i + 1 < len; i += 1u + payload[i]) {
        const uint8_t adLen = payload[i];
        if (adLen == 0 || i + 1 + (size_t)adLen > len) break;

        const bool odidElem = payload[i + 1] == 0x16 && adLen >= 6 &&
                              payload[i + 2] == 0xFA && payload[i + 3] == 0xFF &&
                              payload[i + 4] == 0x0D;
        if (!odidElem) continue;

        const uint8_t* msg    = payload + i + 6;     // past type + UUID(2) + appcode + counter
        const int      msgLen = (int)adLen - 5;
        if (msgLen < (int)sizeof(ODID_BasicID_encoded)) return false;

        ODID_UAS_Data uas;
        memset(&uas, 0, sizeof(uas));
        if ((msg[0] & 0xF0) == (ODID_MESSAGETYPE_PACKED << 4))
            odid_message_process_pack(&uas, (uint8_t*)msg, msgLen);
        else
            decodeOpenDroneID(&uas, (uint8_t*)msg);
        return fillFromODID(&uas, mac, rssi, SRC_REMOTEID, out);
    }
    return false;
}

// Public BLE classifier: Remote ID first, the vendor-OUI fallback only under it.
bool droneClassifyBLE(const uint8_t mac[6], const uint8_t* payload, size_t len,
                      int rssi, AcabDetection* out) {
    if (droneRidBLE(mac, payload, len, rssi, out)) return true;
    if (droneVendorOui(mac)) return emitVendorOui(mac, rssi, SRC_BLE, out);
    return false;
}

// ---------------------------------------------------------------------------
// 802.11 management frame (WiFi promiscuous capture)
// ---------------------------------------------------------------------------
// Remote ID comes in two public ASTM F3411 frame types: a NAN action frame (fixed
// multicast destination 51:6f:9a:01:00:00) and a beacon carrying an ODID vendor
// IE (Wi-Fi Alliance OUI 90:3a:e6 or ASTM OUI fa:0b:bc). Both hand their ODID
// payload to the Apache-licensed decoder.
static bool droneRidWiFi(const uint8_t* frame, size_t len, int rssi,
                         AcabDetection* out) {
    if (!frame || len < 24) return false;

    // NAN action frame: recognised solely by its multicast destination (bytes 4-9).
    static const uint8_t kNanDest[6] = {0x51, 0x6f, 0x9a, 0x01, 0x00, 0x00};
    if (memcmp(frame + 4, kNanDest, 6) == 0) {
        ODID_UAS_Data uas;
        memset(&uas, 0, sizeof(uas));
        char srcMac[6] = {0};
        if (odid_wifi_receive_message_pack_nan_action_frame(
                &uas, srcMac, (uint8_t*)frame, (int)len) == 0)
            return fillFromODID(&uas, frame + 10, rssi, SRC_REMOTEID, out);
        return false;
    }

    // Beacon (type/subtype byte 0x80): scan its tagged parameters for an ODID vendor IE.
    if (frame[0] == 0x80) {
        for (size_t off = 36; off + 2 < len; off += 2u + frame[off + 1]) {
            const bool odidVendor =
                frame[off] == 0xdd && off + 5 < len &&
                ((frame[off+2]==0x90 && frame[off+3]==0x3a && frame[off+4]==0xe6) ||
                 (frame[off+2]==0xfa && frame[off+3]==0x0b && frame[off+4]==0xbc));
            if (!odidVendor) continue;

            const size_t msg = off + 7;                  // past tag + len + OUI(3) + type
            if (msg < len) {
                ODID_UAS_Data uas;
                memset(&uas, 0, sizeof(uas));
                odid_message_process_pack(&uas, (uint8_t*)(frame + msg), (int)(len - msg));
                return fillFromODID(&uas, frame + 10, rssi, SRC_REMOTEID, out);
            }
        }
    }
    return false;
}

// Public WiFi classifier: Remote ID first, then the vendor-OUI fallback on the
// transmitter address (addr2, frame bytes 10-15) when no RID was decoded.
bool droneClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                       AcabDetection* out) {
    if (droneRidWiFi(frame, len, rssi, out)) return true;
    if (frame && len >= 16 && droneVendorOui(frame + 10))
        return emitVendorOui(frame + 10, rssi, SRC_WIFI, out);
    return false;
}
