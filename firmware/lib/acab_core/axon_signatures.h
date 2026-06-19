/*
 * ACAB - Axon body-worn camera signature (clean-room).
 * Both values are public / own-capture, not ported. See docs/signatures.md.
 */
#ifndef ACAB_AXON_SIGNATURES_H
#define ACAB_AXON_SIGNATURES_H

// MAC OUI: Axon Enterprise, Inc. (formerly TASER International) - their sole IEEE
// block (MA-L, 2010). Used literally as {0x00,0x25,0xdf} in axon_detect.cpp.
//   src: IEEE OUI registry -> https://maclookup.app/macaddress/0025DF

// ASCII tag a real Axon body cam self-identifies with in its BLE service data. In
// the field capture it rode inside a 128-bit service-UUID (AD 0x21) which, being
// little-endian, only reads as "AXJANUSBWCDEVICE" when the bytes are reversed - so
// the matcher searches both byte orders (see bytesContainAscii in axon_detect.cpp).
// AND it with the OUI to separate a body cam from other Axon gear (dock / TASER).
//   src: own field capture, 2026-06.
#define AXON_BWC_PAYLOAD  "BWCDEVICE"

#endif // ACAB_AXON_SIGNATURES_H
