package tech.acab.app.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * SECTION 8 parity fixtures for the follow-evidence scorer.
 *
 * These are not "coverage". They are the cross-platform contract: if either side ever swaps the
 * hand-written haversine for a platform geodesic (Location.distanceBetween here, CLLocation.distance
 * there) the two libraries' disagreement over kilometre scales flips a band at the 250 / 500 /
 * 1000 m boundary and THESE are what catch it. Same reason the string builders are asserted
 * verbatim: a locale-sensitive formatter would print "2,2 km" in de-DE while iOS printed "2.2 km",
 * and nobody would notice until a screenshot arrived from Berlin.
 *
 * WHAT "PARITY" MEANS HERE, STATED EXACTLY, because a comment that overstates it is worse than none.
 * Fixtures A to I (journeys) and J to O (the boundaries) below use the SAME VECTORS as
 * ios/BeaconsTests/FollowEvidenceTests.swift: same base point, same per-crumb steps, same crumb
 * ORDER, same elapsed, same base wall clock, and the same expected span / places / mean gap / band.
 * Four of A to I (D, E, F and I) used to use different vectors while this file claimed otherwise,
 * which made the suite's own headline the least reliable sentence in it; they were re-cut onto the
 * iOS vectors rather than the claim being softened. Every user-facing literal is likewise pinned on
 * both sides, verbatim, and so is the guard ORDER in evaluate() (see the zero-crumb, no-stamp case
 * at the end of theCrumbFloorKeepsTheNoneSentence).
 *
 * What is NOT claimed: the two suites are not line-for-line identical. Each carries extra
 * assertions the other does not, and they are always either on one of these same vectors or on the
 * pure string builders, so neither suite can pass on a vector the other would fail.
 *
 * Every vector moves in LATITUDE only from 37.000000, -122.000000, except fixture F which needs a
 * two-dimensional wander to make its point. A pure meridian arc is the one case where the haversine
 * reduces to R * dLat exactly, so the expected metres below are arithmetic rather than a value
 * copied out of whatever the code happened to print.
 */
class FollowEvidenceTest {

    private val baseLat = 37.000000
    private val baseLon = -122.000000

    /**
     * One degree of latitude at R = 6371008.8 is 111195.08 m. This divisor is deliberately a hair
     * SMALLER, which places every crumb a fraction of a metre BEYOND its nominal distance so the
     * scorer's floor() lands on the whole number the fixtures assert instead of one metre under it.
     * Copied digit for digit from the iOS suite's metresPerDegLat. Do not "correct" it to the true
     * value: the vectors are chosen against this one, and fixture I's span would floor to 11999.
     */
    private val metresPerDegLat = 111194.93

    /** An arbitrary wall clock shared with the iOS suite (Date(timeIntervalSince1970:
     *  1_700_000_000)); only the difference between the two stamps ever matters. */
    private val baseClockMs = 1_700_000_000_000L

    /** n crumbs marching north in equal steps, in append order. iOS's `ladder(step:count:)`,
     *  built the same way (base + index * step) so the two suites agree to the last bit rather
     *  than to the printed decimal. */
    private fun ladder(step: Double, count: Int): List<Pair<Double, Double>> =
        (0 until count).map { (baseLat + it * step) to baseLon }

    /** The scorer under the conditions the panel actually calls it with: a live tracker whose
     *  FIRST-CRUMB and last-crumb stamps are [elapsedSec] apart.
     *
     *  firstCrumbAtMs, not firstSeenAtMs. first-seen is when the device was first HEARD and it
     *  survives an app restart in the persisted store; crumbs start later and die with the session,
     *  so scoring from first-seen narrated a window the trail did not cover and let the band time
     *  floors be met by minutes with no crumbs in them. See the pair of tests below the fixtures. */
    private fun score(
        crumbs: List<Pair<Double, Double>>,
        elapsedSec: Int,
        timeBasis: TimeBasis = TimeBasis.Exact,
    ): FollowEvidence = FollowEvidence.evaluate(
        type = DeviceType.TRACKER,
        crumbs = crumbs,
        firstCrumbAtMs = baseClockMs,
        lastCrumbAtMs = baseClockMs + elapsedSec * 1000L,
        timeBasis = timeBasis,
    )

