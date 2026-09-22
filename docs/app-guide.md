# app guide

the iPhone and Android apps connect to the beacon, OUI-Spy, or Mesh-Detect and show what the board hears. live detection requires a board; sample data and your saved Log remain available without one. see the [project overview](../README.md) for supported hardware and detection limits.

install from the [App Store](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) for iOS 18 or newer, or [Google Play](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) for Android 8 or newer. both apps currently use English. developer instructions are in [ios/README.md](../ios/README.md) and [android/README.md](../android/README.md).

## try it or connect a board

tap **See how it works** to explore six fictional detections. sample settings do not configure hardware, and sample rows never enter your real Log. tap **Exit sample data** to restore your saved data and settings. the sample walkthrough does not replace the orientation shown after your first real connection.

to connect:

1. power the board and keep it near your phone, with Bluetooth on.
2. grant the requested connection access, tap **Scan for beacons**, choose the board, and approve the system pairing prompt.
3. finish the walkthrough and review the permission and readiness prompts.

connection needs Bluetooth access on iPhone, Nearby devices on Android 12 or newer, or Location on Android 8 through 11. newer Android versions and iPhone let you decline Location and still detect and keep a Log. location adds observation pins and place mutes; iPhone also requires it to start Live Mode. Android Live Mode does not request background Location.

make the first pairing in trusted surroundings: an unowned board accepts its first phone at any time. already-bonded phones can reconnect normally. a new phone can pair only during the two-minute window after a physical power-on. turn the board off and on to reopen it; a firmware-update restart does not reopen the window.

## read the results

- **Status** counts devices heard in roughly the last 45 seconds, with matched/watched devices separated from Desert-mode ambient radios. an unfamiliar firmware category appears separately as **unclassified**, not as an ordinary nearby device. the radar draws at most 14 dots, prioritizing stars and recognized matches; its total still includes every recent, unmuted device. a detector switched off keeps its recent count and adds an **OFF** label. tap a nonzero category count for its Log, or an empty disabled category for its detector setting.
- **Log** keeps sightings on your phone while disconnected. search names, vendors, or full/partial hardware addresses; combine the search with category and New/Offline filters; and sort by newest or strongest signal. CSV and GPX exports use the same matching rows and order, including when the Log is paused.
- **Map** combines located sightings with an optional community-mapped camera layer. **Recent** shows devices with a known sighting in the last 15 minutes; choose **All history** in Map options to include older or undated retained sightings. this is a display filter: it does not stop recording or remove anything from the Log.
- **Beacon** controls detector categories, alert behavior, radios, offline buffering, firmware updates, and setup readiness.

Status names the strongest recent match and shows when it was last heard; with no matched devices, it falls back to an explicitly labelled unclassified or ambient sighting. a user-assigned name takes precedence over the broadcast name. the radar shows signal strength, not bearing or an exact distance.

Beacon puts routine scan and alert controls first in its hardware group and separates phone notifications, Live Mode, and display preferences. connection labels distinguish reconnecting and secure setup from a ready link. radio labels wait for board status instead of assuming scanning is active. firmware summaries distinguish an available update, progress, completion, failure, and an unfinished second-radio update; open the summary for details or recovery actions.

most map pins show where your phone heard a signal, using its strongest sighting with a recorded location, rather than the device's exact location. a stronger RSSI moves the pin to that sighting's location; equal or weaker signals leave it in place. Remote ID drones can supply aircraft coordinates and sometimes operator coordinates; vendor-only drone matches do not provide those positions. community-mapped cameras are a separate dataset. a missing pin does not prove that no camera exists.

the Log and Map offer a **Watched** category when they contain watched/starred detections, including starred devices that also belong to another category.

the Map groups nearby pins and can simplify marker symbols in crowded or zoomed-out views. iPhone also simplifies dense trail rendering; on either platform you can switch map trails off if you do not need them. zoom in for more detail. its counts distinguish the current display from retained located history; filtering and simplification do not discard saved evidence. Map options groups history, display, and reference-overlay controls in one sheet; the overlays are not filters, so switching one off never hides a detection.

the confidence percentage describes the specificity of the matching evidence, not signal strength. open a detection for identifiers, first and last sightings, location context, and why it matched. weak vendor matches need confirmation. open a tracker in the Log to see its breadcrumb trail on the detail map: these are your phone's positions when it heard the tracker, not the tracker's exact route. breadcrumbs need a fresh phone location, at least 60 seconds and 25 meters between points, and keep up to 120 points in memory for the current app session. they are not restored after restarting the app. tracker details can also show **Seen with you** evidence; a sighting or repeated nearby presence is not a stalking verdict.

