package tech.acab.app.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import no.nordicsemi.android.dfu.DfuBaseService
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper
import tech.acab.app.model.DeviceStatus
import tech.acab.app.net.FirmwareBuild
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.UUID

enum class NrfDfuPhase { IDLE, PREPARING, TRIGGERING, SCANNING, FLASHING, CONFIRMING, DONE, FAILED }

data class NrfDfuProgress(
    val phase: NrfDfuPhase = NrfDfuPhase.IDLE,
    val pct: Int = 0,
    val message: String = "",
) {
    val isRunning: Boolean get() = phase != NrfDfuPhase.IDLE && phase != NrfDfuPhase.DONE && phase != NrfDfuPhase.FAILED
}

/**
 * Drives one nRF co-processor DFU over BLE, self-contained so AcabBleManager only wires it in.
 *
 * Flow: download + verify the package (sha256 AND the app-side ECDSA signature, since the nRF's
 * stock bootloader can't verify our sig), tell the S3 to relay the DFU trigger, scan for the
 * bootloader's "AdaDFU" advertiser, hand it to Nordic's DfuServiceInitiator (legacy DFU), then
 * watch the S3's reported nrfv for the new version. The S3 link (AcabBleManager's own GATT) stays
 * up the whole time; the DFU library talks to AdaDFU over a separate connection.
 */
