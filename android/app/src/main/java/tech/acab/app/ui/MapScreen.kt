package tech.acab.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import tech.acab.app.BuildConfig
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import java.io.File
import org.osmdroid.config.Configuration
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Overlay
import org.osmdroid.views.overlay.Polygon
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.mylocation.GpsMyLocationProvider
import org.osmdroid.views.overlay.mylocation.MyLocationNewOverlay
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.FollowEvidence
import tech.acab.app.model.validCoord
import tech.acab.app.net.AlprStore
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import tech.acab.app.ui.theme.Acab
import tech.acab.app.model.displayName

/** AND-PERF-1: hard cap on detection overlays drawn in one viewport rebuild, so a huge log
 *  can't rebuild thousands of markers on every ~3 Hz emission. */
private const val MAP_MARKER_CAP = 600

/** Cheap overlay rebuild key. [plan] is intentionally compared by identity: its nested groups can
 * contain the entire retained feed (up to FEED_CAP rows, AcabBleManager), and walking those IDs
 * just to discover a projection-cache hit would put a feed-sized allocation back on every RSSI
 * publication. Identity loses nothing: MapRenderPlanCache hands back the prior instance for a
 * structurally equal plan, so a new instance is always a changed plan. No RSSI field at all: the
 * one overlay RSSI can move, the no-GPS drone ring, is resized in place by the pass under the
 * rebuild gate (see [DrawnRing]), so a signal change never tears the other overlays down.
 * Internal rather than private only so MapProjectionTest can pin that every field moves the key. */
internal class MapOverlaySignature(
    private val plan: MapRenderPlan,
    private val zoomBucket: Int,
    private val showBreadcrumbs: Boolean,
    private val showLabels: Boolean,
    private val spatialRevision: Long,
    private val ageMinute: Long,
) {
    override fun equals(other: Any?): Boolean = other is MapOverlaySignature &&
        plan === other.plan && zoomBucket == other.zoomBucket &&
        showBreadcrumbs == other.showBreadcrumbs && showLabels == other.showLabels &&
        spatialRevision == other.spatialRevision && ageMinute == other.ageMinute

    override fun hashCode(): Int = System.identityHashCode(plan)
}

/** A row belongs in the map feed when it can produce at least one honest overlay. Operator
 * coordinates are Remote ID telemetry and therefore only meaningful on a drone row. Keeping an
 * operator-only drone here lets the later viewport pass emit its OP marker and accessible list
 * entry even when aircraft and observer coordinates are unavailable. */
internal fun hasMapRepresentation(
    type: DeviceType,
    primary: Pair<Double, Double>?,
    pilotLat: Double?,
    pilotLon: Double?,
): Boolean = mapRepresentationCoord(type, primary, pilotLat, pilotLon) != null

/** Coordinate used to establish the initial camera frame. Prefer the detection/observer pin;
 * an operator-only drone falls back to its valid Remote ID operator position so the map does not
 * remain centered somewhere unrelated with its sole honest marker offscreen. */
internal fun mapRepresentationCoord(
    type: DeviceType,
    primary: Pair<Double, Double>?,
    pilotLat: Double?,
    pilotLon: Double?,
): Pair<Double, Double>? = when {
    primary != null && validCoord(primary.first, primary.second) -> primary
    type == DeviceType.DRONE && validCoord(pilotLat, pilotLon) -> pilotLat!! to pilotLon!!
    else -> null
}

/** iOS-parity "you are here" marker: a blue fill inside a white ring with a soft shadow, drawn to
 *  a bitmap so it can replace osmdroid's default person/arrow icon on MyLocationNewOverlay. Matches
 *  the look of the iOS map's native UserAnnotation dot. */
private fun userLocationDot(density: Float): Bitmap {
    fun dp(v: Float) = v * density
    val size = dp(26f).toInt().coerceAtLeast(1)
    val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val cx = size / 2f
    val cy = size / 2f
    val p = Paint(Paint.ANTI_ALIAS_FLAG)
    p.color = android.graphics.Color.argb(70, 0, 0, 0)      // soft drop shadow
    c.drawCircle(cx, cy + dp(0.5f), dp(9.5f), p)
    p.color = android.graphics.Color.WHITE                  // white ring
    c.drawCircle(cx, cy, dp(9f), p)
    p.color = android.graphics.Color.parseColor("#0A84FF")  // iOS system blue fill
    c.drawCircle(cx, cy, dp(6.5f), p)
    return bmp
}

private val osmConfigured = java.util.concurrent.atomic.AtomicBoolean(false)

