package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** AND-NAV-03 and AND-A11Y-09: what TalkBack hears on a Log row in select mode and on a removable
 *  filter chip. The row's checkbox role, its toggle state and the Back handler are Compose
 *  semantics this JVM source set cannot render (no Compose UI test runtime here); these pin the
 *  words the fix composes into them. */
class LogSelectRowSemanticsTest {
    /** Outside select mode only a muted row has a state, the words it always had. FAILS IF an
     *  unmuted row gains a state (TalkBack would read a stray word on every row) or the muted
     *  words move. */
    @Test
    fun outsideSelectModeOnlyMutedRowsHaveAState() {
        assertNull(logRowStateDescription(selectMode = false, checked = false, muted = false))
        assertEquals(
            "Muted, history retained",
            logRowStateDescription(selectMode = false, checked = false, muted = true),
        )
    }

    /** In select mode an unmuted row leaves its state to the checkbox role; a muted row names its
     *  check in the same words, so neither the check nor the mute goes unspoken. FAILS IF the
     *  muted select-mode state drops the check (the old SelectMark description was the only place
     *  the check was spoken) or ignores [checked]. */
    @Test
    fun selectModeMutedRowNamesItsCheck() {
        assertNull(logRowStateDescription(selectMode = true, checked = true, muted = false))
        assertNull(logRowStateDescription(selectMode = true, checked = false, muted = false))
        assertEquals(
            "Selected, muted, history retained",
            logRowStateDescription(selectMode = true, checked = true, muted = true),
        )
        assertEquals(
            "Not selected, muted, history retained",
            logRowStateDescription(selectMode = true, checked = false, muted = true),
        )
    }

    /** R19 (review P2-6): a row draws its disclosure chevron only outside select mode, where a
     *  tap opens the dossier; in select mode the tap toggles the check, so a chevron would
     *  promise a drill-in that does not happen (iOS drops its indicator the same way). FAILS IF
     *  the chevron is drawn unconditionally again. */
    @Test
    fun selectModeDropsTheDisclosureChevron() {
        assertTrue(logRowShowsChevron(selectMode = false))
        assertFalse(logRowShowsChevron(selectMode = true))
    }

    /** A removable filter chip speaks its tap, not the generic "double tap to activate". FAILS IF
     *  the name stops saying the tap removes the filter or drops which filter it is. */
    @Test
    fun filterChipNamesTheRemoval() {
        assertEquals("Remove the offline only filter", logFilterChipRemoveDescription("offline only"))
        assertEquals("Remove the Network camera filter", logFilterChipRemoveDescription("Network camera"))
    }
}
