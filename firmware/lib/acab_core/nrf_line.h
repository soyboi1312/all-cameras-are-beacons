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
 * Two checks. The LEXICAL one above (every field in the nRF's own print format). Then a STRUCTURAL
 * one: a BLE advert payload is a chain of AD structures, each a length byte then that many bytes,
 * and the chain must tile the payload exactly (zero padding is allowed after a 0x00 length byte,
 * the way a 31-byte legacy advert pads). A fused line whose cut lands inside hex on both sides
 * with an even nibble count passes the lexical check, but it almost never tiles: the splice lands
 * mid-structure and the next length byte points past the end.
 *
 * ponytail: still no CRC. A splice that happens to land on an AD boundary with a sane length byte
 * still passes both checks. A per-line CRC from the nRF closes that, at the cost of a coordinated
 * nRF release; add it if the [diag] rej= counter shows fusing is common. The other ceiling: a
 * device whose own on-air advert does not tile (a non-spec stack) is dropped here, while the
 * single-radio NimBLE path still hands it to the classifiers. Real stacks build spec chains.
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

// True when the AD structures in payload[0..n) tile it exactly. A 0x00 length byte ends the chain;
// only zero bytes may follow it. An empty payload tiles trivially.
static inline bool nrfLineAdTiles(const uint8_t* payload, size_t n) {
    size_t i = 0;
    while (i < n) {
        const size_t adLen = payload[i];
        if (adLen == 0) {
            for (; i < n; i++) if (payload[i] != 0) return false;
            return true;
        }
        i += 1 + adLen;
    }
    return i == n;
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
    if (!nrfLineAdTiles(payload, n)) return false;  // structural check, see the header comment
    *rssi = v;
    *plen = n;
    return true;
}

#endif
