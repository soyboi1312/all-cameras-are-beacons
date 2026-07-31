/*
 * ACAB - OTA image-signing PUBLIC key (ECDSA P-256, SubjectPublicKeyInfo DER).
 *
 * The board verifies a detached ECDSA-P256/SHA-256 signature over the whole OTA image
 * against THIS key before accepting an update (see ota_update.cpp otaFinish). The matching
 * PRIVATE key lives OFFLINE only (firmware/tools/ota_signing/beacon_ota_key.pem, gitignored)
 * and signs each build in the flasher build scripts. Because authenticity is rooted in this
 * baked-in key, a compromised download host / manifest / phone app still cannot get an
 * unsigned image to execute: the image must be signed by the holder of the private key.
 *
 * To rotate: generate a new P-256 key, regenerate this header (openssl ec -pubout -outform
 * DER | xxd), ship it in a signed OTA (or web-flash), then sign future builds with the new key.
 *
 * This is a DEV key generated during development. Replace it with your own offline production
 * key before shipping OTA-capable hardware, and back that key up (losing it means re-keying
 * via a web-flash, never a brick).
 */
#ifndef ACAB_OTA_PUBKEY_H
#define ACAB_OTA_PUBKEY_H

#include <stddef.h>
#include <stdint.h>

// SubjectPublicKeyInfo DER for the ECDSA P-256 (prime256v1) OTA signing public key.
static const uint8_t ACAB_OTA_PUBKEY_DER[] = {
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00, 0x04, 0xa6, 0x01, 0x4a, 0xa0, 0xe9, 0xae, 0x83, 0x17, 0x98,
    0x1d, 0x71, 0x22, 0xae, 0x7a, 0x39, 0xac, 0xde, 0xc3, 0x3b, 0xdb, 0x89,
    0x11, 0x23, 0x8f, 0xed, 0xaf, 0xce, 0x7c, 0x90, 0xfd, 0x9c, 0x06, 0xc1,
    0x9a, 0x93, 0x45, 0xab, 0x5b, 0x45, 0x81, 0x57, 0xb0, 0xcd, 0x19, 0xbd,
    0xd0, 0x5d, 0x72, 0x22, 0x49, 0xf6, 0x1e, 0xf9, 0x64, 0x09, 0x2b, 0x68,
    0xef, 0x9b, 0x79, 0xbd, 0x39, 0xb2, 0x6f
};
static const size_t ACAB_OTA_PUBKEY_DER_LEN = sizeof(ACAB_OTA_PUBKEY_DER);

#endif // ACAB_OTA_PUBKEY_H
