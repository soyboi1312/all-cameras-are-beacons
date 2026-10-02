package tech.acab.app.ui

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.hasName
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel

/** R19 (review P2-5): the Log row subtitle of a NAMED row leads with DeviceType.inlineLabel
 *  ("ALPR camera", "body cam"), the lowercase-first form every row uses, never `label`, whose
 *  Title Case ("ALPR Camera", "Body Camera") sat beside "Network camera" in one list. A nameless
 *  row keeps source · method. TWIN: iOS DetectionRowSubtitleTests (DetectionRow.subtitle(for:)). */
class LogRowSubtitleTest {
    private fun row(type: DeviceType, name: String?) = Detection.fromJson(
        JSONObject().put("t", type.raw).put("meth", 1).put("c", 75)
            .put("mac", "aa:bb:cc:dd:ee:01").put("rssi", -60).putOpt("name", name)
            .put("new", true))

    /** FAILS IF the named branch goes back to `label` ("ALPR Camera · ...", "Body Camera · ..."). */
    @Test
    fun aNamedRowLeadsWithTheInlineLabel() {
        val alpr = row(DeviceType.FLOCK_CAMERA, "Flock Falcon 01")
        val body = row(DeviceType.BODY_CAM, "X6A12345")
        assertTrue(alpr.hasName)
        assertEquals("${alpr.type.inlineLabel} · ${alpr.methodLabel}", detectionRowSubtitle(alpr))
        assertEquals("${body.type.inlineLabel} · ${body.methodLabel}", detectionRowSubtitle(body))
        assertEquals("ALPR camera", alpr.type.inlineLabel)
        assertEquals("body cam", body.type.inlineLabel)
        // The Title Case export word never leads a row.
        assertFalse(detectionRowSubtitle(alpr).startsWith(alpr.type.label))
        assertFalse(detectionRowSubtitle(body).startsWith(body.type.label))
    }

    /** A nameless row has nothing but the category in its title, so the subtitle says where and
     *  how it was heard instead of repeating the category. */
    @Test
    fun aNamelessRowKeepsSourceAndMethod() {
        val d = row(DeviceType.NETWORK_CAMERA, null)
        assertFalse(d.hasName)
        assertEquals("${d.sourceLabel} · ${d.methodLabel}", detectionRowSubtitle(d))
    }
}
