# All Cameras Are Beacons

**beacons** picks up the Wi-Fi and Bluetooth broadcasts of supported surveillance devices, such as license-plate readers, body cams, and drones, and shows them in the iPhone and Android apps. Mesh-Detect can also send them out as Meshtastic alerts. it runs on the beacon, our pocket-sized dual-radio detector, and on Colonel Panic's OUI-Spy and Mesh-Detect boards.

detection is passive: shipping firmware never probes, jams, spoofs, controls, or interferes with nearby devices. the board talks to your phone over bonded, encrypted Bluetooth, and Mesh-Detect also sends alerts through its wired Meshtastic node.

## getting started

the apps are free, but live detection needs a compatible board. without one, you can still use sample data and your saved Log.

- **buy a beacon** on [Tindie](https://www.tindie.com/stores/soyboitech/) or [Etsy](https://www.etsy.com/shop/soyboitech): the slim model ([Tindie](https://www.tindie.com/products/soyboitech/beacon-slim-pocket-counter-surveillance-detector/), [Etsy](https://www.etsy.com/listing/4587255406/airtag-and-bluetooth-tracker-detector)) or the battery model ([Tindie](https://www.tindie.com/products/soyboitech/beacon-battery-pocket-counter-surveillance/), [Etsy](https://www.etsy.com/listing/4587261765/rechargeable-airtag-and-bluetooth)). [soyboi.tech](https://soyboi.tech) has current pricing and availability.
- **try the app without hardware:** install it for [iPhone](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) or [Android](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) and tap **See How It Works** for a tour with made-up detections.
- **connect a board:** turn it on, tap **Scan for Beacons**, pick your board, and approve the pairing request. the app takes you through setup and permissions. do the first pairing somewhere you trust; see the [pairing guide](docs/app-guide.md#try-it-or-connect-a-board).
- **flash your own OUI-Spy or Mesh-Detect** with the [DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) or [from the command line](#flashing-from-the-command-line).
- **get help** from the [getting-started guide](https://soyboi.tech/getting-started), the [app guide](docs/app-guide.md), or the [FAQ](https://soyboi.tech/faq), or [open an issue](https://github.com/soyboi1312/all-cameras-are-beacons/issues).

<a id="the-beacon"></a>
<a id="firmware-targets"></a>

## supported hardware

all three boards run the same detector engine and the same per-category settings. they differ in radio coverage and in where alerts go.

| hardware | radios | alerts |
|---|---|---|
| **the beacon** (rev-A and rev-B) | nRF52840 dedicated to Bluetooth scanning; ESP32-S3 for Wi-Fi and the app link | phone app, onboard buzzer, optional encrypted offline log |
| **OUI-Spy** | Seeed XIAO ESP32-S3, one radio shared between Wi-Fi and Bluetooth | phone app, onboard buzzer, optional encrypted offline log |
| **Mesh-Detect** | the same XIAO build, plus a wired Heltec V3 running Meshtastic | phone app and mesh alerts, with optional phone location while connected, and an optional encrypted offline log |

the beacon is about the size of an AirPods case and runs on USB-C power; the battery model charges through the same port. retail units come pre-flashed. pair one with the app to choose detector categories, alerts, and optional location or offline logging. firmware updates come through the app, and USB recovery is specific to each board revision (see [production beacon](#production-beacon)).

for Mesh-Detect, [mesh setup](docs/mesh-setup.md) covers the Heltec wiring and the public or private channel options.

## what it detects

| category | radio | default | notes |
|---|---|---|---|
| **Flock cameras** (license-plate readers) | Bluetooth + Wi-Fi | on | a camera's own Flock- network name, the FS Ext Battery name, or a name with Flock's manufacturer ID is strong evidence; other names and vendor-prefix matches need confirming |
| **Flock Raven** audio sensors | Bluetooth | on | matches Raven-specific services seen in field captures |
| **Remote ID drones** | Bluetooth + Wi-Fi | on | broadcasts can include the aircraft's position; a separate, opt-in vendor match flags drones without Remote ID, but a hit may be a controller or other vendor gear |
| **body cams** (Axon and Utility BodyWorn) | Bluetooth + Wi-Fi | on | Axon's device tag is the strongest match; the Motorola vendor match (Motorola Solutions and WatchGuard Video blocks) is broad, weak, and a separate opt-in |
| **item trackers** | Bluetooth | off | Find My, Find Hub, Tile, and SmartTag; Find My and Find Hub tags only count once separated from their owner; no buzzer alerts on the board |
| **smart or recording glasses** | Bluetooth | on | eyewear-specific evidence is stronger; some Meta identifiers also appear on other hardware |
| **network cameras** | Wi-Fi | off | a vendor match may be a camera, recorder, hub, or accessory |

the [signature reference](docs/signatures.md) lists every supported manufacturer, the evidence behind each match, how confidence is set, and the matches we rejected. there are also [Axon notes](docs/axon.md) and [glasses research](docs/glasses.md). Remote ID decoding uses [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c).

diagnostic builds also log [capture candidates](docs/signatures.md#capture-only-alpr-vendor-prefix-candidates-206) for research. these are not production detections and never reach the phone apps.

## limits

### confidence

a decoded Remote ID payload or a device-specific signature is strong evidence. a match on a vendor's radio-address prefix (OUI) is weaker: it identifies the registered vendor, not the exact product. prefixes from chip suppliers that would flag unrelated consumer gear are excluded, with one exception: four Liteon Wi-Fi prefixes seen at Flock Falcon sites still match probe requests, so a laptop can trigger them.

tap a detection to see how it was matched, its confidence, and the evidence. **confidence describes how specific the evidence is.** it is not signal strength, and it is not the probability that a camera is there. treat weak matches as leads to check.

### what it can hear

the board only listens on 2.4 GHz; there is no 5 GHz radio. it cannot see equipment that never makes a supported broadcast, such as wired-only or purely optical gear. Wi-Fi is scanned one channel at a time, so short transmissions can be missed, and Wi-Fi eco mode adds more gaps. OUI-Spy and Mesh-Detect split one radio's time between Wi-Fi and Bluetooth; the beacon's dedicated Bluetooth scanner runs the whole time during normal scanning.

an empty screen means nothing supported was recognized while the board was listening. **it does not mean you are unwatched.** [radio coverage](docs/radio-coverage.md) has the channel schedule, duty cycles, and Wi-Fi eco tradeoffs.

## privacy

there are no accounts, analytics, or third-party trackers, and nothing is uploaded automatically. detections stay on your board and phone unless you export or contribute them yourself. Mesh-Detect is the exception: it sends detections out as mesh alerts, which can include your phone's location while it is connected, and the default build posts them on the public channel that anyone on the mesh can read. the apps do go online to load map tiles, firmware files, and the optional mapped-camera dataset, but those requests never include your detections.

if you allow location access, the phone geotags sightings and sends its position to the board over the encrypted link. offline records can keep that location. exports can include both where you were and the positions drones broadcast, so check an export before you share it.

two things these protections do not cover:

- **the board can be tracked.** it advertises a fixed factory Bluetooth address, because iPhones could not connect to a rotating one in testing.
- **offline encryption does not protect a seized board from forensic access.** while buffering is on, the key is stored on the board.

read the [privacy policy](web/privacy.html) and the [Bluetooth privacy details](docs/ble-protocol.md#peripheral-address-bonding-and-privacy) before you rely on any of this.

## the phone apps

both apps have the same four tabs:

- **Status:** a radar of devices heard in the last 45 seconds, with a count for each category.
- **Map:** located sightings from the last 45 seconds, the last 15 minutes, or all history, plus a separate layer of community-mapped cameras.
- **Log:** saved detections, filtered as active, new, or all, with search, filters, signal history, matching evidence, and CSV or GPX export. it works while disconnected.
- **Beacon:** the board's detectors, alerts, radios, offline buffering, firmware updates, and connection status, plus this phone's notifications, Live Mode, and display settings.

**most pins show where your phone heard a signal, not where the device is.** Remote ID drones are the exception, since they can broadcast their own position. the community camera layer is reference data, so a missing pin does not mean there is no camera.

you can **Watch** or mute individual devices, turn on phone notifications per category (they all start off), and check counts at a glance with Live Mode or home-screen widgets. permanent mutes sync to the board. timed and place mutes only apply on the phone, so the board can still sound for that device. both apps support screen readers, larger text, and higher contrast, and are English-only for now.

| platform | requires | install | build from source |
|---|---|---|---|
| iPhone | iOS 18 or newer | [App Store](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) | [iOS README](ios/README.md) |
| Android | Android 8 or newer | [Google Play](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) | [Android README](android/README.md) |

the [app guide](docs/app-guide.md) covers pairing, permissions, sample data, alerts and mutes, tracker evidence, Live Mode, widgets, and accessibility.

## flashing

### production beacon

normal updates come through the app. USB recovery depends on the board revision:

- [rev-A beacon flasher](https://soyboi.tech/flash.html)
- [rev-B beacon flasher](https://soyboi.tech/flash-revb.html)

**never flash one revision's image onto the other, or a DIY image onto a production beacon.** the wrong image can leave the board needing USB recovery.

### DIY OUI-Spy and Mesh-Detect

1. connect the XIAO ESP32-S3 to your computer with a USB-C cable that carries data, not a charge-only cable.
2. open the [DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) in Chrome or Edge and pick the firmware for your board.
3. select the board when prompted and wait for flashing to finish.

the flasher uses Web Serial, so it needs a desktop browser; Safari and Firefox do not support it. the [web flasher docs](web/README.md) cover self-hosting and rebuilding the images.

### flashing from the command line

for firmware development, use PlatformIO:

```bash
cd firmware
pio run -e oui-spy -t upload
# or, for Mesh-Detect:
pio run -e mesh-detect -t upload

pio device monitor -b 115200
```

[platformio.ini](firmware/platformio.ini) defines the shipping, capture, and bench environments. capture builds log nearby identifiers and raw payloads, so keep those logs private and reflash shipping firmware when you are done. `odid-sim` is a Remote ID simulator for bench use only.

<a id="how-the-project-is-organized"></a>

## developer documentation

| location | contents |
|---|---|
| [firmware/](firmware/) | shared detector engine, board entry points, tests, and release tools |
| [ios/](ios/) and [android/](android/) | native apps and system widgets |
| [web/](web/) | the DIY browser flasher and its release manifests |
| [docs/](docs/) | app guide, radio coverage, signature evidence, protocol, mesh setup, and map performance checks |

good places to start:

- the [BLE protocol](docs/ble-protocol.md), for app integration
- the [signature reference](docs/signatures.md), for detector work
- the [release guide](firmware/tools/RELEASE.md), for signing and publishing
- the [map performance checks](docs/map-performance.md), for the shared map regression workload and each platform's benchmark tests
- the [false-positive log](docs/false-positives.md), for vendor matches that turned out to be other hardware

the companion nRF firmware and the beacon's hardware design files are not in this repository.

## project status

the source tree is at **2.1.0** for the ESP32-S3 firmware and **2.1.1** for both apps. published releases can trail the source, so check the app's firmware update screen and the store listings for what is actually available.

the detector, mesh path, apps, and update flows have all been tested on real hardware. field testing continues, especially for the capture candidates. the [OTA protocol](docs/ble-protocol.md#firmware-update-ota) documents the update order.

2.0.7 was a one-time transition release that rotated the OTA signing key. from 2.0.8 on, the source tree signs with the production key only. a board that installed 2.0.7 needs nothing more. a board still on 2.0.6 or older only trusts the retiring key and cannot verify a production-signed image, so read the [key-rotation guide](firmware/tools/RELEASE.md#ota-key-rotation) before you publish a release or update a board that has been offline since the transition.

## license

the project's own **application and ESP32-S3 firmware code** in this repository is licensed under [Apache-2.0](LICENSE). bundled third-party components keep their own licenses; see [CREDITS.md](CREDITS.md) and their license files. keep the applicable [LICENSE](LICENSE), [NOTICE](NOTICE), and third-party notices with any distribution.

the **companion nRF firmware, hardware design, PCB layout, enclosure, manufacturing files, product name, and trademarks are not covered** by that license unless explicitly stated otherwise.

## credits

- the **Colonel Panic OUI-Spy** ecosystem, for compatible hardware and earlier work
- [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c), for Remote ID decoding
- [DeFlock](https://deflock.me) and the independent researchers cited in the [signature reference](docs/signatures.md)

All Cameras Are Beacons is an independent project and is not affiliated with, endorsed by, or sponsored by Colonel Panic. "OUI-Spy" and "Mesh-Detect" are Colonel Panic's product names, used here only to identify compatible hardware.
