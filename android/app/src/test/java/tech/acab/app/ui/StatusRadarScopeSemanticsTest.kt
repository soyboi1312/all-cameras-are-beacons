package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType

/** The spoken strings behind the Status radar. Plain JUnit, like the rest of this source set:
 *  the semantics modifiers that carry them are checked by reading; these pin the words. */
class StatusRadarScopeSemanticsTest {
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
                "with matches and stars first. Radar shows signal strength only, not direction.",
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
                "with matches and stars first. Radar shows signal strength only, not direction.",
            one.radarContentDescription,
        )

        val none = statusNearbySummary(emptyList(), emptySet())
        assertEquals(
            "0 recently heard devices nearby. 0 dots drawn, at most 14, " +
                "with matches and stars first. Radar shows signal strength only, not direction.",
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
}
