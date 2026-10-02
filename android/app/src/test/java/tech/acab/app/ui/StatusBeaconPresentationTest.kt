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
import tech.acab.app.ble.LOG_ACTIVE_SECTION_HEADER
import tech.acab.app.ble.OtaPhase
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.model.displayName
import tech.acab.app.model.titleName

class StatusBeaconPresentationTest {
    private fun row(
        mac: String,
        type: DeviceType,
        rssi: Int = -70,
    ) = Detection.fromJson(
        JSONObject().put("t", type.raw).put("c", 80).put("mac", mac).put("rssi", rssi))

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
            "matches and watched devices first · counts include every recent device",
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
        assertEquals("signatures or your watchlist", STATUS_MATCHED_CARD_DETAIL)
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
            "3 MATCHED + WATCHED, signatures or your watchlist",
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
     *  (null here is the SAMPLE pill, which LinkChip draws for sample mode). Each case also turns on
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
     *  its own: beaconConnectionPresentation feeds the Beacon hero's two lines, read before the
     *  row above. Every call to it outside that block leaves
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
        // no radio line, no scan and no fault banner until the reboot window closes.
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

        // The Beacon tab's Scan radios row value, the same three moments. This is the split
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

        // The Beacon hero's two lines, which take this fact through their OWN arm in
        // beaconConnectionPresentation rather than through the row above. Same moment as `gap`:
        // the reboot drop cleared the frame and the reconnect landed READY, so hasStatus is false.
        val header = beaconConnectionPresentation(
            false, false, ConnState.READY, false, rebootingForUpdate = true,
        )
        assertEquals(gap.label, header.headerKicker)
        assertEquals("UPDATING FIRMWARE · detection may pause", header.heroPrefix)
        // The link is up through the reboot, so only those two lines move: what hangs off
        // `connected` (the refresh action's enabled gate, and currentStatus) stays as it was.
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
     *  template around a name that is not an initialism, and its display name "body cam" (U3-d). */
    @Test
    fun notifyDetectorOffWarningKeepsTheAlprInitialism() {
        assertEquals(
            "the ALPR camera detector is off, so this won't fire. turn it on under Detectors.",
            notifyDetectorOffWarning(DeviceType.FLOCK_CAMERA),
        )
        assertEquals(
            "the body cam detector is off, so this won't fire. turn it on under Detectors.",
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

    /** The quiet sentence (the Status first-zero line) says which window zero covers, and the
     *  number comes from ACTIVE_NEARBY_WINDOW_MS, so retuning the window moves the sentence with
     *  it; this pins the shipped number and the opening clause. TWIN: iOS
     *  DashboardPresentationTests.testQuietSentenceNamesTheWindow. */
    @Test
    fun quietSentenceNamesTheWindow() {
        assertTrue(FirstRunTour.QUIET_SENTENCE.contains("in the last 45 seconds."))
        assertTrue(FirstRunTour.QUIET_SENTENCE.startsWith("quiet does not mean clear. "))
    }

    /** The Log's first time-section header is built from ACTIVE_NEARBY_WINDOW_MS, so retuning the
     *  window moves the copy with it; this pins the shipped number. TWIN: iOS
     *  DashboardPresentationTests.testActiveSectionHeaderNamesTheWindow. */
    @Test
    fun activeSectionHeaderNamesTheWindow() {
        assertEquals("heard in the last 45 s", LOG_ACTIVE_SECTION_HEADER)
    }

    @Test
    fun sampleTrackerSwitchEchoesIntoTheStatusOffTileWithoutRemovingItsRecentCount() {
        val sample = DeviceStatus.fromJson(JSONObject(
            """{"fw":"beacon board 2.0.8","tracker":true,"ble":true,"wifi":true}""",
        ))
        val trackerOff = sample.copy(tracker = false)
        val tile = statusCountTilePresentation("Tracker", count = 1, enabled = trackerOff.tracker)

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
        // Hour and day arms, the same branches as iOS dashboardLastHeardLabel (STA-P8): two hours
        // reads "2h ago", never "120m ago".
        val later = 200_000_000L
        assertEquals("last heard 59m ago", statusLastHeardAge(later - 3_599_000L, later, demo = false))
        assertEquals("last heard 2h ago", statusLastHeardAge(later - 7_200_000L, later, demo = false))
        assertEquals("last heard 23h ago", statusLastHeardAge(later - 86_399_000L, later, demo = false))
        assertEquals(
            "last heard more than a day ago",
            statusLastHeardAge(later - 86_400_000L, later, demo = false),
        )
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

    /** The Beacon hero draws its second line (the presenter's headerKicker) only when the first
     *  line does not already say it, case aside. Wrong inputs: a case-sensitive compare draws the
     *  first-frame and update-reboot sentences twice; a whole-string compare draws SAMPLE DATA
     *  under SAMPLE DATA · no live board; dropping the rule entirely also fails the lost-link arm. */
    @Test
    fun heroDropsTheSecondLineWhenTheStatusLineRepeatsIt() {
        fun hero(p: BeaconConnectionPresentation, demo: Boolean = false, firmware: String? = null): Pair<String, String?> {
            val status = beaconHeroStatusLine(p, demo = demo, firmware = firmware)
            return status to beaconHeroConnectionLine(status, p.headerKicker)
        }
        val firstFrame = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.READY, hasStatus = false,
        )
        assertEquals("CONNECTED · waiting for board status" to null, hero(firstFrame))

        val reboot = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.READY, hasStatus = false,
            rebootingForUpdate = true,
        )
        assertEquals("UPDATING FIRMWARE · detection may pause" to null, hero(reboot))

        val sample = beaconConnectionPresentation(
            demo = true, reconnecting = false, state = ConnState.READY, hasStatus = true,
        )
        assertEquals("SAMPLE DATA · no live board" to null, hero(sample, demo = true, firmware = "beacon board"))

        val lost = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.DISCONNECTED, hasStatus = false,
        )
        assertEquals("CONNECTION LOST · BOARD STATUS UNAVAILABLE" to null, hero(lost))

        // Lines that say different things both stay.
        val retained = beaconConnectionPresentation(
            demo = false, reconnecting = true, state = ConnState.CONNECTING, hasStatus = true,
        )
        assertEquals(
            "RECONNECTING · last reported · beacon board" to "RECONNECTING · BOARD STATUS UNAVAILABLE",
            hero(retained, firmware = "beacon board"),
        )
        val ready = beaconConnectionPresentation(
            demo = false, reconnecting = false, state = ConnState.READY, hasStatus = true,
        )
        assertEquals("CONNECTED · beacon board" to "CONNECTED OVER BLE", hero(ready, firmware = "beacon board"))
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
        // into the synthetic status and both presenters read them. Since the 2026-09-26 review
        // (P3-8) this row prints the LIVE arm's own words for the echoed switches, not the SAMPLE
        // DATA family the Status header keeps (statusScanPresentation, pinned above): the banner,
        // the pill, the dot and the hero already say sample on that page. iOS's Scan radios row
        // reads the same four literals from sampleRadiosRowValue (BeaconPagePolishTests); the
        // full four-way pin is BeaconScanRadiosSampleTest.
        assertEquals(
            "SCANNING · WI-FI",
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

    /** The Beacon tab's two segments, in order, with every render gate the rows carry: Alerts
     *  leaves on a mesh board (no buzzer), Firmware leaves while an update is promoted to the
     *  banner, System readiness and the saved log never show in the sample tour, Improve detection
     *  only when its gate is true. Wrong inputs: ALERTS listed before DESERT fails the first
     *  assertion; SYSTEM_READINESS without its `!demo` fails the demo assertion.
     *  iOS twin: BeaconPresentationTests.testBeaconRowsFollowTheSharedPartition (iOS also lists
     *  disconnect and power off as rows; Android puts them in the overflow menu. iOS also lists
     *  the phone side's PREFERENCES / SUPPORT header rows; Android derives those two labels from
     *  the group key in beaconGroupHeaderLabel, so this phone list is rows only, decisions R13). */
    @Test
    fun beaconRowsFollowTheSharedPartition() {
        val board = listOf(
            BeaconRowId.HERO, BeaconRowId.UPTIME, BeaconRowId.DETECTIONS, BeaconRowId.DETECTION_HEADER,
            BeaconRowId.SCAN_RADIOS, BeaconRowId.DETECTORS, BeaconRowId.DESERT, BeaconRowId.ON_BOARD_HEADER,
            BeaconRowId.ALERTS, BeaconRowId.BOARD_LED, BeaconRowId.FIRMWARE, BeaconRowId.MANAGED_DEVICES,
        )
        assertEquals(board, beaconRows(BeaconSegment.BOARD, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(board - BeaconRowId.ALERTS, beaconRows(BeaconSegment.BOARD, meshBoard = true,
            firmwareVisible = true, demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(board - BeaconRowId.FIRMWARE, beaconRows(BeaconSegment.BOARD, meshBoard = false,
            firmwareVisible = false, demo = false, improveAvailable = true, hasSavedLog = true))

        val phone = listOf(
            BeaconRowId.NOTIFICATIONS, BeaconRowId.LIVE_MODE, BeaconRowId.DISPLAY,
            BeaconRowId.SYSTEM_READINESS, BeaconRowId.IMPROVE_DETECTION, BeaconRowId.HELP_SUPPORT,
            BeaconRowId.ABOUT, BeaconRowId.SAVED_LOG,
        )
        assertEquals(phone, beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(
            listOf(BeaconRowId.NOTIFICATIONS, BeaconRowId.LIVE_MODE, BeaconRowId.DISPLAY,
                BeaconRowId.HELP_SUPPORT, BeaconRowId.ABOUT),
            beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
                demo = true, improveAvailable = false, hasSavedLog = true),
        )
        assertEquals(phone - BeaconRowId.SAVED_LOG, beaconRows(BeaconSegment.PHONE, meshBoard = false,
            firmwareVisible = true, demo = false, improveAvailable = true, hasSavedLog = false))
    }

    /** The partition cut into groups (decisions R13): the hero card, the Uptime / Detections tile
     *  pair, then DETECTION and ON THE BOARD with their header rows lifted into the header slot,
     *  and the THIS PHONE groups under their iOS keys. Each group with rows under a header or an
     *  intro gets its one line from beaconGroupIntro; the cards get none. Wrong inputs: filing a
     *  header row as a row fails the groups assertion, dropping the mesh gate from the ON THE
     *  BOARD line fails the mesh assertion, and a help line that promises setup checks in the
     *  sample tour fails the demo one. The sentences themselves are pinned byte for byte against
     *  iOS by the drift row "Beacon group intro lines".
     *  iOS twin: BeaconPresentationTests.testBeaconRowsFollowTheSharedPartition (its grouping
     *  block, which also has key 4 for Disconnect and Power off). */
    @Test
    fun beaconRowGroupsFollowTheIosSectionsAndCarryTheirIntros() {
        val board = beaconRows(BeaconSegment.BOARD, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true)
        val groups = beaconRowGroups(board)
        assertEquals(listOf(
            BeaconRowGroup(0, null, listOf(BeaconRowId.HERO)),
            BeaconRowGroup(1, null, listOf(BeaconRowId.UPTIME, BeaconRowId.DETECTIONS)),
            BeaconRowGroup(2, BeaconRowId.DETECTION_HEADER,
                listOf(BeaconRowId.SCAN_RADIOS, BeaconRowId.DETECTORS, BeaconRowId.DESERT)),
            BeaconRowGroup(3, BeaconRowId.ON_BOARD_HEADER, listOf(BeaconRowId.ALERTS, BeaconRowId.BOARD_LED,
                BeaconRowId.FIRMWARE, BeaconRowId.MANAGED_DEVICES)),
        ), groups)
        assertEquals(listOf(true, true, false, false), groups.map { it.isCardGroup })
        val mesh = beaconRowGroups(beaconRows(BeaconSegment.BOARD, meshBoard = true, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(listOf(BeaconRowId.BOARD_LED, BeaconRowId.FIRMWARE, BeaconRowId.MANAGED_DEVICES), mesh[3].rows)

        val phone = beaconRowGroups(beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true))
        assertEquals(listOf(5, 6, 7), phone.map { it.key })
        assertEquals(listOf(
            listOf(BeaconRowId.NOTIFICATIONS, BeaconRowId.LIVE_MODE, BeaconRowId.DISPLAY),
            listOf(BeaconRowId.SYSTEM_READINESS, BeaconRowId.IMPROVE_DETECTION, BeaconRowId.HELP_SUPPORT,
                BeaconRowId.ABOUT),
            listOf(BeaconRowId.SAVED_LOG),
        ), phone.map { it.rows })
        assertFalse(phone.any { it.isCardGroup })

        fun intro(key: Int, mesh: Boolean = false, demo: Boolean = false, word: String = "phone") =
            beaconGroupIntro(key, mesh, demo = demo, deviceWord = word)
        // The cards and the saved-log group have no line.
        assertNull(intro(0))
        assertNull(intro(1))
        assertNull(intro(7))
        assertEquals("radios, detectors, desert mode, and the offline buffer.", intro(2))
        assertEquals("alerts, the board light, firmware, and managed devices.", intro(3))
        assertEquals("the board light, firmware, and managed devices.", intro(3, mesh = true))
        assertEquals("notifications, Live Mode, and display for this phone.", intro(5))
        assertEquals("notifications, Live Mode, and display for this tablet.", intro(5, word = "tablet"))
        assertEquals("setup checks, help, support, and about this app.", intro(6))
        assertEquals("help, support, and about this app.", intro(6, demo = true))
        // The mesh and sample facts each move only their own line.
        assertEquals(intro(2), intro(2, mesh = true, demo = true))
        assertEquals(intro(6), intro(6, mesh = true))
        assertEquals(intro(3), intro(3, demo = true))
    }

    /** Disconnect and Power off moved from the foot of the page into the overflow menu with their
     *  gates unchanged: Disconnect reads "Exit Sample Data" in the tour and is blocked while the
     *  combined update runs; Power off is rev-B only, needs a connected board with a current frame,
     *  never shows in the tour, and is disabled while board controls are unavailable. Wrong input:
     *  the power-off gate without `!demo` gives the demo case a second item. iOS twin:
     *  disconnectButton / showPowerOff in SettingsView.swift. */
    @Test
    fun overflowCarriesTheSlotGates() {
        assertEquals(listOf(BeaconOverflowItem("disconnect", "Exit Sample Data", true)),
            beaconOverflowItems(demo = true, connected = true, hasStatus = true, boardRev = "B",
                combinedRunning = true, boardControlsAvailable = true))
        assertEquals(
            listOf(BeaconOverflowItem("disconnect", "Disconnect", true),
                BeaconOverflowItem("poweroff", "Power Off Beacon", true)),
            beaconOverflowItems(demo = false, connected = true, hasStatus = true, boardRev = "B",
                combinedRunning = false, boardControlsAvailable = true),
        )
        assertEquals(BeaconOverflowItem("disconnect", "Disconnect", false),
            beaconOverflowItems(demo = false, connected = true, hasStatus = true, boardRev = "B",
                combinedRunning = true, boardControlsAvailable = true).first())
        assertEquals(BeaconOverflowItem("poweroff", "Power Off Beacon", false),
            beaconOverflowItems(demo = false, connected = true, hasStatus = true, boardRev = "B",
                combinedRunning = false, boardControlsAvailable = false).last())
        for ((rev, connected, hasStatus) in listOf(
            Triple<String?, Boolean, Boolean>("A", true, true),
            Triple<String?, Boolean, Boolean>(null, true, true),
            Triple<String?, Boolean, Boolean>("B", false, true),
            Triple<String?, Boolean, Boolean>("B", true, false),
        )) {
            assertEquals("rev $rev, connected $connected, status $hasStatus",
                listOf("disconnect"),
                beaconOverflowItems(demo = false, connected = connected, hasStatus = hasStatus,
                    boardRev = rev, combinedRunning = false, boardControlsAvailable = true).map { it.id })
        }
    }

    /** A pushed page draws only while its row is listed, and a board page only while board
     *  controls are available. That second rule is what keeps the restore offer exclusive: the
     *  Desert and Alerts pages carry it, and desertRestoreNeedsDetachedSurface draws the detached
     *  copy exactly when they are withheld (AcabAppStateTest pins that side). Phone pages and
     *  Firmware are not board-gated. Wrong inputs: dropping the board gate makes the first
     *  assertion return DETECTORS; gating every page makes the NOTIFICATIONS and FIRMWARE
     *  assertions return null. */
    @Test
    fun boardPagesDrawOnlyWhileTheBoardAnswersAndTheirRowIsListed() {
        val rows = beaconRows(BeaconSegment.BOARD, meshBoard = false, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true) +
            beaconRows(BeaconSegment.PHONE, meshBoard = false, firmwareVisible = true,
                demo = false, improveAvailable = true, hasSavedLog = true)
        assertNull(beaconPageToDraw(BeaconRowId.DETECTORS, rows, boardControlsAvailable = false))
        assertEquals(BeaconRowId.DETECTORS,
            beaconPageToDraw(BeaconRowId.DETECTORS, rows, boardControlsAvailable = true))
        assertEquals(BeaconRowId.NOTIFICATIONS,
            beaconPageToDraw(BeaconRowId.NOTIFICATIONS, rows, boardControlsAvailable = false))
        assertEquals(BeaconRowId.FIRMWARE,
            beaconPageToDraw(BeaconRowId.FIRMWARE, rows, boardControlsAvailable = false))
        assertNull("the Firmware row leaves while the banner is promoted",
            beaconPageToDraw(BeaconRowId.FIRMWARE, rows - BeaconRowId.FIRMWARE, boardControlsAvailable = true))
        val meshRows = beaconRows(BeaconSegment.BOARD, meshBoard = true, firmwareVisible = true,
            demo = false, improveAvailable = true, hasSavedLog = true)
        assertNull("no Alerts page on a mesh board",
            beaconPageToDraw(BeaconRowId.ALERTS, meshRows, boardControlsAvailable = true))
        assertNull(beaconPageToDraw(null, rows, boardControlsAvailable = true))
    }

    /** U1-d: sample data says sample less on Status. The bare "SAMPLE DATA" kicker is not drawn
     *  (null), the radio variants and every live label are, and the strongest header carries no
     *  suffix in sample data while a real session keeps " · RECENT". Wrong inputs: hiding every
     *  sample label (the second assertion fails); keeping " · SAMPLE" (the header assertion fails).
     *  TWIN: iOS DashboardPresentationTests (dashboardScanKicker, dashboardStrongestHeader). */
    @Test
    fun sampleDataSaysSampleLessOnStatus() {
        assertNull(statusScanKicker("SAMPLE DATA", demo = true))
        assertEquals("SAMPLE DATA · BLUETOOTH ONLY", statusScanKicker("SAMPLE DATA · BLUETOOTH ONLY", demo = true))
        assertEquals("SAMPLE DATA · RADIOS OFF", statusScanKicker("SAMPLE DATA · RADIOS OFF", demo = true))
        assertEquals("SCANNING · BLE · WI-FI", statusScanKicker("SCANNING · BLE · WI-FI", demo = false))
        assertEquals("STRONGEST MATCH", statusStrongestHeader(StatusStrongestKind.MATCHED, demo = true))
        assertEquals("STRONGEST AMBIENT", statusStrongestHeader(StatusStrongestKind.AMBIENT, demo = true))
        assertEquals("STRONGEST MATCH · RECENT", statusStrongestHeader(StatusStrongestKind.MATCHED, demo = false))
        assertEquals("STRONGEST UNCLASSIFIED · RECENT",
            statusStrongestHeader(StatusStrongestKind.UNCLASSIFIED, demo = false))
    }

    /** U3-d: a row with no name, maker or serial is TITLED by the category's display name while
     *  its export value (displayName, the CSV / GPX type column) keeps DeviceType.label. A
     *  Hikvision row keeps its maker title. Wrong inputs: changing `label` (the displayName
     *  assertion and the CSV tests fail) or leaving titleName = displayName (the first fails). */
    @Test
    fun titleNameUsesTheDisplayNameOnlyForTheBareCategory() {
        val bodyCam = row("00:25:df:00:00:01", DeviceType.BODY_CAM)
        assertEquals("body cam", bodyCam.titleName)
        assertEquals("Body Camera", bodyCam.displayName)
        val netcam = row("44:19:b6:00:00:02", DeviceType.NETWORK_CAMERA)
        assertEquals("network camera", netcam.titleName)
        assertEquals("Network camera", netcam.displayName)
        val hikvision = netcam.copy(method = 1, detail = "Hikvision on wifi")
        assertEquals("Hikvision", hikvision.titleName)
        assertEquals("Hikvision", hikvision.displayName)
        assertEquals("network camera", DeviceType.NETWORK_CAMERA.inlineCategory)
        assertEquals("body cam", DeviceType.BODY_CAM.inlineLabel)
    }

    /** U2-b: the THIS PHONE row values name a system block the way iOS does ("· BLOCKED BY IOS"),
     *  and never in sample data. Wrong input: the old kickers, which never said BLOCKED. TWIN: iOS
     *  SettingsView notifyKicker / liveModeState. */
    @Test
    fun thisPhoneRowValuesNameTheAndroidBlock() {
        assertEquals("3 ON · BLOCKED BY ANDROID", beaconNotifyRowValue(3, blockedBySystem = true, demo = false))
        assertEquals("3 ON", beaconNotifyRowValue(3, blockedBySystem = true, demo = true))
        assertEquals("3 ON", beaconNotifyRowValue(3, blockedBySystem = false, demo = false))
        assertEquals("OFF", beaconNotifyRowValue(0, blockedBySystem = true, demo = false))
        assertEquals("LIVE BLOCKED BY ANDROID · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = false, countsPrivate = false, demo = false))
        // Sample data never reads BLOCKED, and since R19 never LIVE either: the switch is a
        // preview there (LiveModePreviewCopyTest pins both sample arms).
        assertEquals("PREVIEW ON · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = false, countsPrivate = false, demo = true))
        assertEquals("LIVE ON · COUNTS PRIVATE",
            beaconLiveRowValue(wanted = true, deliverable = true, countsPrivate = true, demo = false))
        assertEquals("LIVE OFF · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = false, deliverable = false, countsPrivate = false, demo = false))
    }

    /** U2-c: in sample data the notify card promises no permission prompt (its switches are
     *  previews). Wrong input: the permission-prompt sentence in sample data. TWIN: iOS
     *  SettingsView notifyCard's sample sentence ("... and iOS won't ask permission."). */
    @Test
    fun sampleNotifyCardPromisesNoPermissionPrompt() {
        assertEquals(
            "Preview which categories you could enable. Nothing is saved and Android won't ask permission.",
            notifyCardExplainer(demo = true),
        )
        assertEquals(
            "Pick what's worth a notification. Every category is off until you turn it on, and Android asks permission the first time you do.",
            notifyCardExplainer(demo = false),
        )
    }
}
