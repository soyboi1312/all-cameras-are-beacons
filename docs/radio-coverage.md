# radio coverage

beacons can recognize a device only when it receives a supported broadcast. match confidence describes the evidence in a received signal; radio coverage describes the opportunity to receive it. a quiet screen does not establish that you are unwatched.

## Wi-Fi coverage

the ESP32-S3 listens on **2.4 GHz only**. it cannot hear 5 GHz traffic, and it listens to one Wi-Fi channel at a time.

all shipping boards use the same channel-hopping sequence. it returns to channel 6 between visits to the other channels to favor brief Wi-Fi Remote ID broadcasts:

| channel | slots per sweep | nominal share of the active sweep |
|---|---|---|
| 6 | 12 of 24 | 50 percent |
| each of 1–5 and 7–13 | 1 of 24 | about 4.2 percent |

these are scheduling shares, not reception probabilities. a camera broadcasting on channel 11 during a brief drive-by can be missed while the scanner listens elsewhere. interference, range, obstructions, and the transmitter's timing also affect reception.

battery-saver eco mode inserts **3, 7, or 15 seconds** with Wi-Fi reception disabled between sweeps. zero disables that extra pause. this trades Wi-Fi coverage for runtime without pausing Bluetooth scanning. diagnostic capture builds ignore eco mode so it cannot create intentional gaps in a capture.

the schedule and eco behavior are defined by `WIFI_HOP_SEQ`, `wifiHopTask`, and `acabScannerSetWifiEco` in [acab_scanner.cpp](../firmware/lib/acab_core/acab_scanner.cpp).

### the 5 GHz gap (measured, open)

the 2.4 GHz limit above is a real coverage hole, and it has been measured rather than assumed. a
dual-band ESP32-C5 bench sniffer (`firmware/tools/c5-sniff`) ran a ~27 minute capture hopping both
bands (`firmware/tools/detection logs/c5-lvt.log`); neither path is in the public repository. the
sniffer's `[diag]` counters are cumulative since boot, and the first `[diag]` line in the file, two
seconds after it opened, read up=297s, so the frame columns below are in-window deltas: the last
in-capture `[diag]` line (up=1901s) minus that first one.

the channel column counts channels the capture shows producing frames since boot. on 5 GHz it is
not the heartbeat's own `ch=` figure, because above channel 48 that figure is not a measurement.
the per-channel counter (`chan_hit` in `BandStat`) has 64 slots indexed by channel number, and
`sniff_cb` counts a frame there only when the channel is below 64, so it counts 36, 40, 44 and 48
and never 149 to 165. for those five channels `hop_task` reads past the end of that array into the
5 GHz BSSID set, so the 5 GHz `ch=` can credit channels no counter saw, and it rose from 4 of 9 to
9 of 9 in step with that set filling: `aps` read 209 on the first line and 887 on the first line to
show 9 of 9. what the capture does show: on 2.4 GHz, all 11 counters, which already read 11 of 11 on
the first line; on 5 GHz, the four counters for 36 to 48, which must all be nonzero for `ch=` to
reach 9 of 9, plus per-sighting lines that tag camera-OUI frames on 149, 153, 157 and 161 inside
the window. nothing shows channel 165 producing a frame. the log holds no `set_channel(N) FAILED`
line, so the driver accepted every hop to 165 in the window, but a channel the radio tuned to is
not a channel shown receiving.

| band | frames in the window | channels shown producing frames (since boot) | ALPR (Falcon) frames | camera-OUI frames |
|---|---|---|---|---|
| 2.4 GHz | 22,646 | 11 of 11 | 1 (see below) | 285 |
| 5 GHz | 39,719 | 8 of 9, none shown on 165 (see above) | **0** | 32 |

those last two columns are FRAME counts, not device counts, which is a distinction worth keeping:
32 frames could be one camera heard 32 times. the per-sighting log lines carry a band tag, so the
device count is recoverable. the table below counts distinct MACs on the capture's `[wifi]` lines,
grouped by band tag, camera-vendor OUIs only: the capture also holds one Falcon-OUI MAC (2.4 GHz,
the probe-response row), which is left out of these rows and discussed in the ALPR note below.

