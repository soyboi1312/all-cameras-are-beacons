import XCTest
@testable import Beacons

/// The dossier's pure builders: the clock text (ago, span), the two row values the list derives
/// from a stamp or a score (SIGHTINGS, confidence), and the SIGNAL header's LIVE / STALE decision.
/// DetectionDetailView re-renders on a 1 s tick because these readings move with the clock and
/// nothing @Published does, and they only follow that tick while the builders measure against the
/// `now` they are handed. Every `now` below is in 1970, so a builder that reads the wall clock
/// prints an age of decades and fails here.
final class DetectionDetailTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAgoMeasuresToThePassedNowNotTheWallClock() {
        XCTAssertEqual(dossierRelativeAgo(now.addingTimeInterval(-61), now: now), "1m ago")
    }

    func testAgoAdvancesWithEachTick() {
        let heard = now
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(4)), "now")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(5)), "5s ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(59)), "59s ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(60)), "1m ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(3_600)), "1h ago")
        XCTAssertEqual(dossierRelativeAgo(heard, now: now.addingTimeInterval(86_400)), "1d ago")
    }

    func testAgoWithoutATimeIsADashAndAFutureStampIsNow() {
        XCTAssertEqual(dossierRelativeAgo(nil, now: now), "-")
        XCTAssertEqual(dossierRelativeAgo(now.addingTimeInterval(30), now: now), "now")
    }

    func testAgoDegradesOnAPoisonedDateInsteadOfTrapping() {
        let poisoned = Date(timeIntervalSinceReferenceDate: -1e300)
        XCTAssertTrue(dossierRelativeAgo(poisoned, now: now).hasSuffix("d ago"))
    }

    func testSpanMeasuresToThePassedNowNotTheWallClock() {
        XCTAssertEqual(dossierSightingSpan(since: now.addingTimeInterval(-18 * 60), now: now), "18m")
    }

    func testSpanFloorsAtOneSecondAndAdvancesWithEachTick() {
        let first = now
        XCTAssertEqual(dossierSightingSpan(since: first, now: now), "1s")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(59)), "59s")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(60)), "1m")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(3_600)), "1h")
        XCTAssertEqual(dossierSightingSpan(since: first, now: now.addingTimeInterval(86_400)), "1d")
    }

    /// The SIGHTINGS row names how good the first-seen time is, one arm per TimeBasis.
    /// Wrong input it catches: the `.reconstructed` arm without the `~` (a derived stamp would
    /// read as exact).
    func testSightingsTextNamesHowGoodTheFirstSeenTimeIs() {
        let first = now.addingTimeInterval(-61)
        XCTAssertEqual(dossierSightingsText(count: 3, firstSeen: first, basis: .exact, now: now),
                       "3 \u{00B7} first 1m ago")
        XCTAssertEqual(dossierSightingsText(count: 3, firstSeen: first,
                                            basis: .reconstructed(precisionSec: 30), now: now),
                       "3 \u{00B7} first ~1m ago")
        XCTAssertEqual(dossierSightingsText(count: 3, firstSeen: first,
                                            basis: .bracketed(after: nil, before: now), now: now),
                       "3 \u{00B7} time bounded")
        XCTAssertEqual(dossierSightingsText(count: 3, firstSeen: first, basis: .unknown, now: now),
                       "3 \u{00B7} time unknown")
        XCTAssertEqual(dossierSightingsText(count: 3, firstSeen: nil, basis: .exact, now: now), "3")
    }

    /// The SIGHTINGS age follows the `now` it is handed, tick by tick.
    /// Wrong input it catches: a builder that measures against Date() instead of `now` (it prints
    /// thousands of days, because `now` here is in 1970).
    func testSightingsTextAdvancesWithEachTick() {
        let first = now
        XCTAssertEqual(dossierSightingsText(count: 1, firstSeen: first, basis: .exact,
                                            now: now.addingTimeInterval(4)),
                       "1 \u{00B7} first now")
        XCTAssertEqual(dossierSightingsText(count: 1, firstSeen: first, basis: .exact,
                                            now: now.addingTimeInterval(60)),
                       "1 \u{00B7} first 1m ago")
    }

    /// The confidence row: the verdict band, then the percent, at both band edges (50 and 80).
    /// Wrong input it catches: the weak band spelled `case ...50:` (50 reads weak).
    func testConfidenceLineNamesTheBandAndThePercent() {
        XCTAssertEqual(dossierConfidenceLine(confidence: 0), "Weak match, verify \u{00B7} 0%")
        XCTAssertEqual(dossierConfidenceLine(confidence: 49), "Weak match, verify \u{00B7} 49%")
        XCTAssertEqual(dossierConfidenceLine(confidence: 50), "Partial match \u{00B7} 50%")
        XCTAssertEqual(dossierConfidenceLine(confidence: 79), "Partial match \u{00B7} 79%")
        XCTAssertEqual(dossierConfidenceLine(confidence: 80), "Strong match \u{00B7} 80%")
        XCTAssertEqual(dossierConfidenceLine(confidence: 100), "Strong match \u{00B7} 100%")
    }

    /// A dossier value draws through keepingMiddleDotsAttached: a no-break space before each
    /// middle dot, so an AX5 wrap never starts a line with an orphan "· 80%". Every dot in a
    /// multi-dot value gets the joiner, and a value with no dot is drawn as it is.
    /// Wrong inputs it catches: dossierValueForDisplay returning the value as it is (the plain
    /// space returns), a joiner AFTER the dot instead of before it, and a helper that joins only
    /// the first dot. It does not see the view: dossierRowValue must keep drawing this builder.
    func testDossierValueKeepsEachMiddleDotOnItsWordsLine() {
        XCTAssertEqual(dossierValueForDisplay(dossierConfidenceLine(confidence: 80)),
                       "Strong match\u{00A0}\u{00B7} 80%")
        XCTAssertEqual(dossierValueForDisplay(methodChipLabel(method: .oui, maker: "Axon")),
                       "OUI\u{00A0}\u{00B7} VENDOR ONLY")
        XCTAssertEqual(dossierValueForDisplay("3 \u{00B7} first 4m ago \u{00B7} derived"),
                       "3\u{00A0}\u{00B7} first 4m ago\u{00A0}\u{00B7} derived")
        XCTAssertEqual(dossierValueForDisplay("00:25:DF:12:34:56"), "00:25:DF:12:34:56")
    }

    /// The SIGNAL header: a sample row reads LIVE whatever its age (C10, sample data is always
    /// active), a real row reads STALE once its last sighting is older than activeNearbyInterval,
    /// and a sample row never asks the store. The store's answer is built with lastSeenIsStale,
    /// the rule BLEManager.isStale applies.
    /// Wrong inputs it catches: the demo arm removed (a sample row older than 45 s reads STALE),
    /// and the operands swapped to `storeIsStale() && !isDemoMode` (the store is asked for a
    /// sample row).
    func testSampleRowsReadLiveWhateverTheirAgeAndRealRowsGoStale() {
        let old = now.addingTimeInterval(-(activeNearbyInterval + 1))
        let fresh = now.addingTimeInterval(-activeNearbyInterval)
        XCTAssertFalse(dossierSignalIsStale(isDemoMode: true,
                                            storeIsStale: lastSeenIsStale(old, now: now)),
                       "a sample row older than the window must read LIVE")
        XCTAssertTrue(dossierSignalIsStale(isDemoMode: false,
                                           storeIsStale: lastSeenIsStale(old, now: now)),
                      "a real row older than the window must read STALE")
        XCTAssertFalse(dossierSignalIsStale(isDemoMode: false,
                                            storeIsStale: lastSeenIsStale(fresh, now: now)),
                       "a real row heard inside the window must read LIVE")
        var asked = false
        let askStore: () -> Bool = { asked = true; return true }
        XCTAssertFalse(dossierSignalIsStale(isDemoMode: true, storeIsStale: askStore()))
        XCTAssertFalse(asked, "a sample row must not ask the store")
    }

    /// C12-03: the Technical details Last seen row agrees with the LIVE header in sample data.
    /// The seed stamps its rows once, so the measured age grows ("9m ago") while the header says
    /// LIVE; in sample data the row reads "now", and a real row keeps its measured age. Wrong
    /// input: without the demo arm the sample row read the 9 minute age.
    /// TWIN: android DetailTimeLabelsTest's sample Last seen case.
    func testSampleLastSeenReadsNowLikeTheLiveHeader() {
        let nineMinutes = now.addingTimeInterval(-9 * 60)
        XCTAssertEqual(dossierLastSeenValue(isDemoMode: true,
                                            measured: dossierRelativeAgo(nineMinutes, now: now)),
                       "now")
        XCTAssertEqual(dossierLastSeenValue(isDemoMode: false,
                                            measured: dossierRelativeAgo(nineMinutes, now: now)),
                       "9m ago")
        // The header and the row give one answer for the same sample row.
        XCTAssertFalse(dossierSignalIsStale(isDemoMode: true,
                                            storeIsStale: lastSeenIsStale(nineMinutes, now: now)))
    }

    /// U1-b: the SIGNAL header says SAMPLE for a sample row (never LIVE), else STALE or LIVE.
    /// Wrong input: the demo arm reading "LIVE". TWIN: android DetailTimeLabelsTest.
    func testSignalWordNamesSampleThenStaleThenLive() {
        XCTAssertEqual(dossierSignalWord(isDemoMode: true, stale: false), "SAMPLE")
        XCTAssertEqual(dossierSignalWord(isDemoMode: false, stale: true), "STALE")
        XCTAssertEqual(dossierSignalWord(isDemoMode: false, stale: false), "LIVE")
    }

    /// U3-a: no "Remote ID over Remote ID". Wrong input: always "over <source>".
    func testFlaggedLineDropsARepeatedSource() {
        XCTAssertEqual(dossierFlaggedLine(methodLabel: "Remote ID", sourceLabel: "Remote ID"),
                       "Flagged by Remote ID.")
        XCTAssertEqual(dossierFlaggedLine(methodLabel: "OUI match", sourceLabel: "WiFi"),
                       "Flagged by OUI match over WiFi.")
    }

    /// U3-b: the maker is dropped from the hero subtitle only when it IS the headline (ignoring
    /// case); no fuzzy match. Wrong input: always appending the maker.
    func testHeroSubtitleDropsAMakerThatIsTheHeadline() {
        XCTAssertEqual(dossierHeroSubtitle(node: "AABB", makerOrVendor: "Apple Find My",
                                           headline: "Apple Find My"), "NODE AABB")
        XCTAssertEqual(dossierHeroSubtitle(node: "5E6F", makerOrVendor: "Meta", headline: "Meta"),
                       "NODE 5E6F")
        XCTAssertEqual(dossierHeroSubtitle(node: "2A10", makerOrVendor: "Flock Safety",
                                           headline: "FlockSafety"), "NODE 2A10 · Flock Safety")
    }

    /// U3-c: "matched on" keeps the two OUI telegrams the FAQ quotes and every other method label
    /// verbatim, with its own casing. Wrong inputs: `.lowercased()` ("manufacturer id") and the
    /// retired "NAME MATCH". TWIN: android DetailTimeLabelsTest
    /// methodChipLabelPrefersVendorOnlyOverChipsetOnly.
    func testMethodChipLabelKeepsEachLabelsOwnCasing() {
        XCTAssertEqual(methodChipLabel(method: .oui, maker: "Axon"), "OUI · VENDOR ONLY")
        XCTAssertEqual(methodChipLabel(method: .oui, maker: nil), "OUI · CHIPSET ONLY")
        XCTAssertEqual(methodChipLabel(method: .name, maker: nil), "device name")
        XCTAssertEqual(methodChipLabel(method: .mfgID, maker: "Meta"), "manufacturer ID")
        XCTAssertEqual(methodChipLabel(method: .ssid, maker: nil), "SSID")
        XCTAssertEqual(methodChipLabel(method: .remoteID, maker: nil), "Remote ID")
    }

    /// U3-f: the body-cam fallback sentence names the offline buffer only for a real replay.
    /// TWIN: android DetailTimeLabelsTest's dossierBodyCamFallbackLine case.
    func testBodyCamFallbackNamesTheBufferOnlyForAReplay() {
        XCTAssertEqual(dossierBodyCamFallbackLine(isReplay: true),
                       "Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired.")
        XCTAssertEqual(dossierBodyCamFallbackLine(isReplay: false),
                       "Matched a body-worn camera signature. The board didn't report which one.")
    }

    /// U3-f seed fidelity: the sample body cam carries the firmware's Axon OUI detail verbatim, so
    /// the dossier names its signature, and it is a LIVE row, never a replay. Wrong input: a seed
    /// row without `det` (no signature) or with `hist` (the buffer sentence on a live sample).
    /// TWIN: android MuteAndNearbyPolicyTest's DEMO_SAMPLE_ROWS body cam case.
    func testSampleBodyCamIsWireRealAndLive() throws {
        let rows = try demoSampleRows().map {
            try JSONDecoder().decode(Detection.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        let cams = rows.filter { $0.type == .axonBodyCam }
        XCTAssertEqual(cams.count, 1)
        let cam = try XCTUnwrap(cams.first)
        XCTAssertEqual(cam.detail, "Axon OUI")
        XCTAssertEqual(cam.bodyCamSignature, .axonOUI)
        XCTAssertFalse(cam.isHistory)
    }

    /// U3-g: the "(offline)" note belongs to a tracker's detail only. Wrong input: a gate on the
    /// suffix alone (the body cam case). TWIN: android DetailTimeLabelsTest trackerOfflineNote.
    func testTrackerOfflineNoteNeedsATrackerAndTheSuffix() {
        XCTAssertEqual(trackerOfflineNote(type: .tracker, detail: "Apple Find My (offline)"),
                       "offline here means separated from its owner, not replayed from the offline buffer.")
        XCTAssertNil(trackerOfflineNote(type: .tracker, detail: "Tile"))
        XCTAssertNil(trackerOfflineNote(type: .tracker, detail: nil))
        XCTAssertNil(trackerOfflineNote(type: .axonBodyCam, detail: "x (offline)"))
    }

    /// U3-h: the signal graph plots on ONE fixed scale, -100 dBm at the floor and -30 at the
    /// ceiling, clamped. Wrong input: a per-series min...max, where a weak [-88, -86] series
    /// reaches the top of the plot. TWIN: android DetailTimeLabelsTest signalGraphFraction.
    func testSignalGraphUsesAFixedDbmScale() {
        XCTAssertEqual(signalGraphFloorDbm, -100)
        XCTAssertEqual(signalGraphCeilingDbm, -30)
        XCTAssertEqual(signalGraphFraction(rssi: -30), 1, accuracy: 1e-9)
        XCTAssertEqual(signalGraphFraction(rssi: -100), 0, accuracy: 1e-9)
        XCTAssertEqual(signalGraphFraction(rssi: -65), 0.5, accuracy: 1e-9)
        XCTAssertEqual(signalGraphFraction(rssi: -20), 1, accuracy: 1e-9)
        XCTAssertEqual(signalGraphFraction(rssi: -110), 0, accuracy: 1e-9)
        XCTAssertLessThan(signalGraphFraction(rssi: -88), signalGraphFraction(rssi: -54))
        XCTAssertLessThan(signalGraphFraction(rssi: -88), 0.25)
        XCTAssertLessThan(signalGraphFraction(rssi: -86), 0.25, "a weak series stays low")
    }
}
