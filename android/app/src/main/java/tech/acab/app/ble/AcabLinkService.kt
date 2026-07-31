package tech.acab.app.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.Manifest
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch
import tech.acab.app.MainActivity
import tech.acab.app.R
import tech.acab.app.model.Detection

/**
 * Drive-mode foreground service. Keeps the BLE link alive in the background (the manager
 * is a process singleton) and posts an ongoing "glanceable counter" notification , a live
 * ALPR / drone / body-cam / tracker tally on the lock screen and in the shade. The phone
 * analog of the iOS Live Activity. On Android 16+ it promotes to a Live Update status-bar
 * chip (see promoteIfSupported). An in-flight OTA also holds it (HOLD_OTA) so the cached-app
 * freezer can't halt the chunk stream mid-flash; that face is a plain keep-alive line.
 */
class AcabLinkService : Service() {

    // Default, not Main: every render walks the feed and crosses the NotificationManager
    // binder, and at drive-length durations that must not ride the main thread alongside
    // Map/Log recomposition. notify() is thread-safe and build() touches only immutable data
    // + NotificationCompat builders; only startForegroundCompat stays on main (onStartCommand).
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val ble by lazy { AcabBleManager.getInstance(this) }
    private var renderJob: Job? = null
    // Fingerprint of the last face actually posted: an unchanged tick skips the build and the
    // notification IPC outright (the collector otherwise re-renders for hours with the screen
    // off). The minute tick still lands whenever the "Xm ago" text really changes.
    private var lastFace: String? = null

    private data class RenderInput(
        val dets: List<Detection>, val state: ConnState, val redact: Boolean, val drive: Boolean,
    )

    override fun onBind(intent: Intent?): IBinder? = null