    // ---- A: three crumbs, 111 m apart. Real continuity, no ground covered. ----
    @Test
    fun fixtureA_shortHopsAreNotEvidence() {
        val ev = score(ladder(step = 0.0010, count = 3), elapsedSec = 1200)
        assertEquals(222, ev.spanM)
        // NOTE: the spec's fixture table annotates this row "places 2", which does not follow from
        // SECTION 3. With 111 m steps every crumb is strictly inside the 250 m radius of the FIRST
        // anchor, so the greedy pass opens exactly one place. The band, which is the thing both
        // platforms must agree on, is unaffected: 222 m is nowhere near the 500 m floor. Kept as 1
        // so the test asserts the algorithm rather than the typo. iOS records the same discrepancy.
        assertEquals(1, ev.places)
        assertEquals(600, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.NONE, ev.band)
    }

    // ---- B: three crumbs, 333 m apart, 20 minutes. The weaker band. ----
    @Test
    fun fixtureB_threePlacesOverHalfAKilometre() {
        val ev = score(ladder(step = 0.0030, count = 3), elapsedSec = 1200)
        assertEquals(667, ev.spanM)
        assertEquals(3, ev.places)
        assertEquals(600, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.NEARBY, ev.band)
        assertEquals("3 places, about 650 m apart, over 20 minutes", ev.summary)
        assertEquals("near you more than once", ev.band.label)
    }

    // ---- C: five crumbs over 2.2 km and an hour. The top band. ----
    @Test
    fun fixtureC_fivePlacesOverTwoKilometres() {
        val ev = score(ladder(step = 0.0050, count = 5), elapsedSec = 3600)
        assertEquals(2223, ev.spanM)
        assertEquals(5, ev.places)
        assertEquals(900, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.ACROSS, ev.band)
        assertEquals("5 places, about 2.2 km apart, over 60 minutes", ev.summary)
        assertEquals("near you in several places", ev.band.label)
    }

    // ---- D: two crumbs is a there-and-back coincidence, whatever the geometry. ----
    @Test
    fun fixtureD_twoCrumbsIsNeverEvidence() {
        val ev = score(ladder(step = 0.0500, count = 2), elapsedSec = 3600)
        // NONE, not NOT_MEASURED, and this is the one refusal where that is right: the crumbs are
        // real and the comparison did run over them, there are simply fewer than three. "Not across
        // enough ground to read anything into yet" is literally true here and nowhere else.
        assertEquals(FollowBand.NONE, ev.band)
        assertEquals(null, ev.summary)
    }

    // ---- E: 5 km apart but two hours between three crumbs. The morning-and-noon coincidence. ----
    @Test
    fun fixtureE_wideMeanGapIsRejected() {
        val trail = ladder(step = 0.02248246, count = 3)
        val ev = score(trail, elapsedSec = 7200)
        assertEquals(4999, ev.spanM)
        assertEquals(3, ev.places)
        assertEquals(3600, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.NONE, ev.band)
        // Control: the SAME geometry with a mean gap right on the 1200 s limit does fire, so the
        // rejection above is the gap test and not something else quietly failing.
        assertEquals(FollowBand.ACROSS, score(trail, elapsedSec = 2400).band)
    }

    // ---- F: the market / mall / office floor. Kilometres of path, one place. ----
    @Test
    fun fixtureF_pathLengthInsideOneCircleIsOnePlace() {
        // 20 crumbs zig-zagging around a circle of alternating 100 m and 30 m radius: an hour in a
        // market, a mall floor, a festival, an office. The SUMMED path is over a kilometre, which
        // is precisely why the scorer uses the diameter instead.
        val crumbs = ArrayList<Pair<Double, Double>>()
        var path = 0
        for (i in 0 until 20) {
            val ang = i * 2.0 * PI / 20.0
            val r = if (i % 2 == 0) 100.0 else 30.0
            val dLat = (r * cos(ang)) / metresPerDegLat
            val dLon = (r * sin(ang)) / (metresPerDegLat * cos(baseLat * PI / 180.0))
            val c = (baseLat + dLat) to (baseLon + dLon)
            crumbs.lastOrNull()?.let {
                path += FollowEvidence.metres(it.first, it.second, c.first, c.second)
            }
            crumbs.add(c)
        }
        // The fixture only makes its point if the walked path really is long.
        assertTrue("walked path should exceed 1 km, so the two definitions genuinely split", path > 1000)
        val ev = score(crumbs, elapsedSec = 3600)
        assertEquals(1, ev.places)
        assertEquals(200, ev.spanM)
        assertEquals(FollowBand.NONE, ev.band)
    }

