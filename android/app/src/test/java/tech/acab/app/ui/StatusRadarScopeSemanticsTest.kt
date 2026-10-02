package tech.acab.app.ui

import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.AcabPalette
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.JetBrainsMono

/** The spoken strings behind the Status radar. Plain JUnit, like the rest of this source set:
 *  the semantics modifiers that carry them are checked by reading; these pin the words. */
class StatusRadarScopeSemanticsTest {
    private fun row(
        mac: String,
        type: DeviceType,
        rssi: Int = -70,
    ) = Detection.fromJson(
        JSONObject().put("t", type.raw).put("c", 80).put("mac", mac).put("rssi", rssi))

    @Test
    fun radarContentDescriptionSpeaksCountCapAndCaveat() {
        val ambient = List(15) { row("ambient-$it", DeviceType.NEARBY_DEVICE, -30 - it) }
        val others = listOf(
            row("match", DeviceType.TRACKER, -95),
            row("starred", DeviceType.UNKNOWN, -100),
            row("unknown", DeviceType.UNKNOWN, -99),
        )
        val summary = statusNearbySummary(ambient + others, setOf("starred"))

        // The literal 14, not STATUS_RADAR_DOT_CAP, for the reason StatusBeaconPresentationTest
        // .nearbySummarySeparatesAmbientAndKeepsImportantRowsInsideDotCap gives: the cap is
        // SHARED with iOS. The sentence is byte-identical to iOS RadarScope.accessibilityLabel
        // in Components.swift.
        assertEquals(
            "18 recently heard devices nearby. 14 dots drawn, at most 14, " +
                "with matches and watched devices first. Radar shows signal strength only, not direction.",
            summary.radarContentDescription,
        )
    }

    /** Singular at one and plural otherwise, for the devices and the dots alike, as iOS
     *  RadarScope.accessibilityLabel says it. The one-dot sentence fails on the old "1 dots
     *  drawn"; the empty scope pins that zero stays plural. */
    @Test
    fun radarContentDescriptionIsSingularAtOneDeviceAndOneDot() {
        val one = statusNearbySummary(listOf(row("one", DeviceType.TRACKER)), emptySet())
        assertEquals(
            "1 recently heard device nearby. 1 dot drawn, at most 14, " +
                "with matches and watched devices first. Radar shows signal strength only, not direction.",
            one.radarContentDescription,
        )

        val none = statusNearbySummary(emptyList(), emptySet())
        assertEquals(
            "0 recently heard devices nearby. 0 dots drawn, at most 14, " +
                "with matches and watched devices first. Radar shows signal strength only, not direction.",
            none.radarContentDescription,
        )
    }

    /** The spoken card is count, title, detail, built from the two lines RadarCountCard draws
     *  under the number. StatusBeaconPresentationTest pins the matched card the same way. */
    @Test
    fun radarCountCardDescriptionSpeaksCountThenTitleThenDetail() {
        assertEquals(
            "0 AMBIENT, Desert-mode broadcasts",
            statusRadarCountCardDescription(0, STATUS_AMBIENT_CARD_TITLE, STATUS_AMBIENT_CARD_DETAIL),
        )
    }

    /** The strongest slot's empty state is the quiet sentence, the same FirstRunTour constant, and
     *  only on a connected, real session with nothing heard in the window: never over the sample
     *  tour, never while one device is nearby (the strongest cell owns the slot then), and never
     *  before the link is up. TWIN: iOS
     *  DashboardPresentationTests.testFirstZeroLineOnlyForAConnectedEmptyRealSession. */
    @Test
    fun firstZeroLineOnlyForAConnectedEmptyRealSession() {
        assertSame(FirstRunTour.QUIET_SENTENCE,
            statusFirstZeroLine(connected = true, demo = false, scanning = true, total = 0))
        assertNull(statusFirstZeroLine(connected = true, demo = true, scanning = true, total = 0))
        assertNull(statusFirstZeroLine(connected = true, demo = false, scanning = true, total = 1))
        assertNull(statusFirstZeroLine(connected = false, demo = false, scanning = true, total = 0))
    }