class NrfDfuCoordinator(
    private val context: Context,
    private val adapter: BluetoothAdapter?,
    private val scope: CoroutineScope,
    private val sendTrigger: () -> Unit,           // writeConfig {"nrfdfu": true}
    private val statusProvider: () -> DeviceStatus?, // for the post-flash version confirm
    private val otaInProgress: () -> Boolean,      // true while an S3 OTA is live (never overlap)
) {
    private val _progress = MutableStateFlow(NrfDfuProgress())
    val progress: StateFlow<NrfDfuProgress> = _progress.asStateFlow()

    private var job: Job? = null
    private var scanCb: ScanCallback? = null
    private var confirmTarget: Int = 0
    private val main = Handler(Looper.getMainLooper())

    // START-phase stall recovery, mirroring the iOS NrfDfuFlasher winning stack (proven on
    // hardware 2026-07-23). Two field-confirmed failure modes wedge the legacy START handshake
    // indefinitely: the image-size write dropped under radio congestion, and the Adafruit
    // bootloader stalling in its erase-before-response window. Both recover on a fresh attempt, so
    // we watchdog the window between start() and the first upload progress and, on expiry, abort +
    // rescan + retry, bounded.
    private var dfuController: no.nordicsemi.android.dfu.DfuServiceController? = null
    private var pendingZip: File? = null
    private var retryCount = 0
    private var intentionalAbort = false   // our own stall-recovery abort must not read as failure
    private var pastStart = false          // true once upload progress begins (watchdog disarm)
    private var listenerRegistered = false
    private var settleRunnable: Runnable? = null
    private var watchdogRunnable: Runnable? = null
    private var scanTimeoutRunnable: Runnable? = null

    companion object {
        // Legacy Nordic DFU service, advertised by the Adafruit/Seeed bootloader in OTA mode.
        private val DFU_SERVICE = UUID.fromString("00001530-1212-EFDE-1523-785FEABCD123")
        private const val SCAN_TIMEOUT_MS = 40_000L
        // Let the Adafruit HCI queue drain after AdaDFU appears, before we open the transfer.
        private const val SETTLE_MS = 3_000L
        // connect + service discovery + START + the bootloader's erase-before-response all fit well
        // inside this; the first upload-progress callback disarms it.
        private const val START_WATCHDOG_MS = 25_000L
        private const val RETRY_BACKOFF_MS = 2_000L
        private const val MAX_START_RETRIES = 3
        // Proximity gate: the UI tells the user to hold the phone next to the beacon, so a real
        // target is loud. Reject weaker advertisers so a wildcard-signed zip can't flash a
        // neighbor board that happens to be in bootloader mode. 127 = RSSI unavailable.
        private const val MIN_RSSI = -70
        // The stock Adafruit/Seeed bootloader HARD-FAILS the transfer (Response op=3 status=6
        // "Operation failed" + disconnect, seen on hardware 2026-07-23) when data packets outrun
        // its shallow HCI RX queue. Adafruit's guidance: OTA needs PRN <= 8; the library default is
        // 12. 6 gives headroom - each PRN is a flow-control stop that lets it drain to flash.
        private const val PRN = 6
    }

    /** True when a co-processor update is available for this build vs the running version. */
    fun updateAvailable(build: FirmwareBuild): Boolean {
        val nrf = build.nrf ?: return false
        val running = statusProvider()?.nrfVersion ?: return false
        return nrf.hasVerifiableImage && nrf.version > running
    }

    fun startUpdate(build: FirmwareBuild) {
        if (_progress.value.isRunning) return
        // Never overlap an S3 OTA: both flows drive the same radio, and a co-processor DFU started
        // mid-OTA would fight the S3 image stream. Parity with iOS BLEManager+NrfDFU.swift:39.
        if (otaInProgress()) {
            set(NrfDfuPhase.FAILED, 0, "Finish the board update first, then update the co-processor.")
            return
        }
        val nrf = build.nrf
        if (nrf == null || !nrf.hasVerifiableImage) {
            set(NrfDfuPhase.FAILED, 0, "No verified co-processor update is published for this board yet.")
            return
        }
        confirmTarget = nrf.version
        retryCount = 0
        intentionalAbort = false
        pastStart = false
        DfuServiceInitiator.createDfuNotificationChannel(context)

        job = scope.launch {
            set(NrfDfuPhase.PREPARING, 0, "Preparing update…")
            val zipFile = try {
                withContext(Dispatchers.IO) { downloadAndVerify(nrf.zipUrl, nrf.size, nrf.sha256, nrf.sig) }
            } catch (e: CancellationException) {
                // cancel() already owns the state ("Co-processor update cancelled."). The blocking
                // HTTP read isn't interruptible, so this zombie resume can land seconds later; it
                // must not clobber the cancelled copy - or a restarted run's fresh state. Parity
                // with iOS BLEManager+NrfDFU's dedicated CancellationError catch.
                throw e
            } catch (e: Exception) {
                set(NrfDfuPhase.FAILED, 0, (e as? PrepError)?.msg
                    ?: "Couldn't download the co-processor update. Check your connection and try again.")
                return@launch
            }
            // Trigger the nRF into its bootloader, then look for AdaDFU.
            set(NrfDfuPhase.TRIGGERING, 0, "Starting co-processor update mode…")
            main.post { sendTrigger() }
            scanForDfuTarget(zipFile)
        }
    }

    fun cancel() {
        job?.cancel(); job = null
        stopScan()
        clearPendingCallbacks()
        if (_progress.value.phase == NrfDfuPhase.FLASHING) {
            intentionalAbort = true   // swallow the async onDfuAborted so it can't clobber our copy
            sendAbortBroadcast()
        }
        unregisterDfuListener()
        if (_progress.value.isRunning) set(NrfDfuPhase.FAILED, 0, "Co-processor update cancelled.")
    }

    fun dismiss() {
        if (!_progress.value.isRunning) set(NrfDfuPhase.IDLE, 0, "")
    }

    // ---- steps ----

    private class PrepError(val msg: String) : Exception(msg)

    private fun downloadAndVerify(url: String, expectedSize: Long, expectedSha: String, sigHex: String): File {
        val parsed = URL(url)
        if (!parsed.protocol.equals("https", ignoreCase = true)) throw PrepError("Update URL must be https.")
        val conn = (parsed.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"; connectTimeout = 15_000; readTimeout = 20_000
        }
        val bytes = try {
            if (conn.responseCode != HttpURLConnection.HTTP_OK)
                throw PrepError("Couldn't download the co-processor update. Check your connection and try again.")
            val cap = expectedSize.coerceIn(1L, 4L * 1024 * 1024) + 4096
            val out = java.io.ByteArrayOutputStream(cap.toInt())
            conn.inputStream.use { input ->
                val tmp = ByteArray(16 * 1024); var total = 0L
                while (true) {
                    val r = input.read(tmp); if (r < 0) break
                    total += r
                    if (total > cap) throw PrepError("The co-processor update was the wrong size, so it wasn't installed.")
                    out.write(tmp, 0, r)
                }
            }
            out.toByteArray()
        } finally { conn.disconnect() }

        if (bytes.size.toLong() != expectedSize)
            throw PrepError("The co-processor update was the wrong size, so it wasn't installed.")
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (!sha.equals(expectedSha, ignoreCase = true))
            throw PrepError("The co-processor update failed its integrity check, so it wasn't installed.")
        // App-side signature gate: the ONLY gate for the nRF (its bootloader can't verify our sig).
        if (!NrfDfuSignature.isValid(bytes, sigHex))
            throw PrepError("The co-processor update couldn't be verified as signed by the beacon maker, so it wasn't installed.")

        val f = File(context.cacheDir, "beacon-nrf-dfu.zip")
        f.writeBytes(bytes)
        return f
    }

    @SuppressLint("MissingPermission")
    private fun scanForDfuTarget(zipFile: File) {
        pendingZip = zipFile
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) { set(NrfDfuPhase.FAILED, 0, "Bluetooth is off."); return }
        set(NrfDfuPhase.SCANNING, 0, "Looking for the co-processor in update mode…")

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                // Once-guard: the scan is unfiltered LOW_LATENCY against a ~100ms advertiser, so
                // duplicate results can already be queued on the main looper when the winning
                // match calls stopScan(). Without this, a queued duplicate overwrites the settle
                // runnable and posts a SECOND beginDfu (FLASHING passes the isRunning check),
                // enqueuing a doomed second transfer into the DfuBaseService queue. Drop anything
                // from a callback that is no longer the active scan.
                if (scanCb !== this) return
                val addr = result.device?.address ?: return
                // Match by name OR the advertised DFU service. The bootloader's DFU service is a
                // 128-bit UUID that can ride in the scan response, which a hardware ScanFilter
                // matches unreliably; the name "AdaDFU" is the reliable key. We scan unfiltered and
                // decide here.
                val name = runCatching { result.device?.name }.getOrNull()
                    ?: result.scanRecord?.deviceName
                val hasService = result.scanRecord?.serviceUuids?.any { it.uuid == DFU_SERVICE } == true
                if (name?.equals("AdaDFU", ignoreCase = true) != true && !hasService) return
                // Proximity gate (iOS parity: guard rssi != 127, rssi > -70). Without it ANY
                // Adafruit/Seeed board in bootloader mode nearby matches the name and would accept
                // our wildcard zip. 127 = RSSI unavailable.
                val rssi = result.rssi
                if (rssi == 127 || rssi <= MIN_RSSI) {
                    set(NrfDfuPhase.SCANNING, 0, "A co-processor is in update mode but too far. Hold the phone closer.")
                    return
                }
                stopScan()
                clearScanTimeout()
                // Settle before opening the transfer: lets the Adafruit HCI queue drain so the
                // START-phase image-size write isn't silently discarded under radio congestion.
                set(NrfDfuPhase.SCANNING, 0, "Found the co-processor; settling…")
                val r = Runnable { beginDfu(addr, zipFile) }
                settleRunnable = r
                main.postDelayed(r, SETTLE_MS)
            }
        }
        scanCb = cb
        // No hardware filter; match in the callback (see above).
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { scanner.startScan(null, settings, cb) }
            .onFailure { set(NrfDfuPhase.FAILED, 0, "Couldn't start the update scan."); return }

        clearScanTimeout()
        val to = Runnable {
            if (_progress.value.phase == NrfDfuPhase.SCANNING) {
                stopScan()
                set(NrfDfuPhase.FAILED, 0,
                    "The co-processor didn't show up in update mode. It usually recovers on its own; reconnect and try again.")
            }
        }
        scanTimeoutRunnable = to
        main.postDelayed(to, SCAN_TIMEOUT_MS)
    }

    private fun clearScanTimeout() {
        scanTimeoutRunnable?.let { main.removeCallbacks(it) }
        scanTimeoutRunnable = null
    }

    private fun clearPendingCallbacks() {
        settleRunnable?.let { main.removeCallbacks(it) }; settleRunnable = null
        watchdogRunnable?.let { main.removeCallbacks(it) }; watchdogRunnable = null
        clearScanTimeout()
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        val cb = scanCb ?: return
        scanCb = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(cb) }
    }

    private fun beginDfu(address: String, zipFile: File) {
        if (!_progress.value.isRunning) return
        settleRunnable = null
        registerDfuListener()
        pastStart = false
        set(NrfDfuPhase.FLASHING, 0, "Sending to co-processor…")
        dfuController = DfuServiceInitiator(address)
            .setDeviceName("AdaDFU")
            .setKeepBond(false)
            .setForceDfu(false)
            // We connect straight to the bootloader (AdaDFU), so there's no buttonless jump and no
            // address change to chase.
            .setForceScanningForNewAddressInLegacyDfu(false)
            .setPacketsReceiptNotificationsEnabled(true)
            .setPacketsReceiptNotificationsValue(PRN)
            .setZip(zipFile.absolutePath)
            .start(context, NrfDfuService::class.java)
        armStartWatchdog()
    }

    // ---- START-phase stall recovery (iOS NrfDfuFlasher parity) ----

    private fun armStartWatchdog() {
        watchdogRunnable?.let { main.removeCallbacks(it) }
        val r = Runnable { startStalled() }
        watchdogRunnable = r
        main.postDelayed(r, START_WATCHDOG_MS)
    }

    private fun startStalled() {
        // Only fires if upload never began (pastStart disarms it). A terminal phase means we lost
        // the race with a real callback; nothing to do.
        if (pastStart || _progress.value.phase != NrfDfuPhase.FLASHING) return
        retryCount += 1
        if (retryCount > MAX_START_RETRIES) {
            intentionalAbort = true          // swallow the resulting onDfuAborted
            sendAbortBroadcast()
            unregisterDfuListener()
            set(NrfDfuPhase.FAILED, 0,
                "The co-processor didn't acknowledge the update after several tries. Power-cycle the beacon and try again.")
            return
        }
        // Abort the wedged transfer, then rescan for AdaDFU and retry from a fresh connection. The
        // abort's onDfuAborted is swallowed (intentionalAbort); the retry owns the flow.
        set(NrfDfuPhase.SCANNING, 0, "No response from the co-processor; retrying ($retryCount/$MAX_START_RETRIES)…")
        intentionalAbort = true
        sendAbortBroadcast()
        val zip = pendingZip
        main.postDelayed({
            if (!_progress.value.isRunning) return@postDelayed
            if (zip == null) { set(NrfDfuPhase.FAILED, 0, "The co-processor update failed. Reconnect and try again."); return@postDelayed }
            scanForDfuTarget(zip)
        }, RETRY_BACKOFF_MS)
    }

    private fun sendAbortBroadcast() {
        // The running DfuBaseService is aborted through its documented local-broadcast channel.
        val i = Intent(DfuBaseService.BROADCAST_ACTION)
            .putExtra(DfuBaseService.EXTRA_ACTION, DfuBaseService.ACTION_ABORT)
        LocalBroadcastManager.getInstance(context).sendBroadcast(i)
        runCatching { dfuController?.abort() }
        dfuController = null
    }

    private fun registerDfuListener() {
        if (listenerRegistered) return
        DfuServiceListenerHelper.registerProgressListener(context, dfuListener)
        listenerRegistered = true
    }

    private fun unregisterDfuListener() {
        if (!listenerRegistered) return
        DfuServiceListenerHelper.unregisterProgressListener(context, dfuListener)
        listenerRegistered = false
    }

    private val dfuListener = object : DfuProgressListenerAdapter() {
        override fun onDfuProcessStarted(deviceAddress: String) {
            // Upload is underway: past the START handshake, stand the watchdog down.
            disarmStartWatchdog()
        }
        override fun onProgressChanged(deviceAddress: String, percent: Int, speed: Float,
                                       avgSpeed: Float, currentPart: Int, partsTotal: Int) {
            disarmStartWatchdog()
            set(NrfDfuPhase.FLASHING, percent.coerceIn(0, 100), "Sending to co-processor…")
        }
        override fun onDfuCompleted(deviceAddress: String) {
            unregisterDfuListener()
            clearPendingCallbacks()
            dfuController = null
            startConfirm()
        }
        override fun onDfuAborted(deviceAddress: String) {
            // Our own stall-recovery abort lands here; the rescan/retry (or the terminal fail) owns
            // the flow, so don't clobber it.
            if (intentionalAbort) { intentionalAbort = false; return }
            unregisterDfuListener()
            clearPendingCallbacks()
            set(NrfDfuPhase.FAILED, 0, "The co-processor update was stopped.")
        }
        override fun onError(deviceAddress: String, error: Int, errorType: Int, message: String?) {
            // An error surfaced by our own abort isn't a failure; the retry owns the flow.
            if (intentionalAbort) { intentionalAbort = false; return }
            unregisterDfuListener()
            clearPendingCallbacks()
            set(NrfDfuPhase.FAILED, 0, "The co-processor update failed: ${message ?: "error $error"}. Reconnect and try again.")
        }
    }

    private fun disarmStartWatchdog() {
        if (pastStart) return
        pastStart = true
        watchdogRunnable?.let { main.removeCallbacks(it) }
        watchdogRunnable = null
    }

    /** After the flash, the nRF reboots into the new app and reports its version to the S3 over
     *  UART (emitted as nrfv). We're still linked to the S3, so watch status for the target. If it
     *  never arrives, the flash still succeeded, so resolve to DONE rather than crying failure. */
    private fun startConfirm() {
        set(NrfDfuPhase.CONFIRMING, 100, "Confirming update…")
        val deadline = System.currentTimeMillis() + 60_000
        fun tick() {
            if (_progress.value.phase != NrfDfuPhase.CONFIRMING) return
            val v = statusProvider()?.nrfVersion
            if (v != null && v >= confirmTarget) { set(NrfDfuPhase.DONE, 100, "Co-processor updated."); return }
            if (System.currentTimeMillis() >= deadline) { set(NrfDfuPhase.DONE, 100, "Co-processor updated."); return }
            main.postDelayed({ tick() }, 1_000)
        }
        tick()
    }

    private fun set(phase: NrfDfuPhase, pct: Int, message: String) {
        _progress.value = NrfDfuProgress(phase, pct, message)
    }
}
