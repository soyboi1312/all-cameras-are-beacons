package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The dossier's Related help overlay is titled, and announced by TalkBack as, the same pane every
 *  other route to the Help content names: "Help + support" (the Status "?" overlay, the Beacon
 *  row, the iOS HelpView navigation title). It once read "HELP", so one screen had two names and
 *  an uppercase word in the system face that belonged to neither type layer (R16). The two Android
 *  twins (MainScreen's HELP_OVER_TAB_TITLE and DeviceScreen's beaconPageTitle) are private, so the
 *  literal is pinned here. FAILS IF the overlay title drifts from the shared name again. */
class DossierHelpTitleTest {
    @Test
    fun theDossierHelpOverlayIsNamedHelpPlusSupport() {
        assertEquals("Help + support", DOSSIER_HELP_TITLE)
    }
}
