package tech.acab.app.ble

import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import tech.acab.app.model.DeviceStatus
import tech.acab.app.net.FirmwareBuild

/** The combined one-click flow as the Device screen sees it. Mirrors the iOS
 *  CombinedUpdatePhase state machine (BLEManager+CombinedUpdate.swift). */
enum class CombinedUpdatePhase {
    IDLE,
    CHECKING,          // deciding which legs to run
    UPDATING_S3,       // the S3 application-firmware OTA is streaming
    RECONNECTING,      // board rebooting after S3, and/or waiting for nrfv to repopulate
    UPDATING_COPROC,   // the nRF DFU is streaming
    VERIFYING,         // nRF flashed; confirming the new version
    DONE,              // everything current
    FAILED,            // the flow stopped (see [CombinedUpdateProgress.reason])
    PARTIAL,           // S3 took but the co-processor leg didn't finish (re-offer the nRF leg)
}

/** One value at a time on [CombinedUpdateCoordinator.progress]: the phase, a merged 0..1 bar, a
 *  plain-language label, elapsed seconds, plus a soft [notice] (done/partial) and a failure
 *  [reason]. Collected by the Device screen's FirmwareCard. */
data class CombinedUpdateProgress(
    val phase: CombinedUpdatePhase = CombinedUpdatePhase.IDLE,
    val progress: Float = 0f,        // overall 0f..1f
    val label: String = "",          // plain-language phase label
    val elapsedSeconds: Int = 0,
    val notice: String? = null,      // soft note shown on DONE / PARTIAL (e.g. S3-only)
    val reason: String? = null,      // user-facing failure reason on FAILED
) {
    /** True while the flow is actively working (drives banner suppression + the progress UI). */
    val isRunning: Boolean
        get() = when (phase) {
            CombinedUpdatePhase.IDLE, CombinedUpdatePhase.DONE,
            CombinedUpdatePhase.FAILED, CombinedUpdatePhase.PARTIAL -> false
            else -> true
        }
}

/**
 * One-click combined update: a single "Update" flow that brings a beacon fully current, S3
 * application firmware FIRST, then, when it applies, the nRF co-processor. This COMPOSES the two
 * proven engines ([AcabBleManager.startOta] / [NrfDfuCoordinator]); it re-implements no transfer.
 * It only sequences them, maps their two progress streams onto one 0..1 bar, and self-heals the
 * seam where the S3 reboot reset-pulses the nRF (so its reported version briefly disappears).
 *
 * Direct port of iOS BLEManager+CombinedUpdate.swift. The transitions are driven by COLLECTING the
 * S3 OTA and nRF DFU StateFlows (plus the status flow, for the nrfv repopulate) and a slow ticker
 * for elapsed time + the indeterminate creeps. Everything runs on Main.immediate, so evaluations
 * are serialized; a small re-entrancy guard covers the synchronous emits a sub-engine start fires.
 */