| | distinct camera-vendor MACs |
|---|---|
| heard on 2.4 GHz only | 48 |
| heard on **5 GHz only** | **17** |
| heard on both | 2 |

a MAC on a `[wifi]` line is not always the radio that sent the frame. the sniffer checks addr1 (the
receiver), addr2 (the transmitter) and addr3 in that order, logs the first field whose OUI is on
its lists, and tags the line `a1`, `a2` or `a3`. a line tagged `a3` therefore means neither the
receiver nor the transmitter matched. in a data frame addr3 names the frame's final destination,
its original source, or its network, and on an `a3` line it is not the radio that sent it. on 5 GHz
the lines hold every camera-OUI frame the sniffer received, not a sample: the 32 camera-OUI frames
in the window are exactly the 32 `[wifi]` lines tagged 5G, every one from an address that never
won a slot in the sniffer's 16-entry hit table and so was printed on every frame. none of them
matched on addr1 and the 5 GHz Falcon count is 0, so no camera-vendor transmitter hid behind an
earlier match. read that way, the 17 split like this:

- **3 were the transmitter** (`a2`) of 5 GHz frames, 8 frames between them, and the frame TYPE is
  not the same across the 3, which is what decides whether the board's rule could have read the
  address. `t=` on these lines is frame-control byte 0, so it gives the type. one of the 3, an Arlo
  beacon (`t=0x80`), is one address step from an Arlo MAC that beaconed on 2.4 GHz two seconds
  later, which fits a single dual-band base station that a 2.4 GHz receiver can hear. the other 2
  were one frame each: a Wyze beacon (`t=0x80`) at -92 dBm, and a Ring null-function DATA frame
  (`t=0x48`) at -89 dBm. a mgmt frame's source is always addr2. a data frame's is addr2, addr3 or
  addr4 depending on the DS bits in frame-control byte 1, which this sniffer does not log, so the
  Ring line carries the same ambiguity as the 14 below.
- **14 appear only as addr3 in data frames.** a radio that matched no listed OUI sent every one of
  those frames, so they show traffic naming that address crossing a 5 GHz network, not the device's
  own radio, which could be on 2.4 GHz, on a cable, or on 5 GHz without the sniffer catching one of
  its frames. that does not place them outside what a board detects; see the network-camera
  finding below.

the 2 MACs heard on both bands are the same case: each was only ever addr3, and each turned up on
2.4 GHz within ten seconds of its 5 GHz sighting.

put as a comparison rather than a bare number: of 67 camera-vendor MACs in that capture, excluding
the one Falcon-OUI MAC, 17, about a quarter, appeared only in 5 GHz frames. that is a count of
addresses, so it is a ceiling on the camera-vendor devices only a 5 GHz receiver would have
detected, not a measure of them. held to the test the ALPR note below applies to the Falcon row,
which counts only transmitters, the capture shows **2** camera-vendor devices transmitting only on
5 GHz, one frame each, or 3 if the Arlo radio above counts as its own device. the same test finds
at least 25 of the 48 MACs heard only on 2.4 GHz transmitting there; "at least" because a 2.4 GHz
frame can hide a camera-vendor transmitter behind an addr1 match, and the 3 addresses there that
held hit-table slots print at most one line every 5 seconds. that transmitter count is NOT the
number of cameras a 5 GHz receiver would have detected, and it is not a floor on it either. it can
run low, because the board's camera rule does not require the camera to be the transmitter. it can
also run high, because on a DATA frame an `a2` tag only says addr2 held a camera OUI, while the
board reads addr2 as the source only when the DS bits allow it. the network-camera finding below
works both ends, and says why this capture cannot pin down where between 1 and 17 the count lies.

