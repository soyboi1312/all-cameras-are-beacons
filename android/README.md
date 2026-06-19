# All Cameras Are Beacons, Android

Native Kotlin + Jetpack Compose companion for the OUI-Spy ACAB board, the Android
counterpart to the iOS app in `../ios`. It talks to the same firmware over the
same encrypted BLE GATT service (`../docs/ble-protocol.md`).

## Status

Working end to end. Done:
- Gradle/Compose project, runtime permissions, the full Crimson theme.
- BLE layer (`ble/AcabBleManager.kt`): scan by service UUID, connect, **bond**
  (the GATT service is encrypted as of firmware 0.2.2/0.2.3), subscribe to the
  detection + status notifies, parse the JSON, write config.
- Models (`model/Models.kt`) matching the firmware `t`/`s`/`meth` fields.
- Four-tab UI: status, an osmdroid (OpenStreetMap) map, log, and device controls.
- Tap a detection for its detail card: a signal-strength history, first-seen and
  last-seen timestamps, and identifiers, with the chart greying out when a device
  goes stale. The phone's location is geotagged onto fixed-install hits.

Still TODO:
- A real launcher icon (currently the `@android:drawable/ic_dialog_map`
  placeholder; swap it in before any public release).
- Log export, and getting onto the Play Store (see below).

## Build & run

You need **Android Studio** (it bundles the SDK, a JDK, and Gradle):

1. Android Studio, **Open**, select this `android/` folder.
2. Let it run Gradle sync (first sync downloads Gradle 8.11.1 + the SDK).
3. **Run on a physical phone.** The emulator has no Bluetooth, so BLE needs a real
   device with USB debugging on.
4. On first connect the phone prompts to pair ("just works", no passkey). Accept
   it; the bond is remembered after that.

From the command line, with a JDK 17+ on `JAVA_HOME` (on macOS, Android Studio's
bundled JBR at `/Applications/Android Studio.app/Contents/jbr/Contents/Home` works)
and the SDK on `ANDROID_HOME`:

```bash
./gradlew :app:assembleDebug
```

The installable APK lands at `app/build/outputs/apk/debug/app-debug.apk`; push it
to a plugged-in phone with `adb install -r app/build/outputs/apk/debug/app-debug.apk`.

`applicationId` = `tech.acab.app`, `minSdk` 26, `targetSdk` 35.

## Shipping a real APK

The debug build above is signed with a throwaway debug key, fine for your own phone
but not for sharing widely or for the Play Store. For a real release:

1. **Make a signing key once** and keep it safe (you reuse it for every update):
   ```bash
   keytool -genkey -v -keystore acab-release.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias acab
   ```
2. Point Gradle at it: add a `signingConfig` to `app/build.gradle.kts` that reads
   the keystore path and passwords from `~/.gradle/gradle.properties` or env vars,
   so no secrets land in git.
3. Build the artifact:
   - `./gradlew :app:assembleRelease` for a signed **APK** to sideload or hand out.
   - `./gradlew :app:bundleRelease` for an **AAB**, the format the Play Store wants.

Getting it onto the **Play Store** also needs a one-time **$25** Google Play
developer account, a store listing (a real icon, screenshots, description, privacy
policy), and a data-safety form. The listen-only, BLE-only design keeps that form
short, but the **ACAB** name may draw review scrutiny, same as on iOS.

## Notes

- Reflashing the board with **erase** wipes its bond; after that the phone must
  "Forget This Device" in Bluetooth settings and re-pair. Flash without erase to
  keep the pairing (same as iOS).
- The map uses osmdroid against OpenStreetMap tiles, so there is no Google Play
  Services dependency and no map API key to register for.
