package tech.acab.app.ui

import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType

/** Synthetic category key for the user's own watchlist lens. A detection belongs here when it
 * was filed by the firmware as the historical WATCHED type OR its address is starred right now.
 * The second half matters because starring a tracker/camera must not erase its real category just
 * to make it appear in this lens; the first preserves already-filed t=8 evidence after unstar. */
internal const val WATCHED_FILTER_KEY = "WATCHED"

internal fun Detection.isWatchedFilterMember(watchedMacs: Set<String>): Boolean =
    type == DeviceType.WATCHED || mac.lowercase() in watchedMacs

/** Category membership shared by the Log and Map. WATCHED is an overlay lens; every other key is
 * the detection's ordinary category and therefore stays mutually exclusive. */
internal fun Detection.matchesCategoryFilter(
    category: String?,
    watchedMacs: Set<String>,
): Boolean = category == null || if (category == WATCHED_FILTER_KEY) {
    isWatchedFilterMember(watchedMacs)
} else {
    type.category == category
}

internal fun watchedDetectionCount(rows: List<Detection>, watchedMacs: Set<String>): Int =
    rows.count { it.isWatchedFilterMember(watchedMacs) }