the distinct-AP counters are not in that table on purpose: both bands saturated the sniffer's
approximate 1,024-entry BSSID set (`BSSID_SET_N`), so 1024 is the cap, not a population. what the
capture does establish is narrower, and worth stating exactly: the 5 GHz RECEIVE PATH was
demonstrably live, at 39,719 frames inside the window, with frames shown on eight of the nine
sampled channels on the basis above. an instrument that cannot be shown to have been receiving
cannot report a meaningful zero, so this clears the first hurdle on those eight channels, and not
on 165. it does not clear the second one on any channel, which is whether anything was there to
hear. see the ALPR note below.

two findings:

- **the ALPR question is NOT settled by this capture, and the table above must not be read as if it
  were.** the 5 GHz zero only carries meaning against a positive control, that is, a Falcon known to
  be present and transmitting. there was not one. the lone 2.4 GHz row is not a control either: it
  decodes as `t=0x50 a1`, one probe RESPONSE at -89 dBm matched on addr1, the DESTINATION field. a
  probe response answers a probe request, so a device holding that Falcon-OUI address did transmit
  on 2.4 GHz moments earlier, but the sniffer never received that frame, and the Falcon OUIs are
  Liteon blocks that a capture ties to a Falcon site rather than to a Falcon's radio (see
  [signatures.md](signatures.md)). so both bands recorded zero Falcon transmissions, and one
  inferred probe from an address that need not be a Falcon rules out none of "switched off
  fleet-wide", "moved to 5 GHz with none in range", and "never used 5 GHz at all". settling it
  needs a capture taken beside a Falcon confirmed powered and present, listening on both bands at
  once. that capture has not been taken. note also that the sniffer covers non-DFS 5 GHz channels
  only, so UNII-2 and UNII-2e were never swept, and of the channels it did sweep, nothing shows 165
  receiving, so no proof of life backs the 5 GHz zero there.
- **network cameras are in the gap too, by a count this capture cannot pin down.** camera-vendor
  radios did transmit on 5 GHz where a shipping board cannot hear them: 2 devices, one frame each,
  plus a third radio that fits a base station also heard on 2.4 GHz. that is a transmitter count,
  and the detection floor worked out below is lower than it, not higher. the other 14 addresses
  heard only on 5 GHz were never the transmitter of a frame the sniffer caught, and that does not
  take them out of the gap, because the board's own source-address rule (`netcamClassifyWiFi` in
  [netcam_detect.cpp](../firmware/lib/acab_core/netcam_detect.cpp)) does not require the camera to
  be the radio that sent the frame. in a data frame with fromDS set and toDS clear, an AP relaying
  traffic to a station, it reads addr3 as the source and matches that against the camera vendor
  list, and when network-camera detection is on, a match there raises a detection for that address.
  in other directions addr3 is not the source, for example the destination in a frame a station
  sends to its AP, and the rule does not count it. this sniffer does not log frame-control byte 1,
  whose DS bits say which case a frame is, so each of the 14 may be a camera's relayed traffic that
  a board would report if it heard the frame, or a frame that names the camera as its destination
  or its network, which it would not. the capture therefore puts the camera-vendor devices only a
  5 GHz receiver would have detected somewhere between 1 and 17. the floor the capture establishes
  is 1, and it is the Wyze line: `t=0x80` is a mgmt frame, `netcamClassifyWiFi` reads addr2 as the
  source on a mgmt frame whatever the DS bits say, that OUI is a plain row in `CAMERA_VENDOR_OUI`,
  and no OUI table ahead of it on the mgmt path holds that block, so a dual-band board with the
  network-camera detector turned on would have named it. that detector is opt-in and off by default
  on every shipping build: `netcamRestoreEnabled(false)` runs at boot in
  [beacon-board/main.cpp](../firmware/src/beacon-board/main.cpp), the source oui-spy and the beacon
  board share, and in [mesh-detect/main.cpp](../firmware/src/mesh-detect/main.cpp), and the `netcam`
  row of [ble-protocol.md](ble-protocol.md) records the same default. so a board left as it ships
  names no network camera on any band until the user turns that detector on in the app. against a
  real board neither app seeds it on: `netcamOn` starts false in
  [SettingsView.swift](../ios/Beacons/Views/SettingsView.swift), and in
  [DeviceScreen.kt](../android/app/src/main/java/tech/acab/app/ui/DeviceScreen.kt) it starts from
  the board's own `ncam`, which both status decoders read as false when the key is absent, and the
  only writers are the two user-facing controls. the one place either app shows that detector on is
  the guided sample tour, whose canned status frame sets `ncam` true on both phones, so a reader who
  checks this in sample mode sees the opposite of what a real board reports. the Ring
  `a2` line does not stand beside it at the floor: `t=0x48` is a data frame, and the byte 1 the
  sniffer never logged leaves its source field as open as the 14, so it sits in the unresolved
  middle with them, for the same reason they do. the Arlo sits in that middle for a different
  reason, device identity rather than frame direction: its frames are beacons, so the rule would
  read them, but the Arlo MAC one address step away on 2.4 GHz says a 2.4 GHz board may hear that
  base station anyway. the ceiling of 17 is that floor plus those 2 plus the 14 addr3 addresses.
  that stays unresolved until a capture logs frame-control byte 1. 802.11 address fields are sent
  in the clear even under WPA, so a 5 GHz receiver could run the same source-address OUI match the
  2.4 GHz netcam path uses. one caveat on the size of the prize: 5 GHz carries less far and through
  fewer walls than 2.4, so this is a parked or walking capability more than a drive-by one.

