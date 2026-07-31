package tech.acab.app.ble

import android.util.Base64
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/**
 * App-side signature check for the nRF co-processor DFU package.
 *
 * The S3 image is verified ON the board (its OTA gate holds the public key). The nRF is
 * different: its stock Adafruit/Seeed bootloader speaks legacy DFU, which is CRC-only and cannot
 * verify our ECDSA signature. So for the nRF the APP is the only gate, and it MUST verify before
 * pushing the package to a bootloader that will flash whatever it's handed.
 *
 * The manifest's nrf.sig is a DER-encoded ECDSA P-256 signature over SHA-256 of the whole .zip,
 * produced by `openssl dgst -sha256 -sign`, so "SHA256withECDSA" over the zip bytes is the exact
 * inverse. Verified against the real staged artifact with `openssl dgst -sha256 -verify` first.
 */
object NrfDfuSignature {
    // Same public key baked into the board firmware for S3 OTA (SubjectPublicKeyInfo / X.509,
    // base64). Pairs with tools/ota_signing/beacon_ota_key.pem (gitignored).
    private const val PUBLIC_KEY_B64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpgFKoOmugxeYHXEirno5rN7DO9uJ" +
        "ESOP7a/OfJD9nAbBmpNFq1tFgVewzRm90F1yIkn2HvlkCSto75t5vTmybw=="

    /** True when [sigHexDer] is a valid signature over [zip] from the beacon signing key. Any
     *  malformed input returns false, never throws: the caller treats false as "refuse to flash". */
    fun isValid(zip: ByteArray, sigHexDer: String): Boolean = runCatching {
        val der = hexToBytes(sigHexDer) ?: return false
        val key = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(Base64.decode(PUBLIC_KEY_B64, Base64.DEFAULT)))
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(key)
            update(zip)
            verify(der)
        }
    }.getOrDefault(false)

    private fun hexToBytes(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var i = 0
        while (i < hex.length) {
            val hi = Character.digit(hex[i], 16)
            val lo = Character.digit(hex[i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i / 2] = ((hi shl 4) or lo).toByte()
            i += 2
        }
        return out
    }
}
