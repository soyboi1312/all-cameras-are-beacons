package tech.acab.app.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
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
 * chip (see promoteIfSupported).
 */
class AcabLinkService : Service() {

    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private val ble by lazy { AcabBleManager.getInstance(this) }

    override fun onBind(intent: Intent?): IBinder? = null

    @OptIn(FlowPreview::class)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        startForegroundCompat(build(ble.state.value, ble.detections.value, ble.redactLockScreen.value))
        scope.launch {
            // Re-render on detections / connection-state / redaction changes, sampled so a
            // burst of hits can't hammer NotificationManager (it drops excess updates anyway).
            combine(ble.detections, ble.state, ble.redactLockScreen) { d, s, r -> Triple(d, s, r) }
                .sample(500L)
                .collect { (d, s, r) -> runCatching { nm()?.notify(NOTIF_ID, build(s, d, r)) } }
        }
        // NOT_STICKY: if the system kills us under memory pressure, don't get recreated with a
        // null intent into a disconnected, device-less "Reconnecting…" zombie. Drive mode just
        // ends; the user re-enables it. (The connectedDevice FGS needs a live link anyway.)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun build(state: ConnState, dets: List<Detection>, redact: Boolean): Notification {
        val counts = dets.groupingBy { it.type.category }.eachCount()
        val total = dets.size
        val connected = state == ConnState.READY
        // Only show buckets with hits, in the same order as the iOS Live Activity.
        val breakdown = listOf("ALPR", "DRONE", "BODY CAM", "TRACKER", "POLICE")
            .mapNotNull { c -> (counts[c] ?: 0).takeIf { it > 0 }?.let { "$c $it" } }
            .joinToString("  ")
        val title = if (total > 0) "$total detected" else "Drive mode"
        val text = when {
            !connected -> "Reconnecting…"
            breakdown.isNotEmpty() -> breakdown
            else -> "Scanning · all clear"
        }
        val tap = tapIntent()
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        if (redact) {
            // Lock-screen privacy (user setting, default on): a locked phone shows only the
            // redacted public version ("Drive mode active"), never the gear breakdown. The
            // full text appears in the shade once unlocked.
            b.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            b.setPublicVersion(buildPublic(tap))
        } else {
            b.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        }
        promoteIfSupported(b, total)
        return b.build()
    }

    /** The redacted lock-screen face: no counts, no breakdown - just "Drive mode active". */
    private fun buildPublic(tap: PendingIntent): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("Drive mode")
            .setContentText("Active · counts in app")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, MainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** Android 16 (API 36) "Live Update": promote the ongoing notification so the OS shows
     *  a compact status-bar chip with the count. Hook left here; the real call is wired up
     *  once compileSdk is 36 + androidx.core carries the promote APIs (see build.gradle). */
    private fun promoteIfSupported(b: NotificationCompat.Builder, total: Int) {
        // Android 16 (API 36) "Live Update": promote the ongoing notification to a compact
        // status-bar chip showing the count (the Dynamic-Island analog). On API 26-35 these
        // calls are skipped and the plain ongoing notification is the universal fallback.
        if (Build.VERSION.SDK_INT >= 36) {
            b.setRequestPromotedOngoing(true)
            b.setShortCriticalText(if (total > 0) total.toString() else null)
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun nm(): NotificationManager? =
        getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    companion object {
        private const val CHANNEL_ID = "acab.drive"
        private const val NOTIF_ID = 1001

        fun start(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, AcabLinkService::class.java))

        fun stop(context: Context) =
            context.stopService(Intent(context, AcabLinkService::class.java))
    }
}