closing this needs a dual-band receiver. the ESP32-S3 has no 5 GHz PHY, so it cannot become one,
which makes this a hardware question rather than a firmware one. the C5 sniffer already runs a
netcam OUI list generated from `netcam_signatures.h`, though the copy lags the header: all 180 of
its blocks are in `CAMERA_VENDOR_OUI`, which now holds 194, and it matches any of the three
address fields rather than the board's source-address rule. what is not settled is whether a second
radio belongs in the product, in a companion, or stays a bench tool.

## Bluetooth coverage

- **OUI-Spy and Mesh-Detect** share the ESP32-S3 radio between Bluetooth scanning, Wi-Fi, and the phone link. the configured Bluetooth scan window is 67/131 of each interval, about **51 percent**. there are also short pauses between scan runs, so this is not a measured guarantee of listening time.
- **the dual-radio beacon** gives Bluetooth scanning its own nRF52840, configured to scan continuously while enabled. it does not pause for the ESP32-S3's Wi-Fi channel hops. continuous scanning still does not guarantee that every broadcast arrives or produces a detection.

the single-radio settings and scan loop are in `acabScannerBegin` and `bleScanTask` in [acab_scanner.cpp](../firmware/lib/acab_core/acab_scanner.cpp). the dual-radio selection is defined by `ACAB_DUAL_RADIO` in [platformio.ini](../firmware/platformio.ini) and `setup` in [main.cpp](../firmware/src/beacon-board/main.cpp).

## offline log admission

hearing a device is not the same as keeping it. while the phone is away, the offline log stores matched devices at a limited rate: a burst of 256, then one every 10 seconds, with the last 32 of those kept for devices heard for at least 10 seconds. this stops a nearby transmitter that invents fake camera or drone identities from overwriting the log in minutes; a full overwrite now takes about 67.6 hours. the densest real scenes captured so far sit well inside the limit (at most 34 new matched devices in any 10 minutes, on a residential drive with network cameras on). if the limit ever turns a detection away, the board keeps a flag that survives reboots, and the app shows `DETECTION FLOOD REFUSED` until the buffer is cleared.

the numbers and their evidence are in `DET_LOG_RATE_*` in [det_log.h](../firmware/lib/acab_core/det_log.h).

return to [how much does it actually hear?](../README.md#how-much-does-it-actually-hear).
