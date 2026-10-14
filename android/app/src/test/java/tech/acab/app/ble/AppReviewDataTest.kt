package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.maker
import tech.acab.app.ui.logUnreadableNotice
import java.io.File
import java.nio.file.Files

/**
 * The pure rules behind the app review 2026-10-12 Android data-layer fixes. AcabBleManager needs a
 * Context, so each behaviour lives in a top-level function the manager calls and is pinned here;
 * the call sites themselves (fileLive's alert gate, setLocation's board push, the CCCD branch,
 * the connect retry) are not driven by this suite.
 */
class AppReviewDataTest {

    // ---- A.6 / S2: a place rule keeps alerts quiet while it waits on a fix ----

    /** FAILS on the old rule (only ACTIVE entered the muted set, so alerts flowed whenever the
     *  fix missed the bar): the CURRENT_LOCATION_REQUIRED line. Both sides of the set are pinned. */
    @Test
    fun placeRuleAlertGateCoversActiveAndFixRequired() {
        assertTrue(placeRuleSuppressesAlerts(MuteRuleStatus.ACTIVE))
        assertTrue(placeRuleSuppressesAlerts(MuteRuleStatus.CURRENT_LOCATION_REQUIRED))
        assertFalse(placeRuleSuppressesAlerts(MuteRuleStatus.OUTSIDE_RADIUS))
        assertFalse(placeRuleSuppressesAlerts(MuteRuleStatus.EXPIRED))
        assertFalse(placeRuleSuppressesAlerts(MuteRuleStatus.INVALID_PLACE))
    }

    /** The indoor case end to end through the real rule evaluator: a 50 m place rule and a fix
     *  80 m wide evaluates CURRENT_LOCATION_REQUIRED (the row shows) and the alerts stay quiet. */
    @Test
    fun aCoarseIndoorFixKeepsAPlaceMutedDeviceQuiet() {
        val rule = IgnoredDevice(mac = "aa:bb:cc:dd:ee:ff", label = "camera", latitude = 1.0, longitude = 2.0)
        val coarse = MutePosition(1.0 to 2.0, horizontalAccuracyMeters = 80.0)
        val status = evaluateMuteRule(rule, now = 0L, currentPosition = coarse) { _, _ -> 0.0 }
        assertEquals(MuteRuleStatus.CURRENT_LOCATION_REQUIRED, status)
        assertTrue(placeRuleSuppressesAlerts(status))
    }

    // ---- A.8 / S3: observer fixes need a real accuracy ----

    /** FAILS on the old age-only gate: the null, negative, NaN and 250.1 m lines all passed it.
     *  Both sides of the 250 m bar and of the 120 s age rule are pinned. */
    @Test
    fun observerFixNeedsAgeAndAccuracy() {
        val sec = 1_000_000_000L
        assertTrue(locationFixSupportsObserver(0L, 5.0))
        assertTrue(locationFixSupportsObserver(0L, 250.0))
        assertFalse(locationFixSupportsObserver(0L, 250.1))
        assertFalse(locationFixSupportsObserver(0L, null))          // hasAccuracy() false
        assertFalse(locationFixSupportsObserver(0L, -1.0))
        assertFalse(locationFixSupportsObserver(0L, Double.NaN))
        assertTrue(locationFixSupportsObserver(120 * sec, 10.0))
        assertFalse(locationFixSupportsObserver(120 * sec + 1, 10.0))
        assertFalse(locationFixSupportsObserver(-1L, 10.0))          // a fix from the future
        assertEquals(250f, OBSERVER_FIX_MAX_ACCURACY_M, 0f)
    }

    // ---- B.8 / S4: the mute sheet names the real refusal ----