    // ---- G: the wall clock moved under us. ----
    @Test
    fun fixtureG_clockJumpIsNotMeasured() {
        // Five crumbs cost at least four 60 s gates, so a 100 s window is arithmetically impossible.
        // The geometry may be real, but the duration in the sentence would be fiction, so the
        // scorer refuses rather than reporting a finding it did not compute.
        val ev = score(ladder(step = 0.0050, count = 5), elapsedSec = 100)
        assertEquals(FollowBand.NOT_MEASURED, ev.band)
    }

    // ---- H: first heard off the board's offline buffer, so the stamp is not a clock reading. ----
    @Test
    fun fixtureH_nonExactTimeBasisIsNotMeasured() {
        val trail = ladder(step = 0.0050, count = 5)
        // Identical vector to fixture C, which bands ACROSS on an Exact basis.
        assertEquals(FollowBand.ACROSS, score(trail, elapsedSec = 3600).band)
        val bracketed = TimeBasis.Bracketed(afterMs = null, beforeMs = baseClockMs)
        assertEquals(FollowBand.NOT_MEASURED, score(trail, elapsedSec = 3600, timeBasis = bracketed).band)
    }

    // ---- I: nine crumbs, eight places, 12 km, two hours. ----
    @Test
    fun fixtureI_longRunReadsInWholeKilometresAndHours() {
        // Eight anchors spread over 12 km, plus a NINTH crumb 100 m from the first, so n = 9 while
        // places stays 8. That gap between n and places is the point: crumbs are not places.
        val crumbs = ladder(step = 12000.0 / (7.0 * metresPerDegLat), count = 8) +
            listOf((baseLat + 100.0 / metresPerDegLat) to baseLon)
        val ev = score(crumbs, elapsedSec = 7200)
        assertEquals(9, ev.crumbCount)
        assertEquals(8, ev.places)
        assertEquals(12000, ev.spanM)
        assertEquals(900, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.ACROSS, ev.band)
        assertEquals("8 places, about 12 km apart, over 2 hours", ev.summary)
    }

    // ---- J to O: the boundaries themselves ----
    //
    // A to I are journeys, and a journey fixture sits nowhere near a threshold: a `>=` that quietly
    // became a `>` on ONE platform would keep every one of them passing on both. J to O are the
    // edges instead, one metre / one second / one crumb either side of every comparison in
    // evaluate(). iOS runs these same six on the same vectors, which is the only thing that catches
    // an operator that drifted on one side.

    /** A crumb [m] metres north of base. On the meridian for the same reason the ladders are: the
     *  haversine reduces to R * dLat there, so "500 m" really is 500 m and the expected numbers
     *  below are arithmetic rather than values read back out of the code. iOS's `at(_:)`. */
    private fun at(m: Double): Pair<Double, Double> = (baseLat + m / metresPerDegLat) to baseLon

    /** J: the NEARBY span floor is inclusive. Crumbs at 0 m, 500 m and 100 m, so the third joins the
     *  first anchor (100 < 250) and places is 2 while the diameter is exactly 500. */
    @Test
    fun fixtureJ_nearbySpanFloorIsInclusive() {
        val onTheFloor = score(listOf(at(0.0), at(500.0), at(100.0)), elapsedSec = 900)
        assertEquals(2, onTheFloor.places)
        assertEquals(500, onTheFloor.spanM)
        assertEquals("500 m IS the floor, not one metre over it", FollowBand.NEARBY, onTheFloor.band)
        // One metre under, with places, elapsed and mean gap all unchanged, so the only thing that
        // can have moved the answer is the span comparison.
        val under = score(listOf(at(0.0), at(499.0), at(100.0)), elapsedSec = 900)
        assertEquals(2, under.places)
        assertEquals(499, under.spanM)
        assertEquals(FollowBand.NONE, under.band)
    }

