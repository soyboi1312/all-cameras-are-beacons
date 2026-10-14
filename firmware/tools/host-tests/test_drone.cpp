// Host regression test for the drone detector: the ASTM F3411 / OpenDroneID "Remote ID" path,
// and the vendor-OUI fallback that sits UNDERNEATH it.
//
// WHY THIS EXISTS: drone_detect.cpp has two layers that are easy to break independently.
//   1. Remote ID (confidence 99). Field-validated once, 2026-07-23, against a real airborne DJI.
//      Nothing about that decode is exercised by a compile, and a broken AD walk would look
//      exactly like "no drones flew past today".
//   2. The vendor-OUI fallback (confidence 60), which is OPT-IN and DEFAULT OFF because it cannot
//      tell a flying drone from a controller sitting on a shelf. Two regressions matter here and
//      neither is visible to the compiler: the fallback silently turning ON by default (every
//      Parrot gadget becomes a "drone"), and its detail string drifting. Both apps parse that
//      string's "<Maker> gear, no Remote ID" shape to tell an OUI guess from a real Remote ID
//      sighting, so the exact wording is a wire format, not cosmetics.
//
// HOW THE ODID DECODER GETS HERE: run.sh compiles this file plus drone_detect.cpp and nothing
// else, but the decode lives in the vendored opendroneid library (Apache-2.0). Rather than fake
// the decoder and end up asserting against our own fake, we #include the vendored opendroneid.c
// AND its sibling wifi.c into this translation unit, so every Remote ID assertion below runs the
// REAL decoder and the REAL 802.11 pack/NAN parser (both LOCAL SECURITY PATCHes included) over
// REAL wire bytes produced by the REAL encoder. wifi.c wants <byteswap.h>, which macOS lacks;
// stubs/byteswap.h supplies the three macros. The one seam is the NAN receive shim below.
#include "drone_detect.h"
#include "drone_signatures.h"

// Pulled in BEFORE the extern "C" block on purpose: opendroneid.c includes <math.h> and <stdio.h>,
// wifi.c <errno.h> and <time.h>, and dragging a system header into a C-linkage block is how you
// get a mystery build failure on a different libc. Their include guards make the ones inside the
// block no-ops.
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <vector>
#include <Arduino.h>   // the host stub's deterministic millis(), for the track-TTL test

extern "C" {
#include "opendroneid/opendroneid.h"
#include "opendroneid/opendroneid.c"   // the real Apache-2.0 decoder, not a stand-in
// The real wifi.c defines the NAN receive entry point drone_detect.cpp links against. Rename that
// one definition so the shim below can own the public name and forward to it.
#define odid_wifi_receive_message_pack_nan_action_frame acabRealNanReceive
// wifi.c is C: its pack builder hands (void *) to the typed encode* functions, which C++ rejects.
// These add the cast at those call sites only. They sit after opendroneid.c so they cannot touch
// the definitions there, and are undefined again right after wifi.c.
#define encodeBasicIDMessage(e, d)    encodeBasicIDMessage((ODID_BasicID_encoded*)(e), (d))
#define encodeLocationMessage(e, d)   encodeLocationMessage((ODID_Location_encoded*)(e), (d))
#define encodeAuthMessage(e, d)       encodeAuthMessage((ODID_Auth_encoded*)(e), (d))
#define encodeSelfIDMessage(e, d)     encodeSelfIDMessage((ODID_SelfID_encoded*)(e), (d))
#define encodeSystemMessage(e, d)     encodeSystemMessage((ODID_System_encoded*)(e), (d))
#define encodeOperatorIDMessage(e, d) encodeOperatorIDMessage((ODID_OperatorID_encoded*)(e), (d))
#include "opendroneid/wifi.c"          // the real pack + NAN parser, with the local bounds patches
#undef encodeBasicIDMessage
#undef encodeLocationMessage
#undef encodeAuthMessage
#undef encodeSelfIDMessage
#undef encodeSystemMessage
#undef encodeOperatorIDMessage
#undef odid_wifi_receive_message_pack_nan_action_frame
}

// ---------------------------------------------------------------------------
// The definitions drone_detect.cpp needs from translation units the harness does not compile.
// ---------------------------------------------------------------------------

// Desert forces classification past a toggled-off detector, so tests control it: several
// assertions prove it reaches the master gate but NOT the OUI opt-in.
static bool gDesert = false;
bool desertIsEnabled(void) { return gDesert; }

// acabSanitizeAscii is NOT defined here: it is inline in acab_scanner.h, so every string the drone
// detector emits (UAS ID, operator ID) goes through the real clamp.

// ROUTING SHIM over the real NAN parser. Every frame goes to acabRealNanReceive unless a test
// scripts a failure through gNanRc, which is what the routing tests need: that a parse failure
// suppresses the detection (and hands over to the OUI fallback), and that the frame reached the
// parser at all (gNanCalls). The parsing itself is never faked.
static int  gNanRc    = 0;              // nonzero: pretend the vendored parser rejected the frame
static int  gNanCalls = 0;              // proves the frame reached the parser
extern "C" int odid_wifi_receive_message_pack_nan_action_frame(ODID_UAS_Data* uas, char* mac,
                                                              uint8_t* buf, size_t buf_size) {
    gNanCalls++;
    if (gNanRc != 0) return gNanRc;
    return acabRealNanReceive(uas, mac, buf, buf_size);
}

// ---------------------------------------------------------------------------
// Assertion helpers. failures, chk_impl and the chk macro (and why it must stay a macro) come from
// host_check.h; ok() below prints in the same format.
// ---------------------------------------------------------------------------
#include "host_check.h"
// For the fields chk() does not carry (id, coordinates, method, source, telemetry).
static void ok(const char* name, bool cond) {
    printf("  %-52s %s\n", name, cond ? "PASS" : "**FAIL**");
    if (!cond) failures++;
}
static bool nearly(double a, double b) { return fabs(a - b) < 1e-6; }

