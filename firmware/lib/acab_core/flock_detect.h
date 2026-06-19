/*
 * ACAB - Flock Safety detector (camera + Raven).
 *
 * One entry point per radio. Both are pure classifiers: hand them a frame, they
 * fill an AcabDetection and return true on a hit. No globals, no NimBLE types in
 * the signature - so the logic stays host-testable and both scanners can share it.
 *
 * Signatures live in flock_signatures.h, sourced from public registries and
 * research (see docs/signatures.md), not from upstream code.
 */
#ifndef ACAB_FLOCK_DETECT_H
#define ACAB_FLOCK_DETECT_H

#include "detection.h"
#include <stddef.h>

// Classify a BLE advertisement. `adv` is the raw advertising payload (AD
// structures, may be null). Returns true + fills `out` if it looks like a Flock
// camera or Raven.
bool flockClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                      int rssi, AcabDetection* out);

// Classify an 802.11 management frame from promiscuous capture (`frame` starts
// at the frame-control field). Matches Flock OUIs on the transmitter/BSSID, plus
// the "empty-SSID probe from a Flock OUI" strong-signal heuristic.
bool flockClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                       AcabDetection* out);

#endif // ACAB_FLOCK_DETECT_H