    /** FAILS on the old sheet logic, which fell through to "list is full" for an unstorable
     *  address: the first line. The guard order (address before fix before capacity) is the
     *  second line, where an unstorable address with no fix still says UNSTORABLE_ADDRESS. */
    @Test
    fun muteRefusalFollowsIgnoreDeviceGuardOrder() {
        val good = MutePosition(1.0 to 2.0, horizontalAccuracyMeters = 10.0)
        assertEquals(MuteRefusal.UNSTORABLE_ADDRESS, muteRefusalFor("not-a-mac", MuteScope.PERMANENT, null, listFull = true))
        assertEquals(MuteRefusal.UNSTORABLE_ADDRESS, muteRefusalFor("not-a-mac", MuteScope.HERE, null, listFull = true))
        assertEquals(MuteRefusal.LOCATION_NEEDED, muteRefusalFor("AA:BB:CC:DD:EE:FF", MuteScope.HERE, null, listFull = true))
        assertEquals(MuteRefusal.LOCATION_NEEDED,
            muteRefusalFor("aa:bb:cc:dd:ee:ff", MuteScope.HERE, good.copy(horizontalAccuracyMeters = 51.0), listFull = true))
        assertEquals(MuteRefusal.LIST_FULL, muteRefusalFor("aa:bb:cc:dd:ee:ff", MuteScope.HERE, good, listFull = true))
        assertEquals(MuteRefusal.LIST_FULL, muteRefusalFor("aa:bb:cc:dd:ee:ff", MuteScope.ONE_DAY, null, listFull = true))
        // Past every guard with room in the list: a save that did not land, never "list is full".
        assertEquals(MuteRefusal.SAVE_FAILED,
            muteRefusalFor("aa:bb:cc:dd:ee:ff", MuteScope.ONE_DAY, null, listFull = false))
    }

    // ---- B.8 / S5 and A.5 / S6: alert text ----

    /** FAILS on the old title (DeviceType.label): "Body Camera" and "ALPR Camera". */
    @Test
    fun alertTitlesAreSentenceCaseInlineLabels() {
        fun title(t: DeviceType) = detectionAlertText(t, t.label, 70, redact = false).first
        assertEquals("ALPR camera", title(DeviceType.FLOCK_CAMERA))
        assertEquals("Body cam", title(DeviceType.BODY_CAM))
        assertEquals("Drone", title(DeviceType.DRONE))
        assertEquals("Recording glasses", title(DeviceType.GLASSES))
        assertEquals("Network camera", title(DeviceType.NETWORK_CAMERA))
        assertEquals("Flock Raven", title(DeviceType.FLOCK_RAVEN))
    }

    /** Body shape is unchanged: a named device leads, the bare category reads "Detected nearby",
     *  and a name that strips to nothing falls back the same way. The comparison is with `label`
     *  exactly, so a name equal to the new title still leads: the "Body cam" line, the same vector
     *  as iOS AppReviewDataTests (alertText(for:redact:) compares with label too). */
    @Test
    fun alertBodyNamesTheDeviceOrSaysDetectedNearby() {
        assertEquals("Axon Body 4 detected, 72% confidence.",
            detectionAlertText(DeviceType.BODY_CAM, "Axon Body 4", 72, redact = false).second)
        assertEquals("Body cam detected, 72% confidence.",
            detectionAlertText(DeviceType.BODY_CAM, "Body cam", 72, redact = false).second)
        assertEquals("Detected nearby, 72% confidence.",
            detectionAlertText(DeviceType.BODY_CAM, DeviceType.BODY_CAM.label, 72, redact = false).second)
        assertEquals("Detected nearby, 72% confidence.",
            detectionAlertText(DeviceType.TRACKER, "‮\n", 72, redact = false).second)
    }

    /** FAILS on the old notifier, which kept the category and the name in the alert itself while
     *  redaction was on. The sentence is the iOS placeholder too (S6), so it is pinned literally. */
    @Test
    fun redactedAlertIsGeneric() {
        val (title, body) = detectionAlertText(DeviceType.TRACKER, "AirTag", 90, redact = true)
        assertEquals("beacons", title)
        assertEquals("Something was detected nearby.", body)
        assertEquals(REDACTED_ALERT_BODY, body)
    }

    // ---- B.3: only a key failure blames key storage ----

    /** FAILS on the old Boolean, which sent every false (a duplicate CCCD success landing on
     *  "already running", a refused queue) to the key-storage hint: the ALREADY_RUNNING and
     *  NOT_QUEUED lines. */
    @Test
    fun handshakeStartReasonsMapToTheirOwnHints() {
        assertNull(startupHandshakeFailure(BufferHandshakeStart.STARTED))
        assertNull(startupHandshakeFailure(BufferHandshakeStart.ALREADY_RUNNING))
        assertEquals(SecureSetupFailure.BUFFER_KEY_UNAVAILABLE,
            startupHandshakeFailure(BufferHandshakeStart.KEY_UNAVAILABLE))
        assertEquals(SecureSetupFailure.BUFFER_HANDSHAKE_FAILED,
            startupHandshakeFailure(BufferHandshakeStart.NOT_QUEUED))
    }

