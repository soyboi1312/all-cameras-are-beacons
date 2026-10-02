package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.DeviceType

/** The dossier's clock-derived labels, [relativeAgo] ("4m ago") and [seenSpan] ("18m", which
 *  CONFIRM IT renders as "over 18m"), are pure in (stamp, nowMs), and DetailScreen.kt hands both
 *  its 1 s tick. Before 2026-09-10 both read the wall clock inside the call and nothing
 *  recomposed the dossier on a timer, so an open dossier held its last age while no frame
 *  arrived. These tests pass an explicit nowMs that is nowhere near the wall clock, so an
 *  implementation that measures to System.currentTimeMillis() instead of nowMs cannot produce
 *  these answers.
 *
 *  What this cannot pin: a DetailScreen.kt call site that stops passing nowMs. relativeAgo keeps a
 *  wall-clock default for MapScreen checkedAgo, so such a call still compiles; seenSpan has no
 *  default, so ConfirmItPanel cannot drop it silently.
 *
 *  Since Route A this file also pins the dossier's pure row presenters (methodChipLabel,
 *  dossierConfidenceLine, dossierValueForDisplay, dossierActionsStacked), so the dossier's tests stay in one file. */
class DetailTimeLabelsTest {

    /** A 1970 stamp against a tick 61 s later. Measured to the wall clock instead, the same stamp
     *  is about 20,000 days old, so both assertions fail if nowMs stops reaching the arithmetic. */
    @Test
    fun agesAreMeasuredToTheTickNotTheWallClock() {
        assertEquals("1m ago", relativeAgo(0L, 61_000L))
        assertEquals("1m", seenSpan(0L, 61_000L))
    }

    /** The other direction: a stamp ten days AHEAD of the wall clock, measured to a tick three
     *  hours after it. A wall-clock implementation sees a future stamp and clamps it to "now" and
     *  "1s", so these fail too. */
    @Test
    fun aStampAheadOfTheWallClockStillAgesAgainstTheTick() {
        val stamp = System.currentTimeMillis() + 10 * 86_400_000L
        val tick = stamp + 3 * 3_600_000L
        assertEquals("3h ago", relativeAgo(stamp, tick))
        assertEquals("3h", seenSpan(stamp, tick))
    }

    /** One tick crosses a bucket edge, which is the reason the dossier ticks at all: with no new
     *  frame, the label must still change when nowMs moves by one second. */
    @Test
    fun oneTickMovesTheLabelAcrossAnEdge() {
        val first = 1_757_000_000_000L
        assertEquals("59s ago", relativeAgo(first, first + 59_000L))
        assertEquals("1m ago", relativeAgo(first, first + 60_000L))
        assertEquals("59s", seenSpan(first, first + 59_000L))
        assertEquals("1m", seenSpan(first, first + 60_000L))
    }

    /** The same buckets and edges as iOS `dossierRelativeAgo(_:now:)` in DetectionDetailView.swift,
     *  which DetectionDetailTimeTests pins: under 5 s is "now", then whole seconds, minutes, hours
     *  and days, each rounded down. check-signature-drift.py's "dossier time labels" rule pins the
     *  same buckets in both bodies. */
    @Test
    fun relativeAgoBucketsAndEdges() {
        val t = 1_757_000_000_000L
        assertEquals("-", relativeAgo(null, t))
        assertEquals("now", relativeAgo(t, t))
        assertEquals("now", relativeAgo(t, t + 4_999L))
        assertEquals("5s ago", relativeAgo(t, t + 5_000L))
        assertEquals("59m ago", relativeAgo(t, t + 3_599_999L))
        assertEquals("1h ago", relativeAgo(t, t + 3_600_000L))
        assertEquals("23h ago", relativeAgo(t, t + 86_399_999L))
        assertEquals("1d ago", relativeAgo(t, t + 86_400_000L))
        // A stamp a little ahead of the tick (a backward clock step) reads "now", never a
        // negative age.
        assertEquals("now", relativeAgo(t + 2_000L, t))
    }

