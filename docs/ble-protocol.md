# ACAB BLE GATT Protocol (oui-spy ↔ iOS app)

This is the contract between the ACAB oui-spy firmware and the native SwiftUI app
(Phase 2). The firmware advertises as **`ACAB`** and exposes one service.

## Service & characteristics

| Role | UUID | Properties |
|---|---|---|
| **Service** | `acab0100-6f75-6973-7079-000000000000` | - |
| **Detections** | `acab0101-6f75-6973-7079-000000000000` | `NOTIFY` |
| **Config** | `acab0102-6f75-6973-7079-000000000000` | `WRITE`, `WRITE_NR` |
| **Status** | `acab0103-6f75-6973-7079-000000000000` | `READ`, `NOTIFY` |

> The low 4 bytes spell `ouispy` (`6f 75 69 73 70 79`). The app should subscribe
> to **Detections** and **Status** on connect, and request an MTU of 247 so each
> detection record fits in a single notification.

## Detections (notify)

One compact-JSON object per sighting. Emitted on first detection and again each
time the device is re-seen after the 60 s dedup window (`new` distinguishes them).

```json
{"t":1,"s":0,"meth":3,"c":85,"mac":"d4:ad:fc:11:22:33","rssi":-67,
 "name":"FS Ext Battery","det":"mfg 0x09C8","n":3,"new":true}
```

| Key | Meaning | Values |
|---|---|---|
| `t` | device type | `1` Flock camera · `2` Flock Raven · `3` Axon body cam · `4` Drone |
| `s` | source | `0` BLE · `1` WiFi · `2` Remote ID |
| `meth` | match method | `1` oui · `2` name · `3` mfg-id · `4` svc-uuid · `5` ssid · `6` probe · `7` remote-id |
| `c` | confidence | `0`-`100` |
| `mac` | transmitter MAC | string |
| `rssi` | signal strength | dBm |
| `name` | advertised name | optional |
| `id` | RID serial / operator id | optional (drones) |
| `det` | detail (raven fw, ssid, drone op-id…) | optional |
| `lat`,`lon` | subject location | drones: broadcast position; others: detector GPS |
| `gage` | age (s) of the GPS fix used for `lat`,`lon` | optional; set when stamped from a stale phone fix (offline / Desert) |
| `plat`,`plon` | drone operator location | optional |
| `alt` | altitude (m MSL) | optional (drones) |
| `n` | sighting count this session | integer |
| `new` | first sighting in window | bool |

### Suggested Swift model

```swift
struct Detection: Decodable {
    enum Kind: Int { case flockCamera = 1, flockRaven, axonBodyCam, drone }
    let t: Int, s: Int, meth: Int, c: Int
    let mac: String, rssi: Int
    let name: String?, id: String?, det: String?
    let lat: Double?, lon: Double?, plat: Double?, plon: Double?, alt: Int?
    let n: Int, new: Bool
    var kind: Kind { Kind(rawValue: t) ?? .flockCamera }
}
```

## Config (write)

Write a JSON object with any subset of keys:

```json
{"axon": true, "buzzer": false, "volume": 60, "ble": true, "wifi": true, "beep": true}
```