class CombinedUpdateCoordinator(
    private val otaProgress: StateFlow<OtaProgress>,
    private val nrfProgress: StateFlow<NrfDfuProgress>,
    private val status: StateFlow<DeviceStatus?>,
    private val otaCapable: StateFlow<Boolean>,
    private val startS3: (FirmwareBuild) -> Unit,     // AcabBleManager.startOta
    private val cancelS3: () -> Unit,                 // AcabBleManager.cancelOta
    private val dismissS3: () -> Unit,                // AcabBleManager.clearOtaResult
    private val startNrf: (FirmwareBuild) -> Unit,    // AcabBleManager.startNrfUpdate
    private val cancelNrf: () -> Unit,                // AcabBleManager.cancelNrfUpdate
    private val dismissNrf: () -> Unit,               // AcabBleManager.dismissNrfUpdate
    private val nrfUpdateAvailable: (FirmwareBuild) -> Boolean,
    private val rereadStatus: () -> Unit,             // AcabBleManager.refreshStatus (== iOS otaRereadStatus)
    private val acquireHold: () -> Unit,              // AcabLinkService FGS hold, spanning BOTH legs
    private val releaseHold: () -> Unit,
) {
    private val _progress = MutableStateFlow(CombinedUpdateProgress())
    val progress: StateFlow<CombinedUpdateProgress> = _progress.asStateFlow()

    // Everything runs on Main.immediate so evaluations are single-threaded (no locks needed beyond
    // the re-entrancy guard); the UI-facing StateFlow and the sub-engine start calls all touch main.
    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())

    // ---- one running flow's context (reset per run) ----
    private var build: FirmwareBuild? = null
    private var phase = CombinedUpdatePhase.IDLE
    private var progressF = 0f
    private var label = ""
    private var elapsed = 0
    private var notice: String? = null
    private var reason: String? = null
    private var startedAt = 0L

    // What we planned at the start, and how the 0..1 bar splits (single leg spans the whole bar;
    // both legs split 0-60 / 60-100).
    private var s3Planned = false
    private var nrfPlanned = false
    private var s3Base = 0f; private var s3Span = 0f
    private var nrfBase = 0f; private var nrfSpan = 1f

    private var s3Finished = false       // S3 reached DONE (or was never planned)
    private var s3DidUpdate = false      // S3 actually flashed something (for honest messaging)
    private var s3DoneAt = 0L
    private var reconnectStartedAt = 0L
    private var nrfIndeterminateStartedAt = 0L
    private var verifyStartedAt = 0L
    private var nrfRetried = false       // the nRF leg auto-retries exactly once

    private var runJob: Job? = null

    // ---- staleness (the single button's offer condition) ----

    /** The S3 application firmware is behind AND self-updatable: it opts into OTA, carries a
     *  verifiable image, the board exposes the OTA characteristic, and the installed version is
     *  strictly older than the manifest's. Mirrors iOS s3UpdateStale. */
    fun s3UpdateStale(build: FirmwareBuild): Boolean {
        if (!build.ota || !build.hasVerifiableImage || !otaCapable.value) return false
        val installed = status.value?.version ?: return false
        return isOlderThan(installed, build.version)
    }

    /** Either radio is behind: the OR of the two existing checks. Drives whether the single
     *  "Update" button is offered at all. Mirrors iOS combinedUpdateStale. */
    fun updateStale(build: FirmwareBuild): Boolean =
        s3UpdateStale(build) || nrfUpdateAvailable(build)

    // ---- entry points ----

    /** Start the one-click flow. Any real failure lands in [progress] rather than throwing. */
    fun start(build: FirmwareBuild) {
        if (_progress.value.isRunning) return
        // Never collide with a directly-driven sub-engine (there are no per-leg buttons anymore,
        // but an in-flight engine from a prior path would be clobbered).
        if (otaBusy() || nrfProgress.value.isRunning) return

        val s3 = s3UpdateStale(build)
        val nrf = nrfUpdateAvailable(build)
        if (!s3 && !nrf) return   // button wouldn't be shown; defense in depth

        // Clear any lingering terminal sub-state so the engines are idle before we drive them.
        dismissS3()
        dismissNrf()

        this.build = build
        s3Planned = s3
        nrfPlanned = nrf
        if (s3 && nrf) {
            s3Base = 0f; s3Span = 0.60f            // S3 = 0-60%
            nrfBase = 0.60f; nrfSpan = 0.40f       // nRF = 60-100%
        } else if (s3) {
            s3Base = 0f; s3Span = 1.0f             // S3 spans the whole bar
            nrfBase = 1.0f; nrfSpan = 0f
        } else {
            s3Base = 0f; s3Span = 0f
            nrfBase = 0f; nrfSpan = 1.0f           // nRF spans the whole bar
        }
        s3Finished = false; s3DidUpdate = false; s3DoneAt = 0L; reconnectStartedAt = 0L
        nrfIndeterminateStartedAt = 0L; verifyStartedAt = 0L; nrfRetried = false
        notice = null; reason = null; progressF = 0f; elapsed = 0
        startedAt = SystemClock.elapsedRealtime()
        phase = CombinedUpdatePhase.CHECKING
        label = "Checking for updates"
        acquireHold()                 // FGS hold spans BOTH legs (S3 releases its own on DONE)
        publish()
        beginFirstLeg()
        startDrivers()
    }

    /** User asked to stop a running flow. Best-effort: stops the drivers and the live sub-engine.
     *  The S3 leg is only cancelled before its point of no return (the board reboot): once the
     *  engine is REBOOTING/CONFIRMING the image already committed, so cancelling would kill the
     *  reconnect/confirm loop and tell the user "cancelled" about an update that actually took.
     *  Let the engine finish quietly instead (iOS BLEManager+CombinedUpdate isCancellable parity). */
    fun cancel() {
        if (!_progress.value.isRunning) return
        stopDrivers()
        if (otaCancellable()) cancelS3()
        if (nrfProgress.value.isRunning) cancelNrf()
        releaseHold()
        phase = CombinedUpdatePhase.FAILED
        reason = "Update cancelled."
        label = "Update cancelled"
        build = null
        publish()
    }

    /** Clear a terminal state back to rest. */
    fun dismiss() {
        if (_progress.value.isRunning) return
        stopDrivers()
        dismissS3()
        dismissNrf()
        build = null
        phase = CombinedUpdatePhase.IDLE
        progressF = 0f; elapsed = 0; notice = null; reason = null; label = ""
        publish()
    }

    // ---- drivers ----

    private fun beginFirstLeg() {
        val b = build ?: return
        if (s3Planned) {
            phase = CombinedUpdatePhase.UPDATING_S3
            startS3(b)
        } else {
            // No S3 work. Go straight to the co-processor decision on a fresh status read.
            s3Finished = true
            reconnectStartedAt = SystemClock.elapsedRealtime()
            rereadStatus()
            phase = CombinedUpdatePhase.RECONNECTING
        }
    }

    private fun startDrivers() {
        runJob?.cancel()
        runJob = scope.launch {
            // Collect the two sub-engine streams (+ status, for the nrfv repopulate) to DRIVE the
            // phase transitions; the ticker below covers elapsed time and the indeterminate creeps.
            launch { otaProgress.collect { tick() } }
            launch { nrfProgress.collect { tick() } }
            launch { status.collect { tick() } }
            while (isActive) { delay(TICK_MS); tick() }
        }
    }

    private fun stopDrivers() {
        runJob?.cancel()
        runJob = null
    }

    // Re-entrancy guard: a sub-engine start (dismissNrf -> IDLE, startNrf -> PREPARING) emits into a
    // flow we collect, which re-enters tick() synchronously on Main.immediate. Coalesce those into
    // the current evaluation instead of nesting.
    private var inTick = false
    private var pendingTick = false

    private fun tick() {
        if (inTick) { pendingTick = true; return }
        inTick = true
        try {
            do {
                pendingTick = false
                evaluate()
            } while (pendingTick)
        } finally {
            inTick = false
        }
        publish()
    }

    private fun evaluate() {
        if (!phase.isRunningPhase()) return
        elapsed = ((SystemClock.elapsedRealtime() - startedAt) / 1000L).toInt()
        when (phase) {
            CombinedUpdatePhase.UPDATING_S3 -> driveS3()
            CombinedUpdatePhase.RECONNECTING -> driveReconnect()
            CombinedUpdatePhase.UPDATING_COPROC, CombinedUpdatePhase.VERIFYING -> driveNrf()
            CombinedUpdatePhase.CHECKING -> {}   // start() advances immediately; nothing to poll
            else -> {}
        }
        if (phase.isRunningPhase()) label = labelFor()
    }

    // ---- leg 1: S3 application firmware ----

    private fun driveS3() {
        when (otaProgress.value.phase) {
            OtaPhase.FAILED ->
                // S3 failed: abort the whole flow, never touch the nRF.
                fail(otaProgress.value.message.ifEmpty { "The board update failed." })
            OtaPhase.DONE -> {
                // Engine handled reboot + reconnect + confirm internally.
                s3Finished = true
                s3DidUpdate = true
                s3DoneAt = SystemClock.elapsedRealtime()
                if (reconnectStartedAt == 0L) reconnectStartedAt = SystemClock.elapsedRealtime()
                rereadStatus()
                phase = CombinedUpdatePhase.RECONNECTING
                setProgress(s3Base + s3Span * 0.95f)
            }
            OtaPhase.REBOOTING, OtaPhase.CONFIRMING -> {
                // The engine is rebooting/reconnecting the board. Enter our reconnect band.
                if (reconnectStartedAt == 0L) reconnectStartedAt = SystemClock.elapsedRealtime()
                phase = CombinedUpdatePhase.RECONNECTING
            }
            else ->
                // downloading / verifying / checking / sending -> real-pct portion of the S3 band.
                setProgress(s3Base + s3Span * s3RealSub())
        }
    }

    /** Sub-progress 0..0.75 across the S3 transfer's real-percentage phases (the top 0.75..1.0 of
     *  the S3 band is the indeterminate reboot creep, handled in the reconnect driver). */
    private fun s3RealSub(): Float {
        val p = otaProgress.value
        return when (p.phase) {
            OtaPhase.DOWNLOADING -> 0.03f + 0.13f * pctFrac(p.pct)
            OtaPhase.VERIFYING -> 0.18f
            // Android's CHECKING ("preparing the board") sits AFTER verify, right before SENDING;
            // hold it level with verify so the bar never dips (the monotonic clamp would anyway).
            OtaPhase.CHECKING -> 0.18f
            OtaPhase.SENDING -> 0.18f + 0.57f * pctFrac(p.pct)
            else -> 0.03f
        }
    }

    // ---- seam: reboot / reconnect / wait for nrfv ----

    private fun driveReconnect() {
        val now = SystemClock.elapsedRealtime()
        // Indeterminate creep across the top of the S3 band, never quite reaching the top until a
        // real transition fires.
        val base = s3Base + s3Span * 0.75f
        val top = s3Base + s3Span
        val started = if (reconnectStartedAt != 0L) reconnectStartedAt else startedAt
        val t = ((now - started).toFloat() / RECONNECT_CREEP_MS).coerceAtMost(1f)
        setProgress(base + (top - base) * t * 0.9f)

        if (!s3Finished) {
            // The S3 engine is still finishing its own reboot/confirm. Watch for its terminal.
            when (otaProgress.value.phase) {
                OtaPhase.DONE -> {
                    s3Finished = true
                    s3DidUpdate = true
                    s3DoneAt = now
                    rereadStatus()
                }
                OtaPhase.FAILED -> fail(otaProgress.value.message.ifEmpty { "The board update failed." })
                else -> {}
            }
            return
        }

        // S3 finished (or was skipped). No planned co-processor leg -> done as soon as the S3 reboot
        // settled; don't stall on a nrfv a single-radio board never reports.
        if (!nrfPlanned) { decideNrfLeg(); return }

        // The S3 reboot reset-pulsed the nRF, so nrfv is briefly absent. Wait for it to repopulate
        // before re-evaluating the co-processor leg on a fresh Status.
        val doneAt = if (s3DoneAt != 0L) s3DoneAt else started
        if (status.value?.nrfVersion != null || (now - doneAt) > NRFV_WAIT_MS) {
            decideNrfLeg()
        }
    }

    private fun decideNrfLeg() {
        val b = build ?: return
        if (status.value?.nrfVersion == null) {
            if (nrfPlanned) {
                // We meant to update the co-processor but can't read its version right now. Don't
                // claim it updated; finish S3-only with a soft notice. The single button self-heals:
                // staleness re-evaluates per Status frame, so it re-offers the nRF-only run once
                // nrfv returns.
                notice = "Couldn't reach the co-processor to check its version - reconnect and try Update again if its update is available."
                finish(if (s3DidUpdate) CombinedUpdatePhase.DONE else CombinedUpdatePhase.PARTIAL)
            } else {
                // Single-radio board (or no co-processor package): S3-only, cleanly done.
                finish(CombinedUpdatePhase.DONE)
            }
            return
        }
        if (nrfUpdateAvailable(b)) {
            beginNrfLeg()
        } else {
            // Co-processor already current (or nothing was planned for it).
            finish(CombinedUpdatePhase.DONE)
        }
    }

    // ---- leg 2: nRF co-processor ----

    private fun beginNrfLeg() {
        val b = build ?: return
        nrfIndeterminateStartedAt = SystemClock.elapsedRealtime()
        phase = CombinedUpdatePhase.UPDATING_COPROC
        setProgress(nrfBase)
        startNrf(b)
    }

    private fun driveNrf() {
        val now = SystemClock.elapsedRealtime()
        when (nrfProgress.value.phase) {
            // Trigger / scan / settle: one indeterminate band. (iOS folds preparing+triggering here;
            // Android's extra SCANNING phase rides the same band.)
            NrfDfuPhase.PREPARING, NrfDfuPhase.TRIGGERING, NrfDfuPhase.SCANNING -> {
                phase = CombinedUpdatePhase.UPDATING_COPROC
                val started = if (nrfIndeterminateStartedAt != 0L) nrfIndeterminateStartedAt else now
                val t = ((now - started).toFloat() / TRIGGER_CREEP_MS).coerceAtMost(1f)
                setProgress(nrfBase + nrfSpan * (0.25f * t))
            }
            NrfDfuPhase.FLASHING -> {
                phase = CombinedUpdatePhase.UPDATING_COPROC
                val sub = 0.25f + 0.625f * pctFrac(nrfProgress.value.pct)
                setProgress(nrfBase + nrfSpan * sub)
            }
            NrfDfuPhase.CONFIRMING -> {
                // Best-effort confirm: the nRF engine resolves to DONE after a bounded wait even if
                // the new version isn't re-reported, so this is "updated (verifying)", not a failure.
                if (phase != CombinedUpdatePhase.VERIFYING) verifyStartedAt = now
                phase = CombinedUpdatePhase.VERIFYING
                val started = if (verifyStartedAt != 0L) verifyStartedAt else now
                val t = ((now - started).toFloat() / CONFIRM_CREEP_MS).coerceAtMost(1f)
                setProgress(nrfBase + nrfSpan * (0.875f + 0.125f * t * 0.9f))
            }
            NrfDfuPhase.DONE -> finish(CombinedUpdatePhase.DONE)
            NrfDfuPhase.FAILED -> {
                if (!nrfRetried) {
                    // Auto-retry the co-processor leg exactly once (the DFU is idempotent).
                    nrfRetried = true
                    nrfIndeterminateStartedAt = SystemClock.elapsedRealtime()
                    phase = CombinedUpdatePhase.UPDATING_COPROC
                    dismissNrf()               // reset FAILED -> IDLE so startNrf takes
                    build?.let { startNrf(it) }
                } else {
                    // S3 already took (or wasn't needed); the co-processor didn't. Surface partial so
                    // the same button can re-offer just the nRF leg.
                    notice = nrfProgress.value.message
                    finish(CombinedUpdatePhase.PARTIAL)
                }
            }
            NrfDfuPhase.IDLE -> {}   // transient between a retry reset and the next start
        }
    }

    // ---- terminals + helpers ----

    private fun finish(kind: CombinedUpdatePhase) {
        when (kind) {
            CombinedUpdatePhase.DONE -> {
                progressF = 1.0f
                label = "Update complete"
                phase = CombinedUpdatePhase.DONE
            }
            CombinedUpdatePhase.PARTIAL -> {
                // Leave the bar where it is (S3 region); the co-processor leg didn't complete.
                label = "Partly updated"
                phase = CombinedUpdatePhase.PARTIAL
            }
            else -> return
        }
        stopDrivers()
        releaseHold()
        build = null
        publish()
    }

    private fun fail(reason: String) {
        stopDrivers()
        releaseHold()
        this.reason = reason
        label = "Update failed"
        phase = CombinedUpdatePhase.FAILED
        build = null
        publish()
    }

    /** Monotonic, clamped progress setter (never goes backward within a run). */
    private fun setProgress(p: Float) {
        progressF = p.coerceIn(progressF, 1f)
    }

    private fun labelFor(): String = when (phase) {
        CombinedUpdatePhase.CHECKING -> "Checking for updates"
        CombinedUpdatePhase.UPDATING_S3 -> when (otaProgress.value.phase) {
            OtaPhase.DOWNLOADING -> "Downloading firmware"
            OtaPhase.VERIFYING -> "Verifying download"
            else -> "Updating board firmware"
        }
        CombinedUpdatePhase.RECONNECTING -> if (s3Finished) "Reconnecting to the board" else "Board is restarting"
        CombinedUpdatePhase.UPDATING_COPROC -> "Updating the second radio"
        CombinedUpdatePhase.VERIFYING -> "Finishing up"
        else -> label
    }

    private fun otaBusy(): Boolean {
        val p = otaProgress.value.phase
        return p != OtaPhase.IDLE && p != OtaPhase.DONE && p != OtaPhase.FAILED
    }

    /** Cancel only makes sense before the point of no return (the board reboot). REBOOTING and
     *  CONFIRMING are busy but NOT cancellable: the flash already committed and the engine is
     *  bringing the board back up. Mirrors iOS OtaState.isCancellable. */
    private fun otaCancellable(): Boolean = when (otaProgress.value.phase) {
        OtaPhase.CHECKING, OtaPhase.DOWNLOADING, OtaPhase.VERIFYING, OtaPhase.SENDING -> true
        else -> false
    }

    private fun publish() {
        _progress.value = CombinedUpdateProgress(
            phase = phase,
            progress = progressF.coerceIn(0f, 1f),
            label = label,
            elapsedSeconds = elapsed,
            notice = notice,
            reason = reason,
        )
    }

    private fun CombinedUpdatePhase.isRunningPhase(): Boolean = when (this) {
        CombinedUpdatePhase.IDLE, CombinedUpdatePhase.DONE,
        CombinedUpdatePhase.FAILED, CombinedUpdatePhase.PARTIAL -> false
        else -> true
    }

    private fun pctFrac(pct: Int): Float = pct.coerceIn(0, 100) / 100f

    /** Strictly older, compared numerically dotted-field by dotted-field (so "1.10" > "1.7", and a
     *  newer board is never flagged). Same comparator the S3 OTA + DeviceScreen use. */
    private fun isOlderThan(installed: String, latest: String): Boolean {
        val a = installed.split(".").map { it.toIntOrNull() ?: 0 }
        val b = latest.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x < y
        }
        return false
    }

    companion object {
        private const val TICK_MS = 400L
        // Timing for the indeterminate creeps and the post-S3 version-repopulate wait (iOS parity).
        private const val RECONNECT_CREEP_MS = 45_000L   // S3 reboot/reconnect band
        private const val TRIGGER_CREEP_MS = 12_000L     // nRF trigger/scan band
        private const val CONFIRM_CREEP_MS = 30_000L     // nRF confirm band
        private const val NRFV_WAIT_MS = 15_000L         // wait for nrfv to come back
    }
}
