package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import tech.acab.app.model.DeviceStatus

class DemoStatusPreviewTest {
    private val allOff = DeviceStatus.fromJson(JSONObject(
        """{
            "fw":"beacon board 2.0.8",
            "ble":false,
            "wifi":false,
            "flock":false,
            "drone":false,
            "droui":false,
            "bodycam":false,
            "moto":false,
            "tracker":false,
            "glasses":false,
            "ncam":false
        }""",
    ))

    @Test
    fun sampleModeAppliesTheEditToTheSyntheticFrame() {
        assertEquals(
            allOff.copy(tracker = true),
            allOff.withDemoStatusEdit(demoMode = true) { copy(tracker = true) },
        )
    }

    /** The gate that keeps a preview off a real retained status frame: outside sample mode the
     * same frame comes back and the edit never runs. */
    @Test
    fun outsideSampleModeTheFrameIsUntouchedAndTheEditNeverRuns() {
        var ran = false
        val out = allOff.withDemoStatusEdit(demoMode = false) { ran = true; copy(tracker = true) }

        assertSame(allOff, out)
        assertFalse(ran)
    }

    @Test
    fun sampleModeWithNoFrameStaysNull() {
        val none: DeviceStatus? = null

        assertNull(none.withDemoStatusEdit(demoMode = true) { copy(tracker = true) })
    }
}