    /**
     * K: both elapsed floors, on ONE vector (0 m, 600 m, 1200 m: three places, 1200 m across) run at
     * four durations so time is the only thing moving.
     *
     * The ACROSS floor does not switch the panel off, it drops it a band, and that is the part worth
     * pinning: falling short of the stronger claim must land on the weaker one, never on silence. A
     * product built on under-claiming still has to say the smaller true thing.
     */
    @Test
    fun fixtureK_elapsedFloorsDemoteRatherThanSilence() {
        val trail = listOf(at(0.0), at(600.0), at(1200.0))
        assertEquals(FollowBand.ACROSS, score(trail, elapsedSec = 1800).band)   // 30 min exactly
        assertEquals(FollowBand.NEARBY, score(trail, elapsedSec = 1799).band)   // one second under
        assertEquals(FollowBand.NEARBY, score(trail, elapsedSec = 900).band)    // 15 min exactly
        assertEquals(FollowBand.NONE, score(trail, elapsedSec = 899).band)      // one second under
    }

    /** L: the mean-gap ceiling is inclusive, on K's geometry so only the gap moves. n = 3, so the
     *  mean is elapsed / 2: 2400 s is exactly 1200 and fires, 2402 s is 1201 and does not. */
    @Test
    fun fixtureL_meanGapCeilingIsInclusive() {
        val trail = listOf(at(0.0), at(600.0), at(1200.0))
        val onTheLimit = score(trail, elapsedSec = 2400)
        assertEquals(1200, onTheLimit.elapsedSec / (onTheLimit.crumbCount - 1))
        assertEquals(FollowBand.ACROSS, onTheLimit.band)
        val over = score(trail, elapsedSec = 2402)
        assertEquals(1201, over.elapsedSec / (over.crumbCount - 1))
        // NOT demoted to NEARBY: both bands share the gap test, so one second past the ceiling drops
        // straight to NONE. That is the whole point of the ceiling. Two encounters hours apart is
        // the coincidence that looks most like following and least is it.
        assertEquals(FollowBand.NONE, over.band)
    }

    /** M: places is the one thing distance cannot buy. Two anchors 1200 m apart over 40 minutes
     *  clears the ACROSS span, the ACROSS elapsed AND the gap, and still lands on NEARBY, because a
     *  there-and-back between two points is not a route through three. */
    @Test
    fun fixtureM_acrossNeedsThreePlacesNotJustDistance() {
        val ev = score(listOf(at(0.0), at(1200.0), at(100.0)), elapsedSec = 2400)
        assertEquals(2, ev.places)
        assertEquals(1200, ev.spanM)
        assertEquals(1200, ev.elapsedSec / (ev.crumbCount - 1))
        assertEquals(FollowBand.NEARBY, ev.band)
    }

    /**
     * N and O: the clock-sanity bound is (n - 1) * 60 with 5 s of slack, and it MOVES with n.
     *
     * The append gate spaces crumbs by at least 60 s, so a shorter window is a wall clock that moved
     * rather than a tag that did. Both sides of both bounds are asserted because the pair is what
     * makes it a bound: identical geometry, one second apart, and the two answers are a finding and
     * a refusal.
     */
    @Test
    fun fixturesNO_clockSlackBoundMovesWithCrumbCount() {
        val three = listOf(at(0.0), at(600.0), at(1200.0))
        assertEquals("115 + 5 slack meets 2 * 60", FollowBand.NONE, score(three, elapsedSec = 115).band)
        assertEquals(FollowBand.NOT_MEASURED, score(three, elapsedSec = 114).band)
        val four = listOf(at(0.0), at(400.0), at(800.0), at(1200.0))
        assertEquals("175 + 5 slack meets 3 * 60", FollowBand.NONE, score(four, elapsedSec = 175).band)
        assertEquals(FollowBand.NOT_MEASURED, score(four, elapsedSec = 174).band)
    }

