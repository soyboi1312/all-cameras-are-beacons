package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.DeviceType

class MapLocationTest {
    private fun containsLongitude(bounds: DetailBreadcrumbBounds, lon: Double): Boolean =
        if (bounds.west <= bounds.east) lon in bounds.west..bounds.east
        else lon >= bounds.west || lon <= bounds.east

    @Test
    fun operatorOnlyCoordinatesAreKeptOnlyForDroneRows() {
        assertTrue(hasMapRepresentation(
            DeviceType.DRONE, primary = null, pilotLat = 32.7, pilotLon = -117.1))
        assertFalse(hasMapRepresentation(
            DeviceType.NEARBY_DEVICE, primary = null, pilotLat = 32.7, pilotLon = -117.1))
        assertFalse(hasMapRepresentation(
            DeviceType.DRONE, primary = null, pilotLat = 0.0, pilotLon = 0.0))
        assertTrue(hasMapRepresentation(
            DeviceType.NEARBY_DEVICE, primary = 32.7 to -117.1,
            pilotLat = null, pilotLon = null))

        // Initial camera fitting must use the same operator fallback. Merely retaining the row
        // would still strand its only marker outside the default viewport.
        assertEquals(
            32.7 to -117.1,
            mapRepresentationCoord(
                DeviceType.DRONE, primary = null, pilotLat = 32.7, pilotLon = -117.1),
        )
        assertEquals(
            40.0 to -73.0,
            mapRepresentationCoord(
                DeviceType.DRONE, primary = 40.0 to -73.0,
                pilotLat = 32.7, pilotLon = -117.1),
        )
    }

    @Test
    fun detailBreadcrumbBoundsIncludeThePinAndTrail() {
        val pin = 32.7000 to -117.1000
        val crumbs = listOf(32.7010 to -117.1020, 32.7050 to -117.0900)
        val bounds = detailBreadcrumbBounds(pin, crumbs)!!

        for ((lat, lon) in listOf(pin) + crumbs) {
            assertTrue(lat in bounds.south..bounds.north)
            assertTrue(containsLongitude(bounds, lon))
        }
        assertTrue(bounds.north > bounds.south)
    }

    /** Two crumbs, not one: a trail under the shared two-point gate is not folded into the frame
     *  at all, so a one-crumb case would prove nothing about the arc. The iOS twin is
     *  MapPinRulesTests.testDetailThumbnailTakesTheShortArcAcrossAntimeridian, which uses the same
     *  shape. Dropping the `>= 2` gate in detailBreadcrumbBounds does not fail this one; that is
     *  what detailBreadcrumbIgnoresATrailShorterThanTwoPoints is for. */
    @Test
    fun detailBreadcrumbUsesTheSmallArcAcrossTheAntimeridian() {
        val pin = 10.0 to 179.5
        val crumbs = listOf(10.0 to 179.0, 10.1 to -179.0)
        val bounds = detailBreadcrumbBounds(pin, crumbs)!!

        assertTrue("crossing boxes use west > east", bounds.west > bounds.east)
        assertTrue(containsLongitude(bounds, pin.second))
        for ((_, lon) in crumbs) assertTrue(containsLongitude(bounds, lon))
        val circularSpan = bounds.east - bounds.west + 360.0
        assertTrue("two-degree trail must not frame the whole world", circularSpan < 3.0)
    }

    /** The two-point gate itself, SHARED with iOS detectionDetailMapRegion (`usableTrail.count
     *  >= 2`). One crumb draws no polyline on either platform, so neither platform widens the
     *  thumbnail around it; the frame stays the lone pin's neighbourhood box. Deleting the
     *  `validCrumbs.size >= 2` guard in detailBreadcrumbBounds fails this: the far crumb would
     *  drag the box roughly a degree wide and pull its centre off the pin. */
    @Test
    fun detailBreadcrumbIgnoresATrailShorterThanTwoPoints() {
        val lonePin = detailBreadcrumbBounds(32.7 to -117.1, emptyList())!!
        val oneCrumb = detailBreadcrumbBounds(32.7 to -117.1, listOf(33.4 to -117.9))!!

        assertEquals(lonePin.north, oneCrumb.north, 1e-9)
        assertEquals(lonePin.south, oneCrumb.south, 1e-9)
        assertEquals(lonePin.east, oneCrumb.east, 1e-9)
        assertEquals(lonePin.west, oneCrumb.west, 1e-9)
        assertEquals(0.008, oneCrumb.north - oneCrumb.south, 1e-9)
    }

    /** Pins the pad and the floor SHARED with iOS detectionDetailMapRegion. The iOS twins are
     *  MapPinRulesTests.testDetailThumbnailKeepsNeighborhoodScaleForALonePin (the same 0.008
     *  floor) and MapPinRulesTests.testDetailThumbnailPadsAWideTrailByTheSharedFactor (the same
     *  `0.01 * 1.35` on the same two-crumb trail). Changing DETAIL_MAP_MIN_SPAN_DEG or
     *  DETAIL_MAP_FIT_SCALE on one platform, or flooring before padding instead of after, fails
     *  on the platform that changed. */
    @Test
    fun detailBreadcrumbFloorsAShortTrailAtNeighbourhoodScale() {
        val lone = detailBreadcrumbBounds(32.7 to -117.1, emptyList())!!
        assertEquals(0.008, lone.north - lone.south, 1e-9)
        assertEquals(0.008, lone.east - lone.west, 1e-9)

        // ~44 m of trail, under the floor even after padding: the frame must not shrink onto it.
        // Two crumbs, because one is below the shared two-point gate and never reaches the fit.
        val short = detailBreadcrumbBounds(
            32.7 to -117.1, listOf(32.7002 to -117.1, 32.7004 to -117.1))!!
        assertEquals(0.008, short.north - short.south, 1e-9)

        // Wider than the floor, so the shared 1.35 pad decides instead.
        val wide = detailBreadcrumbBounds(
            32.70 to -117.1, listOf(32.705 to -117.1, 32.71 to -117.1))!!
        assertEquals(0.01 * 1.35, wide.north - wide.south, 1e-9)
    }

    @Test
    fun detailBreadcrumbPaddingStaysInsideWebMercatorAtThePoles() {
        // Two crumbs each: below the shared two-point gate the trail is dropped and the pin's own
        // clamp is all that would be under test.
        val north = detailBreadcrumbBounds(89.0 to 40.0, listOf(89.5 to 40.1, 89.8 to 40.2))!!
        val south = detailBreadcrumbBounds(-89.0 to 40.0, listOf(-89.5 to 40.1, -89.8 to 40.2))!!

        assertTrue(north.north <= 85.05112878)
        assertTrue(north.south >= -85.05112878)
        assertTrue(south.north <= 85.05112878)
        assertTrue(south.south >= -85.05112878)
        assertTrue(north.north >= north.south)
        assertTrue(south.north >= south.south)
    }
}
