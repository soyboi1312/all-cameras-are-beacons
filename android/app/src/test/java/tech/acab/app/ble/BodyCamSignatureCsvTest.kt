package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import tech.acab.app.model.Detection

/**
 * The CSV's bodycam_signature cell carries a BodyCamSignature raw value and nothing else: any other
 * row's detail is free text (a drone's carries the broadcast Operator ID), and the detection CSV is
 * what a contribution shares.
 * TWIN: iOS ExportTests.testSignatureColumnNamesTheRuleAndNeverCopiesFreeText.
 *
 * NOT COVERED: detectionsCsv's own append of detectionCsvSignatureCell (a manager member, and this
 * JVM suite builds no manager), the same boundary WifiChannelExportTest draws.
 */
class BodyCamSignatureCsvTest {

    /** Row 4 of the 2026-10-21 record in docs/signatures.md (d8:1f:65:04:9a:23 in
     *  acab-detections 6.csv), as 2.2.2 firmware sends it. */
    private val sigIdJson =
        """{"t":3,"s":0,"meth":8,"c":75,"mac":"d8:1f:65:04:9a:23","rssi":-89,""" +
        """"det":"Axon Bluetooth ID","n":4}"""

    private val freeTextJson =
        """{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,""" +
        """"det":"HomeNet-5G hardware OUI","n":1}"""

    private fun decode(json: String): Detection = Detection.fromWireJson(json, JSONObject(json))

    @Test fun bodyCamRow_exportsItsSignature() {
        assertEquals("Axon Bluetooth ID", detectionCsvSignatureCell(decode(sigIdJson)))
        assertEquals("BWC DEVICE",
            detectionCsvSignatureCell(decode(sigIdJson.replace("Axon Bluetooth ID", "BWC DEVICE"))))
    }

    @Test fun nearbyDetail_neverReachesTheCell() {
        assertEquals("fixture carries free text", "HomeNet-5G hardware OUI", decode(freeTextJson).detail)
        assertEquals("", detectionCsvSignatureCell(decode(freeTextJson)))
    }

    @Test fun bodyCamDetailOutsideTheClosedSet_staysOut() {
        assertEquals("",
            detectionCsvSignatureCell(decode(sigIdJson.replace("Axon Bluetooth ID", "Axon Bluetooth ID v2"))))
        assertEquals("", detectionCsvSignatureCell(decode(sigIdJson.replace(""""det":"Axon Bluetooth ID",""", ""))))
    }
}
