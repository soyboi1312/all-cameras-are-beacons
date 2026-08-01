# All Cameras Are Beacons

**All Cameras Are Beacons.** A little gadget that quietly notices when surveillance gear is around you and gives you a heads-up, either on your phone or out over a Meshtastic mesh.

It runs on the beacon (our own two-radio board) and on the **Colonel Panic OUI-Spy** and **Mesh-Detect** boards (tiny Seeed XIAO ESP32-S3 dev boards). Plug it in and it listens for the radio signals that cameras, sensors, and drones are already shouting into the air. When it detects one, it tells you.

> **Important** this only ever *listens*. It does not jam,
> spoof, or interfere with anything. It is the radio equivalent of noticing a
> camera on a pole and writing it down. Mapping surveillance gear in public is a
> long-standing privacy practice (the folks at deflock.me have been at it a while).

## the beacon

the beacon is a pocket detector, about the size of an airpods case, that quietly maps the surveillance broadcasting around you. flip it on, drop it in a bag, and everything it hears shows up live on your phone.

it is a **passive listener** on two bands, WiFi and bluetooth. surveillance gear announces itself over the air to do its job; the beacon recognizes those broadcasts and puts them on your map. it never transmits, jams, or spoofs. it is a detector, not a weapon.

**what it catches**
- flock / ALPR license-plate cameras, plus flock's raven audio sensors
- drones overhead: the FAA remote ID broadcast is the main tell, and DJI, Parrot, Skydio, Autel, and Yuneec craft are also flagged by their own radio hardware when they aren't broadcasting it
- body-worn cameras in range (Axon, matched on its own registered hardware address and on its device tag. a broader Motorola Solutions vendor match sits on its own switch under body cam, opt-in and off by default: in our own capture every one of those hits was fixed equipment, not anything worn, so it reads as a weak match to verify rather than a confirmed camera)
- BLE item trackers riding along with you (AirTag / Find My, Tile, SmartTag; off by default. your phone sees a tracker from the first sighting, and the buzzer holds quiet for that tracker's first minute, so one you merely walk past never sounds)
- smart / recording glasses on the people around you (Ray-Ban / Oakley Meta, Snap Spectacles, Vuzix; honest "possible glasses" call, since the Meta signature can also be a VR headset)
- network cameras on the WiFi you're on (opt-in, off by default; branded IP-camera OUIs like Hikvision, Dahua, Amcrest, Axis, Reolink on the host network. it matches known camera brands, not every camera, and is never a hidden-camera claim)

**the device**
- dual radio: a dedicated bluetooth scanner runs flat-out while a second radio handles WiFi and the app link, so neither starves the other. single-radio boards time-slice one antenna between scanning and the phone link; the beacon's bluetooth scan never pauses
- location tagged via your phone's GPS
- an on-board buzzer alerts you, so it works with your phone put away
- optional offline logging: opt in once and it keeps what it heard while you were gone, encrypted, waiting when you reconnect
- ships pre-flashed and ready to pair, nothing to set up out of the box
- USB-C powered (the battery model recharges over the same port). when new firmware lands the app flags it and installs it over-the-air over bluetooth, no cable and no toolchain; you can also flash from your browser in one click at [soyboi.tech/flash](https://soyboi.tech/flash.html)

**free app, paid hardware.** the iOS and android apps are free and open source, and so is the firmware, read every line before you trust it. the beacon hardware is what we sell. buy the beacon, own the data: no accounts, no cloud, no telemetry, every detection stays on your device.

**get one.** everything about the beacon lives at [soyboi.tech](https://soyboi.tech). preorder on [tindie](https://www.tindie.com/stores/soyboitech/).

**honest about limits.** silent gear stays invisible: wired cameras and purely optical systems emit no radio and won't show up. this is not an SDR or a bug sweeper, it listens to two bands for known signatures, nothing more. a quiet screen means nothing announced itself, not that you're unwatched.

## What it looks for

| What | How it's spotted | Notes |
|---|---|---|
| **Flock cameras** (automated license-plate readers) | Bluetooth + WiFi | very reliable |
| **Flock Raven** (their audio / gunshot sensor) | Bluetooth | very reliable |
| **Drones** broadcasting FAA Remote ID | Bluetooth + WiFi | very reliable. a separate opt-in fallback, off by default, flags DJI, Parrot, Skydio, Autel and Yuneec hardware when Remote ID is silent; that one means vendor gear nearby, which may be a controller rather than an aircraft |
| **Axon body cameras** | Bluetooth | field-validated June 2026; on by default |
| **BLE item trackers** (AirTag / Find My, Tile, Samsung SmartTag) | Bluetooth | off by default, flip it on from the app; the buzzer holds quiet for a tracker's first minute in range, so one you walk past never sounds, while the sighting still reaches the app straight away |
| **Smart / recording glasses** (Ray-Ban / Oakley Meta, Snap Spectacles, Vuzix) | Bluetooth | on by default; capture-pending, reports as "possible glasses" since the Meta signature can also be a VR headset |
| **Network cameras** (branded IP cameras: Hikvision, Dahua, Amcrest, Axis, Reolink) | WiFi | opt-in, off by default; the board never joins a network, it listens promiscuously and matches camera-brand OUIs in frames already on the air, at ~65 confidence; known brands only, cannot find every camera, never a hidden-camera claim. now 43 vendor blocks including Ring, Wyze and Anker/eufy, where a hit may be another product from the same maker |

Flock and Raven detection is built from publicly documented signatures, the IEEE OUI registry, Bluetooth SIG assigned numbers, and independent Flock research, all mapped out in [docs/signatures.md](docs/signatures.md). Drone detection reads the public FAA / ASTM Remote ID broadcast via the open-source [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c) decoder, with a secondary hardware-signature fallback for DJI, Parrot, Skydio, Autel, and Yuneec when a craft isn't broadcasting Remote ID. BLE tracker detection is opt-in; Axon body-cam detection is field-validated (notes in [docs/axon.md](docs/axon.md)). Smart/recording-glasses detection keys off Bluetooth SIG company IDs and is capture-pending (notes in [docs/glasses.md](docs/glasses.md)).

## How reliable is it?

It depends on *how* a device matched, and the app tells you. ACAB flags things by the radio signatures they broadcast: a Bluetooth name, a service ID, or the MAC vendor prefix (OUI). Name and Bluetooth matches are specific to Flock and very reliable. An OUI match is weaker: it only identifies the chipset vendor, and Flock is built on commodity WiFi and cellular modules (Liteon, Espressif, USI, and friends) that also ship in consumer cameras, routers, and IoT gear. So an OUI-only hit can occasionally be a home device on the same part; we have seen a home security camera flagged this way. The app shows the real registered hardware vendor and marks OUI-only matches as possible false positives, so treat those as leads to confirm rather than certainties.

## Flashing

**Got a beacon?** It ships pre-flashed and ready to pair. New firmware installs over-the-air from the app over Bluetooth with no cable, or in one click from your browser at [soyboi.tech/flash](https://soyboi.tech/flash.html) with a USB-C cable. The DIY flasher below is for rolling your own, you don't need it.

**Building your own** oui-spy or mesh-detect on a bare XIAO board? No tools to install, there's a one-click flasher hosted online:

**https://soyboi1312.github.io/all-cameras-are-beacons/**

1. Open that link in **Chrome or Edge** on a computer. (Safari and Firefox can't talk to USB devices, so they won't work here.)
2. Plug your board in with a USB-C cable.
3. Click **Flash firmware** or one of the **Flash Mesh-Detect** buttons (public or private channel), choose the board when the browser asks, and let it run.

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

There are two native apps, one for **iPhone** and one for **Android**, that do the same job: pair with a beacon, OUI-Spy, or Mesh-Detect board over Bluetooth and show what it's finding in real time. Both give you a live status view, a map of where things were seen, a running logbook, and controls for the board's buzzer and radios. Tap any detection to open its detail card: a signal-strength history, when the device was **first** and **last** heard, and its identifiers. If something hasn't been heard in a while its signal chart greys out, so live hits stand apart from stale ones. Both apps also carry the newer features: star any device to make it your own custom category (the beacon then calls it out every time it's seen), an ignore list for your own gear, an opt-in known-cameras map layer built from community-mapped ALPR sites, and the opt-in encrypted offline buffer.

A few things worth knowing about how the apps read a detection:

- **Every row shows a confidence percentage.** It grades how uniquely the thing that matched identifies that device class, and it has nothing to do with signal strength. 80 and up is a strong signature match, under 50 is a weak one worth verifying rather than an alarm. Tap the row to see exactly which signal fired.
- **Name your devices.** Anything you star or ignore can be renamed on the managed-devices screen, and that name then replaces the generic label everywhere: the log, the detail card, map pins, notifications, and the CSV export. Call a tag "Jane's tag" once and you never read "Tracker" again.
- **The known-cameras layer names the manufacturer.** Tap a mapped camera and it tells you who makes it (Flock Safety, Ubicquia, Genetec, Motorola/Vigilant, and others). When a live ALPR detection lands within 150 m of a mapped camera, the detail card says so, which is independent corroboration that the hit is real. Absence is never treated as evidence: an unmapped area only means nobody has mapped it.
- **A first-run walkthrough** appears the first time a board connects, and there is a full demo mode running on sample data if you want to look around before buying anything. How the apps and firmware talk is in [docs/ble-protocol.md](docs/ble-protocol.md).

### iPhone

**All Cameras Are Beacons** lives in [ios/](ios/). Try the beta on TestFlight at [testflight.apple.com/join/RC3j99A8](https://testflight.apple.com/join/RC3j99A8). Grab Apple's free [TestFlight app](https://apps.apple.com/us/app/testflight/id899247664) first, then open the link to install.

### Android

**All Cameras Are Beacons for Android** lives in [android/](android/): native Kotlin / Jetpack Compose, the same feature set, with an OpenStreetMap map (no Google dependency). It isn't on the Play Store yet, so for now you build it from source or sideload the APK. Build and release notes are in [android/README.md](android/README.md).

Either app needs an OUI-Spy or Mesh-Detect board to actually detect anything, but you can poke around the interface without one.

## How the project is organized

```
firmware/
├── platformio.ini            # the builds: beacon-board, oui-spy, mesh-detect (+ mesh-detect-ch1)
├── lib/acab_core/            # the shared detection engine (radio-agnostic)
│   ├── detection.h           #   the common "what did we find" event model
│   ├── flock_detect.*        #   Flock cameras + Raven
│   ├── drone_detect.*        #   Remote ID (wraps opendroneid/)
│   ├── axon_detect.*         #   Axon body cameras (field-validated)
│   ├── tracker_detect.*      #   BLE item trackers (AirTag, Tile, SmartTag; opt-in)
│   ├── glasses_detect.*      #   smart / recording glasses (Meta, Snap, Vuzix)
│   ├── desert_detect.*       #   desert mode (report everything nearby)
│   ├── acab_scanner.*        #   the BLE + WiFi scanning and dedup
│   └── opendroneid/          #   vendored opendroneid-core-c
├── src/beacon-board/              # build 1: streams to the phone app
└── src/mesh-detect/          # build 2: sends out over Meshtastic

ios/                          # the native iPhone app
android/                      # the native Android app
web/                          # the browser flasher
docs/                         # protocol, mesh wiring, Axon notes
```

## Where things stand

The firmware works, the mesh side has been tested on real hardware, and there are native apps for both iPhone and Android. Detection works by recognizing known signatures, so part of the ongoing work is keeping those signatures matching real-world gear as it changes.

Firmware updates are handled two ways: the one-click browser flasher, and over-the-air updates over Bluetooth built into both apps (the app checks a hosted version manifest, so new firmware ships without waiting on an app-store release). The over-the-air path is validated end-to-end on hardware, including signature verification and automatic rollback if an update ever fails to boot.

Still on the list:
- Getting the iPhone app onto the App Store and the Android app onto the Play Store
- Field-proving the newer detectors. The dual-radio board is done and shipping: both
  radios, power, and over-the-air updates for BOTH processors are proven on hardware, the
  ESP32-S3 over its own OTA and the companion nRF over Bluetooth DFU from inside the app.
  What is still open is ground truth, not code: the glasses signatures have one capture
  behind them and the WiFi body-cam path has none. The bring-up checklist is in
  [firmware/nrf-ble-scan/BRINGUP.md](firmware/nrf-ble-scan/BRINGUP.md).

## Thanks to

- The **Colonel Panic OUI-Spy** ecosystem, whose hardware this runs on and whose
  earlier work pointed the way.
- Remote ID decoding from
  [opendroneid-core-c](https://github.com/opendroneid/opendroneid-core-c) (Apache-2.0).
- Flock signature research from the [deflock.me](https://deflock.me) community and the
  independent researchers cited in [docs/signatures.md](docs/signatures.md).

All Cameras Are Beacons is an independent project and is not affiliated with, endorsed by,
or sponsored by Colonel Panic. "OUI-Spy" and "Mesh-Detect" are Colonel Panic's product
names, used here only to identify compatible hardware.
