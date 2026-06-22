# All Cameras Are Beacons

**All Cameras Are Beacons.** A little gadget that quietly notices when surveillance gear is around you and gives you a heads-up, either on your phone or out over a Meshtastic mesh.

It runs on the **Colonel Panic OUI-Spy** and **Mesh-Detect** boards (tiny Seeed XIAO ESP32-S3 dev boards). Plug it in and it listens for the radio signals that cameras, sensors, and drones are already shouting into the air. When it detects one, it tells you.

> **Important** this only ever *listens*. It does not jam,
> spoof, or interfere with anything. It is the radio equivalent of noticing a
> camera on a pole and writing it down. Mapping surveillance gear in public is a
> long-standing privacy practice (the folks at deflock.me have been at it a while).

## What it looks for

| What | How it's spotted | Notes |
|---|---|---|
| **Flock cameras** (automated license-plate readers) | Bluetooth + WiFi | very reliable |
| **Flock Raven** (their audio / gunshot sensor) | Bluetooth | very reliable |
| **Drones** broadcasting FAA Remote ID | Bluetooth + WiFi | very reliable |
| **Axon body cameras** | Bluetooth | field-validated June 2026; on by default |
| **BLE item trackers** (AirTag / Find My, Tile, Samsung SmartTag) | Bluetooth | off by default; flip it on from the app when you want it |

Flock and Raven detection is built from publicly documented signatures, the IEEE OUI registry, Bluetooth SIG assigned numbers, and independent Flock research, all mapped out in [docs/signatures.md](docs/signatures.md). Drone detection reads the public FAA / ASTM Remote ID broadcast via the open-source [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c) decoder. BLE tracker detection is opt-in; Axon body-cam detection is field-validated (notes in [docs/axon.md](docs/axon.md)).

## How reliable is it?

It depends on *how* a device matched, and the app tells you. ACAB flags things by the radio signatures they broadcast: a Bluetooth name, a service ID, or the MAC vendor prefix (OUI). Name and Bluetooth matches are specific to Flock and very reliable. An OUI match is weaker: it only identifies the chipset vendor, and Flock is built on commodity WiFi and cellular modules (Liteon, Espressif, USI, and friends) that also ship in consumer cameras, routers, and IoT gear. So an OUI-only hit can occasionally be a home device on the same part; we have seen a home security camera flagged this way. The app shows the real registered hardware vendor and marks OUI-only matches as possible false positives, so treat those as leads to confirm rather than certainties.

## The easiest way to flash it: your browser

No tools to install. There's a one-click flasher hosted online:

**https://soyboi1312.github.io/all-cameras-are-beacons/**

1. Open that link in **Chrome or Edge** on a computer. (Safari and Firefox can't talk to USB devices, so they won't work here.)
2. Plug your board in with a USB-C cable.
3. Click **Flash OUI-Spy** or **Flash Mesh-Detect**, choose the board when the browser asks, and let it run.

If you'd rather host your own copy of the flasher, it all lives in [web/](web/).

## Flashing from the command line (for tinkering)

If you're poking at the firmware itself, PlatformIO is the best method:

```bash
cd firmware

pio run -e oui-spy     -t upload    # the app-controlled scanner
pio run -e mesh-detect -t upload    # the Meshtastic version

pio device monitor -b 115200        # watch what it's finding, live
```

Changed the firmware? Rebuild the browser flasher images with `./web/build-flasher.sh`, push, and the hosted page updates itself.

## Two flavors, same detector

Both builds run every detector at once. The only real difference is where the alerts go:

- **OUI-Spy** streams them to the **All Cameras Are Beacons** phone app (iPhone or Android) over Bluetooth.
- **Mesh-Detect** sends labeled messages out over a wired Heltec V3 running Meshtastic, on whatever channel you pick. Each one is plain-spoken: `Flock camera detected`, `Drone detected`, and so on. It **also pairs with the phone app** the same way OUI-Spy does, and while a phone is connected it tags each Meshtastic message with the phone's location as a tap-to-open maps link.

Wiring and Meshtastic setup are in [docs/mesh-setup.md](docs/mesh-setup.md).

## The phone apps

There are two native apps, one for **iPhone** and one for **Android**, that do the same job: pair with an OUI-Spy or Mesh-Detect board over Bluetooth and show what it's finding in real time. Both give you a live status view, a map of where things were seen, a running logbook, and controls for the board's buzzer and radios. Tap any detection to open its detail card: a signal-strength history, when the device was **first** and **last** heard, and its identifiers. If something hasn't been heard in a while its signal chart greys out, so live hits stand apart from stale ones. How the apps and firmware talk is in [docs/ble-protocol.md](docs/ble-protocol.md).

### iPhone

**All Cameras Are Beacons** lives in [ios/](ios/). Try the beta on TestFlight at [testflight.apple.com/join/UjgG7Gyu](https://testflight.apple.com/join/UjgG7Gyu). Grab Apple's free [TestFlight app](https://apps.apple.com/us/app/testflight/id899247664) first, then open the link to install.

### Android

**All Cameras Are Beacons for Android** lives in [android/](android/): native Kotlin / Jetpack Compose, the same feature set, with an OpenStreetMap map (no Google dependency). It isn't on the Play Store yet, so for now you build it from source or sideload the APK. Build and release notes are in [android/README.md](android/README.md).

Either app needs an OUI-Spy or Mesh-Detect board to actually detect anything, but you can poke around the interface without one.

## How the project is organized

```
firmware/
├── platformio.ini            # the two builds: oui-spy and mesh-detect
├── lib/acab_core/            # the shared detection engine (radio-agnostic)
│   ├── detection.h           #   the common "what did we find" event model
│   ├── flock_detect.*        #   Flock cameras + Raven
│   ├── drone_detect.*        #   Remote ID (wraps opendroneid/)
│   ├── axon_detect.*         #   Axon body cameras (field-validated)
│   ├── tracker_detect.*      #   BLE item trackers (AirTag, Tile, SmartTag; opt-in)
│   ├── acab_scanner.*        #   the BLE + WiFi scanning and dedup
│   └── opendroneid/          #   vendored opendroneid-core-c
├── src/oui-spy/              # build 1: streams to the phone app
└── src/mesh-detect/          # build 2: sends out over Meshtastic

ios/                          # the native iPhone app
android/                      # the native Android app
web/                          # the browser flasher
docs/                         # protocol, mesh wiring, Axon notes
```

## Where things stand

The firmware works, the mesh side has been tested on real hardware, and there are native apps for both iPhone and Android. Detection works by recognizing known signatures, so part of the ongoing work is keeping those signatures matching real-world gear as it changes. 
Still on the list: 
- Getting the Android app onto the Play Store
- Over-the-air firmware updates.

## Thanks to

- The **Colonel Panic OUI-Spy** ecosystem, whose hardware this runs on and whose
  earlier work pointed the way.
- Remote ID decoding from
  [opendroneid-core-c](https://github.com/opendroneid/opendroneid-core-c) (Apache-2.0).
- Flock signature research from the [deflock.me](https://deflock.me) community and the
  independent researchers cited in [docs/signatures.md](docs/signatures.md).
