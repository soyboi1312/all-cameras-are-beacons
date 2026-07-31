/*
 * ACAB - shared ASCII-in-bytes matching.
 *
 * BLE carries 128-bit UUIDs and service data little-endian, so an ASCII-encoded tag
 * (like Axon's "BWCDEVICE", or the "reelyActive"-style UUIDs seen in the wild) often
 * only reads right when the bytes are reversed. This helper searches a raw byte
 * buffer for an ASCII needle case-insensitively, in BOTH byte orders.
 *
 * Shared so every detector can text-match service-data / 128-bit-UUID payloads, not
 * just Axon - a service-data tag is MAC-independent, so it survives the BLE MAC
 * randomization that breaks OUI matching.
 */
#ifndef ACAB_ASCII_MATCH_H
#define ACAB_ASCII_MATCH_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <ctype.h>

static inline bool acabBytesContainAscii(const uint8_t* buf, uint8_t len, const char* needle) {
    if (!buf || !needle || !*needle) return false;
    size_t nl = strlen(needle);
    if (len < nl) return false;
    for (uint8_t i = 0; i + nl <= len; i++) {           // forward
        size_t k = 0;
        while (k < nl && tolower(buf[i + k]) == tolower((unsigned char)needle[k])) k++;
        if (k == nl) return true;
    }
    for (uint8_t i = 0; i + nl <= len; i++) {           // reversed (little-endian UUID / svc-data)
        size_t k = 0;
        while (k < nl && tolower(buf[len - 1 - (i + k)]) == tolower((unsigned char)needle[k])) k++;
        if (k == nl) return true;
    }
    return false;
}

#endif // ACAB_ASCII_MATCH_H