| Key | Effect |
|---|---|
| `axon` | enable/disable the **experimental** Axon detector (default off). Also gates the Motorola/police-gear OUI, which now reports as a body cam |
| `tracker` | enable/disable the BLE item-tracker (Find My, offline form) detector (default off) |
| `desert` | **Desert mode**: report EVERY device in range, not just known signatures (default off). See *Desert mode* below |
| `buzzer` | master audio on/off (`false` disables sound entirely) |
| `volume` | buzzer loudness, integer `0` to `100` (`0` is silent) |
| `ble` | enable/disable the BLE detection scan. `false` stops scanning only - the GATT link to the app stays up |
| `wifi` | enable/disable the Wi-Fi (promiscuous) detection scan |
| `beep` | `true` plays one preview beep at the current volume (pair with `volume` to audition a level) |
| `buffer` | enable/disable the offline detection buffer (default **off**, opt-in). See *Offline detection buffer* below |
| `key` | 64 lowercase hex chars = the 32-byte at-rest encryption key; the app generates + persists it and pushes it on connect, the board holds it in RAM only |
| `epoch` | unix seconds (the phone's wall clock), so the board can date buffered records for this power session |
| `sync` | start a replay drain: stream stored records with `seq` greater than this value (`0` = everything) |
| `clearlog` | `true` performs a real flash-sector erase of the buffer |

Sub-GHz (433/915 MHz) is not present on the OUI-Spy XIAO, so there is no key for it.

The firmware re-notifies Status after applying a config write.

## Status (read / notify)

```json
{"fw":"ACAB-ouispy 1.7","up":1234,"total":42,
 "ble":true,"wifi":true,"axon":false,"tracker":false,"buzzer":true,"vol":80,"gps":false,"bufon":false,"desert":false}
```

| Key | Meaning |
|---|---|
| `fw` | firmware build + version |
| `up` | uptime (seconds) |
| `total` | detections emitted this session |
| `ble` / `wifi` | detection scan active for that radio (reflects the `ble` / `wifi` config toggles) |
| `axon` | experimental Axon detector enabled |
| `buzzer` | master audio enabled |
| `vol` | buzzer volume, `0` to `100` |
| `gps` | a GPS fix is being applied to fixed-device detections |
| `buf` | number of detections currently held in the offline buffer |
| `bufon` | offline buffering is enabled |
| `tracker` | BLE item-tracker detector enabled |
| `desert` | Desert mode enabled (reporting every device in range) |
| `ign` | number of MACs on the board's ignore list (for app reconciliation) |

## Desert mode

Off by default. When enabled (`{"desert":true}`), the board reports **every** device
it sees - not just the known surveillance signatures - as a `Nearby device` detection
(`t=7`). The specific detectors still run first, so known gear keeps its real type;
Desert mode only labels the leftovers. Each nearby device is tagged hardware-OUI vs
randomized-MAC (phones rotate theirs), with the BLE advert name or Wi-Fi SSID when
present. Built for low-RF / remote areas (the desert) where anything new on the air is
worth knowing about. It reuses the dedup, offline-buffer, and alert pipeline, so it
shows, logs, and alerts on new devices like any other detection.

## Offline detection buffer

The board can record detections to encrypted flash while the app is disconnected,
then replay them when the app reconnects, so a walk with the app closed isn't lost.

**Opt-in and sensitive.** Buffering is **off by default**. Records are encrypted at
rest (AES-CTR) with a key the app supplies and the board never persists, so a seized
board's flash dump is ciphertext. The buffer auto-wipes if left undrained across
reboots, and `{"clearlog":true}` does a real sector erase.

### Connect handshake

After subscribing to Detections, the app writes to Config, in order:

```json
{"key":"3f9a...<64 hex>"}
{"epoch":1718900000}
{"sync":1503}
```

- `key` 32-byte at-rest key (generate once, persist in the Keychain / Keystore).
- `epoch` current unix time, so the board can stamp an absolute time on records captured this power session.
- `sync` the highest `seq` the app has already filed (`0` on the first ever sync).

### Replay records

The board streams each stored record over **Detections** as the normal detection
JSON plus a few keys, then a sentinel:

```json
{"t":1,"s":0,"meth":3,"c":85,"mac":"d4:ad:..","rssi":-71,"n":1,"new":true,"hist":true,"seq":1504,"at":1718899820}
{"hist":"end","n":12}
```

| Key | Meaning |
|---|---|
| `hist` | `true` on a replayed record; `"end"` on the final sentinel |
| `seq` | monotonic record id; the app persists the highest contiguous value as its sync cursor |
| `at` | unix seconds the record was captured (absolute) |
| `approx` | present + `true` when the capture time is unknown (a prior power session); order by `seq` |
| `n` (sentinel) | total records the board sent this drain |

The app files history records the same way as live ones (dedup by id), uses `at` for
the timestamp (or a `seq`-derived ordering when `approx`), and does **not** alert on
them. On the sentinel it checks it received `n` records and re-issues
`{"sync":<lastGoodSeq>}` to fill any gap (re-delivery is idempotent via dedup).

### Threat model

This buffer defends against a passive RF eavesdropper (the link is bonded + encrypted)
and a casual finder (opt-in, encrypted at rest, auto-wipe, easy erase). It does **not**
on its own defend against a forensic adversary with physical possession beyond the
encryption: ESP32 flash dumps over USB/JTAG, and `clearlog` needs the bonded phone in
hand. Treat a board that buffered sensitive locations as sensitive until it's drained
and wiped.

## Notes for the app

- **Dedup is on the device.** You still get periodic refreshes; treat `new:false`
  as "still here," update `lastSeen`, don't double-count.
- **Confidence drives UI weight.** Show low-confidence (esp. Axon, `c≈40`) hits
  distinctly - they are experimental.
- **Map layers** map cleanly to `t`: fixed pins for Flock/Axon, moving track for
  drones (use `lat/lon` + `plat/plon`).
