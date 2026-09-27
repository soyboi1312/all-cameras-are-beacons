package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Log tools menu's category words are title-cased (LogCategory.menuLabel) while the filter
 *  chip and the lens footer keep the caps label (logCategoryLabel). The Export header reads the
 *  menu words. TWIN: iOS DetectionCategory.menuLabel and the iOS Export submenu label. */
class LogMenuLabelTitleCaseTest {
    /** FAILS IF the header reads the chip label again (Export NETWORK CAM), drops the category, or
     *  loses the key fallback a deep link can seed. */
    @Test
    fun exportHeaderReadsTheMenuLabel() {
        assertEquals("Export", logExportMenuHeader(null))
        assertEquals("Export Network Cam", logExportMenuHeader("CAMERA"))
        assertEquals("Export Body Cam", logExportMenuHeader("BODY CAM"))
        assertEquals("Export ALPR", logExportMenuHeader("ALPR"))
        assertEquals("Export Watched", logExportMenuHeader(WATCHED_FILTER_KEY))
        // A key the menu does not list reads as the key itself, as the chip and footer do.
        assertEquals("Export SOMETHING", logExportMenuHeader("SOMETHING"))
    }

    /** The chip and footer words are out of the Title Case scope. FAILS IF a menu change leaks
     *  into logCategoryLabel, which the drift-pinned lens footer reads. */
    @Test
    fun chipAndFooterWordsStayCaps() {
        assertEquals("NETWORK CAM", logCategoryLabel("CAMERA"))
        assertEquals("BODY CAM", logCategoryLabel("BODY CAM"))
        assertEquals("WATCHED", logCategoryLabel(WATCHED_FILTER_KEY))
    }
}
