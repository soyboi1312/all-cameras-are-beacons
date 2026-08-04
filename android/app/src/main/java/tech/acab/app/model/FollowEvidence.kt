package tech.acab.app.model

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * "Has this tag been near me across more than one place?", answered from the breadcrumb trail the
 * BLE manager already keeps.
 *
 * WHY THIS IS A SEPARATE, MANAGER-FREE FILE. The firmware says outright (acab_scanner.cpp) that the
 * board cannot make this call: it has no location-over-time, only the phone does. But the phone's
 * copy of that judgement must not live in the manager either. It has to be reproducible byte for
 * byte against the iOS implementation, and the only way to prove that is to run both against the
 * same fixtures with no BLE stack, no permissions and no clock in the way. Everything here is pure:
 * in go a crumb list and four scalars, out comes a band and a sentence.
 *
 * WHY IT READS SO CAUTIOUSLY. This is evidence the user judges, never a verdict the app announces.
 * A false positive here is worse than a miss, because the same person who is told "you are being
 * followed" by a neighbour's earbuds stops believing the ALPR alerts too. So: no notification, no
 * haptic, no buzzer, no list badge, no map change, no CSV column. A detail screen and nothing else.
 * Every band string names an innocent explanation in the same breath as the numbers, on purpose.
 *
 * WHY THE CRUMB LIST IS ALREADY THE WHOLE SIGNAL. AcabBleManager appends a crumb of THE PHONE's own
 * position only when the record is live (not replayed), the device is a TRACKER, a fix under two
 * minutes old exists, at least 60 s has passed since that device's last crumb, and the phone has
 * moved at least 25 m since it. So n crumbs means the tag survived n-1 independent 60 s AND 25 m
 * gates while staying in radio range. This scorer NEVER re-applies those two tests. They already
 * happened at append time, and re-filtering the same thing twice would quietly move the effective
 * thresholds somewhere nobody wrote down.
 *
 * WHAT IS DELIBERATELY NOT AN INPUT, because an engineer will reach for each of these:
 *  - Detection.count (sightings) is dominated by advertising rate and scan luck, not by how long a
 *    tag stayed with you, so scoring on it would reward chatty tags.
 *  - bestRssi is a single 1-of-N extreme, so every device that ever passed close would clear an
 *    RSSI floor.
 *  - rssiHistory is capped at the last 48 samples and is not time-aligned with the crumbs, so a
 *    "median RSSI over the run" is not computable from what is on disk, and approximating it with
 *    bestRssi biases every device toward passing.
 *
 * Mirrors ios/Beacons/Models/FollowEvidence.swift constant for constant and word for word. The
 * parity fixtures in the unit tests are the actual guarantee; keep them.
 */
enum class FollowBand {
    /** SCORED, and the answer was "nothing yet". The comparison against where you have been did
     *  run, over crumbs that exist, and it did not clear a band. The panel still renders, because a
     *  tracker detail screen with NO panel reads as "checked, nothing found". */
    NONE,

    /** NOT SCORED. Distinct from [NONE] on purpose, and the distinction is the whole point: NONE is
     *  a finding, this is the absence of one.
     *
     *  A refusal used to be reported as NONE, which made the app state a result it had never
     *  computed and, in the offline-replay case, sometimes the OPPOSITE of the truth: a tag that
     *  had ridden along for an hour off the board's buffer was narrated as "not across enough
     *  ground to read anything into yet". In a product whose entire discipline is under-claiming,
     *  an over-claim in the reassuring direction is just as much a lie as one in the alarming
     *  direction, and it is the one nobody checks.
     *
     *  Reached when the time basis is derived, when the wall clock jumped under the window, when
     *  the window is longer than an address lives, when the two stamps are missing, or when the
     *  device is not a tracker at all. Every one of those is a statement about the RECORD, not
     *  about the tag, and the sentence says so. */
    NOT_MEASURED,

    /** "near you more than once": two places, half a kilometre apart, over a quarter hour. */
    NEARBY,

    /** "near you in several places": three places, a kilometre apart, over half an hour. */
    ACROSS;

    /** The line the user reads as the finding. Plain body text at the call site, NOT a Kicker:
     *  a casing transform is exactly the sort of thing that drifts between two platforms.
     *
     *  Null for both non-firing states. A header over "we did not measure this" would be a
     *  headline asserting something the body immediately walks back. */
    val label: String?
        get() = when (this) {
            NONE -> null
            NOT_MEASURED -> null
            NEARBY -> "near you more than once"
            ACROSS -> "near you in several places"
        }
}