    /** The same buckets as iOS `dossierSightingSpan(since:now:)` in DetectionDetailView.swift,
     *  which DetectionDetailTimeTests pins, with the same floor of 1 s: a fresh detection reads
     *  "over 1s", never "over 0s". check-signature-drift.py's "dossier time labels" rule pins the
     *  same buckets in both bodies. null drops the "over X" clause when the first sighting has no
     *  time; iOS makes that call in the view's `sightingSpan`, not in the pure function. */
    @Test
    fun seenSpanBucketsAndFloor() {
        val t = 1_757_000_000_000L
        assertNull(seenSpan(null, t))
        assertEquals("1s", seenSpan(t, t))
        assertEquals("1s", seenSpan(t + 2_000L, t))
        assertEquals("45s", seenSpan(t, t + 45_000L))
        assertEquals("59m", seenSpan(t, t + 3_599_999L))
        assertEquals("1h", seenSpan(t, t + 3_600_000L))
        assertEquals("1d", seenSpan(t, t + 86_400_000L))
    }

    /** The "matched on" row. A maker on an OUI hit means the block is the maker's own, so it
     *  reads VENDOR ONLY, never CHIPSET ONLY; every other method reads its own label verbatim,
     *  casing kept (U3-c), as iOS methodChipLabel does. Swapping the two OUI arms fails the first
     *  assertion; "NAME MATCH" fails the third; a `.lowercase()` ("manufacturer id") the fourth. */
    @Test
    fun methodChipLabelPrefersVendorOnlyOverChipsetOnly() {
        assertEquals("OUI · VENDOR ONLY", methodChipLabel(DeviceType.BODY_CAM, 1, "Axon Enterprise", "OUI match"))
        assertEquals("OUI · CHIPSET ONLY", methodChipLabel(DeviceType.FLOCK_CAMERA, 1, null, "OUI match"))
        assertEquals("device name", methodChipLabel(DeviceType.TRACKER, 2, null, "device name"))
        assertEquals("manufacturer ID", methodChipLabel(DeviceType.GLASSES, 3, null, "manufacturer ID"))
        assertEquals("Remote ID", methodChipLabel(DeviceType.DRONE, 7, null, "Remote ID"))
    }

    /** A Desert-mode row matched no signature, so no dossier line calls it a match, whatever method
     *  desert_detect.cpp stamped (SSID on WiFi, none on BLE): "matched on" reads "no signature",
     *  confidence reads "Not a match" with no percent, and the flagged line names only the radio.
     *  The same method or confidence on any other type keeps its usual words. Wrong inputs: keying
     *  on the method or the number instead of the type fails a non-Desert assertion; dropping an
     *  arm fails its Desert assertion. TWIN: iOS DetectionDetailTimeTests
     *  testNearbyDeviceRowsClaimNoSignature. */
    @Test
    fun nearbyDeviceRowsClaimNoSignature() {
        assertEquals("no signature", methodChipLabel(DeviceType.NEARBY_DEVICE, 5, null, "SSID"))
        assertEquals("no signature", methodChipLabel(DeviceType.NEARBY_DEVICE, 0, null, "unknown"))
        assertEquals("SSID", methodChipLabel(DeviceType.FLOCK_CAMERA, 5, null, "SSID"))
        assertEquals("Not a match", dossierConfidenceLine(DeviceType.NEARBY_DEVICE, 0))
        assertEquals("Weak match, verify · 0%", dossierConfidenceLine(DeviceType.UNKNOWN, 0))
        assertEquals("Heard over WiFi in desert mode.", dossierFlaggedLine(DeviceType.NEARBY_DEVICE, "SSID", "WiFi"))
        assertEquals("Heard over BLE in desert mode.", dossierFlaggedLine(DeviceType.NEARBY_DEVICE, "unknown", "BLE"))
        assertEquals("Flagged by SSID over WiFi.", dossierFlaggedLine(DeviceType.FLOCK_CAMERA, "SSID", "WiFi"))
    }

