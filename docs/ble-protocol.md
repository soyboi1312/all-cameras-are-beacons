# ACAB BLE GATT Protocol (OUI-Spy ↔ iOS app)

This is the contract between the OUI-Spy firmware and the native SwiftUI app
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
| `axon` | enable/disable the **experimental** Axon detector (default off) |
| `buzzer` | master audio on/off (`false` disables sound entirely) |
| `volume` | buzzer loudness, integer `0` to `100` (`0` is silent) |
| `ble` | enable/disable the BLE detection scan. `false` stops scanning only - the GATT link to the app stays up |
| `wifi` | enable/disable the Wi-Fi (promiscuous) detection scan |
| `beep` | `true` plays one preview beep at the current volume (pair with `volume` to audition a level) |

Sub-GHz (433/915 MHz) is not present on the OUI-Spy XIAO, so there is no key for it.

The firmware re-notifies Status after applying a config write.

## Status (read / notify)

```json
{"fw":"ACAB-ouispy 0.9","up":1234,"total":42,
 "ble":true,"wifi":true,"axon":false,"buzzer":true,"vol":80,"gps":false}
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

## Notes for the app

- **Dedup is on the device.** You still get periodic refreshes; treat `new:false`
  as "still here," update `lastSeen`, don't double-count.
- **Confidence drives UI weight.** Show low-confidence (esp. Axon, `c≈40`) hits
  distinctly - they are experimental.
- **Map layers** map cleanly to `t`: fixed pins for Flock/Axon, moving track for
  drones (use `lat/lon` + `plat/plon`).
