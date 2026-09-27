package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The sample tour tells one Live Mode story on both phones (2026-09-26 review, P2-12): the THIS
 *  PHONE row reads "PREVIEW ON · COUNTS ..." while the tour toggle is on and "OFF · COUNTS ..."
 *  while it is off (iOS liveModeState "Preview on" / "Off" through driveKicker), never LIVE, and
 *  the Live Mode page carries the iOS preview sentence verbatim. Outside sample data nothing
 *  moves. Wrong input: the old "LIVE ON" / "LIVE OFF" in sample data, or a reworded sentence.
 *  TWIN: iOS SettingsView liveModeState and liveModeStatusDetail. */
class LiveModePreviewCopyTest {
    @Test
    fun sampleDataReadsPreviewOnOrOffNeverLive() {
        assertEquals("PREVIEW ON · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = true, countsPrivate = false, demo = true))
        assertEquals("PREVIEW ON · COUNTS PRIVATE",
            beaconLiveRowValue(wanted = true, deliverable = false, countsPrivate = true, demo = true))
        assertEquals("OFF · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = false, deliverable = true, countsPrivate = false, demo = true))
    }

    /** The sample arms never read the Android block: the sample switches are previews and nothing
     *  would be delivered anyway. */
    @Test
    fun sampleDataNeverReadsBlocked() {
        assertEquals("PREVIEW ON · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = false, countsPrivate = false, demo = true))
    }

    @Test
    fun realSessionsAreUnchanged() {
        assertEquals("LIVE ON · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = true, countsPrivate = false, demo = false))
        assertEquals("LIVE OFF · COUNTS PRIVATE",
            beaconLiveRowValue(wanted = false, deliverable = true, countsPrivate = true, demo = false))
        assertEquals("LIVE BLOCKED BY ANDROID · COUNTS VISIBLE",
            beaconLiveRowValue(wanted = true, deliverable = false, countsPrivate = false, demo = false))
    }

    @Test
    fun thePreviewSentenceIsTheIosSentence() {
        assertEquals("Sample preview only. Your saved setting and system surfaces stay unchanged.",
            LIVE_MODE_PREVIEW_NOTE)
    }
}
