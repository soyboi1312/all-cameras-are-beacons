// Host regression for the mesh-detect uplink's real mesh_link.cpp.
//
// WHY: a non-drone mesh line's lat/lon is the OWNER'S phone fix, and the default mesh-detect
// build talks to the public LongFast channel, whose key everyone has. Until 2026-10-11 buildText
// appended that fix as a Google Maps link on channel 0, and loop() announced the unit there at
// boot. Neither was covered by a test. This suite includes the real implementation (like
// test_alerts does for alerts.cpp) so it drives the file-private buildText and observes the bytes
// handed to the Heltec UART, not log text.
//
// Rule under test (buildText / meshLinkBootPing, mesh_link.cpp): the phone fix and the boot ping
// go out only over MESH_PROTO on a secondary channel index. A drone line keeps the aircraft's own
// Remote ID position on every channel, because the aircraft broadcast that position itself.
#include <Arduino.h>
#include <freertos/semphr.h>
#include <string>

// Host stand-in for the Heltec UART. Captures every byte mesh_link.cpp writes, in order, and
// notes whether the TX mutex was HELD when each write landed. The semphr stub reports takes
// (acabHostSemaphoreTakeObserver) but not gives, so gives are routed through testGive below and
// gMutexHeld is the live take-minus-give depth: a take that was already given back does not
// count. Only the members mesh_link.cpp calls exist.
#define SERIAL_8N1 0
static std::string gUart;            // bytes that would reach the Heltec
static unsigned    gUartWrites = 0;
static unsigned    gUartWritesUnderLock = 0;
static unsigned    gMutexTakes = 0;  // takes in this scenario
static int         gMutexHeld = 0;   // takes minus gives: > 0 means the mutex is held right now
static BaseType_t testGive(SemaphoreHandle_t h) { gMutexHeld--; return xSemaphoreGive(h); }
#define xSemaphoreGive testGive      // applies to mesh_link.cpp, included below; semphr.h is pragma once
struct HardwareSerial {
    explicit HardwareSerial(int) {}
    void begin(unsigned long, uint32_t, int, int) {}
    size_t write(const uint8_t* b, size_t n) {
        gUart.append(reinterpret_cast<const char*>(b), n);
        gUartWrites++;
        if (gMutexHeld > 0) gUartWritesUnderLock++;
        return n;
    }
    // The Arduino Print::println(const char*) is two writes (text, then "\r\n"); keep that
    // shape so the mutex check sees both.
    size_t println(const char* s) {
        size_t n = write(reinterpret_cast<const uint8_t*>(s), strlen(s));
        return n + write(reinterpret_cast<const uint8_t*>("\r\n"), 2);
    }
};

#include "../../src/mesh-detect/mesh_link.cpp"

#include <cstdio>

static int gFail = 0;
static int gRun = 0;

static void check(const char* name, bool pass) {
    gRun++;
    if (!pass) gFail++;
    printf("  %-72s %s\n", name, pass ? "PASS" : "**FAIL**");
}

static void useLink(uint8_t channel, MeshTransport transport, bool includeGPS) {
    MeshLinkConfig c = meshLinkDefaults();
    c.channelIndex = channel;
    c.transport    = transport;
    c.includeGPS   = includeGPS;
    meshLinkBegin(c);
    gUart.clear();
    gUartWrites = gUartWritesUnderLock = gMutexTakes = 0;
    gMutexHeld = 0;
}

// A row as mesh-detect's onDetection hands it to meshLinkSend: for a non-drone type the lat/lon
// is the phone's fix; for a drone it is the aircraft's broadcast position. Synthetic MAC.
static AcabDetection row(AcabDeviceType type, AcabSource src) {
    AcabDetection d;
    const uint8_t mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    acabInit(&d, type, src, mac, -58);
    d.lat = 34.05012;
    d.lon = -118.24001;
    return d;
}

static bool has(const std::string& s, const char* needle) { return s.find(needle) != std::string::npos; }

