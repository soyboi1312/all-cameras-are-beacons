package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
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
    fun everySampleRadioAndDetectorToggleUpdatesOnlyItsStatusField() {
        val expected = mapOf(
            DemoStatusToggle.BLE to allOff.copy(ble = true),
            DemoStatusToggle.WIFI to allOff.copy(wifi = true),
            DemoStatusToggle.FLOCK to allOff.copy(flock = true),
            DemoStatusToggle.DRONE to allOff.copy(drone = true),
            DemoStatusToggle.DRONE_OUI to allOff.copy(droui = true),
            DemoStatusToggle.BODY_CAM to allOff.copy(bodyCam = true),
            DemoStatusToggle.MOTOROLA to allOff.copy(moto = true),
            DemoStatusToggle.TRACKER to allOff.copy(tracker = true),
            DemoStatusToggle.GLASSES to allOff.copy(glasses = true),
            DemoStatusToggle.NETWORK_CAMERA to allOff.copy(ncam = true),
        )

        assertEquals(DemoStatusToggle.entries.toSet(), expected.keys)
        for ((toggle, status) in expected) {
            assertEquals(toggle.name, status, allOff.withDemoStatusToggle(toggle, true))
            assertEquals(toggle.name, allOff, status.withDemoStatusToggle(toggle, false))
        }
    }
}