    /** The wrong input for the quiet sentence: a connected board with both radios switched off
     *  and nothing nearby. The quiet sentence says the beacon listened and heard nothing, so it
     *  must not appear; the slot says why the board is not listening instead. TWIN: iOS
     *  DashboardPresentationTests (the STA-1 radios-off case). */
    @Test
    fun radiosOffWithZeroNearbyShowsWhyNotTheQuietSentence() {
        val scan = statusScanPresentation(
            demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = false, wifiIntent = false, coAlive = true, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertFalse(scan.scanning)
        assertNull(statusFirstZeroLine(connected = true, demo = false, scanning = scan.scanning, total = 0))
        assertEquals(
            "Both beacon detection radios are switched off.",
            statusNotScanningLine(connected = true, demo = false, scanning = scan.scanning, total = 0,
                notScanningDetail = scan.notScanningDetail),
        )
    }

    /** A BLE fault with Wi-Fi off and a co-processor update with Wi-Fi off park the sweep too, and
     *  each gets its own sentence; a live scan carries none, so the quiet sentence keeps its slot. */
    @Test
    fun everyParkedArmCarriesASentenceAndALiveScanCarriesNone() {
        fun scan(ble: Boolean, wifi: Boolean, coAlive: Boolean?, nrfUp: Boolean = false, fw: Boolean = false) =
            statusScanPresentation(
                demo = false, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
                bleIntent = ble, wifiIntent = wifi, coAlive = coAlive, nrfUpdating = nrfUp,
                firmwareUpdateRunning = fw,
            )
        assertEquals("The Bluetooth detection radio stopped responding and Wi-Fi scanning is off.",
            scan(ble = true, wifi = false, coAlive = false).notScanningDetail)
        assertEquals("Bluetooth detection is paused for the update and Wi-Fi scanning is off.",
            scan(ble = true, wifi = false, coAlive = false, nrfUp = true).notScanningDetail)
        assertEquals("Keep the app open and the beacon nearby until the update finishes.",
            scan(ble = true, wifi = true, coAlive = true, fw = true).notScanningDetail)
        val live = scan(ble = true, wifi = true, coAlive = true)
        assertTrue(live.scanning)
        assertNull(live.notScanningDetail)
        assertNull(statusNotScanningLine(connected = true, demo = false, scanning = live.scanning,
            total = 0, notScanningDetail = live.notScanningDetail))
    }
    /** Two MACs that hash to the same ring and the same angle must not draw on top of each other:
     *  the priority dot keeps its hash angle and the second one steps along the ring until it is
     *  at least one dot diameter away. Wrong input: the old loop placed both at the hash angle
     *  (distance 0), so this fails against it. TWIN: the iOS placement test for STA-2. */
    @Test
    fun dotsOnTheSameRingAndAngleComeOutOneDiameterApart() {
        val xy = radarDotPositions(
            angleDeg = intArrayOf(0, 0), ringRadius = floatArrayOf(60f, 60f),
            cx = 100f, cy = 100f, dotRadius = 6f, obstacles = emptyList(),
        )
        assertEquals(160f, xy[0], 0.001f)
        assertEquals(100f, xy[1], 0.001f)
        val dx = xy[2] - xy[0]
        val dy = xy[3] - xy[1]
        assertTrue("dots ${kotlin.math.sqrt(dx * dx + dy * dy)} px apart", dx * dx + dy * dy >= 12f * 12f - 0.01f)
        // still on its own ring: the nudge moves along the ring, never across bands
        val r2 = (xy[2] - 100f) * (xy[2] - 100f) + (xy[3] - 100f) * (xy[3] - 100f)
        assertEquals(60f, kotlin.math.sqrt(r2), 0.01f)
    }

    /** A dot whose hash angle lands on the TOTAL NEARBY caption (or a ring word) moves off it:
     *  the word's bare text frame is an obstacle in the same pass (R18: the frames carry no plate
     *  padding, the words sit straight on the disc). */
    @Test
    fun aDotUnderTheWordMovesClearOfIt() {
        val word = androidx.compose.ui.geometry.Rect(140f, 90f, 180f, 110f)
        val xy = radarDotPositions(
            angleDeg = intArrayOf(0), ringRadius = floatArrayOf(60f),
            cx = 100f, cy = 100f, dotRadius = 6f, obstacles = listOf(word),
        )
        val nx = xy[0].coerceIn(word.left, word.right) - xy[0]
        val ny = xy[1].coerceIn(word.top, word.bottom) - xy[1]
        assertTrue("dot still touches the word", nx * nx + ny * ny >= 36f)
    }

    /** M3: the sweep angle is a function of an ABSOLUTE clock, fract(t / 4.5 s) x 360, so a scope
     *  that re-enters composition (a tab return) continues the turn. Wrong input: an angle measured
     *  from a per-scope start time, where a scope re-created at t = 10 s reads 0, not 80. The
     *  period literal is asserted, not the constant against itself: it is SHARED with iOS
     *  (RadarScope.sweepPeriod = 4.5, pinned in DashboardPresentationTests). */
    @Test
    fun sweepAngleComesFromTheAbsoluteClock() {
        assertEquals(4_500L, RADAR_SWEEP_PERIOD_MS)
        assertEquals(0f, radarSweepDegrees(0L), 1e-3f)
        assertEquals(180f, radarSweepDegrees(2_250L), 1e-3f)
        assertEquals(0f, radarSweepDegrees(4_500L), 1e-3f)
        assertEquals(80f, radarSweepDegrees(10_000L), 1e-3f)
        assertEquals(270f, radarSweepDegrees(-1_125L), 1e-3f)
        // Continuity: two readers at the same absolute time agree, however long each has run.
        val t = 1_790_000_123_456L
        assertEquals(radarSweepDegrees(t), radarSweepDegrees(t, RADAR_SWEEP_PERIOD_MS), 0f)
        // Monotonic inside one turn: a later reading is further round, never back at 0.
        assertTrue(radarSweepDegrees(10_016L) > radarSweepDegrees(10_000L))
    }

    /** The owner dropped the middle ring's word (2026-09-25): the radar labels only the inner ring
     *  STRONG and the disc edge WEAK, and the dots still snap to all three rings. Wrong input that
     *  must fail here: putting "GOOD" to 2 back into RADAR_RING_WORDS. TWIN: iOS
     *  DashboardPresentationTests.testRadarRingWordsAreStrongAndWeakOnly. */
    @Test
    fun radarRingWordsAreStrongAndWeakOnly() {
        assertEquals(listOf("STRONG" to 1, "WEAK" to 3), RADAR_RING_WORDS)
    }

    /** The owner cut the Status radar by about a quarter (2026-09-25, decisions R12): its side is
     *  0.75 of the content column, capped at 315dp (0.75 x the old 420dp cap). The literals are
     *  asserted, not the constants against themselves: the rule is SHARED with iOS
     *  (RadarSideLayout.fraction, .cap, .side(column:)). Wrong input that must fail here: the old
     *  whole-column side (fraction 1, cap 420dp), which is 358dp on a 390dp phone's 358dp column.
     *  TWIN: iOS DashboardPresentationTests.testRadarSideIsThreeQuartersOfTheColumnCappedAt315. */
    @Test
    fun radarSideIsThreeQuartersOfTheColumnCappedAt315() {
        assertEquals(0.75f, STATUS_RADAR_SIDE_FRACTION, 0f)
        assertEquals(315f, STATUS_RADAR_MAX_SIDE.value, 0f)
        assertEquals(268.5f, statusRadarSide(358.dp).value, 1e-3f)   // 390dp phone
        assertEquals(315f, statusRadarSide(420.dp).value, 1e-3f)     // exactly the cap
        assertEquals(315f, statusRadarSide(840.dp).value, 1e-3f)     // tablet column
        assertEquals(0f, statusRadarSide(0.dp).value, 0f)
    }

    /** The radar count is the Status hero and draws like iOS RadarScope countBlock:
     *  JetBrains Mono at Bold (telemetryFixed(..., weight: .bold)), not displayLarge's own
     *  Regular, which drew it thin beside the iOS count. The face and weight are pinned here; the
     *  size stays displayLarge's, which statusRadarCountCapDp's 64/57 derivation reads. */
    @Test
    fun radarCountIsBoldJetBrainsMonoAtDisplayLargeSize() {
        assertEquals(JetBrainsMono, RadarCountStyle.fontFamily)
        assertEquals(FontWeight.Bold, RadarCountStyle.fontWeight)
        assertEquals(AcabTypography.displayLarge.fontSize, RadarCountStyle.fontSize)
        assertEquals(AcabTypography.displayLarge.lineHeight, RadarCountStyle.lineHeight)
    }

    /** The count's ink, as iOS `sweeping ? ACABTheme.text : ACABTheme.faint`: the text ink
     *  (onSurface) while scanning, the faint ink (onSurfaceVariant) while parked, at both contrast
     *  levels. A count that kept the text ink while parked (reading a 0 over dead radios as a
     *  result), or drew the faint ink while scanning, fails. */
    @Test
    fun radarCountInkIsTextWhileScanningAndFaintWhileParked() {
        for (p in listOf(AcabPalette.Normal, AcabPalette.High)) {
            assertEquals(p.onSurface, radarCountInk(scanning = true, palette = p))
            assertEquals(p.onSurfaceVariant, radarCountInk(scanning = false, palette = p))
            assertTrue(p.onSurface != p.onSurfaceVariant)
        }
    }
}
