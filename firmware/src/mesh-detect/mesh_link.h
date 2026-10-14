/*
 * ACAB Mesh-Detect - Meshtastic uplink.
 *
 * The XIAO ESP32-S3 detects; a wired Heltec V3 running Meshtastic transmits.
 * Two transports:
 *
 *   MESH_TEXT  - plaintext line over UART. Works with the Heltec Serial Module in
 *                TEXTMSG mode, but Meshtastic then only broadcasts on the PRIMARY
 *                channel (the "public channel" limitation).
 *
 *   MESH_PROTO - a ToRadio protobuf frame with MeshPacket.channel set, so
 *                detections go out on a channel index you pick. Needs the Heltec
 *                Serial Module in PROTO mode with that channel set up. Use this to
 *                transmit on a specific channel.
 *
 * Every message names the unit: "ALPR camera detected", "Flock Raven detected",
 * "Body camera detected", "Drone detected" (labels come from acabTypeLabel in
 * lib/acab_core/detection.h).
 *
 * Location: the owner's phone fix rides on a non-drone line only over MESH_PROTO on a
 * secondary channel index. On the public primary (channel 0 or MESH_TEXT) it is never
 * attached, and the boot ping is not sent. A drone line carries the aircraft's own Remote ID
 * position on every channel (the aircraft broadcast it). Rule: buildText in mesh_link.cpp.
 */
#ifndef ACAB_MESH_LINK_H
#define ACAB_MESH_LINK_H

#include "detection.h"

enum MeshTransport { MESH_TEXT = 0, MESH_PROTO = 1 };

struct MeshLinkConfig {
    MeshTransport transport;
    uint8_t       channelIndex;    // Meshtastic channel index (0 = primary)
    uint32_t      uartBaud;        // match the Heltec Serial Module baud
    int           uartRxPin;       // XIAO RX  <- Heltec TX
    int           uartTxPin;       // XIAO TX  -> Heltec RX
    bool          includeGPS;      // append the phone's lat,lon when we have it; private channel only
    uint32_t      minIntervalMs;   // min gap between mesh sends (LoRa duty cycle)
};

MeshLinkConfig meshLinkDefaults();
void meshLinkBegin(const MeshLinkConfig& cfg);

uint8_t meshLinkChannel();

// Scanner sink helper: format + send a labelled detection.
void meshLinkSend(const AcabDetection& d, bool isNew);

// Send a raw text line over the mesh (configured transport + channel). Used by
// detections and by the boot self-test ping.
void meshLinkSendText(const char* text);

// Boot self-test ping ("mesh-detect ACAB online"). Sends only on a private channel; a no-op
// on the public primary. Call once from loop() after the Heltec has had time to boot.
void meshLinkBootPing();

#endif // ACAB_MESH_LINK_H