    /** The key carries no unlock requirement on Android, so the hint must not send the user to
     *  unlock. FAILS on the old "Unlock your phone and reconnect." */
    @Test
    fun keyStorageHintDoesNotAdviseUnlocking() {
        assertFalse(AcabBleManager.BUFFER_KEY_UNAVAILABLE_HINT.contains("unlock", ignoreCase = true))
        assertTrue(AcabBleManager.BUFFER_KEY_UNAVAILABLE_HINT.startsWith("Secure buffer key storage is unavailable."))
    }

    // ---- B.6: one quiet retry for a fresh connect's error drop ----

    /** FAILS on the old code, which never retried: the first line. Both sides of each input. */
    @Test
    fun freshLinkDropRetriesOncePerTap() {
        assertTrue(retriesFreshLinkDrop(133, freshAttempt = true, alreadyRetried = false))
        assertFalse(retriesFreshLinkDrop(0, freshAttempt = true, alreadyRetried = false))     // GATT_SUCCESS
        assertFalse(retriesFreshLinkDrop(133, freshAttempt = true, alreadyRetried = true))
        assertFalse(retriesFreshLinkDrop(133, freshAttempt = false, alreadyRetried = false))
    }

    // ---- A.3: an unreadable evidence file is kept, never overwritten ----

    /** A decrypt failure (the unseal throws, as it does on an empty or partial file) and a parse
     *  failure both read as unreadable; a sealed or legacy array reads. */
    @Test
    fun persistedLogReadsOrReportsUnreadable() {
        assertEquals(1, persistedLogRows("""[{"m":"x"}]""") { error("legacy plaintext is not unsealed") }!!.length())
        assertEquals(0, persistedLogRows("ab:cd") { "[]" }!!.length())
        assertNull(persistedLogRows("ab:cd") { throw javax.crypto.AEADBadTagException() })
        assertNull(persistedLogRows("") { throw IndexOutOfBoundsException() })
        assertNull(persistedLogRows("ab:cd") { "not json" })
        assertNull(persistedLogRows("[truncated") { "[]" })
    }

    /** FAILS if the set-aside renames onto an existing kept file (rename(2) would replace it): the
     *  first kept file's content check after the second set-aside in the same millisecond. */
    @Test
    fun setAsideKeepsEveryUnreadableFile() {
        val dir = Files.createTempDirectory("acab-store").toFile()
        try {
            val store = File(dir, "detections.json")
            store.writeText("first")
            val kept1 = setAsideUnreadableLog(store, 123L)
            assertNotNull(kept1)
            assertEquals("detections.json.unreadable-123", kept1!!.name)
            assertFalse(store.exists())
            assertEquals("first", kept1.readText())

            store.writeText("second")
            val kept2 = setAsideUnreadableLog(store, 123L)
            assertEquals("detections.json.unreadable-123-1", kept2!!.name)
            assertEquals("second", kept2.readText())
            assertEquals("first", kept1.readText())

            assertNull(setAsideUnreadableLog(store, 124L))   // nothing left to move
        } finally {
            dir.deleteRecursively()
        }
    }

    /** Clear Log deletes the set-aside files too: they hold MACs and GPS. FAILS on the old delete,
     *  which checked and removed only the store and its staging file: the first call returns true
     *  with both unreadable files still on disk, and the lone-unreadable call returns true without
     *  touching it. A file that only shares the prefix's stem stays. */
    @Test
    fun clearDeletesSetAsideLogs() {
        val dir = Files.createTempDirectory("acab-clear").toFile()
        try {
            val store = File(dir, "detections.json")
            val temp = File(dir, "detections.json.tmp")
            val kept1 = File(dir, "detections.json.unreadable-123")
            val kept2 = File(dir, "detections.json.unreadable-123-1")
            val other = File(dir, "detections.json.bak")
            for (f in listOf(store, temp, kept1, kept2, other)) f.writeText("x")

            assertTrue(deletePersistedLogFiles(store, temp))
            for (f in listOf(store, temp, kept1, kept2)) assertFalse(f.name, f.exists())
            assertTrue(other.exists())

            kept1.writeText("only this one")
            assertTrue(deletePersistedLogFiles(store, temp))
            assertFalse(kept1.exists())
            assertTrue(deletePersistedLogFiles(store, temp))   // nothing left: confirmed absent
        } finally {
            dir.deleteRecursively()
        }
    }

