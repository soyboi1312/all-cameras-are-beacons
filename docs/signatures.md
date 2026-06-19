# ACAB detection signatures (clean-room reference)

Every signature in this file is sourced from a public registry, a published standard,
or independent third-party research, **not** from the colonelpanichacks/oui-spy code.
Rebuild the firmware's detection tables from here and write your own parser.

## Why this is clean

Facts are not copyrightable: MAC OUIs, Bluetooth company IDs, service UUIDs, SSID
patterns, and published standards are public facts. Each entry below cites where it
comes from. The only thing you cannot reuse is upstream *code and curation*, so source
the facts here and implement your own matching.

## Public registries (the backbone)

| Registry | What it gives you | URL |
|---|---|---|
| IEEE OUI registry | MAC OUI to manufacturer (free TXT/CSV) | https://regauth.standards.ieee.org/ |
| Bluetooth SIG Assigned Numbers | company IDs + 16-bit service UUIDs | https://www.bluetooth.com/specifications/assigned-numbers/ |

Bulk-OUI mirrors: macaddress.io, maclookup.app, github.com/Ringmast4r/OUI-Master-Database.

---

## Flock Safety (ALPR camera)

| Signature | Match on | Value | Public source |
|---|---|---|---|
| WiFi SSID | prefix | `Flock-` + partial MAC | ryanohoro, GainSec |
| BLE name | legacy pattern | `Penguin-` + 10 digits | ryanohoro |
| BLE name | current pattern (post Mar 2025) | 10 decimal digits | ryanohoro |
| BLE name | literal | `FS Ext Battery` | ryanohoro |
| BLE mfg data | company ID | `0x09C8` (Flock's BT module; ryanohoro attributes to XUNTONG) | ryanohoro |
| MAC OUI | exact | `B4:1E:52` (Flock Safety, MA-L, reg. 2024-05-09) | IEEE / maclookup.app |

**Detection-quality notes (read before you copy the old tables):**
- The WiFi/BT chip is a LiteOn WCBN3510A. Lite-On's OUIs are shared across millions of
  consumer devices, so OUI-matching on Lite-On is a false-positive magnet. Do not do it.
- Drop the old ~67-OUI "superset" entirely. It was both ported curation and the source of
  the field false positives. `B4:1E:52` (Flock's own block) is the only OUI defensibly
  Flock-specific; everything else was a shared module maker.
- The bare 10-digit BLE name is inherently ambiguous (any device with a 10-digit name
  matches, including phones). Gate it with RSSI and/or a co-signal before alerting.

## Flock Raven (audio sensor)

| Signature | Match on | Value | Source |
|---|---|---|---|
| BLE service UUID | 128-bit UUID (parsed from 0x06 / 0x07 AD structures) | record from your own field capture | own capture |

Raven advertises its service UUIDs in 128-bit form. Capture one in the field, record the
UUID here, and that entry is your own data, fully clean.

## Other ALPR brands: mostly NOT passively detectable

Most ALPR vendors backhaul over cellular (or wired) with no BLE/WiFi beacon, so a
2.4 GHz sniffer cannot see them - the same gap as the Ubicquia units we hit in the
field. Flock is the outlier: it beacons over BLE/WiFi for health and setup.

| Brand | Backhaul | Passively detectable on 2.4 GHz? |
|---|---|---|
| Flock Safety | cellular + BLE/WiFi beacons | yes (signatures above) |
| Motorola / Vigilant (L5Q) | cellular | no |
| Leonardo / ELSAG | cellular / wired | no |
| Genetec AutoVu | wired / WiFi / cellular | site-dependent, usually no |
| Neology, Jenoptik, Perceptics, Rekor, Ubicquia, Conduent | cellular / wired | no |

For the cellular ones the detection path is the DeFlock map + optical (IR-illuminator
spotting), not RF. src: DHS ALPR Market Survey (2025); EFF Street-Level Surveillance.

**Motorola Solutions OUI `4C:CC:34`** is IEEE-confirmed, but it is their whole corporate
block: it covers any Motorola Solutions WiFi/BLE device (in-car routers, body-cam docks,
APs, infrastructure), NOT just ALPR, and NOT their LMR police radios (those are 700/800
MHz, off this board's 2.4 GHz band). Matching it flags "a Motorola Solutions device
nearby" - a useful police-gear hint, but a false positive if labeled "ALPR camera." If
you want it, add it as a separate, honestly-labeled signal, not as an ALPR brand.
src: IEEE OUI registry -> https://maclookup.app/macaddress/4CCC34

## Drone (Remote ID): use the licensed library, no table needed

Vendor in **opendroneid-core-c (Apache-2.0)** and call its decoder. It is ASTM F3411
compliant and covers BLE legacy/extended plus WiFi NAN/beacon Remote ID.
- Library: https://github.com/opendroneid/opendroneid-core-c  (Apache-2.0, commercial-OK with attribution)
- Spec: https://github.com/opendroneid/specs  (standard: ASTM F3411)
- nRF52 reference for Chip B: https://github.com/sxjack/remote_id_bt5  (check its license first)

## Axon body cam

| Signature | Match on | Value | Public source |
|---|---|---|---|
| MAC OUI | exact | `00:25:DF` (Axon Enterprise, ex-TASER; sole IEEE block) | IEEE / maclookup.app |
| BLE payload | service string contains | `BWC DEVICE` | own field capture, 2026-06 |

FCC teardowns: Axon FCC IDs under `X4G...` (e.g. X4GS01200, Body 3) on fccid.io. OUI alone
cannot separate a body cam from other Axon gear; the `BWC DEVICE` payload narrows it.

## BLE trackers

| Tracker | Match on | Value | Public source |
|---|---|---|---|
| Apple AirTag / Find My | mfg company ID + type | `0x004C` + payload type `0x12` | Bluetooth SIG + arXiv 2501.17452 |
| Samsung SmartTag | service UUID | `0xFD5A` | arXiv 2501.17452 + Bluetooth SIG |
| Tile | service UUID | `0xFEED` | Bluetooth SIG |

---

## Sources

- IEEE OUI registry: https://regauth.standards.ieee.org/
- Bluetooth SIG Assigned Numbers: https://www.bluetooth.com/specifications/assigned-numbers/
- Flock teardown (CEHRP): https://www.cehrp.org/dissection-of-flock-safety-camera/
- Flock RF signatures (ryanohoro): https://www.ryanohoro.com/post/spotting-flock-safety-s-falcon-cameras
- Flock WiFi research (GainSec): https://gainsec.com/2025/09/27/button-presses-to-shell-on-flock-safety-license-plate-cameras-over-wi-fi/
- ALPR Watch wiki: https://wiki.alprwatch.org/index.php/Flock_Safety
- DeFlock map (locations, OSM/ODbL open data): https://deflock.me
- OUI 00:25:DF (Axon Enterprise): https://maclookup.app/macaddress/0025DF
- OUI B4:1E:52 (Flock Safety): https://maclookup.app/macaddress/b41e52
- OpenDroneID core library (Apache-2.0): https://github.com/opendroneid/opendroneid-core-c
- Tracker research: https://arxiv.org/abs/2501.17452 and https://arxiv.org/pdf/2401.13584

---

*Drafted 2026-06-18 from public sources. Before shipping: verify Flock's BLE company ID
`0x09C8` against the current Bluetooth SIG assigned-numbers list, and fill in the Raven
service UUID from a field capture.*
