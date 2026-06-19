# False positives log

Devices ACAB flagged that turned out not to be Flock. We keep this to spot patterns
(a vendor that shows up repeatedly is a demotion candidate) and to tune signatures
without dropping real cameras. See the "How reliable is it?" section in the README
for why OUI matches are the noisy ones.

When you hit one, note the MAC (or at least the OUI), what the detail screen says it
"Matched on", and what the device actually was. A screenshot of the detail screen
captures all of it.

| Date | OUI | Vendor | Matched on | What it really was | Action |
|---|---|---|---|---|---|
| 2026-06-15 | 08:3a:88 | USI | OUI | Molekule air purifier | candidate, not yet demoted |
| 2026-06-16 | e0:4f:43 | USI | OUI | home security camera | demoted to extended |

## Notes

- USI (Universal Global Scientific) makes WiFi/BLE modules used across consumer
  gear; two confirmed false positives so far, so it is the clearest demotion
  candidate. Both `08:3a:88` and `e0:4f:43` are USI.
- Of the 67 Flock OUIs, only `b41e52` is registered to Flock Safety itself; the
  rest are commodity module makers and consumer brands, which is why OUI-only
  matches need confirming.
- OUI and heuristic changes live in the firmware, so they take effect after a
  reflash from the web flasher, not instantly.
