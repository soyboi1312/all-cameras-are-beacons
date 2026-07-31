import Foundation
import CoreBluetooth
import CryptoKit

/// UI-facing state of a co-processor (nRF) DFU. Parallel to OTAState but a separate flow: the S3
/// stays connected the whole time, only the nRF reboots into its bootloader and is flashed over a
/// second, throwaway BLE link (NrfDfuFlasher).
enum NrfDfuState: Equatable {
    case idle
    case preparing              // downloading + verifying the package
    case triggering             // told the S3 to relay DFU; waiting for the nRF to enter it
    case flashing(pct: Int)     // Nordic DFU is streaming to AdaDFU
    case confirming             // nRF rebooted; waiting for the S3 to report the new version
    case done
    case failed(reason: String)

    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
}

extension BLEManager {
    /// Whether a co-processor update is available: the board reports its running nRF version,
    /// the manifest carries a NEWER, verifiable nRF package, and we're linked to a board that
    /// actually has a co-processor. Nil `nrfVersion` (single-radio boards) => never.
    func nrfUpdateAvailable(_ entry: FirmwareManifest.Build) -> Bool {
        guard let running = status?.nrfVersion, let nrf = entry.nrf,
              entry.hasVerifiableNrfImage else { return false }
        return nrf.version > running
    }

    /// Kick off a co-processor DFU for the given manifest build. Download + verify the package,
    /// trigger the nRF into its bootloader, then flash it over BLE and confirm the new version.
    func startNrfUpdate(entry: FirmwareManifest.Build) {
        guard case .idle = nrfDfuState else { return }          // one at a time
        guard !otaState.isRunning else {                         // never overlap an S3 OTA
            nrfDfuState = .failed(reason: "Finish the board update first, then update the co-processor.")
            return
        }
        // https only, same gate as the S3 OTA path and Android's coordinator: this is the one
        // image whose ONLY signature check is the app (the nRF bootloader flashes whatever it
        // is handed), so a manifest edit must not be able to point it at http or file:.
        guard let nrf = entry.nrf, entry.hasVerifiableNrfImage,
              let url = URL(string: nrf.url), url.scheme == "https" else {
            nrfDfuState = .failed(reason: "No verified co-processor update is published for this board yet.")
            return
        }
        nrfConfirmTarget = nrf.version
        nrfDfuState = .preparing

        nrfDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await self.downloadNrfZip(url: url, expectedSize: nrf.size,
                                                        expectedSha: nrf.sha256.lowercased(),
                                                        sigHexDER: (nrf.sig ?? "").lowercased())
                if Task.isCancelled { return }
                // Stage to a temp file; DFUFirmware reads the zip from disk.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("beacon-nrf-dfu-\(nrf.version).zip")
                try zip.write(to: tmp, options: .atomic)
                await MainActor.run { self.beginNrfFlash(zipURL: tmp) }
            } catch is CancellationError {
                return
            } catch let e as NrfPrepError {
                await MainActor.run { self.nrfDfuState = .failed(reason: e.message) }
            } catch {
                await MainActor.run {
                    self.nrfDfuState = .failed(reason: "Couldn't download the co-processor update. Check your connection and try again.")
                }
            }
        }
    }

    /// User-cancel. Stops the download or aborts the transfer, whichever is live.
    func cancelNrfUpdate() {
        nrfDownloadTask?.cancel(); nrfDownloadTask = nil
        if let f = nrfFlasher { f.cancel(); return }   // cancel() drives the failed state
        if nrfDfuState.isRunning { nrfDfuState = .failed(reason: "Co-processor update cancelled.") }
        nrfCleanup()
    }

    /// Clear a finished flow back to idle (dismiss the sheet).
    func dismissNrfUpdate() {
        guard !nrfDfuState.isRunning else { return }
        nrfDfuState = .idle
        nrfConfirmTarget = nil
    }

    // MARK: - steps

    private struct NrfPrepError: Error { let message: String }

    private func downloadNrfZip(url: URL, expectedSize: Int, expectedSha: String,
                                sigHexDER: String) async throws -> Data {
        await MainActor.run { self.nrfDfuState = .preparing }
        // Cap the accepted body the same way the S3 OTA does, so a bad URL can't stream forever.
        let cap = min(max(expectedSize, 0), 4 * 1024 * 1024) + 4096
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NrfPrepError(message: "Couldn't download the co-processor update. Check your connection and try again.")
        }
        var data = Data(); data.reserveCapacity(expectedSize)
        for try await b in bytes {
            data.append(b)
            if data.count > cap {
                throw NrfPrepError(message: "The co-processor update was the wrong size, so it wasn't installed.")
            }
        }
        guard data.count == expectedSize else {
            throw NrfPrepError(message: "The co-processor update was the wrong size, so it wasn't installed.")
        }
        let sha = SHA256Hex(data)
        guard sha == expectedSha else {
            throw NrfPrepError(message: "The co-processor update failed its integrity check, so it wasn't installed.")
        }
        // App-side signature gate. Unlike the S3, the nRF bootloader can't verify our signature,
        // so this IS the gate: refuse to hand an unsigned/tampered package to a bootloader that
        // would flash it blindly.
        guard NrfDfuSignature.isValid(zip: data, sigHexDER: sigHexDER) else {
            throw NrfPrepError(message: "The co-processor update couldn't be verified as signed by the beacon maker, so it wasn't installed.")
        }
        return data
    }

    private func beginNrfFlash(zipURL: URL) {
        // A cancel can land after the download task's last isCancelled check; without this guard
        // it would clobber the .failed state, send the trigger, and flash a cancelled update.
        guard case .preparing = nrfDfuState else { return }
        // Tell the S3 to put the nRF into DFU, then flash. The AdaDFU advertiser appears a moment
        // after the trigger; the flasher scans for it with its own timeout.
        nrfDfuState = .triggering
        nrfSendDfuTrigger()

        let flasher = NrfDfuFlasher(
            zipURL: zipURL,
            onProgress: { [weak self] pct in
                Task { @MainActor in self?.nrfDfuState = .flashing(pct: pct) }
            },
            onLog: { print("[nrfdfu] \($0)") },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.nrfDfuState = .confirming
                        self.startNrfConfirm()
                    case .failure(let e):
                        self.nrfDfuState = .failed(reason: (e as? LocalizedError)?.errorDescription
                                                   ?? "The co-processor update failed. Reconnect and try again.")
                        self.nrfCleanup()
                    }
                }
            })
        nrfFlasher = flasher
        flasher.start()
    }

    /// After the flash, the nRF reboots into the new app and reports its version to the S3 over
    /// UART; the S3 emits it as `nrfv`. We're still connected to the S3, so just watch status for
    /// the target version. Best-effort: if it never arrives (e.g. the S3's nrfv is slow), the
    /// flash still succeeded, so we resolve to done after a bounded wait rather than fail.
    private func startNrfConfirm() {
        let target = nrfConfirmTarget ?? 0
        let deadline = Date().addingTimeInterval(60)
        func tick() {
            guard case .confirming = nrfDfuState else { return }
            if let v = status?.nrfVersion, v >= target {
                nrfDfuState = .done; nrfCleanup(); return
            }
            if Date() >= deadline {
                // Transfer completed; version just hasn't been re-reported. Don't cry failure.
                nrfDfuState = .done; nrfCleanup(); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tick() }
        }
        tick()
    }

    private func nrfCleanup() {
        nrfFlasher = nil
        nrfDownloadTask = nil
    }
}

/// Lowercase hex SHA-256, local so this flow doesn't depend on the OTA extension's private helper.
private func SHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
