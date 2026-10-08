import XCTest
@testable import Beacons

final class HistoryReplayPolicyTests: XCTestCase {
    func testCleanDrainMayCheckpointHighestReceivedSequence() {
        XCTAssertEqual(
            historyEndDisposition(received: 100, expected: 100, resyncAttempts: 0, resyncCap: 2),
            .complete)
    }

    func testWireGapRetriesOnlyWithinThisConnectionsBudget() {
        XCTAssertEqual(
            historyEndDisposition(received: 99, expected: 100, resyncAttempts: 1, resyncCap: 2),
            .retryNow)
        XCTAssertEqual(
            historyEndDisposition(received: 99, expected: 100, resyncAttempts: 2, resyncCap: 2),
            .deferIncomplete)
    }

    func testLostBeginNeverFinalizesAStaleGenerationEvenForAnEmptyDrain() {
        // A board wipe can change generation while the begin notify is lost. end(n: 0) matching
        // received=0 is therefore NOT proof that the old tuple may be checkpointed.
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 0, resyncCap: 2,
            beginSeen: false), .retryNow)
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 2, resyncCap: 2,
            beginSeen: false), .deferIncomplete)
        XCTAssertFalse(historyEnvelopeAuthorizesCheckpoint(beginSeen: false))
    }

    func testMatchingEmptyDrainWithItsBeginMayFinalize() {
        XCTAssertEqual(historyEndDisposition(
            received: 0, expected: 0, resyncAttempts: 0, resyncCap: 2,
            beginSeen: true), .complete)
        XCTAssertTrue(historyEnvelopeAuthorizesCheckpoint(beginSeen: true))
    }

    func testIncompleteAttemptDisclosesAllObservableShortfall() {
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 100, received: 99, transportComplete: false), 1)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 99, received: 99, transportComplete: true), 1)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 99, received: 98, transportComplete: false), 2)
        XCTAssertEqual(replayUnreplayedCount(
            promised: 100, sent: 100, received: 101, transportComplete: false), 1)
    }

    func testReplayGenerationUsesExactNonzeroUInt32Lexeme() {
        XCTAssertEqual(Detection.exactWireUInt32(
            forKey: "gen", in: Data(#"{"hist":"begin","gen":42}"#.utf8)), 42)
        for raw in [
            #"{"hist":"begin","gen":1.0000000000000000001}"#,
            #"{"hist":"begin","gen":4294967296}"#,
            #"{"hist":"begin","gen":42,"gen":43}"#,
            #"{"hist":"begin","gen":42,"g\u0065n":43}"#,
        ] {
            XCTAssertNil(Detection.exactWireUInt32(forKey: "gen", in: Data(raw.utf8)), raw)
        }
    }

    /// A drain files an older buffered record after the live row for the same id. The live row
    /// carries ch, which a replay never has, so it must stay. Android used to file every anchored
    /// replay over it, and its CSV lost wifi_channel where this export kept it. The replay stamp is
    /// ingestHistory's capturedAt. Fixtures are verbatim in Android's twin,
    /// HistoryReplayPolicyTest.olderReplayNeverReplacesNewerLiveRow.
    func testOlderReplayNeverReplacesNewerLiveRow() throws {
        let live = try Detection.decodeWireJSON(Data(
            (#"{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:b6:22:0a:5c","rssi":-70,"# +
             #""det":"Hikvision on wifi","ch":149,"n":2}"#).utf8))
        let replay = try Detection.decodeWireJSON(Data(
            (#"{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:b6:22:0a:5c","rssi":-80,"n":1,"# +
             #""hist":true,"seq":7,"at":1790000000,"boot":3,"ms":5000}"#).utf8))
        XCTAssertEqual(live.id, replay.id)
        XCTAssertNil(replay.wifiChannel)
        let replayStamp = try XCTUnwrap(replay.capturedAt)
        let liveSeenAt = replayStamp.addingTimeInterval(60)
        let kept = replayReplacesRow(stamp: replayStamp, rowLastSeen: liveSeenAt) ? replay : live
        XCTAssertEqual(kept.wifiChannel, 149)
        // A replay that is not older still files, so the rule cannot pass by refusing everything.
        XCTAssertTrue(replayReplacesRow(stamp: liveSeenAt, rowLastSeen: liveSeenAt))
        XCTAssertTrue(replayReplacesRow(stamp: replayStamp, rowLastSeen: nil))
    }
}
