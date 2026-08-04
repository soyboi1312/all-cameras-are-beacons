import XCTest
import CoreLocation
@testable import Beacons

/// The SECTION 8 parity fixtures.
///
/// These are not "coverage". They are the mechanism holding iOS and Android to the same arithmetic:
/// the two platforms ship separate implementations of one document, and the failure mode nobody
/// notices is a band boundary that lands differently on each phone for the same walk. If a change
/// here makes a fixture fail, the change is wrong OR the same change is owed to Android; there is
/// no third reading.
///
/// EXACTLY WHAT IS SHARED WITH ANDROID, stated precisely because the previous version of this
/// comment claimed more than was true, and a test file that lies about its own reach is worse than
/// one that admits its limit:
///   - Fixtures A to I (journeys) and J to O (the boundaries) use the SAME VECTORS as
///     android/../FollowEvidenceTest.kt: same base point, same per-crumb steps, same crumb ORDER,
///     same elapsed, same base wall clock, and the same expected span / places / mean gap / band.
///     Four of A to I (D, E, F and I) did not, while both headers claimed they did; the Kotlin
///     suite was re-cut onto these vectors rather than the claim being softened, so the sentence is
///     now true rather than merely aspirational.
///   - Every user-facing string is asserted as a literal on both sides, character for character
///     (testEveryUserFacingStringIsPinned here, everyUserFacingStringIsPinned there).
///   - The guard ORDER in score() is pinned on both sides too, because several refusals can hold at
///     once and they print different sentences. It takes a vector that trips two guards at once to
///     pin it (zero crumbs AND no stamps, which is the demo tour's tracker), so both suites carry
///     that exact case; a five-crumb missing-stamp assertion passes under either order and pins
///     nothing.
///
/// What is NOT claimed: the two suites are not line for line identical. Each carries extra
/// assertions the other does not, always either on one of these same vectors or on the pure string
/// builders, so neither suite can pass on a vector the other would fail.
///
/// The likeliest way to break parity is to "simplify" the scorer's haversine into
/// CLLocation.distance because it is already imported. That swaps in a different geodesic model,
/// which disagrees with Android's by metres over kilometre scales, which flips bands at 250 / 500 /
/// 1000 m. These fixtures are what catches it.
final class FollowEvidenceTests: XCTestCase {

    // MARK: Vectors
    //
    // Every vector moves in LATITUDE ONLY from (37.000000, -122.000000). On a pure meridian arc the
    // haversine collapses to R * dLat exactly, so the expected metres below are arithmetic rather
    // than a value copied out of whatever the code happened to print. A longitude component would
    // fold cos(lat) into every one of them and make a hand-check impossible.

    private static let baseLat = 37.0
    private static let baseLon = -122.0
    /// One degree of latitude at R = 6371008.8 is 111195.08 m. This divisor is deliberately a hair
    /// SMALLER than that, which places every crumb a fraction of a metre beyond its nominal
    /// distance, so the scorer's floor() lands on the whole number the fixtures assert instead of
    /// one metre under it. Do not "correct" it to 111195.08: the vectors are chosen against this
    /// value, and fixture I's span would floor to 11999.
    private static let metresPerDegLat = 111194.93

    /// n crumbs marching north in equal steps.
    private func ladder(step: Double, count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map {
            CLLocationCoordinate2D(latitude: Self.baseLat + Double($0) * step, longitude: Self.baseLon)
        }
    }

    /// A tracker score with everything except the geometry and the duration held at "eligible".
    ///
    /// `elapsed` spans the CRUMB window (first crumb to last crumb), not the contact window. The
    /// scorer takes firstCrumbAt precisely so no caller can hand it the first-HEARD stamp, which
    /// outlives the crumbs it was being used to describe.
    private func score(_ crumbs: [CLLocationCoordinate2D],
                       elapsed: Int,
                       basis: TimeBasis = .exact,
                       type: DeviceType = .tracker) -> FollowEvidence.Score {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        return FollowEvidence.score(crumbs: crumbs,
                                    firstCrumbAt: first,
                                    lastCrumbAt: first.addingTimeInterval(TimeInterval(elapsed)),
                                    basis: basis,
                                    type: type)
    }

