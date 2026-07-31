package tech.acab.app.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import tech.acab.app.MainActivity
import tech.acab.app.R
import java.time.LocalDate

/**
 * Home-screen widget: today's detection count, today's per-category breakdown, the last sighting
 * (glyph + category + relative time), and the link state, glanced from the launcher.
 *
 * A widget runs in the launcher's process and cannot read the app singleton's memory, so the
 * app hands it a tiny summary through a shared-prefs file it reads here. AcabBleManager writes
 * that file on every publish and on connect/disconnect, then calls [refresh] to re-render every
 * placed instance. The prefs file name and key strings are the cross-process CONTRACT and must
 * match the writer in AcabBleManager exactly.
 *
 * Anatomy mirrors the iOS DetectionsWidget (R19): crimson link dot with dim-white text (teal is
 * the tracker category's tone and reads as a detection), a six-cell category strip that hides
 * zero cells, a last-hit line carrying the category's own glyph and tint, and a green
 * check-shield empty state. The layout holds a fixed six cells in WidgetCategory order, so their
 * glyphs and tints live in XML and only the numbers and visibility are set here.
 */
class BeaconsWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        // The OS periodic tick (updatePeriodMillis) and a first placement both land here; render
        // whatever the last-written summary holds.
        val views = buildViews(context)
        for (id in ids) manager.updateAppWidget(id, views)
    }

    companion object {
        // The shared-prefs CONTRACT with AcabBleManager. Same file + keys on both sides.
        const val PREFS = "beacons_widget"
        const val KEY_COUNT = "w_countToday"
        const val KEY_LAST_TYPE = "w_lastType"
        const val KEY_LAST_AT = "w_lastAt"
        const val KEY_CONNECTED = "w_connected"
        const val KEY_DAY = "w_day"

        /** Per-category count keys, "w_c_" + the widget category token. Same shape as the iOS
         *  widget's App Group keys (WidgetCategory.defaultsKey), so both platforms describe the
         *  same breakdown with the same names. */
        const val KEY_CAT_PREFIX = "w_c_"

        /** Widget category tokens, in strip order. These are contract identifiers, not display
         *  text: the strip renders glyphs, and the last-hit line lowercases for display. */
        val CAT_TOKENS = listOf("ALPR", "DRONE", "BODY", "TRACKER", "GLASSES", "CAMERA")

        // Acab palette (see theme/Theme.kt). A RemoteViews render can't reach the Compose theme,
        // so the dynamic colors are duplicated here as ARGB ints.
        private const val TEXT = 0xFFF4EEF0.toInt()       // full-strength text
        private const val DIM = 0x99F0E0E2.toInt()        // secondary text
        private const val FAINT = 0x73F0E0E2.toInt()      // empty-state text
        private const val LAST = 0x8CF0E0E2.toInt()       // last-hit text
        private const val ACCENT = 0xFFEE4034.toInt()     // crimson
        private const val DOT_OFF = 0x47FFFFFF            // link dot, not connected
        private const val GREEN = 0xFF5AD08A.toInt()      // check-shield, nothing detected
        private const val SHIELD_DIM = 0xB3FFFFFF.toInt() // fallback glyph for an odd category

        // Strip cells, in CAT_TOKENS order: the row container (hidden when zero) + its number.
        private val CELL_IDS = intArrayOf(
            R.id.widget_c0, R.id.widget_c1, R.id.widget_c2,
            R.id.widget_c3, R.id.widget_c4, R.id.widget_c5,
        )
        private val CELL_N_IDS = intArrayOf(
            R.id.widget_c0_n, R.id.widget_c1_n, R.id.widget_c2_n,
            R.id.widget_c3_n, R.id.widget_c4_n, R.id.widget_c5_n,
        )

        /** Re-render every placed instance from the current summary. No-op when no widget is
         *  placed, so the hot publish path pays almost nothing. Safe to call from any thread. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, BeaconsWidgetProvider::class.java))
            if (ids.isEmpty()) return
            manager.updateAppWidget(ids, buildViews(context))
        }

        private fun buildViews(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val storedDay = prefs.getInt(KEY_DAY, 0)
            val today = LocalDate.now().toEpochDay().toInt()
            // Honesty at the day boundary: if the summary was written on an earlier day and the
            // app hasn't run since (so the count wasn't reset), show 0 rather than yesterday's
            // total. The count is only trustworthy for the day it was stamped.
            val fresh = storedDay == today
            val count = if (fresh) prefs.getInt(KEY_COUNT, 0) else 0
            val lastType = prefs.getString(KEY_LAST_TYPE, "") ?: ""
            val lastAt = prefs.getLong(KEY_LAST_AT, 0L)
            val connected = prefs.getBoolean(KEY_CONNECTED, false)

            val views = RemoteViews(context.packageName, R.layout.widget_beacons)
            views.setTextViewText(R.id.widget_count, count.toString())
            // The headline goes quiet on a zero day rather than shouting a crimson 0.
            views.setTextColor(R.id.widget_count, if (count > 0) TEXT else DIM)
            views.setTextColor(R.id.widget_today, if (count > 0) ACCENT else FAINT)

            // Link state: crimson dot + dim-white "connected", dim both when not. Vocabulary matches
            // the in-app LinkChip, which also reads CONNECTED rather than LINKED.
            // This is the widget's honest connection signal (mirrors the iOS widget); a stale
            // count never reads as live because the state sits right next to it.
            views.setTextViewText(R.id.widget_status, if (connected) "connected" else "not connected")
            views.setTextColor(R.id.widget_status, DIM)
            views.setTextColor(R.id.widget_dot, if (connected) ACCENT else DOT_OFF)

            // Category strip: one cell per token, hidden when it has nothing today. Same
            // stale-day rule as the headline: a breakdown from yesterday next to a zeroed total
            // would be worse than showing nothing.
            for (i in CAT_TOKENS.indices) {
                val n = if (fresh) prefs.getInt(KEY_CAT_PREFIX + CAT_TOKENS[i], 0) else 0
                if (n > 0) {
                    views.setTextViewText(CELL_N_IDS[i], n.toString())
                    views.setViewVisibility(CELL_IDS[i], android.view.View.VISIBLE)
                } else {
                    views.setViewVisibility(CELL_IDS[i], android.view.View.GONE)
                }
            }

            // Last sighting: the category's own glyph and tint, then "alpr · 3m ago". With
            // nothing to report it becomes the green check-shield and an honest empty line.
            if (lastType.isNotEmpty() && lastAt > 0L) {
                val (icon, tint) = lastLook(lastType)
                views.setImageViewResource(R.id.widget_last_icon, icon)
                views.setInt(R.id.widget_last_icon, "setColorFilter", tint)
                views.setTextViewText(R.id.widget_last, "${lastType.lowercase()} · ${relativeAgo(lastAt)}")
                views.setTextColor(R.id.widget_last, LAST)
            } else {
                views.setImageViewResource(R.id.widget_last_icon, R.drawable.ic_w_ok)
                views.setInt(R.id.widget_last_icon, "setColorFilter", GREEN)
                views.setTextViewText(R.id.widget_last, if (connected) "no detections" else "not connected")
                views.setTextColor(R.id.widget_last, FAINT)
            }

            // Tapping the widget opens the app.
            views.setOnClickPendingIntent(R.id.widget_root, launchIntent(context))
            return views
        }

        /** Glyph + tint for a last-hit category. Matched exactly, not by substring: lastType is
         *  written straight from DeviceType.category, and the network camera's category is
         *  "CAMERA", which a substring match would hand the ALPR glyph. Anything unexpected
         *  (NEARBY, UNKNOWN, a future category) falls back to the neutral shield rather than
         *  borrowing another category's colour. */
        private fun lastLook(cat: String): Pair<Int, Int> = when (cat) {
            "ALPR" -> R.drawable.ic_w_alpr to ACCENT
            "DRONE" -> R.drawable.ic_w_drone to 0xFFF2B53C.toInt()
            "BODY CAM" -> R.drawable.ic_w_body to 0xFFCDC1C3.toInt()
            "TRACKER" -> R.drawable.ic_w_tracker to 0xFF49C5B1.toInt()
            "GLASSES" -> R.drawable.ic_w_glasses to 0xFFB07CFF.toInt()
            "CAMERA" -> R.drawable.ic_w_netcam to 0xFF4AA8FF.toInt()
            "WATCHED" -> R.drawable.ic_w_star to 0xFFE0A84B.toInt()
            else -> R.drawable.ic_w_ok to SHIELD_DIM
        }

        /** Short "ago" string, same tiers as the drive-mode notification's relativeAgo. */
        private fun relativeAgo(atMs: Long): String {
            val secs = ((System.currentTimeMillis() - atMs) / 1000).coerceAtLeast(0)
            return when {
                secs < 5 -> "now"
                secs < 60 -> "${secs}s ago"
                secs < 3600 -> "${secs / 60}m ago"
                secs < 86_400 -> "${secs / 3600}h ago"
                else -> "${secs / 86_400}d ago"
            }
        }

        private fun launchIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
