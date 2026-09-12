# map performance checks

the regression workload is a zoomed-out Map with Desert mode and 4,999 retained detections. on both platforms, detection-driven map rebuilds are coalesced on one row-count ladder (0.3 s under 500 rows, 0.5 s from 500, 0.75 s from 2,000, 1.0 s from 4,000: iOS `mapDetectionRefreshInterval` behind `scheduleDetectionSnapshotRefresh`, Android `mapDetectionRefreshIntervalMs` behind `coalesceDetectionRevisions`), leading edge plus trailing edge so the newest state always lands. a pan, zoom, filter, history-scope or trail toggle change skips that ladder and rebuilds at once, but not the same way on both: Android rebuilds from the last installed evidence snapshot (`locatedEvidence`, keyed on the installed revision) and leaves the ladder's timing alone, while iOS rebuilds through `installFreshSnapshot`, which walks the live store, takes over any pending trailing refresh, and restarts the interval. the projection behind that gate is each platform's own code (`MapTabView.swift` on iOS, `MapProjection.kt` on Android) sharing the same-spot tolerance and the pin priority order. **Recent** defaults to the last 15 minutes; **All history** remains available. history scope changes presentation only, not recording, retained evidence, export, or tracker breadcrumb collection.

the workload was first reported against app 2.0.7 (1) on an iPhone 17 Pro. the source tree has since moved to 2.0.8, so read every recorded figure below as a dated record of the run that produced it rather than as a property of the current build.

## repeatable checks

exercise 500, 2,500, and 4,999 detections, including a mixture of infrastructure, trackers, drones, watched devices, muted devices, and sightings without a reliable time or location. use synthetic coordinates and identifiers for automated fixtures; do not publish real drive logs or exported locations with performance reports.

check both history scopes and each of these states:

- zoomed out, then zoomed in, while the same devices receive repeated RSSI/count updates;
- fresh device arrivals, stronger located sightings, new tracker breadcrumbs, and removal/eviction;
- pan/zoom, category changes, star/unstar, mute/unmute, and opening a detection from the Log;
- community cameras off and on, including crowded map regions and the date line;
- search, New/Offline/category filters, both sort orders, and paused Log exports;
- large text, VoiceOver/TalkBack, and opening/closing Map options and technical details.

unchanged coordinates and membership should not reconstruct clusters on every signal update. new locations and membership must eventually appear, while a direct filter or viewport change should respond immediately. when dense artwork or trails are simplified, the UI must say so and the full retained evidence must remain available. a Recent cutoff must not invent a capture time for an undated offline row.

## automated measurements

name the suites you ran. a whole-suite pass count cannot be checked against the tree it shipped with and goes stale on the next test added, so it is not a useful record; the map work lives in iOS `MapPinRulesTests` and Android `MapProjectionTest`, and a report should say those passed rather than quote a total.

the iOS `MapPinRulesTests` includes dense-fixture membership/work-count checks and `testDenseProjectionWallClockBenchmark500Rows`, `testDenseProjectionWallClockBenchmark2500Rows`, and `testDenseProjectionWallClockBenchmark4999Rows`. these time **only the cluster-building stage**, with fixture construction excluded. they do not time the whole map snapshot, MapKit rendering, or incoming detection processing.

**no current iOS baseline is recorded here.** a September 4, 2026 Debug run in the iPhone 17 / iOS 26.5 simulator did record a five-iteration average per fixture, but the dense fixture has been rebuilt since: `denseSeeds` in `MapPinRulesTests` now lays each row on a distinct coordinate of a 100 x N lattice and cycles four categories, where it previously stacked every seed on one coordinate with one category. that produces 26 / 91 / 169 clusters for 500 / 2,500 / 4,999 rows instead of a single bucket, so a time taken against the earlier fixture measures different work and is not a valid comparison point. those averages are therefore not carried forward. record a fresh local baseline before using these benchmarks for any before/after claim, and keep the host, build, and cluster counts beside it.

