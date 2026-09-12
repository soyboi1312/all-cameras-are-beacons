import Foundation
import XCTest
@testable import Beacons

final class BeaconPresentationTests: XCTestCase {
    func testAbsentStatusNeverClaimsScanning() {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: nil,
            combinedUpdateRunning: false)

        XCTAssertEqual(value.connectionLabel, "CONNECTED · WAITING FOR STATUS")
        XCTAssertEqual(value.scanLabel, "CONNECTED · WAITING FOR BOARD STATUS")
        XCTAssertEqual(value.chipLabel, "WAITING")
        XCTAssertFalse(value.isScanning)
        XCTAssertEqual(value.tone, .neutral)
    }

    func testTransportConnectionWithoutSecureSessionNeverUsesRetainedStatus() throws {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: false,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true),
            combinedUpdateRunning: false)

        XCTAssertEqual(value.connectionLabel, "CONNECTED · SECURING LINK")
        XCTAssertEqual(value.chipLabel, "SECURING")
        XCTAssertFalse(value.isScanning)
    }

    func testReconnectIgnoresStaleNrfUpdateStatus() throws {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: true,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true, coproc: false, nrfUpdating: true),
            combinedUpdateRunning: false)

        XCTAssertEqual(value.connectionLabel, "RECONNECTING")
        XCTAssertEqual(value.scanLabel, "RECONNECTING · BOARD STATUS UNAVAILABLE")
        XCTAssertEqual(value.chipLabel, "RECONNECTING")
        XCTAssertFalse(value.isScanning)
    }

    func testCombinedUpdateUsesGenericDetectionCopy() throws {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true),
            combinedUpdateRunning: true)

        XCTAssertEqual(value.connectionLabel, "UPDATING FIRMWARE")
        XCTAssertEqual(value.scanLabel, "UPDATING FIRMWARE · DETECTION MAY PAUSE")
        XCTAssertEqual(value.chipLabel, "UPDATING")
        XCTAssertFalse(value.detail.contains("Wi-Fi scanning is on"))
        XCTAssertFalse(value.isScanning)
    }

    func testCurrentNrfUpdateCanNameWifiOnlyCoverage() throws {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true, coproc: false, nrfUpdating: true),
            combinedUpdateRunning: false)

        XCTAssertEqual(value.connectionLabel, "CONNECTED · UPDATING")
        XCTAssertEqual(value.chipLabel, "UPDATING")
        XCTAssertTrue(value.scanLabel.contains("WI-FI ONLY"))
        XCTAssertTrue(value.isScanning)
    }

    func testCoprocessorFaultOnlyExistsWhenBluetoothWasIntended() throws {
        let fault = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: true, wifi: true, coproc: false),
            combinedUpdateRunning: false)
        XCTAssertEqual(fault.connectionLabel, "CONNECTED · RADIO FAULT")
        XCTAssertEqual(fault.chipLabel, "RADIO FAULT")
        XCTAssertEqual(fault.tone, .warning)
        XCTAssertTrue(fault.isScanning, "Wi-Fi remains a live detector")

        let intentionallyOff = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: false, wifi: true, coproc: false),
            combinedUpdateRunning: false)
        XCTAssertEqual(intentionallyOff.connectionLabel, "CONNECTED OVER BLE")
        XCTAssertEqual(intentionallyOff.scanLabel, "SCANNING · WI-FI")
        XCTAssertEqual(intentionallyOff.tone, .accent)
    }

    func testBothRadiosOffIsConnectedButNotScanning() throws {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: false,
            status: try makeStatus(ble: false, wifi: false),
            combinedUpdateRunning: false)

        XCTAssertEqual(value.connectionLabel, "CONNECTED OVER BLE")
        XCTAssertEqual(value.chipLabel, "CONNECTED")
        XCTAssertEqual(value.scanLabel, "RADIOS OFF · NOT SCANNING")
        XCTAssertFalse(value.isScanning)
    }

    /// Sample mode names the tour's radio switches and sweeps the radar with them, arm for arm
    /// with Android's statusScanPresentation (StatusBeaconPresentationTest pins the same four
    /// literals). It never claims live hardware: the connection label stays SAMPLE DATA, so the
    /// header pill stays DEMO in every arm.
    func testDemoNamesItsSampleRadiosAndSweepsWithThem() throws {
        let cases: [(Bool, Bool, String, Bool)] = [
            (true,  true,  "SAMPLE DATA", true),
            (true,  false, "SAMPLE DATA · BLUETOOTH ONLY", true),
            (false, true,  "SAMPLE DATA · WI-FI ONLY", true),
            (false, false, "SAMPLE DATA · RADIOS OFF", false),
        ]

        for (ble, wifi, expected, sweeps) in cases {
            let value = beaconRadioPresentation(
                connectionState: .connected,
                sessionReady: true,
                isReconnecting: false,
                isDemoMode: true,
                status: try makeStatus(ble: ble, wifi: wifi),
                combinedUpdateRunning: false)

            XCTAssertEqual(value.chipLabel, "DEMO", "ble=\(ble) wifi=\(wifi)")
            XCTAssertEqual(value.connectionLabel, "SAMPLE DATA", "ble=\(ble) wifi=\(wifi)")
            XCTAssertEqual(value.scanLabel, expected)
            XCTAssertEqual(value.isScanning, sweeps, "the beam follows the sample switches")
        }
    }

    /// A missing frame must not sweep. enterDemo seeds demoMode and the frame together so this
    /// should be unreachable, but an absent status is never an all-clear anywhere else in this
    /// file and sample mode is not the exception.
    func testDemoWithoutAStatusFrameDoesNotSweep() {
        let value = beaconRadioPresentation(
            connectionState: .connected,
            sessionReady: true,
            isReconnecting: false,
            isDemoMode: true,
            status: nil,
            combinedUpdateRunning: false)

        XCTAssertEqual(value.chipLabel, "DEMO")
        XCTAssertEqual(value.scanLabel, "SAMPLE DATA · RADIOS OFF")
        XCTAssertFalse(value.isScanning)
    }

    func testUnavailableConnectionLabelsStayCompact() {
        let cases: [(BLEConnectionState, String)] = [
            (.poweredOff, "BT OFF"),
            (.unauthorized, "BT PERMISSION"),
            (.connecting, "CONNECTING"),
            (.scanning, "SEARCHING"),
            (.idle, "OFFLINE"),
            (.unknown, "CHECKING")
        ]

        for (state, expected) in cases {
            let value = beaconRadioPresentation(
                connectionState: state,
                sessionReady: false,
                isReconnecting: false,
                isDemoMode: false,
                status: nil,
                combinedUpdateRunning: false)
            XCTAssertEqual(value.chipLabel, expected)
            XCTAssertLessThanOrEqual(value.chipLabel.count, 15)
            XCTAssertFalse(value.isScanning)
        }
    }

    /// Every literal below is byte-identical to the Android arm StatusBeaconPresentationTest pins
    /// (`firmwareBannerPresentation` in DeviceScreen.kt): one banner, one wording, both phones.
    /// The one-click offer promises Bluetooth; an outdated board with no OTA listing does not,
    /// because the expanded card then offers only the browser flasher.
    func testFirmwareAvailabilityDistinguishesBoardAndCoprocessor() {
        let board = firmwarePresentation(
            installed: "2.0.7", outdated: true, combinedStale: true, s3Stale: true)
        XCTAssertEqual(board?.title, "Firmware v2.0.8 ready")
        XCTAssertEqual(board?.tone, .accent)
        XCTAssertEqual(board?.detail, "installed v2.0.7 · updates over Bluetooth")

        let browserOnly = firmwarePresentation(
            installed: "2.0.7", outdated: true, combinedStale: false, s3Stale: false)
        XCTAssertEqual(browserOnly?.title, "Firmware v2.0.8 ready")
        XCTAssertEqual(browserOnly?.detail, "installed v2.0.7 · open for update options")
        XCTAssertFalse(browserOnly?.detail.localizedCaseInsensitiveContains("bluetooth") == true)

        let coprocessor = firmwarePresentation(
            installed: "2.0.8", outdated: false, combinedStale: true, s3Stale: false)
        XCTAssertEqual(coprocessor?.title, "Second radio update ready")
        XCTAssertEqual(coprocessor?.detail, "co-processor firmware · installs over Bluetooth")

        let unread = firmwarePresentation(
            installed: nil, outdated: false, combinedStale: true, s3Stale: true)
        XCTAssertEqual(unread?.detail, "installed version unavailable · updates over Bluetooth",
                       "no made-up \"v-\" before the board's version has been read")
    }

    func testFirmwareRunningAndTerminalLabelsDoNotClaimAnotherAvailableUpdate() {
        let running = firmwarePresentation(
            state: .updatingS3, phase: "Sending board firmware", progress: 0.426)
        XCTAssertEqual(running?.title, "Updating board firmware")
        XCTAssertEqual(running?.detail, "Sending board firmware · 43%")
        XCTAssertEqual(running?.tone, .neutral)

        // Each running phase has its own title and its own fallback label when the coordinator
        // has not published one yet, the same five Android uses.
        XCTAssertEqual(firmwarePresentation(state: .checking)?.title, "Checking firmware")
        XCTAssertEqual(firmwarePresentation(state: .checking)?.detail,
                       "finding the right update for this beacon · 0%")
        XCTAssertEqual(firmwarePresentation(state: .reconnecting)?.title,
                       "Firmware update · reconnecting")
        XCTAssertEqual(firmwarePresentation(state: .updatingCoproc)?.title, "Updating second radio")
        XCTAssertEqual(firmwarePresentation(state: .verifying)?.title, "Verifying firmware update")

        let complete = firmwarePresentation(state: .done)
        XCTAssertEqual(complete?.title, "Firmware update complete")
        XCTAssertEqual(complete?.detail, "this beacon is up to date")
        XCTAssertEqual(complete?.tone, .accent)
        let noted = firmwarePresentation(state: .done, notice: "Both updates completed.")
        XCTAssertEqual(noted?.detail, "Both updates completed.",
                       "the coordinator's soft notice outranks the generic done line")

        let failed = firmwarePresentation(state: .failed(reason: "lost link"))
        XCTAssertEqual(failed?.title, "Firmware update failed")
        XCTAssertEqual(failed?.tone, .warning)
    }

    /// A stop the user asked for must not be reported as a failure on either platform. Android's
    /// FAILED arm makes the same call on the same two inputs. Removing the `cancelled` test from
    /// beaconFirmwareBannerPresentation fails every assertion here, and the phase-label-only case
    /// guards the half of the test that reads combinedPhaseLabel rather than the reason.
    func testUserCancelIsNotReportedAsAFirmwareFailure() {
        let cancelled = firmwarePresentation(
            state: .failed(reason: "Update cancelled."), phase: "Update cancelled")
        XCTAssertEqual(cancelled?.title, "Firmware update cancelled")
        XCTAssertEqual(cancelled?.detail, "no further update work is running")
        XCTAssertEqual(cancelled?.tone, .neutral)

        let labelOnly = firmwarePresentation(
            state: .failed(reason: "stopped"), phase: "Update cancelled")
        XCTAssertEqual(labelOnly?.title, "Firmware update cancelled")

        let reasonOnly = firmwarePresentation(state: .failed(reason: "Update cancelled."))
        XCTAssertEqual(reasonOnly?.title, "Firmware update cancelled")
    }

    func testPartialFirmwareCopyNamesWhichLegChanged() {
        let boardChanged = firmwarePresentation(state: .partial, combinedS3Updated: true)
        XCTAssertEqual(boardChanged?.title, "Firmware update incomplete")
        XCTAssertEqual(boardChanged?.detail, "board updated · second radio still needs attention")

        let boardUnchanged = firmwarePresentation(state: .partial, combinedS3Updated: false)
        XCTAssertEqual(boardUnchanged?.detail, "second radio still needs attention",
                       "a co-processor-only run that failed never touched the board")
    }

    func testHealthyFirmwareHasNoPromotedBanner() {
        XCTAssertNil(firmwarePresentation())
    }

    func testIdleFirmwareStatusDoesNotClaimCurrentWithoutEvidence() {
        let noStatus = beaconFirmwareStatusPresentation(
            hasCurrentStatus: false,
            installedVersion: "2.0.8",
            catalogHasBoard: true,
            latestVersion: "2.0.8",
            outdated: false)
        XCTAssertEqual(noStatus.detail, "Waiting for a current board firmware status.")
        XCTAssertEqual(noStatus.tone, .neutral)

        let unlisted = beaconFirmwareStatusPresentation(
            hasCurrentStatus: true,
            installedVersion: "9.1.0",
            catalogHasBoard: false,
            latestVersion: "2.0.8",
            outdated: false)
        XCTAssertTrue(unlisted.detail.contains("not listed in the current firmware catalog"))
        XCTAssertFalse(unlisted.offersBrowserFlasher)
    }

    func testIdleFirmwareStatusScopesLatestClaimToCurrentCatalog() {
        let current = beaconFirmwareStatusPresentation(
            hasCurrentStatus: true,
            installedVersion: "2.0.8",
            catalogHasBoard: true,
            latestVersion: "2.0.8",
            outdated: false)
        XCTAssertEqual(
            current.detail,
            "No newer board firmware is listed in this app's current catalog. Installed v2.0.8.")
        XCTAssertEqual(current.tone, .accent)
        XCTAssertFalse(current.offersBrowserFlasher)

        let old = beaconFirmwareStatusPresentation(
            hasCurrentStatus: true,
            installedVersion: "2.0.7",
            catalogHasBoard: true,
            latestVersion: "2.0.8",
            outdated: true)
        XCTAssertTrue(old.offersBrowserFlasher)
        XCTAssertEqual(old.tone, .warning)
    }

    /// The blocked state has to have its OWN copy and must not offer the flasher link, because
    /// that link goes to the disagreeing listing's own page. Android renders the same sentence
    /// from its `!revisionCompatible` arm. Dropping the `revisionCompatible` guard from
    /// beaconFirmwareStatusPresentation fails both assertions: the row would claim "up to date"
    /// with a newer version listed, or offer the flasher.
    func testRevisionMismatchBlocksTheOfferInsteadOfNamingAnUpdate() {
        let blocked = beaconFirmwareStatusPresentation(
            hasCurrentStatus: true,
            installedVersion: "2.0.7",
            catalogHasBoard: true,
            latestVersion: "2.0.8",
            outdated: false,
            revisionCompatible: false)
        XCTAssertEqual(
            blocked.detail,
            "Update unavailable: this firmware listing does not match the beacon's reported board revision. No update will be offered from this listing.")
        XCTAssertFalse(blocked.offersBrowserFlasher)
        XCTAssertEqual(blocked.tone, .warning)
    }

    func testFirmwareProgressHandlesNonFiniteInput() {
        let value = firmwarePresentation(
            state: .checking,
            phase: "Preparing",
            progress: .nan)
        XCTAssertEqual(value?.detail, "Preparing · 0%")
    }

    private func firmwarePresentation(
        state: CombinedUpdatePhase = .idle,
        phase: String = "",
        progress: Double = 0,
        notice: String? = nil,
        installed: String? = "2.0.8",
        outdated: Bool = false,
        combinedStale: Bool = false,
        s3Stale: Bool = false,
        combinedS3Updated: Bool = false
    ) -> BeaconFirmwareBannerPresentation? {
        beaconFirmwareBannerPresentation(
            combinedState: state,
            phaseLabel: phase,
            progress: progress,
            notice: notice,
            installedVersion: installed,
            latestVersion: "2.0.8",
            outdated: outdated,
            combinedStale: combinedStale,
            s3Stale: s3Stale,
            combinedS3Updated: combinedS3Updated)
    }

    private func makeStatus(
        ble: Bool,
        wifi: Bool,
        coproc: Bool? = nil,
        nrfUpdating: Bool? = nil
    ) throws -> DeviceStatus {
        var object: [String: Any] = [
            "fw": "beacon board",
            "ble": ble,
            "wifi": wifi
        ]
        if let coproc { object["co"] = coproc }
        if let nrfUpdating { object["nrfup"] = nrfUpdating }
        return try JSONDecoder().decode(
            DeviceStatus.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
}
