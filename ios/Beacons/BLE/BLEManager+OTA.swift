import Foundation
import CoreBluetooth
import CryptoKit
import zlib   // system module: crc32() for the standard zlib/PKZIP CRC-32 the board expects

// MARK: - OTA state exposed to the UI

/// The firmware-update state machine, as the Device screen sees it. One value at a time,
/// published on BLEManager.otaState.
enum OTAState: Equatable {
    case idle                       // nothing running
    case checking                   // gathering the image details / preparing
    case downloading(pct: Int)      // pulling the .bin over HTTPS
    case verifying                  // checking size + SHA-256, computing CRC-32
    case sending(pct: Int)          // streaming bytes to the board
    case rebooting                  // board is reflashing + restarting
    case confirming                 // reconnected, confirming + disarming rollback
    case done                       // new firmware is live and confirmed
    case failed(reason: String)     // gave up; reason is user-facing

    /// True while an update is actively running (used to disable other controls / show cancel).
    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default:                    return true
        }
    }
    /// Cancel only makes sense before the point of no return (the board reboot).
    var isCancellable: Bool {
        switch self {
        case .checking, .downloading, .verifying, .sending: return true
        default:                                            return false
        }
    }
}

/// Live state for one running OTA session. Lives on BLEManager.otaSession while active.
final class OTASession {
    let image: Data                 // the verified firmware bytes
    let crc32Hex: String            // lowercase hex, zlib CRC-32 of `image`
    let targetVersion: String       // the version we're flashing (for the begin cmd + post-reboot check)
    let fwLabel: String             // the board's fw label, so the reboot check reads the right entry
    let chunkSize: Int              // <= negotiated ATT MTU - 3

    var offset = 0                  // next byte to send
    var streaming = false           // a stream loop is currently draining writes
    var ended = false               // we've sent {"ota":{"end":true}} and are awaiting done/reboot
    var cancelled = false           // user asked to stop; send abort, don't retry
    var lastProgressAt = Date()     // last time the board moved (prog notify or a fresh chunk went out)

    init(image: Data, crc32Hex: String, targetVersion: String, fwLabel: String, chunkSize: Int) {
        self.image = image
        self.crc32Hex = crc32Hex
        self.targetVersion = targetVersion
        self.fwLabel = fwLabel
        self.chunkSize = chunkSize
    }
}

/// What we're waiting on after telling the board to reboot into new firmware.
struct OTARebootWait {
    let targetVersion: String
    let fwLabel: String
    let startedAt: Date
}

// MARK: - Errors surfaced to the user (no hype, plain language)

private enum OTAText {
    /// Map a board err code (from ota_update.cpp otaResultStr) to a plain explanation.
    static func forBoardError(_ code: String) -> String {
        switch code {
        case "busy":      return "The board is already in the middle of an update. Disconnect, wait a moment, and try again."
        case "not-newer": return "The board is already on this version or newer, so there's nothing to install."
        case "size":      return "The update didn't transfer completely. Check your connection and try again."
        case "begin":     return "The board doesn't have room for the update. This build may be too large for it."
        case "write":     return "The board couldn't write the update to flash. Try again."
        case "crc":        return "The update failed its integrity check. The download may be corrupt; try again."
        case "image":      return "The board rejected the update as invalid. Make sure this build is for your board."
        case "sig":        return "The board couldn't verify this update was signed by the beacon maker, so it refused to install it. Only official signed firmware can be installed over the air."
        case "stall":      return "The update stalled and the board cancelled it. Stay close to the beacon with the app open, and try again."
        case "state":      return "The update fell out of step with the board. Try again."
        default:           return "The board reported an error (\(code)). Try again."
        }
    }
}

// MARK: - The engine

extension BLEManager {