the full iOS projection also emits `MapProjection` intervals in the `MapPerformance` signpost category, and `MapALPRQuery` separately times indexed reference-layer queries. the **intervals ship in Release**, so an Instruments trace of a Release build still shows how many projections ran and how long each took. their **count arguments are DEBUG-only** (`rows` on begin; `scoped`, `represented`, `markers`, `merged`, `culled`, `dropped`, and `vertices` on end, plus `nodes` and `visible` for the reference-layer query), because signpost arguments are written to the OS unified log, which the app cannot clear. neither form carries a device identifier or a coordinate.

run the suite from the repository root after generating the Xcode project:

```sh
xcodegen generate --spec ios/project.yml
xcodebuild test -project ios/Beacons.xcodeproj -scheme Beacons \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

Xcode's test report stores the clock metrics. for command-line reports, use `xcrun xcresulttool get test-results metrics --path <result.xcresult>`.

Android's `MapProjectionTest` covers the same row counts, plus cache identity, history expiry, date-line culling, and drone/operator preservation. its five-run JVM benchmark times culling and grouping, excluding fixture creation and equality assertions. the run recorded for this doc on September 4, 2026 passed `:app:testDebugUnitTest` in full together with the debug build and lint, and averaged 0.490 ms / 1.212 ms / 2.109 ms for 500 / 2,500 / 4,999 rows. the host was not recorded, so treat those as rough JVM output rather than a threshold and note your machine beside any new figures.

that fixture still produces 138 / 144 / 153 symbols with no omitted rows for the three row counts, so the Android figures above still describe the workload in this tree. `verifyDenseProjection` pins the density from both ends, because a grid collapse into a few bubbles would leave the visit and membership assertions intact while printing a faster benchmark; its comment records the same three counts, so retune the test and this doc together. this is a different workload/stage from the iOS benchmark and must not be used to compare platform speed. Android prints `MAP_PROJECTION_BENCH` in the unit-test report. added after the run recorded above, `recentScopeComparesAgainstWallClockNotTheInvalidationTick` pins the Recent scope to a wall-clock read rather than the Map screen's 30-second invalidation tick; it is a correctness check on scope membership, not a timing one, and it is not in the figures above. the coalescing tests added with the Android ladder (`detectionRefreshLadderMirrorsIos`, `detectionRefreshWaitIsZeroWhenIdleAndTheRemainderOtherwise`, `detectionBurstInstallsItsFirstAndLastRevisionsOnly`) are likewise correctness checks and not in the figures; the burst test waits on real time and adds about 0.7 s to the suite.

```sh
cd android
./gradlew :app:testDebugUnitTest :app:assembleDebug :app:lintDebug
```

## physical-device profiling

unit-test timings measure projection work, not MapKit/osmdroid frame rate, battery use, or actual Bluetooth/GPS load. simulator screenshots likewise cannot establish iPhone smoothness. before release, profile a Release build on the affected phone with the same workload and compare it with the previous build under the same conditions.

on iOS, use Instruments' SwiftUI, Time Profiler, Hangs, and animation-hitch tracks. record the number and duration of map-projection updates, main-thread work during pan/zoom, frame hitches, peak memory, and energy impact during a sustained live session. test community cameras separately so dataset work is distinguishable from detected-device work. on Android, use System Trace and the memory profiler for the equivalent checks.

report the build, phone/OS, history scope, retained and mapped counts, zoom level, reference-layer state, and whether the data was replayed or received live. do not claim a device-level speedup from projection-only benchmark results.

the prior session record is [the 2026-09-04 Android UI QA notes](android-ui-qa-2026-09-04.md). it is an emulator pass, and it says so: its frame-pacing sample is a short debug-emulator smoke test, not a phone benchmark and not evidence that the reported zoomed-out 4,999-detection Desert-mode slowdown is resolved. it is kept as a dated record of one build, identified by APK hash, so read it as history rather than as a current baseline.
