package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** 2026-09-26 review P3-11 (owner: row titles are sentence case on both apps; feature names keep
 *  their case). Pins the helper that cases a category name for a Notifications row, and the
 *  checklist's fixed and counted row titles, byte for byte with the iOS twins
 *  (FirstRunTour.checklistRowTitles, checklistDetectorsTitle(count:)). FAILS IF a row title goes
 *  back to lowercase-first, "ALPR camera" is re-cased, or a feature name ("Live Mode") is
 *  sentence-cased away. */
class RowTitleCaseTest {
    @Test
    fun aLowercaseCategoryNameGetsItsFirstLetterUp() {
        assertEquals("Body cam", rowTitleCase("body cam"))
        assertEquals("Network camera", rowTitleCase("network camera"))
        assertEquals("Recording glasses", rowTitleCase("recording glasses"))
        assertEquals("Drone", rowTitleCase("drone"))
        assertEquals("Tracker", rowTitleCase("tracker"))
        assertEquals("Watched device", rowTitleCase("watched device"))
    }

    /** A name that already starts with a capital, or an acronym, is untouched. */
    @Test
    fun aCapitalisedNameIsUnchanged() {
        assertEquals("ALPR camera", rowTitleCase("ALPR camera"))
        assertEquals("Flock Raven", rowTitleCase("Flock Raven"))
        assertEquals("", rowTitleCase(""))
    }

    @Test
    fun theChecklistRowTitlesAreSentenceCase() {
        assertEquals(
            listOf("Paired over encrypted Bluetooth", "Location", "Phone notifications", "Live Mode", "Offline buffer"),
            FirstRunTour.CHECKLIST_ROW_TITLES,
        )
    }

    /** The detectors row before the first frame; a counted title starts with its figure. */
    @Test
    fun theDetectorsRowTitleIsSentenceCase() {
        assertEquals("Detectors on", checklistDetectorsTitle(null))
        assertEquals("1 detector on", checklistDetectorsTitle(1))
        assertEquals("6 detectors on", checklistDetectorsTitle(6))
    }
}
