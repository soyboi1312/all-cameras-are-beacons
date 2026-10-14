package tech.acab.app.ble

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import tech.acab.app.MainActivity
import tech.acab.app.R
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.displayName
import tech.acab.app.ui.rowTitleCase
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Per-category phone notifications for detections. Mirrors iOS DetectionNotifier rule for rule.
 *
 * WHY THIS IS SEPARATE FROM AlertMode: AlertMode governs the BOARD's buzzer (and, in VIBRATE, an
 * in-app haptic). Silencing the board is not the same decision as silencing your phone.
 *
 * ITS OWN CHANNEL, NOT the foreground-service one. AcabLinkService's channel is IMPORTANCE_LOW by
 * design (a persistent status line must never buzz). Detection alerts need HIGH, and the user must
 * be able to tune or mute one without losing the other, which a shared channel forbids.
 *
 * DESIGN RULES:
 *  - Per CATEGORY, opt-in, every one default OFF.
 *  - THE COOLDOWN IS THE EDGE, not the caller's first-sighting flag. The first version gated on
 *    AcabBleManager's `firstTime`, but the detection store is PERSISTED across launches, so a
 *    device seen in any earlier session was never "first" again and could never notify.
 *  - Never for ignored devices (dropped before the hook) or a place-muted one still waiting on a
 *    qualifying fix (fileLive's placeRuleMutesAlerts), never for Desert-mode NEARBY_DEVICE.
 *  - POST_NOTIFICATIONS (API 33+) requested lazily on the first enable.
 *
 * THREADING: the detection path runs on a BINDER thread. BluetoothGattCallback.onCharacteristicChanged
 * -> ingest() -> fileLive() -> here, none of which hops to main. The rate-limit state is therefore
 * concurrent-safe by construction (ConcurrentHashMap + AtomicLong) rather than by assumption; the
 * first version used a plain HashMap and a plain Long, which is a genuine data race next to
 * AcabBleManager's own synchronized(storeLock) neighbours.
 */
class DetectionNotifier(private val ctx: Context) {

    companion object {
        const val CHANNEL_ID = "acab_detections"
        /** Tag on every detection alert (one id per MAC). [cancelPostedAlerts] cancels by it. */
        const val NOTIFICATION_TAG = "acab.det"
        private const val PREFS = "acab"
        private const val KEY_PREFIX = "notify_"

        /** The real rate limit, matching iOS and the settings copy. */
        private const val PER_DEVICE_COOLDOWN_MS = 600_000L    // 10 minutes

        /**
         * Floor between notifications for DIFFERENT devices. Small on purpose: it suppresses one
         * alert, and because the cooldown (not a first-sighting flag) is the edge, the device is
         * offered again on its next sighting rather than lost.
         */
        private const val GLOBAL_MIN_GAP_MS = 4_000L

        /** Prune the cooldown map past this size so a long drive cannot grow it without bound. */
        private const val COOLDOWN_PRUNE_AT = 256

        /**
         * Categories a user can switch on. ONE ALPR row: everywhere else in both apps FLOCK_CAMERA
         * and FLOCK_RAVEN are a single "ALPR" category, and Raven is an acoustic sensor rather than
         * a plate reader, so a separate row subtitled "plate readers" was both a duplicate-looking
         * row and factually wrong. NEARBY_DEVICE is excluded (Desert is ambient, not an event).
         */
        val NOTIFIABLE = listOf(
            DeviceType.FLOCK_CAMERA, DeviceType.BODY_CAM, DeviceType.GLASSES,
            DeviceType.NETWORK_CAMERA, DeviceType.DRONE, DeviceType.TRACKER, DeviceType.WATCHED,
        )

        private fun key(t: DeviceType) = "$KEY_PREFIX${t.raw}"

        /** Cached: the detection path consults this per record, and it used to be up to 8 prefs
         *  reads (each taking a lock) on every one. */
        @Volatile private var enabledCache: Set<Int>? = null

        private fun rebuildCache(ctx: Context) {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val s = HashSet<Int>()
            NOTIFIABLE.forEach { t ->
                if (p.getBoolean(key(t), false)) {
                    s.add(t.raw)
                    // ALPR is one category; RAVEN has no row and follows FLOCK_CAMERA's switch.
                    if (t == DeviceType.FLOCK_CAMERA) s.add(DeviceType.FLOCK_RAVEN.raw)
                }
            }
            enabledCache = s
        }

        fun isEnabled(ctx: Context, t: DeviceType): Boolean {
            val c = enabledCache ?: run { rebuildCache(ctx); enabledCache }
            return c?.contains(t.raw) == true
        }

        fun setEnabled(ctx: Context, t: DeviceType, on: Boolean) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(key(t), on).apply()
            rebuildCache(ctx)
        }

        fun anyEnabled(ctx: Context): Boolean {
            val c = enabledCache ?: run { rebuildCache(ctx); enabledCache }
            return c?.isNotEmpty() == true
        }

        /** API 33+ gates posting behind a runtime permission; below that it is implicit. */
        fun hasPostPermission(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

        /** True when a category is on but the system will not deliver, so the UI can say so
         *  instead of showing a green toggle over a dead feature. */
        fun mutedBySystem(ctx: Context): Boolean {
            if (!anyEnabled(ctx)) return false
            if (!hasPostPermission(ctx)) return true
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return true
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return false
            val ch = nm.getNotificationChannel(CHANNEL_ID) ?: return false
            return ch.importance == NotificationManager.IMPORTANCE_NONE
        }

        /** True when the Live Mode foreground notification can actually reach the shade:
         *  runtime permission held, app-level notifications on, and the drive channel not
         *  muted. THE single owner of this rule: MainActivity's automatic Live Mode start and
         *  the Beacon readiness surface both read it, so they can never disagree about the
         *  same phone. A null channel passes (it is created on the first service start). */
        fun liveChannelDeliverable(ctx: Context): Boolean {
            if (!hasPostPermission(ctx) ||
                !NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return false
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            return nm?.getNotificationChannel(AcabLinkService.CHANNEL_ID)?.importance !=
                NotificationManager.IMPORTANCE_NONE
        }
    }

    private val lastByMac = ConcurrentHashMap<String, Long>()
    private val lastAt = AtomicLong(0L)

    init {
        // Created up front, not on first post, so the channel exists in system settings for the
        // user to tune BEFORE anything is ever detected.
        ensureChannel()
    }

    private fun ensureChannel() {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Detections", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alerts for the detection categories you switched on."
                enableVibration(true)
            }
        )
    }

    /** Same target as the drive-mode notification: open the app on the new-detections log. */
    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        ctx, 1,
        Intent(ctx, MainActivity::class.java).putExtra(MainActivity.EXTRA_OPEN_LOG_NEW, true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * Post for a detection if its category is on and the rate limits allow.
     *
     * LOCK SCREEN. Every alert is VISIBILITY_PRIVATE with the generic public version, so the
     * system's own "sensitive notifications" setting decides what a locked phone shows. Never
     * PUBLIC: that overrides a user who told the OS to hide details (app review 2026-10-12 A.5).
     *
     * REDACTION. [redact] is the app's "hide details on lock screen" switch. PRIVATE alone leaves
     * the locked face to the system setting, whose default shows everything, so with the switch
     * on the alert ITSELF is generic ([detectionAlertText]): the shade loses the details on an
     * unlocked phone too. The quieter side of the trade, and the shared rule with iOS (app review
     * 2026-10-12 S6, DetectionNotifier.alertText(for:redact:)). An earlier version did this and
     * moved to public-version-only redaction; it is back because a PRIVATE alert's locked face
     * now follows the system setting whether this switch is on or off.
     */
    fun notifyIfNeeded(d: Detection, redact: Boolean) {
        if (d.hist) return                             // an offline replay is not a live event
        if (d.type == DeviceType.NEARBY_DEVICE) return // Desert rows are ambient, never an alert
        if (!isEnabled(ctx, d.type)) return
        if (!hasPostPermission(ctx)) return

        val now = System.currentTimeMillis()
        val prev = lastByMac[d.mac]
        if (prev != null && now - prev < PER_DEVICE_COOLDOWN_MS) return
        // Burst floor for DIFFERENT devices. Safe to drop: the device is not marked, so its next
        // sighting is offered again.
        if (now - lastAt.get() < GLOBAL_MIN_GAP_MS) return

        lastByMac[d.mac] = now
        lastAt.set(now)
        pruneCooldowns(now)

        val (title, body) = detectionAlertText(d.type, d.displayName, d.confidence, redact)
        val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            // STATUS, not ALARM. CATEGORY_ALARM punches through Do Not Disturb, which contradicts
            // the sibling haptic path that deliberately honours DND via focusSuppressed(), and is
            // not a promise this feature should be making on the user's behalf.
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(tapIntent())
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(ctx, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_beacons)
                    .setContentTitle(REDACTED_ALERT_TITLE)
                    .setContentText(REDACTED_ALERT_BODY)
                    .setContentIntent(tapIntent())
                    .build()
            )
        try {
            // Per-MAC id so a repeat REPLACES rather than stacks, and so [cancelPostedAlert] can
            // withdraw it. Tagged so it cannot collide with the foreground-service notification's
            // own id space.
            NotificationManagerCompat.from(ctx).notify(NOTIFICATION_TAG, alertId(d.mac), b.build())
        } catch (_: SecurityException) {
            // Permission revoked between the check above and the post. The next enable re-requests.
        }
    }

    private fun pruneCooldowns(now: Long) {
        if (lastByMac.size <= COOLDOWN_PRUNE_AT) return
        lastByMac.entries.removeAll { now - it.value >= PER_DEVICE_COOLDOWN_MS }
    }

    /**
     * The real Clear log: cancel this app's posted detection alerts, which otherwise keep device
     * names in the notification shade after the history is gone. Scoped by [NOTIFICATION_TAG], so
     * the ongoing AcabLinkService notification (untagged, its own id) and anything else survive.
     * Binder IPC to the notification service: call it off the main thread. A post racing this
     * call can survive it; the next alert for that device replaces it by id anyway. Not for a
     * sample-mode Clear.
     *
     * iOS twin: ios/Beacons/BLE/DetectionNotifier.swift removeDetectionNotifications.
     */
    fun cancelPostedAlerts() {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        runCatching {
            nm.activeNotifications
                .filter { it.tag == NOTIFICATION_TAG }
                .forEach { nm.cancel(it.tag, it.id) }
        }
    }

    /**
     * Withdraw the delivered alert for one device, whatever its type: muting it (single or bulk)
     * and un-watching it call this, so a device the user just silenced stops naming itself in the
     * shade. A no-op when nothing is posted for [mac]. One binder call, no listing.
     *
     * Shared rule with iOS (app review 2026-10-12 S8), whose alerts are per MAC the same way.
     * iOS twin: DetectionNotifier.removeDetectionNotifications(forMacs:), the same scope.
     */
    fun cancelPostedAlert(mac: String) {
        runCatching { NotificationManagerCompat.from(ctx).cancel(NOTIFICATION_TAG, alertId(mac)) }
    }

    /** Drop cooldown state so a genuinely new session can alert on the same devices again. */
    fun reset() {
        lastByMac.clear()
        lastAt.set(0L)
    }
}

