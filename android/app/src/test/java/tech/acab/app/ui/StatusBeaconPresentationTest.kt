package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import tech.acab.app.ble.CombinedUpdatePhase
import tech.acab.app.ble.CombinedUpdateProgress
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.DemoStatusToggle
import tech.acab.app.ble.OtaPhase
import tech.acab.app.ble.withDemoStatusToggle
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType

class StatusBeaconPresentationTest {
    private fun row(
        mac: String,
        type: DeviceType,
        rssi: Int = -70,
    ) = Detection(
        type = type,
        source = 0,
        method = 0,
        confidence = 80,
        mac = mac,
        rssi = rssi,
        name = null,
        rid = null,
        detail = null,
        lat = null,
        lon = null,
        pilotLat = null,
        pilotLon = null,
        altitude = null,
        speedH = null,
        speedV = null,
        heading = null,
        heightAGL = null,
        pilotAlt = null,
        ridStatus = null,
        count = 1,
        isNew = false,
        gpsAgeSec = null,
        hist = false,
        seq = 0L,
        at = 0L,
        approx = false,
    )

    @Test
    fun nearbySummarySeparatesAmbientAndKeepsImportantRowsInsideDotCap() {
        val ambient = List(15) { row("ambient-$it", DeviceType.NEARBY_DEVICE, -30 - it) }
        val match = row("match", DeviceType.TRACKER, -95)
        val starredUnknown = row("starred", DeviceType.UNKNOWN, -100)
        val unknown = row("unknown", DeviceType.UNKNOWN, -99)

        val summary = statusNearbySummary(ambient + match + starredUnknown + unknown, setOf("starred"))

        assertEquals(18, summary.total)
        assertEquals(2, summary.matched)
        assertEquals(15, summary.ambient)
        assertEquals(1, summary.unclassified)
        assertEquals(1, summary.watched)
        // The literal 14, not STATUS_RADAR_DOT_CAP: the cap is SHARED with iOS
        // (DashboardSnapshot.dotLimit, which DashboardPresentationTests pins as the literal 14
        // too), so a one-sided change fails on the side that changed. Asserting the constant
        // against itself would pass for any value.
        assertEquals(14, summary.dots.size)
        // The two caption lines, byte-identical to iOS DashboardSnapshot.radarCaption /
        // radarCaptionDetail (DashboardPresentationTests pins the same literals); the second
        // clause is the one that says the dot cap does not cap the counters.
        assertEquals("14 of 18 dots · 14 max", summary.radarCaption)
        assertEquals(
            "matches and stars first · counts include every recent device",
            STATUS_RADAR_CAPTION_DETAIL,
        )
        assertTrue(summary.dots.any { it.row.id == match.id })
        assertTrue(summary.dots.any { it.row.id == starredUnknown.id })
        assertTrue(summary.dots.any { it.row.id == unknown.id })
        assertEquals(starredUnknown.id, summary.dots.first().row.id)
        // The star rides on the dot, not on the type: the scope tints from this flag, and
        // starring deliberately leaves the row's category alone.
        assertTrue(summary.dots.first().watched)
        assertFalse(summary.dots.first { it.row.id == match.id }.watched)
    }

    @Test
    fun strongestCardPrefersAMatchThenFallsBackToAmbient() {
        val loudAmbient = row("ambient", DeviceType.NEARBY_DEVICE, -20)
        val quietMatch = row("match", DeviceType.BODY_CAM, -90)
        val matched = statusNearbySummary(listOf(loudAmbient, quietMatch), emptySet())
        assertEquals(quietMatch.id, matched.strongest?.id)
        assertEquals(StatusStrongestKind.MATCHED, matched.strongestKind)

        val ambientOnly = statusNearbySummary(listOf(loudAmbient), emptySet())
        assertEquals(loudAmbient.id, ambientOnly.strongest?.id)
        assertEquals(StatusStrongestKind.AMBIENT, ambientOnly.strongestKind)

        val unknown = row("unknown", DeviceType.UNKNOWN, -80)
        val unclassifiedFallback = statusNearbySummary(listOf(loudAmbient, unknown), emptySet())
        assertEquals(unknown.id, unclassifiedFallback.strongest?.id)
        assertEquals(StatusStrongestKind.UNCLASSIFIED, unclassifiedFallback.strongestKind)
    }

    @Test
    fun equalRssiRadarOrderingIsStable() {
        val rows = listOf(
            row("c", DeviceType.TRACKER),
            row("a", DeviceType.TRACKER),
            row("b", DeviceType.TRACKER),
        )
        assertEquals(
            statusNearbySummary(rows, emptySet()).dots.map { it.row.id },
            statusNearbySummary(rows.reversed(), emptySet()).dots.map { it.row.id },
        )
    }

    /** Pins the tie-break SHARED with iOS strongerDashboardSighting: signal, then id, and never
     *  recency. Order-stability alone cannot see this - any total order is stable - so this names
     *  the winner instead. Reversing the id rung, or ranking by feed position, fails here: "b"
     *  arrives first and "c" last, and "a" still has to win. */
    @Test
    fun equalRssiTiesResolveByIdNotArrivalOrder() {
        val a = row("a", DeviceType.TRACKER)
        val b = row("b", DeviceType.TRACKER)
        val c = row("c", DeviceType.TRACKER)
        val summary = statusNearbySummary(listOf(b, a, c), emptySet())
        assertEquals(listOf(a.id, b.id, c.id), summary.dots.map { it.row.id })
        assertEquals(a.id, summary.strongest?.id)
    }

