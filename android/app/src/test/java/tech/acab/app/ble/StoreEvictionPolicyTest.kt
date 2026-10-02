package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which rows leave the detection store at its cap ([storeEvictionVictims]).
 *
 * THE DEFECT (security review 2026-09-29). A transmitter faking a few thousand default-on
 * signatures from fresh addresses filled the store, and the old rule then dropped the OLDEST flag
 * rows: earlier sessions, replayed history, watched devices. The next checkpoint sealed the loss.
 * The rule now lets a flood evict its own rows, and watched rows go last.
 *
 * iOS twin: StoreEvictionPolicyTests.swift, vector for vector. Rows are listed oldest first, the
 * order each call site hands them over (by last filing here, by lastSeen on iOS). The call sites
 * themselves, and which clock feeds firstSeenMs there, are not pinned by this suite.
 */
class StoreEvictionPolicyTest {

    private data class Row(
        val id: String,
        val ambient: Boolean = false,
        val watched: Boolean = false,
        val firstSeenMs: Long? = null,
    )

    private val now = 1_790_000_000_000L

    private fun victims(rows: List<Row>, overflow: Int): List<String> =
        storeEvictionVictims(
            rows, overflow, now,
            id = { it.id }, isAmbient = { it.ambient },
            isWatched = { it.watched }, firstSeenMs = { it.firstSeenMs },
        )

    private fun old(n: Int, prefix: String = "old") =
        (0 until n).map { Row("$prefix$it", firstSeenMs = now - 3_600_000L) }

    private fun fresh(n: Int, ageMs: Long = 60_000L, prefix: String = "new") =
        (0 until n).map { Row("$prefix$it", firstSeenMs = now - ageMs) }

    /** Both suites pin the shared numbers, so changing one side alone fails a test. */
    @Test
    fun sharedThresholds() {
        assertEquals(600_000L, STORE_FLOOD_WINDOW_MS)
        assertEquals(500, STORE_FLOOD_COHORT_ROWS)
    }

    @Test
    fun nothingOverflowsNothingGoes() {
        assertEquals(emptyList<String>(), victims(old(3), 0))
    }

    /** Ambient rows go first, least recently seen first, and a watched ambient row is skipped. */
    @Test
    fun ambientRowsGoFirstAndWatchedAmbientIsKept() {
        val rows = listOf(
            Row("flagA", firstSeenMs = now - 3_600_000L),
            Row("ambB", ambient = true),
            Row("ambC", ambient = true, watched = true),
            Row("ambD", ambient = true),
        )
        assertEquals(listOf("ambB"), victims(rows, 1))
        assertEquals(listOf("ambB", "ambD"), victims(rows, 2))
        assertEquals(listOf("ambB", "ambD", "flagA"), victims(rows, 3))
    }

    /** THE ATTACK: 10 older rows, then 501 rows first seen a minute ago. The flood evicts its own
     *  oldest rows; every older row stays. Under the old rule this returned old0..old2. */
    @Test
    fun aFloodEvictsItsOwnRows() {
        assertEquals(listOf("new0", "new1", "new2"), victims(old(10) + fresh(501), 3))
    }

    /** Exactly the threshold is not a flood, so the ordinary rolling log applies. Pins `>`. */
    @Test
    fun atTheThresholdTheOldestFlagsGo() {
        assertEquals(listOf("old0", "old1", "old2"), victims(old(10) + fresh(500), 3))
    }

    /** The window is inclusive at exactly ten minutes and closed one second later. */
    @Test
    fun windowEdge() {
        assertEquals(listOf("new0"), victims(old(10) + fresh(501, ageMs = 600_000L), 1))
        assertEquals(listOf("old0"), victims(old(10) + fresh(501, ageMs = 601_000L), 1))
    }

    /** A row with no first-seen stamp counts as old, so 501 unstamped rows are not a flood. */
    @Test
    fun unstampedRowsCountAsOld() {
        val unstamped = (0 until 501).map { Row("nil$it", firstSeenMs = null) }
        assertEquals(listOf("old0"), victims(old(10) + unstamped, 1))
    }

    /** Watched flag rows are never counted into a flood and go only when nothing else is left. */
    @Test
    fun watchedRowsGoLast() {
        val rows = listOf(
            Row("w", watched = true, firstSeenMs = now - 3_600_000L),
            Row("x", firstSeenMs = now - 3_600_000L),
        )
        assertEquals(listOf("x"), victims(rows, 1))
        assertEquals(listOf("x", "w"), victims(rows, 2))
        val watchedFlood = (0 until 501).map { Row("wf$it", watched = true, firstSeenMs = now) }
        assertEquals("watched rows do not make a flood", listOf("old0"), victims(old(10) + watchedFlood, 1))
    }

    /** A watched row first seen during a flood is neither counted nor taken with the fakes. */
    @Test
    fun aWatchedRowInsideAFloodIsNotTakenWithIt() {
        val rows = old(10) + listOf(Row("wnew", watched = true, firstSeenMs = now - 60_000L)) + fresh(501)
        assertEquals(listOf("new0", "new1"), victims(rows, 2))
    }

    /** Watched rows do not count toward the threshold: 400 unwatched plus 101 watched is no flood. */
    @Test
    fun watchedRowsDoNotCountTowardAFlood() {
        val watchedFresh = (0 until 101).map { Row("w$it", watched = true, firstSeenMs = now - 60_000L) }
        assertEquals(listOf("old0"), victims(old(10) + fresh(400) + watchedFresh, 1))
    }

    /** Ambient rows do not count toward the threshold either, even freshly stamped ones. */
    @Test
    fun ambientRowsDoNotCountTowardAFlood() {
        val ambientFresh = (0 until 2).map { Row("amb$it", ambient = true, firstSeenMs = now - 60_000L) }
        assertEquals(listOf("amb0", "amb1", "old0"), victims(old(10) + ambientFresh + fresh(499), 3))
    }

    /** Every id comes back once, even when a later pass walks rows an earlier pass already took. */
    @Test
    fun noRowIsReturnedTwice() {
        val out = victims(fresh(501) + old(10), 505)
        assertEquals(505, out.toSet().size)
        assertEquals(listOf("old0", "old1", "old2", "old3"), out.takeLast(4))
    }

    /** Ambient rows run out first, then the flood's own rows follow, not the older flags. */
    @Test
    fun ambientThenFlood() {
        val rows = listOf(Row("amb", ambient = true)) + old(10) + fresh(501)
        assertEquals(listOf("amb", "new0"), victims(rows, 2))
    }
}
