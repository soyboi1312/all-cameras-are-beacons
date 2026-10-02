/*
 * ACAB - Axon body-worn camera detector  ***OUI FIELD-VALIDATED 2026-06-17***
 *
 * 2026-06-17: real Axon body cams were caught in the field advertising on the
 * public OUI 00:25:DF (not a random address), with a payload that self-identifies
 * as "...BWC DEVICE". So OUI detection is now ENABLED in the oui-spy build
 * (axonRestoreEnabled(true), in main.cpp). The older "stays
 * disabled" notes below are kept for history. One caveat: the OUI alone can't tell
 * a body cam from another Axon product (TASER/dock/fleet cam) - add a "BWC DEVICE"
 * payload check on top if false positives ever crop up.
 *
 * The idea: body cams are BLE devices, so passive detection works in principle, as
 * long as they advertise a stable signature and not a rotating random address.
 *
 * What we know for sure: Axon Enterprise, Inc. owns exactly one IEEE MAC block,
 * OUI 00:25:DF (MA-L, registered 2010 as TASER International, updated 2025-01-30).
 * It is AXON_OUI_REGISTERED in axon_signatures.h. Heads up: the unrelated
 * "Axon Networks Inc." OUIs are a different company - don't use them.
 *
 * Settled in the field: body cams DO advertise on the public 00:25:DF MAC (not a
 * resolvable random address), so passive OUI detection works. The module is now:
 *   - ENABLED by default - field-validated, so it earns its spot in the scan.
 *   - TWO-TIER - OUI-only is the loose match (any Axon product, conf 75); the
 *     "BWCDEVICE" service-data tag confirms a body cam over other Axon gear
 *     (conf 90) and matches on its own, with or without the OUI.
 */
#ifndef ACAB_AXON_DETECT_H
#define ACAB_AXON_DETECT_H

#include "detection.h"
#include <stddef.h>

// Master on/off. Default ON (field-validated 2026-06-17). The app / mesh config
// can flip it off.
void axonSetEnabled(bool enabled);
bool axonIsEnabled();
// Reload the persisted body-cam toggle on boot (NVS); defaultEnabled if never set.
void axonRestoreEnabled(bool defaultEnabled);

// Classify a BLE advertisement. Returns true + fills `out` only when Axon
// detection is on AND an Axon OUI, the BWCDEVICE tag or a Utility BodyWorn signal matches.
bool axonClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                     int rssi, AcabDetection* out);

// Classify a WiFi MANAGEMENT frame against the same OUI table.
//
// WHY THIS EXISTS (2026-07-31): the Axon OUI was matched on BLE ONLY, so any Axon device
// that speaks WiFi instead of BLE fell through to a generic Nearby Device. That is exactly
// the wrong gap: in-car video (Axon Fleet) is a WiFi device, and an in-car system is what a
// user driving past a vehicle would most expect to see.
//
// Deliberately WEAKER than the BLE path and NOT field-validated - no capture in this repo
// has ever matched this OUI over WiFi. Registry-sourced only, same honesty bar the netcam
// table sets for its own unconfirmed blocks. Payload / name / service-tag matching cannot
// apply here (a mgmt frame carries no BLE advert), so this is strictly an OUI match.
bool axonClassifyWiFi(const uint8_t* frame, size_t len, int rssi, AcabDetection* out);

#endif // ACAB_AXON_DETECT_H
