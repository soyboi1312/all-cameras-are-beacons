/*
 * ACAB - BLE item-tracker detector.
 *
 * Spots common consumer location tags by their over-the-air signature:
 *   - Apple Find My (AirTag + Find My-network accessories, so also Find
 *     My-compatible Chipolo / Pebblebee).
 *   - Tile.
 *   - Samsung SmartTag.
 *
 * OFF by default: trackers are everywhere (every bag, car, pair of earbuds), so
 * leaving this on would bury the surveillance hits. The app / mesh turns it on.
 */
#ifndef ACAB_TRACKER_DETECT_H
#define ACAB_TRACKER_DETECT_H

#include "detection.h"
#include <stddef.h>

// Master on/off. Default: OFF (opt-in).
void trackerSetEnabled(bool enabled);
bool trackerIsEnabled();

// Classify a BLE advertisement as a tracker. Returns true + fills `out` only
// when tracker detection is on AND a known tracker signature matches.
bool trackerClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                        int rssi, AcabDetection* out);

#endif // ACAB_TRACKER_DETECT_H