/** The alert's one id per device. Lowercased so a post and a withdrawal agree whatever case the
 *  MAC arrived in: the managed lists, which un-watch passes from, store it lowercased. iOS twin:
 *  DetectionNotifier.alertIdentifier(_:), lowercased the same way. */
private fun alertId(mac: String): Int = mac.lowercase().hashCode()

/** Title and body of a locked phone's generic alert, and of every alert while the redact switch
 *  is on. The body sentence is shared with iOS (app review 2026-10-12 S6: its
 *  hiddenPreviewsBodyPlaceholder and its redacted alert body). */
internal const val REDACTED_ALERT_TITLE = "beacons"
internal const val REDACTED_ALERT_BODY = "Something was detected nearby."

/**
 * The alert's title and body. Pure, so the casing and the redaction rule are pinned in a JVM
 * test (AppReviewDataTest).
 *
 * TITLE: the category in sentence case, [DeviceType.inlineLabel] with its first letter raised
 * ("ALPR camera", "Body cam", "Recording glasses"), never [DeviceType.label], which mixes Title
 * Case ("ALPR Camera", "Body Camera") with sentence case and put both conventions in one shade.
 * Same transform as a row title (rowTitleCase). Shared rule with iOS (app review 2026-10-12 S5).
 *
 * BODY: the name is radio-controlled: any nearby device can broadcast newlines, control
 * characters or bidi overrides to reshape or spoof the banner, so it is stripped here
 * (notification text only; the log rows render the raw name). A name that strips to nothing, or
 * that is only the category label ([displayName]'s last fallback), reads "Detected nearby"; the
 * comparison is with [DeviceType.label] exactly, not with the title.
 *
 * iOS twin: DetectionNotifier.alertText(for:redact:), the same title, body and redaction rule.
 */
