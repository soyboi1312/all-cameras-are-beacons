/*
 * ACAB Mesh-Detect - Meshtastic uplink implementation.
 *
 * The PROTO encoder hand-builds the three nested messages (ToRadio > MeshPacket >
 * Data). Field numbers are from meshtastic/mesh.proto:
 *   ToRadio.packet   = 1 (len-delimited)
 *   MeshPacket.to    = 2 (fixed32)   -> 0xFFFFFFFF broadcast
 *   MeshPacket.channel = 3 (uint32)  -> the chosen channel index
 *   MeshPacket.decoded = 4 (Data, len-delimited)
 *   Data.portnum     = 1 (PortNum)   -> TEXT_MESSAGE_APP = 1
 *   Data.payload     = 2 (bytes)     -> the message text
 * Stream frame: 0x94 0xC3 <len_hi> <len_lo> <ToRadio bytes>.
 */
#include "mesh_link.h"
#include <Arduino.h>

static MeshLinkConfig gCfg;
static HardwareSerial gMeshSerial(1);   // UART1 to the Heltec node
static uint32_t       gLastSend = 0;

#define PORTNUM_TEXT_MESSAGE_APP 1

MeshLinkConfig meshLinkDefaults() {
    MeshLinkConfig c;
    c.transport     = MESH_TEXT;   // stock Mesh-Detect Heltec uses Serial Module TextMessage,
                                   // which broadcasts on the public/primary channel. Use
                                   // MESH_PROTO (+ channelIndex) for a private channel.
    c.channelIndex  = 0;           // only used by MESH_PROTO
    c.uartBaud      = 115200;
    c.uartRxPin     = 6;    // GPIO6 <- Heltec Serial TXD (GPIO20). Pins match the stock
    c.uartTxPin     = 5;    // GPIO5 -> Heltec Serial RXD (GPIO19). Mesh-Detect wiring.
    c.includeGPS    = true;
    c.minIntervalMs = 3000; // go easy on the LoRa duty cycle
    return c;
}

void meshLinkSetChannel(uint8_t idx) { gCfg.channelIndex = idx; }
uint8_t meshLinkChannel() { return gCfg.channelIndex; }

// Store config and open the UART to the Heltec node.
void meshLinkBegin(const MeshLinkConfig& cfg) {
    gCfg = cfg;
    gMeshSerial.begin(cfg.uartBaud, SERIAL_8N1, cfg.uartRxPin, cfg.uartTxPin);
    Serial.printf("[ACAB-mesh] uplink %s, channel %u, %lu baud (RX=%d TX=%d)\n",
                  cfg.transport == MESH_PROTO ? "PROTO" : "TEXT",
                  cfg.channelIndex, (unsigned long)cfg.uartBaud,
                  cfg.uartRxPin, cfg.uartTxPin);
}

// ---- protobuf helpers ----
// Write a protobuf varint to buf; returns how many bytes it took.
static size_t writeVarint(uint8_t* buf, uint32_t v) {
    size_t n = 0;
    do {
        uint8_t b = v & 0x7F;
        v >>= 7;
        if (v) b |= 0x80;
        buf[n++] = b;
    } while (v);
    return n;
}

// Build a ToRadio text packet for `channel`. Returns the frame length, 0 if it overflows.
static size_t buildProtoFrame(uint8_t* out, size_t outCap, uint8_t channel, const char* text) {
    // --- Data ---
    uint8_t data[256]; size_t dp = 0;
    data[dp++] = 0x08; dp += writeVarint(&data[dp], PORTNUM_TEXT_MESSAGE_APP); // portnum=1
    size_t tlen = strlen(text);
    if (tlen > 230) tlen = 230;
    data[dp++] = 0x12;                                   // payload=2, len-delim
    dp += writeVarint(&data[dp], (uint32_t)tlen);
    memcpy(&data[dp], text, tlen); dp += tlen;

    // --- MeshPacket ---
    uint8_t mp[300]; size_t mpp = 0;
    mp[mpp++] = 0x15;                                    // to=2, fixed32
    mp[mpp++] = 0xFF; mp[mpp++] = 0xFF; mp[mpp++] = 0xFF; mp[mpp++] = 0xFF; // broadcast
    mp[mpp++] = 0x18; mpp += writeVarint(&mp[mpp], channel);               // channel=3
    mp[mpp++] = 0x22; mpp += writeVarint(&mp[mpp], (uint32_t)dp);          // decoded=4
    memcpy(&mp[mpp], data, dp); mpp += dp;

    // --- ToRadio ---
    uint8_t tr[320]; size_t trp = 0;
    tr[trp++] = 0x0A; trp += writeVarint(&tr[trp], (uint32_t)mpp);         // packet=1
    memcpy(&tr[trp], mp, mpp); trp += mpp;

    // --- stream frame ---
    size_t need = 4 + trp;
    if (need > outCap || trp > 0xFFFF) return 0;
    out[0] = 0x94; out[1] = 0xC3;
    out[2] = (trp >> 8) & 0xFF; out[3] = trp & 0xFF;
    memcpy(&out[4], tr, trp);
    return need;
}

// Build the human-readable line. Always starts with "<Label> detected".
static void buildText(const AcabDetection& d, char* buf, size_t cap) {
    char mac[18]; acabFormatMac(d.mac, mac);
    int n = snprintf(buf, cap, "%s detected | %s | rssi %d | %s",
                     acabTypeLabel(d.type), acabSourceLabel(d.src), d.rssi, mac);
    if (n < 0 || (size_t)n >= cap) return;

    if (d.type == ACAB_DRONE) {
        if (d.id[0])
            n += snprintf(buf + n, cap - n, " | RID %s", d.id);
        if ((d.lat || d.lon) && (size_t)n < cap)
            n += snprintf(buf + n, cap - n, " | %.5f,%.5f", d.lat, d.lon);
        if (d.altitude && (size_t)n < cap)
            n += snprintf(buf + n, cap - n, " | alt %ldm", (long)d.altitude);
    } else if (gCfg.includeGPS && (d.lat || d.lon) && (size_t)n < cap) {
        n += snprintf(buf + n, cap - n, " | %.5f,%.5f", d.lat, d.lon);
    }
}

// Send any text line over the mesh, using the configured transport + channel. No
// dedup or rate-limit - used by detections (via meshLinkSend) and the boot
// self-test ping.
void meshLinkSendText(const char* text) {
    Serial.printf("[ACAB-mesh] -> %s\n", text);
    if (gCfg.transport == MESH_TEXT) {
        gMeshSerial.println(text);               // Serial Module TEXTMSG mode
    } else {
        uint8_t frame[340];
        size_t len = buildProtoFrame(frame, sizeof(frame), gCfg.channelIndex, text);
        if (len) gMeshSerial.write(frame, len);  // Serial Module PROTO mode
    }
    gLastSend = millis();
}

// Rate-limited scanner sink: skip repeats and respect the LoRa duty-cycle floor.
void meshLinkSend(const AcabDetection& d, bool isNew) {
    if (!isNew) return;                          // one mesh ping per dedup window
    if (millis() - gLastSend < gCfg.minIntervalMs) return;  // protect the LoRa duty cycle
    char text[256];
    buildText(d, text, sizeof(text));
    meshLinkSendText(text);
}
