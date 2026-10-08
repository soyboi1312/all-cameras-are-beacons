/*
 * ACAB - parse one nRF advert line, "A <mac12hex> <rssi> <payloadhex>" (pure, host-tested).
 *
 * The nRF prints every field itself (%02X pairs, a %d RSSI from an int8) and ends the line there,
 * so a line that deviates in ANY way did not arrive intact. The realistic cause is byte loss, not
 * bit flips: when loop() stalls (a 64 KB flash block erase, say) and the 8 KB UART RX buffer
 * overflows, the stream loses a run of bytes and the head of one line fuses with the tail of a
 * later one. The old parser kept whatever hex it could read, which could pin another device's
 * payload on an intact MAC and log a sighting that never happened. So reject, never repair.
 *
 * ponytail: lexical checks only, no CRC. A fused line whose cut lands inside hex on both sides
 * with an even nibble count still passes. A per-line CRC from the nRF closes that, at the cost of
 * a coordinated nRF release; add it if the [diag] rej= counter shows fusing is common.
 */
#ifndef ACAB_NRF_LINE_H
#define ACAB_NRF_LINE_H

#include <stddef.h>
#include <stdint.h>

static inline int nrfLineHexNib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// Reads one hex byte at p. Never looks past a NUL: p[1] is read only when p[0] is a hex digit.
static inline bool nrfLineHexByte(const char* p, uint8_t* out) {
    const int hi = nrfLineHexNib(p[0]);
    const int lo = hi < 0 ? -1 : nrfLineHexNib(p[1]);
    if (lo < 0) return false;
    *out = (uint8_t)((hi << 4) | lo);
    return true;
}

// True only for a line the nRF could have printed. On success fills mac, rssi and
// payload[0..*plen); a payload longer than cap is a reject, not a truncation.
static inline bool nrfParseAdvLine(const char* s, uint8_t mac[6], int* rssi,
                                   uint8_t* payload, size_t cap, size_t* plen) {
    if (s[0] != 'A' || s[1] != ' ') return false;
    const char* p = s + 2;
    for (int i = 0; i < 6; i++, p += 2)
        if (!nrfLineHexByte(p, &mac[i])) return false;
    if (*p++ != ' ') return false;

    const bool neg = (*p == '-');
    if (neg) p++;
    int v = 0, digits = 0;
    while (*p >= '0' && *p <= '9') {
        if (++digits > 3) return false;
        v = v * 10 + (*p++ - '0');
    }
    if (digits == 0 || *p++ != ' ') return false;
    v = neg ? -v : v;
    if (v < -128 || v > 127) return false;          // the nRF prints an int8

    size_t n = 0;
    for (; *p; p += 2) {                            // whole hex bytes to the end, nothing else
        if (n >= cap || !nrfLineHexByte(p, &payload[n])) return false;
        n++;
    }
    *rssi = v;
    *plen = n;
    return true;
}

#endif