    /** The Desert-mode explainer: the no-match sentence, then a gloss on the firmware's address
     *  label when it is one of the three desert_detect.cpp writes. Wrong inputs: swapping two arms
     *  fails the label check; an arm that drops the base fails the prefix check; a gloss on an
     *  unknown label or a buffered row (no detail) fails the last two. TWIN: iOS
     *  DetectionDetailTimeTests testNearbyDeviceLineSaysNoSignatureMatched. */
    @Test
    fun nearbyDeviceLineSaysNoSignatureMatched() {
        val base = "Desert mode lists every nearby device it hears, and no signature matched this one."
        for (label in listOf("randomized MAC", "hardware OUI", "OUI unknown")) {
            val line = dossierNearbyDeviceLine(label)
            assertTrue(line, line.startsWith("$base \"$label\" means "))
        }
        assertEquals(base, dossierNearbyDeviceLine(null))
        assertEquals(base, dossierNearbyDeviceLine("some future label"))
    }

    /** The "confidence" row: the verdict, then the percent, at the verdict edges 50 and 80 (the
     *  same thresholds as iOS). A verdict that read 50 as weak, or a percent placed first, fails. */
    @Test
    fun confidenceRowReadsTheVerdictThenThePercent() {
        assertEquals("Weak match, verify · 49%", dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 49))
        assertEquals("Partial match · 50%", dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 50))
        assertEquals("Partial match · 79%", dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 79))
        assertEquals("Strong match · 80%", dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 80))
    }

    /** Watch and Mute sit two-up below font scale 1.5 and stack from it, the threshold
     *  DeviceScreen and StatusScreen use. A mute rule does not stack them (its state renders under
     *  the pair), which is why the rule takes no argument here. A `>` threshold keeps 1.5 two-up
     *  and fails the third assertion; a lower one such as 1.3 fails the second. */
    /** The dossier value as drawn: a no-break space before each middle dot, the iOS
     *  dossierValueForDisplay substitution, so at a large font scale "Strong match · 80%" never
     *  starts a line with "· 80%". Written with escapes, so a literal the editor turned into a
     *  plain space cannot make it pass. The builder's string (dossierConfidenceLine) stays as the
     *  test above pins it; the display form differs from it only at the dot. A helper that did
     *  nothing, bound the space AFTER the dot (segmentLabelForDisplay's rule) or also touched a
     *  value with no dot fails. */
    @Test
    fun dossierValueHoldsEachMiddleDotToTheWordBeforeIt() {
        assertEquals("Strong match\u00A0\u00B7 80%", dossierValueForDisplay(dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 80)))
        assertEquals("12\u00A0\u00B7 first ~3 min ago", dossierValueForDisplay("12 \u00B7 first ~3 min ago"))
        assertEquals("a\u00A0\u00B7 b\u00A0\u00B7 c", dossierValueForDisplay("a \u00B7 b \u00B7 c"))
        assertEquals("AA:BB:CC:DD:EE:FF", dossierValueForDisplay("AA:BB:CC:DD:EE:FF"))
        assertTrue(dossierConfidenceLine(DeviceType.FLOCK_CAMERA, 80).contains(" \u00B7 "))
    }

    @Test
    fun actionsStackFromFontScaleOnePointFive() {
        assertFalse(dossierActionsStacked(1.0f))
        assertFalse(dossierActionsStacked(1.49f))
        assertTrue(dossierActionsStacked(1.5f))
        assertTrue(dossierActionsStacked(2.0f))
    }
    /** C12-03: in sample data the Technical details "Last seen" row reads "now", the same demo arm
     *  that keeps the SIGNAL header off STALE (it reads SAMPLE, U1-b), and never computes the measured age; a real row keeps its
     *  measured reading. Wrong input: the old row printed relativeAgo of the seed stamp, "9m ago"
     *  under LIVE. TWIN: iOS DetectionDetailTimeTests (dossierLastSeenValue). */
    @Test
    fun sampleDataLastSeenReadsNowLikeTheLiveHeader() {
        val now = 1_800_000_000_000L
        val seeded = now - 9 * 60_000L
        assertEquals("9m ago", relativeAgo(seeded, now))
        assertEquals("now", dossierLastSeenValue(demo = true) { error("sample rows never measure an age") })
        assertEquals("9m ago", dossierLastSeenValue(demo = false) { relativeAgo(seeded, now) })
    }

    /** U1-b: the SIGNAL header word. Sample rows read SAMPLE (never LIVE, which claims a real
     *  reading); real rows read STALE / LIVE from the clock. Wrong input: demo -> "LIVE" fails the
     *  first assertion. TWIN: iOS DetectionDetailTimeTests (dossierSignalWord). */
    @Test
    fun signalWordReadsSampleForSampleRows() {
        assertEquals("SAMPLE", dossierSignalWord(demo = true, stale = false))
        assertEquals("STALE", dossierSignalWord(demo = false, stale = true))
        assertEquals("LIVE", dossierSignalWord(demo = false, stale = false))
    }

    /** U3-a: a drone's method and source are both "Remote ID", so it says it once. Wrong input:
     *  the old template, "Flagged by Remote ID over Remote ID.". */
    @Test
    fun flaggedLineNeverRepeatsTheSameWord() {
        assertEquals("Flagged by Remote ID.", dossierFlaggedLine(DeviceType.DRONE, "Remote ID", "Remote ID"))
        assertEquals("Flagged by OUI match over WiFi.", dossierFlaggedLine(DeviceType.FLOCK_CAMERA, "OUI match", "WiFi"))
    }

    /** U3-b: the hero subtitle drops the maker when the headline already says it (ignoring case),
     *  with no fuzzy match. Wrong input: always append (the first two fail). */
    @Test
    fun heroSubtitleDropsAMakerTheHeadlineAlreadySays() {
        assertEquals("NODE AABB", dossierHeroSubtitle("AABB", "Apple Find My", "Apple Find My"))
        assertEquals("NODE 5E6F", dossierHeroSubtitle("5E6F", "Meta", "Meta"))
        assertEquals("NODE 2A10 · Flock Safety", dossierHeroSubtitle("2A10", "Flock Safety", "FlockSafety"))
    }

    /** U3-f: the body-cam fallback sentence names the offline buffer only for a real replay.
     *  Wrong input: gating on "detail is nil" would hand a live row the replay sentence. TWIN: iOS
     *  DetectionDetailTimeTests (dossierBodyCamFallbackLine). */
    @Test
    fun bodyCamFallbackNamesTheBufferOnlyForAReplay() {
        assertEquals(
            "Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired.",
            dossierBodyCamFallbackLine(replay = true),
        )
        assertEquals(
            "Matched a body-worn camera signature. The board didn't report which one.",
            dossierBodyCamFallbackLine(replay = false),
        )
    }

    /** U3-g: the tracker "(offline)" gloss needs the tracker category AND the suffix. Wrong input:
     *  gating on the suffix alone fails the body-cam case. */
    @Test
    fun trackerOfflineNoteNeedsATrackerAndTheSuffix() {
        assertEquals(
            "offline here means separated from its owner, not replayed from the offline buffer.",
            trackerOfflineNote(DeviceType.TRACKER, "Apple Find My (offline)"),
        )
        assertNull(trackerOfflineNote(DeviceType.TRACKER, "Tile"))
        assertNull(trackerOfflineNote(DeviceType.BODY_CAM, "x (offline)"))
        assertNull(trackerOfflineNote(DeviceType.TRACKER, null))
    }

    /** U3-h: the signal graph sits on one fixed dBm scale, -100 (bottom) to -30 (top), clamped.
     *  Wrong input: a per-series min...max, where a [-88, -86] series reaches 1.0 and the relative
     *  assertions fail. TWIN: iOS signalGraphFraction(rssi:), same five points. */
    @Test
    fun signalGraphUsesOneFixedDbmScale() {
        assertEquals(-100, SIGNAL_GRAPH_FLOOR_DBM)
        assertEquals(-30, SIGNAL_GRAPH_CEILING_DBM)
        assertEquals(1f, signalGraphFraction(-30), 1e-6f)
        assertEquals(0f, signalGraphFraction(-100), 1e-6f)
        assertEquals(0.5f, signalGraphFraction(-65), 1e-6f)
        assertEquals(1f, signalGraphFraction(-20), 1e-6f)
        assertEquals(0f, signalGraphFraction(-110), 1e-6f)
        assertTrue(signalGraphFraction(-88) < signalGraphFraction(-54))
        assertTrue(signalGraphFraction(-88) < 0.25f)
        assertTrue(signalGraphFraction(-86) < 0.25f)
    }
}
