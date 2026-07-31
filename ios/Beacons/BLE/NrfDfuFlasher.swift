import Foundation
import CoreBluetooth
import NordicDFU

/// Drives one nRF co-processor DFU over BLE, self-contained on its OWN CBCentralManager so the
/// app's live link to the S3 (BLEManager's central) is never disturbed while this runs.
///
/// The nRF, once the S3 relays the `nrfdfu` trigger, reboots into its Adafruit/Seeed bootloader
/// and advertises as "AdaDFU" with the legacy DFU service (0x1530). This class scans for that,
/// then hands the target to Nordic's DFUServiceInitiator, which speaks the legacy DFU protocol
/// end to end. The target is passed BY IDENTIFIER: the initiator uses its own internal central,
/// and a CBPeripheral is bound to the central that discovered it, so only the (central-agnostic)
/// identifier crosses between our scan and the library's transfer.
final class NrfDfuFlasher: NSObject {
    /// Legacy Nordic DFU service, as advertised by the Adafruit/Seeed bootloader in OTA mode.
    static let dfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")

    private let zipURL: URL
    private let onProgress: (Int) -> Void
    private let onLog: (String) -> Void
    private let onFinish: (Result<Void, Error>) -> Void

    private var scanCentral: CBCentralManager?
    private var dfuPeripheral: CBPeripheral?     // the discovered AdaDFU target, bound to scanCentral
    private var controller: DFUServiceController?
    private var scanTimeout: DispatchWorkItem?
    private var finished = false

    // START-phase stall recovery. Two field-confirmed failure modes stall the legacy START
    // handshake indefinitely (the library waits forever by design): (1) CoreBluetooth silently
    // drops the image-size write-without-response under radio congestion (IOS-DFU-Library #505),
    // and (2) the Adafruit bootloader wedges in its erase-before-response window. Both recover
    // on a fresh attempt (the second erase pass is near-instant), so: watchdog the phase between
    // start() and .uploading, and on expiry abort + rescan + retry, bounded.
    private var startWatchdog: DispatchWorkItem?
    private var retryCount = 0
    private let maxStartRetries = 3
    private var intentionalAbort = false

    /// `scanTimeoutSec` bounds how long we wait for AdaDFU to appear after the trigger; if the
    /// nRF never enters DFU (bad GPREGRET, no reboot), we fail rather than hang.
    init(zipURL: URL,
         onProgress: @escaping (Int) -> Void,
         onLog: @escaping (String) -> Void = { _ in },
         onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.zipURL = zipURL
        self.onProgress = onProgress
        self.onLog = onLog
        self.onFinish = onFinish
    }

    enum FlashError: LocalizedError {
        case targetNotFound
        case badPackage
        case dfu(String)
        var errorDescription: String? {
            switch self {
            case .targetNotFound: return "The co-processor didn't show up in update mode. It usually recovers on its own; reconnect and try again."
            case .badPackage:     return "The co-processor update package was unreadable."
            case .dfu(let m):     return m
            }
        }
    }

