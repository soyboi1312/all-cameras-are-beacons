#pragma once
// NOT ECDSA. The "key" accepts exactly one (digest, signature) pair, the one the test registers
// as the offline signer's output over its sample image. Anything else fails, which is the only
// property otaDoFinish's fail-closed branch needs: a wrong signature, or the right signature over
// different bytes, must never reach Update.end. Production links ESP-IDF's real mbedtls.
//
// Same caveat as md.h: nothing here may be read as evidence about real ECDSA-P256.
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <vector>
#include "md.h"

struct mbedtls_pk_context { bool parsed; };

inline std::vector<uint8_t> acabHostPkGoodSig;        // the one signature the key accepts
inline uint8_t  acabHostPkGoodDigest[32] = {};        // ... and only over this digest
inline uint32_t acabHostPkVerifyCalls = 0;

inline void mbedtls_pk_init(mbedtls_pk_context* c) { if (c) c->parsed = false; }
inline void mbedtls_pk_free(mbedtls_pk_context* c) { if (c) c->parsed = false; }

inline int mbedtls_pk_parse_public_key(mbedtls_pk_context* c, const unsigned char* der, size_t len) {
    if (!c || !der || len == 0) return -1;
    c->parsed = true;
    return 0;
}

inline int mbedtls_pk_verify(mbedtls_pk_context* c, int mdType, const unsigned char* hash,
                             size_t hashLen, const unsigned char* sig, size_t sigLen) {
    acabHostPkVerifyCalls++;
    if (!c || !c->parsed || mdType != MBEDTLS_MD_SHA256 || !hash || hashLen != 32 || !sig) return -1;
    if (sigLen != acabHostPkGoodSig.size() || sigLen == 0 ||
        memcmp(sig, acabHostPkGoodSig.data(), sigLen) != 0) return -1;
    return memcmp(hash, acabHostPkGoodDigest, 32) == 0 ? 0 : -1;
}
