package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.wifiBandGhz
import tech.acab.app.model.wifiChannelText

/**
 * WiFi channel (wire "ch") end to end: decode, band rule (twin of iOS
 * Detection.wifiBandGHz(channel:)), detail text, CSV cells and persisted reload.
 *
 * NOT COVERED: detectionsCsv's own append of detectionCsvWifiCells (a manager member, and this
 * JVM suite builds no manager). The stored round trip runs the real top-level detectionToJson.
 */
class WifiChannelExportTest {

    private val wifiJson =
        """{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:b6:22:0a:5c","rssi":-70,""" +
        """"det":"Hikvision on wifi","ch":149,"n":2}"""

    private val bleJson =
        """{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,"cid":76,"n":1}"""

    private fun decode(json: String): Detection = Detection.fromWireJson(json, JSONObject(json))

    @Test fun decode_readsChWhenPresent_nullWhenAbsent() {
        assertEquals(149, decode(wifiJson).wifiChannel)
        assertNull(decode(bleJson).wifiChannel)
        // Non-integral: null like iOS decodeIfPresent(Int.self), never optInt's 0 or 6.
        for (bad in listOf("null", "\"x\"", "6.7")) {
            assertNull(bad, decode(wifiJson.replace("\"ch\":149", "\"ch\":$bad")).wifiChannel)
        }
    }

    @Test fun band_edges() {
        for (ch in listOf(1, 13, 14)) assertEquals("ch $ch", "2.4", wifiBandGhz(ch))
        for (ch in listOf(32, 36, 165, 177)) assertEquals("ch $ch", "5", wifiBandGhz(ch))
        for (ch in listOf(null, 0, 15, 31, 178, 200, -1)) assertNull("ch $ch", wifiBandGhz(ch))
    }

    @Test fun detailText_namesChannelAndBand() {
        assertEquals("149 · 5 GHz", decode(wifiJson).wifiChannelText)
        assertEquals("6 · 2.4 GHz", decode(wifiJson.replace("\"ch\":149", "\"ch\":6")).wifiChannelText)
        assertNull(decode(bleJson).wifiChannelText)
    }

    @Test fun csvHeader_endsWithTheTwoWifiColumns_afterMaker() {
        assertEquals(listOf("maker", "wifi_channel", "wifi_band_ghz"), DETECTION_CSV_COLUMNS.takeLast(3))
    }

    @Test fun csvCells_wifiRowExportsChannelAndBand_bleRowExportsTwoEmptyFields() {
        assertEquals(listOf("149", "5"), detectionCsvWifiCells(decode(wifiJson).wifiChannel))
        assertEquals(listOf("", ""), detectionCsvWifiCells(decode(bleJson).wifiChannel))
    }

    @Test fun storedRow_roundTripsItsChannel() {
        // Real writer: detectionToJson persists "ch", fromStoredJson reads it back.
        assertEquals(149, Detection.fromStoredJson(detectionToJson(decode(wifiJson))).wifiChannel)
        assertFalse(detectionToJson(decode(bleJson)).has("ch"))
    }

    @Test fun demoSeed_wifiRowCarriesA24GHzChannel_bleRowsCarryNone() {
        // Wire-real demo: the S3 sample board's one WiFi row (s=1) has a 2.4 GHz channel, BLE rows
        // (s=0) none. The s=2 drone row is unpinned: WiFi Remote ID carries "ch" too.
        // TWIN: iOS demoSampleRows() in BLEManager.swift.
        for (d in DEMO_SAMPLE_ROWS.map { Detection.fromJson(JSONObject(it)) }) {
            if (d.source == 1) assertEquals(d.mac, "2.4", wifiBandGhz(d.wifiChannel))
            else if (d.source == 0) assertNull(d.mac, d.wifiChannel)
        }
        assertEquals(1, DEMO_SAMPLE_ROWS.count { JSONObject(it).optInt("s") == 1 })
    }
}
