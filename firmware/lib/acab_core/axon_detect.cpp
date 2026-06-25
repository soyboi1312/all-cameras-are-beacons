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
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
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
void axonSetEnabled(bool enabled) { gEnabled = enabled; }
bool axonIsEnabled() { return gEnabled; }

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

// Case-insensitive search for an ASCII needle in a raw byte buffer, checking the
// buffer both forward and reversed. BLE carries 128-bit UUIDs little-endian, so an
// ASCII-encoded UUID (like Axon's "...BWCDEVICE") only reads right when reversed.
static bool bytesContainAscii(const uint8_t* buf, uint8_t len, const char* needle) {
    if (!buf || !needle || !*needle) return false;
    size_t nl = strlen(needle);
    if (len < nl) return false;
    for (uint8_t i = 0; i + nl <= len; i++) {           // forward
        size_t k = 0;
        while (k < nl && tolower(buf[i+k]) == tolower((unsigned char)needle[k])) k++;
        if (k == nl) return true;
    }
    for (uint8_t i = 0; i + nl <= len; i++) {           // reversed
        size_t k = 0;
        while (k < nl && tolower(buf[len-1-(i+k)]) == tolower((unsigned char)needle[k])) k++;
        if (k == nl) return true;
    }
    return false;
}

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
            uint8_t n = dataLen < sizeof(f->name) - 1 ? dataLen : sizeof(f->name) - 1;
            memcpy(f->name, data, n); f->name[n] = 0; f->haveName = true;
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
        if (!bytesContainAscii(f.svc, f.svcLen, gSig.payload)) ok = false;
    }

    if (!any || !ok) return false;

    acabInit(out, ACAB_AXON_BODYCAM, SRC_BLE, mac, (int16_t)rssi);
    out->method = gSig.useMfgId ? M_MFG_ID : (gSig.useOui ? M_OUI : M_NAME);
    if (f.haveName) strncpy(out->name, f.name, sizeof(out->name) - 1);

    // If the advert carries the "BWCDEVICE" service-data tag, confirm it's a body
    // cam (vs dock / TASER / fleet) and give it higher confidence.
    if (bytesContainAscii(f.svc, f.svcLen, AXON_BWC_PAYLOAD)) {
        out->confidence = gSig.baseConfidence < 90 ? 90 : gSig.baseConfidence;
        snprintf(out->detail, sizeof(out->detail), "BWC DEVICE");
    } else {
        out->confidence = gSig.baseConfidence;
        snprintf(out->detail, sizeof(out->detail), "Axon OUI");
    }
    return true;
}