// ---------------------------------------------------------------------------
// ODID message builders. These run the vendored ENCODER, so the bytes handed to the classifier are
// the same bytes a drone puts on the air - the test cannot pass by agreeing with itself.
// ---------------------------------------------------------------------------
static void mkBasicIDT(uint8_t msg[ODID_MESSAGE_SIZE], const char* uasId, ODID_idtype_t idType) {
    ODID_BasicID_data b; odid_initBasicIDData(&b);
    b.IDType = idType;
    b.UAType = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR;
    strncpy(b.UASID, uasId, sizeof(b.UASID) - 1);
    ODID_BasicID_encoded e; memset(&e, 0, sizeof(e));
    if (encodeBasicIDMessage(&e, &b) != ODID_SUCCESS) { printf("  !! BasicID builder failed\n"); failures++; }
    memcpy(msg, &e, ODID_MESSAGE_SIZE);
}
static void mkBasicID(uint8_t msg[ODID_MESSAGE_SIZE], const char* uasId) {
    mkBasicIDT(msg, uasId, ODID_IDTYPE_SERIAL_NUMBER);
}
// Same message, but the ID bytes are written raw so a test can put hostile non-ASCII in there
// (the encoder's strncpy would stop at the first NUL).
static void mkBasicIDRaw(uint8_t msg[ODID_MESSAGE_SIZE], const uint8_t* id, size_t n) {
    ODID_BasicID_encoded e; memset(&e, 0, sizeof(e));
    e.MessageType  = ODID_MESSAGETYPE_BASIC_ID;
    e.ProtoVersion = ODID_PROTOCOL_VERSION;
    e.IDType = ODID_IDTYPE_SERIAL_NUMBER;
    e.UAType = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR;
    if (n > ODID_ID_SIZE) n = ODID_ID_SIZE;
    memcpy(e.UASID, id, n);
    memcpy(msg, &e, ODID_MESSAGE_SIZE);
}
// Location with everything populated. Pass telemetry = false to leave ODID's "no value" sentinels
// in place (INV_DIR 361 / INV_SPEED_H 255 / INV_SPEED_V 63 / INV_ALT -1000), which is what a drone
// that is not reporting those fields actually transmits.
static void mkLocation(uint8_t msg[ODID_MESSAGE_SIZE], double lat, double lon, bool telemetry) {
    ODID_Location_data l; odid_initLocationData(&l);
    l.Status    = ODID_STATUS_AIRBORNE;
    l.Latitude  = lat;
    l.Longitude = lon;
    if (telemetry) {
        l.Direction       = 216.0f;
        l.SpeedHorizontal = 12.5f;
        l.SpeedVertical   = 0.5f;
        l.AltitudeBaro    = 48.0f;
        l.AltitudeGeo     = 48.0f;
        l.Height          = 34.0f;
        l.HeightType      = ODID_HEIGHT_REF_OVER_TAKEOFF;
    }
    ODID_Location_encoded e; memset(&e, 0, sizeof(e));
    if (encodeLocationMessage(&e, &l) != ODID_SUCCESS) { printf("  !! Location builder failed\n"); failures++; }
    memcpy(msg, &e, ODID_MESSAGE_SIZE);
}
static void mkSystem(uint8_t msg[ODID_MESSAGE_SIZE], double opLat, double opLon, float opAlt) {
    ODID_System_data s; odid_initSystemData(&s);
    s.OperatorLocationType = ODID_OPERATOR_LOCATION_TYPE_TAKEOFF;
    s.OperatorLatitude     = opLat;
    s.OperatorLongitude    = opLon;
    s.OperatorAltitudeGeo  = opAlt;
    ODID_System_encoded e; memset(&e, 0, sizeof(e));
    if (encodeSystemMessage(&e, &s) != ODID_SUCCESS) { printf("  !! System builder failed\n"); failures++; }
    memcpy(msg, &e, ODID_MESSAGE_SIZE);
}
static void mkOperatorID(uint8_t msg[ODID_MESSAGE_SIZE], const char* opId) {
    ODID_OperatorID_data o; odid_initOperatorIDData(&o);
    o.OperatorIdType = ODID_OPERATOR_ID;
    strncpy(o.OperatorId, opId, sizeof(o.OperatorId) - 1);
    ODID_OperatorID_encoded e; memset(&e, 0, sizeof(e));
    if (encodeOperatorIDMessage(&e, &o) != ODID_SUCCESS) { printf("  !! OperatorID builder failed\n"); failures++; }
    memcpy(msg, &e, ODID_MESSAGE_SIZE);
}
// A BT5 / WiFi "message pack": several 25-byte messages in one frame, type nibble 0xF.
static size_t mkPack(uint8_t* out, const uint8_t* msgs, int count) {
    ODID_MessagePack_data p; odid_initMessagePackData(&p);
    p.SingleMessageSize = ODID_MESSAGE_SIZE;
    p.MsgPackSize       = (uint8_t)count;
    for (int i = 0; i < count; i++) memcpy(&p.Messages[i], msgs + i * ODID_MESSAGE_SIZE, ODID_MESSAGE_SIZE);
    ODID_MessagePack_encoded e; memset(&e, 0, sizeof(e));
    if (encodeMessagePack(&e, &p) != ODID_SUCCESS) { printf("  !! MessagePack builder failed\n"); failures++; }
    // On the wire the pack is header(3) + count*25; the decoder is handed exactly that many bytes.
    size_t n = 3 + (size_t)count * ODID_MESSAGE_SIZE;
    memcpy(out, &e, n);
    return n;
}

// ---- BLE advert builders (AD structures: [len][type][data...]) ----
// Service Data, UUID 0xFFFA little-endian, app code 0x0D, counter, then the ODID message.
static void addOdid(std::vector<uint8_t>& a, const uint8_t* msg, size_t msgLen) {
    a.push_back((uint8_t)(5 + msgLen));    // type + UUID(2) + appcode + counter + message
    a.push_back(0x16); a.push_back(0xFA); a.push_back(0xFF); a.push_back(0x0D);
    a.push_back(0x01);                     // per-message-type counter
    for (size_t i = 0; i < msgLen; i++) a.push_back(msg[i]);
}
// Same shape but with the caller's own UUID / app code, for the near-miss tests.
static void addOdidLike(std::vector<uint8_t>& a, uint8_t lo, uint8_t hi, uint8_t appCode,
                        const uint8_t* msg, size_t msgLen) {
    a.push_back((uint8_t)(5 + msgLen));
    a.push_back(0x16); a.push_back(lo); a.push_back(hi); a.push_back(appCode);
    a.push_back(0x01);
    for (size_t i = 0; i < msgLen; i++) a.push_back(msg[i]);
}
static void addFlags(std::vector<uint8_t>& a) {
    a.push_back(2); a.push_back(0x01); a.push_back(0x06);   // BT5 adverts usually open with this
}

// ---- 802.11 frame builders ----
// Hand-built beacon: header + fixed params, then one vendor IE [dd][len][OUI][type][counter][pack].
// ouiType 0x0D is Remote ID (what the vendored encoder writes); the tests pass other values to
// prove the type gate.
static std::vector<uint8_t> mkBeaconT(const uint8_t addr2[6], const uint8_t oui[3], uint8_t ouiType,
                                      const uint8_t* pack, size_t packLen) {
    std::vector<uint8_t> f(36, 0);          // 24-byte mgmt header + 12 bytes of fixed params
    f[0] = 0x80;                            // type/subtype: beacon
    memcpy(&f[10], addr2, 6);               // addr2 = transmitter
    f.push_back(0xdd);                      // vendor-specific IE
    f.push_back((uint8_t)(4 + 1 + packLen));
    f.push_back(oui[0]); f.push_back(oui[1]); f.push_back(oui[2]);
    f.push_back(ouiType);
    f.push_back(0x01);                      // message counter
    for (size_t i = 0; i < packLen; i++) f.push_back(pack[i]);
    return f;
}
static std::vector<uint8_t> mkBeacon(const uint8_t addr2[6], const uint8_t oui[3],
                                     const uint8_t* pack, size_t packLen) {
    return mkBeaconT(addr2, oui, 0x0D, pack, packLen);
}
// Bare action frame with the NAN destination and nothing valid behind it: for the routing tests,
// which only care whether drone_detect hands the frame to the parser.
static std::vector<uint8_t> mkNan(const uint8_t addr2[6], const uint8_t dest[6]) {
    std::vector<uint8_t> f(64, 0);
    f[0] = 0xd0;                            // action frame
    memcpy(&f[4], dest, 6);                 // addr1 = the NAN multicast destination
    memcpy(&f[10], addr2, 6);
    return f;
}
// Frames from the vendored ENCODER (wifi.c), so the real NAN and beacon parsers see the bytes a
// drone's Wi-Fi radio puts on the air. caa may be null; lat 0 means no Location message.
static void mkUas(ODID_UAS_Data& u, const char* serial, const char* caa, double lat, double lon) {
    odid_initUasData(&u);
    int n = 0;
    if (serial) {
        u.BasicID[n].IDType = ODID_IDTYPE_SERIAL_NUMBER;
        u.BasicID[n].UAType = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR;
        strncpy(u.BasicID[n].UASID, serial, ODID_ID_SIZE);
        u.BasicIDValid[n++] = 1;
    }
    if (caa) {
        u.BasicID[n].IDType = ODID_IDTYPE_CAA_REGISTRATION_ID;
        u.BasicID[n].UAType = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR;
        strncpy(u.BasicID[n].UASID, caa, ODID_ID_SIZE);
        u.BasicIDValid[n++] = 1;
    }
    if (lat != 0.0) {
        u.Location.Status    = ODID_STATUS_AIRBORNE;
        u.Location.Latitude  = lat;
        u.Location.Longitude = lon;
        u.LocationValid = 1;
    }
}
static std::vector<uint8_t> mkRealNan(const uint8_t addr2[6], ODID_UAS_Data& u) {
    char mac[6]; memcpy(mac, addr2, 6);
    std::vector<uint8_t> f(512, 0);
    int n = odid_wifi_build_message_pack_nan_action_frame(&u, mac, 1, f.data(), f.size());
    if (n <= 0) { printf("  !! NAN frame builder failed (%d)\n", n); failures++; n = 0; }
    f.resize((size_t)n);
    return f;
}
static std::vector<uint8_t> mkRealBeacon(const uint8_t addr2[6], ODID_UAS_Data& u) {
    char mac[6]; memcpy(mac, addr2, 6);
    std::vector<uint8_t> f(512, 0);
    int n = odid_wifi_build_message_pack_beacon_frame(&u, mac, "RID", 3, 100, 1, f.data(), f.size());
    if (n <= 0) { printf("  !! beacon frame builder failed (%d)\n", n); failures++; n = 0; }
    f.resize((size_t)n);
    return f;
}