int main() {
    acabHostSemaphoreTakeObserver = [](SemaphoreHandle_t) { gMutexTakes++; gMutexHeld++; };
    char line[256];

    printf("\n=== mesh uplink: phone fix never leaves on the public channel ===\n");

    useLink(0, MESH_TEXT, true);            // the default build ([env:mesh-detect])
    buildText(row(ACAB_FLOCK_CAMERA, SRC_BLE), line, sizeof(line));
    check("channel 0 TEXT: non-drone line carries no phone coordinates even with includeGPS",
          !has(line, "maps.google.com") && !has(line, "34.05"));
    check("channel 0 TEXT: the rest of the line is intact",
          std::string(line) == "ALPR camera detected | BLE | rssi -58 | 02:00:00:00:00:01");

    useLink(0, MESH_PROTO, true);           // PROTO on index 0 is still the public primary
    buildText(row(ACAB_AXON_BODYCAM, SRC_WIFI), line, sizeof(line));
    check("channel 0 PROTO: still public, still no phone coordinates", !has(line, "maps.google.com"));

    useLink(1, MESH_TEXT, true);            // TEXTMSG ignores the index: public whatever it says
    buildText(row(ACAB_FLOCK_CAMERA, SRC_BLE), line, sizeof(line));
    check("TEXT with a non-zero index: TEXTMSG lands on the primary, so no phone coordinates",
          !has(line, "maps.google.com"));

    useLink(1, MESH_PROTO, true);           // the private build ([env:mesh-detect-ch1])
    buildText(row(ACAB_FLOCK_CAMERA, SRC_BLE), line, sizeof(line));
    check("channel 1 PROTO with includeGPS: the phone fix rides along as the maps link (anti-vacuity)",
          std::string(line) == "ALPR camera detected | BLE | rssi -58 | 02:00:00:00:00:01"
                               " | https://maps.google.com/?q=34.05012,-118.24001");

    useLink(1, MESH_PROTO, false);
    buildText(row(ACAB_FLOCK_CAMERA, SRC_BLE), line, sizeof(line));
    check("channel 1 PROTO with includeGPS off: no phone coordinates", !has(line, "maps.google.com"));

    useLink(0, MESH_TEXT, true);
    AcabDetection drone = row(ACAB_DRONE, SRC_REMOTEID);
    snprintf(drone.id, sizeof(drone.id), "1581F4F");
    drone.altitude = 120;
    buildText(drone, line, sizeof(line));
    check("channel 0: a drone line keeps the aircraft's own Remote ID position and altitude",
          std::string(line) == "Drone detected | RID | rssi -58 | 02:00:00:00:00:01 | RID 1581F4F"
                               " | https://maps.google.com/?q=34.05012,-118.24001 | alt 120m");

    printf("\n=== boot ping and UART serialisation ===\n");

    useLink(0, MESH_TEXT, true);
    meshLinkBootPing();
    check("channel 0: the boot ping writes nothing to the Heltec", gUart.empty() && gUartWrites == 0);

    useLink(1, MESH_PROTO, true);
    meshLinkBootPing();
    check("channel 1 PROTO: the boot ping goes out as a stream frame carrying the text",
          gUart.size() > 12 && (uint8_t)gUart[0] == 0x94 && (uint8_t)gUart[1] == 0xC3
          && has(gUart, "mesh-detect ACAB online"));
    // 94 C3 hi lo | 0A mp_len | 15 FF FF FF FF | 18 <channel> ... (buildProtoFrame)
    check("PROTO frame names the configured channel index", (uint8_t)gUart[11] == 0x18 && (uint8_t)gUart[12] == 1);
    check("the UART write runs while the TX mutex is held (PROTO, one write), then it is released",
          gUartWrites == 1 && gUartWritesUnderLock == gUartWrites && gMutexTakes == 1 && gMutexHeld == 0);

    useLink(0, MESH_TEXT, true);
    meshLinkSendText("ALPR camera detected | BLE | rssi -58 | 02:00:00:00:00:01");
    check("TEXT mode: both println writes (text, newline) land while the TX mutex is held, then it is released",
          gUartWrites == 2 && gUartWritesUnderLock == gUartWrites && gMutexTakes == 1 && gMutexHeld == 0);
    check("TEXT mode: the line reaches the Heltec newline-terminated",
          gUart == "ALPR camera detected | BLE | rssi -58 | 02:00:00:00:00:01\r\n");

    printf(gFail ? "\n  REGRESSION DETECTED (%d failure%s of %d)\n\n"
                 : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail == 1 ? "" : "s", gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
