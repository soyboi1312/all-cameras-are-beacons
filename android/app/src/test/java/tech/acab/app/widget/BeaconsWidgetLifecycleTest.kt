package tech.acab.app.widget

import org.junit.Assert.assertEquals
import org.junit.Test

class BeaconsWidgetLifecycleTest {
    @Test
    fun coldProcessAndOldProcessSnapshotsAlwaysRenderSafe() {
        assertEquals(false, widgetPersistedSummaryMayRender(
            managerAvailable = false,
            processMarkedReadable = true,
            storedGeneration = "current",
            currentGeneration = "current",
        ))
        assertEquals(false, widgetPersistedSummaryMayRender(
            managerAvailable = true,
            processMarkedReadable = true,
            storedGeneration = "old",
            currentGeneration = "new",
        ))
        assertEquals(true, widgetPersistedSummaryMayRender(
            managerAvailable = true,
            processMarkedReadable = true,
            storedGeneration = "current",
            currentGeneration = "current",
        ))
    }
}