    // ---- the window is the CRUMB window, not the contact window ----

    /**
     * The scorer measures from the FIRST CRUMB, so time before the trail started cannot buy a band.
     *
     * This is the arithmetic half of the first-seen fix. first-seen is when the device was first
     * HEARD and is restored from the persisted store on launch; the crumb trail is session-only and
     * starts later (a crumb needs a fresh fix, 60 s and 25 m). Scored from first-seen, a tag heard
     * at 09:00 whose three crumbs all fell between 09:50 and 09:53 cleared the 900 s NEARBY floor
     * on 180 s of trail. The manager side of the fix is firstCrumbAt; this is the side that proves
     * the number in the sentence is the number the geometry spans.
     */
    @Test
    fun theBandFloorsAreMeasuredAcrossTheCrumbsThemselves() {
        val trail = ladder(step = 0.0030, count = 3)   // fixture B's geometry: 667 m, 3 places
        // 800 s of crumbs is under the 900 s NEARBY floor, so the geometry alone is not enough.
        assertEquals(FollowBand.NONE, score(trail, elapsedSec = 800).band)
        // The same geometry with a trail that actually spans the floor does fire, so the rejection
        // above is the elapsed test and nothing else.
        assertEquals(FollowBand.NEARBY, score(trail, elapsedSec = FollowEvidence.ELAPSED_NEARBY_S).band)
    }

    // ---- refusals are not findings ----

    /**
     * Every refusal except the crumb floor reports NOT_MEASURED, and NOT_MEASURED is not NONE.
     *
     * These used to come back as NONE, which made the panel state a finding it had never computed
     * and, for a tag replayed off the board's offline buffer, state the OPPOSITE of the truth: a
     * tag that had ridden along for an hour was narrated as "not across enough ground to read
     * anything into yet". In a product built on under-claiming, a false reassurance is exactly as
     * much a false statement as a false alarm, and it is the one nobody audits.
     */
    @Test
    fun refusalsAreNotMeasuredRatherThanNone() {
        val trail = ladder(step = 0.0050, count = 5)
        // Wrong type. Unreachable from the panel (it is gated on TRACKER), asserted anyway so that
        // widening crumb collection past trackers fails here first.
        for (t in listOf(DeviceType.BODY_CAM, DeviceType.GLASSES, DeviceType.NEARBY_DEVICE)) {
            val ev = FollowEvidence.evaluate(t, trail, baseClockMs, baseClockMs + 3_600_000L, TimeBasis.Exact)
            assertEquals("$t must never band", FollowBand.NOT_MEASURED, ev.band)
        }
        // Derived time basis, clock jump, and a window longer than a tracker address lives.
        assertEquals(
            FollowBand.NOT_MEASURED,
            score(trail, elapsedSec = 3600, timeBasis = TimeBasis.Unknown).band,
        )
        assertEquals(FollowBand.NOT_MEASURED, score(trail, elapsedSec = 100).band)
        assertEquals(
            FollowBand.NOT_MEASURED,
            score(trail, elapsedSec = FollowEvidence.MAX_ELAPSED_S + 1).band,
        )
        // The ceiling itself is INCLUSIVE, so the refusal above is the ceiling and not an
        // off-by-one. A 24 h window over five crumbs is scored and lands on NONE (its mean gap is
        // six hours, nowhere near the 1200 s ceiling); the point is that it was scored at all.
        assertEquals(
            FollowBand.NONE,
            score(trail, elapsedSec = FollowEvidence.MAX_ELAPSED_S).band,
        )
        // A missing stamp is a broken record, not an empty result. Cannot happen in the manager
        // (both stamps are written in the same branch that appends a crumb), which is the reason it
        // is a refusal rather than a finding if it ever does.
        assertEquals(
            FollowBand.NOT_MEASURED,
            FollowEvidence.evaluate(DeviceType.TRACKER, trail, null, baseClockMs, TimeBasis.Exact).band,
        )
        assertEquals(
            FollowBand.NOT_MEASURED,
            FollowEvidence.evaluate(DeviceType.TRACKER, trail, baseClockMs, null, TimeBasis.Exact).band,
        )
        // The two no-claim states must never share a sentence: one says nothing was found, the
        // other says nothing was looked at.
        assertNotEquals(
            score(ladder(step = 0.0010, count = 3), elapsedSec = 1200).detailText,
            score(trail, elapsedSec = 100).detailText,
        )
    }

