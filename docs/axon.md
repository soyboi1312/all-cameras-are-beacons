# Axon body-camera detection (field-validated)

**Status: field-validated, on by default.** As of June 2026 the detector has caught
real Axon body cameras on patrolling officers in the field, so it ships enabled.

## How it works

Axon body cams advertise BLE with a payload signature that survives MAC randomisation
(Axon is moving to rotating BLE MACs, so a MAC-based match alone would not hold), which
is what makes passive detection work. ACAB keys off three public facts:

- **MAC OUI `00:25:DF`**: Axon Enterprise's only IEEE block (MA-L, registered 2010
  as TASER International, updated 2025-01-30). This is the loose match: it flags any
  Axon product (body cam, dock, TASER, fleet gear).
- **The `BWCDEVICE` service-data tag**: a standalone, MAC-independent match (method
  svc-data, confidence 90, detail "BWC DEVICE") that fires with or without the Axon
  OUI - deliberately, because rotating BLE MACs break the OUI path but the tag rides
  in the advert payload. The OUI stays the loose any-Axon-product match at
  confidence 75.
- **Axon's Bluetooth SIG numbers** (2.2.2+): service data under the 16-bit UUID `0xFE6B`,
  or manufacturer data under company ID `0x034D`, each with a payload; `0x034D` also needs its
  serial shape (the byte `0x02`, then nine uppercase letters or digits). Both are registered
  to TASER International (Axon's former name). The match is MAC-independent, like the tag,
  but it names the vendor, not the product: confidence 75, detail "Axon Bluetooth ID",
  ranked below the tag and above the OUI. The first owner-confirmed hit came on 2026-10-21. The
  evidence and the reason for the serial gate are in the body cam section of
  [signatures.md](signatures.md).

Not matched yet: a second Axon 128-bit service-data tag that reads `METROPOLISDEVICE`, seen on
two `00:25:DF` devices in September 2026. Its product is unknown, and on `00:25:DF` the OUI path
still catches it at 75. The advert bytes and the condition for adding a matcher are in
[signatures.md](signatures.md).

There is also a WiFi path. `axonClassifyWiFi` matches both OUIs in `AXON_OUI` (`00:25:DF`, and
`D8:1F:65`, a block the registry lists as Private that field capture attributes to Axon; the BLE
path matches it too), plus the Utility BodyWorn OUIs, on WiFi management frames at confidence 65. Axon's
WiFi estate is broader than body cams (docks, evidence terminals, station gear, and Fleet in-car
video), so the type claim is weaker there: the OUI says "an Axon device", not necessarily a body
cam. It has eight field hits so far (2026-10-21), six of them at scenes the owner confirmed as
body cams. Where a hit's BLE side was heard too, the two were one device: on `00:25:DF` the WiFi
address is one below the BLE address, and on `D8:1F:65` (one pair so far, provisional) WiFi =
(BLE - 1) + 0x800000. In the 2026-08-03 capture the BLE side carried the `BWCDEVICE` tag, so body
cams transmit on WiFi. Details are in the body cam section of [signatures.md](signatures.md).

> Heads up: the unrelated **"Axon Networks Inc."** OUIs (`00:58:28`, `84:70:03`)
> belong to a different, legacy company. Don't use them.

## Field validation

June 2026: driving past multiple officers at different stops, ACAB picked up their
body cams on `00:25:DF`, confirming that Body 3 / Body 4 units advertise on the
public OUI (not a resolvable random address) in normal holstered operation.

## Tuning

`lib/acab_core/axon_detect.*` matches a fixed OUI table (`AXON_OUI`, values in
`axon_signatures.h`), the `BWCDEVICE` tag and Axon's SIG numbers (`AXON_SIG_SVC_UUID`,
`AXON_SIG_COMPANY_ID`, with the `0x034D` payload shape in `AXON_SIG_CID_SERIAL_LEN`). There is no knob to *require* the tag: if
OUI-only false positives ever appear, that is a code change in `axonClassifyBLE`. It's
enabled by default (`gEnabled.on` starts `true`); either app (iOS or Android) can toggle it with
`{"axon":true}`, and the choice is NVS-persisted, restored on every board at boot via
`axonRestoreEnabled(true)`.