/**
 * The scored result for one tracker, plus the sentences that describe it. A value, not a view
 * model: the detail screen renders it and nothing else consumes it.
 */
data class FollowEvidence(
    val band: FollowBand,
    /** Distinct 250 m anchors the crumbs fell into (see [FollowEvidence.places]). */
    val places: Int,
    /** Diameter of the crumb set in whole metres, NOT the walked path length. See [spanMetres]. */
    val spanM: Int,
    /** FIRST CRUMB to most recent crumb, in whole seconds.
     *
     *  Deliberately NOT "first heard". first-seen is when the device was first HEARD, which
     *  survives an app restart, while crumbs start later and die with the session. Scoring the
     *  gap between them narrated a duration the trail did not cover, and let both band time floors
     *  (900 s / 1800 s) be satisfied by minutes that contain no crumbs at all: a tag first heard at
     *  09:00 whose three crumbs all fell between 09:50 and 09:53 cleared the 15 minute floor on
     *  three minutes of trail. This is the window the geometry beside it actually spans. */
    val elapsedSec: Int,
    /** Crumbs the score was computed from, after the manager's 120-entry cap. */
    val crumbCount: Int,
) {
    /** "3 places, about 650 m apart, over 20 minutes". null for both non-firing states, which have
     *  no numbers worth quoting: reciting a 200 m span under a "not enough ground" line invites the
     *  reader to treat the number as the finding, and a NOT_MEASURED result has no numbers at all. */
    val summary: String?
        get() = if (band != FollowBand.NEARBY && band != FollowBand.ACROSS) null
        else "$places places, about ${spanText(spanM)} apart, over ${durationText(elapsedSec)}"

    /** The body paragraph: what was seen, then the innocent explanation, in that order and in the
     *  same breath. The second sentence is not a disclaimer bolted on, it is the point. */
    val detailText: String
        get() = when (band) {
            FollowBand.NONE ->
                "It has been near you, but not across enough ground to read anything into yet."
            // Says what was NOT DONE, not what was not found. See FollowBand.NOT_MEASURED.
            FollowBand.NOT_MEASURED -> NOT_MEASURED_TEXT
            FollowBand.NEARBY ->
                "It was near you at $summary. That also fits a neighbour, a shared ride, or a tag of your own."
            FollowBand.ACROSS ->
                "It was near you at $summary. Worth knowing what it is. Someone travelling the same way looks exactly like this from here."
        }

    /** Detail plus the scope clause, which every scored state carries including NONE. Assembled
     *  here for the fixtures only; the panel lays the two out as separate Texts so the caveat can
     *  sit a size down and a shade back, exactly as iOS stacks it. */
    val bodyText: String get() = "$detailText\n\n$SCOPE_TEXT"

    /** The whole panel as one string, label included. Only the fixtures read this; the view lays
     *  the three parts out itself so the label can be styled apart from the body. */
    val uiText: String get() = band.label?.let { "$it\n\n$bodyText" } ?: bodyText

    companion object {
        // ---- constants: single source of truth, same names on both platforms ----

        /** Three crumbs, not two. Two points is a there-and-back coincidence; three means the tag
         *  cleared two independent 60 s plus 25 m gates. */
        const val MIN_CRUMBS = 3

        /** A crumb joins an existing anchor when it is STRICTLY inside this radius. 250 m is what
         *  makes the coffee shop, the market and the office floor fall out entirely: a stationary
         *  or wandering phone yields ONE anchor no matter how many crumbs it stacks. */
        const val PLACE_RADIUS_M = 250

        /** Above any plausible stack of urban GPS error (10 to 30 m) and above BLE range, so two
         *  places 500 m apart are genuinely two places and not one place seen through drift. */
        const val SPAN_NEARBY_M = 500

        /** A kilometre rounds up the ~840 m figure Apple's own separated-tag behaviour was
         *  measured against, so this app is not quietly more trigger-happy than the platform
         *  detectors users compare it against. */
        const val SPAN_ACROSS_M = 1000

        /** 15 min. Stops a single trip leg, a lift to the shops, from qualifying. */
        const val ELAPSED_NEARBY_S = 900

        /** 30 min. Above Apple's 10 minute significant-location branch, far below its 8 hour
         *  daytime branch. */
        const val ELAPSED_ACROSS_S = 1800

        /** 20 min. Kills the commonest coincidence of all: the same tag at home in the morning and
         *  near the office at noon, which is two crumbs 10 km apart and would otherwise look like
         *  the strongest evidence in the app. */
        const val MAX_MEAN_GAP_S = 1200

        /** 24 h. A tracker address holds only about a day, so a longer run is not one device and
         *  must not be narrated as one. */
        const val MAX_ELAPSED_S = 86400

        /** Both stamps come off the wall clock, and a wall clock can jump (NTP, manual set). The
         *  append gate guarantees at least 60 s between crumbs, so an elapsed shorter than that
         *  means the clock moved, not that the tag did. Five seconds of slack for rounding. */
        const val CLOCK_SLACK_S = 5

        /** IUGG mean Earth radius, metres. A Double literal in both languages. */
        const val EARTH_RADIUS_M = 6371008.8

        // ---- copy ----

        /** Header over a firing band, and only over a firing band. Authored here rather than
         *  inline in the composable for the same reason every other string is: iOS reads its copy
         *  out of FollowEvidence too, and a literal typed into a view is a string that can drift
         *  without either platform's tests noticing. */
        const val KICKER = "SEEN WITH YOU"

        /** The last line of EVERY state, no exceptions: the bands, NONE, NOT_MEASURED, and both
         *  no-crumb states. The panel is absent from a body-cam detail screen, and without this
         *  sentence that absence reads as "nothing found there either" rather than "never looked".
         *
         *  It used to be suppressed on the two no-crumb states, on the reasoning that a
         *  session-and-trackers caveat under them would qualify a measurement never taken. That
         *  had it backwards. The no-crumb states are exactly where the user needs to be told the
         *  memory is session-scoped, because after a restart the row survives and the crumbs do
         *  not, and "session-scoped" is the ONLY thing that explains why a tag they watched ride
         *  with them yesterday has nothing behind it today. */
        const val SCOPE_TEXT =
            "Counted this session only, and only for trackers. Nothing about this is kept when the session ends."

        /** No crumbs because location was never granted. Says what the app is NOT doing rather
         *  than reporting a clean result it never computed. */
        const val NO_LOCATION_TEXT =
            "beacons is not using location, so it cannot tell whether this tag moved with you."

        /** No crumbs despite the permission.
         *
         *  Phrased as a fact about THE APP'S OWN LEDGER, not about the world. Two different states
         *  land here and only this phrasing is true in both: (1) no fix was ever fresh enough
         *  (under two minutes) while the tag was around, and (2) the app restarted, so the store
         *  row persisted while the session-only crumb trail did not. The old wording, "There was no
         *  usable position while this tag was around", asserted a fact about the world that was
         *  flatly false in case (2): the position existed and was used, the app simply no longer
         *  holds it. Every persisted tracker row said it after every cold start. */
        const val NO_FIX_TEXT =
            "No position was recorded alongside this tag this session, so there is nothing to compare."

        /** [FollowBand.NOT_MEASURED]. The register matches [NO_FIX_TEXT] and [NO_LOCATION_TEXT] on
         *  purpose: all three are the app declining to make a claim, and they should read as one
         *  voice rather than as a finding dressed up differently. */
        const val NOT_MEASURED_TEXT =
            "There is no reliable time record for this tag, so it was not compared against where you have been."

        // ---- distance ----

        /**
         * ONE haversine, implemented identically in both languages, used ONLY by this scorer.
         *
         * Do NOT reach for Location.distanceBetween here "because it is already there". It and
         * CLLocation.distance are different geodesic algorithms and disagree by metres over
         * kilometre scales, which flips bands at the 250 / 500 / 1000 m boundaries and silently
         * breaks parity with iOS. The crumb-APPEND gate keeps its platform call on purpose: that
         * is the hot ingest path, its threshold is 25 m, and a metre of disagreement there costs
         * nothing.
         *
         * Floored to whole metres so every comparison downstream is Int vs Int. Two libm
         * implementations can differ in the last ulp; flooring makes that unobservable.
         */
        fun metres(aLat: Double, aLon: Double, bLat: Double, bLon: Double): Int {
            val toRad = 3.141592653589793 / 180.0
            val p1 = aLat * toRad
            val p2 = bLat * toRad
            val dp = (bLat - aLat) * toRad
            val dl = (bLon - aLon) * toRad
            val s1 = sin(dp / 2.0)
            val s2 = sin(dl / 2.0)
            val h = s1 * s1 + cos(p1) * cos(p2) * s2 * s2
            val c = 2.0 * atan2(sqrt(h), sqrt(max(0.0, 1.0 - h)))
            return floor(EARTH_RADIUS_M * c).toInt()
        }

        private fun metres(a: Pair<Double, Double>, b: Pair<Double, Double>): Int =
            metres(a.first, a.second, b.first, b.second)

        // ---- geometry ----

        /**
         * Distinct places, as a greedy anchor pass in stored append order.
         *
         * A crumb joins an anchor when it is STRICTLY within [PLACE_RADIUS_M]; at exactly 250 m it
         * opens a new one. Order-dependent by construction, so both languages must iterate the same
         * stored order and break on the FIRST hit, not the nearest one.
         *
         * Kept separate from the diameter rather than derived from it, because the two numbers say
         * different things: a diameter alone cannot tell a there-and-back between two points from a
         * route through five, and "at 5 places" is the part a human can actually act on.
         */
        fun places(crumbs: List<Pair<Double, Double>>): Int {
            val anchors = ArrayList<Pair<Double, Double>>()
            for (c in crumbs) {
                var isNew = true
                for (a in anchors) {
                    if (metres(a, c) < PLACE_RADIUS_M) {
                        isNew = false
                        break
                    }
                }
                if (isNew) anchors.add(c)
            }
            return anchors.size
        }

        /**
         * Span is the MAX PAIRWISE distance between any two crumbs, i.e. the diameter of the point
         * set, NOT the sum of consecutive crumb distances.
         *
         * Path length answers "how far did I walk while this was near me", which is a question
         * about the user. Diameter answers "how far apart were the places this tag was near me",
         * which is the evidence claim actually being made on screen. The two split hard on exactly
         * the cases that matter: an hour in a market, a mall, a festival or an office floor with a
         * stranger's tag in range accumulates a crumb every 25 m and totals kilometres of path
         * while never leaving a 300 m circle. Path length calls that following; diameter calls it
         * one place. On the genuine drive-to-work-and-home round trip the two agree, so diameter
         * loses nothing.
         *
         * Diameter is also invariant to crumb cadence, so a tag that advertised more often cannot
         * score higher for the same journey, and it degrades SAFELY at the manager's 120-crumb cap:
         * dropping the oldest crumbs can only shrink a diameter, so a long run under-reports rather
         * than over-reports.
         *
         * O(n^2) with n <= 120 is 7140 flat haversines. Not worth optimizing; see the call site for
         * where it is allowed to run.
         */
        fun spanMetres(crumbs: List<Pair<Double, Double>>): Int {
            var span = 0
            for (i in 0 until crumbs.size - 1) {
                for (j in i + 1 until crumbs.size) {
                    val m = metres(crumbs[i], crumbs[j])
                    if (m > span) span = m
                }
            }
            return span
        }

        // ---- number to string ----

        /**
         * "650 m" / "2.2 km". All integer arithmetic and no formatter, deliberately.
         *
         * String.format is locale-sensitive and would print "2,2 km" in de-DE while iOS printed
         * "2.2 km", which is a parity break nobody would notice until a screenshot arrived from
         * Berlin. Int division truncates toward zero in both languages and every value here is
         * non-negative, so truncation and floor agree.
         */
        fun spanText(m: Int): String {
            if (m < 1000) {
                val r = max(50, ((m + 25) / 50) * 50)   // nearest 50 m, never "0 m"
                return "$r m"
            }
            val t = (m + 50) / 100                      // tenths of a km, half up
            val whole = t / 10
            val tenth = t % 10
            return if (tenth == 0) "$whole km" else "$whole.$tenth km"
        }

        /**
         * "20 minutes" / "2 hours" / "1.5 hours". Both band floors are at least 900 s, so the
         * minutes branch can never render a singular and there is no pluralization branch to get
         * wrong. Half hours are FLOORED so the panel never overstates the run.
         */
        fun durationText(s: Int): String {
            if (s < 5400) return "${s / 60} minutes"
            val h2 = s / 1800
            val whole = h2 / 2
            val half = h2 % 2
            return if (half == 0) "$whole hours" else "$whole.5 hours"
        }

        // ---- the score ----

        /**
         * Score one device. Always returns a value, and the value distinguishes THREE outcomes that
         * used to be collapsed into one:
         *   - [FollowBand.NEARBY] / [FollowBand.ACROSS]: a finding.
         *   - [FollowBand.NONE]: scored, nothing found. A RESULT, not an error, because silence
         *     must never be mistaken for a clean bill of health.
         *   - [FollowBand.NOT_MEASURED]: refused. The comparison never ran, so no finding of any
         *     kind may be reported. Reporting these as NONE was the app stating a result it had not
         *     computed.
         *
         * The caller gates on type before rendering anything at all (a body cam gets no panel, not
         * an empty one). The type check is repeated here anyway so this function is readable on its
         * own and cannot silently start scoring a widened crumb set if crumb collection is ever
         * extended past trackers.
         *
         * [firstCrumbAtMs] is the FIRST CRUMB's stamp, not first-seen. See [elapsedSec] for why,
         * and note the rename: the old parameter was called firstSeenAtMs, and silently
         * repurposing that name would have let every call site keep passing the wrong instant.
         *
         * [timeBasis] must still be Exact, and the reason CHANGED with that rename. It used to be
         * arithmetic self-defence: a row first heard off the board's offline buffer carries a
         * firstSeen on the HIST_PSEUDO_BASE pseudo-time axis just above the epoch, so an elapsed
         * measured from it came out in decades. Crumbs are only ever appended on the LIVE filing
         * path, so both stamps are now real wall-clock readings and that particular disaster can no
         * longer happen. The guard is kept anyway, deliberately, and it is now conservatism rather
         * than necessity: a derived basis means this row is a replay of a contact the phone did not
         * witness, the crumb window covers only whatever fragment of it the phone was present for,
         * and narrating that fragment as the run would understate one case and overstate the other.
         * Accepted miss, unchanged: a tag that was replayed and THEN rode with you live is never
         * scored. Do not delete this as dead code; it is a refusal, not a bug.
         */
        fun evaluate(
            type: DeviceType,
            crumbs: List<Pair<Double, Double>>,
            firstCrumbAtMs: Long?,
            lastCrumbAtMs: Long?,
            timeBasis: TimeBasis,
        ): FollowEvidence {
            val n = crumbs.size
            val none = FollowEvidence(FollowBand.NONE, places = 0, spanM = 0, elapsedSec = 0, crumbCount = n)
            val notMeasured =
                FollowEvidence(FollowBand.NOT_MEASURED, places = 0, spanM = 0, elapsedSec = 0, crumbCount = n)

            // Refusals, all of them NOT_MEASURED. Not one of these is a statement about where the
            // tag has been; each says the record this scorer would have had to read is unusable.
            if (type != DeviceType.TRACKER) return notMeasured
            if (timeBasis !is TimeBasis.Exact) return notMeasured
            // The ONE refusal that keeps the none sentence, because there "not across enough ground
            // to read anything into yet" is literally true: the crumbs are real, there are just
            // fewer than three of them, and that IS the finding.
            if (n < MIN_CRUMBS) return none
            // Unreachable in practice (the manager writes both stamps in the same branch that
            // appends a crumb, so n >= 3 implies both exist), which is exactly why a missing one
            // is a broken record rather than an empty result.
            val first = firstCrumbAtMs ?: return notMeasured
            val last = lastCrumbAtMs ?: return notMeasured

            val elapsed = ((last - first) / 1000L).toInt()
            // Clock sanity, both directions. The append gate guarantees elapsed >= (n-1)*60, so a
            // shorter one means the wall clock moved under us and every number below is fiction.
            //
            // Measured from the first crumb this bound is now exact rather than merely safe: the
            // window spans precisely the n-1 intervals the gate enforced. (At the manager's 120-crumb
            // cap it goes back to being conservative-in-the-loose-direction, because firstCrumbAt
            // outlives the oldest crumbs that get trimmed. Stated limit, accepted: it can only make
            // the test easier to pass, never harder, and the trimmed run is at least two hours long.)
            if (elapsed + CLOCK_SLACK_S < (n - 1) * 60) return notMeasured
            if (elapsed > MAX_ELAPSED_S) return notMeasured

            // A MEAN, not a max: there are no PER-CRUMB timestamps and this feature adds no
            // per-crumb storage. Stated limit, accepted: one long silence inside an otherwise dense
            // run still passes. That is fine, because a dense run genuinely rode along with you, and
            // the case the mean DOES catch is the important one (two encounters hours apart, the
            // coincidence that most looks like following and least is). Do not "fix" this by
            // inventing per-crumb timestamps without also revisiting the teardown sites that would
            // have to tear them down: the two window stamps alone already cost the manager a
            // side map apiece (firstCrumbAt, lastCrumbAt), both listed in perDeviceMaps.
            val meanGap = elapsed / (n - 1)   // n >= 3, so the divisor is >= 2
            val places = places(crumbs)
            val span = spanMetres(crumbs)

            val band = when {
                places >= 3 && span >= SPAN_ACROSS_M && elapsed >= ELAPSED_ACROSS_S &&
                    meanGap <= MAX_MEAN_GAP_S -> FollowBand.ACROSS
                places >= 2 && span >= SPAN_NEARBY_M && elapsed >= ELAPSED_NEARBY_S &&
                    meanGap <= MAX_MEAN_GAP_S -> FollowBand.NEARBY
                else -> FollowBand.NONE
            }
            return FollowEvidence(band, places = places, spanM = span, elapsedSec = elapsed, crumbCount = n)
        }
    }
}
