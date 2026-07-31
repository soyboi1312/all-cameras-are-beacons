/*
 * ACAB - Axon body-worn camera detector (field-validated, on by default).
 *
 * Default signature is the inert STUB (matches nothing). axonUseRegistryCandidate()
 * loads the field-validated OUI 00:25:DF (see axon_signatures.h). When the advert
 * also carries the "BWCDEVICE" service-data tag, classify() confirms it as a body
 * cam (vs other Axon gear) and raises confidence; set usePayload=true to require it.
 *
 * Validating against a real unit:
 *   1. Put a BLE sniffer next to a powered Axon body cam.
 *   2. Note the advert: manufacturer company ID, static manufacturer-data bytes,
 *      the MAC OUI, any advertised name, and service-data tags.
 *   3. Fill the fields here / in axon_signatures.h, then axonSetEnabled(true).
 *   4. Check it fires on the Axon and NOT on nearby phones/wearables.
 */
#include "axon_detect.h"
#include "axon_signatures.h"
#include "acab_scanner.h"    // acabSanitizeAscii: clamp attacker-sourced names on ingest
#include "ascii_match.h"     // shared acabBytesContainAscii (Axon "BWCDEVICE" tag, both byte orders)
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <Preferences.h>     // persist the body-cam toggle across reboots (NVS)
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// Inert placeholder: every match source off, so it matches nothing.
static const AxonSignature AXON_PLACEHOLDER = {
    /* useMfgId      */ false, /* mfgId */ 0x0000,
    /* useMfgPrefix  */ false, /* mfgPrefix */ {0}, /* mfgPrefixLen */ 0,
    /* useOui        */ false, /* oui */ {{0}}, /* ouiCount */ 0,
    /* useName       */ false, /* namePatterns */ {nullptr,nullptr,nullptr,nullptr}, /* nameCount */ 0,
    /* usePayload    */ false, /* payload */ nullptr,
    /* baseConfidence*/ 40,
};

// Axon Enterprise's only IEEE OUI, 00:25:DF (cited in axon_signatures.h).
// FIELD-VALIDATED 2026-06-17: real Axon body cams advertise on this public OUI.
// Re-confirmed repeatedly since, always via the BWCDEVICE service-data tag at conf 90:
// two airports 2026-07-21, three more 2026-07-23 (SAN/DFW/Destin), and two again on the
// 2026-07-23 San Diego capture. This is the single best-evidenced signature in the tree.
// OUI-only is the loose match (could be any Axon product); classify() also checks
// for the "BWCDEVICE" service-data tag, and when it's there, confirms body cam and
// raises confidence. Set usePayload=true here to REQUIRE the tag (strictest match).
static const AxonSignature AXON_REGISTRY_CANDIDATE = {
    /* useMfgId      */ false, /* mfgId */ 0x0000,
    /* useMfgPrefix  */ false, /* mfgPrefix */ {0}, /* mfgPrefixLen */ 0,
    /* useOui        */ true,  /* oui */ {{0x00,0x25,0xdf}}, /* ouiCount */ 1,
    /* useName       */ false, /* namePatterns */ {nullptr,nullptr,nullptr,nullptr}, /* nameCount */ 0,
    /* usePayload    */ false, /* payload */ nullptr,
    /* baseConfidence*/ 75,
};

static AxonSignature gSig = AXON_PLACEHOLDER;
static bool gEnabled = true;    // field-validated 2026-06-17 (00:25:DF + BWCDEVICE)

void axonLoadSignature(const AxonSignature* sig) {
    gSig = sig ? *sig : AXON_PLACEHOLDER;
}
void axonUseRegistryCandidate(void) { gSig = AXON_REGISTRY_CANDIDATE; }
// NVS-backed so an app-set body-cam toggle survives a reboot (mirrors tracker/glasses).
// This is the CATEGORY switch: it covers Axon (OUI + the BWCDEVICE tag) and Utility
// BodyWorn, and the broad Motorola proxy gates on it too. Motorola has its own persisted
// sub-toggle on top (policeSetEnabled), so this no longer overwrites that choice.
void axonSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-axon", false); p.putBool("on", enabled); p.end();
}
bool axonIsEnabled() { return gEnabled; }

// Reload the persisted toggle on boot; if none saved yet, use defaultEnabled.
void axonRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-axon", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// ---- local helpers (same AD parsing as flock_detect, kept separate) ----
static bool ciContains(const char* hay, const char* needle) {
    if (!hay || !needle || !*needle) return false;
    for (const char* p = hay; *p; p++) {
        const char* a = p; const char* b = needle;
        while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
        if (!*b) return true;
    }
    return false;
}

// ASCII-in-bytes matching (Axon's "BWCDEVICE" service-data tag, checked in both byte
// orders) now lives in the shared ascii_match.h -> acabBytesContainAscii().

struct AxAdv {
    char     name[40]; bool haveName;
    uint16_t mfgId;    bool haveMfg;
    const uint8_t* mfgData; uint8_t mfgLen;
    uint8_t  svc[48];  uint8_t svcLen;   // concatenated service-data / 128-bit-UUID bytes
};

