package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** The spoken names of the Managed devices row controls (IgnoredCard, WatchedCard in
 *  DeviceScreen.kt). Plain JUnit, like the rest of this source set: the role and label modifiers
 *  that carry these are checked by reading; this pins the words. Before the fix every Rename
 *  control spoke only "Rename", so a list of muted devices read the same name once per row. */
class ManagedDeviceActionLabelsTest {
    @Test
    fun renameNamesTheDeviceItActsOn() {
        assertEquals("Rename my own AirTag", renameDeviceDescription("my own AirTag"))
        assertNotEquals(
            "two rows must not speak the same Rename name",
            renameDeviceDescription("my own AirTag"),
            renameDeviceDescription("partner's keys"),
        )
    }

    @Test
    fun anUnnamedDeviceUsesTheNameItsRowShows() {
        assertEquals("Unknown device", managedDeviceName(""))
        assertEquals("Rename Unknown device", renameDeviceDescription(""))
        assertEquals("unmute Unknown device", unmuteClickLabel(""))
    }

    @Test
    fun unmuteAndUnstarActionsNameTheDevice() {
        assertEquals("unmute my own AirTag", unmuteClickLabel("my own AirTag"))
        assertEquals("stop watching partner's keys", unstarClickLabel("partner's keys"))
    }
}