    /** Fewer than three crumbs is the ONE refusal that keeps the none sentence, because there
     *  "not across enough ground to read anything into yet" is literally true. */
    @Test
    fun theCrumbFloorKeepsTheNoneSentence() {
        for (n in 0..2) {
            val ev = score(ladder(step = 0.0500, count = n), elapsedSec = 3600)
            assertEquals("n=$n", FollowBand.NONE, ev.band)
            assertEquals(
                "n=$n",
                "It has been near you, but not across enough ground to read anything into yet.",
                ev.detailText,
            )
        }
        // GUARD ORDER, pinned, and it takes THIS vector to pin it. The tour seeds a tracker row with
        // no crumbs AND no stamps, so two guards hold at once and they return different sentences:
        // the crumb floor says NONE ("not across enough ground yet") and the missing-stamp guard
        // says NOT_MEASURED ("no reliable time record"). A demo is an empty result, not a broken
        // record, so the crumb floor has to be tested FIRST, and iOS's score() orders it the same
        // way. The five-crumb missing-stamp assertions above pass under either order and pin
        // nothing; only a case that trips both guards can tell the two orders apart.
        assertEquals(
            FollowBand.NONE,
            FollowEvidence.evaluate(DeviceType.TRACKER, emptyList(), null, null, TimeBasis.Exact).band,
        )
    }

    // ---- the place radius is strict ----

    @Test
    fun placeRadiusIsStrictlyInside() {
        // SECTION 3: a crumb joins an anchor when it is STRICTLY within 250 m, so a crumb sitting
        // at exactly 250 m opens a new place. Flooring to whole metres is what makes "exactly" a
        // thing that can be asserted at all.
        assertEquals(1, FollowEvidence.places(ladder(step = 249.0 / metresPerDegLat, count = 2)))
        assertEquals(2, FollowEvidence.places(ladder(step = 250.0 / metresPerDegLat, count = 2)))
    }

    // ---- the string builders, which are the other half of parity ----

    @Test
    fun spanTextRoundsToFiftyMetresThenTenthsOfAKilometre() {
        assertEquals("50 m", FollowEvidence.spanText(0))
        assertEquals("50 m", FollowEvidence.spanText(24))
        assertEquals("50 m", FollowEvidence.spanText(25))
        assertEquals("650 m", FollowEvidence.spanText(667))
        assertEquals("950 m", FollowEvidence.spanText(950))
        assertEquals("1000 m", FollowEvidence.spanText(999))   // still metres under 1 km
        assertEquals("1 km", FollowEvidence.spanText(1000))
        assertEquals("2.2 km", FollowEvidence.spanText(2223))
        assertEquals("12 km", FollowEvidence.spanText(11986))
        assertEquals("12 km", FollowEvidence.spanText(12000))
    }

    @Test
    fun durationTextNeverOverstatesTheRun() {
        assertEquals("15 minutes", FollowEvidence.durationText(900))
        assertEquals("20 minutes", FollowEvidence.durationText(1200))
        assertEquals("60 minutes", FollowEvidence.durationText(3600))
        assertEquals("89 minutes", FollowEvidence.durationText(5399))
        assertEquals("1.5 hours", FollowEvidence.durationText(5400))
        assertEquals("2 hours", FollowEvidence.durationText(7200))
        assertEquals("2 hours", FollowEvidence.durationText(8999))    // floored, never overstated
        assertEquals("2.5 hours", FollowEvidence.durationText(9000))
        // Half hours are floored, so 2h59m reads 2.5 hours rather than rounding up to 3.
        assertEquals("2.5 hours", FollowEvidence.durationText(10_799))
    }