// ---- runners ----
static bool runBLE(const uint8_t mac[6], std::vector<uint8_t>& a, AcabDetection* out) {
    memset(out, 0, sizeof(*out));
    return droneClassifyBLE(mac, a.empty() ? nullptr : a.data(), a.size(), -71, out);
}
static bool runWiFi(std::vector<uint8_t>& f, AcabDetection* out) {
    memset(out, 0, sizeof(*out));
    return droneClassifyWiFi(f.empty() ? nullptr : f.data(), f.size(), -66, out);
}

int main() {
    AcabDetection d;
    bool hit;
    uint8_t msg[ODID_MESSAGE_SIZE], msg2[ODID_MESSAGE_SIZE];
    uint8_t two[2 * ODID_MESSAGE_SIZE], pack[3 + 9 * ODID_MESSAGE_SIZE];

    // Every drone gets its own MAC, and every BasicID its own serial: the detector keeps a track
    // table keyed by UAS-ID (falling back to MAC), so sharing either between two tests would leak
    // one test's coordinates into another's detection.
    const uint8_t macDji[6]    = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x01};  // DJI block, field-observed
    const uint8_t macFlags[6]  = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x02};
    const uint8_t macLoc[6]    = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x03};
    const uint8_t macMerge[6]  = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x04};
    const uint8_t macAdopt[6]  = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x05};
    const uint8_t macOp[6]     = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x06};
    const uint8_t macSys[6]    = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x07};
    const uint8_t macBadLat[6] = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x08};
    const uint8_t macPack[6]   = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x09};
    const uint8_t macShort[6]  = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x0a};
    const uint8_t macHostile[6]= {0x60, 0x60, 0x1f, 0x11, 0x22, 0x0b};
    const uint8_t macTtl[6]    = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x0c};
    const uint8_t macDesert[6] = {0x60, 0x60, 0x1f, 0x11, 0x22, 0x0d};
    const uint8_t macSkydio[6] = {0x38, 0x1d, 0x14, 0x01, 0x02, 0x03};
    const uint8_t macParrot[6] = {0x90, 0x3a, 0xe6, 0x01, 0x02, 0x03};
    const uint8_t macParrotNew[6] = {0x00, 0x12, 0x1c, 0x01, 0x02, 0x03};
    const uint8_t macDjiBaiwang1[6] = {0x9c, 0x5a, 0x8a, 0x01, 0x02, 0x03};
    const uint8_t macDjiBaiwang2[6] = {0xec, 0x72, 0xf7, 0x01, 0x02, 0x03};
    const uint8_t macDjiBaiwang3[6] = {0x34, 0x91, 0xf0, 0x01, 0x02, 0x03};
    const uint8_t macDjiBaiwang4[6] = {0xc8, 0xa1, 0x62, 0x01, 0x02, 0x03};  // listed 2026-10-02
    const uint8_t macAutelMam[6] = {0xec, 0x5b, 0xcd, 0xe1, 0x02, 0x03};
    const uint8_t macAutelNeighbor[6] = {0xec, 0x5b, 0xcd, 0xd1, 0x02, 0x03};
    const uint8_t macAutelAutomotive[6] = {0x18, 0xd7, 0x93, 0x61, 0x02, 0x03};
    const uint8_t macYuneecMam[6] = {0xe0, 0xb6, 0xf5, 0x8f, 0x02, 0x03};
    const uint8_t macYuneecNeighbor[6] = {0xe0, 0xb6, 0xf5, 0x7f, 0x02, 0x03};
    const uint8_t macFreefly[6] = {0xec, 0x71, 0x5e, 0x01, 0x02, 0x03};
    const uint8_t macTeal[6] = {0xb0, 0x30, 0xc8, 0x01, 0x02, 0x03};
    const uint8_t macAeroMal[6] = {0x00, 0x1a, 0xf9, 0x01, 0x02, 0x03};
    const uint8_t macAeroMas[6] = {0x8c, 0x1f, 0x64, 0xb0, 0x7a, 0x03};
    const uint8_t macAeroMasNeighbor[6] = {0x8c, 0x1f, 0x64, 0xb0, 0x6a, 0x03};
    const uint8_t macInspiredMam[6] = {0x34, 0xb5, 0xf3, 0x2a, 0x02, 0x03};
    const uint8_t macInspiredNeighbor[6] = {0x34, 0xb5, 0xf3, 0x3a, 0x02, 0x03};
    const uint8_t macShieldAi[6] = {0x14, 0xdd, 0x48, 0x01, 0x02, 0x03};
    const uint8_t macAndurilMam[6] = {0xe8, 0xb4, 0x70, 0xc1, 0x02, 0x03};
    const uint8_t macAndurilNeighbor[6] = {0xe8, 0xb4, 0x70, 0xb1, 0x02, 0x03};
    const uint8_t macNearMiss[6] = {0x60, 0x60, 0x1e, 0x01, 0x02, 0x03};  // one below DJI's block
    const uint8_t macRandom[6]   = {0x62, 0x60, 0x1f, 0x01, 0x02, 0x03};  // DJI block + LAA bit
    const uint8_t macPhone[6]    = {0xac, 0xde, 0x48, 0x01, 0x02, 0x03};  // nothing at all

    printf("\n=== drone classifier regression ===\n");

    // -----------------------------------------------------------------------
    // Toggles. The two defaults are a product decision, not an implementation detail: RID on,
    // OUI fallback off. A flipped default is a silent behaviour change that ships to every board.
    // -----------------------------------------------------------------------
    ok("master toggle defaults ON", droneIsEnabled());
    ok("OUI fallback defaults OFF", !droneOuiIsEnabled());
    droneRestoreEnabled(false);
    ok("droneRestoreEnabled(false) -> off", !droneIsEnabled());
    droneRestoreEnabled(true);
    ok("droneRestoreEnabled(true) -> on", droneIsEnabled());
    droneOuiRestoreEnabled(true);
    ok("droneOuiRestoreEnabled(true) -> on", droneOuiIsEnabled());
    droneOuiRestoreEnabled(false);
    ok("droneOuiRestoreEnabled(false) -> off", !droneOuiIsEnabled());
    // (The Preferences stub persists within a binary now, but nothing above wrote the droui key,
    //  so these still assert the empty-NVS path: restore applies the default it is handed. The
    //  persisted round-trip is covered by test_axon/test_desert against the same stub.)

    // -----------------------------------------------------------------------
    // BLE Remote ID: the primary path, confidence 99.
    // -----------------------------------------------------------------------
    { std::vector<uint8_t> a; mkBasicID(msg, "1581F3YT7MC5003T0Z10"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDji, a, &d);
      chk("BasicID over BLE service data 0xFFFA", hit, true, d.confidence, 99, d.detail);
      ok("  ... method M_REMOTE_ID, source SRC_REMOTEID",
         d.method == M_REMOTE_ID && d.src == SRC_REMOTEID && d.type == ACAB_DRONE);
      ok("  ... UAS ID decoded (the 2026-07-23 serial)", strcmp(d.id, "1581F3YT7MC5003T0Z10") == 0); }

    // The AD walk must not assume the ODID block is first. BT5 extended adverts routinely open with
    // a Flags structure; if this regresses, every BT5 drone goes silent while BT4 ones still work,
    // which is the kind of half-broken that survives a drive test.
    { std::vector<uint8_t> a; addFlags(a); mkBasicID(msg, "SECONDADSTRUCTURE001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macFlags, a, &d);
      chk("ODID in the SECOND AD structure (Flags first)", hit, true, d.confidence, 99, d.detail);
      ok("  ... UAS ID still decoded", strcmp(d.id, "SECONDADSTRUCTURE001") == 0); }

    // Location message: coordinates and flight telemetry are what the app plots, so each field is
    // pinned. 216 deg / 12.5 m/s / 48 m / 34 m AGL round-trip exactly through the ODID quantisation.
    { std::vector<uint8_t> a; mkLocation(msg, 32.7157, -117.1611, true); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macLoc, a, &d);
      chk("Location message -> position + telemetry", hit, true, d.confidence, 99, d.detail);
      ok("  ... lat/lon decoded", nearly(d.lat, 32.7157) && nearly(d.lon, -117.1611));
      ok("  ... alt 48m, AGL 34m, heading 216, 12.5 m/s",
         d.altitude == 48 && nearly(d.heightAGL, 34.0) && nearly(d.heading, 216.0) &&
         nearly(d.speedH, 12.5) && nearly(d.speedV, 0.5));
      ok("  ... ridStatus 2 (airborne)", d.ridStatus == ODID_STATUS_AIRBORNE); }

    // ODID's "no value" sentinels must NOT be published as real telemetry. If this regresses the
    // app draws a drone flying 255 m/s at 1000 m below sea level.
    { std::vector<uint8_t> a; mkLocation(msg, 32.70, -117.10, false); addOdid(a, msg, sizeof(msg));
      const uint8_t macSent[6] = {0x60, 0x60, 0x1f, 0x33, 0x44, 0x01};
      hit = runBLE(macSent, a, &d);
      chk("Location with ODID no-value sentinels", hit, true, d.confidence, 99, d.detail);
      ok("  ... 361/255/63/-1000 dropped, not published",
         d.heading == 0.0f && d.speedH == 0.0f && d.speedV == 0.0f && d.heightAGL == 0.0f); }

    // A drone splits its identity across separate BT4 adverts. The track table is what makes the
    // second advert carry the first one's data; without it the app shows a drone with no ID.
    { std::vector<uint8_t> a; mkBasicID(msg, "MERGEDRONE0000000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macMerge, a, &d);
      ok("merge: BasicID advert arrives first", hit && strcmp(d.id, "MERGEDRONE0000000001") == 0);
      std::vector<uint8_t> b; mkLocation(msg2, 33.10, -117.20, true); addOdid(b, msg2, sizeof(msg2));
      hit = runBLE(macMerge, b, &d);
      ok("merge: Location advert carries the earlier ID",
         hit && strcmp(d.id, "MERGEDRONE0000000001") == 0 && nearly(d.lat, 33.10)); }

    // The reverse order exercises the other branch in trackFind: a track started by MAC gets
    // ADOPTED when the first BasicID finally shows up, instead of a second track being created
    // (which would drop the position that was already collected).
    { std::vector<uint8_t> a; mkLocation(msg, 33.20, -117.30, true); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macAdopt, a, &d);
      ok("adopt: Location-only advert has no ID yet", hit && d.id[0] == 0 && nearly(d.lat, 33.20));
      std::vector<uint8_t> b; mkBasicID(msg2, "ADOPTDRONE0000000001"); addOdid(b, msg2, sizeof(msg2));
      hit = runBLE(macAdopt, b, &d);
      ok("adopt: BasicID takes over the MAC-keyed track",
         hit && strcmp(d.id, "ADOPTDRONE0000000001") == 0 && nearly(d.lat, 33.20)); }

    // Operator ID lands in `detail`, prefixed "op ". A short ID arrives NUL-padded to 20 bytes
    // and the sanitizer used to turn that padding into dots ("op FAA-OP-777..........").
    { std::vector<uint8_t> a; mkOperatorID(msg, "FAA-OP-777"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macOp, a, &d);
      chk("OperatorID -> detail \"op <id>\", no dot padding", hit, true, d.confidence, 99, d.detail,
          "op FAA-OP-777"); }

    // System message = where the PILOT is standing. This is the part that had never been seen
    // against a real flight until 2026-07-23, and it is a separate field from the aircraft fix.
    { std::vector<uint8_t> a; mkSystem(msg, 32.8000, -117.0000, 12.0f); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macSys, a, &d);
      chk("System message -> operator location", hit, true, d.confidence, 99, d.detail);
      ok("  ... pilot lat/lon/alt, aircraft fix untouched",
         nearly(d.pilotLat, 32.8) && nearly(d.pilotLon, -117.0) && d.pilotAlt == 12 &&
         d.lat == 0.0 && d.lon == 0.0); }

    // Packed message (type nibble 0xF): one frame carrying several messages, which is how BT5 and
    // WiFi carry Remote ID. Different branch in droneRidBLE than the single-message decode.
    { uint8_t bid[ODID_MESSAGE_SIZE], loc[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "PACKEDDRONE000000001"); mkLocation(loc, 34.05, -118.24, true);
      memcpy(two, bid, ODID_MESSAGE_SIZE); memcpy(two + ODID_MESSAGE_SIZE, loc, ODID_MESSAGE_SIZE);
      size_t n = mkPack(pack, two, 2);
      std::vector<uint8_t> a; addOdid(a, pack, n);
      hit = runBLE(macPack, a, &d);
      chk("packed message (BasicID + Location in one)", hit, true, d.confidence, 99, d.detail);
      ok("  ... both messages decoded from one advert",
         strcmp(d.id, "PACKEDDRONE000000001") == 0 && nearly(d.lat, 34.05)); }

    // A short serial is emitted as sent. The sanitizer used to be handed the full 20-byte ODID
    // field, so the app showed "DRONE1.............." and the ID matched no registry lookup.
    { std::vector<uint8_t> a; mkBasicID(msg, "DRONE1"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macShort, a, &d);
      ok("short UAS ID is not dot-padded", hit && strcmp(d.id, "DRONE1") == 0); }

    // One drone, two BasicIDs (F3411 allows a serial plus a CAA registration or session ID; EU
    // class-marked aircraft do this). Both must land on ONE track: the second ID used to open a
    // twin track, so the CAA frame emitted the CAA id with no position and the row flickered.
    { const uint8_t macDual[6] = {0x60, 0x60, 0x1f, 0x33, 0x44, 0x03};
      std::vector<uint8_t> a; mkBasicID(msg, "DUALSERIAL0000000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDual, a, &d);
      ok("dual ID: serial BasicID first", hit && strcmp(d.id, "DUALSERIAL0000000001") == 0);
      std::vector<uint8_t> b; mkLocation(msg2, 33.50, -117.50, true); addOdid(b, msg2, sizeof(msg2));
      hit = runBLE(macDual, b, &d);
      ok("dual ID: Location joins the serial track", hit && nearly(d.lat, 33.50));
      std::vector<uint8_t> c; mkBasicIDT(msg, "FAA-REG-0001", ODID_IDTYPE_CAA_REGISTRATION_ID);
      addOdid(c, msg, sizeof(msg));
      hit = runBLE(macDual, c, &d);
      ok("dual ID: CAA BasicID keeps the serial id and the position",
         hit && strcmp(d.id, "DUALSERIAL0000000001") == 0 && nearly(d.lat, 33.50));
      hit = runBLE(macDual, b, &d);
      ok("dual ID: next Location still carries the serial id",
         hit && strcmp(d.id, "DUALSERIAL0000000001") == 0 && nearly(d.lat, 33.50)); }
    // Reverse order: the CAA id is emitted until the serial shows up, then the serial takes over
    // for good (serial first), and the position collected meanwhile stays with the track.
    { const uint8_t macDual2[6] = {0x60, 0x60, 0x1f, 0x33, 0x44, 0x04};
      std::vector<uint8_t> a; mkBasicIDT(msg, "FAA-REG-0002", ODID_IDTYPE_CAA_REGISTRATION_ID);
      addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDual2, a, &d);
      ok("dual ID reversed: CAA id first", hit && strcmp(d.id, "FAA-REG-0002") == 0);
      std::vector<uint8_t> b; mkLocation(msg2, 33.60, -117.60, true); addOdid(b, msg2, sizeof(msg2));
      hit = runBLE(macDual2, b, &d);
      std::vector<uint8_t> c; mkBasicID(msg, "DUALSERIAL0000000002"); addOdid(c, msg, sizeof(msg));
      hit = runBLE(macDual2, c, &d);
      ok("dual ID reversed: serial takes over, position persists",
         hit && strcmp(d.id, "DUALSERIAL0000000002") == 0 && nearly(d.lat, 33.60));
      hit = runBLE(macDual2, a, &d);
      ok("dual ID reversed: a repeat CAA frame does not flip the id back",
         hit && strcmp(d.id, "DUALSERIAL0000000002") == 0 && nearly(d.lat, 33.60)); }
    // A pack carrying both BasicIDs, CAA first: the decoder puts the CAA in BasicID[0] and the
    // serial in BasicID[1]. Only slot 0 used to be read, so the emitted id was the CAA one.
    { const uint8_t macDual3[6] = {0x60, 0x60, 0x1f, 0x33, 0x44, 0x05};
      uint8_t caa[ODID_MESSAGE_SIZE], ser[ODID_MESSAGE_SIZE];
      mkBasicIDT(caa, "FAA-REG-0003", ODID_IDTYPE_CAA_REGISTRATION_ID); mkBasicID(ser, "DUALSERIAL0000000003");
      memcpy(two, caa, ODID_MESSAGE_SIZE); memcpy(two + ODID_MESSAGE_SIZE, ser, ODID_MESSAGE_SIZE);
      size_t n = mkPack(pack, two, 2);
      std::vector<uint8_t> a; addOdid(a, pack, n);
      hit = runBLE(macDual3, a, &d);
      ok("dual ID in one pack, CAA first: the serial is the id",
         hit && strcmp(d.id, "DUALSERIAL0000000003") == 0); }

    // Hostile ID bytes must not reach the app as control characters: iOS silently drops invalid
    // JSON, which would suppress the live alert entirely. Every byte outside printable ASCII
    // becomes '.', so a crafted advert cannot inject a quote, a newline or a NUL.
    { const uint8_t evil[20] = {'D','J','I',0x01,0x1b,'"','\n',0xff,0x7f,'X',
                                'Y','Z',0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09};
      mkBasicIDRaw(msg, evil, sizeof(evil));
      std::vector<uint8_t> a; addOdid(a, msg, sizeof(msg));
      hit = runBLE(macHostile, a, &d);
      ok("control bytes in UAS ID are clamped to '.'",
         hit && strcmp(d.id, "DJI..\"...XYZ........") == 0); }
    // ('"' 0x22 is printable ASCII so it survives; 0x7f DEL and 0xff are not, so they become '.'.)

    // Second line of defence, and the reason the case above avoids an embedded NUL: the vendored
    // decoder copies the UAS ID with strncpy, so a NUL truncates the rest of the field before our
    // sanitizer ever sees it. Worth pinning, because it means a crafted ID cannot smuggle bytes
    // past a NUL either.
    { const uint8_t evil[20] = {'D','J','I',0x00,'"','"','"','"','"','"',
                                '"','"','"','"','"','"','"','"','"','"'};
      const uint8_t macNul[6] = {0x60, 0x60, 0x1f, 0x33, 0x44, 0x02};
      mkBasicIDRaw(msg, evil, sizeof(evil));
      std::vector<uint8_t> a; addOdid(a, msg, sizeof(msg));
      hit = runBLE(macNul, a, &d);
      ok("bytes after an embedded NUL never reach the app",
         hit && strcmp(d.id, "DJI") == 0); }

    // A garbage int32 in the encoded latitude decodes to as much as +/-214 degrees, and a
    // non-finite Mercator projection freezes the map in both apps. The fix keeps the detection but
    // drops the fix, so this asserts BOTH: still a hit, still no coordinates.
    { mkLocation(msg, 32.5, -117.5, true);
      ((ODID_Location_encoded*)msg)->Latitude = 2147483647;   // 214.7483647 degrees
      std::vector<uint8_t> a; addOdid(a, msg, sizeof(msg));
      hit = runBLE(macBadLat, a, &d);
      chk("latitude out of range -> hit, but no map pin", hit, true, d.confidence, 99, d.detail);
      ok("  ... bogus coordinates dropped, lat/lon left 0", d.lat == 0.0 && d.lon == 0.0); }

    // The 60 s track TTL expires the accumulated identity and position, including on a direct
    // MAC match. Otherwise a location-only frame can inherit another flight's UAS ID and
    // operator position indefinitely while the slot survives.
    { std::vector<uint8_t> a; mkBasicID(msg, "TTLDRONE000000000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macTtl, a, &d);
      ok("TTL: BasicID seen at t=0", hit && strcmp(d.id, "TTLDRONE000000000001") == 0);
      acabHostAdvanceMillis(61000);       // deterministic clock, no sleeping
      std::vector<uint8_t> b; mkLocation(msg2, 33.30, -117.40, true); addOdid(b, msg2, sizeof(msg2));
      hit = runBLE(macTtl, b, &d);
      ok("TTL: 61 s later the old identity is gone", hit && d.id[0] == 0 && nearly(d.lat, 33.30)); }

    // -----------------------------------------------------------------------
    // BLE adversarial input. A malformed advert is free to send and arrives unsolicited.
    // -----------------------------------------------------------------------
    { std::vector<uint8_t> a;
      hit = runBLE(macPhone, a, &d);
      chk("empty advert -> no hit", hit, false); }
    { std::vector<uint8_t> a; a.push_back(30); a.push_back(0x16); a.push_back(0xFA);
      a.push_back(0xFF); a.push_back(0x0D); a.push_back(0x01); a.push_back(0x00);
      hit = runBLE(macPhone, a, &d);
      chk("AD length 30 in a 7-byte buffer -> no hit", hit, false); }
    { std::vector<uint8_t> a; a.push_back(0); a.push_back(0x16);
      mkBasicID(msg, "AFTERZEROLENGTH00001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macPhone, a, &d);
      chk("AD length 0 stops the walk (rest ignored)", hit, false); }
    { std::vector<uint8_t> a; a.push_back(0xFF); a.push_back(0x16); a.push_back(0xFA);
      a.push_back(0xFF); a.push_back(0x0D);
      hit = runBLE(macPhone, a, &d);
      chk("AD length 255 overruns -> no hit, no read past end", hit, false); }
    // Near-miss service UUID: 0xFFFB is the neighbour of the ODID 0xFFFA and must not decode.
    { std::vector<uint8_t> a; mkBasicID(msg, "NEARMISSUUID00000001");
      addOdidLike(a, 0xFB, 0xFF, 0x0D, msg, sizeof(msg));
      hit = runBLE(macPhone, a, &d);
      chk("neighbouring service UUID 0xFFFB -> no hit", hit, false); }
    // Near-miss app code: right UUID, wrong ODID application code.
    { std::vector<uint8_t> a; mkBasicID(msg, "NEARMISSAPPCODE00001");
      addOdidLike(a, 0xFA, 0xFF, 0x0C, msg, sizeof(msg));
      hit = runBLE(macPhone, a, &d);
      chk("app code 0x0C instead of 0x0D -> no hit", hit, false); }
    // Truncated ODID message: shorter than one 25-byte record.
    { std::vector<uint8_t> a; a.push_back(20); a.push_back(0x16); a.push_back(0xFA);
      a.push_back(0xFF); a.push_back(0x0D); a.push_back(0x01);
      for (int i = 0; i < 15; i++) a.push_back(0x00);
      hit = runBLE(macPhone, a, &d);
      chk("ODID block too short for one message -> no hit", hit, false);
      // ... and the walk goes on: droneRidBLE used to RETURN on the short block, so it hid any
      // later ODID block. (Needs more than 31 bytes, so extended advertising in practice.)
      mkBasicID(msg, "AFTERSHORTBLOCK00001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macPhone, a, &d);
      chk("too-short ODID element then a valid one -> hit", hit, true, d.confidence, 99, d.detail);
      ok("  ... the later element's ID decoded", strcmp(d.id, "AFTERSHORTBLOCK00001") == 0); }
    // A well-formed advert carrying a message type the decoder rejects: nothing useful decoded,
    // so fillFromODID must decline rather than emit an empty confidence-99 drone.
    { std::vector<uint8_t> a; memset(msg, 0, sizeof(msg)); msg[0] = 0x70;   // reserved type 7
      addOdid(a, msg, sizeof(msg));
      hit = runBLE(macPhone, a, &d);
      chk("valid ODID block, undecodable message -> no hit", hit, false); }

    // -----------------------------------------------------------------------
    // Vendor-OUI fallback (BLE). Default OFF, confidence 60, and the detail string the apps parse.
    // -----------------------------------------------------------------------
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macDji, a, &d);
      chk("DJI OUI, no Remote ID, fallback OFF -> no hit", hit, false); }

    droneOuiSetEnabled(true);
    ok("droneOuiSetEnabled(true) sticks", droneOuiIsEnabled());
    for (size_t i = 0; i < DRONE_VENDOR_OUI_COUNT; i++) {
      const DroneOui& entry = DRONE_VENDOR_OUI[i];
      uint8_t tableMac[6] = {entry.prefix[0], entry.prefix[1], entry.prefix[2],
                             0x01, 0x02, static_cast<uint8_t>(i)};
      if (entry.prefixBits == 28) tableMac[3] = static_cast<uint8_t>(entry.prefix[3] | 0x01);
      if (entry.prefixBits == 36) {
          tableMac[3] = entry.prefix[3];
          tableMac[4] = static_cast<uint8_t>(entry.prefix[4] | 0x01);
      }
      ok("drone OUI table uses a supported IEEE prefix length",
         entry.prefixBits == 24 || entry.prefixBits == 28 || entry.prefixBits == 36);
      char expected[64];
      snprintf(expected, sizeof(expected), "%s gear, no Remote ID", entry.vendor);
      std::vector<uint8_t> flags; addFlags(flags);
      hit = runBLE(tableMac, flags, &d);
      chk("every drone-vendor table entry reaches the classifier", hit, true,
          d.confidence, DRONE_OUI_CONFIDENCE, d.detail, expected);
    }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macDji, a, &d);
      chk("DJI OUI with fallback ON", hit, true, d.confidence, DRONE_OUI_CONFIDENCE, d.detail,
          "DJI gear, no Remote ID");
      ok("  ... method M_OUI, source SRC_BLE (not SRC_REMOTEID)",
         d.method == M_OUI && d.src == SRC_BLE && d.type == ACAB_DRONE);
      ok("  ... no ID and no position invented", d.id[0] == 0 && d.lat == 0.0 && d.lon == 0.0); }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macSkydio, a, &d);
      chk("Skydio OUI -> \"<Maker> gear, no Remote ID\"", hit, true, d.confidence, 60, d.detail,
          "Skydio gear, no Remote ID"); }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macParrot, a, &d);
      chk("Parrot OUI (also the ODID beacon IE OUI)", hit, true, d.confidence, 60, d.detail,
          "Parrot gear, no Remote ID"); }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macParrotNew, a, &d);
      chk("additional Parrot MA-L block", hit, true, d.confidence, 60, d.detail,
          "Parrot gear, no Remote ID"); }
    { std::vector<uint8_t> a; addFlags(a);
      const uint8_t* baiwang[] = {macDjiBaiwang1, macDjiBaiwang2, macDjiBaiwang3, macDjiBaiwang4};
      for (const uint8_t* mac : baiwang) {
          hit = runBLE(mac, a, &d);
          chk("DJI Baiwang MA-L block", hit, true, d.confidence, 60, d.detail,
              "DJI gear, no Remote ID");
      }
    }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macAutelMam, a, &d);
      chk("Autel MA-M exact fourth nibble", hit, true, d.confidence, 60, d.detail,
          "Autel gear, no Remote ID");
      chk("Autel neighboring MA-M block is not widened",
          runBLE(macAutelNeighbor, a, &d), false);
      chk("Autel automotive-diagnostics MA-M is not attributed to a drone",
          runBLE(macAutelAutomotive, a, &d), false); }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macYuneecMam, a, &d);
      chk("Yuneec MA-M exact fourth nibble", hit, true, d.confidence, 60, d.detail,
          "Yuneec gear, no Remote ID");
      chk("Yuneec neighboring MA-M block is not widened",
          runBLE(macYuneecNeighbor, a, &d), false); }
    { std::vector<uint8_t> a; addFlags(a);
      struct VendorCase { const uint8_t* mac; const char* detail; } cases[] = {
          {macFreefly, "Freefly gear, no Remote ID"},
          {macTeal, "Teal gear, no Remote ID"},
          {macAeroMal, "AeroVironment gear, no Remote ID"},
          {macAeroMas, "AeroVironment gear, no Remote ID"},
          {macInspiredMam, "Inspired Flight gear, no Remote ID"},
          {macShieldAi, "Shield AI gear, no Remote ID"},
          {macAndurilMam, "Anduril gear, no Remote ID"},
      };
      for (const VendorCase& c : cases) {
          hit = runBLE(c.mac, a, &d);
          chk("additional narrow drone-vendor assignment", hit, true, d.confidence, 60,
              d.detail, c.detail);
      }
      chk("AeroVironment neighboring MA-S block is not widened",
          runBLE(macAeroMasNeighbor, a, &d), false);
      chk("Inspired Flight neighboring MA-M block is not widened",
          runBLE(macInspiredNeighbor, a, &d), false);
      chk("Anduril neighboring MA-M block is not widened",
          runBLE(macAndurilNeighbor, a, &d), false);
    }
    // Remote ID is decoded FIRST, so a drone in a vendor block never degrades to the OUI guess.
    { std::vector<uint8_t> a; mkBasicID(msg, "LAYERINGDRONE0000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDesert, a, &d);
      chk("RID wins over OUI on the same MAC (99, not 60)", hit, true, d.confidence, 99, d.detail);
      ok("  ... method stays M_REMOTE_ID", d.method == M_REMOTE_ID); }
    // Near-miss OUI: one below DJI's block. A prefix-table off-by-one would light this up.
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macNearMiss, a, &d);
      chk("neighbouring OUI 60:60:1e -> no hit", hit, false); }
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macPhone, a, &d);
      chk("unrelated OUI -> no hit", hit, false); }
    // Randomized / locally-administered address: a real IEEE OUI implies a public address, so the
    // fallback refuses to guess. Consequence worth knowing: drone gear that randomizes its MAC is
    // invisible to this layer, by design.
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macRandom, a, &d);
      chk("DJI block with the LAA bit set -> no hit", hit, false); }

    // -----------------------------------------------------------------------
    // Master toggle and Desert mode.
    // -----------------------------------------------------------------------
    droneSetEnabled(false);
    { std::vector<uint8_t> a; mkBasicID(msg, "TOGGLEDOFF0000000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDji, a, &d);
      chk("master toggle OFF -> even Remote ID is dropped", hit, false); }
    gDesert = true;
    { std::vector<uint8_t> a; mkBasicID(msg, "DESERTDRONE000000001"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDesert, a, &d);
      chk("Desert mode overrides the master toggle", hit, true, d.confidence, 99, d.detail); }
    droneSetEnabled(true);
    droneOuiSetEnabled(false);
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macSkydio, a, &d);
      chk("Desert mode does NOT force the opt-in OUI fallback", hit, false); }
    droneSetEnabled(false);                          // drones off: the greyed-out sub-toggle stays off
    droneOuiSetEnabled(true);
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macSkydio, a, &d);
      chk("drones off + OUI opt-in on + Desert -> no OUI fallback", hit, false); }
    { std::vector<uint8_t> a; mkBasicID(msg, "DESERTDRONE000000002"); addOdid(a, msg, sizeof(msg));
      hit = runBLE(macDesert, a, &d);
      chk("  ... while Remote ID still reaches through Desert", hit, true, d.confidence, 99, d.detail); }
    droneSetEnabled(true);
    droneOuiSetEnabled(false);
    gDesert = false;
    { std::vector<uint8_t> a; addFlags(a);
      hit = runBLE(macSkydio, a, &d);
      chk("fallback off again once Desert is off", hit, false); }

    // -----------------------------------------------------------------------
    // WiFi: NAN action frame, ODID beacon vendor IE, and the OUI fallback on addr2.
    // -----------------------------------------------------------------------
    { std::vector<uint8_t> f(20, 0);
      hit = runWiFi(f, &d);
      chk("frame shorter than an 802.11 header -> no hit", hit, false); }

    // NAN action frame from the vendored encoder, through the REAL vendored parser (wifi.c, with
    // its two local bounds patches). Two BasicIDs plus a Location in one pack.
    { const uint8_t addr2[6] = {0x34, 0xd2, 0x62, 0x55, 0x66, 0x01};
      ODID_UAS_Data u; mkUas(u, "NANDRONE000000000001", "FAA-REG-NAN1", 32.95, -117.15);
      std::vector<uint8_t> f = mkRealNan(addr2, u);
      gNanCalls = 0; gNanRc = 0;
      hit = runWiFi(f, &d);
      chk("NAN action frame (multicast 51:6f:9a:01:00:00)", hit, true, d.confidence, 99, d.detail);
      ok("  ... reached the ODID parser exactly once", gNanCalls == 1);
      ok("  ... MAC taken from addr2, source SRC_REMOTEID",
         memcmp(d.mac, addr2, 6) == 0 && d.src == SRC_REMOTEID);
      ok("  ... serial id and position out of the real parser",
         strcmp(d.id, "NANDRONE000000000001") == 0 && nearly(d.lat, 32.95) && nearly(d.lon, -117.15));
      droneSetEnabled(false); gDesert = true;
      hit = runWiFi(f, &d);
      chk("Desert overrides the master toggle on WiFi too", hit, true, d.confidence, 99, d.detail);
      droneSetEnabled(true); gDesert = false;
      // Every truncation of that frame is rejected by the real parser. The second LOCAL SECURITY
      // PATCH is what keeps a short frame from underflowing the pack length; under --sanitize a
      // regression here reads past the buffer and fails the run.
      bool anyHit = false;
      for (size_t n = 24; n < f.size(); n++) {
          std::vector<uint8_t> g(f.begin(), f.begin() + (long)n);   // exact-size copy, no slack
          if (runWiFi(g, &d)) anyHit = true;
      }
      ok("every truncated NAN frame -> no hit", !anyHit); }

    { const uint8_t nearDest[6] = {0x51, 0x6f, 0x9a, 0x01, 0x00, 0x01};   // one off the multicast
      const uint8_t addr2[6]    = {0x34, 0xd2, 0x62, 0x55, 0x66, 0x02};
      gNanCalls = 0;
      std::vector<uint8_t> f = mkNan(addr2, nearDest);
      hit = runWiFi(f, &d);
      chk("near-miss NAN destination -> no hit", hit, false);
      ok("  ... parser never called for the wrong destination", gNanCalls == 0); }

    // Parse failure must fall through to the OUI fallback rather than emit a half-decoded drone.
    { const uint8_t nanDest[6] = {0x51, 0x6f, 0x9a, 0x01, 0x00, 0x00};
      const uint8_t addr2[6]   = {0x34, 0xd2, 0x62, 0x55, 0x66, 0x03};   // DJI block
      gNanRc = -1;
      std::vector<uint8_t> f = mkNan(addr2, nanDest);
      hit = runWiFi(f, &d);
      chk("NAN parse failure, fallback OFF -> no hit", hit, false);
      droneOuiSetEnabled(true);
      hit = runWiFi(f, &d);
      chk("NAN parse failure, fallback ON -> OUI guess", hit, true, d.confidence, 60, d.detail,
          "DJI gear, no Remote ID");
      ok("  ... source SRC_WIFI for the WiFi fallback", d.src == SRC_WIFI && d.method == M_OUI);
      droneOuiSetEnabled(false);
      gNanRc = 0; }

    // Beacon carrying the ODID vendor IE, both published OUIs.
    { uint8_t bid[ODID_MESSAGE_SIZE], loc[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "WIFIBEACON0000000001"); mkLocation(loc, 32.9000, -117.0500, true);
      memcpy(two, bid, ODID_MESSAGE_SIZE); memcpy(two + ODID_MESSAGE_SIZE, loc, ODID_MESSAGE_SIZE);
      size_t n = mkPack(pack, two, 2);
      const uint8_t wfaOui[3] = {0x90, 0x3a, 0xe6};
      const uint8_t addr2[6]  = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x04};
      std::vector<uint8_t> f = mkBeacon(addr2, wfaOui, pack, n);
      hit = runWiFi(f, &d);
      chk("beacon + ODID IE under 90:3a:e6 (Parrot SA OUI, French DRI scheme)", hit, true, d.confidence, 99, d.detail);
      ok("  ... ID and position out of the beacon",
         strcmp(d.id, "WIFIBEACON0000000001") == 0 && nearly(d.lat, 32.9) && nearly(d.lon, -117.05)); }

    { uint8_t bid[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "ASTMBEACON0000000001");
      size_t n = mkPack(pack, bid, 1);
      const uint8_t astmOui[3] = {0xfa, 0x0b, 0xbc};
      const uint8_t addr2[6]   = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x05};
      std::vector<uint8_t> f = mkBeacon(addr2, astmOui, pack, n);
      hit = runWiFi(f, &d);
      chk("beacon + ASTM ODID IE fa:0b:bc", hit, true, d.confidence, 99, d.detail);
      ok("  ... single-message pack decodes", strcmp(d.id, "ASTMBEACON0000000001") == 0); }

    { uint8_t bid[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "NEARMISSIE0000000001");
      size_t n = mkPack(pack, bid, 1);
      const uint8_t nearOui[3] = {0x90, 0x3a, 0xe5};                     // one below the WFA OUI
      const uint8_t addr2[6]   = {0xac, 0xde, 0x48, 0x55, 0x66, 0x06};
      std::vector<uint8_t> f = mkBeacon(addr2, nearOui, pack, n);
      hit = runWiFi(f, &d);
      chk("beacon with a near-miss vendor OUI -> no hit", hit, false); }

    // Beacon from the vendored encoder (fa:0b:bc, OUI type 0x0D, after SSID and rates IEs),
    // through the real parser, then every truncation of it.
    { const uint8_t addr2[6] = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x07};
      ODID_UAS_Data u; mkUas(u, "ENCBEACON00000000001", nullptr, 32.96, -117.16);
      std::vector<uint8_t> f = mkRealBeacon(addr2, u);
      hit = runWiFi(f, &d);
      chk("encoder-built beacon through the real parser", hit, true, d.confidence, 99, d.detail);
      ok("  ... id and position decoded",
         strcmp(d.id, "ENCBEACON00000000001") == 0 && nearly(d.lat, 32.96) && nearly(d.lon, -117.16));
      bool anyHit = false;
      for (size_t n = 24; n < f.size(); n++) {
          std::vector<uint8_t> g(f.begin(), f.begin() + (long)n);
          if (runWiFi(g, &d)) anyHit = true;
      }
      ok("every truncated beacon -> no hit", !anyHit); }

    // The OUI-type gate. 90:3a:e6 is Parrot SA's corporate OUI, so Parrot gear carries other
    // vendor IEs under it; the walk used to match on the OUI alone and return after the first one,
    // so a decoy IE ahead of the real Remote ID IE hid the drone.
    { uint8_t bid[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "DECOYIE0000000000001");
      size_t n = mkPack(pack, bid, 1);
      const uint8_t wfaOui[3] = {0x90, 0x3a, 0xe6};
      const uint8_t addr2[6]  = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x08};
      std::vector<uint8_t> f = mkBeacon(addr2, wfaOui, pack, n);
      const uint8_t decoy[8]  = {0xdd, 0x06, 0x90, 0x3a, 0xe6, 0x01, 0xaa, 0xbb};   // 8-byte IE, type 0x01
      f.insert(f.begin() + 36, decoy, decoy + sizeof(decoy));
      hit = runWiFi(f, &d);
      chk("decoy 90:3a:e6 IE ahead of the real ODID IE -> still hits", hit, true, d.confidence, 99, d.detail);
      ok("  ... decoded from the second IE", strcmp(d.id, "DECOYIE0000000000001") == 0);
      std::vector<uint8_t> g = mkBeaconT(addr2, wfaOui, 0x13, pack, n);   // 0x13: wifi.c's NAN type, not Remote ID
      hit = runWiFi(g, &d);
      chk("ODID pack under 90:3a:e6 with OUI type 0x13 -> no hit", hit, false); }

    // The decode is bounded to the IE. A pack header claiming two messages inside an IE that holds
    // one used to be decoded against the rest of the frame, so whatever followed the IE (here a
    // Location message, on the air the FCS or another IE) became the drone's second message.
    { uint8_t bid[ODID_MESSAGE_SIZE], loc[ODID_MESSAGE_SIZE];
      mkBasicID(bid, "BOUNDEDIE00000000001"); mkLocation(loc, 33.70, -117.70, true);
      size_t n = mkPack(pack, bid, 1);
      pack[2] = 2;                                                       // MsgPackSize: claims 2, IE holds 1
      const uint8_t astmOui[3] = {0xfa, 0x0b, 0xbc};
      const uint8_t addr2[6]   = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x09};
      std::vector<uint8_t> f = mkBeacon(addr2, astmOui, pack, n);
      for (size_t i = 0; i < ODID_MESSAGE_SIZE; i++) f.push_back(loc[i]);   // trailing bytes after the IE
      hit = runWiFi(f, &d);
      chk("pack claiming more messages than its IE holds -> no hit", hit, false); }

    // Header-only ODID IEs at the very end of the frame: zero or one pack byte. The first LOCAL
    // SECURITY PATCH in wifi.c rejects these before reading MsgPackSize; under --sanitize a
    // regression reads past the buffer.
    { const uint8_t astmOui[3] = {0xfa, 0x0b, 0xbc};
      const uint8_t addr2[6]   = {0xe4, 0x7a, 0x2c, 0x55, 0x66, 0x0a};
      bool anyHit = false;
      for (size_t packLen = 0; packLen < 3; packLen++) {
          const uint8_t stub[2] = {0xf2, 0x19};                          // looks like a pack header start
          std::vector<uint8_t> f = mkBeacon(addr2, astmOui, stub, packLen);
          std::vector<uint8_t> g(f.begin(), f.end());                    // exact-size copy, no slack
          if (runWiFi(g, &d)) anyHit = true;
      }
      ok("ODID IE shorter than a pack header -> no hit", !anyHit); }

    // Hostile IE length: the tagged-parameter walk must run off the end rather than into it.
    { std::vector<uint8_t> f(36, 0); f[0] = 0x80;
      f.push_back(0xdd); f.push_back(200);                               // claims 200 bytes, has 4
      f.push_back(0x00); f.push_back(0x11); f.push_back(0x22); f.push_back(0x33);
      hit = runWiFi(f, &d);
      chk("beacon IE length overruns the frame -> no hit", hit, false); }
    { std::vector<uint8_t> f(36, 0); f[0] = 0x80;
      hit = runWiFi(f, &d);
      chk("beacon with no tagged parameters at all -> no hit", hit, false); }

    // The OUI fallback needs only addr2, so it fires on frames too short for droneRidWiFi (>= 24)
    // but long enough to hold addr2 (>= 16). Boundary worth pinning: 16 hits, 15 does not.
    droneOuiSetEnabled(true);
    { std::vector<uint8_t> f(16, 0); f[0] = 0x80;
      const uint8_t addr2[6] = {0xec, 0x5b, 0xcd, 0xe7, 0x88, 0x01};     // Autel MA-M
      memcpy(&f[10], addr2, 6);
      hit = runWiFi(f, &d);
      chk("16-byte frame -> OUI fallback on addr2 (Autel)", hit, true, d.confidence, 60, d.detail,
          "Autel gear, no Remote ID"); }
    { std::vector<uint8_t> f(15, 0); f[0] = 0x80;
      const uint8_t addr2[6] = {0xec, 0x5b, 0xcd, 0x77, 0x88, 0x02};
      memcpy(&f[10], addr2, 5);
      hit = runWiFi(f, &d);
      chk("15-byte frame -> too short even for addr2", hit, false); }
    { std::vector<uint8_t> f(24, 0); f[0] = 0x80;
      const uint8_t addr2[6] = {0xe0, 0xb6, 0xf5, 0x87, 0x88, 0x03};     // Yuneec MA-M
      memcpy(&f[10], addr2, 6);
      hit = runWiFi(f, &d);
      chk("Yuneec addr2 -> \"Yuneec gear, no Remote ID\"", hit, true, d.confidence, 60, d.detail,
          "Yuneec gear, no Remote ID"); }
    droneSetEnabled(false);
    { std::vector<uint8_t> f(24, 0); f[0] = 0x80;
      const uint8_t addr2[6] = {0xe0, 0xb6, 0xf5, 0x77, 0x88, 0x04};
      memcpy(&f[10], addr2, 6);
      hit = runWiFi(f, &d);
      chk("master toggle OFF gates the WiFi path too", hit, false); }
    droneSetEnabled(true);
    droneOuiSetEnabled(false);

    // A Parrot-block WiFi CLIENT is not an aircraft (the one OUI 90:3A:E6 device in captures
    // 911.log/913.log only probed). As an AP (the ANAFI Thermal shape) it is Parrot gear, but only
    // with the opt-in on: Desert alone does not force the fallback.
    { const uint8_t parrot[6] = {0x90, 0x3a, 0xe6, 0x01, 0x02, 0x04};
      for (int desert = 0; desert < 2; desert++) for (int oui = 0; oui < 2; oui++) {
        if (!desert && !oui) continue;
        gDesert = desert; droneOuiSetEnabled(oui);
        std::vector<uint8_t> f(24, 0);
        memcpy(&f[4], "\xff\xff\xff\xff\xff\xff", 6); memcpy(&f[10], parrot, 6); memcpy(&f[16], f.data() + 4, 6);
        f.push_back(0x00); f.push_back(0x00);          // wildcard SSID IE
        char nm[96];
        f[0] = 0x40;                                   // probe request
        snprintf(nm, sizeof nm, "Parrot-block probe request is not a drone (desert=%d oui=%d)", desert, oui);
        hit = runWiFi(f, &d); chk(nm, hit, false);
        f[0] = 0xB0;                                   // authentication: client role too
        snprintf(nm, sizeof nm, "Parrot-block auth frame is not a drone (desert=%d oui=%d)", desert, oui);
        hit = runWiFi(f, &d); chk(nm, hit, false);
        for (uint8_t fc : {(uint8_t)0x80, (uint8_t)0x50}) {   // beacon, probe response: AP role
          f[0] = fc;
          snprintf(nm, sizeof nm, "Parrot-block %s is %s (desert=%d oui=%d)",
                   fc == 0x80 ? "beacon" : "probe response", oui ? "Parrot gear" : "not a drone",
                   desert, oui);
          hit = runWiFi(f, &d);
          if (oui) chk(nm, hit, true, d.confidence, 60, d.detail, "Parrot gear, no Remote ID");
          else     chk(nm, hit, false);
        }
      }
      gDesert = false; droneOuiSetEnabled(false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
