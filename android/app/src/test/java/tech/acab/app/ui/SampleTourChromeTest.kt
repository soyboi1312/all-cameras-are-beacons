package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ui.theme.isInstrumentLabel

/** The sample tour overlay names itself (2026-09-26 review, P2-16): its root carries a pane
 *  title, so TalkBack announces the pane change when the full-screen tour opens and closes (the
 *  pattern the Help, saved-log and dossier overlays set), and the mono kicker at the leading edge
 *  of the Skip row names it on screen as iOS does. The pane title is lowercase-first (a spoken
 *  name, not a button); the kicker is the uppercase identifier that Kicker sets in the instrument
 *  face (R16, isInstrumentLabel). FAILS IF either string drifts from its iOS twin or the kicker
 *  stops being an uppercase identifier. */
class SampleTourChromeTest {
    @Test
    fun thePaneTitleIsLowercaseFirstAndNamesTheTour() {
        assertEquals("sample data tour", SAMPLE_TOUR_PANE_TITLE)
    }

    @Test
    fun theKickerIsTheIosKickerAndAnInstrumentLabel() {
        assertEquals("SAMPLE DATA TOUR", SAMPLE_TOUR_KICKER)
        assertTrue(isInstrumentLabel(SAMPLE_TOUR_KICKER))
    }
}