internal fun detectionAlertText(
    type: DeviceType,
    displayName: String,
    confidence: Int,
    redact: Boolean,
): Pair<String, String> {
    if (redact) return REDACTED_ALERT_TITLE to REDACTED_ALERT_BODY
    val who = notificationSafeName(displayName).ifBlank { type.label }
    val body = if (who == type.label) "Detected nearby, $confidence% confidence."
               else "$who detected, $confidence% confidence."
    return rowTitleCase(type.inlineLabel) to body
}

/**
 * [name] with every character that can reshape a notification removed: C0 controls
 * (U+0000-001F, which includes CR/LF/tab), DEL and C1 controls (U+007F-009F), the line and
 * paragraph separators (U+2028-2029), and the bidi marks, embeddings, overrides and isolates
 * (U+061C, U+200E-200F, U+202A-202E, U+2066-2069). Then trimmed. Pure, and used only for the
 * notification body; the UI rows render the raw name.
 *
 * iOS twin: ios/Beacons/BLE/DetectionNotifier.swift notificationSafeName, same character set.
 * Iterates code points, so an astral character (emoji) is kept whole.
 */
internal fun notificationSafeName(name: String): String {
    val out = StringBuilder(name.length)
    var i = 0
    while (i < name.length) {
        val cp = name.codePointAt(i)
        if (!isBannerUnsafe(cp)) out.appendCodePoint(cp)
        i += Character.charCount(cp)
    }
    // Kotlin's trim() drops Unicode space separators (Zs), matching Swift's .whitespaces.
    return out.toString().trim()
}

private fun isBannerUnsafe(cp: Int): Boolean = when (cp) {
    in 0x00..0x1F, in 0x7F..0x9F -> true               // C0, DEL, C1
    0x2028, 0x2029 -> true                              // line / paragraph separator
    0x061C, 0x200E, 0x200F -> true                      // ALM, LRM, RLM
    in 0x202A..0x202E, in 0x2066..0x2069 -> true        // embeddings, overrides, isolates
    else -> false
}