/** Either location grant is enough to place phone-positioned detections and draw the blue dot. */
private fun hasLocationPerm(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED ||
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED

/** One-time osmdroid setup, run from each MapView factory before the first MapView (both map
 *  surfaces call it). The tile-cache caps are set BEFORE load() on purpose: load() ends with a
 *  free-space clamp that shrinks the CURRENT maxBytes when the device is nearly full, and load()
 *  does not read the cache-size fields back from prefs, so this order keeps the 100 MB bound while
 *  still letting the clamp shrink it further. Skipping load() entirely (an older behavior) meant
 *  the clamp never ran and osmdroid grew toward its 600 MB default tile DB.
 *
 *  STORAGE IS PINNED to [osmdroidBaseDir] (app-private internal storage). The tile cache is a
 *  record of every area the user viewed, so it must never land on shared or removable storage.
 *  Unpinned, osmdroid 6.1.20 picks the writable storage with the most free space, which can be an
 *  app-specific EXTERNAL files dir. Order matters, because DefaultConfigurationProvider.load()
 *  (read from the 6.1.20 bytecode) behaves in two ways:
 *   - When the "osmdroid" prefs hold an `osmdroid.basePath` that still exists on disk, load()
 *     REPLACES the in-memory base and tile paths with the stored `osmdroid.basePath` /
 *     `osmdroid.cachePath`, so a value set before load() alone loses to an earlier launch's pick.
 *   - Otherwise (first run, or the stored dir is gone) it asks getOsmdroidBasePath/TileCache,
 *     which return a pre-set field without scanning storage, but only if that field's dir EXISTS;
 *     a missing one makes load() fall back to filesDir/osmdroid and persist THAT path.
 *  So the tile dir is created first (one mkdirs, which also creates the base), the stored keys
 *  are rewritten to our dir (apply() updates the in-memory prefs map synchronously, which load()
 *  then reads), the fields are pre-set, and both are set again after load() in case osmdroid's
 *  fallback (base unwritable) still chose another dir.
 *
 *  The user agent is set AFTER load() for the same reason: load() always overwrites it, with the
 *  bare package name on first run and with the stored `osmdroid.userAgentValue` afterwards. OSM's
 *  tile usage policy requires a User-Agent that identifies the application and gives a way to
 *  make contact; a bare package name satisfies neither.
 *
 *  Disk touch on the calling (main) thread is limited to what load() already did plus one
 *  noBackupFilesDir lookup and one mkdirs (a no-op stat after the first launch). Deleting stale stores is [sweepStaleOsmdroidStores]'s job, off main. */
internal fun configureOsmdroid(context: Context) {
    if (!osmConfigured.compareAndSet(false, true)) return
    val cfg = Configuration.getInstance()
    val base = osmdroidBaseDir(context)
    val tiles = osmdroidTileDir(base)
    tiles.mkdirs()
    val prefs = context.getSharedPreferences("osmdroid", Context.MODE_PRIVATE)
    if (prefs.getString(OSMDROID_PREF_BASE, null) != base.absolutePath ||
        prefs.getString(OSMDROID_PREF_CACHE, null) != tiles.absolutePath) {
        prefs.edit()
            .putString(OSMDROID_PREF_BASE, base.absolutePath)
            .putString(OSMDROID_PREF_CACHE, tiles.absolutePath)
            .apply()
    }
    cfg.setOsmdroidBasePath(base)
    cfg.setOsmdroidTileCache(tiles)
    cfg.tileFileSystemCacheMaxBytes = 100L * 1024 * 1024
    cfg.tileFileSystemCacheTrimBytes = 80L * 1024 * 1024
    cfg.load(context, prefs)
    cfg.setOsmdroidBasePath(base)
    cfg.setOsmdroidTileCache(tiles)
    // Version comes from BuildConfig so it cannot drift from build.gradle.kts, which a hardcoded
    // string inevitably would.
    cfg.userAgentValue = "tech.acab.app/${BuildConfig.VERSION_NAME} (+https://soyboi.tech)"
}

/** The prefs keys DefaultConfigurationProvider.load() reads and writes (osmdroid 6.1.20). */
private const val OSMDROID_PREF_BASE = "osmdroid.basePath"
private const val OSMDROID_PREF_CACHE = "osmdroid.cachePath"

/** osmdroid's dir name under whichever root it picks, and SqlTileWriter's subdir (6.1.20). */
private const val OSMDROID_DIR = "osmdroid"
private const val OSMDROID_TILES_DIR = "tiles"

/** Pinned osmdroid base: app-private internal storage, never external. noBackupFilesDir rather
 *  than filesDir: backup is already disabled app-wide (allowBackup=false), but no_backup keeps a
 *  record of viewed areas out of any backup or device transfer even if that ever changes, and it
 *  is not cacheDir, so the tile DB does not sit beside the FileProvider-exposed export folders. */
internal fun osmdroidBaseDir(context: Context): File = File(context.noBackupFilesDir, OSMDROID_DIR)

internal fun osmdroidTileDir(base: File): File = File(base, OSMDROID_TILES_DIR)

/**
 * Every place an earlier build's unpinned osmdroid could have put its store, given the roots it
 * chose from, minus [pinnedBase]. osmdroid 6.1.20's StorageUtils lists filesDir, the databases
 * dir and each mounted getExternalFilesDirs(null) entry, and falls back to
 * getExternalFilesDir(DIRECTORY_PICTURES); shared storage was never writable (the app has never
 * held a storage permission). Pure over the roots it is given.
 */
internal fun staleOsmdroidStores(roots: List<File?>, pinnedBase: File): List<File> {
    val pinned = pinnedBase.absoluteFile
    return roots.filterNotNull()
        .map { File(it, OSMDROID_DIR).absoluteFile }
        .filter { it != pinned }
        .distinct()
}

/** Recursively delete each of [dirs] that exists and is named like an osmdroid store. The name
 *  check keeps a wrong root from ever turning this into a wipe of an unrelated folder. Returns
 *  the dirs removed. File I/O: off the main thread only. */
internal fun deleteOsmdroidStores(dirs: List<File>): List<File> = dirs.filter { dir ->
    (dir.name == OSMDROID_DIR || dir.name == OSMDROID_TILES_DIR) && dir.exists() &&
        runCatching { dir.deleteRecursively() }.getOrDefault(false)
}

/**
 * Delete tile stores left outside [osmdroidBaseDir] by builds that did not pin it (possibly on
 * external storage). Cold path: AcabBleManager's init runs it on Dispatchers.IO at app start. It
 * never touches the pinned store, so it cannot race a live MapView. getExternalFilesDirs may
 * create the app-specific external dirs; osmdroid's own storage scan already did that on every
 * earlier install that opened the map.
 */
internal fun sweepStaleOsmdroidStores(context: Context) {
    val external = runCatching { context.getExternalFilesDirs(null).toList() }.getOrDefault(emptyList())
    val roots = buildList<File?> {
        add(context.filesDir)
        add(File(context.dataDir, "databases"))
        addAll(external)
        external.filterNotNull().forEach { add(File(it, android.os.Environment.DIRECTORY_PICTURES)) }
    }
    deleteOsmdroidStores(staleOsmdroidStores(roots, osmdroidBaseDir(context)))
}

/**
 * The real Clear log's tile wipe: the cached tiles are a record of the areas the user viewed.
 * File I/O and SQLite: off the main thread only.
 *
 * A live MapView survives this. When osmdroid was configured in this process, the rows are purged
 * through SqlTileWriter's shared connection and that connection is closed (refreshDb) before the
 * files go, so nothing keeps reading the old data. SqlTileWriter reopens lazily and mkdirs the
 * tile dir first (getDb), a failed save is caught inside saveFile, and the SQL cache loader
 * catches Throwable. A tile thread that reopens between refreshDb and the delete holds an
 * unlinked, already-purged file: its next write fails read-only, which SqlTileWriter's
 * catchException treats as non-functional and answers with refreshDb, so it costs a few
 * uncached tiles, never a crash (all per the 6.1.20 bytecode).
 * The pinned base dir itself is kept (only its tiles subdir goes). Stale stores are swept too.
 */
internal fun clearOsmdroidTileCache(context: Context) {
    if (osmConfigured.get()) {
        runCatching {
            org.osmdroid.tileprovider.modules.SqlTileWriter().run {
                purgeCache()
                refreshDb()
            }
        }
    }
    deleteOsmdroidStores(listOf(osmdroidTileDir(osmdroidBaseDir(context))))
    sweepStaleOsmdroidStores(context)
}

/** Mirrors iOS clusterable(_:): the types that arrive in volume (ambient nearby devices,
 *  trackers, consumer glasses, network cams) collapse into grid bubbles so a dense area
 *  can't spray hundreds of individual pins.
 *
 *  This predicate is NOT the whole clustering gate on Android, so do not read it as one. At
 *  street zoom it is: fixed surveillance infrastructure (Flock ALPR, Raven, body cam) and drones
 *  pin individually, exactly as on iOS. Below MAP_FAR_ZOOM, [buildMapRenderPlan] additionally
 *  folds every non-RID row into the adaptive grid - see its KDoc for why, MapProjectionTest's
 *  farZoomCombinesInfrastructureAndPreservesMembersAndCategoryCounts for the pinned behaviour,
 *  and the "far zooms combine dense points" line in the Map options sheet for what the user is
 *  told. iOS has no far-zoom clause: it keeps individual infra artwork at every span and narrows
 *  its annotation budget instead (MapTabView.swift mapInfrastructurePinCap), which drops the
 *  lowest-priority infra pins outright rather than bucketing them. Drones are exempt on both
 *  sides. */
internal fun clusterable(type: DeviceType): Boolean =
    type == DeviceType.NEARBY_DEVICE || type == DeviceType.TRACKER ||
        type == DeviceType.GLASSES || type == DeviceType.NETWORK_CAMERA

// ---------------------------------------------------------------------------------------------
// SAME-COORDINATE PIN GROUPING
//
// Everything heard from one standing position is stamped with the same phone fix, so the
// individually-pinned rows land on top of each other exactly. osmdroid draws overlays in list
// order and hit-tests topmost-first, so the LAST marker added won every tap; the feed is
// newest-first, so the last one added was the OLDEST sighting. One pin per spot settles the
// draw order, the tap and the missing count cue at once.
//
// WHERE IT LIVES: buildMapRenderPlan (MapProjection.kt). At street zoom it drops every row that
// does not grid-cluster onto a PIN_GROUP_EPSILON_DEG cell and SymbolBucket.finish orders each
// cell with sameSpotOrder; the draw loop in the update block below re-applies that order through
// orderSameSpotMembers on the live last-seen read it takes per rebuild. A group of ONE keeps its
// member's own coordinate, so a lone pin renders exactly where it always has; a group of several
// takes the lead's coordinate rather than an average, because the members are the same spot by
// construction and averaging would move the pin off the position the lead was stamped with. The
// pure inputs stay here beside clusterable: the tolerance and the priority table.
//
// EVERY individually-pinned type takes part, drones included: the set is exactly the rows that
// do not grid-cluster, so at street zoom the split is !clusterable(type) (below MAP_FAR_ZOOM only
// drones stay off the grid, see clusterable) and there is no second list to keep in step. A
// drone PIN anchors nothing. Its flight path, operator tether, launch glyph, no-GPS ring
// and operator marker are each emitted by a pass over `droneRows` in the update block below, and
// none of those passes asks whether that row's pin won its group, so an absorbed drone keeps
// every piece of its artwork. What grouping buys the drone is reachability: at a shared spot only
// one pin can be on top and the covered one takes no taps at all, whereas a grouped member is
// reachable through the badged pin's member sheet. A drone alone at its coordinate is a group of
// one and renders exactly as it did before. This rule is shared with iOS.
// ---------------------------------------------------------------------------------------------

/** How close two pins have to be before they are the same spot. 1e-5 degrees is about 1.1 m of
 *  latitude, which is below any GPS fix's own error, so nothing this merges was ever separable.
 *
 *  THE SHARED NUMBER: iOS groups on the same tolerance and both suites assert it.
 *
 *  THE RULE, stated exactly so both platforms group identically: each coordinate is floored onto
 *  a grid of this size and rows sharing a cell are one group. Rows carrying the IDENTICAL
 *  coordinate, which is the case this exists for, always land in the same cell. Two rows a
 *  fraction of a cell apart but straddling a cell edge do not group, and that is accepted: the
 *  tolerance is slack for float drift, not a clustering radius. */
internal const val PIN_GROUP_EPSILON_DEG = 1e-5

/** Which member of a same-spot group draws its pin, lowest first. A body cam must never end up
 *  hidden under an older, less important sighting, so the order is by what the user came here to
 *  see: their own watchlist hit first, then the fixed surveillance kinds in the order the app
 *  lists them everywhere else, then anything left over. Shared with iOS.
 *
 *  DRONE ranks here and reaches same-spot grouping (buildMapRenderPlan, MapProjection.kt) like
 *  every other individually-pinned type, so this rank decides real leads: a body cam sharing a
 *  drone's spot draws the pin, and the drone is a member of that pin's sheet. The order is
 *  applied through sameSpotOrder, the one copy for the projection and the draw loop. The table
 *  is also the cross-platform contract and both suites assert it, so a type quietly dropping out
 *  of one copy is exactly the drift this pairing exists to catch. */
internal fun infraPinPriority(type: DeviceType): Int = when (type) {
    DeviceType.WATCHED -> 0
    DeviceType.FLOCK_CAMERA -> 1
    DeviceType.FLOCK_RAVEN -> 2
    DeviceType.BODY_CAM -> 3
    DeviceType.DRONE -> 4
    else -> 5
}

// ---------------------------------------------------------------------------------------------
// PIN RECENCY
//
// A persisted pin from yesterday used to look exactly like a live hit. Three tiers, shared with
// iOS, decide how a pin presents. Presentation ONLY: the log's and Status's own recency rules,
// and the freeze-at-Stop behaviour, are untouched by any of this.
// ---------------------------------------------------------------------------------------------

/** How recently a pin's row was heard, which is all the map uses it for.
 *
 *  FRESH  full colour, and the platform's ping may run if it has one.
 *  RECENT full colour, no ping.
 *  STALE  dimmed and desaturated, no ping. Still tappable, still full size, still its own
 *         colour family. The tier dates a sighting; it never hides one.
 *
 *  Android draws the pin's pulse frozen into the bitmap rather than animating it, so there is no
 *  ping here to gate and FRESH and RECENT reach identical artwork on this platform. The three
 *  tiers are still the shared rule: the boundary that changes pixels on Android is the stale one. */
internal enum class PinAge { FRESH, RECENT, STALE }

/** Under this, a sighting is live enough to animate. THE SHARED NUMBER: iOS uses the same. */
internal const val PIN_FRESH_MAX_MS = 5 * 60_000L

/** Past this, a sighting is dimmed. THE SHARED NUMBER: iOS uses the same. */
internal const val PIN_RECENT_MAX_MS = 60 * 60_000L

/**
 * The tier for a pin whose row was last heard at [lastSeenMs], against wall clock [now].
 *
 * No stamp, or a zero one, answers RECENT. Never FRESH: an unknown time is not evidence of
 * liveness, and dressing one up as a live hit is the exact thing this whole signal exists to
 * stop. Never STALE either, because we have not established that it is old.
 *
 * A stamp AHEAD of [now] answers FRESH, matching the one-sided rule the detection store already
 * uses for staleness: a backward wall-clock step (an NTP correction) must not age live pins.
 */
internal fun pinAge(lastSeenMs: Long?, now: Long): PinAge = when {
    lastSeenMs == null || lastSeenMs <= 0L -> PinAge.RECENT
    now - lastSeenMs < PIN_FRESH_MAX_MS -> PinAge.FRESH
    now - lastSeenMs <= PIN_RECENT_MAX_MS -> PinAge.RECENT
    else -> PinAge.STALE
}

/**
 * The text a detection marker carries: the category its artwork is drawing, and how many rows it
 * stands for when it leads a same-spot group.
 *
 * NOT A USER-FACING CUE ON THIS PLATFORM, and nothing may be routed through it. osmdroid uses
 * Marker.title for one thing, its default title InfoWindow, and every detection marker consumes
 * its own tap (the click listener returns true), so that window never opens; osmdroid also draws
 * markers as overlays on ONE opaque surface and publishes no per-marker accessibility node, so no
 * screen reader reads this either. A previous round appended a "not heard in the last hour"
 * sentence here for the STALE tier and it reached nobody.
 *
 * The cues that DO reach the user: the group count is the badge composited into the pin bitmap
 * (PinBadgeFactory), the recency tier is the dimmed artwork, the screen-reader companion for the
 * whole map is the LIST chip's sheet, and a pin's age IN WORDS is in the dossier the tap opens,
 * whose "Last seen" row prints it via relativeAgo (DetailScreen.kt).
 */
internal fun pinTitle(category: String, groupSize: Int): String =
    if (groupSize <= 1) category else "$groupSize detections here, showing $category"

/** Rough RSSI -> distance (metres) for a no-GPS proximity ring. Uses a log-distance
 *  path-loss model, a ballpark, not a real measurement. */
private fun rssiRadiusMeters(rssi: Int): Double =
    Math.pow(10.0, (-50.0 - rssi) / 25.0).coerceIn(5.0, 600.0)   // TxPower -50 dBm, n ~ 2.5

/** A no-GPS drone ring as the last rebuild drew it: the Polygon osmdroid holds, the observer
 *  coordinate it is centred on, and the RSSI its radius was built from. The rebuild registers one
 *  per ring it draws; the pass under the rebuild gate resizes it when the RSSI moves, so a signal
 *  change redraws one polygon instead of tearing every overlay down. The radius stays the raw
 *  reading, as on iOS (`MapCircle(center: me, radius: rssiRadiusMeters(d.rssi))` in
 *  MapTabView.swift, where DroneOverlay.rendersSame puts that reading in the render key instead):
 *  a bars bucket would either leave the drawn radius outside the key or step it away from the iOS
 *  circle. */
private class DrawnRing(val polygon: Polygon, val center: GeoPoint, var rssi: Int)

/** Mutable camera memory for the osmdroid MapView, which is torn down whenever the Map tab
 *  leaves composition. A plain holder (not Compose state) so the per-gesture scroll/zoom events
 *  never recompose the screen; rememberSaveable snapshots it via [MapCameraSaver] at save time,
 *  so the camera survives tab switches, rotation and activity recreation. */
private class MapCamera {
    var has = false
    var lat = 0.0
    var lon = 0.0
    var zoom = 15.0
    var follow = true
}

private val MapCameraSaver = androidx.compose.runtime.saveable.listSaver<MapCamera, Double>(
    save = { c -> if (c.has) listOf(c.lat, c.lon, c.zoom, if (c.follow) 1.0 else 0.0) else emptyList() },
    restore = { l ->
        MapCamera().apply {
            if (l.size == 4) { has = true; lat = l[0]; lon = l[1]; zoom = l[2]; follow = l[3] == 1.0 }
        }
    },
)

/** Located detections dropped on a dark map, filterable by category. Non-RID pins use the phone
 *  position paired with their strongest located RSSI sample; drones use their broadcast coords.
 *  [focus] is a one-shot "open in map" jump from the dossier's location thumbnail: center
 *  close-in on that coordinate, then call [onFocusConsumed] so it never re-applies. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun MapScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit,
    focus: Pair<Double, Double>? = null,
    onFocusConsumed: () -> Unit = {},
) {
    val context = LocalContext.current
    val floatingInfoColors = mapInfoColors(Acab.palette)
    val dynamicRings by ble.mapDynamicRings.collectAsState()
    // The spatial revision this screen has INSTALLED, not the manager's live one. The live flow is
    // followed by coalesceDetectionRevisions (MapProjection.kt) under the row-count ceiling that
    // iOS applies through mapDetectionRefreshInterval: 0.3 s under 500 retained rows, up to 1.0 s
    // at 4,000. A burst of revisions lands as one snapshot per interval and its LAST revision
    // always lands (trailing edge). Pan, zoom, filter, scope, toggle and focus rebuilds never wait
    // on it: they run on the installed snapshot at once. Seeded from the live value so a tab return
    // starts from the current store rather than owing a wait to a coroutine that was cancelled.
    var mapEvidenceRev by remember { mutableLongStateOf(ble.spatialEvidenceRev.value) }
    LaunchedEffect(ble) {
        coalesceDetectionRevisions(
            revisions = ble.spatialEvidenceRev,
            installedRevision = mapEvidenceRev,
            rowCount = { ble.detections.value.size },
        ) { mapEvidenceRev = it }
    }
    val watchedList by ble.watched.collectAsState()
    val watchedMacs = remember(watchedList) {
        watchedList.mapTo(HashSet(watchedList.size)) { it.mac.lowercase() }
    }
    // Saveable (under the tab shell's SaveableStateProvider): a tab switch must not clear a lens.
    var filter by rememberSaveable { mutableStateOf<String?>(null) }   // category key (null = all)
    // Where the user last left the camera; re-applied when the MapView is rebuilt after a tab
    // switch or recreation, so the map stops snapping back to the default view.
    val camera = rememberSaveable(saver = MapCameraSaver) { MapCamera() }
    // Location permission decides which empty-state the map can honestly show. Re-checked on
    // resume so granting it in system Settings updates the copy without a relaunch.
    var hasLocationPermission by remember { mutableStateOf(hasLocationPerm(context)) }
    // Declared before the lifecycle observer below, which owns both the native MapView and its
    // location provider. AndroidView stays composed while the Activity is stopped, so onRelease is
    // not a lifecycle pause.
    val myLocation = remember { mutableStateOf<MyLocationNewOverlay?>(null) }
    val liveMap = remember { mutableStateOf<MapView?>(null) }
    val mapInfoWindow = remember { arrayOfNulls<DarkMapInfoWindow>(1) }
    val mapResumed = remember { booleanArrayOf(false) }
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            when (e) {
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    val granted = hasLocationPerm(context)
                    if (!mapResumed[0]) {
                        liveMap.value?.onResume()
                        mapResumed[0] = true
                    }
                    if (granted) myLocation.value?.enableMyLocation()
                    else myLocation.value?.disableMyLocation()
                    hasLocationPermission = granted
                }
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE -> {
                    myLocation.value?.disableMyLocation()
                    if (mapResumed[0]) liveMap.value?.onPause()
                    mapResumed[0] = false
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(obs)
            myLocation.value?.disableMyLocation()
            if (mapResumed[0]) liveMap.value?.onPause()
            mapResumed[0] = false
        }
    }
    // F19: tapped cluster bubble opens a member-list sheet (a same-spot clump can't split by zoom)
    var clusterMembers by remember { mutableStateOf<List<Detection>?>(null) }
    var memberSheetIsViewport by remember { mutableStateOf(false) }
    // IDs whose actual detection/operator pin is inside the current viewport. Updated by the
    // debounced AndroidView pass so TalkBack gets a companion list even while the BLE feed is
    // quiet and osmdroid itself exposes only one opaque surface.
    var visibleDetectionIds by remember { mutableStateOf<List<String>>(emptyList()) }
    // F18: the legend rests as a small info chip; expands on tap, auto-shows while ALPR loads
    var legendExpanded by remember { mutableStateOf(false) }
    // One readable options sheet owns history scope, display choices and reference layers. Keeping
    // those controls together avoids two tiny floating menus that overlap the map and each other.
    var optionsOpen by remember { mutableStateOf(false) }
    val mapPrefs = remember { context.getSharedPreferences("acab.map", Context.MODE_PRIVATE) }
    var showBreadcrumbs by remember { mutableStateOf(mapPrefs.getBoolean("show_breadcrumbs", true)) }
    var showLabels by remember { mutableStateOf(mapPrefs.getBoolean("show_labels", false)) }
    var historyScope by remember {
        mutableStateOf(
            runCatching {
                MapHistoryScope.valueOf(mapPrefs.getString("history_scope", null) ?: "Recent")
            }.getOrDefault(MapHistoryScope.Recent),
        )
    }
    // A Recent row can age out while the radio is quiet. Thirty seconds is plenty for a 15-minute
    // lens and avoids a permanent per-second recomposition. This is the invalidation tick ONLY;
    // the comparison clock is recentScopeClock in MapProjection.kt (see scopedIds below).
    var historyNow by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(historyScope) {
        historyNow = System.currentTimeMillis()
        while (true) {
            delay(30_000L)
            historyNow = System.currentTimeMillis()
        }
    }
    // A dossier can open an old/undated row from the full Logbook. Clear an unrelated category
    // and reveal all history before centering, while leaving the manager's mute projection intact.
    LaunchedEffect(focus) {
        if (focus != null) {
            filter = null
            historyScope = MapHistoryScope.All
            mapPrefs.edit().putString("history_scope", historyScope.name).apply()
            historyNow = System.currentTimeMillis()
        }
    }
    // one-shot pre-fix centering flag; a plain holder (not Compose state) so setting it
    // inside the update pass doesn't schedule another pass
    val centeredOnce = remember { booleanArrayOf(false) }
    // AND-PERF-3: rebuild gate. The ~3 Hz publishes re-run the update lambda even when the
    // visible set didn't change (an ambient RSSI refresh publishes a whole new list), and a
    // full teardown/realloc of up to ~1200 overlays per pass is the map's biggest main-thread
    // cost. Plain holders, not Compose state, same reason as centeredOnce.
    val rebuildSig = remember { arrayOfNulls<Any>(1) }
    val projectionCache = remember { MapRenderPlanCache() }
    // The no-GPS drone rings the last rebuild drew, by drone id. Plain holder, same reason: it is
    // written from the update pass. Cleared and refilled by every rebuild, resized in place
    // between rebuilds (see DrawnRing).
    val drawnRings = remember { HashMap<String, DrawnRing>() }
    var renderStats by remember {
        mutableStateOf(MapRenderPlan(emptyList(), emptyList(), emptyList(), 0, 0, 0, 0, 0))
    }
    // osmdroid gestures do not inherently re-run AndroidView.update. Incremented once after a
    // short quiet period so viewport culling and zoom-dependent clustering also refresh when the
    // detection feed itself is quiet. The pending Runnable is removed when the MapView releases.
    // READ inside the update block below, and that read is the whole mechanism: AndroidView runs
    // update under a snapshot observer, so without it this counter invalidates nothing and a pan
    // into a culled region draws no pins until something else recomposes the screen.
    var viewportRevision by remember { mutableIntStateOf(0) }
    val viewportRefresh = remember { arrayOfNulls<Runnable>(1) }
    val markers = rememberCategoryMarkers()   // category pins, built once
    val labeledMarkers = rememberLabeledCategoryMarkers(markers)   // + under-icon type tag, for showLabels
    // STALE-tier twins of both sets. Built alongside the full-colour ones and remembered the same
    // way, so switching a pin's tier is a map lookup on the rebuild path and never a redraw.
    val dimMarkers = rememberDimCategoryMarkers()
    val labeledDimMarkers = rememberLabeledCategoryMarkers(dimMarkers)
    val pinArt = remember(markers, labeledMarkers, dimMarkers, labeledDimMarkers) {
        MapPinArt(markers, dimMarkers, labeledMarkers, labeledDimMarkers)
    }
    val pinBadges = rememberPinBadgeFactory()
    val operatorMarker = rememberOperatorMarker()
    val launchMarker = rememberLaunchMarker()   // small distinct glyph for a drone track's start

    val clusterFactory = rememberClusterMarkerFactory()

    // known-ALPR reference layer (ON by default, user-toggleable, OSM/DeFlock), managed as its own overlay
    val alpr = remember { AlprStore.getInstance(context) }
    val alprEnabled by alpr.enabled.collectAsState()
    val alprNodes by alpr.nodes.collectAsState()
    val alprLoading by alpr.loading.collectAsState()
    val alprOutcome by alpr.lastOutcome.collectAsState()
    val alprDownloading by alpr.downloading.collectAsState()
    val alprShowUnverified by alpr.showUnverified.collectAsState()
    val alprUnverifiedCount by alpr.unverifiedCount.collectAsState()
    // rawTier is published before alprNodes, so the nodes flow is the recomposition trigger and
    // these counts always describe the same parsed dataset - which is why it is also the memo
    // key. rawTier holds one entry per mapped node and is not Compose state, so unmemoised these
    // scans re-ran on every recomposition of the whole screen, i.e. with the detection feed, for
    // a legend that rests collapsed. The same hazard AlprDataset already solved for
    // unverifiedCount by publishing it as a flow. One grouped pass here, rather than one scan
    // per tier.
    val alprTierCounts = remember(alprNodes) {
        val tally = IntArray(5)
        for (t in alpr.rawTier) {
            when (t) {
                0 -> tally[0]++
                1 -> tally[1]++
                2 -> tally[2]++
                ALPR_TIER_LEGACY_FORMAT -> tally[3]++
                else -> tally[4]++
            }
        }
        tally
    }
    val alprTier0Count = alprTierCounts[0]
    val alprTier1Count = alprTierCounts[1]
    val alprTier2Count = alprTierCounts[2]
    val alprLegacyFormatCount = alprTierCounts[3]
    val alprOtherTierCount = alprTierCounts[4]
    val alprMarker = rememberAlprMarker()
    val alprMarkerUnverified = rememberAlprMarker(confirmed = false)
    // RING-PEEK: the wide variants, drawn for a mapped camera that a live detection pin is
    // standing on. Each is remembered per density, so the bundle's identity is stable and the
    // layer's update early-out still holds.
    val alprMarkerPeek = rememberAlprMarker(peek = true)
    val alprMarkerUnverifiedPeek = rememberAlprMarker(confirmed = false, peek = true)
    val alprIcons = remember(alprMarker, alprMarkerUnverified, alprMarkerPeek,
                            alprMarkerUnverifiedPeek) {
        AlprRingIcons(alprMarker, alprMarkerUnverified, alprMarkerPeek, alprMarkerUnverifiedPeek)
    }
    val alprHolder = remember { AlprOverlayHolder() }
    // How many rings are drawing wide right now, so the legend explains that size only while one
    // is on screen. Pushed from the layer's cull pass, and only when the number changes.
    var alprPeekCount by remember { mutableIntStateOf(0) }
    // Coordinates of the detection pins the last marker rebuild drew (interleaved lat/lon), handed
    // to the ALPR layer for the peek test. Held in a plain array holder, not Compose state: this is
    // an output of the update pass, and writing state from there would schedule another one.
    val peekPins = remember { arrayOf(DoubleArray(0)) }
    // "Too far out for ALPR pins", hoisted so the hint can react to zoom (osmdroid won't
    // recompose). A Boolean written only when it flips, so a pan/zoom gesture's stream of
    // events can't recompose the screen (and re-run the marker rebuild) per event.
    // Seeded from the RESTORED camera, never a bare false: a tab return re-applies camera.zoom
    // in the MapView factory, and a restored zoom below MIN_ZOOM with a false seed left the
    // ALPR layer silently drawing nothing (no pins, no hint) until the next zoom gesture
    // finally flipped the listener.
    var zoomedOutTooFar by remember {
        mutableStateOf(camera.has && camera.zoom < AlprOverlayHolder.MIN_ZOOM)
    }
    var emptyDismissed by remember { mutableStateOf(false) }   // R12: matches iOS dismissible empty banner

    // Spatial evidence and active membership share one coalesced revision in the manager, and this
    // screen installs it on the ceiling above. Routine RSSI/count packets still refresh the no-GPS
    // ring and tapped rows, but reuse this immutable coordinate projection and never retake
    // storeLock per row. Keyed on the installed revision: the snapshot reads the store as it stands
    // when it runs, so every revision the ceiling skipped is already inside it.
    val locatedEvidence = remember(mapEvidenceRev) {
        ble.mapEvidenceSnapshot().filter { row ->
            val d = row.detection
            hasMapRepresentation(d.type, row.coordinate, d.pilotLat, d.pilotLon)
        }
    }
    val located = remember(locatedEvidence) { locatedEvidence.map { it.detection } }
    // The geometry snapshot intentionally ignores ordinary RSSI/count publishes, but Recent
    // membership cannot reuse the last-seen values captured with it forever: a stationary device
    // heard continuously would otherwise age out after 15 minutes. Refresh timing in one lock on
    // the slow scope tick. `scopedIds` has structural equality, so an unchanged membership keeps
    // the same scopedEvidence identity and does not invalidate the projection cache.
    val latestMapLastSeen = remember(locatedEvidence, historyScope, historyNow) {
        if (historyScope == MapHistoryScope.Recent) ble.mapLastSeenSnapshot(located)
        else emptyMap()
    }
    val scopedIds = remember(locatedEvidence, historyScope, latestMapLastSeen, historyNow) {
        // historyNow is ONLY the invalidation tick in the keys above; the comparison clock is a
        // wall-clock read inside recentScopeIds (recentScopeClock in MapProjection.kt, pinned by
        // MapProjectionTest). A row heard since the last tick carries a stamp NEWER than
        // historyNow, and mapHistoryIncludes rejects a stamp ahead of `now`, so a tick-based
        // comparison would drop exactly the freshest sightings out of the default Recent lens for
        // up to 30 seconds. recentScopeIds takes no `now` so the tick cannot be handed in.
        recentScopeIds(locatedEvidence, historyScope, latestMapLastSeen)
    }
    val scopedEvidence = remember(locatedEvidence, historyScope, scopedIds) {
        if (historyScope == MapHistoryScope.All) locatedEvidence
        else {
            val allowed = scopedIds.toHashSet()
            locatedEvidence.filter { it.detection.id in allowed }
        }
    }
    val shownEvidence = remember(scopedEvidence, filter, watchedMacs) {
        filter?.let { f ->
            scopedEvidence.filter { it.detection.matchesCategoryFilter(f, watchedMacs) }
        } ?: scopedEvidence
    }
    val shown = remember(shownEvidence) { shownEvidence.map { it.detection } }
    val mapCoords = remember(locatedEvidence) {
        locatedEvidence.mapNotNull { row -> row.coordinate?.let { row.detection.id to it } }.toMap()
    }
    val shownById = remember(shownEvidence) {
        shownEvidence.associate { it.detection.id to it.detection }
    }
    val visibleDetections = remember(shownById, visibleDetectionIds) {
        visibleDetectionIds.mapNotNull(shownById::get)
    }
    val catCounts = remember(scopedEvidence, watchedMacs) {
        val scoped = scopedEvidence.map { it.detection }
        scoped.groupingBy { it.type.category }.eachCount().toMutableMap().apply {
            // WATCHED is an overlapping lens: a currently starred tracker/camera stays in its
            // real category and appears here too; a historical t=8 row is counted once.
            put(WATCHED_FILTER_KEY, watchedDetectionCount(scoped, watchedMacs))
        }
    }
    fun count(cat: String) = catCounts[cat] ?: 0

    // A current star can disappear without the detection feed changing. Do not strand the map
    // behind an invisible zero-count WATCHED lens; historical WATCHED rows keep it alive.
    LaunchedEffect(filter, watchedMacs, locatedEvidence) {
        if (filter == WATCHED_FILTER_KEY &&
            watchedDetectionCount(scopedEvidence.map { it.detection }, watchedMacs) == 0) {
            filter = null
        }
    }

    // Markers outlive skipped rebuild passes, so a tap resolves the live row by id instead of
    // handing the dossier the snapshot captured whenever the marker was last built.
    fun selectFresh(d: Detection) {
        val id = d.id
        onSelect(ble.detections.value.firstOrNull { it.id == id } ?: d)
    }

    // The accessible one-line read of the whole surface: TalkBack cannot inspect tile pixels,
    // so the map names its own state (count, or why it is empty).
    val mapDescription = when {
        !hasLocationPermission -> buildString {
            append("Map. Phone location is off. ")
            if (shown.isNotEmpty()) {
                append("${shown.size} displayed of ${located.size} retained detection")
                if (located.size != 1) append('s')
                append(". ")
            }
            append("New phone-positioned detections cannot be added; drones broadcasting their own coordinates can still appear.")
        }
        located.isEmpty() -> "Map. No located detections yet."
        else -> buildString {
            append("Map. ${shown.size} displayed of ${located.size} retained detections")
            filter?.let { append(", filter $it") }
            append(if (historyScope == MapHistoryScope.Recent) ", recent fifteen minutes." else ", all history.")
            if (renderStats.simplifiedRows > 0 || renderStats.omittedRows > 0) {
                append(" ${renderStats.symbols.size} map symbols; ${renderStats.simplifiedRows} rows simplified")
                if (renderStats.omittedRows > 0) append(", ${renderStats.omittedRows} omitted at this zoom")
                append('.')
            }
        }
    }

    Box(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxSize(),
        ) {
        AndroidView(
            // clipToBounds because Compose does NOT clip an AndroidView's own drawing to its
            // layout slot, and osmdroid's MapView paints its tile canvas from the WINDOW origin
            // at window size rather than from the slot it was measured into. On the compact
            // branch the slot already is the full width, so the spill has nothing to cover and
            // the bug is invisible; on the >= 840.dp branch the slot is inset by the
            // NavigationRail and the SampleDataBanner, and the tiles painted straight over both,
            // leaving a tablet user on the Map tab with no visible navigation at all (the rail
            // still took touches, so it read as the app losing its own chrome). Compose's own
            // layout was never wrong here - the rail and banner keep their correct semantics
            // bounds throughout - so clip the spill rather than move anything.
            modifier = Modifier.fillMaxSize().clipToBounds()
                .semantics { contentDescription = mapDescription },
            factory = { ctx ->
                // osmdroid setup (user agent + bounded tile cache) MUST land before the first tile
                // fetch, and the factory is the last point before MapView is constructed. It used
                // to sit in a remember{} in composition, which lint flags as a side effect in
                // remember (it is: remember is for caching, not for running things). Idempotent
                // via compareAndSet, so calling it per factory is free.
                configureOsmdroid(ctx)
                MapView(ctx).apply {
                    liveMap.value = this
                    if (lifecycleOwner.lifecycle.currentState.isAtLeast(
                            androidx.lifecycle.Lifecycle.State.RESUMED)) {
                        onResume()
                        mapResumed[0] = true
                    }
                    setTileSource(TileSourceFactory.MAPNIK)
                    // F17/R4: MAPNIK tiles are light; the one shared dark-tile filter (defined in
                    // DetailScreen.kt) inverts + desaturates so this map and the detail mini-map
                    // render the identical tint.
                    overlayManager.tilesOverlay.setColorFilter(osmDarkTileFilter)
                    setMultiTouchControls(true)
                    // No zoom buttons: osmdroid's defaults sat over the "© OpenStreetMap contributors"
                    // line, and pinch-zoom is the primary gesture (the iOS map shows no zoom controls
                    // either). Hide rather than reposition.
                    zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
                    // Restore the last camera when this MapView is a rebuild (tab switch,
                    // rotation); a truly fresh session keeps the old default.
                    controller.setZoom(if (camera.has) camera.zoom else 15.0)
                    if (camera.has) {
                        controller.setCenter(GeoPoint(camera.lat, camera.lon))
                        centeredOnce[0] = true
                    }
                    // "you are here" dot; centers and follows once a fix lands.
                    // osmdroid does nothing without permission, so this is safe
                    // even before location is granted.
                    val self = MyLocationNewOverlay(GpsMyLocationProvider(ctx), this).apply {
                        // iOS-style blue dot instead of osmdroid's default person/arrow, so "you are
                        // here" matches the iOS map's UserAnnotation. Same dot when a heading exists
                        // (a circle looks identical rotated), both anchored dead-center.
                        val dot = userLocationDot(ctx.resources.displayMetrics.density)
                        setPersonIcon(dot); setDirectionIcon(dot)
                        setPersonAnchor(0.5f, 0.5f); setDirectionAnchor(0.5f, 0.5f)
                        if (mapResumed[0] && hasLocationPerm(ctx)) enableMyLocation()
                        // A restored camera the user had panned away from must not snap back to
                        // the phone on the next fix; follow resumes only if it was on before.
                        if (!camera.has || camera.follow) enableFollowLocation()
                    }
                    overlays.add(self)
                    myLocation.value = self
                    val darkInfo = DarkMapInfoWindow(this).also {
                        it.applyColors(floatingInfoColors)
                    }
                    mapInfoWindow[0] = darkInfo
                    alprHolder.attach(this, darkInfo)   // known-ALPR layer + shared dark callout
                    // Only fires when the count changes, so a pan that leaves the number alone
                    // costs no recomposition; the pass it recomposes into early-outs of both the
                    // marker rebuild and the ALPR update, so this cannot feed itself.
                    alprHolder.onPeekCount = { alprPeekCount = it }
                    // mirror the zoom floor into Compose state so the ALPR hint stays live;
                    // write only on a flip so gestures don't recompose per event. The camera
                    // memory rides the same listener: plain field writes, zero recompositions.
                    addMapListener(object : MapListener {
                        private fun sync(): Boolean {
                            val out = zoomLevelDouble < AlprOverlayHolder.MIN_ZOOM
                            if (out != zoomedOutTooFar) zoomedOutTooFar = out
                            camera.has = true
                            camera.lat = mapCenter.latitude
                            camera.lon = mapCenter.longitude
                            camera.zoom = zoomLevelDouble
                            camera.follow = self.isFollowLocationEnabled
                            viewportRefresh[0]?.let { removeCallbacks(it) }
                            val refresh = Runnable { viewportRevision++ }
                            viewportRefresh[0] = refresh
                            postDelayed(refresh, 140L)
                            return false
                        }
                        override fun onScroll(event: ScrollEvent?): Boolean = sync()
                        override fun onZoom(event: ZoomEvent?): Boolean = sync()
                    })
                }
            },
            update = { map ->
                // The InfoWindow is a native Android view, outside Compose's color propagation.
                // Reapply when the app/system contrast preference swaps Acab palettes.
                mapInfoWindow[0]?.applyColors(floatingInfoColors)
                // The gesture revision, read for its SNAPSHOT SUBSCRIPTION and nothing else. This
                // block runs under a snapshot observer, so reading the counter here is what lets
                // the 140 ms debounced increment in the map listener re-invoke the pass after a
                // pan or zoom; without the read a gesture refreshes the cull only when something
                // else happens to recompose. The value is deliberately unused: the plan cache and
                // the overlay signature below still decide whether overlays are rebuilt, so a pan
                // that lands on the same cells costs one cached projection and no teardown.
                @Suppress("UNUSED_VARIABLE")
                val gestureRevision = viewportRevision
                // Cached one-pass cull + clustering. Hot RSSI/count publishes still enter this
                // update lambda, but MapRenderPlanCache returns by identity until geometry, lens,
                // viewport, zoom or breadcrumb availability actually changes.
                val box = map.boundingBox
                val viewport = MapViewport(box.latNorth, box.lonEast, box.latSouth, box.lonWest)
                // One crumb read per tracker per PASS. crumbs() copies the whole trail under the
                // detection store's lock, and the trail pass further down wants the same list, so
                // the two share one read instead of copying it twice on a rebuild.
                val trails = HashMap<String, List<Pair<Double, Double>>>()
                fun trail(id: String): List<Pair<Double, Double>> =
                    trails.getOrPut(id) { ble.crumbs(id) }
                val plan = projectionCache.get(
                    shownEvidence, viewport, map.zoomLevelDouble, MAP_MARKER_CAP,
                    showBreadcrumbs, hasTrackerTrail = { trail(it).size >= 2 },
                )
                if (plan.inViewportIds != visibleDetectionIds) {
                    visibleDetectionIds = plan.inViewportIds
                }
                if (plan != renderStats) renderStats = plan
                // AND-PERF-3: skip the teardown/realloc when nothing an overlay draws has moved
                // since the last pass. Visible membership alone is NOT enough (clusters depend on
                // zoom, drone paths grow, pin tiers age), so every one of those is a field of the
                // signature below: the plan identity, the zoom bucket, the two display toggles,
                // the installed spatial revision and the Recent age minute. The one geometry hot
                // RSSI moves, the no-GPS drone ring's radius, is deliberately NOT here: it is
                // resized in place after this gate, so ordinary count/signal changes skip both
                // projection and overlay churn.
                val signature = MapOverlaySignature(
                    plan = plan,
                    zoomBucket = (map.zoomLevelDouble * 4).toInt(),
                    showBreadcrumbs = showBreadcrumbs,
                    showLabels = showLabels,
                    spatialRevision = mapEvidenceRev,
                    ageMinute = historyNow / 60_000L,
                )
                if (signature != rebuildSig[0]) {
                    rebuildSig[0] = signature
                    // Current hot fields are resolved only after the cheap signature says actual
                    // overlays will change. Taps independently resolve the latest row by id.
                    val currentById = ble.detections.value.associateBy { it.id }
                    val visible = plan.overlayRows.map { currentById[it.id] ?: it }
                    // rebuild just the detection markers; leave the location dot alone. Overlays
                    // are a CopyOnWriteArrayList, so the pass collects into a plain list and lands
                    // in ONE addAll instead of copying the backing array per marker.
                    map.overlays.removeAll { it is Marker || it is Polyline || it is Polygon }
                    drawnRings.clear()   // every ring it named went with the Polygons above
                    val fresh = ArrayList<Overlay>()
                    // RING-PEEK: every PIN this pass draws, interleaved lat/lon. Count bubbles are
                    // deliberately absent - a bubble already says "several things here", and
                    // widening a ring under one would claim the mapped camera for whichever member
                    // happened to land in the cell. Sized for the worst case (every visible row a
                    // pin) so the collect never reallocates; same-spot grouping only ever draws
                    // fewer pins than rows, and its members shared a coordinate anyway, so the set
                    // of PLACES a ring can be asked about is exactly what it was before grouping.
                    val pinPts = DoubleArray(plan.symbols.size * 2)
                    var pinN = 0
                    // One last-seen read per visible row, taken once for the whole pass. Both new
                    // pin rules want it (a same-spot group breaks its priority ties on it, and
                    // every pin takes its recency tier from it) and lastSeen() takes the detection
                    // store's lock on each call, so reading it per use would take that lock
                    // several times for the same row. Inside the rebuild gate deliberately: it is
                    // part of building markers, not something the ~3 Hz feed pays for.
                    //
                    // A pseudo-stamp from the board's buffered replay is an ordering key, not a
                    // clock reading, so it is dropped here and the row is left undated. pinAge
                    // answers RECENT for that, which is the honest tier for a time we do not know.
                    val seenAt = ble.mapLastSeenSnapshot(visible)
                    val nowMs = System.currentTimeMillis()
                    fun ageOf(d: Detection): PinAge = pinAge(seenAt[d.id], nowMs)
                    // The drone rows, split out ONCE and read by the two DRONE OVERLAY passes:
                    // the flight-path / tether / launch-glyph / no-GPS-ring pass immediately
                    // below, and the operator-marker pass further down. THE INVARIANT: both walk
                    // EVERY drone row, whatever same-spot grouping did with that row's pin, so an
                    // absorbed drone never loses its path, its tether, its launch glyph or its
                    // operator. Drone PINS come from the grouped pass with everyone else's.
                    // One filter serves both passes; each used to re-filter `visible` for itself.
                    val droneRows = visible.filter { it.type == DeviceType.DRONE }
                    // drone overlays, under the markers: flight path, tether, launch, no-GPS ring
                    droneRows.forEach { d ->
                        val path = ble.track(d.id)
                        if (path.size >= 2) {
                            fresh.add(Polyline(map).apply {
                                setPoints(path.map { GeoPoint(it.first, it.second) })
                                outlinePaint.color = Acab.droneTone.toArgb()
                                outlinePaint.strokeWidth = 5f
                            })
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(path.first().first, path.first().second)
                                // small distinct launch glyph (iOS: 13pt arrow.up.circle.fill),
                                // never a second full drone pin; captioned LAUNCH when the
                                // "icon labels" setting is on, matching iOS.
                                if (showLabels) {
                                    icon = launchMarker.labeled
                                    setAnchor(Marker.ANCHOR_CENTER, launchMarker.labeledAnchorV)
                                } else {
                                    icon = launchMarker.plain
                                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                }
                                // Consume the tap so osmdroid's default title InfoWindow never
                                // pops (the launch point isn't tappable on iOS either).
                                setOnMarkerClickListener { _, _ -> true }
                            })
                        }
                        val plat = d.pilotLat; val plon = d.pilotLon
                        val dla = d.lat; val dlo = d.lon
                        if (dla != null && dlo != null && plat != null && plon != null &&
                            validCoord(dla, dlo) && validCoord(plat, plon)) {
                            fresh.add(Polyline(map).apply {
                                setPoints(listOf(GeoPoint(dla, dlo), GeoPoint(plat, plon)))
                                outlinePaint.color = Acab.droneTone.copy(alpha = 0.5f).toArgb()
                                outlinePaint.strokeWidth = 3f
                            })
                        }
                        if (d.lat == null) {   // no broadcast GPS: draw an RSSI ring around us
                            // From the publish pass, like the cull: no storeLock, and no second
                            // validCoord test because only valid pairs were ever stored.
                            mapCoords[d.id]?.let { (lat, lon) ->
                                val center = GeoPoint(lat, lon)
                                val ring = Polygon(map).apply {
                                    points = Polygon.pointsAsCircle(center, rssiRadiusMeters(d.rssi))
                                    fillPaint.color = Acab.droneTone.copy(alpha = 0.08f).toArgb()
                                    outlinePaint.color = Acab.droneTone.copy(alpha = 0.5f).toArgb()
                                    outlinePaint.strokeWidth = 3f
                                }
                                fresh.add(ring)
                                // Registered at the RSSI it was built from, so the pass under
                                // the gate can tell a moved radius from a repeat.
                                drawnRings[d.id] = DrawnRing(ring, center, d.rssi)
                            }
                        }
                    }
                    // tracker breadcrumb trails, under the markers: the phone's own path while a
                    // tracker stayed with us, drawn DASHED in the tracker tone so it reads as
                    // "this followed me" and stays distinct from the SOLID drone flight paths.
                    // Gated by the "phone breadcrumb trails" map setting.
                    if (showBreadcrumbs) {
                        visible.filter { it.type == DeviceType.TRACKER }.forEach { d ->
                            // Whatever the cull above already read for this tracker, not a
                            // second copy of the same trail.
                            val crumbs = trail(d.id)
                            if (crumbs.size >= 2) {
                                fresh.add(Polyline(map).apply {
                                    setPoints(crumbs.map { GeoPoint(it.first, it.second) })
                                    outlinePaint.color = Acab.trackerTone.toArgb()
                                    outlinePaint.strokeWidth = 4f
                                    outlinePaint.pathEffect = DashPathEffect(floatArrayOf(18f, 12f), 0f)
                                })
                            }
                        }
                    }
                    // The projection already performed culling, adaptive clustering and exact-pin
                    // grouping in one pass. Drawing only materializes its bounded symbol list.
                    for (group in plan.symbols) {
                        val members = group.members.map { currentById[it.id] ?: it }
                        if (!group.cluster) {
                            // Re-ordered on the live last-seen read above, not the snapshot's:
                            // the snapshot lands on a ceiling and a member may have been heard
                            // since. Same rule as the projection (sameSpotOrder), one owner.
                            val ordered = orderSameSpotMembers(members) { seenAt[it] }
                            val d = ordered.first()
                            val n = ordered.size
                            val point = mapCoords[d.id] ?: (group.lat to group.lon)
                            pinPts[pinN++] = point.first; pinPts[pinN++] = point.second
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(point.first, point.second)
                                val age = ageOf(d)
                                pinIcon(d.type, age, showLabels, pinArt, pinBadges, n)
                                title = pinTitle(d.type.category, n)
                                setOnMarkerClickListener { _, _ ->
                                    if (n == 1) selectFresh(d) else {
                                        memberSheetIsViewport = false
                                        clusterMembers = ordered
                                    }
                                    true
                                }
                            })
                        } else if (members.size == 1) {
                            val d = members.first()
                            pinPts[pinN++] = group.lat; pinPts[pinN++] = group.lon
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(group.lat, group.lon)
                                pinIcon(d.type, ageOf(d), showLabels, pinArt, pinBadges, 1)
                                title = pinTitle(d.type.category, 1)
                                setOnMarkerClickListener { _, _ -> selectFresh(d); true }
                            })
                        } else {
                            val tone = if (group.homogeneousCategory)
                                catTone(group.dominantCategory) else Acab.text
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(group.lat, group.lon)
                                icon = clusterFactory.marker(members.size, tone)
                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                title = "${members.size} detections"
                                setOnMarkerClickListener { _, _ ->
                                    memberSheetIsViewport = false
                                    clusterMembers = members
                                    true
                                }
                            })
                        }
                    }
                    // drone operator pins: the muted person marker, distinct from the dots
                    droneRows.forEach { d ->
                        val plat = d.pilotLat; val plon = d.pilotLon
                        if (plat != null && plon != null && validCoord(plat, plon)) {
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(plat, plon)
                                icon = operatorMarker
                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                title = "Operator"
                                snippet = "operator. this drone broadcasts its pilot's location in its remote ID, so this pin is roughly where it's being flown from."
                                mapInfoWindow[0]?.let(::setInfoWindow)
                                // tap explains what OP is, rather than opening the drone's detail
                                setOnMarkerClickListener { m, _ -> m.showInfoWindow(); true }
                            })
                        }
                    }
                    map.overlays.addAll(fresh)
                    map.invalidate()
                    // Keep the PREVIOUS array whenever the pins landed in the same places. The
                    // ALPR layer early-outs on identity, and this rebuild also runs when the
                    // signature moves without a pin moving (a tracker crumb lands, the 30 s scope
                    // tick rolls ageMinute over, a label toggle), so swapping in an equal-but-new
                    // instance would re-index the pins and re-test every drawn ring for nothing.
                    val nextPins = pinPts.copyOf(pinN)
                    if (!nextPins.contentEquals(peekPins[0])) peekPins[0] = nextPins
                }
                // The no-GPS drone ring is resized IN PLACE, rebuild or not. Its radius is the one
                // geometry hot RSSI moves, and a signature field keyed on the ring's RSSI would
                // redraw every overlay to move one polygon. Everything else about the ring is still
                // under the gate: its CENTRE comes from mapCoords, so it is covered by the
                // installed spatial revision, and whether it exists at all follows the drone's own
                // coordinate, which file() in AcabBleManager bumps the spatial revision for on any
                // lat/lon change, so a first fix retires the ring through the ordinary rebuild.
                // What this pass does not invalidate on: a ring whose RSSI is unchanged. What it
                // can never leave stale: a drawn ring's radius, compared with the latest ring
                // publish on every pass, so a burst's trailing value is always the one on screen.
                // A published ring the rebuild did not draw has nothing to resize and is skipped;
                // it gains a polygon only through a rebuild. That is a drone outside the filter or
                // the history scope, one the installed revision does not hold yet, one with no
                // observer coordinate to centre on, or one whose latitude is present but whose
                // coordinate is invalid (feedSnapshots lists a ring on validCoord, while the
                // rebuild draws one only for a null latitude). Drones skip the viewport cull, so
                // an offscreen drone's ring is drawn and resized like any other. Cost on the ~3 Hz
                // path: one walk of the tiny ring list, and a circle only for a ring that moved.
                var ringsResized = false
                for (ring in dynamicRings) {
                    val drawn = drawnRings[ring.id] ?: continue
                    if (drawn.rssi == ring.rssi) continue
                    drawn.rssi = ring.rssi
                    drawn.polygon.points =
                        Polygon.pointsAsCircle(drawn.center, rssiRadiusMeters(ring.rssi))
                    ringsResized = true
                }
                if (ringsResized) map.invalidate()
                // "open in map" jump from a dossier thumbnail: one close-in hop to the sighting,
                // consumed exactly once so recompositions and tab revisits never re-center.
                // Follow mode would snap back to the phone on the next fix, so drop it first
                // (the recenter button brings it back), and mark the one-shot pin centering
                // done so it can't fight the jump either. osmdroid queues animateTo calls made
                // before layout and replays them, so the cold path (tab composed with the jump
                // already pending) lands the same as the warm one.
                focus?.let { (lat, lon) ->
                    myLocation.value?.disableFollowLocation()
                    centeredOnce[0] = true
                    // zoom 16.5 lands a viewport visually equivalent to iOS's 0.006-degree span
                    map.controller.animateTo(GeoPoint(lat, lon), 16.5, null)
                    onFocusConsumed()
                }
                // before the first fix, fit the camera to the bounding box of EVERY located
                // detection (not just the freshest pin, and never a hard-coded fallback view),
                // once only, so the ~3Hz update passes don't fight the user's pan. After a fix,
                // follow-location keeps the map on you.
                if (!centeredOnce[0] && myLocation.value?.myLocation == null) {
                    val pts = shown.mapNotNull { d ->
                        mapRepresentationCoord(
                            d.type, mapCoords[d.id], d.pilotLat, d.pilotLon)
                    }
                    if (pts.isNotEmpty()) {
                        centeredOnce[0] = true
                        var north = pts.maxOf { it.first }
                        var south = pts.minOf { it.first }
                        var east = pts.maxOf { it.second }
                        var west = pts.minOf { it.second }
                        if (north - south > 1.0 || east - west > 1.0) {
                            // Span cap: a full-history box can be continent-wide (one road trip
                            // and the fit shows the whole country as unreadable specks). Frame
                            // the MOST RECENT located detection at a 0.02-degree street-level
                            // view instead; `shown` is the feed's newest-first order, so its
                            // first located point is the freshest sighting.
                            val (lat, lon) = pts.first()
                            north = lat + 0.01; south = lat - 0.01
                            east = lon + 0.01; west = lon - 0.01
                        } else {
                            // Minimum-span floor, BOTH axes: a single point or a same-spot
                            // clump yields a degenerate box, and zoomToBoundingBox slams it to
                            // max zoom (a blank tile at zoom 29). 0.01 degrees keeps the fit at
                            // a useful street level.
                            if (north - south < 0.01) {
                                val mid = (north + south) / 2
                                north = mid + 0.005; south = mid - 0.005
                            }
                            if (east - west < 0.01) {
                                val mid = (east + west) / 2
                                east = mid + 0.005; west = mid - 0.005
                            }
                        }
                        val fit = org.osmdroid.util.BoundingBox(north, east, south, west)
                        // post: zoomToBoundingBox needs a laid-out view, and this update pass
                        // can run before the first layout on a cold tab.
                        map.post {
                            runCatching { map.zoomToBoundingBox(fit.increaseByScale(1.3f), false, 64) }
                        }
                    }
                }
                // refresh the known-ALPR layer with the latest enabled state + dataset (the
                // holder early-outs when none of those inputs changed, so this is free on the
                // ~3 Hz path; its own debounced listener re-culls on pan/zoom)
                // makerIdx/makerTable are read here (not collected) - they are set in the same
                // parse as alprNodes, so an alprNodes change recomposes this and passes the match.
                alprHolder.update(map, alprNodes, alpr.makerIdx, alpr.makerTable,
                                  alpr.confirmed, alpr.rawTier, alprIcons, alprEnabled,
                                  alprShowUnverified)
                // RING-PEEK, as its OWN call rather than an input to the cull above. The pin set
                // changes every time a new device is heard; the RINGS only change with the
                // viewport or the dataset. Handing the pins to update() defeated its identity
                // early-out, so every arrival re-scanned all 119k nodes and re-alloc'd up to 500
                // markers on the main thread. This path only re-stamps icons on the rings the cull
                // already drew. Last in the pass on purpose: peekPins[0] has to describe the
                // markers this pass just drew, or a ring would widen for a pin that is gone.
                alprHolder.setPeekPins(map, peekPins[0])
            },
            onRelease = { map ->
                viewportRefresh[0]?.let { map.removeCallbacks(it) }
                viewportRefresh[0] = null
                myLocation.value?.disableMyLocation()
                myLocation.value = null
                if (mapResumed[0]) map.onPause()
                mapResumed[0] = false
                if (liveMap.value === map) liveMap.value = null
                alprHolder.detach()
                mapInfoWindow[0]?.close()
                mapInfoWindow[0] = null
                map.onDetach()
            },
        )

        // F17: iOS-style top scrim so the floating header/chips read over the tiles
        Box(
            Modifier.align(Alignment.TopCenter).fillMaxWidth().height(176.dp)
                .background(Brush.verticalGradient(listOf(Acab.bg, Color.Transparent))),
        )

        // header + filter chips float over the map
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = Acab.pad)
                .padding(top = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // NO LINK CHIP HERE, deliberately. The connection pill lives on Status and Beacon,
            // which are where a user goes to ask "is my board there". On the Map it competed with
            // the counts line for a narrow header: on a Pixel 2 (411dp) the row measured this
            // Column first, left the pill too little, and "CONNECTED" wrapped mid-word across
            // three lines. Dropping it also gives the counts the full width. TWIN: iOS
            // MapTabView.header, which drops it for the same reason - iOS never wrapped (its
            // Kicker pins one line at default type) but the pill is redundant on both.
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("Map", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                val simplified = renderStats.simplifiedRows + renderStats.omittedRows
                Kicker(buildString {
                    append("${shown.size} DISPLAYED · ${located.size} RETAINED")
                    if (simplified > 0) append(" · $simplified SIMPLIFIED")
                })
            }
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // The active lens is FIRST and fixed outside the category carousel, so it can
                // never scroll offscreen while continuing to hide points.
                val activeLabel = filter?.let { "FILTER · $it" } ?: "ALL"
                CatChip(filter, activeLabel, shown.size, true) { filter = null }
                OptionsChip(historyScope, alprEnabled, alprLoading) { optionsOpen = true }
                if (visibleDetections.isNotEmpty()) {
                    MapListChip(visibleDetections.size) {
                        memberSheetIsViewport = true
                        clusterMembers = visibleDetections
                    }
                }
            }
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Category chips are dynamic: a chip appears only once that category has a
                // sighting this session, so a zero-count filter never clutters the row.
                MAP_CATEGORIES.sortedByDescending { it.key == filter }.forEach { c ->
                    val active = filter == c.key
                    // Active-filter exception: keep the chip while it is the current filter even
                    // if its live count drops to 0 (eviction/staleness). Without this the chip
                    // would vanish out from under the user, leaving the map filtered with no chip
                    // left to tap and no way to clear back to ALL.
                    val visible = count(c.key) > 0 || active
                    if (visible) {
                        CatChip(c.key, c.label, count(c.key), active) { filter = c.key }
                    }
                }
            }
        }

        // The bottom-left stack (map-settings gear + legend, with the settings menu's tap-away
        // scrim) is composed near the end of this Box so the scrim can float over the other
        // overlays; see below.

        // ALPR hint: the layer is on but nothing is drawing, say why (failed load vs zoomed out),
        // so "off" is never confused with "broken".
        val alprHint = when {
            !alprEnabled || alprLoading -> null
            // A 404 is a rollout state, not a connectivity problem , see RefreshOutcome.
            alprNodes.isEmpty() && alprOutcome == AlprStore.RefreshOutcome.NOT_PUBLISHED ->
                "camera data not published yet · try again later"
            alprNodes.isEmpty() -> "couldn't load camera data · check your connection"
            zoomedOutTooFar -> "zoom in to see mapped cameras"
            else -> null
        }
        if (alprHint != null) {
            Text(
                alprHint,
                color = floatingInfoColors.primaryText,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.Medium,
                fontFamily = Acab.display,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 22.dp)
                    .widthIn(max = 320.dp)
                    .background(floatingInfoColors.surface, RoundedCornerShape(Acab.radiusSm))
                    .border(1.dp, floatingInfoColors.border, RoundedCornerShape(Acab.radiusSm))
                    .padding(horizontal = 14.dp, vertical = 9.dp),
            )
        }

        // Recenter button + the tile credit share the bottom-right corner. The credit is REQUIRED
        // by the OSM tile policy / ODbL and must stay legible, so the button stacks ABOVE it
        // rather than over it. (iOS puts its recenter in this corner unobstructed; MapKit tiles
        // carry their own attribution, so there is nothing to share the space with there.)
        Column(
            Modifier.align(Alignment.BottomEnd).padding(Acab.pad),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Recenter on the phone, mirroring iOS's recenterButton. This is not just a
            // convenience: osmdroid's MyLocationNewOverlay silently drops follow-mode the first
            // time the user pans, and exposes no way back, so without this the blue dot stops
            // tracking for the rest of the session. enableFollowLocation() re-centers on the last
            // fix and resumes following; with no fix yet it simply centers once one lands.
            Box(
                Modifier
                    .minimumInteractiveComponentSize()   // 38dp chip, 48dp touch target
                    .size(38.dp)
                    .background(Acab.bg2.copy(alpha = 0.85f), CircleShape)
                    .border(1.dp, Acab.line, CircleShape)
                    .clickable { myLocation.value?.enableFollowLocation() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.MyLocation, contentDescription = "Center on my location",
                    tint = Acab.text, modifier = Modifier.size(17.dp))
            }
            // tile credit required by the OSM tile policy / ODbL
            Text(
                "© OpenStreetMap contributors",
                color = floatingInfoColors.secondaryText,
                fontSize = 10.sp,
                fontFamily = Acab.mono,
                modifier = Modifier
                    .background(floatingInfoColors.surface, RoundedCornerShape(Acab.radiusSm))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }

        // Empty/location state, with two distinct reasons told apart. Location-off is shown even
        // when a drone broadcast (or an older observer pin) means the
        // map is non-empty: those pins do not make permission magically on. The copy names both
        // exceptions and offers the fix. With location fine, the empty case explains what appears.
        // Dismissible (R12, matches iOS), and it never eats map gestures: the card has no gesture
        // modifier, so a pan falls through to the map; only the controls consume touch.
        if ((!hasLocationPermission || scopedEvidence.isEmpty()) && !emptyDismissed) {
            Box(Modifier.align(Alignment.Center).padding(Acab.pad)) {
                Column(
                    Modifier
                        .background(floatingInfoColors.surface, RoundedCornerShape(Acab.radius))
                        .border(1.dp, floatingInfoColors.border, RoundedCornerShape(Acab.radius))
                        .padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (!hasLocationPermission) {
                        Text(
                            "Location permission is off",
                            color = floatingInfoColors.primaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(end = 28.dp),
                        )
                        Text("Phone location is off. New non-drone detections cannot be positioned. " +
                            "Drones that broadcast coordinates can still appear, and existing " +
                            "phone-positioned detections stay on the map.",
                            color = floatingInfoColors.secondaryText, fontSize = 11.sp,
                            fontFamily = Acab.mono,
                            textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 250.dp))
                        Text(
                            "OPEN SETTINGS",
                            // accentText, not accent: same bg2 floating-info surface as the
                            // SHOW ALL HISTORY sibling below, where the fill tone is under AA as
                            // text (Theme.kt). Twin rule: iOS uses ACABTheme.accentText for crimson
                            // words on this surface.
                            color = Acab.accentText, fontSize = 11.sp, fontFamily = Acab.mono,
                            fontWeight = FontWeight.Bold, letterSpacing = 1.sp,
                            modifier = Modifier
                                .minimumInteractiveComponentSize()
                                .clip(CircleShape)
                                .border(1.dp, Acab.lineStrong, CircleShape)
                                .clickable {
                                    context.startActivity(
                                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null))
                                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    } else if (located.isNotEmpty() && historyScope == MapHistoryScope.Recent) {
                        // The rows here DO have locations; they are simply older than the lens.
                        // Copy is byte-identical to iOS MapTabView's emptyBecauseHistoryScope
                        // branch, down to the one-tap scope switch, so the same state reads the
                        // same on both phones. The "uses your phone's position" line below
                        // deliberately does NOT render here: nothing about location is the reason,
                        // and offering it as one sends the reader to the wrong setting.
                        Text(
                            "No recent located detections",
                            color = floatingInfoColors.primaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(end = 28.dp),
                        )
                        Text(
                            "The Recent map covers the previous 15 minutes. Older located " +
                                "detections are still retained in the Log.",
                            color = floatingInfoColors.secondaryText, fontSize = 11.sp,
                            fontFamily = Acab.mono,
                            textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 250.dp))
                        // accentText, not accent: a crimson WORD on the bg2 info surface, where
                        // the fill tone is under AA as text (Theme.kt). Same cut as the iOS twin
                        // (`.foregroundStyle(ACABTheme.accentText)` on its SHOW ALL HISTORY).
                        Text(
                            "SHOW ALL HISTORY",
                            color = Acab.accentText, fontSize = 11.sp, fontFamily = Acab.mono,
                            fontWeight = FontWeight.Bold, letterSpacing = 1.sp,
                            modifier = Modifier
                                .minimumInteractiveComponentSize()
                                .clip(CircleShape)
                                .border(1.dp, Acab.lineStrong, CircleShape)
                                .clickable {
                                    historyScope = MapHistoryScope.All
                                    mapPrefs.edit()
                                        .putString("history_scope", historyScope.name).apply()
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                    } else {
                        Text(
                            "No located detections yet",
                            color = floatingInfoColors.primaryText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.padding(end = 28.dp),
                        )
                        Text(
                            "Detections appear here once they're heard with location available.",
                            color = floatingInfoColors.secondaryText, fontSize = 11.sp,
                            fontFamily = Acab.mono,
                            textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 250.dp))
                        // Scoped to THIS branch only, exactly as iOS scopes it: it explains why a
                        // detection has no location at all, which is untrue of the recent-scope
                        // branch above.
                        Text("ALPR, body cam, glasses, network camera and tracker hits use your phone's position; drones report their own.",
                            color = floatingInfoColors.secondaryText, fontSize = 11.sp,
                            fontFamily = Acab.mono,
                            textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 250.dp))
                    }
                }
                Box(
                    Modifier.align(Alignment.TopEnd)
                        .minimumInteractiveComponentSize()
                        .size(26.dp)
                        .background(floatingInfoColors.surface, CircleShape)
                        .border(1.dp, floatingInfoColors.border, CircleShape)
                        .clickable { emptyDismissed = true },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Close, contentDescription = "dismiss",
                        tint = floatingInfoColors.primaryText, modifier = Modifier.size(13.dp))
                }
            }
        }
        }

        // Bottom-left legend. Display/history/layer controls moved to the single Options sheet.
        // F18 legend: DERIVED, not latched - auto-expands only while the ALPR dataset actually
        // downloads (keyed to `downloading`, not `loading`, so the per-enable manifest freshness
        // check never force-opens it and overrides the user's collapsed state).
        val legendOpen = legendExpanded || alprDownloading
        Column(
            Modifier.align(Alignment.BottomStart).padding(Acab.pad),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // legend: expanded card, or the small info chip
            if (legendOpen) {
                // stateDescription on both legend states: the chip and the card are the same
                // control to TalkBack (tap = toggle), so each names which side it is on.
                Column(
                    Modifier
                        .background(floatingInfoColors.surface, RoundedCornerShape(Acab.radiusSm))
                        .border(1.dp, floatingInfoColors.border, RoundedCornerShape(Acab.radiusSm))
                        .clickable { legendExpanded = false }
                        .semantics { stateDescription = "expanded" }
                        .padding(11.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    LegendRow(Acab.flockTone, "ALPR")
                    LegendRow(Acab.droneTone, "Drone")
                    LegendRow(Acab.bodyCamTone, "Body cam")
                    LegendRow(Acab.trackerTone, "Tracker")
                    LegendRow(Acab.glassesTone, "Glasses")
                    LegendRow(Acab.netcamTone, "Network camera")
                    // PIN RECENCY: the only pin state on this map that is not a category, so the
                    // legend has to name it or a dimmed pin just looks like a rendering fault.
                    // Always listed, unlike the conditional rows below: a relaunch redraws the
                    // whole persisted log, and every one of those pins is past the stale mark.
                    // The swatch is a neutral tone dimmed by the same rule the pins use, so it
                    // demonstrates the state without claiming a category.
                    LegendRow(dimTone(Acab.text), "dimmed: last heard over an hour ago")
                    if (alprEnabled) {
                        if (alprTier1Count > 0) LegendRow(
                            Acab.flockTone.copy(alpha = 0.95f),
                            "ALPR, manufacturer attributed",
                            hollow = true,
                        )
                        if (alprLegacyFormatCount > 0) LegendRow(
                            Acab.flockTone.copy(alpha = 0.95f),
                            "ALPR, legacy dataset format",
                            hollow = true,
                        )
                        // Parity with iOS: the unverified tier is rendered on the map
                        // (rememberAlprMarker(confirmed = false)) but had no legend row here at
                        // all, so an amber dashed ring was unexplained on Android only. Gated on
                        // the opt-in for the same reason it is gated on the layer: a legend naming
                        // a colour nothing on screen is using reads as a rendering bug.
                        if (alprShowUnverified) {
                            if (alprTier0Count > 0) LegendRow(
                                Acab.warn.copy(alpha = 0.95f),
                                "ALPR, no structured manufacturer",
                                hollow = true,
                            )
                            if (alprTier2Count > 0) LegendRow(
                                Acab.warn.copy(alpha = 0.95f),
                                "ALPR, legacy candidate",
                                hollow = true,
                            )
                            if (alprOtherTierCount > 0) LegendRow(
                                Acab.warn.copy(alpha = 0.95f),
                                "ALPR, unknown attribution tier",
                                hollow = true,
                            )
                        }
                        // RING-PEEK: named only while a wide ring is actually drawn, same rule as
                        // the tier rows above. The wide rim is the map's only cue that a live hit
                        // landed on a camera the dataset already knows about.
                        if (alprPeekCount > 0) LegendRow(
                            Acab.flockTone.copy(alpha = 0.95f),
                            "wide ring: live hit at a mapped camera",
                            hollow = true,
                            wide = true,
                        )
                        Text("cameras: OpenStreetMap ODbL · DeFlock",
                            color = floatingInfoColors.secondaryText,
                            fontSize = 11.sp, fontFamily = Acab.mono)
                    }
                }
            } else {
                Box(
                    Modifier
                        .minimumInteractiveComponentSize()   // 34dp chip, 48dp touch target
                        .size(34.dp)
                        .background(floatingInfoColors.surface, CircleShape)
                        .border(1.dp, floatingInfoColors.border, CircleShape)
                        .clickable { legendExpanded = true }
                        .semantics { stateDescription = "collapsed" },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Outlined.Info, contentDescription = "Map legend",
                        tint = floatingInfoColors.primaryText,
                        modifier = Modifier.size(16.dp))
                }
            }
        }
    }

    // One sheet, three plainly-labelled sections. History scope changes only Map; the retained
    // Logbook remains complete. Display settings and downloaded reference data no longer hide in
    // separate floating controls.
    if (optionsOpen) {
        ModalBottomSheet(
            onDismissRequest = { optionsOpen = false },
            containerColor = Acab.bg3,
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Acab.pad)
                    .padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("Map options", color = Acab.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Kicker("HISTORY")
                MapScopeRow(
                    label = "Recent · 15 minutes",
                    note = "Keeps the live map readable. Older evidence stays in Logbook.",
                    selected = historyScope == MapHistoryScope.Recent,
                ) {
                    historyScope = MapHistoryScope.Recent
                    mapPrefs.edit().putString("history_scope", historyScope.name).apply()
                }
                MapScopeRow(
                    label = "All history",
                    note = "Shows every retained located sighting; far zooms combine dense points.",
                    selected = historyScope == MapHistoryScope.All,
                ) {
                    historyScope = MapHistoryScope.All
                    mapPrefs.edit().putString("history_scope", historyScope.name).apply()
                }
                HorizontalDivider(color = Acab.line)
                Kicker("DISPLAY")
                MapSettingRow("phone breadcrumb trails", showBreadcrumbs,
                    note = FollowEvidence.SCOPE_TEXT) {
                    showBreadcrumbs = it
                    mapPrefs.edit().putBoolean("show_breadcrumbs", it).apply()
                }
                MapSettingRow("icon labels", showLabels) {
                    showLabels = it
                    mapPrefs.edit().putBoolean("show_labels", it).apply()
                }
                HorizontalDivider(color = Acab.line)
                // BYTE-IDENTICAL to iOS MapTabView's `mapOptionsSection("REFERENCE OVERLAYS · NOT
                // FILTERS")`, header and the ALPR note below alike: the toggles here draw
                // reference data over the map and never hide a detection, and the two sheets
                // must say so in the same words.
                Kicker("REFERENCE OVERLAYS · NOT FILTERS")
                Row(
                    Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                        .toggleable(
                            value = alprEnabled,
                            role = Role.Switch,
                            onValueChange = alpr::setEnabled,
                        )
                        .semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("known ALPR cameras", color = Acab.text, fontSize = 14.sp,
                            fontWeight = FontWeight.Medium)
                        // The source credit ("cameras: OpenStreetMap ODbL · DeFlock") is the map
                        // legend's job on both phones; this note carries the privacy disclosure.
                        Text("draws community-mapped camera locations, on by default. the dataset is one offline download; no location, viewport, or detection data is attached, and the site host sees an ordinary web request. pins are mapped locations, not live detections.",
                            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
                    }
                    Spacer(Modifier.size(12.dp))
                    if (alprLoading) {
                        CircularProgressIndicator(color = Acab.dim, strokeWidth = 2.dp,
                            modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(10.dp))
                    }
                    Switch(
                        checked = alprEnabled,
                        onCheckedChange = null,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Acab.onAccent, checkedTrackColor = Acab.accent,
                            uncheckedThumbColor = Acab.dim, uncheckedTrackColor = Acab.bg2,
                            uncheckedBorderColor = Acab.line,
                        ),
                    )
                }
                if (alprEnabled) {
                    AlprDatasetRows(alpr, alprNodes, alprLoading, alprShowUnverified,
                        alprUnverifiedCount, alpr.rawTier)
                }
            }
        }
    }

    // F19: cluster member-list sheet, one row per detection in the tapped bubble
    clusterMembers?.let { members ->
        ModalBottomSheet(
            onDismissRequest = { clusterMembers = null },
            containerColor = Acab.bg3,
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        ) {
            Column(
                Modifier.padding(horizontal = Acab.pad).padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                // header anatomy matches the iOS ClusterListSheet: "N here" title over the kicker
                Text(
                    if (memberSheetIsViewport) "${members.size} visible" else "${members.size} here",
                    color = Acab.text, fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold)
                Kicker(if (memberSheetIsViewport) "VISIBLE MAP DETECTIONS" else "CLUSTERED AT THIS SPOT")
                Spacer(Modifier.height(6.dp))
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 520.dp)) {
                items(members, key = { it.id }) { d ->
                    Row(
                        Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                            .clickable { clusterMembers = null; onSelect(d) }
                            .semantics(mergeDescendants = true) {
                                contentDescription =
                                    "${d.displayName}, ${d.type.category}, signal ${d.rssi} dBm"
                            }
                            .padding(vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CatGlyph(d.type, size = 30)
                        Spacer(Modifier.size(10.dp))
                        Column(Modifier.weight(1f)) {
                            // displayName, not the raw category. This sheet rendered the bare
                            // UPPERCASE category for every member, so it discarded real
                            // advertised names even before makers existed, and iOS has always
                            // reused the whole DetectionRow here. Without this the map sheet
                            // would say "CAMERA" while the log two taps away says "Hikvision".
                            Text(d.displayName, color = Acab.text, fontSize = 13.sp,
                                fontWeight = FontWeight.Medium, maxLines = 1)
                            Text("NODE ${d.mac.replace(":", "").takeLast(4).uppercase()}",
                                color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
                        }
                        Text("${d.rssi}", color = Acab.accentText, fontSize = 12.sp, fontFamily = Acab.mono)
                    }
                }
                }
            }
        }
    }
}

/** The four pin sets the update pass chooses between: full colour or the STALE tier's dimmed
 *  twin, each with and without the "icon labels" under-icon type tag. Bundled so the pass picks
 *  artwork with one call instead of threading four maps through every marker it builds. */
private class MapPinArt(
    val plain: Map<DeviceType, BitmapDrawable>,
    val plainDim: Map<DeviceType, BitmapDrawable>,
    val labeled: LabeledMarkers,
    val labeledDim: LabeledMarkers,
)

/** Point a detection marker at its pin artwork: the category, the recency tier, the "icon labels"
 *  setting, and, when this pin stands for a same-spot group, the count badge. Every variant keeps
 *  the ICON centered on the geo point, so none of these choices moves the pin (the labeled bitmap
 *  is taller and the badged one is padded, so each carries its own raised anchor).
 *
 *  [groupSize] of 1 is the ungrouped pin and takes no badge, which is what keeps a lone pin
 *  pixel-identical to the way it drew before grouping existed. */
private fun Marker.pinIcon(
    type: DeviceType,
    age: PinAge,
    showLabels: Boolean,
    art: MapPinArt,
    badges: PinBadgeFactory,
    groupSize: Int,
) {
    val dim = age == PinAge.STALE
    val base: BitmapDrawable
    val baseAnchorV: Float
    if (showLabels) {
        val set = if (dim) art.labeledDim else art.labeled
        base = set.icons.getValue(type)
        baseAnchorV = set.anchorV
    } else {
        base = (if (dim) art.plainDim else art.plain).getValue(type)
        baseAnchorV = Marker.ANCHOR_CENTER
    }
    if (groupSize > 1) {
        val badged = badges.badged(base, baseAnchorV, groupSize)
        icon = badged.icon
        setAnchor(Marker.ANCHOR_CENTER, badged.anchorV)
    } else {
        icon = base
        setAnchor(Marker.ANCHOR_CENTER, baseAnchorV)
    }
}

/** One row of the map-settings menu: a label + a Switch, whole row tappable, with an optional
 *  caption under it for a toggle whose SCOPE isn't obvious from its two-word label. */
@Composable
private fun MapSettingRow(label: String, checked: Boolean, note: String? = null, onChange: (Boolean) -> Unit) {
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                .toggleable(
                    value = checked,
                    role = Role.Switch,
                    onValueChange = onChange,
                )
                .semantics(mergeDescendants = true) {}
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                modifier = Modifier.weight(1f))
            Spacer(Modifier.size(12.dp))
            Switch(
                checked = checked,
                onCheckedChange = null,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = Acab.onAccent,
                    checkedTrackColor = Acab.accent,
                    checkedBorderColor = Acab.accent,
                    uncheckedThumbColor = Acab.dim,
                    uncheckedTrackColor = Acab.bg3,
                    uncheckedBorderColor = Acab.line,
                ),
            )
        }
        note?.let {
            Text(it, color = Acab.faint, fontSize = 9.sp, fontFamily = Acab.mono, lineHeight = 12.sp,
                modifier = Modifier.padding(end = 8.dp, bottom = 4.dp))
        }
    }
}

