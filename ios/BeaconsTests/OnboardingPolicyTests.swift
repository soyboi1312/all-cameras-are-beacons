import XCTest
@testable import Beacons

final class OnboardingPolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "tech.beacons.tests.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testChecklistWaitsForEncryptedSessionReadiness() {
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: false, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            checklistPresented: false), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            checklistPresented: false), .checklist)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: true, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            checklistPresented: false), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: false, setupHelpPresented: false,
            checklistPresented: false), .none)
    }

    /// Seen is the checklist's marker; the old build's pending key keeps a user it left
    /// mid-onboarding on the checklist once. An upgrader with seen and no pending never sees it.
    func testChecklistGateReadsBothDurableKeys() {
        XCTAssertTrue(firstRunOnboardingShouldRemainActive(
            hasSeenTour: false, finishSetupPending: false))
        XCTAssertTrue(firstRunOnboardingShouldRemainActive(
            hasSeenTour: true, finishSetupPending: true))
        XCTAssertFalse(firstRunOnboardingShouldRemainActive(
            hasSeenTour: true, finishSetupPending: false))

        let cases: [(seen: Bool, pending: Bool, expected: OnboardingPresentation)] = [
            (false, false, .checklist),
            (true, true, .checklist),
            (true, false, .none),
        ]
        for c in cases {
            XCTAssertEqual(onboardingPresentation(
                isSessionReady: true, isDemoMode: false, hasSeenTour: c.seen,
                finishSetupPending: c.pending, setupHelpPresented: false,
                checklistPresented: false), c.expected,
                "seen \(c.seen), pending \(c.pending)")
        }
    }

    func testPendingFinishSetupFromTheOldBuildOpensTheChecklistOnce() {
        FinishSetupOnboarding.arm(in: defaults)
        XCTAssertFalse(FirstRunTour.hasSeen(in: defaults))
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false,
            hasSeenTour: FirstRunTour.hasSeen(in: defaults),
            finishSetupPending: FinishSetupOnboarding.isPending(in: defaults),
            setupHelpPresented: false, checklistPresented: false), .checklist)

        XCTAssertTrue(persistChecklistCompletion(
            isReplay: false, isDemoMode: false, isSessionReady: true, defaults: defaults))
        XCTAssertTrue(FirstRunTour.hasSeen(in: defaults))
        XCTAssertFalse(FinishSetupOnboarding.isPending(in: defaults))
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false,
            hasSeenTour: FirstRunTour.hasSeen(in: defaults),
            finishSetupPending: FinishSetupOnboarding.isPending(in: defaults),
            setupHelpPresented: false, checklistPresented: false), .none)
    }

    func testReplayDemoAndLostReadinessNeverPersistTheChecklist() {
        XCTAssertFalse(persistChecklistCompletion(
            isReplay: true, isDemoMode: false, isSessionReady: true, defaults: defaults))
        XCTAssertFalse(persistChecklistCompletion(
            isReplay: false, isDemoMode: true, isSessionReady: true, defaults: defaults))
        XCTAssertFalse(persistChecklistCompletion(
            isReplay: false, isDemoMode: false, isSessionReady: false, defaults: defaults))
        XCTAssertFalse(FirstRunTour.hasSeen(in: defaults))
        XCTAssertFalse(FinishSetupOnboarding.isPending(in: defaults))
        XCTAssertFalse(checklistCompletionCanPersist(isReplay: true, isDemoMode: false,
                                                     isSessionReady: true))
        XCTAssertFalse(checklistCompletionCanPersist(isReplay: false, isDemoMode: true,
                                                     isSessionReady: true))
        XCTAssertFalse(checklistCompletionCanPersist(isReplay: false, isDemoMode: false,
                                                     isSessionReady: false))
        XCTAssertTrue(checklistCompletionCanPersist(isReplay: false, isDemoMode: false,
                                                    isSessionReady: true))
    }

    func testChecklistQueuesBehindHelpAndNeverStacksWithAnotherSheet() {
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: true,
            checklistPresented: false), .waitForSetupHelp)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: true,
            checklistPresented: false), .waitForSetupHelp)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: true, setupHelpPresented: false,
            checklistPresented: true), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: true, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: false,
            checklistPresented: false), .none)
    }

    /// The six category detectors, not the droui refinement of the drone detector.
    func testChecklistDetectorsTitleCountsEnabledDetectors() throws {
        func status(_ json: String) throws -> DeviceStatus {
            try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
        }
        // Sentence case since the 2026-09-26 review (P3-11): the uncounted title is a row title.
        XCTAssertEqual(checklistDetectorsTitle(count: enabledDetectorCount(nil)), "Detectors on")
        let five = try status(#"{"fw":"beacon board 2.0.9","flock":true,"drone":true,"droui":true,"bodycam":true,"tracker":false,"glasses":true,"ncam":true}"#)
        XCTAssertEqual(checklistDetectorsTitle(count: enabledDetectorCount(five)), "5 detectors on")
        // Absent flock / drone / glasses decode as ON, so the one-detector fixture sets them false.
        let one = try status(#"{"fw":"beacon board 2.0.9","flock":false,"drone":false,"bodycam":false,"tracker":false,"glasses":false,"ncam":true}"#)
        XCTAssertEqual(checklistDetectorsTitle(count: enabledDetectorCount(one)), "1 detector on")
    }

    func testAutomaticLiveModeStaysBlockedUntilOnboardingIsReleased() {
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: false,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: true))
        XCTAssertTrue(automaticLiveModeCanRun(hasReadySession: true,
                                               isDemoMode: false,
                                               locationAuthorized: true,
                                               firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: false,
                                                isDemoMode: false,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: false,
                                                locationAuthorized: false,
                                                firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: true,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: false))
    }

    func testLocationChoiceHasExplicitContinueAndNotNowState() {
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: false, isDenied: false),
                       .continueOrNotNow)
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: false, isDenied: true),
                       .openSettingsOrDone)
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: true, isDenied: false),
                       .done)
    }

    func testLocationPromptRequiresAVisibleCompletedFinishSetupSheet() {
        XCTAssertTrue(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: false, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: false, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: false,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: true, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: false))
    }

    func testDemoEntryCancelsActiveAndDeferredScanWork() {
        XCTAssertFalse(demoEntryNeedsScanCancellation(isScanning: false,
                                                       scanDeferred: false))
        XCTAssertTrue(demoEntryNeedsScanCancellation(isScanning: true,
                                                      scanDeferred: false))
        XCTAssertTrue(demoEntryNeedsScanCancellation(isScanning: false,
                                                      scanDeferred: true))
    }

    func testSecureReadinessWatchdogSpansTransportThroughReady() {
        XCTAssertEqual(secureReadinessTimeoutInterval, 45)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .transportConnected), .arm)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .sessionReady), .cancel)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .teardown), .cancel)

        let expected = UUID()
        XCTAssertTrue(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: false, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: UUID(),
            sessionReady: false, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: true, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: false, isDemoMode: true))
    }

    func testImproveDetectionRequiresAReadyRealBeacon() {
        XCTAssertTrue(improveDetectionAvailable(isSessionReady: true, isDemoMode: false))
        XCTAssertFalse(improveDetectionAvailable(isSessionReady: false, isDemoMode: false))
        XCTAssertFalse(improveDetectionAvailable(isSessionReady: true, isDemoMode: true))
        XCTAssertFalse(helpSupportActionIsVisible(
            "improveDetection", canImproveDetection: false))
        XCTAssertTrue(helpSupportActionIsVisible(
            "improveDetection", canImproveDetection: true))
        XCTAssertTrue(helpSupportActionIsVisible("firstRunTour", canImproveDetection: false))
        XCTAssertTrue(contributionCaptureCanStart(isSessionReady: true, isDemoMode: false))
        XCTAssertFalse(contributionCaptureCanStart(isSessionReady: false, isDemoMode: false))
        XCTAssertFalse(contributionCaptureCanStart(isSessionReady: true, isDemoMode: true))
    }

    /// Every failure path, for every board kind: one distinct diagnosis that names the board
    /// being connected by its own noun (decisions R14), never the generic "board", lowercase-first,
    /// with no dash and no unfilled template hole. Unknown (nil) reads exactly as beacon. TWIN:
    /// Android OnboardingRecoveryPolicyTest (its own causes, the same nouns).
    func testConnectionFailuresGiveDistinctBeaconRecovery() {
        let failures: [BeaconConnectionFailure] = [
            .timeout, .transport, .securePairing, .missingService, .missingChannel("config"),
            .secureServiceDiscovery, .secureChannelDiscovery,
        ]
        XCTAssertEqual(failures.map { beaconConnectionRecovery($0, kind: nil) },
                       failures.map { beaconConnectionRecovery($0, kind: .beacon) },
                       "an unknown kind reads exactly as beacon")
        for kind in BoardKind.allCases {
            let messages = failures.map { beaconConnectionRecovery($0, kind: kind) }
            XCTAssertEqual(Set(messages).count, failures.count, "\(kind)")
            for message in messages {
                XCTAssertTrue(message.contains(kind.noun), "\(kind): \(message)")
                XCTAssertFalse(message.contains("board"), "\(kind): \(message)")
                XCTAssertFalse(message.contains("{"), "unfilled hole: \(message)")
                XCTAssertFalse(message.contains("\u{2013}") || message.contains("\u{2014}"), message)
                XCTAssertEqual(message.first.map { String($0) }, message.first.map { String($0).lowercased() },
                               "lowercase-first: \(message)")
            }
            for other in BoardKind.allCases where other != kind {
                XCTAssertFalse(messages.contains { $0.contains(" \(other.noun)") },
                               "\(kind) never names \(other)")
            }
            XCTAssertTrue(beaconConnectionRecovery(.securePairing, kind: kind).contains("iOS pairing request"))
            XCTAssertTrue(beaconConnectionRecovery(.missingChannel("detections + config"), kind: kind)
                .contains("missing its detections + config channel"))
            let window = renderBoardCopy(BLEManager.pairWindowHint, kind)
            XCTAssertTrue(window.contains("within two minutes"))
            XCTAssertTrue(window.contains("turn the \(kind.noun) off and on"), window)
        }
    }

    /// The "already paired to another phone?" note shows only under a hint a second phone can
    /// explain. TWIN: Android's showsPairWindowNote test holds the same four-row table, so a
    /// stage that flips on one phone fails that phone's suite.
    func testPairWindowNoteShowsOnlyForLinkAndPairingStages() {
        let expected: [ConnectFailureStage: Bool] = [
            .link: true,
            .pairing: true,
            .profile: false,
            .secureSetup: false,
        ]
        XCTAssertEqual(Set(expected.keys), Set(ConnectFailureStage.allCases),
                       "every stage has a row: a new stage must choose")
        for stage in ConnectFailureStage.allCases {
            XCTAssertEqual(showsPairWindowNote(for: stage), expected[stage], "\(stage)")
        }
    }

    /// Each iOS failure cause lands on the stage that decides its note, and the hint carries the
    /// cause's own sentence. The post-encryption hints (buffer-key store, offline-history
    /// handshake, clear-log reply) are fixed text built through ConnectHint.secureSetup.
    func testConnectHintStagesForEveryFailureCause() {
        let expected: [(BeaconConnectionFailure, ConnectFailureStage)] = [
            (.timeout, .link),
            (.transport, .link),
            (.securePairing, .pairing),
            (.missingService, .profile),
            (.missingChannel("detections + config"), .profile),
            (.secureServiceDiscovery, .profile),
            (.secureChannelDiscovery, .profile),
        ]
        let kinds: [BoardKind?] = [nil] + BoardKind.allCases.map { $0 }
        for (failure, stage) in expected {
            XCTAssertEqual(connectFailureStage(failure), stage, "\(failure)")
            for kind in kinds {
                let hint = ConnectHint.failure(failure, kind: kind)
                XCTAssertEqual(hint.stage, stage, "\(failure)")
                XCTAssertEqual(hint.text, beaconConnectionRecovery(failure, kind: kind))
            }
        }
        let noted = expected.filter { showsPairWindowNote(for: $0.1) }.map(\.0)
        XCTAssertEqual(noted, [.timeout, .transport, .securePairing],
                       "the note follows exactly the connect and secure-pairing failures")
        let setup = ConnectHint.secureSetup("Offline history was not cleared. Reconnect and try again.")
        XCTAssertEqual(setup.stage, .secureSetup)
        XCTAssertFalse(showsPairWindowNote(for: setup.stage))
    }

    func testScanRowsUseHumanSignalBands() {
        XCTAssertEqual(beaconSignalDescription(rssi: -91), "weak")
        XCTAssertEqual(beaconSignalDescription(rssi: -90), "fair")
        XCTAssertEqual(beaconSignalDescription(rssi: -80), "good")
        XCTAssertEqual(beaconSignalDescription(rssi: -67), "strong")
    }

    func testBluetoothPrePermissionActionUsesNeutralContinueTitle() {
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: false, bluetoothGranted: false), "Continue")
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: false, bluetoothGranted: true), "Scan for Beacons")
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: true, bluetoothGranted: false), "Stop Scanning")
    }
}