    /// Begin: scan for AdaDFU, then flash. Safe to call once per instance.
    func start(scanTimeoutSec: TimeInterval = 40) {
        onLog("scanning for the co-processor in update mode (AdaDFU)")
        scanCentral = CBCentralManager(delegate: self, queue: .main)
        let to = DispatchWorkItem { [weak self] in self?.fail(.targetNotFound) }
        scanTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSec, execute: to)
    }

    /// Abort an in-flight transfer (user cancel). No-op once finished.
    func cancel() {
        guard !finished else { return }
        _ = controller?.abort()
        if let central = scanCentral, let p = dfuPeripheral { central.cancelPeripheralConnection(p) }
        teardownScan()
        fail(.dfu("Co-processor update cancelled."))
    }

    // MARK: - internals

    private func beginDfu(peripheral: CBPeripheral) {
        dfuPeripheral = peripheral
        teardownScan()
        // Settle before starting: lets CoreBluetooth's shared outgoing buffer drain (the S3 link
        // is streaming notifications concurrently) so the START-phase write-without-response isn't
        // silently discarded — the documented #505 failure this pause works around.
        onLog("found AdaDFU; settling 3s, then starting transfer (attempt \(retryCount + 1))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.startTransfer(peripheral: peripheral)
        }
    }

    private func startTransfer(peripheral: CBPeripheral) {
        guard !finished else { return }
        let firmware: DFUFirmware
        do {
            firmware = try DFUFirmware(urlToZipFile: zipURL)
        } catch {
            fail(.badPackage); return
        }
        guard let central0 = scanCentral else { fail(.dfu("Bluetooth became unavailable.")); return }
        let initiator = DFUServiceInitiator(centralManager: central0, target: peripheral)
            .with(firmware: firmware)
        initiator.delegate = self
        initiator.progressDelegate = self
        initiator.logger = self          // route the library's verbose steps to onLog for diagnosis
        // We are already connected to the bootloader (AdaDFU), not the app, so there is no
        // buttonless jump and no address change to chase: flash this target in place.
        initiator.forceScanningForNewAddressInLegacyDfu = false
        initiator.alternativeAdvertisingNameEnabled = false
        // The stock Adafruit bootloader's HCI RX queue is shallow and hard-fails the transfer
        // (Response op=3 status=6 "Operation failed" + disconnect, seen on hardware 2026-07-23)
        // when data packets outrun it. Adafruit's own guidance: OTA needs PRN <= 8. The library
        // default is 12. Use 6 for headroom - each PRN is a flow-control stop that lets the
        // bootloader drain its queue to flash before the next burst.
        initiator.packetReceiptNotificationParameter = 6
        // Arm the stall watchdog: connect + service discovery + START + the bootloader's
        // erase-before-response all fit well inside 25s (the 123KB erase is 3-15s); .uploading
        // disarms it. On expiry: abort and retry from a fresh scan.
        armStartWatchdog()
        // Start with OUR central + the discovered peripheral (Bluefruit-parity path). With
        // start(targetWithIdentifier:) the library owns a private central, and a wedged START
        // leaves a connection nothing can cancel (controller.abort() is a link-layer no-op there,
        // and the retain cycle inside the DFU stack keeps its central alive after controller=nil).
        // Owning the central makes the stall recovery's disconnect explicit and guaranteed.
        controller = initiator.start()
    }

    private func armStartWatchdog() {
        startWatchdog?.cancel()
        let wd = DispatchWorkItem { [weak self] in self?.startStalled() }
        startWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: wd)
    }

    private func startStalled() {
        guard !finished else { return }
        retryCount += 1
        guard retryCount <= maxStartRetries else {
            fail(.dfu("The co-processor didn't acknowledge the update after several tries. Power-cycle the beacon and try again."))
            return
        }
        onLog("start phase stalled (no response in 25s); aborting and retrying (\(retryCount)/\(maxStartRetries))")
        intentionalAbort = true
        _ = controller?.abort()
        controller = nil
        // Explicit, guaranteed disconnect: we own the central, so cancel the wedged connection
        // directly (abort() alone is a link-layer no-op in the START phase, and a connected
        // bootloader never advertises, which would starve the rescan).
        if let central = scanCentral, let p = dfuPeripheral {
            central.cancelPeripheralConnection(p)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.finished else { return }
            self.onLog("rescanning for AdaDFU (retry \(self.retryCount))")
            self.dfuPeripheral = nil
            self.scanCentral?.delegate = self      // reclaim from the DFU library
            self.scanCentral?.scanForPeripherals(withServices: nil,
                                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            let to = DispatchWorkItem { [weak self] in self?.fail(.targetNotFound) }
            self.scanTimeout = to
            // Same 40s window as the initial scan: Android's retry path re-enters
            // scanForDfuTarget, which arms SCAN_TIMEOUT_MS on every scan, retries included.
            DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: to)
        }
    }

    private func teardownScan() {
        // Stop scanning + cancel the timeout, but KEEP the central: the DFU transfer runs on it,
        // and the stall recovery needs it to cancel the connection + rescan.
        scanTimeout?.cancel(); scanTimeout = nil
        scanCentral?.stopScan()
    }

    private func succeed() {
        guard !finished else { return }
        finished = true
        startWatchdog?.cancel(); startWatchdog = nil
        onFinish(.success(()))
    }

    private func fail(_ e: FlashError) {
        guard !finished else { return }
        finished = true
        startWatchdog?.cancel(); startWatchdog = nil
        teardownScan()
        onFinish(.failure(e))
    }
}

// MARK: - scanning for AdaDFU

extension NrfDfuFlasher: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, central === scanCentral else { return }
        // Scan WITHOUT a service filter and match by name below. The Adafruit/Seeed bootloader's
        // DFU service is a 128-bit UUID that iOS scan filters match unreliably (it can ride in the
        // scan response rather than the primary advert), so filtering on it silently drops the
        // target. The name "AdaDFU" is the reliable key.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanCentral != nil else { return }
        // Match by name (peripheral.name or the advertised local name), OR by the DFU service if
        // it happens to be in the advertisement. Either identifies our bootloader unambiguously.
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        let isDfu = (name?.caseInsensitiveCompare("AdaDFU") == .orderedSame)
            || (advServices?.contains(Self.dfuServiceUUID) ?? false)
        guard isDfu else { return }
        // Proximity gate: the UI tells the user to hold the phone next to the beacon, so a real
        // target is loud. Without this, ANY Adafruit/Seeed board in bootloader mode nearby (a
        // neighbor's Feather, a second bench unit) matches the name and would accept our wildcard
        // zip. 127 = RSSI unavailable.
        let rssi = RSSI.intValue
        guard rssi != 127, rssi > -70 else {
            onLog("ignoring far AdaDFU (rssi \(rssi))")
            return
        }
        beginDfu(peripheral: peripheral)
    }
}

// MARK: - DFU library callbacks

extension NrfDfuFlasher: DFUServiceDelegate {
    func dfuStateDidChange(to state: DFUState) {
        onLog("dfu: \(state.description)")
        switch state {
        case .uploading, .validating:
            // Past the START handshake: the stall window is over, stand the watchdog down.
            startWatchdog?.cancel(); startWatchdog = nil
        case .completed:
            succeed()
        case .aborted:
            // Our own stall-recovery abort lands here; the rescan is already scheduled.
            if intentionalAbort { intentionalAbort = false }
        default:
            break
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        // An error surfaced by our own stall-recovery abort isn't a failure; the retry owns the flow.
        if intentionalAbort { intentionalAbort = false; return }
        // Word-for-word the Android string for the same terminal library error, recovery
        // suffix included: every other user-facing string in this flow is already identical.
        fail(.dfu("The co-processor update failed: \(message). Reconnect and try again."))
    }
}

extension NrfDfuFlasher: DFUProgressDelegate {
    func dfuProgressDidChange(for part: Int, outOf totalParts: Int, to progress: Int,
                              currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double) {
        onProgress(max(0, min(100, progress)))
    }
}

// Verbose DFU-library logging, surfaced through onLog so a stalled transfer shows exactly which
// step (connecting / enabling DFU mode / sending init packet / uploading) it hangs on.
extension NrfDfuFlasher: LoggerDelegate {
    func logWith(_ level: LogLevel, message: String) {
        onLog("[\(level)] \(message)")
    }
}
