# False positives log

Vendor matches that turned out to be other hardware. This started as a Flock-only
list and is no longer limited to Flock, or to matches a user ever saw: a capture-build
identifier that resolves to an unrelated vendor belongs here too, because the reason to
record it is the same. We keep this to spot patterns (a vendor that shows up repeatedly
is a demotion candidate) and to tune signatures without dropping real cameras. See the
"How reliable is it?" section in the README for why OUI matches are the noisy ones.

When you hit one in the app, note the MAC (or at least the OUI), what the detail screen
says it "Matched on", and what the device actually was. A screenshot of the detail
screen captures all of it. For a capture-build identifier there is no detail screen, so
record the assigned number, the runtime tag, and where the evidence lives.

| Date | Identifier | Vendor | Matched on | What it really was | Action |
|---|---|---|---|---|---|
| 2026-06-15 | 08:3a:88 | USI | OUI | Molekule air purifier | removed from the tables (deliberately excluded; see signatures.md) |
| 2026-06-16 | e0:4f:43 | USI | OUI | home security camera | removed from the tables (deliberately excluded) |
| 2026-09-04 | `0x087F` (SIG company ID, tag `PCAM-CID`) | Phillips Connect Technologies LLC | Bluetooth SIG company ID, capture builds only | trailer telematics (smart-trailer gateways and cargo sensors), not a camera | stays capture-only; never promoted to a detector, never reaches either app. Evidence in `docs/captures/vendor-cid-087f-2026-09-04.txt`; row and caveats in signatures.md |

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