    @Test
    fun disabledCountTileKeepsRecentCountAndRoutesUsefully() {
        val retained = statusCountTilePresentation("trackers", 3, enabled = false)
        assertEquals("3", retained.visibleCount)
        assertTrue(retained.off)
        assertEquals(StatusCountTileDestination.LOG, retained.destination)
        assertEquals("show in log", retained.clickLabel)
        // The whole sentence, byte-identical to iOS dashboardTileAccessibilityLabel
        // (DashboardPresentationTests pins the same two): name, count, then the setting.
        assertEquals("trackers, 3 recently heard, detector off", retained.contentDescription)

        val empty = statusCountTilePresentation("trackers", 0, enabled = false)
        assertEquals("0", empty.visibleCount)
        assertEquals(StatusCountTileDestination.DETECTOR_SETTINGS, empty.destination)
        assertEquals("open detector settings", empty.clickLabel)

        assertEquals(StatusCountTileDestination.LOG,
            statusCountTilePresentation("trackers", 0, enabled = null).destination)
    }

    /** The six tiles, their drawn and spoken names, which types each counts and which board
     *  toggle each reads, are one list on both phones (iOS DashboardSnapshot.stripTiles, pinned
     *  in DashboardPresentationTests with the same three frames). The ALPR tile counts Raven
     *  rows, so its spoken name says so: dropping FLOCK_RAVEN from `counted`, or shortening the
     *  spoken name back to "License plate reader", fails here. */
    @Test
    fun stripTilesMatchIosAndTheAlprTileCountsAndNamesRaven() {
        assertEquals(
            listOf(DeviceType.FLOCK_CAMERA, DeviceType.DRONE, DeviceType.BODY_CAM,
                DeviceType.TRACKER, DeviceType.GLASSES, DeviceType.NETWORK_CAMERA),
            STATUS_STRIP_TILES.map { it.type },
        )
        assertEquals(listOf("ALPR", "DRONE", "BODY", "TRKR", "GLAS", "NETCAM"),
            STATUS_STRIP_TILES.map { it.label })
        assertEquals(
            listOf("ALPR cameras and Raven audio sensors", "drones", "body cameras", "trackers",
                "glasses", "network cameras"),
            STATUS_STRIP_TILES.map { it.spoken },
        )
        val alpr = STATUS_STRIP_TILES[0]
        assertEquals(listOf(DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN), alpr.counted)

        // Each tile reads its own board toggle; the ALPR tile's Raven rows ride the flock bit.
        // Every frame sets all six detector keys, because fromJson defaults flock, drone and
        // glasses on and the other three off, so an absent key proves nothing. Across the three
        // frames no two tiles share an on/off pattern and no tile is on in all three or off in
        // all three, while every other Boolean on the frame reads the same in all three. So
        // pointing any tile at another detector's toggle, or at a non-detector Boolean, fails.
        val wireKeys = listOf("flock", "drone", "axon", "tracker", "glasses", "ncam") // tile order
        val patterns = listOf(
            listOf(true, false, false, true, true, false),
            listOf(false, true, false, true, false, true),
            listOf(false, false, true, false, true, true),
        )
        for ((index, pattern) in patterns.withIndex()) {
            val json = JSONObject("""{"fw":"beacon board 2.0.8","ble":true,"wifi":true}""")
            wireKeys.zip(pattern).forEach { (key, on) -> json.put(key, on) }
            val frame = DeviceStatus.fromJson(json)
            assertEquals("frame $index", pattern, STATUS_STRIP_TILES.map { it.toggle(frame) })
        }

        assertEquals(
            "ALPR cameras and Raven audio sensors, 2 recently heard",
            statusCountTilePresentation(alpr.spoken, 2, enabled = true).contentDescription,
        )
    }

    /** The breakdown under the radar has one owner. The four card literals and the two lines are
     *  byte-identical to iOS DashboardSnapshot.matchedCardTitle / matchedCardDetail /
     *  ambientCardTitle / ambientCardDetail and unclassifiedLine / watchedLine, pinned there in
     *  DashboardPresentationTests. Rewording either side fails its own suite; the other side is a
     *  by-hand edit. The two lines exist only when they have something to say. The card's spoken
     *  sentence at the end has no iOS literal: VoiceOver builds its reading from the card's
     *  combined children. */
    @Test
    fun nearbyBreakdownLiteralsMatchIosAndOnlyRenderWhenThereIsSomethingToSay() {
        assertEquals("MATCHED + WATCHED", STATUS_MATCHED_CARD_TITLE)
        assertEquals("signatures or exact stars", STATUS_MATCHED_CARD_DETAIL)
        assertEquals("AMBIENT", STATUS_AMBIENT_CARD_TITLE)
        assertEquals("Desert-mode broadcasts", STATUS_AMBIENT_CARD_DETAIL)

        val full = statusNearbySummary(
            listOf(row("unknown", DeviceType.UNKNOWN), row("star", DeviceType.NEARBY_DEVICE)),
            setOf("star"),
        )
        assertEquals("1 unclassified · category not recognized by this app", full.unclassifiedLine)
        assertEquals("1 watched · included in matches", full.watchedLine)

        val quiet = statusNearbySummary(listOf(row("t", DeviceType.TRACKER)), emptySet())
        assertNull(quiet.unclassifiedLine)
        assertNull(quiet.watchedLine)

        // The card speaks count, title, detail, in the order VoiceOver reads the iOS card's
        // combined children. RadarCountCard hands its two drawn lines straight to this function,
        // so the join under test is the one TalkBack hears.
        assertEquals(
            "3 MATCHED + WATCHED, signatures or exact stars",
            statusRadarCountCardDescription(3, STATUS_MATCHED_CARD_TITLE, STATUS_MATCHED_CARD_DETAIL),
        )
    }

