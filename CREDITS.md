# Credits and provenance

All Cameras Are Beacons grew out of the OUI-Spy and Flock-detection community. This
file records where the detection comes from, the public sources behind the
signatures, the one Apache-licensed dependency, and the project's own work, so the
lineage stays visible.

## Detection sources

- **Flock Safety + Raven detection** (`firmware/lib/acab_core/flock_detect.*`):
  the MAC OUI, the `Flock-` SSID, advertised-name patterns, and the BT
  manufacturer ID are re-derived from public data, the IEEE OUI registry, the
  community `nite-oui-collection` (@NitekryDPaul) for the Flock-specific OUI set, the
  Bluetooth SIG assigned numbers, independent Flock research (ryanohoro, CEHRP,
  GainSec), and the **deflock.me** community. Each entry's source is documented in
  `docs/signatures.md`.
- **Drone Remote ID detection** (`firmware/lib/acab_core/drone_detect.*`): our own
  classifier for the public **ASTM F3411 / OpenDroneID** broadcast formats, the
  Service-Data UUID 0xFFFA, the NAN multicast address, and the beacon vendor IEs
  are all defined in the standard.
- **OpenDroneID decoder** (`firmware/lib/acab_core/opendroneid/`): vendored from
  **opendroneid/opendroneid-core-c**, licensed **Apache-2.0** (the full license is
  preserved in `firmware/lib/acab_core/opendroneid/LICENSE`).

This project grew out of the **OUI-Spy** ecosystem: it runs on Colonel Panic's
OUI-Spy and Mesh-Detect hardware, and earlier releases of these detectors began as
ports of `colonelpanichacks/oui-spy` and `colonelpanichacks/oui-spy-unified-blue` before the
signatures were re-sourced and the classifiers re-derived from the public references
above.

## Original to this project

The Axon body-cam detector, the BLE item-tracker detector, the shared `acab_core`
engine structure, the encrypted BLE GATT protocol, the native iOS and Android
apps, the Meshtastic uplink, and the web flasher are original to All Cameras Are Beacons.

## A note on licensing

The only third-party code in the firmware is opendroneid-core-c, which is cleanly
Apache-2.0, and its license travels with the vendored copy (see the LICENSE in that
directory). Everything else, the detection signatures, the classifiers, the
`acab_core` engine, the BLE GATT protocol, the apps, the Meshtastic uplink, and the
web flasher, is this project's own work, built from the public references in
`docs/signatures.md`. Earlier releases ported detection code from the unlicensed
`colonelpanichacks/oui-spy`, `colonelpanichacks/oui-spy-unified-blue`, and `flock-you`; those
signatures have since been re-sourced from public registries and the classifiers
re-derived from public standards, so the project no longer carries their
all-rights-reserved code.

## Keeping signatures fresh

Detection signatures drift as Flock and others change hardware (this already bit
us once, when an early port shipped a stale subset of the Flock OUIs). Run

    python3 firmware/tools/check-signature-drift.py

periodically to diff the local Flock OUI tables and the opendroneid decoder
against their upstream sources. It only reports; it never changes anything.
