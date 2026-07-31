import Foundation
import CryptoKit

/// App-side signature check for the nRF co-processor DFU package.
///
/// The S3 image is verified ON the board (its OTA gate holds the public key). The nRF is
/// different: its stock Adafruit/Seeed bootloader speaks legacy DFU, which is CRC-only and
/// cannot verify our ECDSA signature. So for the nRF the APP is the only gate, and it MUST
/// verify before pushing the package to a bootloader that will flash whatever it's handed.
///
/// The manifest's nrf.sig is a DER-encoded ECDSA P-256 signature over SHA-256 of the whole
/// .zip, produced by `openssl dgst -sha256 -sign`, so `isValidSignature(_:for:)` (which hashes
/// the data with SHA-256 internally) is the exact inverse. Verified against the real staged
/// artifact with `openssl dgst -sha256 -verify` before shipping this.
enum NrfDfuSignature {
    /// The same public key baked into the board firmware for S3 OTA (SubjectPublicKeyInfo /
    /// X.509, base64). Pairs with tools/ota_signing/beacon_ota_key.pem, which is gitignored.
    private static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpgFKoOmugxeYHXEirno5rN7DO9uJ
    ESOP7a/OfJD9nAbBmpNFq1tFgVewzRm90F1yIkn2HvlkCSto75t5vTmybw==
    -----END PUBLIC KEY-----
    """

    /// True when `sigHexDER` is a valid signature over `zip` from the beacon signing key.
    /// Any malformed input (bad hex, non-DER signature, wrong key) returns false, never throws:
    /// the caller treats false as "refuse to flash".
    static func isValid(zip: Data, sigHexDER: String) -> Bool {
        guard let sigData = Data(hexString: sigHexDER), !sigData.isEmpty,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData),
              let key = try? P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
        else { return false }
        return key.isValidSignature(signature, for: zip)
    }
}

extension Data {
    /// Parse a lowercase/uppercase hex string ("3046...") into bytes, or nil on any bad char /
    /// odd length. Local to this file so the crypto gate owns its own parsing.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = out
    }
}
