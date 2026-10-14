# False positives log

Vendor matches that turned out to be other hardware. This started as a Flock-only
list and is no longer limited to Flock, or to matches a user ever saw: a capture-build
identifier that resolves to an unrelated vendor belongs here too, because the reason to
record it is the same. We keep this to spot patterns (a vendor that shows up repeatedly
is a demotion candidate) and to tune signatures without dropping real cameras. See the
[confidence](../README.md#confidence) section of the README for why OUI matches are the noisy ones.

When you hit one in the app, note the MAC (or at least the OUI), what the detail screen
shows on the "matched on" row under MATCH QUALITY, and what the device actually was. A screenshot of the detail
screen captures all of it. For a capture-build identifier there is no detail screen, so
record the assigned number, the runtime tag, and where the evidence lives.

| Date | Identifier | Vendor | Matched on | What it really was | Action |
|---|---|---|---|---|---|
| 2026-06-15 | 08:3a:88 | USI | OUI | Molekule air purifier | removed from the tables (deliberately excluded; see signatures.md) |
| 2026-06-16 | e0:4f:43 | USI | OUI | home security camera | removed from the tables (deliberately excluded) |
| 2026-09-04 | `0x087F` (SIG company ID, tag `PCAM-CID`) | Phillips Connect Technologies LLC | Bluetooth SIG company ID, capture builds only | trailer telematics (smart-trailer gateways and cargo sensors), not a camera | stays capture-only; never promoted to a detector, never reaches either app. Evidence in `docs/captures/vendor-cid-087f-2026-09-04.txt`; row and caveats in signatures.md |
| 2026-06-18 | random BLE address with a bare 10-decimal-digit name | none (a name pattern, no vendor) | BLE name, the bare 10-digit form | a phone or gadget advertising a placeholder numeric name | the bare 10-digit rule was removed (`nameMatch` in `flock_detect.cpp`); `Penguin-`+digits, `FS-`+hex, the `FS Ext Battery` literal, `0x09C8` and `B4:1E:52` stay |
| 2026-07-23 | `4C:CC:34` (x15), `10:74:6F` (x10), `B8:E2:8C` (x2) | Motorola Solutions | OUI (Wi-Fi), body-cam detector | all 27 of 27 Motorola Wi-Fi OUI hits at one indoor site were fixed ceiling and infrastructure gear, not body cams (the 3 Axon BLE hits in the same 45 rows were real officers) | the body-cam category stays on by default; the broad Motorola OUI match became its own opt-in sub-toggle (config `motorola`, status `moto`; default off, conf 45), so these blocks fire only when a user turns it on; the blocks stay because the vendor read is correct (`bodycam_vendor_signatures.h`) |
| 2026-07-31 | `0x01AB` (SIG company ID) | Meta Platforms, Inc. | BLE manufacturer company ID, glasses detector | a Meta device that was not glasses, heard the same day the worn-glasses capture confirmed `0x01AB` on real frames | row stays on at conf 45 (weak match): a company ID names the vendor, not the type (`glasses_signatures.h`) |
| 2026-09 (own drive logs) | DJI vendor-OUI blocks (e.g. `9C:5A:8A`, an `OsmoAction6`-named unit) | DJI | MAC OUI, the opt-in `droneoui` fallback (conf 60, "DJI gear, no Remote ID") | 12 DJI Osmo handheld cameras and a Hasselblad camera, against one named drone | the fallback stays opt-in (default off) under the drone toggle, and Desert mode does not force it (`droneClassifyBLE` in `drone_detect.cpp`) |
| 2026-09-11 | `0xFEB8` (SIG member service UUID) | Meta Platforms, Inc. | 16-bit service UUID, glasses detector | two `Quest 3`-named adverts from two random addresses 42 minutes apart (one or two headsets; the capture does not say), each carrying 0xFEB8 and no manufacturer data, at conf 45 | row stays at conf 45 (weak match); evidence in `docs/captures/911-2026-09-11.txt` |

## Notes

- USI (Universal Global Scientific) makes WiFi/BLE modules used across consumer
  gear; two confirmed false positives so far, so it is the clearest demotion
  candidate. Both `08:3a:88` and `e0:4f:43` are USI.
- The old ~67-OUI "superset" was dropped; of that set only `b41e52` was registered
  to Flock Safety itself, and the rest (commodity module makers and consumer brands)
  drove the field false positives. Today's tables ship one Flock OUI (`b41e52`) plus
  four probe-request-gated Falcon (Liteon) OUIs, which is why OUI-only matches still
  need confirming.
- The `0x087F` entry never reached a user. It is a capture-only row in
  `firmware/lib/acab_core/vendor_capture.h`, compiled into the two capture
  environments alone, so it created no detection and no alert; it is logged here
  because the question it was added to answer ("who makes this family?") came back
  with an answer that is not a camera vendor. The advertised name `PCAM_*` is a
  vendor-chosen label and is not evidence of a camera. The registrant resolution is
  from an external copy of the SIG list and has to be re-confirmed against the
  assigned-numbers list before the row is quoted anywhere else.
- OUI and heuristic changes live in the firmware, so they take effect after a
  reflash from the web flasher, not instantly.
- `FS-100`-style white-label names and a `Flock-Party`-shaped hotspot are structurally
  excluded since 2026-10-11, not confidence-capped: the `FS-` BLE name and the `Flock-` SSID
  both need a hex-only tail of at least four digits (`FLOCK_HEX_TAIL_MIN` in
  `flock_signatures.h`), so neither shape can appear in this table again.