    // Hard limits so a slow link or a bad board can't hang the UI forever.
    private static let otaStallTimeout: TimeInterval = 20   // no board progress -> give up
    private static let otaRebootTimeout: TimeInterval = 90  // board never comes back -> report it
    private static let otaMaxChunk = 512                    // cap chunk size regardless of MTU
    /// How long the post-reboot version check waits for a FRESH status frame after the
    /// reconnect, re-reading every 1.5s, before deciding without one. A fresh boot on a
    /// congested link can take well over the old ~3s to land its first status; failing an
    /// update that applied over a slow read is worse than waiting. 30s on both platforms
    /// (Android bounds its own wait-for-status the same way).
    private static let otaPostRebootStatusWait: TimeInterval = 30

    /// Public entry point from the Device screen. Kicks off the whole flow for one manifest
    /// build entry. Non-throwing: any failure lands in `otaState = .failed(reason:)`.
    func startFirmwareUpdate(entry: FirmwareManifest.Build, fwLabel: String) {
        guard !otaState.isRunning else { return }
        guard otaLink != nil else {
            otaState = .failed(reason: "The board isn't connected. Reconnect and try again.")
            return
        }
        // entry.ota must be true AND the image verifiable. The Device screen already gates on
        // otaEligible, but the engine enforces it too (defense in depth): never start an update
        // for a build the manifest marked ota:false, even if a future caller reaches here directly.
        guard entry.ota, entry.hasVerifiableImage, let url = URL(string: entry.app.url), url.scheme == "https" else {
            otaState = .failed(reason: "This update isn't available to install over the air yet.")
            return
        }
        otaState = .checking
        let expectedSize = entry.app.size
        let expectedSha = entry.app.sha256.lowercased()
        // Image signature (lowercase hex DER). The gate already guarantees it's non-empty; we
        // hand it to the board on its own control message before begin so the board can verify.
        let imageSig = (entry.app.sig ?? "").lowercased()
        let targetVersion = entry.version

        otaDownloadTask = Task { [weak self] in
            await self?.runDownloadAndFlash(url: url, expectedSize: expectedSize,
                                            expectedSha: expectedSha, imageSig: imageSig,
                                            targetVersion: targetVersion, fwLabel: fwLabel)
        }
    }

    /// User tapped cancel. Before the reboot we can still back out cleanly: tell the board to
    /// abort and drop the session.
    func cancelFirmwareUpdate() {
        guard otaState.isCancellable else { return }
        // Stop the download/verify Task too. During .checking/.downloading/.verifying there is no
        // otaSession yet, so cancelling only the session would let runDownloadAndFlash run on and
        // hand off to beginTransfer, flashing the board despite the cancel.
        otaDownloadTask?.cancel()
        otaDownloadTask = nil
        otaSession?.cancelled = true
        otaStopStall()
        otaWriteControl(["abort": true])
        otaSession = nil
        otaState = .failed(reason: "Update cancelled.")
    }

    /// Clear a terminal state so the card goes back to its resting look.
    func dismissFirmwareUpdate() {
        guard !otaState.isRunning else { return }
        otaState = .idle
    }

    // MARK: Download + verify (off the BLE path, on a background Task)

    private func runDownloadAndFlash(url: URL, expectedSize: Int, expectedSha: String,
                                     imageSig: String, targetVersion: String, fwLabel: String) async {
        // 1. Download the .bin, reporting coarse progress. Stream with a hard byte ceiling so a
        // malicious or misconfigured server can't balloon RAM before the size check: cap at
        // min(declared size, 8 MiB), matching Android. The size/SHA/sig gates below still run on
        // whatever we accept, so a truncated or padded download is rejected there too.
        await MainActor.run { self.otaState = .downloading(pct: 0) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cap = min(expectedSize, 8 * 1024 * 1024)
        var data = Data()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await MainActor.run {
                    self.otaState = .failed(reason: "Couldn't download the update. Check your connection and try again.")
                }
                return
            }
            // Reject up front if the server advertises a body larger than the ceiling.
            if http.expectedContentLength > Int64(cap) {
                await MainActor.run {
                    self.otaState = .failed(reason: "The download was the wrong size, so it wasn't installed.")
                }
                return
            }
            if cap > 0 { data.reserveCapacity(cap) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > cap {
                    // Server kept sending past the ceiling; stop buffering and reject.
                    await MainActor.run {
                        self.otaState = .failed(reason: "The download was the wrong size, so it wasn't installed.")
                    }
                    return
                }
            }
        } catch {
            let cancelled = Task.isCancelled   // URLSession.bytes throws when the Task is cancelled
            await MainActor.run {
                self.otaDownloadTask = nil
                self.otaState = cancelled
                    ? .failed(reason: "Update cancelled.")
                    : .failed(reason: "Couldn't download the update. Check your connection and try again.")
            }
            return
        }

