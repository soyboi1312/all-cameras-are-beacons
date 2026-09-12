# Android UI QA - 2026-09-04

## Environment

- Android 16 / API 36, arm64 QEMU AVD `beacon_play_36` (`emulator-5554`).
- 1440 × 3120, density 560; portrait and landscape; font scales 1.0 and 2.0.
- Navigation used user-authorized adb input, UIAutomator hierarchy dumps, and screenshots.
- Installed debug APK with `adb install -r`; no uninstall, data clear, or new location/Bluetooth permission grant.
- Final APK SHA-256: `95b867900dd4a0d8441c99586e9899f658cc659522b76b4a3ca944bf451b1d55`.
- Functional UI checks used the app's six fictional sample detections (five have map positions), not a live beacon.
- This UI session tested app version 2.0.7 / version code 27, before the subsequent 2.0.8 version bump; the APK hash above identifies the tested build.

## Results

| Area | Observed result |
| --- | --- |
| Status | Matched and ambient totals are separate; the 14-dot limit and strength-only/no-direction explanation are visible. Strongest-device name and sample timing are readable. |
| Detector off | Fixed a sample-only cross-tab state bug. Turning Trackers off now preserves the count of one, adds the OFF badge and accessibility description, and still opens the retained tracker in Log. Retested on the final APK. |
| Radio state | Sample Bluetooth off gives the Wi-Fi-only summary; both radios off gives `SAMPLE DATA · RADIOS OFF` on Beacon and on Status. The tested build labelled the Beacon tab `SAMPLE · ALL RADIOS OFF`; the 2026-09-08 rename gave both tabs the one literal (`beaconRadioStatusLabel` in DeviceScreen.kt). |
| Beacon organization | Hardware controls precede the separate phone-preference group. Controls remain usable at 2× text and in landscape. Sample/firmware labels do not claim a live connected board. |
| Watched filters | Starring the sample tracker adds a conditional Watched filter to Log and Map. Filtering preserves its Tracker category. Removing the last star removes the filter and returns Log to all six rows. |
| Log detail | Tracker details and its existing map position open correctly. The sample does not contain a real breadcrumb history. |
| ALPR callout | Visually verified white/light text on an opaque dark callout, including the distinction between a mapped camera location and a live detection. |
| Large text | Status counts, strongest-device details, and Beacon controls wrap readably at 2× text. Fixed the Map location-hint heading overlapping its dismiss control; visually retested on the final APK. |
| Map interaction | Eight pan gestures completed with the community-camera layer visible; the app remained responsive and no app crash appeared in the sampled runtime logs. |

## Automated validation

The final Android command `:app:testDebugUnitTest :app:assembleDebug :app:lintDebug` passed: **288 tests**, no failures/errors/skips; lint **0 errors**, 105 warnings and 8 hints. Added regressions cover all ten sample radio/detector echoes and retained tracker counts. `git diff --check` passed.

## Performance interpretation and remaining physical tests

After resetting graphics counters, the eight-pan sample run recorded 241 frames, five deadline misses (2.07%), and 18 ms at the 95th and 99th percentiles. This is a short debug-emulator smoke test, not a phone benchmark or evidence that the reported zoomed-out 4,999-detection Desert-mode slowdown is resolved. The existing 4,999-row projection unit test exercises data selection only, not on-device rendering.

Still requiring a physical-device/live-data test: sustained high-volume Desert-mode ingestion and zoomed-out rendering, strongest-RSSI location updates from real sightings, breadcrumb collection and mute behavior during a live route, Bluetooth reconnects, and actual firmware update progress/failure recovery.

## 2026-09-06 addendum: reproduction steps, not a run

Two Map behaviours changed after the session above, and neither is covered by it or by any
automated test that can reach the composable call site. **Nothing in this section has been
observed.** These are steps to run on the next device or emulator pass; record the result beside
them then, and do not read them as results now.

- **Recent-scope clock.** With **Recent** selected on Map, leave the tab idle long enough for its
  30-second invalidation tick to fire, then have the board report a device. Expected: the new row
  appears in Recent on the next recomposition, not up to 30 seconds later, and **All history**
  shows the same row. `MapScreen` keeps `historyNow` as an invalidation tick only; the comparison
  clock is read inside `recentScopeIds` (`recentScopeClock` in `MapProjection.kt`), which
  `MapProjectionTest.recentScopeComparesAgainstWallClockNotTheInvalidationTick` pins. The unit test
  exercises the helper, not the screen that calls it, so this step is what checks the wiring.
- **Permission flags across the shared tab shell.** With Location denied, open **Map**, tap
  **ALLOW** on the location banner, and grant from the system dialog. Expected: the banner clears
  and the Beacon tab's system-readiness card flips its `Location context` row from `OPTIONAL` to
  `ALLOWED`, without leaving the app, rotating, or force-stopping it. `MainScreen` carries
  `reconnecting`, `locationGranted` and `notificationsAvailable` into its once-remembered
  `movableContentOf` through
  `rememberUpdatedState` holders; a plain capture would freeze them at first composition, and a
  runtime grant does not recreate the activity, so a frozen flag leaves the banner up over a map
  that is already positioning. This tree has no `androidTest` source set, so nothing automated
  covers it.

## Cleanup and evidence

Exited sample mode back to the connection screen. Temporary system changes were restored and read back: font scale 1.0, auto-rotation 1, user rotation 0; no size/density overrides. No real managed-device lists or detection history were edited. The debug APK remains installed and QEMU remains available.

Local screenshots are retained in `/tmp/acab-android-ui-eSh5hN`, including `alpr-callout.png`, `status-off-fixed.png`, `map-large-fixed.png`, and `beacon-landscape.png`. This temporary directory is not a committed test fixture.
