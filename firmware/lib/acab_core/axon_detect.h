/*
 * ACAB - Axon body-worn camera detector  ***OUI FIELD-VALIDATED 2026-06-17***
 *
 * 2026-06-17: real Axon body cams were caught in the field advertising on the
 * public OUI 00:25:DF (not a random address), with a payload that self-identifies
 * as "...BWC DEVICE". So OUI detection is now ENABLED in the oui-spy build
 * (axonUseRegistryCandidate + axonSetEnabled, in main.cpp). The older "stays
 * disabled" notes below are kept for history. One caveat remains: the OUI alone
 * can't tell a body cam from another Axon product (TASER/dock/fleet cam) - AND a
 * "BWC DEVICE" payload check on top if false positives ever crop up.
 *
 * The idea: body cams are BLE devices, so passive detection works in principle as
 * long as they advertise a stable signature instead of a rotating random address.
 *
 * What we know for sure: Axon Enterprise, Inc. owns exactly one IEEE MAC block,
 * OUI 00:25:DF (MA-L, registered 2010 as TASER International, updated 2025-01-30).
 * That's loaded below via axonUseRegistryCandidate(). Heads up: the unrelated
 * "Axon Networks Inc." OUIs are a different company - don't use them.
 *
 * Settled in the field: body cams DO advertise on the public 00:25:DF MAC (not a
 * resolvable random address), so passive OUI detection works. The module is now:
 *   - ENABLED by default - field-validated, so it earns its place in the scan.
 *   - DATA-DRIVEN - load a captured signature with axonLoadSignature(), or use the
 *     registry OUI via axonUseRegistryCandidate().
 *   - TIGHTENABLE - OUI-only is the loose match (any Axon product); set
 *     usePayload=true to require the "BWCDEVICE" service-data tag and confirm a
 *     body cam over other Axon gear.
 */
#ifndef ACAB_AXON_DETECT_H
#define ACAB_AXON_DETECT_H

#include "detection.h"
#include <stddef.h>

// A swappable Axon BLE signature, filled from a real-device capture. Match logic
// ANDs together whichever fields are populated.
struct AxonSignature {
    bool     useMfgId;
    uint16_t mfgId;            // BLE manufacturer company ID, once identified

    bool     useMfgPrefix;     // match leading bytes of manufacturer data
    uint8_t  mfgPrefix[8];
    uint8_t  mfgPrefixLen;

    bool     useOui;
    uint8_t  oui[4][3];        // up to 4 candidate Axon OUIs
    uint8_t  ouiCount;

    bool     useName;
    // name substrings, matched case-insensitively (e.g. "Axon", "AB3", "AB4")
    const char* namePatterns[4];
    uint8_t  nameCount;

    bool        usePayload;    // require an ASCII tag in service data (both byte orders)
    const char* payload;       // e.g. "BWCDEVICE"; see axon_signatures.h

    uint8_t  baseConfidence;   // kept low until field-verified
};

// Swap in a new signature (e.g. from a captured Body 3/4). nullptr resets to the
// built-in placeholder.
void axonLoadSignature(const AxonSignature* sig);

// Load the registry candidate (Axon Enterprise OUI 00:25:DF, OUI-only). Doesn't
// enable the module - call axonSetEnabled(true) too if you want to run it.
void axonUseRegistryCandidate(void);

// Master on/off. Default ON (field-validated 2026-06-17). The app / mesh config
// can flip it off.
void axonSetEnabled(bool enabled);
bool axonIsEnabled();

// Classify a BLE advertisement. Returns true + fills `out` only when Axon
// detection is on AND the active signature matches.
bool axonClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                     int rssi, AcabDetection* out);

#endif // ACAB_AXON_DETECT_H