    @OptIn(FlowPreview::class)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        isRunning = true
        createChannel()
        startForegroundCompat(
            build(ble.state.value, ble.detections.value, ble.redactLockScreen.value, ble.driveModeOn))
        // onStartCommand can run again on a repeat start; cancel the previous collector
        // so re-renders never stack up.
        renderJob?.cancel()
        renderJob = scope.launch {
            // Re-render on detections / connection-state / redaction / hold changes, sampled so
            // a burst of hits can't hammer NotificationManager (it drops excess updates anyway).
            // The minute tick keeps the "last ALPR 2m ago" line honest during a quiet stretch.
            val minuteTick = flow { while (true) { emit(Unit); delay(60_000L) } }
            combine(ble.detections, ble.state, ble.redactLockScreen, ble.driveMode, minuteTick) { d, s, r, drv, _ ->
                RenderInput(d, s, r, drv)
            }
                .sample(RENDER_SAMPLE_MS)
                .collect { renderIfChanged(it) }
        }
        // NOT_STICKY: if the system kills us under memory pressure, don't get recreated with a
        // null intent into a disconnected, device-less "Reconnecting…" zombie. Drive mode just
        // ends; the user re-enables it. (The connectedDevice FGS needs a live link anyway.)
        return START_NOT_STICKY
    }

    private fun renderIfChanged(inp: RenderInput) {
        val face = face(inp.state, inp.dets, inp.redact, inp.drive)
        if (face == lastFace) return
        lastFace = face
        runCatching { nm()?.notify(NOTIF_ID, build(inp.state, inp.dets, inp.redact, inp.drive)) }
    }

    /** Everything the rendered surface can show, flattened: equal faces mean a notify() would
     *  be a visual no-op, so the render is skipped. */
    private fun face(state: ConnState, dets: List<Detection>, redact: Boolean, drive: Boolean): String {
        if (!drive) return "ota|$redact"
        val counts = dets.groupingBy { it.type.category }.eachCount()
        val total = driveTotal(counts)
        val connected = state == ConnState.READY
        val breakdown = breakdownOf(counts)
        val text = textOf(connected, total)
        return "$connected|$total|$redact|$text|$breakdown"
    }

    /** Headline count: the sum over the buckets this surface actually lists. Was dets.size,
     *  which folded in NEARBY / network-camera / WATCHED rows that breakdownOf never shows,
     *  so the title disagreed with its own expanded row and with iOS. */
    private fun driveTotal(counts: Map<String, Int>): Int =
        DRIVE_CATS.sumOf { counts[it] ?: 0 }

    private fun breakdownOf(counts: Map<String, Int>): String =
        DRIVE_CATS
            .mapNotNull { c -> (counts[c] ?: 0).takeIf { it > 0 }?.let { "$c $it" } }
            .joinToString("  ")

    private fun textOf(connected: Boolean, total: Int): String = when {
        !connected -> "Reconnecting…"
        total == 0 -> "no detections"
        else -> lastLine()
    }

    override fun onDestroy() {
        isRunning = false
        scope.cancel()
        super.onDestroy()
    }

    private fun build(state: ConnState, dets: List<Detection>, redact: Boolean, drive: Boolean): Notification {
        // Only an in-flight firmware update is holding the service (Drive mode off): show a
        // plain keep-alive face, no counters.
        if (!drive) return buildOtaHold()
        val counts = dets.groupingBy { it.type.category }.eachCount()
        val total = driveTotal(counts)
        val connected = state == ConnState.READY
        // Only show buckets with hits, in the same order as the iOS Live Activity.
        val breakdown = breakdownOf(counts)
        // Same vocabulary as the iOS Live Activity (F27): title DRIVE MODE, body one of
        // "no detections" / "Reconnecting…" / "last <KIND> <relative>".
        val text = textOf(connected, total)
        val tap = tapIntent()
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("DRIVE MODE")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        // The expanded shade keeps the per-category tally, the analog of the iOS tile row.
        if (connected && breakdown.isNotEmpty()) {
            b.setStyle(NotificationCompat.BigTextStyle().bigText("$text\n$breakdown"))
        }
        if (redact) {
            // Lock-screen privacy (user setting, default on): a locked phone shows only the
            // redacted public version ("Drive mode active"), never the gear breakdown. The
            // full text appears in the shade once unlocked.
            b.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            b.setPublicVersion(buildPublic(tap))
        } else {
            b.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        }
        promoteIfSupported(b, total, connected)
        return b.build()
    }

    /** "last ALPR 2m ago" - the most recently heard LIVE detection, category + relative time.
     *  Reads the manager's O(1) newest-live pointer instead of a maxBy over the whole feed
     *  with a storeLock-guarded lastSeen() per row. Live rows only, deliberately: an offline
     *  replay re-files rows with pseudo-stamps that sort below every real one, so a max over
     *  the store diverges from "most recently heard" right after a buffer drain. */
    private fun lastLine(): String {
        val nl = ble.newestLive() ?: return "no detections"
        return "last ${nl.category} ${relativeAgo(nl.at)}"
    }

    /** The face shown while only a firmware update holds the service: a static keep-alive. */
    private fun buildOtaHold(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("FIRMWARE UPDATE")
            .setContentText("Sending the update to your board.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(tapIntent())
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

    /** Short "ago" string, same tiers as the dossier's relativeAgo. */
    private fun relativeAgo(ms: Long?): String {
        if (ms == null) return "now"
        val secs = ((System.currentTimeMillis() - ms) / 1000).coerceAtLeast(0)
        return when {
            secs < 5 -> "now"
            secs < 60 -> "${secs}s ago"
            secs < 3600 -> "${secs / 60}m ago"
            secs < 86_400 -> "${secs / 3600}h ago"
            else -> "${secs / 86_400}d ago"
        }
    }

    /** The redacted lock-screen face: no counts, no breakdown - just "active". */
    private fun buildPublic(tap: PendingIntent): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("DRIVE MODE")
            .setContentText("Active · counts in app")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

    /** Tap opens the app on the Log tab with the NEW filter active (F27 deep link). */
    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_OPEN_LOG_NEW, true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** Android 16 (API 36) "Live Update": promote the ongoing notification so the OS shows
     *  a compact status-bar chip with the count. */
    private fun promoteIfSupported(b: NotificationCompat.Builder, total: Int, connected: Boolean) {
        // Android 16 (API 36) "Live Update": promote the ongoing notification to a compact
        // status-bar chip showing the count (the Dynamic-Island analog). On API 26-35 these
        // calls are skipped and the plain ongoing notification is the universal fallback.
        if (Build.VERSION.SDK_INT >= 36) {
            b.setRequestPromotedOngoing(true)
            // Only surface the count while the board is actually linked. When it disconnects or
            // powers off, the chip must not keep flashing the last tally as if it were live - drop
            // the number so the chip goes to the plain state (the body already reads "Reconnecting…").
            // This mirrors the iOS Live Activity fix: no stale count on the glanceable surface once
            // the link is gone. (Drive mode also fully ends on a real disconnect via cleanup(); this
            // covers the brief reconnecting window and any state where connected is false.)
            b.setShortCriticalText(if (connected && total > 0) total.toString() else null)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ch = NotificationChannel(CHANNEL_ID, "Drive mode", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Live detection counter while driving"
            setShowBadge(false)
        }
        nm()?.createNotificationChannel(ch)
    }

    private fun startForegroundCompat(n: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // The location type is what keeps fixes flowing once the activity is gone, so drive
                // mode stops pinning every hit on wherever we last had one. OR it in ONLY when the
                // permission is actually held: location is optional here (MainActivity gates
                // startLocation), and Android 14+ throws SecurityException on a declared type the app
                // has no permission for, which would kill drive mode outright for a user who declined.
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (hasLocationPermission()) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                startForeground(NOTIF_ID, n, types)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            // Never let a foreground-service start crash the process. Android 14+ throws
            // SecurityException if we assert the connectedDevice type without BLUETOOTH_CONNECT (a
            // store reviewer who denied Bluetooth then triggered Drive mode in the demo), and can
            // throw ForegroundServiceStartNotAllowedException. Degrade: drop the service so Drive
            // mode simply doesn't engage, rather than taking down the app.
            android.util.Log.w("AcabLinkService", "startForeground failed; stopping service", e)
            // The service is going down without anyone calling stop(): keep the bookkeeping in
            // sync with reality. Clear the holder set so a later hold-release (OTA/combined)
            // doesn't find a stale "drive" entry, skip stopService, and resurrect a drive-mode
            // notification the user never re-requested; and reset the manager's drive flag so
            // the in-app switch and the QS tile stop claiming ACTIVE for a service that never
            // engaged. endDriveMode() re-enters stop(), which is a no-op on the cleared set.
            holders.clear()
            runCatching { if (ble.driveModeOn) ble.endDriveMode() }
            stopSelf()
        }
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun nm(): NotificationManager? =
        getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    companion object {
        private const val CHANNEL_ID = "acab.drive"
        private const val NOTIF_ID = 1001

        /** The buckets drive mode speaks, in the order the expanded shade lists them. The
         *  headline count, the Android-16 status chip and the breakdown all read this one
         *  list, so the title can never claim more than the rows below it explain. Desert
         *  mode's NEARBY rows, opt-in network cameras and WATCHED re-sightings are excluded
         *  deliberately, matching the iOS Live Activity (BLEManager.publishDetections).
         *  These are DeviceType.category identifiers, not display text. */
        private val DRIVE_CATS = listOf("ALPR", "DRONE", "BODY CAM", "TRACKER", "GLASSES")
        // Render cadence. The surface is glanceable (relative ages in seconds/minutes), so
        // 2 s is plenty; unchanged faces are skipped before the build + IPC anyway.
        private const val RENDER_SAMPLE_MS = 2_000L

        /** Start reasons. Drive mode and an in-flight OTA hold the service independently -
         *  endDriveMode used to stop it unconditionally, which would also have killed an OTA's
         *  process keep-alive (and vice versa); stop() only tears the service down when the
         *  last holder releases. */
        const val HOLD_DRIVE = "drive"
        const val HOLD_OTA = "ota"
        // The one-click combined update holds the service across BOTH legs: the S3 OTA releases its
        // own HOLD_OTA on its DONE, so without this independent hold the process could be frozen in
        // the seam between the S3 finishing and the nRF DFU starting (and through the nRF leg, which
        // takes no hold of its own).
        const val HOLD_COMBINED = "combined"
        private val holders = java.util.Collections.synchronizedSet(mutableSetOf<String>())

        /** True while the foreground service is alive. The Quick Settings tile reads this to
         *  render its on/off state; a plain static flag rather than a binding, so it can lag
         *  by one main-thread turn around start/destroy. */
        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, holder: String = HOLD_DRIVE) {
            holders.add(holder)
            ContextCompat.startForegroundService(context, Intent(context, AcabLinkService::class.java))
        }

        fun stop(context: Context, holder: String = HOLD_DRIVE) {
            holders.remove(holder)
            if (holders.isEmpty()) context.stopService(Intent(context, AcabLinkService::class.java))
        }
    }
}