static void parseAdv(const uint8_t* adv, size_t len, AxAdv* f) {
    memset(f, 0, sizeof(*f));
    size_t i = 0;
    while (i + 1 < len) {
        uint8_t adLen = adv[i];
        if (adLen == 0 || i + 1 + adLen > len) break;
        uint8_t adType = adv[i + 1];
        const uint8_t* data = &adv[i + 2];
        uint8_t dataLen = adLen - 1;
        if ((adType == 0x08 || adType == 0x09) && !f->haveName) {
            // clamp the attacker-controlled advertised name to printable ASCII on ingest (same
            // invariant as the other ingest paths), not a raw memcpy.
            acabSanitizeAscii(f->name, data, dataLen, sizeof(f->name)); f->haveName = true;
        } else if (adType == 0xFF && dataLen >= 2 && !f->haveMfg) {
            f->mfgId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
            f->mfgData = data; f->mfgLen = dataLen; f->haveMfg = true;
        } else if (adType == 0x06 || adType == 0x07 ||   // 128-bit service-UUID list
                   adType == 0x20 || adType == 0x21 ||   // service data 32/128-bit
                   adType == 0x16) {                      // service data 16-bit
            uint8_t room = (uint8_t)(sizeof(f->svc) - f->svcLen);
            uint8_t n = dataLen < room ? dataLen : room;
            memcpy(f->svc + f->svcLen, data, n);
            f->svcLen += n;
        }
        i += 1 + adLen;
    }
}

// Match the active signature against one BLE advertisement. Returns false if the
// module is off, if no criteria are set, or if any set criterion fails.
bool axonClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                     int rssi, AcabDetection* out) {
    if (!gEnabled && !desertIsEnabled()) return false;

    AxAdv f;
    if (adv && advLen) parseAdv(adv, advLen, &f);
    else memset(&f, 0, sizeof(f));

    // Every criterion that's set has to match. With none set (the placeholder),
    // nothing matches and we bail - by design.
    bool any = false, ok = true;

    if (gSig.useMfgId) {
        any = true;
        if (!(f.haveMfg && f.mfgId == gSig.mfgId)) ok = false;
    }
    if (ok && gSig.useMfgPrefix && gSig.mfgPrefixLen) {
        any = true;
        // manufacturer data starts right after the 2-byte company id
        if (!(f.haveMfg && f.mfgLen >= 2 + gSig.mfgPrefixLen &&
              memcmp(f.mfgData + 2, gSig.mfgPrefix, gSig.mfgPrefixLen) == 0)) ok = false;
    }
    if (ok && gSig.useOui && gSig.ouiCount) {
        any = true;
        bool hit = false;
        for (uint8_t i = 0; i < gSig.ouiCount; i++)
            if (mac[0]==gSig.oui[i][0] && mac[1]==gSig.oui[i][1] && mac[2]==gSig.oui[i][2]) { hit = true; break; }
        if (!hit) ok = false;
    }
    if (ok && gSig.useName && gSig.nameCount) {
        any = true;
        bool hit = false;
        for (uint8_t i = 0; i < gSig.nameCount; i++)
            if (gSig.namePatterns[i] && ciContains(f.name, gSig.namePatterns[i])) { hit = true; break; }
        if (!hit) ok = false;
    }
    if (ok && gSig.usePayload && gSig.payload) {
        any = true;
        if (!acabBytesContainAscii(f.svc, f.svcLen, gSig.payload)) ok = false;
    }
    bool sigHit = any && ok;   // the configured OUI / mfg / name signature matched

    // Durable, MAC-INDEPENDENT signal: the "BWCDEVICE" service-data tag. Axon is
    // moving to rotating BLE MACs, which breaks the OUI match - but the tag rides in
    // the advert payload, so make it a STANDALONE match (not just a confidence bump on
    // top of the OUI). A random-MAC Axon body cam still gets caught by its own tag.
    bool tagHit = acabBytesContainAscii(f.svc, f.svcLen, AXON_BWC_PAYLOAD);

    // Utility Inc. "BodyWorn" police body cam (a different brand, same body-cam category,
    // so it rides this same detector + toggle). The advertised name is the strong, MAC-
    // independent signal; the public OUI is the weaker fallback. Signatures (name + the
    // OUI table) live in axon_signatures.h next to their citations.
    bool utilName = ciContains(f.name, UTIL_BWC_NAME);
    bool utilOui  = false;
    if (!(mac[0] & 0x02)) {   // skip locally-administered / random MACs (no real OUI)
        for (size_t i = 0; i < UTIL_BWC_OUI_COUNT && !utilOui; i++)
            utilOui = (mac[0] == UTIL_BWC_OUI[i][0] && mac[1] == UTIL_BWC_OUI[i][1] &&
                       mac[2] == UTIL_BWC_OUI[i][2]);
    }
    bool utilHit  = utilName || utilOui;

    if (!sigHit && !tagHit && !utilHit) return false;

    acabInit(out, ACAB_AXON_BODYCAM, SRC_BLE, mac, (int16_t)rssi);
    if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);

    if (tagHit) {
        // Axon, confirmed by its own broadcast tag - highest confidence, and it survives
        // MAC randomization. Reported as service-data, not OUI.
        out->method = M_SERVICE_DATA;
        out->confidence = gSig.baseConfidence < 90 ? 90 : gSig.baseConfidence;
        snprintf(out->detail, sizeof(out->detail), "BWC DEVICE");
    } else if (sigHit) {
        // Axon loose match: OUI / mfg / name only (could be any Axon product). Weaker; the
        // OUI table only matches public MACs, so acabApplyDurability leaves it as-is.
        out->method = gSig.useMfgId ? M_MFG_ID : (gSig.useOui ? M_OUI : M_NAME);
        out->confidence = gSig.baseConfidence;
        snprintf(out->detail, sizeof(out->detail), "Axon OUI");
    } else {
        // Utility BodyWorn (the only remaining reason we didn't bail). The "BodyWorn Remote"
        // name is specific + MAC-independent, so it's a strong hit; OUI-only is the weak fallback
        // (Utility makes other gear too). Third-party field-observed, not own-captured yet.
        out->method = utilName ? M_NAME : M_OUI;
        out->confidence = utilName ? 85 : 70;
        snprintf(out->detail, sizeof(out->detail), "Utility BodyWorn");
    }
    return true;
}
