/*
 * ACAB - Network-camera detector implementation.
 *
 * Branded IP camera on the host WiFi, matched by its non-randomized vendor OUI on an
 * 802.11 frame. OPT-IN / default OFF - mirrors the drone-OUI opt-in exactly (persisted to
 * NVS "acab-netcam"/"on"). See netcam_detect.h for the why, netcam_signatures.h for the
 * table and the honesty rules.
 */
#include "netcam_detect.h"
#include "netcam_signatures.h"
#include "acab_scanner.h"   // acabScannerRefreshWifiFilter: widen/narrow the promiscuous filter on toggle
#include <Arduino.h>
#include <Preferences.h>    // persist the opt-in across reboots (NVS)
#include <string.h>
#include <stdio.h>

// Opt-in flag (default OFF). NVS-backed in namespace "acab-netcam" key "on" so an app-set
// toggle survives a reboot. Mirrors the drone-OUI opt-in (gEnabledOui) exactly.
static bool gEnabled = false;

void netcamSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-netcam", false); p.putBool("on", enabled); p.end();
    // Widen the WiFi promiscuous filter to DATA frames when turning ON, narrow back to
    // MGMT-only when turning OFF, so the OFF path truly delivers no data frames (zero cost).
    // Safe to call before the scanner starts (it no-ops until WiFi is up).
    acabScannerRefreshWifiFilter();
}
bool netcamIsEnabled() { return gEnabled; }

// Reload the persisted opt-in on boot; if none saved yet, use defaultEnabled (callers pass
// false so it stays off by default). Does NOT touch the promiscuous filter - it runs before
// the scanner starts, and acabScannerBegin reads netcamIsEnabled() when it installs the
// filter, so the restored state is applied there.
void netcamRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-netcam", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// Branded IP-camera OUI match. Skip randomized / locally-administered MACs (the OUI is
// meaningless there), like the flock/drone OUI matchers. Cheap: a short scan of the small
// camera table - this is the ONLY per-data-frame work in production when the toggle is on.
// Table entry for this MAC, or nullptr. Callers that only want the label use
// netcamVendorOui below; the classifier needs the whole entry so it can grade a
// field-validated block above a registry-only one.
static const NetcamOui* netcamEntry(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return nullptr;   // locally-administered / randomized: no real OUI
    for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++)
        if (mac[0] == CAMERA_VENDOR_OUI[i].oui[0] && mac[1] == CAMERA_VENDOR_OUI[i].oui[1] &&
            mac[2] == CAMERA_VENDOR_OUI[i].oui[2]) return &CAMERA_VENDOR_OUI[i];
    return nullptr;
}

const char* netcamVendorOui(const uint8_t mac[6]) {
    const NetcamOui* e = netcamEntry(mac);
    return e ? e->vendor : nullptr;
}

bool netcamClassifyWiFi(const uint8_t* frame, size_t len, bool isDataFrame,
                        int rssi, AcabDetection* out) {
    if (!gEnabled) return false;             // opt-in: zero work when off
    if (!frame || len < 16) return false;

    // Where the SOURCE MAC lives.
    size_t saOff;
    if (isDataFrame) {
        // 802.11 data-frame source address depends on the ToDS/FromDS bits (frame-control
        // byte 1). A camera uploading its stream to the AP is ToDS=1/FromDS=0 -> SA = addr2.
        const uint8_t fc1 = frame[1];
        const bool toDS   = fc1 & 0x01;
        const bool fromDS = fc1 & 0x02;
        if (!fromDS)      saOff = 10;        // SA = addr2 (station->AP, or ad-hoc): the streaming-camera case
        else if (!toDS)   saOff = 16;        // SA = addr3 (AP->station relay of the camera's frames)
        else              saOff = 24;        // SA = addr4 (WDS 4-address)
    } else {
        // Mgmt frame (bonus): match the transmitter addr2 - a camera acting as its own AP
        // (beacon/probe-resp BSSID) or probing (probe-req prober) gives itself away here.
        saOff = 10;
    }
    if (saOff + 6 > len) return false;

    const NetcamOui* e = netcamEntry(frame + saOff);
    if (!e) return false;
    const char* vendor = e->vendor;

    acabInit(out, ACAB_NETCAM, SRC_WIFI, frame + saOff, (int16_t)rssi);
    out->method     = M_OUI;
    out->confidence = e->validated ? NETCAM_OUI_CONFIDENCE_VALIDATED : NETCAM_OUI_CONFIDENCE;
    // HONEST label: names the vendor + that it is on the network. NOT "hidden camera".
    snprintf(out->detail, sizeof(out->detail), "%s on wifi", vendor);
    return true;
}