    // MARK: A - too little ground

    func testFixtureA_shortHopIsNotEvidence() {
        let s = score(ladder(step: 0.0010, count: 3), elapsed: 1200)
        XCTAssertTrue(s.eligible)
        XCTAssertEqual(s.span, 222)
        XCTAssertEqual(s.meanGapS, 600)
        XCTAssertEqual(s.band, .none, "222 m of ground is under the 500 m floor")
        // SPEC DISCREPANCY, recorded rather than papered over: SECTION 8 lists places = 2 for this
        // vector, but SECTION 3 is the normative algorithm and it yields 1. The three crumbs sit at
        // 0 m, 111 m and 222 m from the first, and every one of those is strictly inside the 250 m
        // anchor radius, so they all collapse onto one anchor. The band is unaffected (none either
        // way, because span 222 < 500), so behaviour and cross-platform parity are untouched; only
        // the fixture's intermediate number was wrong. Android must assert 1 here too.
        XCTAssertEqual(s.places, 1)
    }

    // MARK: B - the weaker band

    func testFixtureB_nearbyBand() {
        let s = score(ladder(step: 0.0030, count: 3), elapsed: 1200)
        XCTAssertEqual(s.span, 667)
        XCTAssertEqual(s.places, 3)
        XCTAssertEqual(s.meanGapS, 600)
        XCTAssertEqual(s.band, .nearby)
        XCTAssertEqual(FollowEvidence.detailText(s), "3 places, about 650 m apart, over 20 minutes")
        XCTAssertEqual(FollowEvidence.label(s.band), "near you more than once")
    }

    // MARK: C - the top band

    func testFixtureC_acrossBand() {
        let s = score(ladder(step: 0.0050, count: 5), elapsed: 3600)
        XCTAssertEqual(s.span, 2223)
        XCTAssertEqual(s.places, 5)
        XCTAssertEqual(s.meanGapS, 900)
        XCTAssertEqual(s.band, .across)
        XCTAssertEqual(FollowEvidence.detailText(s), "5 places, about 2.2 km apart, over 60 minutes")
        XCTAssertEqual(FollowEvidence.label(s.band), "near you in several places")
    }

    // MARK: D - below the crumb floor

    func testFixtureD_twoCrumbsIsACoincidence() {
        // Two points is a there-and-back and nothing more, however far apart they are.
        let s = score(ladder(step: 0.0500, count: 2), elapsed: 3600)
        XCTAssertFalse(s.eligible)
        XCTAssertEqual(s.band, .none)
    }

    // MARK: E - the two-encounters-hours-apart case the mean gap exists to kill

    func testFixtureE_meanGapTooWide() {
        // 5 km apart over two hours on three crumbs. This is the pattern that looks most like
        // following and least is: home in the morning, near work at noon.
        let s = score(ladder(step: 0.02248246, count: 3), elapsed: 7200)
        XCTAssertTrue(s.eligible)
        XCTAssertEqual(s.span, 4999)
        XCTAssertEqual(s.places, 3)
        XCTAssertEqual(s.meanGapS, 3600)
        XCTAssertEqual(s.band, .none, "mean gap 3600 s is over the 1200 s ceiling")
    }

    // MARK: F - why span is a diameter and not a path length

    func testFixtureF_wanderingOneSpotIsOnePlace() {
        // 20 crumbs zig-zagging inside a 200 m circle: an hour in a market, a mall floor, a
        // festival, an office. The SUMMED path is over a kilometre, which is precisely why the
        // scorer does not use summed path.
        var crumbs: [CLLocationCoordinate2D] = []
        var path = 0
        for i in 0..<20 {
            let ang = Double(i) * 2.0 * Double.pi / 20.0
            let r = (i % 2 == 0) ? 100.0 : 30.0
            let dLat = (r * cos(ang)) / Self.metresPerDegLat
            let dLon = (r * sin(ang)) / (Self.metresPerDegLat * cos(Self.baseLat * Double.pi / 180.0))
            let c = CLLocationCoordinate2D(latitude: Self.baseLat + dLat, longitude: Self.baseLon + dLon)
            if let prev = crumbs.last { path += FollowEvidence.metres(prev, c) }
            crumbs.append(c)
        }
        XCTAssertGreaterThan(path, 1000, "the fixture only makes its point if the path really is long")
        let s = score(crumbs, elapsed: 3600)
        XCTAssertTrue(s.eligible)
        XCTAssertEqual(s.places, 1)
        XCTAssertEqual(s.span, 200)
        XCTAssertEqual(s.band, .none)
    }

