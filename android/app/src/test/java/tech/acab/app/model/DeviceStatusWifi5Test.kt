package tech.acab.app.model

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * "wifi5" is tri-state: only beacon-c5 sends it, and ABSENT (no 5 GHz radio) hides the Beacon
 * tab's 5 GHz Wi-Fi switch. FAILS IF the parse defaults an absent key (an S3 would get a dead
 * switch) or drops a present value. TWIN: iOS DeviceStatusWifi5Tests.
 */
class DeviceStatusWifi5Test {

    private fun status(json: String) = DeviceStatus.fromJson(JSONObject(json))

    @Test
    fun `present true reads true`() {
        assertEquals(true, status("""{"fw":"beacon c5 2.1.0","wifi":true,"wifi5":true}""").wifi5)
    }

    @Test
    fun `present false reads false`() {
        assertEquals(false, status("""{"fw":"beacon c5 2.1.0","wifi":true,"wifi5":false}""").wifi5)
    }

    @Test
    fun `absent reads null, never a default`() {
        assertNull(status("""{"fw":"beacon board 2.1.0","wifi":true,"wifiEco":0}""").wifi5)
    }
}