Watch and Mute actions, match caveats, **Related help**, and the location map appear near the top of detection details. expand **Related help** for the questions that fit that kind of detection. **Technical details**, further down, holds identifiers, capture-time qualifiers, and broadcast fields. collapsing either section does not hide the match's uncertainty warning.

## watch or mute a device

star a detection to watch that exact device. open a detection to mute it permanently, for 1 hour, for 24 hours, or within 50 meters of a saved place. manage names, stars, and mutes under **Beacon**. retained history remains in the Log and shows a **MUTED** label while the rule is active. muting removes the star; starring a muted device unmutes it.

muting an individual tracker stops new breadcrumbs while the mute is active and hides it from the main Map, but does not erase its existing session trail from Log details. unmuting allows new points to resume on the same trail; the muted interval is not filled in. **silent** alert mode and Focus/Do Not Disturb only suppress alerts; they do not stop breadcrumbs.

permanent mutes are copied to the board and silence that device's alerts with the phone away. timed and place mutes depend on the connected phone; the board can still sound according to its alert setting. stars and mutes follow an exact hardware address, so a device that rotates addresses may appear again.

## choose alerts

**buzzer** uses the board's speaker. **vibrate** mutes its detection sounds and uses category-specific phone haptics; glasses use a double tap and body cams use a repeating pattern. **silent** suppresses those detection alerts. iPhone haptics work while the app is open, including during a Focus. Android haptics defer to Do Not Disturb.

vibrate and silent also suppress the startup jingle. deliberate shutdown and battery-model press-and-hold start cues can still sound; master volume at zero silences those too. lights are controlled separately. tracker-category detections never beep on the board, including when starred. a star adds watched-device alerts only when no built-in signature matches.

per-category phone notifications are separate from board alert mode. every notification category starts off; enable the ones you want under **Beacon** and grant notification permission when requested. system notification settings can still prevent delivery or sound.

## Live Mode and widgets

Live Mode shows the nearby-now count on supported system surfaces. it starts enabled after first setup, subject to permissions and operating-system availability. detection and the Log still work if it is unavailable or switched off.

- iPhone uses a Live Activity on the Lock Screen and Dynamic Island. Location is required for background reliability.
- Android uses an ongoing notification or Live Update where supported. Android 13 or newer requires notification permission for that surface.

counts appear on the Lock Screen by default. the hide-counts setting under **Beacon** hides the iPhone Lock Screen count, but Dynamic Island, Watch, and CarPlay counts remain visible. iPhone detection-alert previews follow the system's **Show Previews** setting. on Android, hiding counts also removes the status-bar count and category details from locked detection notifications.

add the home-screen widget through your system's widget picker. it shows today's detection total and connection state, with the latest hit and category breakdown where space permits. its daily total differs from Live Mode's recent count. Live Mode can be toggled from Control Center on iPhone or Quick Settings on Android. supported setups can show compact Live Activities in CarPlay and Apple Watch Smart Stack, or the Android widget in compatible car hosts. these are system-provided views, not dedicated car or watch apps.

## accessibility and your data

key controls and status surfaces include VoiceOver or TalkBack descriptions, and layouts support larger text. the palette follows supported system contrast settings; on iPhone higher contrast also sets type one weight heavier. **Beacon > Display > always use higher contrast** forces higher contrast on.

ALPR map callouts and legends use solid dark backgrounds and bright, wrapping text so the map underneath cannot wash out their contrast. mapped-camera attribution and the distinction from live detections remain visible.

offline buffering is optional and encrypted, but the enabled board stores its key too, so it is not protection against forensic access to a captured board. offline pins may use the phone's last shared fix; they do not track the board's movement. the board also advertises a fixed Bluetooth address, allowing observers to correlate it over time. the board limits how fast it buffers recognized detections (a burst of 256, then about one every 10 seconds), so a flood of fake identities cannot overwrite the buffer in minutes; if that limit turns rows away, the Log and the offline buffer control show **DETECTION FLOOD REFUSED** until the board buffer is erased. clearing the phone's Log does not erase the board buffer; use **ERASE** under the offline buffer control. see the [BLE privacy and buffer details](ble-protocol.md).

exports can include observation, aircraft, and operator locations. review them before sharing. the app's own copy of each export or improve detection share is temporary: once it is more than an hour old, the app deletes it at the next launch (on Android, also at the next export). clearing the Log deletes all of those copies at once and removes the app's detection notifications; on Android it also deletes the cached map tiles, which the app keeps only in its private internal storage. iPhone maps use Apple Maps, and the app keeps no tile cache of its own. detections are not automatically uploaded; map tiles, firmware updates, and the optional camera dataset require ordinary network requests. see the [privacy policy](../web/privacy.html), [getting-started guide](https://soyboi.tech/getting-started), or [FAQ](https://soyboi.tech/faq) for more help.
