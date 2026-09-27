package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import tech.acab.app.ble.CombinedUpdatePhase
import tech.acab.app.ble.ConnState

/** 2026-09-26 review P3-8: the Beacon tab's Scan radios row names the sample tour's radio state
 *  in the LIVE arms' own words (SCANNING · BLE · WI-FI and its three siblings) instead of a
 *  fifth "SAMPLE DATA" on a page whose banner, hero, pill and dot already say it. The sample
 *  frame never carries "co" or "nrfup", so the four radio arms are the only live arms it can
 *  reach. FAILS IF the sample arm drifts from the live arm for the same switches, or goes back to
 *  the SAMPLE DATA family (which the Status header keeps, statusScanPresentation). */
class BeaconScanRadiosSampleTest {
    private val sample = beaconConnectionPresentation(true, false, ConnState.READY, true)
    private val live = beaconConnectionPresentation(false, false, ConnState.READY, true)

    private fun label(demo: Boolean, ble: Boolean, wifi: Boolean): String = beaconRadioStatusLabel(
        demo = demo,
        connection = if (demo) sample else live,
        rebootingForUpdate = false,
        hasStatus = true,
        bleIntent = ble,
        wifiIntent = wifi,
        coAlive = null,
        nrfUpdating = false,
        combinedPhase = CombinedUpdatePhase.IDLE,
    )

    @Test
    fun theSampleRowReadsTheLiveWordsForEachRadioState() {
        assertEquals("SCANNING · BLE · WI-FI", label(demo = true, ble = true, wifi = true))
        assertEquals("SCANNING · BLE", label(demo = true, ble = true, wifi = false))
        assertEquals("SCANNING · WI-FI", label(demo = true, ble = false, wifi = true))
        assertEquals("RADIOS OFF · NOT SCANNING", label(demo = true, ble = false, wifi = false))
    }

    /** One switch state, one sentence: the sample arm and the live arm agree for every pair. */
    @Test
    fun theSampleArmMatchesTheLiveArm() {
        for (ble in listOf(true, false)) for (wifi in listOf(true, false)) {
            assertEquals(label(demo = false, ble = ble, wifi = wifi), label(demo = true, ble = ble, wifi = wifi))
        }
    }

    /** The Status header keeps its SAMPLE DATA family: the two presenters part ways in the tour
     *  on purpose (the header pill and the sweep read it; the row does not). */
    @Test
    fun theStatusHeaderStillSaysSampleData() {
        val header = statusScanPresentation(
            demo = true, reconnecting = false, rebootingForUpdate = false, hasStatus = true,
            bleIntent = true, wifiIntent = false, coAlive = null, nrfUpdating = false,
            firmwareUpdateRunning = false,
        )
        assertEquals("SAMPLE DATA · BLUETOOTH ONLY", header.label)
    }
}
