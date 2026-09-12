package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The dossier's clock-derived labels, [relativeAgo] ("4m ago") and [seenSpan] ("18m", which
 *  CONFIRM IT renders as "over 18m"), are pure in (stamp, nowMs), and DetailScreen.kt hands both
 *  its 1 s tick. Before 2026-09-10 both read the wall clock inside the call and nothing
 *  recomposed the dossier on a timer, so an open dossier held its last age while no frame
 *  arrived. These tests pass an explicit nowMs that is nowhere near the wall clock, so an
 *  implementation that measures to System.currentTimeMillis() instead of nowMs cannot produce
 *  these answers.
 *
 *  What this cannot pin: a DetailScreen.kt call site that stops passing nowMs. relativeAgo keeps a
 *  wall-clock default for MapScreen checkedAgo, so such a call still compiles; seenSpan has no
 *  default, so ConfirmItPanel cannot drop it silently. */
class DetailTimeLabelsTest {

    /** A 1970 stamp against a tick 61 s later. Measured to the wall clock instead, the same stamp
     *  is about 20,000 days old, so both assertions fail if nowMs stops reaching the arithmetic. */
    @Test
    fun agesAreMeasuredToTheTickNotTheWallClock() {
        assertEquals("1m ago", relativeAgo(0L, 61_000L))
        assertEquals("1m", seenSpan(0L, 61_000L))
    }

    /** The other direction: a stamp ten days AHEAD of the wall clock, measured to a tick three
     *  hours after it. A wall-clock implementation sees a future stamp and clamps it to "now" and
     *  "1s", so these fail too. */
    @Test
    fun aStampAheadOfTheWallClockStillAgesAgainstTheTick() {
        val stamp = System.currentTimeMillis() + 10 * 86_400_000L
        val tick = stamp + 3 * 3_600_000L
        assertEquals("3h ago", relativeAgo(stamp, tick))
        assertEquals("3h", seenSpan(stamp, tick))
    }

    /** One tick crosses a bucket edge, which is the reason the dossier ticks at all: with no new
     *  frame, the label must still change when nowMs moves by one second. */
    @Test
    fun oneTickMovesTheLabelAcrossAnEdge() {
        val first = 1_757_000_000_000L
        assertEquals("59s ago", relativeAgo(first, first + 59_000L))
        assertEquals("1m ago", relativeAgo(first, first + 60_000L))
        assertEquals("59s", seenSpan(first, first + 59_000L))
        assertEquals("1m", seenSpan(first, first + 60_000L))
    }

    /** The same buckets and edges as iOS `dossierRelativeAgo(_:now:)` in DetectionDetailView.swift,
     *  which DetectionDetailTimeTests pins: under 5 s is "now", then whole seconds, minutes, hours
     *  and days, each rounded down. check-signature-drift.py's "dossier time labels" rule pins the
     *  same buckets in both bodies. */
    @Test
    fun relativeAgoBucketsAndEdges() {
        val t = 1_757_000_000_000L
        assertEquals("-", relativeAgo(null, t))
        assertEquals("now", relativeAgo(t, t))
        assertEquals("now", relativeAgo(t, t + 4_999L))
        assertEquals("5s ago", relativeAgo(t, t + 5_000L))
        assertEquals("59m ago", relativeAgo(t, t + 3_599_999L))
        assertEquals("1h ago", relativeAgo(t, t + 3_600_000L))
        assertEquals("23h ago", relativeAgo(t, t + 86_399_999L))
        assertEquals("1d ago", relativeAgo(t, t + 86_400_000L))
        // A stamp a little ahead of the tick (a backward clock step) reads "now", never a
        // negative age.
        assertEquals("now", relativeAgo(t + 2_000L, t))
    }

    /** The same buckets as iOS `dossierSightingSpan(since:now:)` in DetectionDetailView.swift,
     *  which DetectionDetailTimeTests pins, with the same floor of 1 s: a fresh detection reads
     *  "over 1s", never "over 0s". check-signature-drift.py's "dossier time labels" rule pins the
     *  same buckets in both bodies. null drops the "over X" clause when the first sighting has no
     *  time; iOS makes that call in the view's `sightingSpan`, not in the pure function. */
    @Test
    fun seenSpanBucketsAndFloor() {
        val t = 1_757_000_000_000L
        assertNull(seenSpan(null, t))
        assertEquals("1s", seenSpan(t, t))
        assertEquals("1s", seenSpan(t + 2_000L, t))
        assertEquals("45s", seenSpan(t, t + 45_000L))
        assertEquals("59m", seenSpan(t, t + 3_599_999L))
        assertEquals("1h", seenSpan(t, t + 3_600_000L))
        assertEquals("1d", seenSpan(t, t + 86_400_000L))
    }
}