/** Large-text-safe history choice for the unified Options sheet. The full row is the radio target;
 * the note is merged into its accessibility label. */
@Composable
private fun MapScopeRow(label: String, note: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .toggleable(value = selected, role = Role.RadioButton) { if (it) onSelect() }
            .semantics(mergeDescendants = true) { this.selected = selected }
            .padding(vertical = 5.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier.size(20.dp).border(1.dp, if (selected) Acab.accent else Acab.line, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) Box(Modifier.size(10.dp).background(Acab.accent, CircleShape))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(label, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(note, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                lineHeight = 15.sp)
        }
    }
}

// Count grouping policy, both platforms: DATASET sizes on these captions group by the device
// locale ("12,345" / "12 345" / "12.345"), because they are chrome, not evidence; iOS uses
// Int.formatted() for the same captions in MapTabView. Session counters (tiles, log headers)
// stay ungrouped on both platforms. Until 2026-09-02 this file pinned Locale.US here, so once a
// count reached 1,000 the caption disagreed with iOS on any phone whose locale groups digits
// differently from en-US (12 345, 12.345, 1,23,456).

/** All tiers are dataset records; only tiers 0 and 1 are canonical ALPR entries. */
private fun alprRecordCount(n: Int): String =
    String.format(java.util.Locale.getDefault(), "%,d ALPR record%s", n, if (n == 1) "" else "s")