        // Freeze the accumulated bytes into an immutable value for the verify + handoff steps
        // (nothing mutates them past this point; a `let` also keeps the MainActor.run capture below
        // out of the "captured var in concurrent code" trap).
        let image = data

        // 2. Verify size + SHA-256 before we touch the board. Reject on any mismatch.
        await MainActor.run { self.otaState = .verifying }
        guard image.count == expectedSize else {
            await MainActor.run {
                self.otaState = .failed(reason: "The download was the wrong size, so it wasn't installed.")
            }
            return
        }
        let sha = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard sha == expectedSha else {
            await MainActor.run {
                self.otaState = .failed(reason: "The download failed its integrity check, so it wasn't installed.")
            }
            return
        }

        // 3. Compute the standard zlib CRC-32 the board will re-check the whole image against.
        let crcHex = Self.zlibCRC32Hex(image)

        // 4. Last chance to bail: if the user cancelled during download/verify, do NOT arm the board.
        if Task.isCancelled {
            await MainActor.run { self.otaDownloadTask = nil; self.otaState = .failed(reason: "Update cancelled.") }
            return
        }
        // Hand off to the BLE state machine on the main actor (all CoreBluetooth work).
        await MainActor.run {
            self.otaDownloadTask = nil
            self.beginTransfer(image: image, crc32Hex: crcHex, imageSig: imageSig,
                               targetVersion: targetVersion, fwLabel: fwLabel)
        }
    }

    /// Lowercase-hex zlib/PKZIP CRC-32 over the whole image (matches the board's crc32_update).
    private static func zlibCRC32Hex(_ data: Data) -> String {
        let crc = data.withUnsafeBytes { raw -> uLong in
            let base = raw.bindMemory(to: Bytef.self).baseAddress
            return crc32(uLong(0), base, uInt(data.count))
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: crc))
    }

    // MARK: BLE transfer

    private func beginTransfer(image: Data, crc32Hex: String, imageSig: String,
                               targetVersion: String, fwLabel: String) {
        guard let link = otaLink else {
            otaState = .failed(reason: "The board isn't connected. Reconnect and try again.")
            return
        }
        // Chunk = negotiated write-without-response MTU (already ATT MTU - 3), capped so a
        // large negotiated MTU can't hand the board oversized writes.
        let mtuChunk = link.peripheral.maximumWriteValueLength(for: .withoutResponse)
        let chunk = max(20, min(mtuChunk, Self.otaMaxChunk))

        let session = OTASession(image: image, crc32Hex: crc32Hex, targetVersion: targetVersion,
                                 fwLabel: fwLabel, chunkSize: chunk)
        otaSession = session
        otaState = .sending(pct: 0)

        // Send the image signature on its own control message first, so each JSON stays small.
        // The board holds it and verifies the signed digest in otaFinish before committing.
        otaWriteControl(["sig": imageSig])

        // Arm the session on the board. It answers with {"ota":"ready","size":N} on the OTA
        // char, which starts the stream; or {"ota":"err",...} which we surface.
        otaWriteControl([
            "begin": true,
            "size": image.count,
            "crc": crc32Hex,
            "ver": targetVersion,
            "force": false,
        ])
        otaStartStall()
    }

    /// Notify arriving on the OTA characteristic. Small JSON: ready / prog / done / abort /
    /// ok / err. Drives every board-side transition.
    func otaHandleNotify(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // The board sends the code as either {"ota":"ready", ...}. Read that string.
        let kind = obj["ota"] as? String

        switch kind {
        case "ready":
            // begin accepted: start streaming.
            guard let s = otaSession, !s.cancelled else { return }
            s.lastProgressAt = Date()
            otaResumeStreaming()

        case "prog":
            // Periodic progress from the board (~every 64 KB). Prefer the board's own pct.
            guard let s = otaSession, !s.cancelled else { return }
            s.lastProgressAt = Date()
            let pct = (obj["pct"] as? Int) ?? Int(Double(s.offset) / Double(max(1, s.image.count)) * 100)
            if !s.ended { otaState = .sending(pct: min(100, max(0, pct))) }

        case "done":
            // end accepted: the board is about to reboot (~250 ms). Wait for the disconnect.
            otaStopStall()
            guard let s = otaSession else { return }
            otaState = .rebooting
            otaAwaitingReboot = OTARebootWait(targetVersion: s.targetVersion,
                                              fwLabel: s.fwLabel, startedAt: Date())
            otaSession = nil
            armRebootTimeout()

        case "ok":
            // confirm accepted: rollback disarmed, new firmware is live.
            otaAwaitingReboot = nil
            otaState = .done

        case "abort":
            otaStopStall()
            // Ignore a late abort echo once we've already stopped (e.g. the user cancelled): don't
            // clobber the terminal state.
            guard otaSession != nil || otaState.isRunning else { break }
            otaSession = nil
            if otaState.isRunning { otaState = .failed(reason: "The update was stopped on the board.") }

        case "err":
            otaStopStall()
            // A cancel hands "abort" to the board, but chunks already in CoreBluetooth's buffer
            // keep flowing and draw per-chunk "err:state" replies. Once we've stopped (no session,
            // not mid-run), ignore them so a late error can't overwrite "Update cancelled."
            guard otaSession != nil || otaState.isRunning else { break }
            otaSession = nil
            let code = (obj["e"] as? String) ?? "unknown"
            otaState = .failed(reason: OTAText.forBoardError(code))

        default:
            break
        }
    }

    // MARK: Streaming with back-pressure

    /// Drain as many chunks as CoreBluetooth will take. Stops when the send buffer is full
    /// (peripheralIsReady(toSendWriteWithoutResponse:) resumes us) or the image is done.
    func otaResumeStreaming() {
        guard let s = otaSession, !s.cancelled, !s.ended, let link = otaLink else { return }
        if s.streaming { return }   // reentrancy guard: one drain loop at a time
        s.streaming = true
        defer { s.streaming = false }

        while s.offset < s.image.count {
            // Back-pressure: park once the send buffer fills; peripheralIsReady resumes us.
            // EXCEPTION: the very first chunk of the session goes unconditionally, because
            // canSendWriteWithoutResponse can report false before any write has ever been
            // attempted, and peripheralIsReady(toSendWriteWithoutResponse:) is only delivered
            // after a write, which would strand the stream before it starts.
            if s.offset > 0 && !link.peripheral.canSendWriteWithoutResponse { break }
            let end = min(s.offset + s.chunkSize, s.image.count)
            let chunk = s.image.subdata(in: s.offset..<end)
            link.peripheral.writeValue(chunk, for: link.char, type: .withoutResponse)
            s.offset = end
            s.lastProgressAt = Date()
        }

        // Reflect local send progress even before the next board prog notify.
        let pct = Int(Double(s.offset) / Double(max(1, s.image.count)) * 100)
        otaState = .sending(pct: min(99, max(0, pct)))   // hold 100 for the board's own confirmation

        if s.offset >= s.image.count {
            // All bytes handed to the link. Close the session; the board validates + reboots.
            s.ended = true
            otaWriteControl(["end": true])
            otaState = .sending(pct: 100)
            // Keep the stall watchdog running until we hear "done" / "err".
        }
    }

    // MARK: Reboot -> reconnect -> confirm

    /// Called from didDisconnectPeripheral. Returns true if this disconnect was an EXPECTED
    /// OTA reboot (so the caller skips its normal teardown) and starts the reconnect.
    func otaHandleDisconnect(_ peripheral: CBPeripheral) -> Bool {
        // A user tapped Disconnect during the reboot/confirm window: this is an intentional teardown,
        // not an OTA reboot to reconnect through. Tear the OTA session down here (stop the stall timer,
        // drop the reboot wait and session so the armed reboot/confirm/backstop closures all no-op via
        // their otaAwaitingReboot?.targetVersion guard) and do NOT re-arm a reconnect the user asked to
        // stop. Return false so didDisconnectPeripheral's userDisconnect branch runs and consumes the
        // flag; leaving it set would defeat the next unexpected-drop auto-reconnect, and returning true
        // would strand the flow on a reconnect the user cancelled. The caller also fixes connectionState.
        if userDisconnect {
            otaStopStall()
            otaAwaitingReboot = nil
            otaSession = nil
            otaState = .idle
            return false
        }
        guard otaAwaitingReboot != nil else {
            if let s = otaSession, !s.cancelled {
                otaStopStall()
                if s.ended {
                    // We already sent "end" and the board dropped before (or instead of) its
                    // "done" notify , that single notify can be lost, or the reboot can race
                    // ahead of it. The board most likely committed the image and rebooted, so
                    // treat this as a PROBABLE SUCCESS: enter the reboot/confirm path and let the
                    // post-reboot version check decide, rather than falsely reporting failure on
                    // an update that actually took.
                    otaAwaitingReboot = OTARebootWait(targetVersion: s.targetVersion,
                                                      fwLabel: s.fwLabel, startedAt: Date())
                    otaSession = nil
                    otaState = .confirming
                    armRebootTimeout()   // else a board that never comes back pins on 'confirming' forever
                    otaReconnectPeripheral()
                    return true
                }
                // Dropped mid-stream, before "end": nothing was committed. Retryable failure.
                otaSession = nil
                otaState = .failed(reason: "Lost the connection to the board during the update. It's still on the firmware it had, so it's safe. Reconnect and try again.")
            }
            return false
        }
        // Expected reboot: hold the peripheral and reconnect on the same bond.
        otaState = .confirming
        otaReconnectPeripheral()
        return true
    }

    /// Called from the connected-completion path once chars are up again. If we were waiting
    /// on an OTA reboot, wait for a FRESH status frame and then confirm (or report a rollback).
    func otaHandleReconnected() {
        guard otaAwaitingReboot != nil else { return }
        // Decide on a frame from THIS link only. The OTA reboot disconnect deliberately skips
        // the normal teardown, so `status` (and currentFwVersion) still hold the PRE-reboot
        // values here; judging those would read a successful update as "came back on its
        // previous firmware". Clear the fresh-frame flag, nudge a read, and poll below.
        otaSawFreshStatus = false
        otaRereadStatus()
        otaAwaitRebootStatus(deadline: Date().addingTimeInterval(Self.otaPostRebootStatusWait))
    }

    /// Re-check every 1.5s until a fresh status frame lands or `deadline` passes, then decide.
    /// The regular 5s status poll is held while otaState.isRunning, so this loop's re-reads are
    /// the only thing feeding the check; without them a single lost notify would run out the
    /// whole wait.
    private func otaAwaitRebootStatus(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let wait = self.otaAwaitingReboot else { return }
            if self.otaSawFreshStatus || Date() >= deadline {
                self.decideRebootOutcome(wait)
            } else {
                self.otaRereadStatus()   // keep nudging: small MTUs can drop the notify path entirely
                self.otaAwaitRebootStatus(deadline: deadline)
            }
        }
    }

    /// True for a plain dotted-numeric version like "2", "1.7", "2.0.0" (optionally a trailing
    /// "-suffix"). Rejects a non-numeric fw string before a version compare, so a degraded
    /// lexical compare can't falsely confirm success and disarm rollback.
    private static func isNumericVersion(_ s: String) -> Bool {
        let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
        guard !core.isEmpty else { return false }
        return core.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private func decideRebootOutcome(_ wait: OTARebootWait) {
        guard otaAwaitingReboot?.targetVersion == wait.targetVersion else { return }
        // Only a frame received AFTER the reconnect may decide (see otaHandleReconnected). If
        // none landed inside the wait cap, fall through to the didn't-report outcome below
        // rather than judging the stale pre-reboot version still sitting in `status`.
        let running = otaSawFreshStatus ? (currentFwVersion ?? "") : ""
        // Confirm only on a PARSEABLE a.b[.c] version that is >= the target. A non-numeric string
        // (e.g. a fallback "ESP32") must not disarm rollback via a degraded lexical compare.
        let parseable = Self.isNumericVersion(running)
        let ok = parseable && running.compare(wait.targetVersion, options: .numeric) != .orderedAscending
        if ok {
            // New firmware booted. Confirm to disarm the board's rollback (belt-and-braces:
            // the board also self-heals ~20 s after a healthy boot).
            otaState = .confirming
            otaWriteControl(["confirm": true])
            // The board answers {"ota":"ok"} -> .done. Backstop in case that notify is missed:
            let target = wait.targetVersion
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.otaAwaitingReboot?.targetVersion == target else { return }
                self.otaAwaitingReboot = nil
                if case .confirming = self.otaState { self.otaState = .done }
            }
        } else {
            otaAwaitingReboot = nil
            if parseable {
                // Came back on the OLD (or a lower) version: the flashed image never reached a
                // healthy boot, so it reverted. Safe on its prior firmware.
                otaState = .failed(reason: "The board came back on its previous firmware, so it stayed safe. The update didn't take; try again.")
            } else {
                // Came back but didn't report a version we can trust; leave rollback armed.
                otaState = .failed(reason: "The board came back but didn't report the new version, so rollback was left armed for safety. Reconnect to check its firmware.")
            }
        }
    }

    private func armRebootTimeout() {
        let target = otaAwaitingReboot?.targetVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.otaRebootTimeout) { [weak self] in
            guard let self, let w = self.otaAwaitingReboot, w.targetVersion == target else { return }
            // Never came back. Surface a clear failure rather than spinning forever.
            self.otaAwaitingReboot = nil
            self.otaState = .failed(reason: "The board didn't come back after the update. Power-cycle it and check its firmware; if the new image won't boot it usually recovers to the previous version, and if not you can re-flash it over USB.")
        }
    }

    // MARK: Stall watchdog

    /// Arm a timer that fails the transfer if the board goes silent (no prog notify AND no
    /// fresh chunk went out) for too long. Re-checks periodically.
    func otaStartStall() {
        otaStopStall()
        otaStallTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let s = self.otaSession, !s.cancelled else { return }
            if Date().timeIntervalSince(s.lastProgressAt) > Self.otaStallTimeout {
                self.otaStopStall()
                self.otaSession = nil
                self.otaWriteControl(["abort": true])   // best-effort: tell the board to drop it
                self.otaState = .failed(reason: "The update stalled with no progress from the board. Keep the phone next to it and try again.")
            }
        }
    }

    func otaStopStall() {
        otaStallTimer?.invalidate()
        otaStallTimer = nil
    }
}
