package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection

class HistoryReplayPolicyTest {
    @Test fun cleanDrainMayCheckpointItsHighestReceivedSequence() {
        assertEquals(
            HistoryEndDisposition.COMPLETE,
            historyEndDisposition(received = 100, expected = 100, resyncAttempts = 0, resyncCap = 2),
        )
    }

    @Test fun aWireGapRetriesOnlyWithinThisConnectionsBudget() {
        assertEquals(
            HistoryEndDisposition.RETRY_NOW,
            historyEndDisposition(received = 99, expected = 100, resyncAttempts = 1, resyncCap = 2),
        )
        assertEquals(
            HistoryEndDisposition.DEFER_INCOMPLETE,
            historyEndDisposition(received = 99, expected = 100, resyncAttempts = 2, resyncCap = 2),
        )
    }

    @Test fun lostBeginNeverFinalizesAStaleGenerationEvenForAnEmptyDrain() {
        // A board wipe can change generation while the begin notify is lost. end(n=0) matching
        // received=0 is therefore NOT proof that the old tuple may be checkpointed.
        assertEquals(
            HistoryEndDisposition.RETRY_NOW,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 0, resyncCap = 2,
                beginSeen = false,
            ),
        )
        assertEquals(
            HistoryEndDisposition.DEFER_INCOMPLETE,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 2, resyncCap = 2,
                beginSeen = false,
            ),
        )
        assertFalse(historyEnvelopeAuthorizesCheckpoint(beginSeen = false))
    }

    @Test fun matchingEmptyDrainWithItsBeginMayFinalize() {
        assertEquals(
            HistoryEndDisposition.COMPLETE,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 0, resyncCap = 2,
                beginSeen = true,
            ),
        )
        assertTrue(historyEnvelopeAuthorizesCheckpoint(beginSeen = true))
    }

    @Test fun incompleteAttemptDisclosesAllObservableShortfall() {
        assertEquals(1, replayUnreplayedCount(100, 100, 99, transportComplete = false))
        assertEquals(1, replayUnreplayedCount(100, 99, 99, transportComplete = true))
        assertEquals(2, replayUnreplayedCount(100, 99, 98, transportComplete = false))
        // A duplicate can balance or exceed the count without identifying which seq was missed.
        assertEquals(1, replayUnreplayedCount(100, 100, 101, transportComplete = false))
    }

    /** A drain files an older buffered record after the live row for the same id. The live row
     *  carries ch, which a replay never has, so it must stay. Android used to file every anchored
     *  replay over it, and its CSV lost wifi_channel where the iOS export kept it. The stamps are
     *  fileHistory's: at * 1000 for an anchored record, HIST_PSEUDO_BASE - seq * 1000 for approx.
     *  Fixtures are verbatim in iOS's twin, testOlderReplayNeverReplacesNewerLiveRow. */
    @Test fun olderReplayNeverReplacesNewerLiveRow() {
        val live = decode(
            """{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:b6:22:0a:5c","rssi":-70,""" +
            """"det":"Hikvision on wifi","ch":149,"n":2}""")
        val replay = decode(
            """{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:b6:22:0a:5c","rssi":-80,"n":1,""" +
            """"hist":true,"seq":7,"at":1790000000,"boot":3,"ms":5000}""")
        assertEquals(live.id, replay.id)
        assertNull(replay.wifiChannel)
        val replayStamp = replay.at * 1000L
        val liveSeenAt = replayStamp + 60_000L
        val kept = if (replayReplacesRow(replayStamp, liveSeenAt)) replay else live
        assertEquals(149, kept.wifiChannel)
        // The approx case the old approx-only guard covered: a pseudo stamp never wins either.
        assertFalse(replayReplacesRow(AcabBleManager.HIST_PSEUDO_BASE - 7 * 1000L, liveSeenAt))
        // A replay that is not older still files, so the rule cannot pass by refusing everything.
        assertTrue(replayReplacesRow(liveSeenAt, liveSeenAt))
        assertTrue(replayReplacesRow(replayStamp, null))
    }

    private fun decode(json: String): Detection = Detection.fromWireJson(json, JSONObject(json))
}