    /** ARM ORDER of the Status header, pinned with iOS beaconRadioPresentation
     *  (DashboardPresentationTests pins the same four cases): link facts outrank the combined
     *  coordinator. Moving the genericFirmwareUpdate arm of statusScanPresentation above
     *  `reconnecting` fails the first two label assertions, and above `!hasStatus` fails the
     *  third, because each would then read "UPDATING FIRMWARE · DETECTION MAY PAUSE". The pill
     *  follows the same order (statusLinkChipLabel; iOS chipLabel, pinned in the same iOS test):
     *  moving its UPDATING arm back above `!hasStatus` fails the WAITING assertion. The Beacon
     *  tab's beaconRadioStatusLabel takes the same link facts first, through
     *  beaconConnectionPresentation and its own update-reboot arm, so it is held to the same two
     *  lines here; after the link facts its order differs (see its KDoc). */
    @Test
    fun statusHeaderReadsReconnectAndFirstFrameBeforeTheRunningUpdate() {
        fun pill(p: StatusScanPresentation, reconnecting: Boolean, hasStatus: Boolean) =
            statusLinkChipLabel(
                demo = false, reconnecting = reconnecting, rebootingForUpdate = false,
                hasStatus = hasStatus,
                firmwareUpdateRunning = true, bleUpdating = p.bleUpdating, bleFault = p.bleFault,
            )

        // The drop cleared the frame (AcabBleManager cleanup) and the shell is reconnecting while
        // the coordinator is still running.
        val reconnect = statusScanPresentation(
            demo = false, reconnecting = true, rebootingForUpdate = false, hasStatus = false,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertEquals("RECONNECTING · BOARD STATUS UNAVAILABLE", reconnect.label)
        assertFalse(reconnect.scanning)
        assertEquals("RECONNECTING", pill(reconnect, reconnecting = true, hasStatus = false))

        // A retained frame with the nrfup bit does not change that: the reconnect wins, and
        // nothing about the co-processor is claimed off a frame the link cannot vouch for.
        val reconnectStaleNrf = statusScanPresentation(
            demo = false, reconnecting = true, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = false, nrfUpdating = true,
            firmwareUpdateRunning = true,
        )
        assertEquals("RECONNECTING · BOARD STATUS UNAVAILABLE", reconnectStaleNrf.label)
        assertFalse(reconnectStaleNrf.bleUpdating)
        assertFalse(reconnectStaleNrf.bleFault)
        assertFalse(reconnectStaleNrf.scanning)
        assertEquals("RECONNECTING", pill(reconnectStaleNrf, reconnecting = true, hasStatus = true))

        // Back on the link after that unexpected drop, first frame not yet in: the link fact again.
        // The OTA engine is not rebooting the board here, so rebootingForUpdate is false.
        val firstFrameGap = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = false,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertEquals("CONNECTED · WAITING FOR BOARD STATUS", firstFrameGap.label)
        assertFalse(firstFrameGap.scanning)
        // The pill too. It read an amber UPDATING here while the Status screen ranked the
        // coordinator above the missing frame, beside a kicker saying the board had not reported.
        assertEquals("WAITING", pill(firstFrameGap, reconnecting = false, hasStatus = false))

        // With a frame in hand the coordinator's sentence and the UPDATING pill return.
        val framed = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = true, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertEquals("UPDATING FIRMWARE · DETECTION MAY PAUSE", framed.label)
        assertEquals("UPDATING", pill(framed, reconnecting = false, hasStatus = true))

        // The Beacon tab, same two lines for the same two moments.
        val reconnectShell = beaconConnectionPresentation(false, true, ConnState.CONNECTING, false)
        assertEquals(
            "RECONNECTING · BOARD STATUS UNAVAILABLE",
            beaconRadioStatusLabel(false, reconnectShell, false, false, false, false, null, false,
                CombinedUpdatePhase.UPDATING_S3),
        )
        val noFrameYet = beaconConnectionPresentation(false, false, ConnState.READY, false)
        assertEquals(
            "CONNECTED · WAITING FOR BOARD STATUS",
            beaconRadioStatusLabel(false, noFrameYet, false, false, false, false, null, false,
                CombinedUpdatePhase.VERIFYING),
        )
    }

    /** The pill's own arm order, one step at a time: the twin of iOS
     *  BeaconRadioPresentation.chipLabel over the connection label beaconRadioPresentation picks
     *  (null here is the DEMO pill, which LinkChip draws for sample mode). Each case also turns on
     *  the input of every arm below it, so each assertion fails if its arm drops below the next.
     *  The update reboot is the one exception: the update arm below it returns the same word, so
     *  that case leaves the update inputs off and turns on the missing frame and the fault instead.
     *  It fails if the reboot arm is removed or drops below `!hasStatus`. */
    @Test
    fun linkChipLabelRanksLikeTheIosChip() {
        assertNull(statusLinkChipLabel(demo = true, reconnecting = true, rebootingForUpdate = true,
            hasStatus = false, firmwareUpdateRunning = true, bleUpdating = true, bleFault = true))
        assertEquals("RECONNECTING", statusLinkChipLabel(demo = false, reconnecting = true,
            rebootingForUpdate = true, hasStatus = false, firmwareUpdateRunning = true,
            bleUpdating = true, bleFault = true))
        assertEquals("UPDATING", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = true, hasStatus = false, firmwareUpdateRunning = false,
            bleUpdating = false, bleFault = true))
        assertEquals("WAITING", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = false, hasStatus = false, firmwareUpdateRunning = true,
            bleUpdating = true, bleFault = true))
        assertEquals("UPDATING", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = false, hasStatus = true, firmwareUpdateRunning = true,
            bleUpdating = false, bleFault = true))
        assertEquals("UPDATING", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = false, hasStatus = true, firmwareUpdateRunning = false,
            bleUpdating = true, bleFault = true))
        assertEquals("RADIO FAULT", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = false, hasStatus = true, firmwareUpdateRunning = false,
            bleUpdating = false, bleFault = true))
        assertEquals("CONNECTED", statusLinkChipLabel(demo = false, reconnecting = false,
            rebootingForUpdate = false, hasStatus = true, firmwareUpdateRunning = false,
            bleUpdating = false, bleFault = false))
    }

    /** The phone's own S3 update reboot is a link fact, ranked after the reconnect and before the
     *  missing frame, as iOS ranks isRebootingForUpdate. DashboardPresentationTests pins the same
     *  `gap` and `reconnect` pairing (testOwnUpdateRebootOutranksTheMissingFrame) and the same
     *  `confirming` case (testOwnUpdateRebootKeepsTheCoordinatorLineInsteadOfSecuring). The reboot
     *  drop clears the frame (AcabBleManager cleanup) and the reconnect lands READY before the
     *  first one, so without the arm `gap` reads "CONNECTED · WAITING FOR BOARD STATUS" under a
     *  WAITING pill, which fails its first two assertions. The arm does not lean on the
     *  coordinator's flag, so without it `confirming` reads "SCANNING · WI-FI ONLY · BLE RADIO
     *  FAULT"; with the label arm but without its frameSpeaks gate, its scanning and bleFault
     *  assertions fail. Moving the arm above `reconnecting` fails the last assertion. The Beacon
     *  tab's beaconRadioStatusLabel now takes the same fact in the same slot, and the block at the
     *  end pins it to this label: dropping its arm makes `beaconGap` read "CONNECTED · WAITING FOR
     *  BOARD STATUS" and `beaconFramed` read "SCANNING · WI-FI ONLY · BLE RADIO FAULT", and moving
     *  it above the connection check makes `beaconReconnect` read the update line.
     *
     *  The tab's OTHER presenter is pinned at the end of this test, because it ranks this fact on
     *  its own: beaconConnectionPresentation feeds the Beacon tab's header kicker and its hero, the
     *  two lines read before the row above. Every call to it outside that block leaves
     *  rebootingForUpdate at its default, so before `header` nothing entered that arm and it could
     *  have been deleted with this suite and check-signature-drift.py both green. Dropping it, or
     *  moving it under its own `!hasStatus` arm, makes `header` read "CONNECTED · WAITING FOR BOARD
     *  STATUS" and fails the first two header assertions; moving it above the connection checks
     *  fails the last one. */
    @Test
    fun statusHeaderReadsTheUpdateRebootBeforeTheMissingFrame() {
        val gap = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = true, hasStatus = false,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertEquals("UPDATING FIRMWARE · DETECTION MAY PAUSE", gap.label)
        assertEquals("UPDATING", statusLinkChipLabel(
            demo = false, reconnecting = false, rebootingForUpdate = true, hasStatus = false,
            firmwareUpdateRunning = true, bleUpdating = gap.bleUpdating, bleFault = gap.bleFault,
        ))
        assertFalse(gap.scanning)

        // A frame in hand that reports the co-processor down, with the coordinator's flag down:
        // no radio line, no scan and no fault pill until the reboot window closes.
        val confirming = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = true, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = false, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertEquals("UPDATING FIRMWARE · DETECTION MAY PAUSE", confirming.label)
        assertFalse(confirming.scanning)
        assertFalse(confirming.bleFault)
        assertEquals("UPDATING", statusLinkChipLabel(
            demo = false, reconnecting = false, rebootingForUpdate = true, hasStatus = true,
            firmwareUpdateRunning = false, bleUpdating = confirming.bleUpdating,
            bleFault = confirming.bleFault,
        ))

        // The reconnect still outranks it, as on iOS.
        val reconnect = statusScanPresentation(
            demo = false, reconnecting = true, rebootingForUpdate = true, hasStatus = false,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertEquals("RECONNECTING · BOARD STATUS UNAVAILABLE", reconnect.label)

        // The Beacon tab's collapsed Scan radios row, the same three moments. This is the split
        // the arm closes: the reboot drop clears the frame and the reconnect lands READY with the
        // tabs uncovered, so this row used to read CONNECTED · WAITING FOR BOARD STATUS while the
        // Status tab one tap away read the update line, on the path every S3 update takes.
        val beaconGap = beaconConnectionPresentation(false, false, ConnState.READY, false)
        assertEquals(
            gap.label,
            beaconRadioStatusLabel(false, beaconGap, true, false, false, false, null, false,
                CombinedUpdatePhase.RECONNECTING),
        )
        assertEquals(
            "UPDATING FIRMWARE · DETECTION MAY PAUSE",
            beaconRadioStatusLabel(false, beaconGap, true, false, false, false, null, false,
                CombinedUpdatePhase.RECONNECTING),
        )
        // A frame in hand reporting the co-processor down, with the coordinator idle: the reboot
        // outranks the fault line here too, so the row cannot claim Wi-Fi coverage mid-reboot.
        val beaconFramed = beaconConnectionPresentation(false, false, ConnState.READY, true)
        assertEquals(
            confirming.label,
            beaconRadioStatusLabel(false, beaconFramed, true, true, true, true, false, false,
                CombinedUpdatePhase.IDLE),
        )
        // And the connection still outranks the reboot, matching the Status header above.
        val beaconReconnect = beaconConnectionPresentation(false, true, ConnState.CONNECTING, false)
        assertEquals(
            "RECONNECTING · BOARD STATUS UNAVAILABLE",
            beaconRadioStatusLabel(false, beaconReconnect, true, false, false, false, null, false,
                CombinedUpdatePhase.RECONNECTING),
        )

        // The Beacon tab's header kicker and hero, which take this fact through their OWN arm in
        // beaconConnectionPresentation rather than through the row above. Same moment as `gap`:
        // the reboot drop cleared the frame and the reconnect landed READY, so hasStatus is false.
        val header = beaconConnectionPresentation(
            false, false, ConnState.READY, false, rebootingForUpdate = true,
        )
        assertEquals(gap.label, header.headerKicker)
        assertEquals("UPDATING FIRMWARE · detection may pause", header.heroPrefix)
        // The link is up through the reboot, so only those two lines move: what hangs off
        // `connected` (the refresh button's enabled gate, and currentStatus) stays as it was.
        assertTrue(header.connected)
        // The connection outranks the reboot here too, as it does on the row and on iOS.
        assertEquals(
            "RECONNECTING · BOARD STATUS UNAVAILABLE",
            beaconConnectionPresentation(
                false, true, ConnState.CONNECTING, false, rebootingForUpdate = true,
            ).headerKicker,
        )
    }

    /** The update-reboot link fact is the OTA engine's REBOOTING and CONFIRMING phases and nothing
     *  else (StatusScreen maps otaProgress through this before collectAsState). iOS
     *  isRebootingForUpdate spans the same reboot-to-confirm window. Dropping either phase, or
     *  adding another, fails the set comparison. */
    @Test
    fun updateRebootLinkFactIsTheRebootAndConfirmPhases() {
        assertEquals(
            setOf(OtaPhase.REBOOTING, OtaPhase.CONFIRMING),
            OtaPhase.entries.filter(::otaPhaseIsUpdateReboot).toSet(),
        )
    }

    /** The dead-switch line under a phone-notification toggle whose detector is off (DeviceScreen
     *  NotifyCard). iOS SettingsView notifyCard prints the same template from the same
     *  DeviceType.inlineLabel. The ALPR line is the one `label.lowercase()` got wrong ("the alpr
     *  camera detector"), so it fails if the name source is reverted; the body-cam line pins the
     *  template around a name that is not an initialism. */
    @Test
    fun notifyDetectorOffWarningKeepsTheAlprInitialism() {
        assertEquals(
            "the ALPR camera detector is off, so this won't fire. turn it on under Detectors.",
            notifyDetectorOffWarning(DeviceType.FLOCK_CAMERA),
        )
        assertEquals(
            "the body camera detector is off, so this won't fire. turn it on under Detectors.",
            notifyDetectorOffWarning(DeviceType.BODY_CAM),
        )
    }

    /** The recency kicker is built from ACTIVE_NEARBY_WINDOW_MS, the default window of the
     *  freshIdSet call that builds the radar's rows. Byte-identical to iOS
     *  DashboardSnapshot.seenWindowKicker (built from activeNearbyInterval, pinned in
     *  DashboardPresentationTests), so retuning either window fails on the side that moved. */
    @Test
    fun seenWindowKickerNamesTheFreshnessWindow() {
        assertEquals("SEEN < 45s", STATUS_SEEN_WINDOW_KICKER)
    }

    @Test
    fun sampleTrackerSwitchEchoesIntoTheStatusOffTileWithoutRemovingItsRecentCount() {
        val sample = DeviceStatus.fromJson(JSONObject(
            """{"fw":"beacon board 2.0.8","tracker":true,"ble":true,"wifi":true}""",
        ))
        val trackerOff = sample.withDemoStatusToggle(DemoStatusToggle.TRACKER, false)
        val tile = statusCountTilePresentation("Tracker", count = 1, enabled = trackerOff.tracker)

        assertFalse(trackerOff.tracker)
        assertEquals("1", tile.visibleCount)
        assertTrue(tile.off)
        assertEquals(StatusCountTileDestination.LOG, tile.destination)
    }

    @Test
    fun lastHeardAgeHandlesNowFutureMissingAndSample() {
        val now = 1_000_000L
        assertEquals("last heard just now", statusLastHeardAge(now, now, demo = false))
        assertEquals("last heard just now", statusLastHeardAge(now + 10_000L, now, demo = false))
        assertEquals("last heard 44s ago", statusLastHeardAge(now - 44_900L, now, demo = false))
        assertEquals("last heard 1m ago", statusLastHeardAge(now - 60_000L, now, demo = false))
        assertEquals("last heard unknown", statusLastHeardAge(null, now, demo = false))
        // Byte-identical to iOS dashboardLastHeardLabel's demo string, asserted there too.
        assertEquals("sample sighting · not live", statusLastHeardAge(null, now, demo = true))
    }

    @Test
    fun connectionCopyDoesNotCallReconnectOrFirstFrameConnectedStatusLive() {
        val reconnect = beaconConnectionPresentation(
            demo = false, reconnecting = true, state = ConnState.CONNECTING, hasStatus = true,
        )
        assertEquals("RECONNECTING · BOARD STATUS UNAVAILABLE", reconnect.headerKicker)
        assertFalse(reconnect.connected)

        val firstFrame = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.READY, hasStatus = false,
        )
        assertEquals("CONNECTED · WAITING FOR BOARD STATUS", firstFrame.headerKicker)
        assertTrue(firstFrame.connected)

        val ready = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.READY, hasStatus = true,
        )
        assertEquals("CONNECTED OVER BLE", ready.headerKicker)
        assertTrue(ready.connected)
    }

    @Test
    fun statusScanCopyParksWithoutFrameDuringReconnectAndDuringBoardUpdate() {
        val sampleBoth = statusScanPresentation(
            demo = true, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertTrue(sampleBoth.scanning)
        assertEquals("SAMPLE DATA", sampleBoth.label)
        val sampleWifi = statusScanPresentation(
            demo = true, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = false, wifiIntent = true, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertTrue(sampleWifi.scanning)
        assertEquals("SAMPLE DATA · WI-FI ONLY", sampleWifi.label)
        val sampleOff = statusScanPresentation(
            demo = true, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertFalse(sampleOff.scanning)
        assertEquals("SAMPLE DATA · RADIOS OFF", sampleOff.label)

        val waiting = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = false,
            bleIntent = false, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertFalse(waiting.scanning)
        assertEquals("CONNECTED · WAITING FOR BOARD STATUS", waiting.label)

        val reconnect = statusScanPresentation(
            demo = false, reconnecting = true, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = true, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertFalse(reconnect.scanning)
        // Same wording the Device tab's beaconConnectionPresentation uses for this state: the
        // radar's counts are NOT retained through a reconnect (the 45s freshness filter empties
        // them), so the header may not claim they are.
        assertEquals("RECONNECTING · BOARD STATUS UNAVAILABLE", reconnect.label)

        val boardUpdate = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = false, nrfUpdating = false,
            firmwareUpdateRunning = true,
        )
        assertFalse(boardUpdate.scanning)
        assertFalse(boardUpdate.bleFault)
        assertEquals("UPDATING FIRMWARE · DETECTION MAY PAUSE", boardUpdate.label)

        val nrfUpdateWithWifi = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = true, coAlive = true, nrfUpdating = true,
            firmwareUpdateRunning = true,
        )
        assertTrue(nrfUpdateWithWifi.scanning)
        assertTrue(nrfUpdateWithWifi.bleUpdating)
        assertEquals("SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR", nrfUpdateWithWifi.label)

        val nrfUpdateAlone = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = false, coAlive = true, nrfUpdating = true,
            firmwareUpdateRunning = false,
        )
        assertFalse(nrfUpdateAlone.scanning)
        assertEquals("UPDATING CO-PROCESSOR · NOT SCANNING", nrfUpdateAlone.label)
    }

    @Test
    fun radioCopyDistinguishesUnavailableUpdatingFaultAndIntentionalOff() {
        val connected = beaconConnectionPresentation(false, false, ConnState.READY, true)
        val reconnect = beaconConnectionPresentation(false, true, ConnState.CONNECTING, true)
        assertEquals(
            "RECONNECTING · BOARD STATUS UNAVAILABLE",
            beaconRadioStatusLabel(false, reconnect, false, true, true, true, false, false,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR",
            beaconRadioStatusLabel(false, connected, false, true, true, true, true, true,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "UPDATING FIRMWARE · DETECTION MAY PAUSE",
            beaconRadioStatusLabel(false, connected, false, true, true, false, false, false,
                CombinedUpdatePhase.UPDATING_COPROC),
        )
        assertEquals(
            "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR",
            beaconRadioStatusLabel(false, connected, false, true, false, true, false, true,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "UPDATING FIRMWARE · DETECTION MAY PAUSE",
            beaconRadioStatusLabel(false, connected, false, true, true, true, false, false,
                CombinedUpdatePhase.UPDATING_S3),
        )
        assertEquals(
            "SCANNING · WI-FI ONLY · BLE RADIO FAULT",
            beaconRadioStatusLabel(false, connected, false, true, true, true, false, false,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "SCANNING · WI-FI",
            beaconRadioStatusLabel(false, connected, false, true, false, true, false, false,
                CombinedUpdatePhase.IDLE),
        )
        // The Beacon tab and the Status header have to say the same thing about one board state.
        // This pins the two Android presenters to each other, and the literal below pins the
        // words. iOS beaconRadioPresentation carries the same literal, but only its own suite
        // can hold it there; rewording iOS cannot fail this.
        assertEquals(
            statusScanPresentation(
                demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
                bleIntent = true, wifiIntent = true, coAlive = true, nrfUpdating = false,
                firmwareUpdateRunning = false,
            ).label,
            beaconRadioStatusLabel(false, connected, false, true, true, true, true, false,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "SCANNING · BLE · WI-FI",
            beaconRadioStatusLabel(false, connected, false, true, true, true, true, false,
                CombinedUpdatePhase.IDLE),
        )
        assertEquals(
            "RADIOS OFF · NOT SCANNING",
            beaconRadioStatusLabel(false, connected, false, true, false, false, true, false,
                CombinedUpdatePhase.IDLE),
        )
        // Sample mode is shared with iOS as of 2026-09-08. Both tours echo the radio switches
        // into the synthetic status and both presenters read them, so the collapsed row names
        // them the way the Status header does, on both phones. iOS pins the same four literals
        // in BeaconPresentationTests.testDemoNamesItsSampleRadiosAndSweepsWithThem.
        assertEquals(
            "SAMPLE DATA · WI-FI ONLY",
            beaconRadioStatusLabel(true, connected, false, true, false, true, null, false,
                CombinedUpdatePhase.IDLE),
        )
    }

    @Test
    fun firmwareBannerNamesEveryActiveAndTerminalPhase() {
        val expectations = mapOf(
            CombinedUpdatePhase.IDLE to FirmwareBannerKind.READY,
            CombinedUpdatePhase.CHECKING to FirmwareBannerKind.UPDATING,
            CombinedUpdatePhase.UPDATING_S3 to FirmwareBannerKind.UPDATING,
            CombinedUpdatePhase.RECONNECTING to FirmwareBannerKind.UPDATING,
            CombinedUpdatePhase.UPDATING_COPROC to FirmwareBannerKind.UPDATING,
            CombinedUpdatePhase.VERIFYING to FirmwareBannerKind.UPDATING,
            CombinedUpdatePhase.DONE to FirmwareBannerKind.COMPLETED,
            CombinedUpdatePhase.FAILED to FirmwareBannerKind.FAILED,
            CombinedUpdatePhase.PARTIAL to FirmwareBannerKind.PARTIAL,
        )
        for ((phase, kind) in expectations) {
            val presentation = firmwareBannerPresentation(
                latest = "2.0.8",
                installed = "2.0.7",
                combined = CombinedUpdateProgress(phase = phase, s3Updated = true),
                combinedStale = phase == CombinedUpdatePhase.IDLE,
                s3Stale = phase == CombinedUpdatePhase.IDLE,
            )
            assertEquals(phase.name, kind, presentation.kind)
            if (phase != CombinedUpdatePhase.IDLE) {
                assertFalse("${phase.name} must not say ready", presentation.title.contains("ready", true))
            }
        }
        assertTrue(
            firmwareBannerPresentation("2.0.8", "2.0.7",
                CombinedUpdateProgress(phase = CombinedUpdatePhase.DONE),
                combinedStale = false, s3Stale = false).title.contains("complete"),
        )
        assertTrue(
            firmwareBannerPresentation("2.0.8", "2.0.7",
                CombinedUpdateProgress(phase = CombinedUpdatePhase.PARTIAL, s3Updated = true),
                combinedStale = false, s3Stale = false)
                .kicker.contains("board updated"),
        )
        val cancelled = firmwareBannerPresentation(
            "2.0.8",
            "2.0.7",
            CombinedUpdateProgress(
                phase = CombinedUpdatePhase.FAILED,
                label = "Update cancelled",
                reason = "Update cancelled.",
            ),
            combinedStale = false,
            s3Stale = false,
        )
        assertEquals(FirmwareBannerKind.CANCELLED, cancelled.kind)
        assertTrue(cancelled.title.contains("cancelled"))

        val secondRadioOnly = firmwareBannerPresentation(
            latest = "2.0.8",
            installed = "2.0.8",
            combined = CombinedUpdateProgress(),
            combinedStale = true,
            s3Stale = false,
        )
        assertEquals("Second radio update ready", secondRadioOnly.title)
        assertFalse(secondRadioOnly.kicker.contains("already current", ignoreCase = true))
        assertTrue(shouldPromoteFirmwareBanner(
            boardFirmwareOutdated = false,
            combinedUpdateAvailable = true,
            combined = CombinedUpdateProgress(),
        ))
    }

    /** Every literal below is byte-identical to the iOS arm BeaconPresentationTests pins
     *  (`beaconFirmwareBannerPresentation` in BeaconPresentation.swift): one banner, one wording,
     *  both phones. A reword on either side fails its own suite; the other side is a by-hand edit. */
    @Test
    fun firmwareBannerWordingMatchesTheiOSPresenterArmForArm() {
        fun banner(
            phase: CombinedUpdatePhase,
            label: String = "",
            progress: Float = 0f,
            notice: String? = null,
            s3Updated: Boolean = false,
            installed: String? = "2.0.7",
            combinedStale: Boolean = false,
            s3Stale: Boolean = false,
        ) = firmwareBannerPresentation(
            "2.0.8", installed,
            CombinedUpdateProgress(
                phase = phase, label = label, progress = progress, notice = notice,
                s3Updated = s3Updated,
            ),
            combinedStale = combinedStale, s3Stale = s3Stale,
        )

        val running = banner(CombinedUpdatePhase.UPDATING_S3, label = "Sending board firmware", progress = 0.426f)
        assertEquals("Updating board firmware", running.title)
        assertEquals("Sending board firmware · 43%", running.kicker)
        // Each running phase has its own title and its own fallback label when the coordinator
        // has not published one yet.
        assertEquals("Checking firmware", banner(CombinedUpdatePhase.CHECKING).title)
        assertEquals("finding the right update for this beacon · 0%", banner(CombinedUpdatePhase.CHECKING).kicker)
        assertEquals("Firmware update · reconnecting", banner(CombinedUpdatePhase.RECONNECTING).title)
        assertEquals("Updating second radio", banner(CombinedUpdatePhase.UPDATING_COPROC).title)
        assertEquals("Verifying firmware update", banner(CombinedUpdatePhase.VERIFYING).title)
        assertEquals("confirming the installed version · 0%", banner(CombinedUpdatePhase.VERIFYING).kicker)
        assertEquals("the board is restarting · 100%", banner(CombinedUpdatePhase.RECONNECTING, progress = 7f).kicker)

        val done = banner(CombinedUpdatePhase.DONE)
        assertEquals("Firmware update complete", done.title)
        assertEquals("this beacon is up to date", done.kicker)
        assertEquals("Both updates completed.", banner(CombinedUpdatePhase.DONE, notice = "Both updates completed.").kicker)

        val partialBoard = banner(CombinedUpdatePhase.PARTIAL, s3Updated = true)
        assertEquals("Firmware update incomplete", partialBoard.title)
        assertEquals("board updated · second radio still needs attention", partialBoard.kicker)
        assertEquals("second radio still needs attention", banner(CombinedUpdatePhase.PARTIAL).kicker)

        val coprocOnly = banner(CombinedUpdatePhase.IDLE, installed = "2.0.8", combinedStale = true)
        assertEquals("Second radio update ready", coprocOnly.title)
        assertEquals("co-processor firmware · installs over Bluetooth", coprocOnly.kicker)
        val board = banner(CombinedUpdatePhase.IDLE, combinedStale = true, s3Stale = true)
        assertEquals("Firmware v2.0.8 ready", board.title)
        assertEquals("installed v2.0.7 · updates over Bluetooth", board.kicker)
        // No made-up "v-" before the board's version has been read.
        assertEquals(
            "installed version unavailable · updates over Bluetooth",
            banner(CombinedUpdatePhase.IDLE, installed = null, combinedStale = true, s3Stale = true).kicker,
        )
    }

    /** shouldPromoteFirmwareBanner promotes on an outdated board alone, and with combinedStale
     *  false FirmwareCard's `outdated` arm offers only the browser flasher, so the header may not
     *  promise a Bluetooth install. Restoring "updates over Bluetooth" to the IDLE fallback arm of
     *  firmwareBannerPresentation fails this; so does dropping it from the one-click arm. */
    @Test
    fun browserOnlyUpdateBannerDoesNotPromiseBluetooth() {
        assertTrue(shouldPromoteFirmwareBanner(
            boardFirmwareOutdated = true,
            combinedUpdateAvailable = false,
            combined = CombinedUpdateProgress(),
        ))
        val browserOnly = firmwareBannerPresentation(
            latest = "2.0.8",
            installed = "2.0.7",
            combined = CombinedUpdateProgress(),
            combinedStale = false,
            s3Stale = false,
        )
        assertEquals(FirmwareBannerKind.READY, browserOnly.kind)
        assertFalse(browserOnly.kicker.contains("Bluetooth", ignoreCase = true))
        // Same words as the iOS beaconFirmwareBannerPresentation fallback arm.
        assertEquals("installed v2.0.7 · open for update options", browserOnly.kicker)

        val oneClick = firmwareBannerPresentation(
            latest = "2.0.8",
            installed = "2.0.7",
            combined = CombinedUpdateProgress(),
            combinedStale = true,
            s3Stale = true,
        )
        assertEquals("installed v2.0.7 · updates over Bluetooth", oneClick.kicker)
    }

    @Test
    fun firmwareStartRequiresCurrentReadyBoardButTerminalDismissDoesNotUseThisGate() {
        assertTrue(beaconBoardControlsAvailable(
            demo = true,
            reconnecting = false,
            state = ConnState.DISCONNECTED,
            hasStatus = false,
            combinedRunning = false,
            nrfUpdating = false,
        ))
        assertFalse(beaconBoardControlsAvailable(
            demo = false,
            reconnecting = true,
            state = ConnState.CONNECTING,
            hasStatus = true,
            combinedRunning = false,
            nrfUpdating = false,
        ))
        assertTrue(canStartBeaconFirmwareAction(
            demo = false,
            reconnecting = false,
            state = ConnState.READY,
            hasStatus = true,
            combinedRunning = false,
            nrfUpdating = false,
        ))
        assertFalse(canStartBeaconFirmwareAction(false, true, ConnState.CONNECTING,
            hasStatus = true, combinedRunning = false, nrfUpdating = false))
        assertFalse(canStartBeaconFirmwareAction(false, false, ConnState.READY,
            hasStatus = false, combinedRunning = false, nrfUpdating = false))
        assertFalse(canStartBeaconFirmwareAction(false, false, ConnState.READY,
            hasStatus = true, combinedRunning = true, nrfUpdating = false))
        assertFalse(canStartBeaconFirmwareAction(false, false, ConnState.READY,
            hasStatus = true, combinedRunning = false, nrfUpdating = true))
        assertFalse(canStartBeaconFirmwareAction(true, false, ConnState.READY,
            hasStatus = true, combinedRunning = false, nrfUpdating = false))
    }
}