/** Same grouping, counting PINS instead. The unconfirmed tier is deliberately not called cameras:
 *  that some of them are not cameras is the entire reason the toggle exists. */
private fun pinCount(n: Int): String =
    String.format(java.util.Locale.getDefault(), "%,d pin%s", n, if (n == 1) "" else "s")

/** Manifest `updated` ("2026-07-27") -> "Jul 27" for the settings caption; the raw string if it
 *  ever arrives in another shape, null when we have no dataset stamp at all. */
private fun datasetDateLabel(updated: String?): String? {
    if (updated.isNullOrEmpty()) return null
    return runCatching {
        val parsed = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
            .apply { isLenient = false }.parse(updated)!!
        val thisYear = java.util.Calendar.getInstance().get(java.util.Calendar.YEAR)
        val year = java.util.Calendar.getInstance().apply { time = parsed }.get(java.util.Calendar.YEAR)
        java.text.SimpleDateFormat(if (year == thisYear) "MMM d" else "MMM d yyyy", java.util.Locale.US).format(parsed)
    }.getOrDefault(updated)
}

/** Sub-minute checks read "just now" (parity with iOS); everything older defers to the shared
 *  relativeAgo() buckets. */
private fun checkedAgo(epochMs: Long): String =
    if (System.currentTimeMillis() - epochMs < 60_000) "just now" else relativeAgo(epochMs)

