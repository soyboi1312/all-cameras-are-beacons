package tech.acab.app.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PersonSearch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import tech.acab.app.model.DeviceType

/** Pins the measured wrap rule the category strips use. Units are dp at density 1. Most fixtures
 *  are the Roboto label, 12sp Medium with no tracking (`CategoryTileLabelStyle`, the connect
 *  panel's strip; the Status strip's mono label has its own test below); NETCAM measures 48.9 / 56.3 /
 *  63.6dp at font scale 1.0 / 1.15 / 1.3 (TTF-derived from the Roboto-Medium advances, kerning
 *  ignored; re-true on beacon_play_36). A 411dp phone leaves a 379dp strip (411 - 2 x 16), with
 *  4dp gaps as the 4b mockup draws them and 0dp tile side padding, so a six-across box is 59.8dp.
 *  iOS twin: CategoryStripLayoutTests. */
class CategoryTilesPerRowTest {
    private fun perRow(strip: Float, widest: Float, preferred: Int) =
        categoryTilesPerRow(strip, gapPx = 4f, tilePaddingPx = 0f, widestLabelPx = widest, preferred = preferred)

    @Test
    fun sixAcrossWhileTheWidestLabelFits() {
        assertEquals("NETCAM at font scale 1.0", 6, perRow(379f, 48.9f, 6))
        assertEquals("NETCAM at font scale 1.15, 3.5dp to spare", 6, perRow(379f, 56.3f, 6))
    }

    /** The Status strip draws the instrument face (CategoryTileTelemetryLabelStyle, R16): every
     *  JetBrains Mono glyph advances 0.6em, so NETCAM is 6 x (0.6 x 10.8 + 0.8) = 43.7dp at font
     *  scale 1.0 and, on the linear estimate the categoryTilesPerRow doc carries, 56.8 / 87.4dp at
     *  1.3 / 2.0 (re-true on beacon_play_36 with the Roboto fixtures above). */
    @Test
    fun theStatusStripsMonoLabelKeepsSixLonger() {
        assertEquals("mono NETCAM at font scale 1.0", 6, perRow(379f, 43.7f, 6))
        assertEquals("mono NETCAM at font scale 1.3, where Roboto already wraps", 6, perRow(379f, 56.8f, 6))
        assertEquals("mono NETCAM at font scale 2.0", 3, perRow(379f, 87.4f, 6))
    }

    @Test
    fun wrapsAtTheFirstScaleWhereALabelWouldBeCut() {
        assertEquals("NETCAM at font scale 1.3", 3, perRow(379f, 63.6f, 6))
        assertEquals("one dp past the box", 3, perRow(379f, 60.8f, 6))
    }

    @Test
    fun narrowPhonesWrapWithoutANamedWidthThreshold() {
        // A 360dp phone leaves a 328dp strip: a 51.3dp box six across.
        assertEquals("NETCAM at font scale 1.15", 3, perRow(328f, 56.3f, 6))
        assertEquals("NETCAM at font scale 1.0, 2.4dp to spare", 6, perRow(328f, 48.9f, 6))
    }

    @Test
    fun aSmallerPreferredCountIsKeptWhenItFits() {
        // A four-across box is 91.75dp.
        assertEquals(4, perRow(379f, 48.9f, 4))
        assertEquals(3, perRow(379f, 100f, 4))
    }

    @Test
    fun aLabelTooWideForThreeDropsToTwoAndNoFurther() {
        // 379dp strip: a three-across box is 123.7dp, a two-across box 187.5dp.
        assertEquals(2, perRow(379f, 125f, 6))
        assertEquals("a three-tile strip also drops", 2, perRow(379f, 125f, 3))
        assertEquals("two is the floor even when it clips", 2, perRow(379f, 500f, 6))
        assertEquals(3, perRow(379f, 100f, 3))
    }

    @Test
    fun oneOrTwoTilesAreNeverRearranged() {
        assertEquals(1, perRow(379f, 500f, 1))
        assertEquals(2, perRow(379f, 500f, 2))
    }

    /** The tiles have no side padding today, but the rule still subtracts it: with 4dp a side the
     *  six-across label box is 51.8dp, so the 1.15 NETCAM wraps. */
    @Test
    fun thePaddingTermStillCounts() {
        assertEquals(3, categoryTilesPerRow(379f, 4f, 4f, 56.3f, 6))
        assertEquals(6, categoryTilesPerRow(379f, 4f, 0f, 56.3f, 6))
    }

    /** U2-d: the category glyphs follow the mockups: body cam is person-search and glasses the
     *  hand-authored eyeglasses vector (a lazy val, so every call hands back the same instance
     *  instead of rebuilding the path per tile / row / pin). Wrong inputs: the old Videocam and
     *  RemoveRedEye glyphs. */
    @Test
    fun bodyCamAndGlassesUseTheMockupGlyphs() {
        assertEquals(Icons.Filled.PersonSearch.name, DeviceType.BODY_CAM.icon().name)
        assertEquals("Filled.Eyeglasses", DeviceType.GLASSES.icon().name)
        assertSame(DeviceType.GLASSES.icon(), DeviceType.GLASSES.icon())
    }
}