    // MARK: G - the clock moved under us

    func testFixtureG_clockJumpIsNotScored() {
        // Five crumbs cost at least four 60 s gates, so 100 s of elapsed is arithmetically
        // impossible. The geometry may be real, but the duration in the sentence would be fiction.
        let s = score(ladder(step: 0.0050, count: 5), elapsed: 100)
        XCTAssertFalse(s.eligible)
        // .notMeasured, NOT .none. This vector is fixture C's geometry, which bands across on a
        // sane clock, so "not across enough ground" would have been the opposite of the truth.
        XCTAssertEqual(s.band, .notMeasured)
    }

    // MARK: H - a derived first-seen stamp

    func testFixtureH_nonExactTimeBasisIsNotScored() {
        // A device first heard off the board's offline buffer carries a pseudo-time stamp near the
        // epoch, so elapsed would come out in decades.
        let s = score(ladder(step: 0.0050, count: 5), elapsed: 3600,
                      basis: .bracketed(after: nil, before: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertFalse(s.eligible)
        XCTAssertEqual(s.band, .notMeasured)
        // Control: the identical vector on an exact basis bands across, so the refusal above is the
        // time basis and nothing else, and the two states really do say opposite things.
        XCTAssertEqual(score(ladder(step: 0.0050, count: 5), elapsed: 3600).band, .across)
    }

    // MARK: I - a long run, and the string builders at km / hours scale

    func testFixtureI_longRunAcrossBand() {
        // Eight anchors spread over 12 km, plus a ninth crumb 100 m from the first, so n = 9 while
        // places stays 8. That gap between n and places is the point: crumbs are not places.
        let step = 12000.0 / (7.0 * Self.metresPerDegLat)
        var crumbs = ladder(step: step, count: 8)
        crumbs.append(CLLocationCoordinate2D(latitude: Self.baseLat + 100.0 / Self.metresPerDegLat,
                                             longitude: Self.baseLon))
        let s = score(crumbs, elapsed: 7200)
        XCTAssertEqual(s.places, 8)
        XCTAssertEqual(s.span, 12000)
        XCTAssertEqual(s.meanGapS, 900)
        XCTAssertEqual(s.band, .across)
        XCTAssertEqual(FollowEvidence.detailText(s), "8 places, about 12 km apart, over 2 hours")
    }

    // MARK: J to O - the boundaries themselves
    //
    // A to I are journeys, and a journey fixture sits nowhere near a threshold: a `>=` that quietly
    // became a `>` on ONE platform would keep every one of them passing on both. J to O are the
    // edges instead, one metre / one second / one crumb either side of every comparison in score().
    // Android runs these same six on the same vectors, which is the only thing that catches an
    // operator that drifted on one side.

    /// A crumb `m` metres north of base. On the meridian for the same reason the ladders are: the
    /// haversine reduces to R * dLat there, so "500 m" really is 500 m and the expected numbers
    /// below are arithmetic rather than values read back out of the code.
    private func at(_ m: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Self.baseLat + m / Self.metresPerDegLat,
                               longitude: Self.baseLon)
    }

    /// J: the nearby SPAN floor is inclusive. Crumbs at 0 m, 500 m and 100 m, so the third joins the
    /// first anchor (100 < 250) and places is 2 while the diameter is exactly 500.
    func testFixtureJ_nearbySpanFloorIsInclusive() {
        let onTheFloor = score([at(0), at(500), at(100)], elapsed: 900)
        XCTAssertEqual(onTheFloor.places, 2)
        XCTAssertEqual(onTheFloor.span, 500)
        XCTAssertEqual(onTheFloor.band, .nearby, "500 m IS the floor, not one metre over it")
        // One metre under, with places, elapsed and mean gap all unchanged, so the only thing that
        // can have moved the answer is the span comparison.
        let under = score([at(0), at(499), at(100)], elapsed: 900)
        XCTAssertEqual(under.places, 2)
        XCTAssertEqual(under.span, 499)
        XCTAssertEqual(under.band, .none)
    }

    /// K: both elapsed floors, on ONE vector (0 m, 600 m, 1200 m: three places, 1200 m across) run
    /// at four durations so time is the only thing moving.
    ///
    /// The across floor does not switch the panel off, it drops it a band, and that is the part
    /// worth pinning: falling short of the stronger claim must land on the weaker one, never on
    /// silence. A product built on under-claiming still has to say the smaller true thing.
    func testFixtureK_elapsedFloorsDemoteRatherThanSilence() {
        let trail = [at(0), at(600), at(1200)]
        XCTAssertEqual(score(trail, elapsed: 1800).band, .across)   // 30 min exactly
        XCTAssertEqual(score(trail, elapsed: 1799).band, .nearby)   // one second under: demoted
        XCTAssertEqual(score(trail, elapsed: 900).band, .nearby)    // 15 min exactly
        XCTAssertEqual(score(trail, elapsed: 899).band, .none)      // one second under: no band
    }

    /// L: the mean-gap ceiling is inclusive, on K's geometry so only the gap moves. n = 3, so the
    /// mean is elapsed / 2: 2400 s is exactly 1200 and fires, 2402 s is 1201 and does not.
    func testFixtureL_meanGapCeilingIsInclusive() {
        let trail = [at(0), at(600), at(1200)]
        let onTheLimit = score(trail, elapsed: 2400)
        XCTAssertEqual(onTheLimit.meanGapS, 1200)
        XCTAssertEqual(onTheLimit.band, .across)
        let over = score(trail, elapsed: 2402)
        XCTAssertEqual(over.meanGapS, 1201)
        // NOT demoted to nearby: both bands share the gap test, so one second past the ceiling
        // drops straight to none. That is the whole point of the ceiling. Two encounters hours
        // apart is the coincidence that looks most like following and least is it.
        XCTAssertEqual(over.band, .none)
    }

    /// M: places is the one thing distance cannot buy. Two anchors 1200 m apart over 40 minutes
    /// clears the across span, the across elapsed AND the gap, and still lands on nearby, because a
    /// there-and-back between two points is not a route through three.
    func testFixtureM_acrossNeedsThreePlacesNotJustDistance() {
        let s = score([at(0), at(1200), at(100)], elapsed: 2400)
        XCTAssertEqual(s.places, 2)
        XCTAssertEqual(s.span, 1200)
        XCTAssertEqual(s.meanGapS, 1200)
        XCTAssertEqual(s.band, .nearby)
    }

    /// N and O: the clock-sanity bound is (n - 1) * 60 with 5 s of slack, and it MOVES with n.
    ///
    /// The append gate spaces crumbs by at least 60 s, so a shorter window is a wall clock that
    /// moved rather than a tag that did. Both sides of both bounds are asserted because the pair is
    /// what makes it a bound: identical geometry, one second apart, and the two answers are a
    /// finding and a refusal.
    func testFixturesNO_clockSlackBoundMovesWithCrumbCount() {
        let three = [at(0), at(600), at(1200)]
        XCTAssertEqual(score(three, elapsed: 115).band, .none, "115 + 5 slack meets 2 * 60")
        XCTAssertEqual(score(three, elapsed: 114).band, .notMeasured)
        let four = [at(0), at(400), at(800), at(1200)]
        XCTAssertEqual(score(four, elapsed: 175).band, .none, "175 + 5 slack meets 3 * 60")
        XCTAssertEqual(score(four, elapsed: 174).band, .notMeasured)
    }

    // MARK: Type gate

    func testNonTrackerIsNeverScored() {
        // Redundant with the crumb-append gate today, and deliberately so: if crumb collection is
        // ever widened past trackers, this is the test that fails first.
        let s = score(ladder(step: 0.0050, count: 5), elapsed: 3600, type: .axonBodyCam)
        XCTAssertFalse(s.eligible)
        // .notMeasured, like every refusal except the crumb floor. Nothing was compared here, so
        // there is no finding of any kind to report, not even an empty one.
        XCTAssertEqual(s.band, .notMeasured)
    }

    // MARK: The window is the CRUMB window, not the contact window

    /// The band floors are measured across the crumbs themselves, so time before the trail started
    /// cannot buy a band.
    ///
    /// The arithmetic half of the first-crumb fix. first-seen is when the device was first HEARD and
    /// it is restored from the persisted store on launch; the crumb trail is session-only and starts
    /// later (a crumb needs a fresh fix, 60 s and 25 m). Scored from first-seen, a tag heard at
    /// 09:00 whose three crumbs all fell between 09:50 and 09:53 cleared the 900 s nearby floor on
    /// 180 s of trail. BLEManager.firstCrumbAt is the manager half; this is the half that proves the
    /// number in the sentence is the number the geometry spans.
    func testBandFloorsAreMeasuredAcrossTheCrumbsThemselves() {
        let trail = ladder(step: 0.0030, count: 3)   // fixture B's geometry: 667 m over 3 places
        // 800 s of crumbs is under the 900 s nearby floor, so the geometry alone is not enough.
        XCTAssertEqual(score(trail, elapsed: 800).band, .none)
        // The same geometry over a trail that does span the floor fires, so the rejection above is
        // the elapsed test and nothing else quietly failing.
        XCTAssertEqual(score(trail, elapsed: FollowEvidence.elapsedNearbyS).band, .nearby)
    }

    // MARK: Refusals are not findings

    /// Every refusal except the crumb floor reports .notMeasured, and .notMeasured is not .none.
    ///
    /// These used to come back as .none, which made the panel state a finding it had never computed
    /// and, for a tag replayed off the board's offline buffer, state the OPPOSITE of the truth: a
    /// tag that had ridden along for an hour was narrated as "not across enough ground to read
    /// anything into yet". In a product built on under-claiming a false reassurance is exactly as
    /// much a false statement as a false alarm, and it is the one nobody audits.
    func testRefusalsAreNotMeasuredRatherThanNone() {
        let trail = ladder(step: 0.0050, count: 5)   // fixture C's geometry, which bands across
        XCTAssertEqual(score(trail, elapsed: 3600, basis: .unknown).band, .notMeasured)
        XCTAssertEqual(score(trail, elapsed: 100).band, .notMeasured)
        XCTAssertEqual(score(trail, elapsed: FollowEvidence.maxElapsedS + 1).band, .notMeasured)
        // The ceiling itself is INCLUSIVE, so the refusal above is the ceiling and not an
        // off-by-one. A 24 h window over five crumbs IS scored and lands on none (its mean gap is
        // six hours, far past the 1200 s ceiling); the point is that it was scored at all.
        XCTAssertEqual(score(trail, elapsed: FollowEvidence.maxElapsedS).band, .none)
        // A missing stamp is a broken record, not an empty result. Cannot happen in the manager
        // (both stamps are written in the same branch that appends a crumb), which is the reason it
        // is a refusal rather than a finding if it ever does.
        XCTAssertEqual(FollowEvidence.score(crumbs: trail, firstCrumbAt: nil,
                                            lastCrumbAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            basis: .exact, type: .tracker).band, .notMeasured)
        XCTAssertEqual(FollowEvidence.score(crumbs: trail,
                                            firstCrumbAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            lastCrumbAt: nil,
                                            basis: .exact, type: .tracker).band, .notMeasured)
    }

    /// Fewer than three crumbs is the ONE refusal that keeps the none sentence, because there
    /// "not across enough ground to read anything into yet" is literally true. n = 0 is the tour's
    /// sample tracker, which seeds a row with no crumbs and no stamps and must NOT be narrated as a
    /// broken record.
    func testCrumbFloorKeepsTheNoneSentence() {
        for n in 0...2 {
            let s = score(ladder(step: 0.0500, count: n), elapsed: 3600)
            XCTAssertEqual(s.band, .none, "n=\(n)")
            XCTAssertEqual(FollowEvidence.body(s),
                           "It has been near you, but not across enough ground to read anything into yet.",
                           "n=\(n)")
        }
        // GUARD ORDER, pinned. The tour seeds a tracker row with no crumbs AND no stamps, so this
        // is the case that proves the crumb floor is tested BEFORE the stamps: a demo is an empty
        // result, not a broken record, and Kotlin's evaluate() orders it the same way.
        XCTAssertEqual(FollowEvidence.score(crumbs: [], firstCrumbAt: nil, lastCrumbAt: nil,
                                            basis: .exact, type: .tracker).band, .none)
    }

    // MARK: The place radius is strict

    func testPlaceRadiusIsStrictlyInside() {
        // SECTION 3: a crumb joins an anchor when it is STRICTLY within 250 m, so a crumb sitting
        // at exactly 250 m opens a new place. Flooring to whole metres is what makes "exactly" a
        // thing that can be asserted at all.
        let inside = 249.0 / Self.metresPerDegLat
        let at = 250.0 / Self.metresPerDegLat
        XCTAssertEqual(FollowEvidence.places(ladder(step: inside, count: 2)), 1)
        XCTAssertEqual(FollowEvidence.places(ladder(step: at, count: 2)), 2)
    }

    // MARK: String builders
    //
    // Hand-built integer strings, never a formatter: Kotlin's String.format would print "2,2 km"
    // in de-DE while iOS printed "2.2 km", and no test on either platform alone would show it.

    func testSpanText() {
        XCTAssertEqual(FollowEvidence.spanText(0), "50 m")        // floor, never "0 m"
        XCTAssertEqual(FollowEvidence.spanText(667), "650 m")     // nearest 50
        XCTAssertEqual(FollowEvidence.spanText(999), "1000 m")    // still metres under 1 km
        XCTAssertEqual(FollowEvidence.spanText(1000), "1 km")
        XCTAssertEqual(FollowEvidence.spanText(2223), "2.2 km")
        XCTAssertEqual(FollowEvidence.spanText(12000), "12 km")
    }

    func testDurationText() {
        XCTAssertEqual(FollowEvidence.durationText(900), "15 minutes")   // the nearby floor
        XCTAssertEqual(FollowEvidence.durationText(1200), "20 minutes")
        XCTAssertEqual(FollowEvidence.durationText(3600), "60 minutes")
        XCTAssertEqual(FollowEvidence.durationText(5400), "1.5 hours")   // the switchover
        XCTAssertEqual(FollowEvidence.durationText(7200), "2 hours")
        XCTAssertEqual(FollowEvidence.durationText(9000), "2.5 hours")
        XCTAssertEqual(FollowEvidence.durationText(8999), "2 hours")     // floored, never overstated
    }

    // MARK: Copy

    func testCopyCarriesTheScopeClauseAndNoEmDash() {
        // The scope clause is load-bearing: crumbs are session-only and tracker-only, and the
        // panel's absence from a body cam screen must not read as "checked, nothing found".
        XCTAssertTrue(FollowEvidence.scopeLine.contains("this session only"))
        XCTAssertTrue(FollowEvidence.scopeLine.contains("only for trackers"))
        // House style, checked mechanically because it is the kind of thing a later edit reintroduces.
        for s in [FollowEvidence.scopeLine, FollowEvidence.noLocationLine, FollowEvidence.noFixLine,
                  FollowEvidence.notMeasuredLine,
                  FollowEvidence.body(.unscored), FollowEvidence.body(.notMeasured),
                  FollowEvidence.kicker,
                  FollowEvidence.label(.nearby) ?? "", FollowEvidence.label(.across) ?? ""] {
            XCTAssertFalse(s.contains("\u{2014}"), "em-dash in user-facing copy: \(s)")
        }
        XCTAssertNil(FollowEvidence.label(.none), "the none state gets no header to walk back")
        XCTAssertNil(FollowEvidence.label(.notMeasured), "a refusal has nothing to head either")
    }

    /// A refusal must never come back wearing the none sentence. This is the assertion that fails
    /// if someone folds .notMeasured into .none to "simplify" the enum: the two states describe
    /// opposite situations, one a finding and one the absence of one.
    func testRefusalsDoNotBorrowTheNoneSentence() {
        XCTAssertEqual(FollowEvidence.body(.notMeasured), FollowEvidence.notMeasuredLine)
        XCTAssertNotEqual(FollowEvidence.body(.notMeasured), FollowEvidence.body(.unscored))
        // The none sentence survives for the one case where it is literally true: we looked, and
        // one or two crumbs is not enough ground. Two crumbs is fixture D.
        XCTAssertEqual(FollowEvidence.body(score(ladder(step: 0.0500, count: 2), elapsed: 3600)),
                       "It has been near you, but not across enough ground to read anything into yet.")
    }

    /// Every user-visible string, asserted as a literal. This is the half of parity that no amount
    /// of arithmetic testing covers: the two platforms can agree perfectly on the band and still
    /// print different sentences. Android's suite asserts the identical literals, so a wording
    /// change made on one side alone fails there and here rather than shipping as a quiet
    /// divergence between two phones sitting on the same table.
    func testEveryUserFacingStringIsPinned() {
        XCTAssertEqual(FollowEvidence.kicker, "SEEN WITH YOU")
        XCTAssertEqual(FollowEvidence.label(.nearby), "near you more than once")
        XCTAssertEqual(FollowEvidence.label(.across), "near you in several places")
        XCTAssertEqual(FollowEvidence.scopeLine,
                       "Counted this session only, and only for trackers. "
                       + "Nothing about this is kept when the session ends.")
        XCTAssertEqual(FollowEvidence.noLocationLine,
                       "beacons is not using location, so it cannot tell whether this tag moved with you.")
        // Describes the app's ledger, not the world. The row is persisted and the crumbs are not,
        // so after a restart the old wording ("there was no usable position while this tag was
        // around") asserted as fact something that had simply been dropped.
        XCTAssertEqual(FollowEvidence.noFixLine,
                       "No position was recorded alongside this tag this session, "
                       + "so there is nothing to compare.")
        XCTAssertEqual(FollowEvidence.notMeasuredLine,
                       "There is no reliable time record for this tag, "
                       + "so it was not compared against where you have been.")
        XCTAssertEqual(FollowEvidence.body(score(ladder(step: 0.0010, count: 3), elapsed: 1200)),
                       "It has been near you, but not across enough ground to read anything into yet.")
        XCTAssertEqual(FollowEvidence.body(score(ladder(step: 0.0030, count: 3), elapsed: 1200)),
                       "It was near you at 3 places, about 650 m apart, over 20 minutes. "
                       + "That also fits a neighbour, a shared ride, or a tag of your own.")
        XCTAssertEqual(FollowEvidence.body(score(ladder(step: 0.0050, count: 5), elapsed: 3600)),
                       "It was near you at 5 places, about 2.2 km apart, over 60 minutes. "
                       + "Worth knowing what it is. Someone travelling the same way looks exactly "
                       + "like this from here.")
    }

    // MARK: The 24 h ceiling

    func testRunLongerThanAnAddressLivesIsNotScored() {
        // A separated tracker holds one address for about a day, so a longer window is not one
        // device and must not be narrated as one.
        let s = score(ladder(step: 0.0050, count: 5), elapsed: 86401)
        XCTAssertFalse(s.eligible)
        XCTAssertEqual(s.band, .notMeasured, "a refused window is not a finding of nothing")
        let ok = score(ladder(step: 0.0050, count: 5), elapsed: 86400)
        XCTAssertTrue(ok.eligible)
    }
}