    /** Every state carries the session-and-trackers-only clause, INCLUDING the two that say
     *  nothing was found or nothing was measured. Its absence from a body-cam screen would
     *  otherwise read as a clean result rather than a check that never ran, and its absence from
     *  the no-crumb states after a restart left the "nothing to compare" line standing with
     *  nothing to explain it. */
    @Test
    fun everyStateCarriesTheScopeSentence() {
        val none = score(ladder(step = 0.0010, count = 3), elapsedSec = 1200)
        val notMeasured = score(ladder(step = 0.0050, count = 5), elapsedSec = 100)
        val nearby = score(ladder(step = 0.0030, count = 3), elapsedSec = 1200)
        val across = score(ladder(step = 0.0050, count = 5), elapsedSec = 3600)
        for (ev in listOf(none, notMeasured, nearby, across)) {
            assertTrue(ev.uiText.endsWith(FollowEvidence.SCOPE_TEXT))
        }
        // No em-dashes anywhere in the user-facing copy. Written as an escape so this file does
        // not itself contain the character it bans.
        val copy = listOf(
            none.uiText, notMeasured.uiText, nearby.uiText, across.uiText,
            FollowEvidence.NO_LOCATION_TEXT, FollowEvidence.NO_FIX_TEXT,
            FollowEvidence.NOT_MEASURED_TEXT, FollowEvidence.KICKER,
        )
        for (s in copy) assertTrue("em-dash in copy: $s", !s.contains('\u2014'))
    }

    /** Every user-visible string, asserted as a literal. This is the half of parity that no amount
     *  of arithmetic testing covers: the two platforms can agree perfectly on the band and still
     *  print different sentences. The iOS suite asserts the identical literals, so a wording change
     *  made on one side alone fails there and here rather than shipping as a quiet divergence. */
    @Test
    fun everyUserFacingStringIsPinned() {
        assertEquals("SEEN WITH YOU", FollowEvidence.KICKER)
        assertEquals("near you more than once", FollowBand.NEARBY.label)
        assertEquals("near you in several places", FollowBand.ACROSS.label)
        // Neither no-claim state gets a header that the body would immediately walk back.
        assertEquals(null, FollowBand.NONE.label)
        assertEquals(null, FollowBand.NOT_MEASURED.label)
        assertEquals(
            "Counted this session only, and only for trackers. " +
                "Nothing about this is kept when the session ends.",
            FollowEvidence.SCOPE_TEXT,
        )
        assertEquals(
            "beacons is not using location, so it cannot tell whether this tag moved with you.",
            FollowEvidence.NO_LOCATION_TEXT,
        )
        // Describes the app's own ledger, not the world. The old wording ("There was no usable
        // position while this tag was around") was false after every app restart, when the crumbs
        // are gone but the store row is not: the position existed, the app just no longer has it.
        assertEquals(
            "No position was recorded alongside this tag this session, so there is nothing to compare.",
            FollowEvidence.NO_FIX_TEXT,
        )
        assertEquals(
            "There is no reliable time record for this tag, so it was not compared against where " +
                "you have been.",
            FollowEvidence.NOT_MEASURED_TEXT,
        )
        assertEquals(
            "It has been near you, but not across enough ground to read anything into yet.",
            score(ladder(step = 0.0010, count = 3), elapsedSec = 1200).detailText,
        )
        assertEquals(
            FollowEvidence.NOT_MEASURED_TEXT,
            score(ladder(step = 0.0050, count = 5), elapsedSec = 100).detailText,
        )
        assertEquals(
            "It was near you at 3 places, about 650 m apart, over 20 minutes. " +
                "That also fits a neighbour, a shared ride, or a tag of your own.",
            score(ladder(step = 0.0030, count = 3), elapsedSec = 1200).detailText,
        )
        assertEquals(
            "It was near you at 5 places, about 2.2 km apart, over 60 minutes. Worth knowing what " +
                "it is. Someone travelling the same way looks exactly like this from here.",
            score(ladder(step = 0.0050, count = 5), elapsedSec = 3600).detailText,
        )
    }

}