/** Dataset status + manual refresh for the known-ALPR layer, shown in the map-settings menu only
 *  while the layer is on. The caption reads count / dataset date / last manifest check straight
 *  off the store; the row re-runs the store's existing refresh path (manifest check -> conditional
 *  download -> sha256 verify) and flashes the outcome inline. Double-taps are guarded twice:
 *  the row disables while a fetch is in flight, and the store's own fetch gate drops extras. */
@Composable
private fun AlprDatasetRows(alpr: AlprStore, nodes: IntArray, loading: Boolean,
                            showUnverified: Boolean, unverifiedCount: Int, rawTier: IntArray) {
    val updated by alpr.updated.collectAsState()
    val lastChecked by alpr.lastChecked.collectAsState()
    var awaiting by remember { mutableStateOf(false) }            // a tap-initiated check is out
    var outcome by remember { mutableStateOf<Pair<String, Boolean>?>(null) }   // msg to isSuccess

    val caption = buildString {
        // Count what the map DRAWS. Captioning the full dataset while hiding a chunk of it makes
        // the toggle below look broken (the number never moves) and overstates the coverage.
        val n = (nodes.size / 2).let { if (showUnverified) it else it - unverifiedCount }
        if (n > 0) {
            append(alprRecordCount(n))
            datasetDateLabel(updated)?.let { append(" · dataset ").append(it) }
        } else {
            append("no dataset yet")
        }
        append(" · ")
        append(lastChecked?.let { "checked ${checkedAgo(it)}" } ?: "never checked")
    }

    // Resolve a tap-initiated check once the store goes idle: read the outcome the fetch just
    // published, flash it for a beat, then fall back to the plain row label. `awaiting` stays
    // OUT of the key on purpose: clearing it must not relaunch the effect and cancel the delay.
    LaunchedEffect(loading) {
        if (!loading && awaiting) {
            awaiting = false
            outcome = when (alpr.lastOutcome.value) {
                AlprStore.RefreshOutcome.UPDATED ->
                    "updated · ${alprRecordCount(alpr.nodes.value.size / 2)}" to true
                AlprStore.RefreshOutcome.UP_TO_DATE -> "up to date" to true
                else -> "couldn't check" to false
            }
            delay(2500)
            outcome = null
        }
    }

    Text(
        caption, color = Acab.faint, fontSize = 9.sp, fontFamily = Acab.mono,
        modifier = Modifier.widthIn(max = 240.dp).padding(top = 2.dp),
    )
    // Opt-in for the tier nobody could name a manufacturer for. Off by default because those pins
    // are where "your app is wrong" reports come from: the user drives to one, finds an empty pole,
    // and blames the detector rather than the stranger who mapped it. Kept as a row instead of
    // dropped from the dataset so mappers who want to see and fix them still can. Mirrors iOS.
    if (unverifiedCount > 0) {
        val tier0 = rawTier.count { it == 0 }
        val tier2 = rawTier.count { it == 2 }
        val other = (unverifiedCount - tier0 - tier2).coerceAtLeast(0)
        val tierSummary = buildList {
            if (tier0 > 0) add("${pinCount(tier0)} with no structured manufacturer")
            if (tier2 > 0) add(String.format(
                java.util.Locale.getDefault(),
                "%,d legacy candidate%s",
                tier2,
                if (tier2 == 1) "" else "s",
            ))
            if (other > 0) add("${pinCount(other)} with an unknown attribution tier")
        }.joinToString("; ")
        MapSettingRow(
            "additional ALPR records", showUnverified,
            note = if (showUnverified)
                "showing $tierSummary, drawn hollow. Legacy candidates may be aliases."
            else
                "$tierSummary hidden. Tier 1 records have structured manufacturer attribution.",
        ) { alpr.setShowUnverified(it) }
    }
    val done = outcome
    Row(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .clickable(enabled = !loading) {
                awaiting = true
                outcome = null
                alpr.refresh()
            }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (loading) {
            CircularProgressIndicator(color = Acab.dim, strokeWidth = 1.5.dp, modifier = Modifier.size(11.dp))
        } else {
            Icon(
                if (done?.second == true) Icons.Filled.Check else Icons.Filled.Refresh,
                contentDescription = null,
                tint = if (done?.second == true) Acab.accent else Acab.dim,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(
            when {
                loading -> "checking"
                done != null -> done.first
                else -> "check for updates"
            },
            color = if (done?.second == true) Acab.accent else Acab.dim,
            fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** One legend row: colored dot (filled, or a hollow ring for reference layers) + label. [wide]
 *  draws the ring-peek swatch, the one that is bigger on the map. The swatch sits in a fixed slot
 *  so that extra width cannot push its label out of line with every other row. */
@Composable
private fun LegendRow(color: Color, label: String, hollow: Boolean = false, wide: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        val dotSize = if (wide) 12.dp else 8.dp
        val dot = if (hollow) Modifier.size(dotSize).border(1.5.dp, color, RoundedCornerShape(50))
                  else Modifier.size(dotSize).background(color, RoundedCornerShape(50))
        Box(Modifier.size(12.dp), contentAlignment = Alignment.Center) { Box(dot) }
        Text(label, color = Acab.text, fontSize = 12.sp, lineHeight = 16.sp,
            fontFamily = Acab.mono)
    }
}

/** Opens the unified history/display/reference-overlay sheet. The current time scope stays visible
 * on the closed chip, which is the map's most consequential display choice. */
@Composable
private fun OptionsChip(
    scope: MapHistoryScope,
    alprEnabled: Boolean,
    loading: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClick = onClick)
            .semantics {
                stateDescription = buildString {
                    append(if (scope == MapHistoryScope.Recent) "recent fifteen minutes" else "all history")
                    append(if (alprEnabled) ", known ALPR layer on" else ", known ALPR layer off")
                }
            }
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (loading) {
            CircularProgressIndicator(
                Modifier.size(10.dp),
                strokeWidth = 1.5.dp,
                color = Acab.dim,
            )
        }
        Icon(Icons.Outlined.Layers, contentDescription = null,
            tint = Acab.dim, modifier = Modifier.size(12.dp))
        Text(
            if (scope == MapHistoryScope.Recent) "OPTIONS · 15M" else "OPTIONS · ALL",
            color = Acab.dim,
            fontSize = 10.5.sp,
            letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono,
        )
    }
}

/** Sighted and accessibility companion to the opaque native map. Its sheet contains every
 *  detection pin currently inside the viewport, each as a focusable dossier action. */
@Composable
private fun MapListChip(count: Int, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier.minimumInteractiveComponentSize()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "$count visible map detections, open list"
            }
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(Icons.AutoMirrored.Outlined.ListAlt, contentDescription = null,
            tint = Acab.dim, modifier = Modifier.size(12.dp))
        Text("LIST $count", color = Acab.dim, fontSize = 10.5.sp,
            letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Tint for a filter key; ALL falls back to the crimson accent. */
private fun catTone(cat: String?): Color = when (cat) {
    "ALPR" -> Acab.flockTone
    "DRONE" -> Acab.droneTone
    "BODY CAM" -> Acab.bodyCamTone
    "TRACKER" -> Acab.trackerTone
    "GLASSES" -> Acab.glassesTone
    "CAMERA" -> Acab.netcamTone
    WATCHED_FILTER_KEY -> Acab.watchTone
    else -> Acab.accent
}

/** One entry in the ordered category set shared by every filter surface. [key] is the
 *  DeviceType.category the filter matches on; [label] is the chip's display text. Defined
 *  once here (mirrors iOS) so a new category is added in a single place. "Nearby Device"
 *  is deliberately absent: it is ambient noise, not a filter category. */
private data class MapCategory(val key: String, val label: String)

private val MAP_CATEGORIES = listOf(
    MapCategory("ALPR", "ALPR"),
    MapCategory("DRONE", "DRONE"),
    MapCategory("BODY CAM", "BODY CAM"),
    MapCategory("TRACKER", "TRACKER"),
    MapCategory("GLASSES", "GLASSES"),
    MapCategory("CAMERA", "NETWORK CAM"),
    MapCategory(WATCHED_FILTER_KEY, "WATCHED"),
)

/** Pill chip that filters the pins to one category; active fills with its tone. */
@Composable
private fun CatChip(cat: String?, label: String, n: Int, active: Boolean, onClick: () -> Unit) {
    val tone = catTone(cat)
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .background(if (active) tone else Acab.bg2, shape)
            .border(1.dp, if (active) Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .semantics { selected = active }
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            label,
            color = if (active) Acab.onAccent else Acab.dim,
            fontSize = 10.5.sp,
            letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono,
        )
        Text(
            "$n",
            color = if (active) Acab.onAccent.copy(alpha = 0.7f) else Acab.faint,
            fontSize = 10.sp,
            fontFamily = Acab.mono,
        )
    }
}