    /** The Log shows the set-aside notice outside sample data only, in the twin sentence. FAILS if
     *  the sample-data gate is dropped: the demo line. The literal is iOS
     *  BLEManager.unreadableLogNoticeText too, pinned the same way in iOS AppReviewDataTests, so a
     *  one-sided copy edit fails one of the two suites. */
    @Test
    fun unreadableLogNoticeShowsOutsideSampleDataOnly() {
        val sentence = "an earlier saved log could not be opened, so this phone kept it aside and started a new one."
        assertEquals(sentence, AcabBleManager.UNREADABLE_LOG_NOTICE)
        assertEquals(sentence, logUnreadableNotice(AcabBleManager.UNREADABLE_LOG_NOTICE, demo = false))
        assertNull(logUnreadableNotice(AcabBleManager.UNREADABLE_LOG_NOTICE, demo = true))
        assertNull(logUnreadableNotice(null, demo = false))
    }

    // ---- U2: Mark Seen never baselines the live axis past now ----

    /** FAILS on the old pick (the newest real stamp, unclamped): the future-stamp line returns
     *  now + 60_000, which would mark every live row first heard in the next minute as seen.
     *  A past stamp is kept, pseudo stamps are ignored, and no real stamp gives now. */
    @Test
    fun markSeenLiveWatermarkClampsToNow() {
        val now = 1_800_000_000_000L
        val pseudo = AcabBleManager.HIST_PSEUDO_BASE - 5L
        assertEquals(now, liveSeenWatermark(listOf(now - 5_000L, now + 60_000L), now))
        assertEquals(now - 5_000L, liveSeenWatermark(listOf(now - 9_000L, now - 5_000L, pseudo), now))
        assertEquals(now, liveSeenWatermark(listOf(pseudo), now))
        assertEquals(now, liveSeenWatermark(emptyList(), now))
    }

    // ---- A.10: a Live Mode tile tap is a request for a minute, not forever ----

    /** FAILS on the old no-expiry flag, which honoured a tap however old: the 60_001 ms line. Both
     *  sides of the bar, no request (0), and a stamp from the future (a clock it cannot be). */
    @Test
    fun tileDriveRequestExpiresAfterAMinute() {
        assertEquals(60_000L, tech.acab.app.TILE_DRIVE_REQUEST_MAX_AGE_MS)
        assertTrue(tech.acab.app.tileDriveRequestFresh(1_000L, 1_000L))
        assertTrue(tech.acab.app.tileDriveRequestFresh(1_000L, 61_000L))
        assertFalse(tech.acab.app.tileDriveRequestFresh(1_000L, 61_001L))
        assertFalse(tech.acab.app.tileDriveRequestFresh(0L, 1_000L))
        assertFalse(tech.acab.app.tileDriveRequestFresh(2_000L, 1_000L))
    }

    /** "Apple AirTag" only for the AirTag string a firmware after 2.2.1 sends (the status byte
     *  declared an AirTag); the generic Find My string keeps "Apple Find My", which most separated
     *  frames are (offline Apple devices, third-party tags, AirPods). FAILS before the AirTag key:
     *  maker was null.
     *  TWIN: iOS AppReviewDataTests.testTrackerTitleIsAirTagOnlyWhenDeclared. */
    @Test
    fun trackerTitleIsAirTagOnlyWhenDeclared() {
        fun maker(det: String) = Detection.fromJson(
            JSONObject().put("t", DeviceType.TRACKER.raw).put("s", 0).put("meth", 3).put("c", 85)
                .put("mac", "aa:bb:cc:dd:ee:01").put("rssi", -60).put("det", det),
        ).maker
        assertEquals("Apple AirTag", maker("Apple AirTag (offline)"))
        assertEquals("Apple Find My", maker("Apple Find My (offline)"))
    }
}
