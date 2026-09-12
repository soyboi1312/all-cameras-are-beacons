import XCTest
@testable import Beacons

/// The logbook's first-open baseline gate (logFirstOpenBaselineRuns in DetectionsView.swift).
/// It decides whether an ordinary appearance of the Log runs BLEManager.seedSeenWatermarkOnce,
/// which marks everything already stored as seen. Running it one appearance too early is the
/// regression this pins: the user taps a NEW notification, the first dossier pop runs the
/// postponed baseline, and the rows the tap promised are gone behind "Nothing new".
final class DetectionsViewGateTests: XCTestCase {
    private let mark = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 1_000_060)

    func testOrdinaryFirstOpenRunsTheBaseline() {
        XCTAssertTrue(logFirstOpenBaselineRuns(deepLinkNew: false, hasVisit: false,
                                               visitWatermark: nil, current: mark))
    }

    func testDeepLinkNeverBaselinesInTheSamePass() {
        XCTAssertFalse(logFirstOpenBaselineRuns(deepLinkNew: true, hasVisit: false,
                                                visitWatermark: nil, current: mark),
                       "the seed exists to show rows the baseline would mark seen")
        XCTAssertFalse(logFirstOpenBaselineRuns(deepLinkNew: true, hasVisit: true,
                                                visitWatermark: later, current: mark),
                       "the flag wins over a visit whose watermark has already moved")
    }

    func testBaselineIsSkippedForTheWholeSeededVisit() {
        // The assertion that fails if the skip is narrowed back to one appearance: a visit
        // recorded at the CURRENT watermark is still in progress, so a second appearance inside
        // it (a dossier pop, a size-class change) must still not run the postponed baseline.
        XCTAssertFalse(logFirstOpenBaselineRuns(deepLinkNew: false, hasVisit: true,
                                                visitWatermark: mark, current: mark))
    }

    func testVisitEndsOnlyWhenTheWatermarkMovesUnderIt() {
        // Leaving the Log tab calls markAllSeen (MainTabView.onChange(of: tab)), which stamps a
        // new Date. The next ordinary open is then outside the visit and baselines normally.
        XCTAssertTrue(logFirstOpenBaselineRuns(deepLinkNew: false, hasVisit: true,
                                               visitWatermark: mark, current: later))
    }

    func testNeverBaselinedInstallSeparatesNoVisitFromANilWatermark() {
        // nil is a real watermark (nothing was ever marked seen), which is why the visit is a
        // struct and its existence travels separately. Both rows here carry a nil watermark, and
        // they must not decide the same way.
        //
        // The second row is the ONLY assertion in this suite that fails if the hasVisit guard is
        // dropped from logFirstOpenBaselineRuns, so neither row is redundant and this test is not
        // safe to fold away. Without the guard a nil watermark compares equal to a nil current
        // mark, so an install that never ran a baseline and has no visit reads as a visit in
        // progress and the baseline never runs. The first row answers false with or without the
        // guard, and testOrdinaryFirstOpenRunsTheBaseline answers true either way (its nil
        // watermark against a set mark differs anyway), so neither of those covers it.
        XCTAssertFalse(logFirstOpenBaselineRuns(deepLinkNew: false, hasVisit: true,
                                                visitWatermark: nil, current: nil),
                       "a visit seeded before any baseline is still a visit")
        XCTAssertTrue(logFirstOpenBaselineRuns(deepLinkNew: false, hasVisit: false,
                                               visitWatermark: nil, current: nil))
    }
}
