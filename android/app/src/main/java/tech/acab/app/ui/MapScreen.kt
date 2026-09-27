package tech.acab.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import tech.acab.app.BuildConfig
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedFilterChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import java.io.File
import org.osmdroid.config.Configuration
import org.osmdroid.events.MapEventsReceiver
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.util.TileSystem
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.MapEventsOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Overlay
import org.osmdroid.views.overlay.Polygon
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.infowindow.InfoWindow
import org.osmdroid.views.overlay.mylocation.GpsMyLocationProvider
import org.osmdroid.views.overlay.mylocation.MyLocationNewOverlay
import tech.acab.app.ble.ACTIVE_NEARBY_WINDOW_MS
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.validCoord
import tech.acab.app.net.AlprStore
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabTypography
import tech.acab.app.ui.theme.tabular
import tech.acab.app.ui.theme.telemetry
import tech.acab.app.model.titleName

/** AND-PERF-1: hard cap on detection overlays drawn in one viewport rebuild, so a huge log
 *  can't rebuild thousands of markers on every ~3 Hz emission. */
private const val MAP_MARKER_CAP = 600

/** The main Map's "phone breadcrumb trails" option starts OFF (decision B1): a user's own or a
 *  family member's tag (a Tile, a partner's AirTag) otherwise draws a trail that reads as being
 *  followed, and the trails clutter the main Map. Only the fallback for a user who never flipped
 *  the switch: a stored "show_breadcrumbs" choice wins. Collection is unchanged, and the
 *  tracker's dossier still shows its trail. TWIN: iOS MapTabView.showBreadcrumbsDefault in
 *  MapTabView.swift. */
internal const val MAP_SHOW_BREADCRUMBS_DEFAULT = false

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
 *  and, for what the user is told, the SIMPLIFIED part of the legend card's counts line and the
 *  "rows simplified" clause of the map's spoken description. iOS has no far-zoom clause: it
 *  keeps individual infra artwork at every span and narrows
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
 *  Android draws the pin's ping frozen into the bitmap rather than animating it, so there is no
 *  motion to gate. The FRESH set carries the frozen ring and the RECENT and STALE sets do not
 *  ([pinArtVariant]), so all three tiers change pixels on this platform. A pin crosses FRESH to
 *  RECENT on the rebuild MapOverlaySignature.ageMinute forces: within about a minute under the
 *  Active scope (historyNow ticks every second) and about 1.5 min under Recent and All (every
 *  30 s). TWIN: iOS MapPin's ping ring, gated by animatedPinCap and Reduce Motion. */
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

/** Which of the three pin bitmap sets a tier draws: RINGED (the frozen ring, FRESH only), PLAIN
 *  (full colour, RECENT), DIMMED (STALE). */
internal enum class PinArtVariant { RINGED, PLAIN, DIMMED }

internal fun pinArtVariant(age: PinAge): PinArtVariant = when (age) {
    PinAge.FRESH -> PinArtVariant.RINGED
    PinAge.RECENT -> PinArtVariant.PLAIN
    PinAge.STALE -> PinArtVariant.DIMMED
}

/** The legend's "dimmed" row appears only while a drawn pin is STALE. The rebuild pass hands in
 *  the ids it drew a pin for, the last-seen read it already holds and its clock, and gets back the
 *  new flag only when it differs from [previous] (null = no write), so the Compose state is
 *  written on a flip and never per pass. Reuses [pinAge], so no new threshold exists.
 *  TWIN: iOS `MapSnapshot.hasStalePins` in MapTabView.swift. */
internal fun mapStalePinFlag(previous: Boolean, seenAt: Map<String, Long>, drawnIds: Collection<String>, nowMs: Long): Boolean? {
    val now = drawnIds.any { pinAge(seenAt[it], nowMs) == PinAge.STALE }
    return if (now == previous) null else now
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
 * (PinBadgeFactory), the recency tier is the ring and the dimmed artwork, the screen-reader
 * companion for the whole map is the member list the legend card's headline row opens, and a
 * pin's age IN WORDS is in the dossier the tap opens,
 * whose "Last seen" row prints it via relativeAgo (DetailScreen.kt).
 */
internal fun pinTitle(category: String, groupSize: Int): String =
    if (groupSize <= 1) category else "$groupSize detections here, showing $category"

// ---- Large-text layout rules (font scale 2.0 must leave a usable map). Pure, pinned by
// MapLayoutTest. Every px value is measured by the screen; nothing here reads a density.

/** The legend button's downloading suffix. TWIN: iOS MapTabView.legendLoadingValue in
 *  MapTabView.swift, the same words. */
internal const val MAP_LEGEND_LOADING_STATE = "loading camera data"

/** The Map legend button's spoken state (TalkBack's stateDescription): "collapsed" or "expanded",
 *  and while the known-ALPR dataset downloads, [MAP_LEGEND_LOADING_STATE] after a comma
 *  ("collapsed, loading camera data"). A download never opens the card; this suffix and the
 *  spinner badge on the button are how it shows. TWIN: iOS mapLegendAccessibilityValue in
 *  MapTabView.swift, the same four outputs. */
internal fun mapLegendStateDescription(open: Boolean, downloading: Boolean): String {
    val state = if (open) "expanded" else "collapsed"
    return if (downloading) "$state, $MAP_LEGEND_LOADING_STATE" else state
}

/** The most of the map slot the open legend card may take. TWIN: the default-size share in iOS
 *  mapLegendCardCap (MapTabView.swift), which takes it of the whole map region, not of the room
 *  under the scope header. */
internal const val MAP_LEGEND_CARD_MAX_SHARE = 0.55f

/** The open legend card's height ceiling, in px. [slotPx] is the whole map slot (the chrome
 *  included; the twin of iOS regionHeight), [roomPx] the room under the floating chrome (the
 *  card's own box, which ends at the bottom of the slot), [bottomReservePx] the card's bottom
 *  padding (the controls row, the OSM credit and the gap above it), and [gapPx] the space kept
 *  between the card's top and the chrome. The card takes at most [MAP_LEGEND_CARD_MAX_SHARE] of
 *  the slot, and less when that would run it up into the chrome, but never less than [floorPx]
 *  (its header row, one 48dp key row and its own paddings), so the honesty headline is never
 *  capped away; only that floor may reach the chrome, in a very short room. The share is of the slot, not the room: 55%
 *  of the room under the sample-data banner, the scope segments and the chips was too short on a
 *  411dp-wide phone at font scale 1.0 for the six category keys, Known ALPR, Drone operator and
 *  the credit, so the last line sat under the card's edge (iOS takes its 55% of the whole
 *  region for the same keys). Unbounded until both are measured. TWIN: iOS mapLegendCardCap in MapTabView.swift. */
internal fun mapLegendCardMaxPx(slotPx: Int, roomPx: Int, bottomReservePx: Int, floorPx: Int, gapPx: Int): Int {
    if (slotPx <= 0 || roomPx <= 0) return Int.MAX_VALUE
    val share = (slotPx * MAP_LEGEND_CARD_MAX_SHARE).toInt()
    return maxOf(floorPx, minOf(share, roomPx - bottomReservePx - gapPx))
}

/** Whether the open legend card's header row (the honesty headline and the close button) scrolls
 *  WITH the keys instead of staying fixed above them: when the header, measured at [headerPx],
 *  plus [restPx] (the least the card needs under it to show its first key row: its own paddings,
 *  the counts line and one key row) do not fit the card's ceiling [cardMaxPx]. A fixed header
 *  over a scroll window too short for one key row (a phone in portrait at font scale 2.0, where
 *  the room clamp binds) showed the counts line cut at the fold and no key at all; scrolling the
 *  header with the keys gives the keys the whole card, and the honesty line is still the first
 *  thing the open card shows. An uncapped card or an unmeasured header keeps the header fixed
 *  (nothing to scroll, or nothing known yet). TWIN: the third form of iOS legendCard's
 *  ViewThatFits (legendHeaderScroll in MapTabView.swift). */
internal fun mapLegendHeaderScrolls(cardMaxPx: Int, headerPx: Int, restPx: Int): Boolean =
    cardMaxPx != Int.MAX_VALUE && headerPx > 0 && headerPx + restPx > cardMaxPx

/** The legend card's open state and the known-ALPR callout's words (null = closed), the two
 *  things a confirmed tap on the map settles. See [afterTap]. */
internal data class MapTapState(val legendOpen: Boolean, val alprCallout: Pair<String, String>?)

/** The state after a confirmed tap on the map. Every map tap closes the legend card, whether it
 *  lands on the bare map ([ring] null: the callout closes too) or on a known-ALPR ring ([ring] =
 *  the ring's title and snippet, which the callout then shows). The ring's marker consumes its
 *  tap before the bare-map overlay sees it, so the ring path has to close the card itself: the
 *  callout only shows while the card is closed, and a ring tapped under an open card once set a
 *  callout nothing displayed. TWIN: iOS MapTabView, where the map layer's simultaneous tap
 *  gesture closes the card and the ring's Button sets showALPRInfo. */
internal fun MapTapState.afterTap(ring: Pair<String, String>?): MapTapState =
    copy(legendOpen = false, alprCallout = ring)

/** Whether the Map's two floating buttons (Map options above Center on my location) stack
 *  vertically at the lower right: while the room under the chrome ([roomPx], -1 until measured)
 *  holds the vertical stack ([stackPx], its bottom margin included) plus [creditClearancePx] (the
 *  OSM credit's height and gap, the band the chrome cap keeps free above the controls row). In a
 *  shorter room (a phone in landscape at a large font scale) the two sit side by side in the
 *  controls row, so the upper one never lands on the chrome. TWIN: iOS MapTabView's floating
 *  stack, a ViewThatFits that tries the VStack, then the HStack. */
internal fun mapFloatingStackVertical(roomPx: Int, stackPx: Int, creditClearancePx: Int): Boolean =
    roomPx < 0 || roomPx >= stackPx + creditClearancePx

/** AND-V210-3: the most height the floating chrome may be drawn at, in px: the slot minus
 *  [bottomReservePx], the band at the bottom of the map that holds the floating controls row and
 *  the OSM credit above it, so the chrome never covers a button or the credit and its own last
 *  row is never under them (at a large font scale in landscape the chip row once ran under the
 *  old legend sheet and could not be reached). A chrome taller than this scrolls inside it
 *  (MapTopChrome). The reserve is a constant plus the credit's measured height, never anything
 *  the chrome's height moves, so the two cannot feed back into each other. Unbounded until the
 *  slot is measured. */
internal fun mapChromeMaxPx(slotPx: Int, bottomReservePx: Int): Int =
    if (slotPx <= 0) Int.MAX_VALUE else (slotPx - bottomReservePx).coerceAtLeast(0)

/** Below this window height, in dp, the Map's floating chrome goes compact (M1-C): the M3
 *  compact window-height class boundary. A phone in landscape is under it; a portrait phone and a
 *  tablet in either orientation are over it, so their chrome is unchanged at font scales under
 *  [MAP_CHROME_CAP_FONT_SCALE]. */
internal const val MAP_CHROME_COMPACT_HEIGHT_DP = 480

/** From this font scale the Map's floating chrome is CAPPED whatever the window height (owner
 *  decision 2026-09-26, review P3-4 + P3-5 + AND-NAV-01 as one design): it takes the compact
 *  arrangement ([mapChromeArrangement]), so the scope segments sit at their one-line width and
 *  the category chips share a sideways-scrolling row with them instead of stacking three rows
 *  and wrapping "recent" over "· 5" (P3-4); and its own type, the "Map" title and the OSM
 *  credit plate, is drawn at no more than this scale ([mapChromeTypeScale]), so the title pill
 *  stays 56dp and the credit stays one line (P3-5). The chrome is navigation over the map, not
 *  content, so it is what the scalable-content page lets a layout adapt: the map itself keeps
 *  at least half the window at font scale 2.0 in portrait, where the stacked chrome left it
 *  about 40%. The segments' and chips' labels are NOT capped in a window at least
 *  [MAP_CHROME_COMPACT_HEIGHT_DP] tall: they scale in full and the row scrolls. In a
 *  compact-height window (a phone in landscape) they take the same cap ([mapChromeLabelScale],
 *  verify step 2026-09-26): there the full-scale segments and chips ran the chrome past its
 *  bound (mapChromeMaxPx) at 2.0, the chip row was cut at the bound above the OSM credit, and
 *  the map clear of the chrome was about a quarter of the window; at the cap the title, the
 *  segments and the chips fit ONE row. 1.5 is the large-type breakpoint this app already uses for its other reflows
 *  (LogScreen DETECTION_ROW_STACK_FONT_SCALE, DeviceScreen's stacked tiles), between the
 *  review's shots at 1.0 (the stacked chrome fits) and 2.0 (about 40% map); an Android number,
 *  not iOS's: iOS caps its Map chips and pills at accessibility2 (MapTabView filterBar), the
 *  same idea on its own scale. Pinned in MapChromeCapTest. */
internal const val MAP_CHROME_CAP_FONT_SCALE = 1.5f

/** Whether the Map chrome is in its capped, compact form: at [fontScale] >=
 *  [MAP_CHROME_CAP_FONT_SCALE], or in a window under [MAP_CHROME_COMPACT_HEIGHT_DP] tall (a
 *  phone in landscape, at any scale). */
internal fun mapChromeCapped(fontScale: Float, windowHeightDp: Int): Boolean =
    fontScale >= MAP_CHROME_CAP_FONT_SCALE || windowHeightDp < MAP_CHROME_COMPACT_HEIGHT_DP

/** The font scale the chrome's own type (the "Map" title, the OSM credit) is drawn at: the
 *  system's [fontScale] up to [MAP_CHROME_CAP_FONT_SCALE], and that cap above it. Never more
 *  than the system scale, so at 1.0 nothing moves. */
internal fun mapChromeTypeScale(fontScale: Float): Float = minOf(fontScale, MAP_CHROME_CAP_FONT_SCALE)

/** The font scale the chrome's scope-segment and category-chip labels are drawn (and measured)
 *  at: the system's [fontScale] in a window at least [MAP_CHROME_COMPACT_HEIGHT_DP] tall, where
 *  the capped chrome has a row to scroll them in; [mapChromeTypeScale] in a compact-height
 *  window (a phone in landscape), where the rows are the map (see
 *  [MAP_CHROME_CAP_FONT_SCALE]). Identity at any scale under the cap. Pinned in MapChromeCapTest. */
internal fun mapChromeLabelScale(fontScale: Float, windowHeightDp: Int): Float =
    if (windowHeightDp < MAP_CHROME_COMPACT_HEIGHT_DP) mapChromeTypeScale(fontScale) else fontScale

/** Whether the stacked chrome's scope segments draw their labels as two lines, the word over
 *  the count with no dot ("recent" over "5", P3-4): when the three segments' one-line width
 *  [segmentsPx] is more than the row they are given, [rowPx]. The caller passes the width of
 *  the labels AS DRAWN (MapChromeWidths.segmentsDrawnPx, the real counts), not the three-digit
 *  width the arrangement compares: at the default scale "active · 5" fits its segment on one
 *  line and stays there (the shipped 2.1.0 Map), while the three-digit form would not. Under
 *  the cap only: the capped chrome gives the segments their one-line width. Pinned in
 *  MapChromeCapTest. */
internal fun mapScopeLabelsStack(segmentsPx: Int, rowPx: Int): Boolean = segmentsPx > rowPx

/** The widest the stacked chrome's scope segments get (Large screen app quality LS-U2: buttons
 *  are not full width on large screens), the cap LocationContextBanner already uses in the same
 *  chrome. A phone row is narrower than this, so the cap only acts on an expanded window. */
internal val MAP_SCOPE_SEGMENTS_MAX_WIDTH = 520.dp

/** The stacked chrome's segments width in px: the row inside the 16dp gutters, capped at
 *  [MAP_SCOPE_SEGMENTS_MAX_WIDTH] ([capPx]). Pure so MapScopeSegmentsWidthTest can pin it. */
internal fun mapScopeSegmentsWidthPx(rowPx: Int, capPx: Int): Int = minOf(rowPx, capPx).coerceAtLeast(0)

/** How the Map's floating chrome lays out. STACKED: the bar, then the scope segments, then the
 *  chips, each on its own row. SCOPE_BESIDE_TITLE: the segments sit in the bar after the title,
 *  and the chips scroll on one row under it. ONE_ROW: the chips join that row too.
 *  SCOPE_WITH_CHIPS: the bar alone, then ONE row that scrolls sideways and holds the segments at
 *  their one-line width followed by the ALL chip and the category chips. */
internal enum class MapChromeArrangement { STACKED, SCOPE_BESIDE_TITLE, ONE_ROW, SCOPE_WITH_CHIPS }

/** M1-C. A window at least [MAP_CHROME_COMPACT_HEIGHT_DP] tall, under [MAP_CHROME_CAP_FONT_SCALE],
 *  keeps the stacked chrome. A shorter one (a phone in landscape, where the stacked rows covered
 *  almost all of the map), or any window at [fontScale] >= the cap ([mapChromeCapped]; a portrait
 *  phone at font scale 2.0 kept about 40% map under the stacked rows, P3-5), takes the fewest
 *  rows whose pieces all fit [rowPx] at their natural one-line widths: the title [titlePx], the
 *  segments [segmentsPx], and the ALL chip plus a minimum carousel [chipsMinPx]. Nothing is ever
 *  squeezed below its natural width, so when even the title row cannot hold the segments (a
 *  large font scale) it takes SCOPE_WITH_CHIPS (AND-V210-3): two rows, where STACKED's three did
 *  not fit a landscape map at that scale; the segments and the chips share one
 *  sideways-scrolling row at their one-line widths, so no label is clipped or wrapped. That is
 *  the arm a phone takes at font scale 2.0 in both orientations (MapChromeCapTest). All widths
 *  in px, as the screen measures them; [titlePx] is measured at the capped type scale. */
internal fun mapChromeArrangement(
    windowHeightDp: Int,
    rowPx: Int,
    titlePx: Int,
    segmentsPx: Int,
    chipsMinPx: Int,
    fontScale: Float = 1f,
): MapChromeArrangement = when {
    !mapChromeCapped(fontScale, windowHeightDp) -> MapChromeArrangement.STACKED
    titlePx + segmentsPx + chipsMinPx <= rowPx -> MapChromeArrangement.ONE_ROW
    titlePx + segmentsPx <= rowPx -> MapChromeArrangement.SCOPE_BESIDE_TITLE
    else -> MapChromeArrangement.SCOPE_WITH_CHIPS
}

/** The legend card's qualifier line under the honesty headline: how much the map projects, in
 *  iOS projectionSummary's words and order, so the line is byte-identical on both phones
 *  (decisions R17's open item, settled with the 2026-09-26 review's P1-2): "N displayed · N
 *  retained", then "N markers" when the markers and the displayed rows differ or rows were merged,
 *  then "N outside display budget" for rows past the marker cap ([omittedRows], iOS droppedRows),
 *  then "simplified" when rows were merged into a marker ([simplifiedRows], iOS mergedRows).
 *  iOS's "outside this view" clause names a count this projection does not report (MapRenderPlan
 *  has no viewport-culled total), so it is omitted, not written as zero. Plain " · " separators; the draw site holds each dot to its word
 *  (keepingMiddleDotsAttached), as iOS joins with a no-break space. Lowercase: it is a telemetry
 *  line, set in the instrument face (R16) by its Kicker, not an uppercase label. TWIN: iOS
 *  MapTabView.projectionSummary(_:). Pinned in MapProjectionSummaryTest. */
internal fun mapProjectionSummary(displayed: Int, retained: Int, markers: Int,
                                  simplifiedRows: Int, omittedRows: Int): String {
    val parts = mutableListOf("$displayed displayed", "$retained retained")
    if (markers != displayed || simplifiedRows > 0) parts.add("$markers markers")
    if (omittedRows > 0) parts.add("$omittedRows outside display budget")
    if (simplifiedRows > 0) parts.add("simplified")
    return parts.joinToString(" · ")
}

/** The legend headline's TalkBack companion count, singular for one: "1 visible map detection",
 *  "5 visible map detections". */
internal fun mapVisibleDetectionsPhrase(visibleCount: Int): String =
    if (visibleCount == 1) "1 visible map detection" else "$visibleCount visible map detections"

/** The legend's "Drone operator" key shows only while an operator marker is drawn. The rebuild
 *  pass that adds the operator markers hands in how many it drew and gets back the new flag only
 *  when it differs from [previous] (null = no write), so the Compose state is written on a flip
 *  and never per pass. TWIN of [mapStalePinFlag]; iOS twin: mapHasOperatorPins in MapTabView.swift
 *  (MapSnapshot.hasOperatorPins). */
internal fun mapOperatorPinFlag(previous: Boolean, drawnOperatorCount: Int): Boolean? {
    val now = drawnOperatorCount > 0
    return if (now == previous) null else now
}

/** One chip in the map's category row. [key] null is the fixed ALL chip. */
internal data class MapChipModel(val key: String?, val label: String, val count: Int, val selected: Boolean)

/** The map's category chips, in drawn order: the fixed ALL chip first, counting [allCount] (every
 *  in-scope located row before the category filter; iOS `snap.totalLocated`) and selected only
 *  with no filter; then the categories heard in scope ([catCounts]), the active one first and kept
 *  at zero (except WATCHED, which leaves with its last in-scope member), selected only when it is
 *  the filter. No "FILTER · x" label: the chosen chip says which lens is on, as on iOS. TWIN: iOS
 *  MapTabView's ALL chip + shownCategories. */
internal fun mapCategoryChipModels(filter: String?, allCount: Int, catCounts: Map<String, Int>): List<MapChipModel> =
    buildList {
        add(MapChipModel(null, "ALL", allCount, selected = filter == null))
        MAP_CATEGORIES.sortedByDescending { it.key == filter }.forEach { c ->
            val active = filter == c.key
            val n = catCounts[c.key] ?: 0
            if (n > 0 || (active && c.key != WATCHED_FILTER_KEY)) add(MapChipModel(c.key, c.label, n, active))
        }
    }

/** The Map options "phone breadcrumb trails" subline. FollowEvidence.SCOPE_TEXT stays the dossier
 *  Seen with you panel's line. TWIN: iOS MapTabView.breadcrumbToggleSubline, same words. */
internal const val MAP_BREADCRUMB_TOGGLE_SUBLINE =
    "draws your phone's path while the beacon kept hearing a tracker. kept in memory for this session only."

/** The first fit's top inset: the floating chrome covers the top [chromePx] of the MapView, so
 *  the fit frames the pins in the area under it. Capped at half of the bordered height, so a
 *  chrome taller than the map at a large font scale still leaves the fit an area to frame. */
internal fun mapFitTopInsetPx(mapHeightPx: Int, chromePx: Int, borderPx: Int): Int =
    chromePx.coerceIn(0, ((mapHeightPx - 2 * borderPx) / 2).coerceAtLeast(0))

/** [MapView.zoomToBoundingBox] with a top and a bottom inset: frame [box] inside the MapView minus
 *  its top [topInsetPx] (the floating chrome) and its bottom [bottomInsetPx] (the floating
 *  controls row, MAP_CONTROLS_RESERVE), [borderPx] on every side. The zoom is osmdroid's own
 *  bounding-box zoom for that smaller area, clamped the way zoomToBoundingBox clamps it. The
 *  centre is the box's Mercator middle moved up by half of (top - bottom), so the box sits centred
 *  in the area between the chrome and the controls. No inset, or a view not laid out yet or too
 *  short for the insets, falls back to the plain call. TWIN: iOS MapTabView's constant bottom
 *  safe-area inset (mapFloatingControlsInset), which keeps its first fit above the controls. */
private fun fitBetweenChrome(
    map: MapView,
    box: org.osmdroid.util.BoundingBox,
    borderPx: Int,
    topInsetPx: Int,
    bottomInsetPx: Int,
) {
    val w = map.width - 2 * borderPx
    val h = map.height - topInsetPx - bottomInsetPx - 2 * borderPx
    if ((topInsetPx <= 0 && bottomInsetPx <= 0) || w <= 0 || h <= 0) {
        map.zoomToBoundingBox(box, false, borderPx)
        return
    }
    val tiles = MapView.getTileSystem()
    // Explicit getters: MapView's zoom-limit setters take a boxed Double.
    val maxZoom = map.getMaxZoomLevel()
    var zoom = tiles.getBoundingBoxZoom(box, w, h)
    if (zoom == Double.MIN_VALUE || zoom > maxZoom) zoom = maxZoom
    zoom = zoom.coerceIn(map.getMinZoomLevel(), maxZoom)
    val midY = (tiles.getY01FromLatitude(box.latNorth, true) +
        tiles.getY01FromLatitude(box.latSouth, true)) / 2.0
    val centreY = midY - (topInsetPx - bottomInsetPx) / 2.0 / TileSystem.MapSize(zoom)
    map.controller.setZoom(zoom)
    map.controller.setCenter(GeoPoint(tiles.getLatitudeFromY01(centreY, true), box.centerWithDateLine.longitude))
}

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

/** Located detections dropped on a dark map, filterable by category and history scope. Non-RID
 *  pins use the phone position paired with their strongest located RSSI sample; drones use their
 *  broadcast coords. [focus] is a one-shot "open in map" jump from the dossier's location
 *  thumbnail: center close-in on that coordinate, then call [onFocusConsumed] so it never
 *  re-applies. [locationGranted] and [onRequestLocation] drive the location offer drawn below the
 *  chip rows (hidden in the sample data); both are defaulted so the MainScreen call compiles
 *  before it passes them. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun MapScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit,
    focus: Pair<Double, Double>? = null,
    onFocusConsumed: () -> Unit = {},
    locationGranted: Boolean = false,
    onRequestLocation: () -> Unit = {},
) {
    val context = LocalContext.current
    // The native callout's colours, rebuilt only on a contrast switch. Its only readers are
    // DarkMapInfoWindow's init and the applyColors call in the update pass; floating Compose
    // chrome reads MaterialTheme roles.
    val infoWindowColors = remember(Acab.highContrast) { mapInfoColors(Acab.palette) }
    val dynamicRings by ble.mapDynamicRings.collectAsState()
    val demo by ble.demoMode.collectAsState()
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
    // One options sheet holds the display choices and the reference layers. The history scope
    // is NOT in it: the scope is the segmented control on the map itself.
    var optionsOpen by remember { mutableStateOf(false) }
    // THE LEGEND CARD: open or closed. Starts closed and is never persisted; saveable, so a
    // rotation keeps it. The lower-left info button toggles it; the card's close button, a tap on
    // the bare map, Back, and opening a dossier, a member list or Map options close it. A known-ALPR
    // download never opens it (the button's spinner badge and its spoken state say so instead).
    // TWIN: iOS MapTabView.legendExpanded.
    var legendOpen by rememberSaveable { mutableStateOf(false) }
    // The tapped known-ALPR ring's title and snippet (AlprOverlayHolder.onRingTap), shown in the
    // Compose callout above the lower-left controls; null = closed. TWIN: iOS MapTabView.alprCallout.
    var alprCallout by remember { mutableStateOf<Pair<String, String>?>(null) }
    val mapPrefs = remember { context.getSharedPreferences("acab.map", Context.MODE_PRIVATE) }
    var showBreadcrumbs by remember {
        mutableStateOf(mapPrefs.getBoolean("show_breadcrumbs", MAP_SHOW_BREADCRUMBS_DEFAULT))
    }
    var showLabels by remember { mutableStateOf(mapPrefs.getBoolean("show_labels", false)) }
    var historyScope by remember {
        mutableStateOf(parseMapHistoryScope(mapPrefs.getString("history_scope", null)))
    }
    // A row can age out of the Active or Recent lens while the radio is quiet. One second under
    // Active (a 45 s window has to move with the clock), thirty seconds otherwise (plenty for a
    // 15-minute lens, and no permanent per-second recomposition). This is the invalidation tick
    // ONLY; the comparison clock is recentScopeClock in MapProjection.kt (see scopedIds below).
    var historyNow by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(historyScope) {
        historyNow = System.currentTimeMillis()
        while (true) {
            delay(if (historyScope == MapHistoryScope.Active) 1_000L else 30_000L)
            historyNow = System.currentTimeMillis()
        }
    }
    // A dossier can open an old/undated row from the full Log. Clear an unrelated category
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
    // detection feed itself is quiet, and when the MapView changes height (a window resize).
    // The pending Runnable is removed when the MapView releases.
    // READ inside the update block below, and that read is the whole mechanism: AndroidView runs
    // update under a snapshot observer, so without it this counter invalidates nothing and a pan
    // into a culled region draws no pins until something else recomposes the screen.
    var viewportRevision by remember { mutableIntStateOf(0) }
    val viewportRefresh = remember { arrayOfNulls<Runnable>(1) }
    // Three pin sets, one per recency tier (pinArtVariant): the FRESH set with its frozen ring,
    // the plain RECENT set, and the dimmed STALE set, each with its "icon labels" twin. All are
    // remembered per density and contrast, so switching a pin's tier is a map lookup on the
    // rebuild path and never a redraw.
    val ringedMarkers = rememberCategoryMarkers()
    val labeledRingedMarkers = rememberLabeledCategoryMarkers(ringedMarkers)
    val plainMarkers = rememberPlainCategoryMarkers()
    val labeledPlainMarkers = rememberLabeledCategoryMarkers(plainMarkers)
    val dimMarkers = rememberDimCategoryMarkers()
    val labeledDimMarkers = rememberLabeledCategoryMarkers(dimMarkers)
    val pinArt = remember(ringedMarkers, plainMarkers, dimMarkers,
                          labeledRingedMarkers, labeledPlainMarkers, labeledDimMarkers) {
        MapPinArt(ringedMarkers, plainMarkers, dimMarkers,
            labeledRingedMarkers, labeledPlainMarkers, labeledDimMarkers)
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
    // tier keys that sit in the legend card. The same hazard AlprDataset already
    // solved for unverifiedCount by publishing it as a flow. One grouped pass here, rather than
    // one scan per tier.
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
    // A callout or bubble left open across a lens change looks like it belongs to the new view, so
    // a scope change, a category chip, the ALPR layer going off, or a sheet opening closes the ALPR
    // callout and any osmdroid bubble (the Remote-ID operator explanation). A tap on the bare map
    // closes them too (the MapEventsOverlay in the factory). The first run closes nothing.
    LaunchedEffect(historyScope, filter, alprEnabled, clusterMembers != null, optionsOpen) {
        alprCallout = null
        alprHolder.clearSelection()
        liveMap.value?.let { InfoWindow.closeAllInfoWindowsOn(it) }
    }
    // How many rings are drawing wide right now, so the legend explains that size only while one
    // is on screen. Pushed from the layer's cull pass, and only when the number changes.
    var alprPeekCount by remember { mutableIntStateOf(0) }
    // Whether any pin the last rebuild drew is in the STALE tier, so the legend names the dimmed
    // look only while one is on screen. Written from the rebuild pass through mapStalePinFlag,
    // only when it flips (the alprPeekCount pattern).
    var hasStalePins by remember { mutableStateOf(false) }
    // Whether the last rebuild drew any drone operator marker, so the legend names it only while
    // one is on screen. Written through mapOperatorPinFlag, only when it flips.
    var hasOperatorPins by remember { mutableStateOf(false) }
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
    // when it runs, so every revision the ceiling skipped is already inside it. ONE snapshot, split
    // by the one predicate: the located rows feed the map, the unlocated rows feed only the
    // "without a location" count.
    val (locatedEvidence, unlocatedEvidence) = remember(mapEvidenceRev) {
        splitMapEvidence(ble.mapEvidenceSnapshot())
    }
    val located = remember(locatedEvidence) { locatedEvidence.map { it.detection } }
    // The geometry snapshot intentionally ignores ordinary RSSI/count publishes, but Active and
    // Recent membership cannot reuse the last-seen values captured with it forever: a stationary
    // device heard continuously would otherwise age out of the lens. Refresh timing in one lock on
    // the scope tick, under every scope except All. `scopedIds` has structural equality, so an
    // unchanged membership keeps the same scopedEvidence identity and does not invalidate the
    // projection cache.
    val latestMapLastSeen = remember(locatedEvidence, historyScope, historyNow) {
        if (historyScope != MapHistoryScope.All) ble.mapLastSeenSnapshot(located)
        else emptyMap()
    }
    val scopedIds = remember(locatedEvidence, historyScope, latestMapLastSeen, historyNow, demo) {
        // historyNow is ONLY the invalidation tick in the keys above; the comparison clock is a
        // wall-clock read inside recentScopeIds (recentScopeClock in MapProjection.kt, pinned by
        // MapProjectionTest). A row heard since the last tick carries a stamp NEWER than
        // historyNow, and mapHistoryIncludes rejects a stamp ahead of `now`, so a tick-based
        // comparison would drop exactly the freshest sightings out of the lens until the next
        // tick. recentScopeIds takes no `now` so the tick cannot be handed in. `demo` is the
        // sample-data bypass on Active and Recent (mapHistoryIncludes): every sample row draws
        // as active and recent, as Status and the Log count it. TWIN: iOS
        // mapScopeIncludes(isDemoMode:).
        recentScopeIds(locatedEvidence, historyScope, latestMapLastSeen, demo)
    }
    val scopedEvidence = remember(locatedEvidence, historyScope, scopedIds) {
        mapScopedLocated(locatedEvidence, historyScope, scopedIds)
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

    // WATCHED exists only while at least one IN-SCOPE located row belongs to it. A current star
    // can disappear without the detection feed changing, and under the Active scope a watched
    // row ages out after 45 s, so the effect is keyed on the in-scope WATCHED count itself (it
    // moves with an unstar, an eviction, a scope change and the membership tick alike) and drops
    // the empty lens back to ALL; historical WATCHED rows keep it alive. MapCategoryChips never
    // keeps a zero WATCHED chip for the active filter. TWIN: iOS MapTabView's
    // .onChange(of: snapshot.counts[DeviceType.watched.category]) hook and shownCategories.
    val watchedInScope = catCounts[WATCHED_FILTER_KEY] ?: 0
    LaunchedEffect(filter, watchedInScope) {
        if (filter == WATCHED_FILTER_KEY && watchedInScope == 0) {
            filter = null
        }
    }

    // SEGMENT COUNTS (contracts 5.2 / 5.3): the category lens over BOTH lists, re-read on a 1 s
    // tick under EVERY scope. A located row that aged out and is heard again moves neither the
    // membership nor a spatial field, so nothing else would restart a slower tick and "active · 0"
    // could stay up while a row is active. Separate from the membership read above on purpose:
    // that one covers every located row regardless of the chip and runs on historyNow.
    val categoryLocated = remember(locatedEvidence, filter, watchedMacs) {
        filter?.let { f -> locatedEvidence.filter { it.detection.matchesCategoryFilter(f, watchedMacs) } }
            ?: locatedEvidence
    }
    val categoryUnlocated = remember(unlocatedEvidence, filter, watchedMacs) {
        filter?.let { f -> unlocatedEvidence.filter { it.detection.matchesCategoryFilter(f, watchedMacs) } }
            ?: unlocatedEvidence
    }
    val countRows = remember(categoryLocated, categoryUnlocated) {
        ArrayList<Detection>(categoryLocated.size + categoryUnlocated.size).apply {
            categoryLocated.mapTo(this) { it.detection }
            categoryUnlocated.mapTo(this) { it.detection }
        }
    }
    val locatedIds = remember(categoryLocated) { categoryLocated.map { it.detection.id } }
    val unlocatedIds = remember(categoryUnlocated) { categoryUnlocated.map { it.detection.id } }
    var countsNow by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000L)
            countsNow = System.currentTimeMillis()
        }
    }
    // Read only here, inside derivedStateOf: the screen recomposes when a count changes VALUE,
    // never on the tick itself. One mapLastSeenSnapshot lock per second over the category lens.
    // `demo` is the same sample-data bypass the membership above applies, so "active · N" and
    // "recent · N" count the pins their scopes draw.
    val scopeCounts by remember(countRows, locatedIds, unlocatedIds, historyScope, demo) {
        derivedStateOf {
            @Suppress("UNUSED_VARIABLE")
            val tick = countsNow   // the tick, read for its subscription and nothing else
            mapScopeCounts(ble.mapLastSeenSnapshot(countRows), locatedIds, unlocatedIds,
                historyScope, recentScopeClock(), demo)
        }
    }

    // Markers outlive skipped rebuild passes, so a tap resolves the live row by id instead of
    // handing the dossier the snapshot captured whenever the marker was last built.
    // Opening a dossier closes the legend card, so the card never outlives the map it describes and
    // never competes with the dossier for Back.
    fun selectFresh(d: Detection) {
        legendOpen = false
        val id = d.id
        onSelect(ble.detections.value.firstOrNull { it.id == id } ?: d)
    }

    // The accessible one-line read of the whole surface: TalkBack cannot inspect tile pixels,
    // so the map names its own state (count, or why it is empty).
    // Keyed on the three render numbers the text reads, not on renderStats itself: a plan is a
    // data class over the whole drawn feed, so a new plan as a key would be compared field by
    // field, lists included.
    // Location-off is a real-session state: in the sample tour neither the card nor TalkBack
    // reports it (the chrome's location offer below is gated on !demo the same way).
    // TWIN: iOS MapTabView `emptyBecausePermission` / `spokenLocationDenied`,
    // `ble.locationDenied && !ble.demoMode`.
    val locationOff = !hasLocationPermission && !demo
    val mapDescription = remember(locationOff, shown.size, located.size, filter,
                                  historyScope, renderStats.symbols.size, renderStats.simplifiedRows,
                                  renderStats.omittedRows) {
        when {
            locationOff -> buildString {
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
                append(when (historyScope) {
                    MapHistoryScope.Active -> ", active forty-five seconds."
                    MapHistoryScope.Recent -> ", recent fifteen minutes."
                    MapHistoryScope.All -> ", all history."
                })
                if (renderStats.simplifiedRows > 0 || renderStats.omittedRows > 0) {
                    append(" ${renderStats.symbols.size} map symbols; ${renderStats.simplifiedRows} rows simplified")
                    if (renderStats.omittedRows > 0) append(", ${renderStats.omittedRows} omitted at this zoom")
                    append('.')
                }
            }
        }
    }
    // The legend card's honesty headline (contracts 5.4) and, under it, the qualifier line in
    // iOS projectionSummary's words (mapProjectionSummary).
    val headline = remember(shownEvidence.size, scopeCounts.withoutLocation) {
        mapHonestyHeadline(shownEvidence.size, scopeCounts.withoutLocation)
    }
    val countsLine = remember(shown.size, located.size, renderStats.symbols.size,
                              renderStats.simplifiedRows, renderStats.omittedRows) {
        mapProjectionSummary(displayed = shown.size, retained = located.size,
            markers = renderStats.symbols.size, simplifiedRows = renderStats.simplifiedRows,
            omittedRows = renderStats.omittedRows)
    }
    // An Int, never the list, so the legend card stays skippable at feed rate; its "open list"
    // action reads the current list through this holder at tap time.
    val visibleCount = visibleDetections.size
    val visibleDetectionsNow = rememberUpdatedState(visibleDetections)
    // The six category keys, always present, in the order the chips use.
    val categoryLegend = remember(Acab.highContrast) {
        listOf(
            LegendEntry(Acab.flockTone, "ALPR", hollow = false),
            LegendEntry(Acab.droneTone, "Drone", hollow = false),
            LegendEntry(Acab.bodyCamTone, "Body cam", hollow = false),
            LegendEntry(Acab.trackerTone, "Tracker", hollow = false),
            LegendEntry(Acab.glassesTone, "Glasses", hollow = false),
            LegendEntry(Acab.netcamTone, "Network camera", hollow = false),
        )
    }
    // The ALPR ring keys, the iOS words (knownALPRKey / lowerConfidenceKey in MapTabView.swift),
    // each named only while that ring can be on the map: a legend naming a colour nothing on
    // screen is using reads as a rendering bug. "Known ALPR" is the solid ring (tier 1 and the
    // legacy dataset format, rememberAlprMarker(confirmed = true)); "ALPR (lower confidence)" is
    // the amber ring the opt-in draws for tiers 0, 2 and unknown (confirmed = false), gated on
    // the opt-in for the same reason the whole list is gated on the layer.
    val tierLegend = remember(alprEnabled, alprShowUnverified, alprTierCounts, Acab.highContrast) {
        buildList {
            if (!alprEnabled) return@buildList
            if (alprTierCounts[1] > 0 || alprTierCounts[3] > 0) add(LegendEntry(
                Acab.flockTone.copy(alpha = 0.95f), "Known ALPR", hollow = true))
            if (alprShowUnverified &&
                (alprTierCounts[0] > 0 || alprTierCounts[2] > 0 || alprTierCounts[4] > 0)) add(LegendEntry(
                Acab.warn.copy(alpha = 0.95f), "ALPR (lower confidence)", hollow = true))
        }
    }
    // One grid, the six category keys then the ALPR keys, as the iOS legend lays them out.
    val keyLegend = remember(categoryLegend, tierLegend) { categoryLegend + tierLegend }

    // THE LEGEND CARD (owner decision 2026-09-26; it replaces the persistent legend sheet). The
    // map fills its slot and nothing docks over it. A round info button at the lower left opens a
    // floating card whose first line is the honesty headline, then the counts line, the one key
    // grid (six categories, then the ALPR keys), the conditional keys and the ALPR credit. Map
    // options and Center on my location float at the lower right. No control changes the
    // MapView's frame, so opening or closing the card never moves the map. The
    // "© OpenStreetMap contributors" credit is a fixed map overlay directly above the info button
    // (M1: visible at all times), and the card, the ALPR notices and the empty card sit above it.
    // TWIN: iOS MapTabView.mapLayout (the constant inset, the info button, the card, the stack).
    val density = LocalDensity.current
    // The slot height feeds the chrome cap; the chrome's natural height feeds the first fit.
    // Both are written only when they change size.
    var slotPx by remember { mutableIntStateOf(0) }
    var chromePx by remember { mutableIntStateOf(0) }
    // The room left under the chrome, -1 until measured: it bounds the legend card and decides
    // whether the lower-right buttons stack or sit side by side. Written only on a size change.
    var roomPx by remember { mutableIntStateOf(-1) }
    // The OSM credit overlay's measured height. The card, the ALPR notices and the empty card
    // stack above it by this much plus MAP_CREDIT_GAP, and the chrome cap keeps it free. Keyed on
    // density, so a density or font-scale change starts it over.
    var creditPx by remember(density) { mutableIntStateOf(0) }
    val creditClearance = with(density) { creditPx.toDp() } + MAP_CREDIT_GAP
    // AND-V210-3: the floating chrome is drawn no taller than the slot minus the controls row and
    // the credit above it, and scrolls inside that when its natural height is more (a large font
    // scale in landscape), so no chip sits under a button or the credit. Unspecified until the
    // slot is measured.
    val chromeMaxPx = mapChromeMaxPx(
        slotPx = slotPx,
        bottomReservePx = with(density) { (MAP_CONTROLS_RESERVE + creditClearance).roundToPx() },
    )
    val chromeMaxHeight = if (chromeMaxPx == Int.MAX_VALUE) Dp.Unspecified
                          else with(density) { chromeMaxPx.toDp() }
    // The legend card's header row (the honesty headline and the close button), measured for the
    // card's floor. Keyed on density like creditPx; 0 until the card first opens.
    var cardHeaderPx by remember(density) { mutableIntStateOf(0) }
    // The card's ceiling (mapLegendCardMaxPx): a share of the slot, never up into the chrome,
    // never below the header row plus the card's 4dp top padding, one 48dp key row and its 16dp
    // bottom padding (MapLegendCardContent's paddings, outside its scroll).
    val cardMaxPx = with(density) {
        mapLegendCardMaxPx(
            slotPx = slotPx,
            roomPx = roomPx,
            bottomReservePx = (MAP_CONTROLS_RESERVE + creditClearance).roundToPx(),
            floorPx = cardHeaderPx + (4.dp + 48.dp + 16.dp).roundToPx(),
            gapPx = 8.dp.roundToPx(),
        )
    }
    // The lower-right buttons stack vertically while the room holds them (mapFloatingStackVertical);
    // in a shorter room they sit side by side in the controls row.
    val stackVertical = with(density) {
        mapFloatingStackVertical(
            roomPx = roomPx,
            stackPx = MAP_FLOATING_STACK_HEIGHT.roundToPx(),
            creditClearancePx = creditClearance.roundToPx(),
        )
    }
    // The first fit frames the pins above the controls row (fitBetweenChrome). Read by the fit's
    // Runnable, never in composition.
    val controlsReservePx = with(density) { MAP_CONTROLS_RESERVE.roundToPx() }
    // Back closes the card. The card is closed before any dossier opens (selectFresh), so this
    // never competes with MainScreen's dossier BackHandler.
    BackHandler(enabled = legendOpen) { legendOpen = false }

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
    val showEmptyCard = (locationOff || scopedEvidence.isEmpty()) && !emptyDismissed
    // Recenter on the phone (the lower-right locate button).
    val onLocate = remember<() -> Unit>(myLocation) { { myLocation.value?.enableFollowLocation() } }
    val onScope: (MapHistoryScope) -> Unit = { s ->
        historyScope = s
        mapPrefs.edit().putString("history_scope", s.name).apply()
    }

    // THE SLOT, clipped (M1-A, AND-V210-1). The MapView fills it, and every floating control is
    // drawn inside it, so nothing spills over the NavigationRail or under the navigation-bar
    // inset. The slot height feeds the chrome cap; written only when the slot changes size.
    Box(Modifier.fillMaxSize().onSizeChanged { slotPx = it.height }.clipToBounds()) {
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
            // No inset: the map fills the slot and runs under the floating controls, and no
            // control ever changes its frame, so opening the legend card never moves the map.
            // The first fit keeps the chrome and the controls row clear (fitBetweenChrome).
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
                    // No zoom buttons: osmdroid draws its defaults centred on the map's bottom edge,
                    // the band the floating controls, the OpenStreetMap credit overlay and the ALPR
                    // notices already share, and pinch-zoom is the primary gesture (the iOS map
                    // shows no zoom controls either). Hide rather than reposition.
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
                        it.applyColors(infoWindowColors)
                    }
                    mapInfoWindow[0] = darkInfo   // the Remote-ID operator bubble
                    alprHolder.attach(this)   // known-ALPR layer
                    // A ring tap opens the Compose callout and closes the legend card (afterTap:
                    // the marker consumes the tap, so the bare-map overlay below never closes the
                    // card for it, and the callout only shows while the card is closed); the
                    // Remote-ID bubble closes so two explanations never stand at once.
                    alprHolder.onRingTap = { title, snippet ->
                        InfoWindow.closeAllInfoWindowsOn(this)
                        MapTapState(legendOpen, alprCallout).afterTap(ring = title to snippet).let {
                            legendOpen = it.legendOpen
                            alprCallout = it.alprCallout
                        }
                    }
                    // A tap on the bare map closes the callout, any bubble and the legend card
                    // (pans and zooms leave the card open, as Apple Maps does). First in the list,
                    // so every marker (added after it, and hit-tested first) keeps its own tap.
                    overlays.add(0, MapEventsOverlay(object : MapEventsReceiver {
                        override fun singleTapConfirmedHelper(p: GeoPoint?): Boolean {
                            MapTapState(legendOpen, alprCallout).afterTap(ring = null).let {
                                legendOpen = it.legendOpen
                                alprCallout = it.alprCallout
                            }
                            alprHolder.clearSelection()
                            InfoWindow.closeAllInfoWindowsOn(this@apply)
                            return false
                        }
                        override fun longPressHelper(p: GeoPoint?): Boolean = false
                    }))
                    // Only fires when the count changes, so a pan that leaves the number alone
                    // costs no recomposition; the pass it recomposes into early-outs of both the
                    // marker rebuild and the ALPR update, so this cannot feed itself.
                    alprHolder.onPeekCount = { alprPeekCount = it }
                    // The one 140 ms debounce behind viewportRevision: a pan or zoom schedules
                    // it, and so does a change in the MapView's HEIGHT (a window resize, a
                    // rotation), which is not a scroll or zoom event for the listener below.
                    fun scheduleViewportRefresh() {
                        viewportRefresh[0]?.let { removeCallbacks(it) }
                        val refresh = Runnable { viewportRevision++ }
                        viewportRefresh[0] = refresh
                        postDelayed(refresh, 140L)
                    }
                    addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
                        if (bottom - top != oldBottom - oldTop) scheduleViewportRefresh()
                    }
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
                            scheduleViewportRefresh()
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
                mapInfoWindow[0]?.applyColors(infoWindowColors)
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
                // the installed spatial revision and the age minute. The one geometry hot
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
                    // The ids this pass draws a PIN for (bubbles are never dimmed), for the
                    // legend's stale-pin flag below.
                    val drawnPinIds = ArrayList<String>(plan.symbols.size)
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
                    // Gated by the "phone breadcrumb trails" map setting, off by default
                    // (MAP_SHOW_BREADCRUMBS_DEFAULT).
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
                            drawnPinIds.add(d.id)
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(point.first, point.second)
                                val age = ageOf(d)
                                pinIcon(d.type, age, showLabels, pinArt, pinBadges, n)
                                title = pinTitle(d.type.category, n)
                                setOnMarkerClickListener { _, _ ->
                                    if (n == 1) selectFresh(d) else {
                                        legendOpen = false
                                        memberSheetIsViewport = false
                                        clusterMembers = ordered
                                    }
                                    true
                                }
                            })
                        } else if (members.size == 1) {
                            val d = members.first()
                            pinPts[pinN++] = group.lat; pinPts[pinN++] = group.lon
                            drawnPinIds.add(d.id)
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(group.lat, group.lon)
                                pinIcon(d.type, ageOf(d), showLabels, pinArt, pinBadges, 1)
                                title = pinTitle(d.type.category, 1)
                                setOnMarkerClickListener { _, _ -> selectFresh(d); true }
                            })
                        } else {
                            // A mixed bubble takes the neutral onSurfaceVariant: its fill then differs
                            // from the light same-spot badge as well as its size and position.
                            val tone = if (group.homogeneousCategory)
                                catTone(group.dominantCategory) else Acab.palette.onSurfaceVariant
                            fresh.add(Marker(map).apply {
                                position = GeoPoint(group.lat, group.lon)
                                icon = clusterFactory.marker(members.size, tone)
                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                title = "${members.size} detections"
                                setOnMarkerClickListener { _, _ ->
                                    legendOpen = false
                                    memberSheetIsViewport = false
                                    clusterMembers = members
                                    true
                                }
                            })
                        }
                    }
                    // drone operator pins: the muted person marker, distinct from the dots.
                    // Counted for the legend's "Drone operator" key (mapOperatorPinFlag below).
                    var operatorPins = 0
                    droneRows.forEach { d ->
                        val plat = d.pilotLat; val plon = d.pilotLon
                        if (plat != null && plon != null && validCoord(plat, plon)) {
                            operatorPins++
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
                    // Written only on a flip (contracts 5.5), so the read that subscribes this
                    // block costs one gated re-run per flip, never one per pass.
                    mapStalePinFlag(hasStalePins, seenAt, drawnPinIds, nowMs)?.let { hasStalePins = it }
                    mapOperatorPinFlag(hasOperatorPins, operatorPins)?.let { hasOperatorPins = it }
                    // Keep the PREVIOUS array whenever the pins landed in the same places. The
                    // ALPR layer early-outs on identity, and this rebuild also runs when the
                    // signature moves without a pin moving (a tracker crumb lands, the scope tick
                    // rolls ageMinute over, a label toggle), so swapping in an equal-but-new
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
                // (the locate button brings it back), and mark the one-shot pin centering
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
                        // post: the fit needs a laid-out view, and this update pass can run
                        // before the first layout on a cold tab. V-A5: the floating chrome covers
                        // the top of the MapView and the floating controls its bottom, so the fit
                        // frames the pins in the area BETWEEN them (the bottom inset is the
                        // constant MAP_CONTROLS_RESERVE). chromePx is read when the Runnable runs,
                        // outside composition, so it subscribes to nothing.
                        map.post {
                            runCatching {
                                fitBetweenChrome(map, fit.increaseByScale(1.3f), 64,
                                    mapFitTopInsetPx(map.height, chromePx, 64), controlsReservePx)
                            }
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

        // The chrome and the room under it. Nothing in this Column has a gesture modifier of its
        // own, so a pan anywhere between the controls falls through to the map.
        Column(Modifier.fillMaxSize()) {
            // Its content is measured at its natural height (unbounded, inside MapTopChrome's
            // scroll), so a map slot shorter than the chrome at a large font scale can never
            // squeeze the scope segments or the chip row (V-A2: a chrome measured into a short
            // slot gets less height than its wrapped labels need). That NATURAL height offsets
            // the first fit (V-A5). It is DRAWN no taller than chromeMaxHeight and scrolls inside
            // it (AND-V210-3).
            MapTopChrome(
                scope = historyScope,
                counts = scopeCounts,
                onScope = onScope,
                filter = filter,
                // The located rows in scope, before the category chip: what the pins represent
                // with no chip on (mapScopedLocated). TWIN: iOS snap.totalLocated.
                allCount = scopedEvidence.size,
                catCounts = catCounts,
                onFilter = { filter = it },
                showLocationOffer = !locationGranted && !demo,
                onRequestLocation = onRequestLocation,
                onNaturalHeight = { if (it != chromePx) chromePx = it },
                modifier = Modifier.heightIn(max = chromeMaxHeight),
            )
            // What is left under the chrome. Its height bounds the legend card and decides the
            // lower-right stack's shape; it holds the empty / location card, which centres in it.
            Box(Modifier.weight(1f).fillMaxWidth().onSizeChanged { roomPx = it.height }) {
                if (showEmptyCard) {
                    MapEmptyCard(
                        locationOff = locationOff,
                        hasLocated = located.isNotEmpty(),
                        scope = historyScope,
                        onDismiss = { emptyDismissed = true },
                        onOpenSettings = {
                            context.startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.fromParts("package", context.packageName, null))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        },
                        onShowAll = { onScope(MapHistoryScope.All) },
                        // V-A1: the card centres in the space above the floating controls: the
                        // vertical stack's height and 8dp while the two buttons stack, and always
                        // the controls row, the OSM credit and its gap. The card's own 16dp
                        // padding is the gap under it. Its height is capped by that space, and it
                        // scrolls when it overflows, so its action never lands under a button.
                        // TWIN: iOS mapFloatingStackReserve.
                        modifier = Modifier.align(Alignment.Center).padding(
                            bottom = if (stackVertical) {
                                maxOf(MAP_FLOATING_STACK_HEIGHT + 8.dp, MAP_CONTROLS_RESERVE + creditClearance)
                            } else {
                                MAP_CONTROLS_RESERVE + creditClearance
                            },
                        ),
                    )
                }
            }
        }
        // The ALPR callout stacks over the hint above the OSM credit, clear of the lower-right
        // buttons. Hidden while the legend card is open (the card is the one thing at the bottom
        // then); removed rather than made transparent, because Compose has no way to leave a
        // clickable in place and let touches through, and nothing else lays out around it.
        // TWIN: iOS mapBottomNotices (the callout above the hint), hidden while the card is open.
        AnimatedVisibility(
            visible = !legendOpen && (alprCallout != null || alprHint != null),
            modifier = Modifier.align(Alignment.BottomStart)
                .padding(bottom = MAP_CONTROLS_RESERVE + creditClearance),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            Column {
                alprCallout?.let { (title, snippet) ->
                    MapAlprCallout(
                        title = title, snippet = snippet,
                        endClearance = MAP_CONTROLS_END_CLEARANCE,
                        onClose = { alprCallout = null; alprHolder.clearSelection() },
                    )
                }
                alprHint?.let { MapAlprHint(it) }
            }
        }
        // THE LEGEND CARD, above the OSM credit (which stays visible and still) and the info
        // button. TWIN: iOS MapTabView.legendCard.
        MapLegendCard(
            visible = legendOpen,
            maxHeightPx = cardMaxPx,
            modifier = Modifier.align(Alignment.BottomStart)
                .padding(start = 16.dp, end = 16.dp, bottom = MAP_CONTROLS_RESERVE + creditClearance),
            headline = headline,
            countsLine = countsLine,
            visibleCount = visibleCount,
            onOpenList = {
                legendOpen = false
                memberSheetIsViewport = true
                clusterMembers = visibleDetectionsNow.value
            },
            keyLegend = keyLegend,
            hasStalePins = hasStalePins,
            hasOperatorPins = hasOperatorPins,
            alprEnabled = alprEnabled,
            alprPeekCount = alprPeekCount,
            onClose = { legendOpen = false },
            onHeaderMeasured = { if (it != cardHeaderPx) cardHeaderPx = it },
        )
        // THE INFO BUTTON, lower left: a round small FAB with the info glyph and no count (the
        // scope segments already count). It toggles the card and stays put while the card is
        // open. While the known-ALPR dataset downloads (`downloading`, not `loading`, so the
        // per-enable manifest freshness check shows nothing) it wears a spinner badge and says so
        // in its spoken state; the card stays closed. The badge takes no touches and has no
        // semantics of its own. No onClickLabel: TalkBack has no hint slot that reads the way
        // VoiceOver's "Shows the map legend" does (a recorded platform difference).
        // TWIN: iOS MapTabView's info button (mapLegendAccessibilityValue).
        Box(Modifier.align(Alignment.BottomStart).padding(start = MAP_CONTROL_MARGIN, bottom = MAP_CONTROL_MARGIN)) {
            SmallFloatingActionButton(
                onClick = { legendOpen = !legendOpen },
                shape = CircleShape,
                containerColor = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.semantics {
                    contentDescription = "Map legend"
                    stateDescription = mapLegendStateDescription(open = legendOpen, downloading = alprDownloading)
                },
            ) {
                Icon(Icons.Outlined.Info, contentDescription = null)
            }
            if (alprDownloading) {
                Box(
                    Modifier.align(Alignment.TopEnd)
                        .size(20.dp)
                        .background(MaterialTheme.colorScheme.surfaceContainer, CircleShape)
                        .clearAndSetSemantics {},
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                }
            }
        }
        // THE FLOATING STACK, lower right: Map options above Center on my location, or side by
        // side when the room is short (stackVertical). Hidden while the legend card is open, the
        // way the notices are. The locate button is not just a convenience: osmdroid's
        // MyLocationNewOverlay silently drops follow-mode the first time the user pans, and
        // exposes no way back, so without it the blue dot stops tracking for the rest of the
        // session. enableFollowLocation() re-centers on the last fix and resumes following; with
        // no fix yet it simply centers once one lands. TWIN: iOS MapTabView's settingsButton and
        // recenterButton.
        AnimatedVisibility(
            visible = !legendOpen,
            modifier = Modifier.align(Alignment.BottomEnd)
                .padding(end = MAP_CONTROL_MARGIN, bottom = MAP_CONTROL_MARGIN),
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            val layers: @Composable () -> Unit = {
                SmallFloatingActionButton(
                    onClick = { legendOpen = false; optionsOpen = true },
                    shape = CircleShape,
                    containerColor = MaterialTheme.colorScheme.secondaryContainer,
                    modifier = Modifier.semantics {
                        contentDescription = "Map options"
                        stateDescription = if (alprEnabled) "known ALPR layer on" else "known ALPR layer off"
                    },
                ) {
                    Icon(Icons.Outlined.Layers, contentDescription = null)
                }
            }
            val locate: @Composable () -> Unit = {
                SmallFloatingActionButton(
                    onClick = onLocate,
                    shape = CircleShape,
                    containerColor = MaterialTheme.colorScheme.secondaryContainer,
                ) {
                    Icon(Icons.Filled.MyLocation, contentDescription = "Center on my location")
                }
            }
            if (stackVertical) {
                Column(verticalArrangement = Arrangement.spacedBy(MAP_CONTROL_SPACING)) { layers(); locate() }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(MAP_CONTROL_SPACING)) { layers(); locate() }
            }
        }
        // Tile credit required by the OSM tile policy / ODbL, visible at all times (M1): a small
        // opaque plate at bottom-start directly above the info button, fixed to the slot, so
        // nothing (the card, a drag, a font-scale change of anything else) moves it. The chrome
        // cap keeps it free, and the card and the notices stack above it. Its end clearance keeps
        // it off the lower-right buttons (it wraps instead). Drawn LAST in this box, so nothing
        // covers it. TWIN: MapKit's own logo and Legal line above the iOS info button.
        MapOsmCredit(
            endClearance = MAP_CONTROLS_END_CLEARANCE,
            // Capped with the chrome (P3-5): at font scale 2.0 in portrait the bodySmall credit
            // wrapped to two lines in a plate about 130dp tall, over the map.
            capped = mapChromeCapped(density.fontScale, LocalConfiguration.current.screenHeightDp),
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(bottom = MAP_CONTROLS_RESERVE)
                .onSizeChanged { if (it.height != creditPx) creditPx = it.height },
        )
    }

    // The options sheet: display choices and the reference layers. Default sheet colours and
    // shape; the rows own their 16dp, so the column has no horizontal padding and no dividers.
    if (optionsOpen) {
        ModalBottomSheet(onDismissRequest = { optionsOpen = false }, modifier = Modifier.statusBarsPadding()) {
            LightSheetSystemBarIcons()
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 16.dp),
            ) {
                Text(
                    "Map options",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        .semantics { heading() },
                )
                MapOptionsHeader { Kicker("DISPLAY") }
                GroupedSwitchRow(
                    "phone breadcrumb trails",
                    showBreadcrumbs,
                    onCheckedChange = {
                        showBreadcrumbs = it
                        mapPrefs.edit().putBoolean("show_breadcrumbs", it).apply()
                    },
                    supporting = MAP_BREADCRUMB_TOGGLE_SUBLINE,
                )
                GroupedSwitchRow(
                    "icon labels",
                    showLabels,
                    onCheckedChange = {
                        showLabels = it
                        mapPrefs.edit().putBoolean("show_labels", it).apply()
                    },
                )
                // BYTE-IDENTICAL to iOS MapTabView's `mapOptionsSection("REFERENCE OVERLAYS · NOT
                // FILTERS")`, header and the ALPR note below alike: the toggles here draw
                // reference data over the map and never hide a detection, and the two sheets
                // must say so in the same words.
                MapOptionsHeader { Kicker("REFERENCE OVERLAYS · NOT FILTERS") }
                // Not GroupedSwitchRow: its `pending` would disable the row during a download,
                // and turning the layer OFF mid-download has always been allowed. The source
                // credit ("cameras: OpenStreetMap ODbL · DeFlock") is the map legend's job on both
                // phones; this note carries the privacy disclosure.
                GroupedRow(
                    headline = "known ALPR cameras",
                    modifier = Modifier.toggleable(
                        value = alprEnabled,
                        role = Role.Switch,
                        onValueChange = alpr::setEnabled,
                    ),
                    supporting = { Kicker("draws community-mapped camera locations, on by default. the dataset is one offline download; no location, viewport, or detection data is attached, and the site host sees an ordinary web request. pins are mapped locations, not live detections.") },
                    trailing = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            if (alprLoading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            // The same check-mark thumb GroupedSwitchRow draws for its sibling
                            // rows (the 4j switch anatomy). 16.dp is M3's switch icon size,
                            // inlined so this file reads no M3 switch default (the grep gate stays at 0).
                            Switch(
                                checked = alprEnabled,
                                onCheckedChange = null,
                                thumbContent = if (alprEnabled) {
                                    {
                                        Icon(Icons.Filled.Check, contentDescription = null,
                                            modifier = Modifier.size(16.dp))
                                    }
                                } else null,
                            )
                        }
                    },
                )
                if (alprEnabled) {
                    AlprDatasetRows(alpr, alprNodes, alprLoading, alprShowUnverified,
                        alprUnverifiedCount)
                }
            }
        }
    }

    // F19: cluster member-list sheet, one row per detection in the tapped bubble (or, from the
    // legend card's headline row, every detection pin inside the viewport).
    clusterMembers?.let { members ->
        ModalBottomSheet(onDismissRequest = { clusterMembers = null }, modifier = Modifier.statusBarsPadding()) {
            LightSheetSystemBarIcons()
            Column(Modifier.padding(bottom = 16.dp)) {
                // header anatomy matches the iOS ClusterListSheet: "N here" title over the kicker
                Text(
                    if (memberSheetIsViewport) "${members.size} visible" else "${members.size} here",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 16.dp).semantics { heading() },
                )
                Box(Modifier.padding(horizontal = 16.dp)) {
                    Kicker(if (memberSheetIsViewport) "VISIBLE MAP DETECTIONS" else "CLUSTERED AT THIS SPOT")
                }
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = 520.dp)) {
                    items(members, key = { it.id }) { d ->
                        // titleName, not the raw category, so the map sheet names a device the
                        // way the log two taps away does (iOS reuses the whole DetectionRow here).
                        GroupedRow(
                            headline = d.titleName,
                            modifier = Modifier.semantics(mergeDescendants = true) {
                                contentDescription =
                                    "${d.titleName}, ${d.type.category}, signal ${d.rssi} dBm"
                            },
                            supporting = { Kicker("NODE ${d.mac.replace(":", "").takeLast(4).uppercase()}") },
                            leading = { CatGlyph(d.type, size = 40) },
                            trailing = {
                                Text("${d.rssi}", style = MapMemberSignalStyle,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            },
                            onClick = { clusterMembers = null; onSelect(d) },
                        )
                    }
                }
            }
        }
    }
}

// Hoisted text styles: built once per process, never per composition (the Map body recomposes at
// feed rate). Tabular figures where a count sits beside other counts.
private val MapCountLabelStyle = AcabTypography.labelLarge.tabular()
private val MapHeadlineStyle = AcabTypography.bodyLarge.tabular()
private val MapCountsLineStyle = AcabTypography.bodyMedium.tabular()
/** A cluster member's bare signal number: the Log row's instrument face (R16, Theme.kt telemetry),
 *  because iOS draws these members as whole DetectionRows. TWIN: iOS DetectionRow signalText and
 *  LogScreen.kt LogRowSignalStyle, the same role. */
private val MapMemberSignalStyle = AcabTypography.labelMedium.telemetry()

/** Each floating button's layout box. The buttons are M3 small FABs, a 40dp disc, but the M3
 *  1.3.1 clickable Surface under a FAB applies minimumInteractiveComponentSize (javap of
 *  SurfaceKt), so each is laid out, and takes touches, in a 48dp box with the disc centred 4dp
 *  inside it. Every clearance below is measured from this box, not from the disc. TWIN: iOS
 *  mapControlSize (44pt there, the disc and the target at once). */
private val MAP_CONTROL_TARGET = 48.dp
/** The floating buttons' margin from the map slot's bottom and side edges: M3's FAB margin. TWIN:
 *  iOS mapControlMargin (its own number, measured from its own disc). */
private val MAP_CONTROL_MARGIN = 16.dp
/** Between the two lower-right buttons, stacked or side by side. TWIN: iOS mapControlSpacing. */
private val MAP_CONTROL_SPACING = 12.dp
/** The band at the bottom of the map the controls row takes, and 8dp above it: the first fit
 *  frames the pins above it (fitBetweenChrome), and the OSM credit sits on it. Constant, so the
 *  map is never re-framed by a control. TWIN: iOS mapFloatingControlsInset. */
private val MAP_CONTROLS_RESERVE = MAP_CONTROL_MARGIN + MAP_CONTROL_TARGET + 8.dp
/** How far up from the slot's bottom edge the vertical lower-right stack reaches. */
private val MAP_FLOATING_STACK_HEIGHT = MAP_CONTROL_MARGIN + MAP_CONTROL_TARGET * 2 + MAP_CONTROL_SPACING
/** The end clearance of what sits at the bottom start (the OSM credit, the ALPR notices), so it
 *  never runs under the lower-right buttons: their margin, their box, and a 16dp gap. */
private val MAP_CONTROLS_END_CLEARANCE = MAP_CONTROL_MARGIN + MAP_CONTROL_TARGET + 16.dp
/** The gap between the OSM credit overlay's top and what stacks above it (the legend card, the
 *  ALPR notices, the empty card). */
private val MAP_CREDIT_GAP = 8.dp
/** M1-C: the compact bar's gap between the "Map" title and the scope segments. */
private val MAP_CHROME_TITLE_GAP = 12.dp
/** M1-C: the compact row's width lost to the bar: the 16dp gutter either side of it and its own
 *  16dp start and 8dp end padding (MapFloatingBar). */
private val MAP_CHROME_ROW_INSET = 16.dp * 2 + 16.dp + 8.dp
/** M1-C: added to each measured segment so a px lost to rounding never wraps a label that was
 *  measured to fit. A policy margin, not an M3 number. */
private val MAP_CHROME_TEXT_SLACK = 2.dp
/** M1-C: the room before the ALL chip and after the carousel when the chips sit in the bar. */
private val MAP_CHROME_INLINE_CHIP_EDGE = 8.dp
/** M1-C: the least carousel width the one-row bar keeps beside the ALL chip, so a category chip
 *  (or the start of one, which says the row scrolls) is still in view. A policy floor, not a
 *  measured chip width. */
private val MAP_CHROME_CAROUSEL_MIN = 48.dp
/** M3's segment check slot: the 18dp icon plus its 8dp spacing. In M3 1.3.1 the segment content
 *  measures its label at the FULL width and then adds this slot beside it (javap of
 *  SegmentedButtonContentMeasurePolicy), so a label that fills the segment overflows it by this. */
private val MAP_SEGMENT_CHECK_WIDTH = 26.dp

/** The options sheet's section headers render like SectionLabel (titleSmall, onSurfaceVariant)
 *  while the call inside stays a bare `Kicker("...")`, the shape the drift needle on the
 *  REFERENCE header reads. The nested MaterialTheme re-provides typography only, only inside the
 *  open sheet. */
private val MapOptionsHeaderTypography = AcabTypography.copy(bodyMedium = AcabTypography.titleSmall)

@Composable
private fun MapOptionsHeader(content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp)
            .semantics(mergeDescendants = true) { heading() },
    ) {
        MaterialTheme(typography = MapOptionsHeaderTypography, content = content)
    }
}

/** The chrome above the map. In a window at least [MAP_CHROME_COMPACT_HEIGHT_DP] tall (a portrait
 *  phone, a tablet either way) under [MAP_CHROME_CAP_FONT_SCALE], top to bottom: the floating
 *  bar, the scope segments, the category chips and the location offer. In a shorter window (a
 *  phone in landscape), or at the cap and above in any window, the chrome goes compact (M1-C
 *  and P3-5, [mapChromeArrangement]): the scope segments move into the bar beside the title, and
 *  the chips join them when that row still has room for them, so the stacked rows no longer
 *  cover the map; when the title row cannot hold the segments, the segments and the chips share
 *  one sideways-scrolling row under the bar. The bar's title is drawn at the capped type scale
 *  ([mapChromeTypeScale]) and measured at it; the segment and chip labels at
 *  [mapChromeLabelScale] (the system scale in a tall window, the cap in a compact-height one),
 *  drawn and measured in the one pair of styles ([MapChromeLabelStyles]). No horizontal padding of its own, so the chip
 *  carousel can scroll to the screen edge; each child owns its 16dp. Map options and Center on my
 *  location are not here: they float at the lower right of the map.
 *
 *  AND-V210-3: the caller bounds the height ([mapChromeMaxPx], through [modifier]). The rows are
 *  measured at their natural height inside a vertical scroll, which [onNaturalHeight] reports,
 *  and the scroll is enabled only while that natural height is more than the bound, so a chrome
 *  that fits takes no drag from the map and one that does not fit is still reachable in full
 *  instead of running under the floating controls. */
@Composable
private fun MapTopChrome(
    scope: MapHistoryScope,
    counts: MapScopeCounts,
    onScope: (MapHistoryScope) -> Unit,
    filter: String?,
    allCount: Int,
    catCounts: Map<String, Int>,
    onFilter: (String?) -> Unit,
    showLocationOffer: Boolean,
    onRequestLocation: () -> Unit,
    onNaturalHeight: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val windowHeightDp = LocalConfiguration.current.screenHeightDp
    val fontScale = LocalDensity.current.fontScale
    // The title's style at the capped type scale (identity under the cap), drawn and measured.
    // Remembered: the copy is an allocation, and this recomposes with the scope counts.
    val titleMedium = MaterialTheme.typography.titleMedium
    val titleStyle = remember(titleMedium, fontScale) {
        titleMedium.atFontScale(mapChromeTypeScale(fontScale), fontScale)
    }
    // The segment and chip labels' styles at mapChromeLabelScale (identity in a tall window
    // under the cap), drawn and measured; remembered for the same reason as the title's.
    val labelLarge = MaterialTheme.typography.labelLarge
    val labelScale = mapChromeLabelScale(fontScale, windowHeightDp)
    val labels = remember(labelLarge, labelScale, fontScale) {
        MapChromeLabelStyles(
            label = labelLarge.atFontScale(labelScale, fontScale),
            count = MapCountLabelStyle.atFontScale(labelScale, fontScale),
        )
    }
    var naturalPx by remember { mutableIntStateOf(0) }
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val widths = rememberMapChromeWidths(counts, allCount, titleStyle, labels)
        val gutterPx = with(LocalDensity.current) { MAP_CHROME_ROW_INSET.roundToPx() }
        val arrangement = mapChromeArrangement(
            windowHeightDp = windowHeightDp,
            rowPx = constraints.maxWidth - gutterPx,
            titlePx = widths.titlePx,
            segmentsPx = widths.segmentsPx,
            chipsMinPx = widths.chipsMinPx,
            fontScale = fontScale,
        )
        val overflows = constraints.hasBoundedHeight && naturalPx > constraints.maxHeight
        // The STACKED arm's segments row (the width inside the 16dp gutters), read here at the
        // BoxWithConstraints level: `constraints` is this scope's, and the Column below is its
        // own layout scope, where the outer receiver cannot be called implicitly.
        val stackedSegmentsRowPx = constraints.maxWidth - with(LocalDensity.current) { (16.dp * 2).roundToPx() }
        Column(
            Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState(), enabled = overflows)
                // After the scroll, so this is the content's natural height, never the bound.
                .onSizeChanged { naturalPx = it.height; onNaturalHeight(it.height) }
                // The 4dp under the last row keeps its shadow (the bar's 3dp when it is the only
                // row) inside the scroll container's clip.
                .padding(top = 8.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            when (arrangement) {
                MapChromeArrangement.STACKED -> {
                    MapFloatingBar(Modifier.padding(horizontal = 16.dp), titleStyle)
                    // Capped at MAP_SCOPE_SEGMENTS_MAX_WIDTH and start-aligned under the 16dp
                    // gutter (the Column's default alignment): on an expanded window each of
                    // active / recent / all was about 600dp wide with a short label in the
                    // middle. A phone row is under the cap, so nothing moves there. The chip
                    // carousel keeps the full width because it scrolls.
                    val segmentsWidthPx = mapScopeSegmentsWidthPx(
                        rowPx = stackedSegmentsRowPx,
                        capPx = with(LocalDensity.current) { MAP_SCOPE_SEGMENTS_MAX_WIDTH.roundToPx() },
                    )
                    val segmentsWidth = with(LocalDensity.current) { segmentsWidthPx.toDp() }
                    // Under the cap a label that would not fit its segment on one line draws as
                    // the word over the count instead of "recent" over "· 5" (P3-4).
                    MapScopeSegments(scope, counts, onScope,
                        Modifier.padding(horizontal = 16.dp).width(segmentsWidth),
                        stackedLabels = mapScopeLabelsStack(widths.segmentsDrawnPx, segmentsWidthPx),
                        labels = labels)
                    MapCategoryChips(filter, allCount, catCounts, onFilter, labels = labels)
                }
                MapChromeArrangement.SCOPE_BESIDE_TITLE -> {
                    MapFloatingBar(Modifier.padding(horizontal = 16.dp), titleStyle) {
                        MapScopeSegments(scope, counts, onScope, Modifier.weight(1f), labels = labels)
                    }
                    MapCategoryChips(filter, allCount, catCounts, onFilter, labels = labels)
                }
                MapChromeArrangement.ONE_ROW -> {
                    val segmentsWidth = with(LocalDensity.current) { widths.segmentsPx.toDp() }
                    MapFloatingBar(Modifier.padding(horizontal = 16.dp), titleStyle) {
                        MapScopeSegments(scope, counts, onScope, Modifier.width(segmentsWidth), labels = labels)
                        MapCategoryChips(filter, allCount, catCounts, onFilter,
                            modifier = Modifier.weight(1f), edgePadding = MAP_CHROME_INLINE_CHIP_EDGE,
                            labels = labels)
                    }
                }
                MapChromeArrangement.SCOPE_WITH_CHIPS -> {
                    val segmentsWidth = with(LocalDensity.current) { widths.segmentsPx.toDp() }
                    MapFloatingBar(Modifier.padding(horizontal = 16.dp), titleStyle)
                    // One row for both, scrolling sideways: the segments at their measured
                    // one-line width, then ALL and the category chips. ALL scrolls with the row
                    // here (there is no room to pin it), but it stays the first chip.
                    Row(
                        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        MapScopeSegments(scope, counts, onScope, Modifier.width(segmentsWidth), labels = labels)
                        for (m in mapCategoryChipModels(filter, allCount, catCounts)) {
                            MapCategoryChip(m, onFilter, labels = labels)
                        }
                    }
                }
            }
            // Its wrapper already applies the 16dp gutter and the 520dp cap.
            if (showLocationOffer) LocationContextBanner(onAllow = onRequestLocation)
        }
    }
}

/** The natural one-line widths, in px, that [mapChromeArrangement] compares, and
 *  [segmentsDrawnPx], the segments' one-line width at the counts actually drawn, which only
 *  [mapScopeLabelsStack] reads. See [rememberMapChromeWidths] for how each is measured. */
private data class MapChromeWidths(
    val titlePx: Int,
    val segmentsPx: Int,
    val chipsMinPx: Int,
    val segmentsDrawnPx: Int,
)

/** The styles the chrome's segment and chip labels are drawn AND measured in: labelLarge for a
 *  chip's category word ([label]) and the tabular MapCountLabelStyle for every count and segment
 *  label ([count]), both at [mapChromeLabelScale] (MapTopChrome builds the pair once per scale). */
private data class MapChromeLabelStyles(val label: TextStyle, val count: TextStyle)

/** Measures the words each compact-row piece draws, with the style it draws them in, and adds the
 *  M3 padding around them. M3 1.3.1 numbers, read from the material3-release.aar bytecode with
 *  javap: a segment is TextButtonContentPadding's 12dp either side plus the check slot
 *  ([MAP_SEGMENT_CHECK_WIDTH]) beside its label, and at least ButtonDefaults.MinWidth (58dp), and
 *  the row gives every segment the widest one's width (each takes weight 1); a filter chip is its
 *  label with HorizontalElementsPadding (8dp) either side. Counts are measured at three digits or more (a count under 100 is measured as
 *  100): the figures are tabular, so every digit is one width, and the arrangement does not flip
 *  each time a count crosses 9 or 99. The segments are measured a second time at the counts as
 *  drawn ([MapChromeWidths.segmentsDrawnPx]) for the stacked arm's label form alone
 *  (mapScopeLabelsStack): that decision may move with the count, exactly as the wrap it
 *  replaces did, and at the default scale it keeps "active · 5" on one line.
 *  The title is measured in [titleStyle], the style MapFloatingBar draws it in (the capped
 *  type scale, mapChromeTypeScale), and the segments and chips in [labels], the styles they
 *  draw in (mapChromeLabelScale), so the compact rows fit what is drawn.
 *  Measured again only when a drawn label, the font scale or a style changes. */
@Composable
private fun rememberMapChromeWidths(
    counts: MapScopeCounts,
    allCount: Int,
    titleStyle: TextStyle,
    labels: MapChromeLabelStyles,
): MapChromeWidths {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val labelStyle = labels.label
    val countStyle = labels.count
    fun labels(atLeast: Int) = MapHistoryScope.entries.map { s ->
        val n = when (s) {
            MapHistoryScope.Active -> counts.active
            MapHistoryScope.Recent -> counts.recent
            MapHistoryScope.All -> counts.all
        }
        segmentLabelForDisplay(mapScopeSegmentLabel(s, maxOf(n, atLeast)))
    }
    val segmentLabels = labels(atLeast = 100)
    val drawnLabels = labels(atLeast = 0)
    val allDigits = maxOf(allCount, 100).toString()
    return remember(measurer, density, titleStyle, labels, segmentLabels, drawnLabels, allDigits) {
        fun w(text: String, style: TextStyle) =
            measurer.measure(AnnotatedString(text), style, softWrap = false, maxLines = 1).size.width
        with(density) {
            val segmentPadding = (12.dp * 2 + MAP_SEGMENT_CHECK_WIDTH + MAP_CHROME_TEXT_SLACK).roundToPx()
            val minSegment = 58.dp.roundToPx()
            fun segments(labels: List<String>) = MapHistoryScope.entries.size *
                maxOf(labels.maxOf { w(it, countStyle) } + segmentPadding, minSegment)
            MapChromeWidths(
                titlePx = w("Map", titleStyle) + MAP_CHROME_TITLE_GAP.roundToPx(),
                segmentsPx = segments(segmentLabels),
                chipsMinPx = w("ALL", labelStyle) + w(allDigits, countStyle) +
                    (8.dp + 6.dp + 8.dp).roundToPx() +
                    (MAP_CHROME_INLINE_CHIP_EDGE * 2 + 8.dp + MAP_CHROME_CAROUSEL_MIN).roundToPx(),
                segmentsDrawnPx = segments(drawnLabels),
            )
        }
    }
}

/** The floating bar: the screen title, and in the compact chrome the scope segments (and chips)
 *  after it. With the title alone (the stacked chrome, and SCOPE_WITH_CHIPS) the pill HUGS the
 *  word, start-aligned, with 16dp either side (2026-09-26 review P3-2): a full-width pill
 *  holding one word read as an empty search field beside the Log's SearchBar in the same slot,
 *  and ran about 1800dp on a tablet. With [middle] it fills the row, as the segments need. Shape,
 *  colour, shadow and the 56dp minimum are the same either way. The title draws in [titleStyle]
 *  (titleMedium at the capped type scale, MapTopChrome). Map options and Center on my location
 *  float at the lower right of the map instead (owner decision 2026-09-26). NO search field: the
 *  map has no geocoding, and a place search would send the viewport off the phone (C11, locked).
 *  NO LINK CHIP either: the connection pill lives on Status and Beacon, which are where a user
 *  goes to ask "is my board there". TWIN: iOS MapTabView draws no link chip either. */
@Composable
private fun MapFloatingBar(
    modifier: Modifier = Modifier,
    titleStyle: TextStyle = MaterialTheme.typography.titleMedium,
    // M1-C: the compact chrome's scope segments (and chips) after the title. Null (the stacked
    // chrome) lets the pill hug the title.
    middle: (@Composable RowScope.() -> Unit)? = null,
) {
    Surface(
        modifier = modifier.then(if (middle == null) Modifier else Modifier.fillMaxWidth()),
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shadowElevation = 3.dp,
    ) {
        Row(
            Modifier.heightIn(min = 56.dp).padding(start = 16.dp, end = if (middle == null) 16.dp else 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Map",
                style = titleStyle,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.semantics { heading() },
            )
            if (middle != null) {
                Spacer(Modifier.width(MAP_CHROME_TITLE_GAP))
                middle()
            }
        }
    }
}

/** Active / Recent / All as one M3 segmented row (radio semantics), each label carrying the count
 *  that segment would show. Labels may wrap at large font scales; nothing clamps them. With
 *  [stackedLabels] (the stacked chrome under the cap, when the one-line labels as drawn are
 *  wider than the row: mapScopeLabelsStack) each label is drawn as its word over its count with no dot
 *  (segmentLabelStacked, P3-4), the two lines a wrap would give it without the dot leading the
 *  second. At the cap and above the chrome gives the segments their one-line width instead.
 *  Every label draws in [labels].count, the tabular count style at mapChromeLabelScale (the
 *  style itself at the system scale unless the window is compact in height).
 *
 *  V-A2: M3 1.3.1 measures a segment's label at the FULL segment width and then adds the check's
 *  slot beside it, on every segment, selected or not (javap of SegmentedButtonContentMeasurePolicy:
 *  width = max(check, 18dp) + 8dp + label). A label that fills its segment (a wrapped label at a
 *  large font scale) therefore overflows the segment and is clipped at both edges. The label is
 *  measured [MAP_SEGMENT_CHECK_WIDTH] narrower instead, so it wraps inside the room that is left.
 *  At font scale 1.0 no label comes near that width, so nothing moves there.
 *
 *  The row takes its tallest segment's height and every segment fills it, so a wrapped label does
 *  not leave the outline jagged or poke above and below the pill (same as Log's LogScopeControl). */
@Composable
private fun MapScopeSegments(
    scope: MapHistoryScope,
    counts: MapScopeCounts,
    onScope: (MapHistoryScope) -> Unit,
    modifier: Modifier = Modifier,
    stackedLabels: Boolean = false,
    labels: MapChromeLabelStyles,
) {
    val checkPx = with(LocalDensity.current) { MAP_SEGMENT_CHECK_WIDTH.roundToPx() }
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        MapHistoryScope.entries.forEachIndexed { i, s ->
            val n = when (s) {
                MapHistoryScope.Active -> counts.active
                MapHistoryScope.Recent -> counts.recent
                MapHistoryScope.All -> counts.all
            }
            SegmentedButton(
                selected = scope == s,
                onClick = { onScope(s) },
                modifier = Modifier.fillMaxHeight(),
                shape = SegmentedButtonDefaults.itemShape(i, MapHistoryScope.entries.size),
                label = {
                    // Centred, and broken before the dot, never between the dot and the count
                    // (segmentLabelForDisplay, shared with Log's LogScopeControl), so a wrapped
                    // label does not leave "recent ·" over a lone "5"; or, when the row is
                    // known to be too narrow, the word over the count with no dot.
                    val label = mapScopeSegmentLabel(s, n)
                    Text(
                        if (stackedLabels) segmentLabelStacked(label) else segmentLabelForDisplay(label),
                        style = labels.count,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.narrowedBy(checkPx),
                    )
                },
            )
        }
    }
}

/** Measures its content [px] narrower than the width it is offered, when that width is bounded,
 *  and reports the narrower size. See MapScopeSegments for why the segment labels need it. */
private fun Modifier.narrowedBy(px: Int): Modifier = layout { measurable, constraints ->
    val maxWidth = if (constraints.hasBoundedWidth) (constraints.maxWidth - px).coerceAtLeast(0)
                   else constraints.maxWidth
    val placeable = measurable.measure(
        constraints.copy(minWidth = minOf(constraints.minWidth, maxWidth), maxWidth = maxWidth))
    layout(placeable.width, placeable.height) { placeable.place(0, 0) }
}

/** The category row: the fixed ALL chip, then a carousel of the categories heard in the current
 *  scope ([mapCategoryChipModels]). Elevated chips because a flat chip's unselected container is
 *  transparent, and text over tiles must sit on an opaque surface. The hue never fills a chip and
 *  no tone dot is drawn: a dot on the selected container fails 3:1 for flock. */
@Composable
private fun MapCategoryChips(
    filter: String?,
    allCount: Int,
    catCounts: Map<String, Int>,
    onFilter: (String?) -> Unit,
    modifier: Modifier = Modifier,
    // The room before the ALL chip and after the carousel: the 16dp screen gutter under the bar,
    // MAP_CHROME_INLINE_CHIP_EDGE inside the compact bar (M1-C).
    edgePadding: Dp = 16.dp,
    // The chip labels' styles (mapChromeLabelScale; MapTopChrome's pair).
    labels: MapChromeLabelStyles,
) {
    val models = mapCategoryChipModels(filter, allCount, catCounts)
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        // ALL is FIRST and fixed outside the category carousel, so the way back to every
        // category can never scroll offscreen (except in SCOPE_WITH_CHIPS, where the whole row
        // scrolls).
        MapCategoryChip(models.first(), onFilter, Modifier.padding(start = edgePadding), labels)
        Row(
            Modifier
                .weight(1f)
                .horizontalScroll(rememberScrollState())
                .padding(start = 8.dp, end = edgePadding),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Category chips are dynamic: a chip appears only once that category has a sighting
            // in the current scope, and the active one leads and stays even at zero (except
            // WATCHED), so the map is never filtered with no chip left to tap. The rule lives in
            // mapCategoryChipModels, pinned in MapPinTest.
            for (c in models.drop(1)) MapCategoryChip(c, onFilter, labels = labels)
        }
    }
}

/** One chip of the map's category row. The ALL chip ([MapChipModel.key] null) counts every
 *  in-scope located row whatever the filter, reads selected only with no filter, and a tap clears
 *  the filter (TWIN: iOS MapTabView's ALL chip, which counts snap.totalLocated); no check icon,
 *  its selected container is the cue, and the chip's selected state is what TalkBack reads. A
 *  category chip has checkbox semantics: tapping the selected chip clears the filter. The word
 *  draws in [labels].label (M3's labelLarge, the chip's own style, at mapChromeLabelScale) and
 *  the count in [labels].count. */
@Composable
private fun MapCategoryChip(
    model: MapChipModel,
    onFilter: (String?) -> Unit,
    modifier: Modifier = Modifier,
    labels: MapChromeLabelStyles,
) {
    ElevatedFilterChip(
        selected = model.selected,
        onClick = { onFilter(if (model.key == null || model.selected) null else model.key) },
        label = {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(model.label, style = labels.label)
                Text("${model.count}", style = labels.count)
            }
        },
        leadingIcon = if (model.key != null && model.selected) {
            {
                Icon(Icons.Filled.Check, contentDescription = null,
                    modifier = Modifier.size(FilterChipDefaults.IconSize))
            }
        } else null,
        modifier = modifier,
    )
}

/** One legend key: a swatch colour, its label, and whether the swatch is a hollow ring. */
private data class LegendEntry(val color: Color, val label: String, val hollow: Boolean)

/** The legend card: [MapLegendCardContent] on an opaque surfaceContainerHigh card (the floating
 *  bar's surface; Android has no glass), at most 420dp wide and [maxHeightPx] tall
 *  (mapLegendCardMaxPx; Int.MAX_VALUE = uncapped). It scales out of the info button's corner, or
 *  only fades while the system's animator duration scale is 0 (rememberReduceMotion). An M3
 *  Surface, so it takes the touches that land on it; a tap on the bare map beside it, or on a
 *  known-ALPR ring, closes it (afterTap). Its pane title makes TalkBack announce it. Its own
 *  composable, so the Reduce Motion read and the card skip the screen's feed-rate
 *  recompositions; the parameters are the content's plus [visible], [maxHeightPx] and
 *  [modifier] (the caller's placement). */
@Composable
private fun MapLegendCard(
    visible: Boolean,
    maxHeightPx: Int,
    headline: String,
    countsLine: String,
    visibleCount: Int,
    onOpenList: () -> Unit,
    keyLegend: List<LegendEntry>,
    hasStalePins: Boolean,
    hasOperatorPins: Boolean,
    alprEnabled: Boolean,
    alprPeekCount: Int,
    onClose: () -> Unit,
    onHeaderMeasured: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = rememberReduceMotion()
    val corner = TransformOrigin(0f, 1f)
    val maxHeight = if (maxHeightPx == Int.MAX_VALUE) Dp.Unspecified
                    else with(LocalDensity.current) { maxHeightPx.toDp() }
    AnimatedVisibility(
        visible = visible,
        modifier = modifier,
        enter = if (reduceMotion) fadeIn() else fadeIn() + scaleIn(initialScale = 0.92f, transformOrigin = corner),
        exit = if (reduceMotion) fadeOut() else fadeOut() + scaleOut(targetScale = 0.92f, transformOrigin = corner),
    ) {
        Surface(
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            shadowElevation = 3.dp,
            modifier = Modifier
                .widthIn(max = 420.dp)
                .fillMaxWidth()
                .heightIn(max = maxHeight)
                .semantics { paneTitle = "Map legend" },
        ) {
            MapLegendCardContent(
                maxHeightPx = maxHeightPx,
                headline = headline,
                countsLine = countsLine,
                visibleCount = visibleCount,
                onOpenList = onOpenList,
                keyLegend = keyLegend,
                hasStalePins = hasStalePins,
                hasOperatorPins = hasOperatorPins,
                alprEnabled = alprEnabled,
                alprPeekCount = alprPeekCount,
                onClose = onClose,
                onHeaderMeasured = onHeaderMeasured,
            )
        }
    }
}

/** The legend card's content (owner decision 2026-09-26), in order: the header row
 *  ([MapLegendCardHeader]), the honesty headline FIRST with the close button beside it; then the
 *  body ([MapLegendCardBody]): the qualifier (counts) line, ONE key grid (the six categories,
 *  then the ALPR keys), the conditional keys (dimmed, wide ring, Drone operator) and the ALPR
 *  data credit. Two forms under the card's ceiling [maxHeightPx] (mapLegendHeaderScrolls): while
 *  the header and the body's first key row fit, the header stays fixed and the body scrolls under
 *  it (a card with room hugs its content: fill = false, and the scroll has no range); when they
 *  do not (a phone in portrait at font scale 2.0), the header scrolls WITH the body, so the keys
 *  are reachable and no line is cut at the fold under a fixed header. The card's 4dp top and 16dp
 *  bottom padding sit OUTSIDE the scroll, so the fold never runs flush to the card's edge, and
 *  the fold fades while more is below it ([legendFold]): a line at the fold once read as
 *  clipping. The header's height is reported through [onHeaderMeasured] for
 *  the card's floor. The OSM tile credit is not here: it is the map's own fixed overlay under
 *  the card ([MapOsmCredit]), so it stays visible and still whether the card is open or not.
 *  Every parameter is a primitive, a string, a remembered list or a lambda, so the BLE-rate
 *  recompositions of the screen skip it. TWIN: iOS MapTabView.legendCard (its accessibility-size
 *  forms: the header fixed over scrolling keys, else legendHeaderScroll). */
@Composable
private fun MapLegendCardContent(
    maxHeightPx: Int,
    headline: String,
    countsLine: String,
    visibleCount: Int,
    onOpenList: () -> Unit,
    keyLegend: List<LegendEntry>,
    hasStalePins: Boolean,
    hasOperatorPins: Boolean,
    alprEnabled: Boolean,
    alprPeekCount: Int,
    onClose: () -> Unit,
    onHeaderMeasured: (Int) -> Unit,
) {
    // The header row and the counts line, measured for the form choice; 0 until laid out (the
    // header stays fixed until both are known). Fresh on every open: AnimatedVisibility drops
    // this content when the card closes.
    var headerPx by remember { mutableIntStateOf(0) }
    var countsPx by remember { mutableIntStateOf(0) }
    // The least the card needs under the header to show its first key row: the 4dp top and 16dp
    // bottom padding here, the body's 8dp top padding, the counts line, the grid's 8dp top
    // padding and one 48dp key row (the same row the card's floor reserves).
    val restPx = with(LocalDensity.current) { (4.dp + 16.dp + 8.dp + 8.dp + 48.dp).roundToPx() } + countsPx
    val headerScrolls = mapLegendHeaderScrolls(cardMaxPx = maxHeightPx, headerPx = headerPx, restPx = restPx)
    val scroll = rememberScrollState()
    Column(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 16.dp)) {
        val header: @Composable () -> Unit = {
            MapLegendCardHeader(
                headline = headline,
                visibleCount = visibleCount,
                onOpenList = onOpenList,
                onClose = onClose,
                onMeasured = { headerPx = it; onHeaderMeasured(it) },
            )
        }
        val body: @Composable () -> Unit = {
            MapLegendCardBody(
                countsLine = countsLine,
                keyLegend = keyLegend,
                hasStalePins = hasStalePins,
                hasOperatorPins = hasOperatorPins,
                alprEnabled = alprEnabled,
                alprPeekCount = alprPeekCount,
                onCountsMeasured = { countsPx = it },
            )
        }
        val fold = MaterialTheme.colorScheme.surfaceContainerHigh
        if (headerScrolls) {
            Column(Modifier.weight(1f, fill = false).legendFold(scroll, fold).verticalScroll(scroll)) {
                header()
                body()
            }
        } else {
            header()
            Column(Modifier.weight(1f, fill = false).legendFold(scroll, fold).verticalScroll(scroll)) { body() }
        }
    }
}

/** The height of the legend card's fold fade ([legendFold]). */
private val MAP_LEGEND_FOLD = 24.dp

/** The legend card's fold: a fade to the card's [color] over the last [MAP_LEGEND_FOLD] of the
 *  scroll window while [scroll] can move further down, and over the first while it can move back
 *  up, so a line cut at the fold reads as more to scroll, not as clipping (a Compose scroll draws
 *  no bar of its own). Applied BEFORE verticalScroll, so it draws in the window, not the content.
 *  Draw-only: the scroll reads are inside the draw pass, so a scroll redraws the fade and
 *  recomposes nothing. Nothing at all while the content fits. */
private fun Modifier.legendFold(scroll: ScrollState, color: Color): Modifier = drawWithContent {
    drawContent()
    val h = MAP_LEGEND_FOLD.toPx().coerceAtMost(size.height)
    if (scroll.canScrollForward) {
        drawRect(
            Brush.verticalGradient(listOf(Color.Transparent, color), startY = size.height - h, endY = size.height),
            topLeft = Offset(0f, size.height - h), size = Size(size.width, h),
        )
    }
    if (scroll.canScrollBackward) {
        drawRect(
            Brush.verticalGradient(listOf(color, Color.Transparent), startY = 0f, endY = h),
            topLeft = Offset.Zero, size = Size(size.width, h),
        )
    }
}

/** The legend card's header row: the honesty headline and the close button. Its height goes to
 *  [onMeasured] (the card's floor and its form choice, see [MapLegendCardContent]). */
@Composable
private fun MapLegendCardHeader(
    headline: String,
    visibleCount: Int,
    onOpenList: () -> Unit,
    onClose: () -> Unit,
    onMeasured: (Int) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Row(
        Modifier.fillMaxWidth().padding(end = 4.dp).onSizeChanged { onMeasured(it.height) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The honesty headline. While any detection pin is inside the viewport it is also
        // the sighted and TalkBack route to the list of them (osmdroid publishes no node per
        // marker); the chevron is the visible cue that the row opens something.
        Row(
            Modifier
                .weight(1f)
                .heightIn(min = 48.dp)
                .then(
                    if (visibleCount > 0) {
                        Modifier
                            .clickable(onClickLabel = "open list", role = Role.Button) { onOpenList() }
                            .semantics(mergeDescendants = true) {
                                contentDescription = "$headline. ${mapVisibleDetectionsPhrase(visibleCount)}, open list"
                            }
                    } else Modifier,
                )
                .padding(start = 16.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(headline, style = MapHeadlineStyle, color = scheme.onSurface,
                modifier = Modifier.weight(1f))
            if (visibleCount > 0) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null,
                    tint = scheme.onSurfaceVariant)
            }
        }
        // Outside the headline's clickable, so closing never opens the list. Spoken lowercase-
        // first, like every icon-only button here (CLAUDE.md copy rules). TWIN: iOS legendCard's
        // close control, the same spoken name.
        IconButton(onClick = onClose) {
            Icon(Icons.Filled.Close, contentDescription = "close map legend",
                tint = scheme.onSurfaceVariant)
        }
    }
}

/** The legend card's body under the header row: the counts line (its height goes to
 *  [onCountsMeasured] for the card's form choice), the key grid, the conditional keys and the
 *  ALPR data credit. The caller scrolls it (see [MapLegendCardContent]). */
@Composable
private fun MapLegendCardBody(
    countsLine: String,
    keyLegend: List<LegendEntry>,
    hasStalePins: Boolean,
    hasOperatorPins: Boolean,
    alprEnabled: Boolean,
    alprPeekCount: Int,
    onCountsMeasured: (Int) -> Unit,
) {
    val scheme = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Box(Modifier.padding(horizontal = 16.dp).onSizeChanged { onCountsMeasured(it.height) }) {
            // A lowercase telemetry line (mapProjectionSummary), so telemetryLine forces the
            // instrument face; each middle dot is held to its word, as the Log rows do. TWIN: iOS
            // legendCard's projectionSummary text in ACABTheme.telemetry.
            Kicker(keepingMiddleDotsAttached(countsLine), style = MapCountsLineStyle, telemetryLine = true)
        }
        LegendGrid(keyLegend, Modifier.padding(top = 8.dp))
        // PIN RECENCY: the only pin state on this map that is not a category, so the legend
        // names it, but only while a drawn pin is actually dimmed (hasStalePins, contracts
        // 5.5): a key for a look nothing on screen has reads as a rendering bug. The swatch
        // is a neutral tone dimmed by the same rule the pins use, so it demonstrates the
        // state without claiming a category. The two conditional keys name the treatment, then
        // its meaning, lowercase-first like every row (R19, settling R17's open item): the same
        // words and case as iOS legendKeys' "dimmed" and "wide ring" entries, byte-identical
        // (drift rows "map dimmed-pin legend key" / "map ring-peek legend key").
        if (hasStalePins) {
            Box(Modifier.padding(horizontal = 16.dp)) {
                LegendRow(dimTone(scheme.onSurface), "dimmed: last heard over an hour ago")
            }
        }
        // RING-PEEK: named only while a wide ring is actually drawn, same rule as the ALPR
        // keys. The wide rim is the map's only cue that a live hit landed on a camera the
        // dataset already knows about; the wide swatch shows the cue, so the words name the
        // treatment and the event, as iOS legendKeys' ring-peek entry does, byte-identical.
        if (alprEnabled && alprPeekCount > 0) {
            Box(Modifier.padding(horizontal = 16.dp)) {
                LegendRow(Acab.flockTone.copy(alpha = 0.95f),
                    "wide ring: live hit at a mapped camera", hollow = true, wide = true)
            }
        }
        // The drone operator's person marker, named only while one is drawn
        // (mapOperatorPinFlag). The swatch is the operator marker at legend size: the person
        // glyph in onSurface on a surfaceContainerHigh disc (rememberOperatorMarker's inks),
        // scaled from its 14dp glyph on a 24dp disc to 7dp on the 12dp swatch slot.
        // TWIN: iOS MapTabView's "Drone operator" legendEntry (MapSnapshot.hasOperatorPins).
        if (hasOperatorPins) {
            Row(
                Modifier.padding(horizontal = 16.dp).heightIn(min = 28.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    Modifier.size(12.dp).background(scheme.surfaceContainerHigh, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Person, contentDescription = null,
                        tint = scheme.onSurface, modifier = Modifier.size(7.dp))
                }
                Text("Drone operator", style = MaterialTheme.typography.bodyMedium,
                    color = scheme.onSurface)
            }
        }
        if (alprEnabled) {
            Text(
                "cameras: OpenStreetMap ODbL · DeFlock",
                style = MaterialTheme.typography.bodySmall,
                color = scheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
    }
}

/** "© OpenStreetMap contributors", the tile credit the OSM tile policy / ODbL requires, as a map
 *  overlay (M1): bodySmall onSurfaceVariant on a small opaque surfaceContainer plate, so it reads
 *  the same over any tile. While the chrome is [capped] (mapChromeCapped: font scale 1.5 and up,
 *  or a compact window height) it is ONE line of labelSmall at the capped type scale
 *  (mapChromeTypeScale, P3-5), never wrapped: at 1.5 that is 16.5sp, about 240dp for the 28
 *  characters, inside the 315dp a 411dp phone leaves it in portrait after its start gutter and
 *  end clearance (the numbers behind the cap; a plate that clipped the credit would break M1).
 *  The caller positions it (directly above the info button) and gives the end clearance. */
@Composable
private fun MapOsmCredit(endClearance: Dp, capped: Boolean, modifier: Modifier = Modifier) {
    Box(modifier.padding(start = 16.dp, end = endClearance)) { MapOsmCreditText(capped) }
}

/** The credit's plate. */
@Composable
private fun MapOsmCreditText(capped: Boolean) {
    val fontScale = LocalDensity.current.fontScale
    val typography = MaterialTheme.typography
    val style = remember(typography, capped, fontScale) {
        if (capped) typography.labelSmall.atFontScale(mapChromeTypeScale(fontScale), fontScale)
        else typography.bodySmall
    }
    Text(
        "© OpenStreetMap contributors",
        style = style,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = if (capped) 1 else Int.MAX_VALUE,
        softWrap = !capped,
        modifier = Modifier
            .background(MaterialTheme.colorScheme.surfaceContainer, MaterialTheme.shapes.extraSmall)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/** This style drawn as if the system font scale were [effective] instead of [actual]: size and
 *  line height scaled by their ratio, identity when they are equal (the chrome's type cap,
 *  mapChromeTypeScale). A style without a size is returned as is, as Kicker's pinned form
 *  guards. Compose applies [actual] to every sp value, so dividing by it and multiplying by the
 *  effective scale is the only way to draw sp text at a different scale than the system's. */
private fun TextStyle.atFontScale(effective: Float, actual: Float): TextStyle {
    if (effective == actual || actual <= 0f || !fontSize.isSpecified) return this
    val ratio = effective / actual
    return copy(
        fontSize = fontSize * ratio,
        lineHeight = if (lineHeight.isSpecified) lineHeight * ratio else lineHeight,
    )
}

/** Legend keys two to a row. Labels wrap inside their half (no line cap), so "Network camera" at
 *  a large font scale takes two lines instead of clipping. */
@Composable
private fun LegendGrid(entries: List<LegendEntry>, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth()) {
        entries.chunked(2).forEach { pair ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                pair.forEach { e ->
                    Box(Modifier.weight(1f)) { LegendRow(e.color, e.label, hollow = e.hollow) }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** One legend key: a coloured dot (filled, or a hollow ring for reference layers) + label. [wide]
 *  draws the ring-peek swatch, the one that is bigger on the map. The swatch sits in a fixed slot
 *  so that extra width cannot push its label out of line with every other row. The hollow ring is
 *  drawn, not a border. */
@Composable
private fun LegendRow(color: Color, label: String, hollow: Boolean = false, wide: Boolean = false) {
    Row(
        Modifier.heightIn(min = 28.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(12.dp), contentAlignment = Alignment.Center) {
            val d = if (wide) 12.dp else 10.dp
            if (hollow) {
                Box(Modifier.size(d).drawBehind {
                    drawCircle(color, radius = size.minDimension / 2 - 0.75.dp.toPx(),
                        style = Stroke(1.5.dp.toPx()))
                })
            } else {
                Box(Modifier.size(d).background(color, CircleShape))
            }
        }
        Text(label, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface)
    }
}

/** The empty / location card, with the reasons told apart. Location-off is shown even when a
 *  drone broadcast (or an older observer pin) means the map is non-empty: those pins do not make
 *  permission magically on. Dismissible (R12, matches iOS), and it never eats map gestures: the
 *  card is a plain background with no gesture modifier (never an M3 Surface, which consumes
 *  pointer input), so a pan falls through to the map; only the controls consume touch.
 *
 *  V-A1: the card is capped by the room its caller gives it and scrolls when its content is
 *  taller (the location-off body is five lines at font scale 1.0), so its action is never squeezed
 *  to a sliver above the floating controls. The scroll is enabled only while there is something to scroll, so
 *  a card that fits still lets a pan fall through to the map.
 *
 *  MAP-06: while the card overflows its room (font scale 2.0 between the chips and the floating
 *  controls), its action moves up to sit directly under the title, before the body, so the one-tap
 *  way out (Show All History, Open Settings) is never the part scrolled out of sight. Moving it
 *  changes the order, not the height, so the overflow test cannot flip back and forth. */
@Composable
private fun MapEmptyCard(
    locationOff: Boolean,
    hasLocated: Boolean,
    scope: MapHistoryScope,
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
    onShowAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val title: @Composable (String) -> Unit = { t ->
        // end padding keeps the heading clear of the dismiss button at 2x text (2026-09-04 QA)
        Text(t, style = MaterialTheme.typography.titleSmall, color = scheme.onSurface,
            modifier = Modifier.padding(end = 28.dp))
    }
    val body: @Composable (String) -> Unit = { t ->
        Text(t, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant,
            textAlign = TextAlign.Center)
    }
    val scroll = rememberScrollState()
    // Read in composition: maxValue is a snapshot state written by the scroll's layout, so the
    // card recomposes once when it first overflows (or stops overflowing), never per frame.
    val actionFirst = scroll.maxValue > 0
    Box(modifier.padding(16.dp)) {
        Column(
            Modifier
                .widthIn(max = 320.dp)
                .background(scheme.surfaceContainerHigh, MaterialTheme.shapes.medium)
                .verticalScroll(scroll, enabled = scroll.maxValue > 0)
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            when {
                locationOff -> {
                    title("Location permission is off")
                    val action: @Composable () -> Unit = {
                        TextButton(onClick = onOpenSettings) { Text("Open Settings") }
                    }
                    if (actionFirst) action()
                    body("Phone location is off. New non-drone detections cannot be positioned. " +
                        "Drones that broadcast coordinates can still appear, and existing " +
                        "phone-positioned detections stay on the map.")
                    if (!actionFirst) action()
                }
                hasLocated && scope != MapHistoryScope.All -> {
                    // The rows here DO have locations; they are simply older than the lens. Copy
                    // is byte-identical to iOS MapTabView's emptyBecauseHistoryScope branch, down
                    // to the one-tap scope switch, so the same state reads the same on both
                    // phones. The "uses your phone's position" line below deliberately does NOT
                    // render here: nothing about location is the reason, and offering it as one
                    // sends the reader to the wrong setting.
                    val action: @Composable () -> Unit = {
                        TextButton(onClick = onShowAll) { Text("Show All History") }
                    }
                    when (scope) {
                        MapHistoryScope.Active -> {
                            title("No active located detections")
                            if (actionFirst) action()
                            body("The Active map covers the last ${ACTIVE_NEARBY_WINDOW_MS / 1_000L} seconds. " +
                                "Older located detections are still retained in the Log.")
                        }
                        else -> {
                            title("No recent located detections")
                            if (actionFirst) action()
                            body("The Recent map covers the previous 15 minutes. Older located " +
                                "detections are still retained in the Log.")
                        }
                    }
                    if (!actionFirst) action()
                }
                else -> {
                    title("No located detections yet")
                    body("Detections appear here once they're heard with location available.")
                    // Scoped to THIS branch only, exactly as iOS scopes it: it explains why a
                    // detection has no location at all, which is untrue of the scope branch above.
                    body("ALPR, body cam, glasses, network camera and tracker hits use your phone's position; drones report their own.")
                }
            }
        }
        IconButton(onClick = onDismiss, modifier = Modifier.align(Alignment.TopEnd)) {
            Icon(Icons.Filled.Close, contentDescription = "dismiss", tint = scheme.onSurfaceVariant)
        }
    }
}

/** The tapped known-ALPR ring, in words: its title and snippet (alprMarkerText, so the tier line
 *  "a mapped location, not a live detection" and the DeFlock / OSM ODbL credit are always whole),
 *  with a close control. Drawn in Compose above the OSM credit rather than as an osmdroid bubble,
 *  which drew under the floating chrome and ran off the screen edge (MAP-02). Announced politely
 *  when it opens. TWIN: iOS MapTabView.alprCallout. */
@Composable
private fun MapAlprCallout(title: String, snippet: String, endClearance: Dp, onClose: () -> Unit) {
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shadowElevation = 3.dp,
        modifier = Modifier
            .padding(start = 16.dp, end = endClearance, bottom = 8.dp)
            .widthIn(max = 420.dp),
    ) {
        Row(Modifier.padding(start = 16.dp, top = 12.dp, bottom = 12.dp, end = 4.dp),
            verticalAlignment = Alignment.Top) {
            Column(
                Modifier.weight(1f).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(title, style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface)
                Text(snippet, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = onClose) {
                Icon(Icons.Filled.Close, contentDescription = "close mapped camera information")
            }
        }
    }
}

/** Why the ALPR layer draws nothing (failed load vs zoomed out). Opaque, bottom start, above the
 *  OSM credit; the end inset ([MAP_CONTROLS_END_CLEARANCE]) keeps it clear of the lower-right
 *  buttons. */
@Composable
private fun MapAlprHint(hint: String, modifier: Modifier = Modifier) {
    Text(
        hint,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurface,
        textAlign = TextAlign.Center,
        modifier = modifier
            .padding(start = 16.dp, end = MAP_CONTROLS_END_CLEARANCE, bottom = 16.dp)
            .widthIn(max = 320.dp)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh, MaterialTheme.shapes.small)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

/** The pin sets the update pass chooses between: one per recency tier (pinArtVariant), each with
 *  and without the "icon labels" under-icon type tag. Bundled so the pass picks artwork with one
 *  call instead of threading six sets through every marker it builds. */
private class MapPinArt(
    val ringed: Map<DeviceType, BitmapDrawable>,
    val plain: Map<DeviceType, BitmapDrawable>,
    val dim: Map<DeviceType, BitmapDrawable>,
    val labeledRinged: LabeledMarkers,
    val labeledPlain: LabeledMarkers,
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
    val variant = pinArtVariant(age)
    val base: BitmapDrawable
    val baseAnchorV: Float
    if (showLabels) {
        val set = when (variant) {
            PinArtVariant.RINGED -> art.labeledRinged
            PinArtVariant.PLAIN -> art.labeledPlain
            PinArtVariant.DIMMED -> art.labeledDim
        }
        base = set.icons.getValue(type)
        baseAnchorV = set.anchorV
    } else {
        base = when (variant) {
            PinArtVariant.RINGED -> art.ringed
            PinArtVariant.PLAIN -> art.plain
            PinArtVariant.DIMMED -> art.dim
        }.getValue(type)
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

// Count grouping policy, both platforms: DATASET sizes on these captions group by the device
// locale ("12,345" / "12 345" / "12.345"), because they are chrome, not evidence; iOS uses
// Int.formatted() for the same captions in MapTabView. Session counters (tiles, log headers)
// stay ungrouped on both platforms. Until 2026-09-02 this file pinned Locale.US here, so once a
// count reached 1,000 the caption disagreed with iOS on any phone whose locale groups digits
// differently from en-US (12 345, 12.345, 1,23,456).

/** The dataset line's count noun, the iOS word: "132,331 cameras", "1 camera", grouped digits.
 *  It counts what the map draws (the caller drops the hidden lower-confidence pins). */
private fun alprCameraCount(n: Int): String =
    String.format(java.util.Locale.getDefault(), "%,d camera%s", n, if (n == 1) "" else "s")

/** [alprCameraCount] in Title Case, for the check-for-updates row's "Updated · N Cameras" flash:
 *  that row is an action, and actions are title-cased; the caption keeps the lowercase noun. */
private fun alprCameraCountTitle(n: Int): String =
    String.format(java.util.Locale.getDefault(), "%,d Camera%s", n, if (n == 1) "" else "s")

/** The caption under the Map options "lower-confidence pins" toggle. Says what the tier MEANS
 *  rather than naming it, because "unverified" invites the reading that we checked and it failed;
 *  and it says pins, not cameras, because some of them are not cameras. [count] is the
 *  lower-confidence pin count with grouped digits; one pin reads "pin is". TWIN: iOS
 *  alprLowerConfidenceLine(count:showing:) in MapTabView.swift, the same words. */
internal fun alprLowerConfidenceLine(
    count: Int,
    showing: Boolean,
    locale: java.util.Locale = java.util.Locale.getDefault(),
): String {
    val n = String.format(locale, "%,d", count)
    val one = count == 1
    return if (showing)
        "showing $n ${if (one) "pin" else "pins"} without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras."
    else
        "$n lower-confidence ${if (one) "pin is" else "pins are"} hidden. some are not cameras."
}

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

/** Dataset status + manual refresh for the known-ALPR layer, shown in the options sheet only
 *  while the layer is on. The caption reads count / dataset date / last manifest check straight
 *  off the store; the row re-runs the store's existing refresh path (manifest check -> conditional
 *  download -> sha256 verify) and flashes the outcome inline. Double-taps are guarded twice:
 *  the row is not clickable while a fetch is in flight, and the store's own fetch gate drops
 *  extras. */
@Composable
private fun AlprDatasetRows(alpr: AlprStore, nodes: IntArray, loading: Boolean,
                            showUnverified: Boolean, unverifiedCount: Int) {
    val updated by alpr.updated.collectAsState()
    val lastChecked by alpr.lastChecked.collectAsState()
    var awaiting by remember { mutableStateOf(false) }            // a tap-initiated check is out
    var outcome by remember { mutableStateOf<Pair<String, Boolean>?>(null) }   // msg to isSuccess

    val caption = buildString {
        // Count what the map DRAWS. Captioning the full dataset while hiding a chunk of it makes
        // the toggle below look broken (the number never moves) and overstates the coverage.
        val n = (nodes.size / 2).let { if (showUnverified) it else it - unverifiedCount }
        if (n > 0) {
            append(alprCameraCount(n))
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
                    "Updated · ${alprCameraCountTitle(alpr.nodes.value.size / 2)}" to true
                AlprStore.RefreshOutcome.UP_TO_DATE -> "Up to Date" to true
                else -> "Couldn't Check" to false
            }
            delay(2500)
            outcome = null
        }
    }

    Text(
        caption,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
    // Opt-in for the tier nobody could name a manufacturer for. Off by default because those pins
    // are where "your app is wrong" reports come from: the user drives to one, finds an empty pole,
    // and blames the detector rather than the stranger who mapped it. Kept as a row instead of
    // dropped from the dataset so mappers who want to see and fix them still can. Mirrors iOS
    // (the "lower-confidence pins" toggle and alprLowerConfidenceLine).
    if (unverifiedCount > 0) {
        GroupedSwitchRow(
            "lower-confidence pins",
            showUnverified,
            onCheckedChange = { alpr.setShowUnverified(it) },
            supporting = alprLowerConfidenceLine(unverifiedCount, showUnverified),
        )
    }
    val done = outcome
    val succeeded = done?.second == true
    GroupedRow(
        headline = when {
            loading -> "Checking"
            done != null -> done.first
            else -> "Check for Updates"
        },
        leading = {
            if (loading) {
                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            } else {
                Icon(
                    if (succeeded) Icons.Filled.Check else Icons.Filled.Refresh,
                    contentDescription = null,
                    tint = if (succeeded) MaterialTheme.colorScheme.primary
                           else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        onClick = if (loading) null else {
            {
                awaiting = true
                outcome = null
                alpr.refresh()
            }
        },
    )
}

/** Tint for a category key, for a single-category cluster bubble. Anything that is not one of the
 *  filterable categories (a nearby-device or unknown bubble) takes the same neutral as a mixed
 *  bubble, onSurfaceVariant: crimson is the app's one accent and never paints ambient devices. */
private fun catTone(cat: String): Color = when (cat) {
    "ALPR" -> Acab.flockTone
    "DRONE" -> Acab.droneTone
    "BODY CAM" -> Acab.bodyCamTone
    "TRACKER" -> Acab.trackerTone
    "GLASSES" -> Acab.glassesTone
    "CAMERA" -> Acab.netcamTone
    WATCHED_FILTER_KEY -> Acab.watchTone
    else -> Acab.palette.onSurfaceVariant
}

/** One entry in the ordered category set the map's chips use. [key] is the DeviceType.category
 *  the filter matches on; [label] is the chip's display text. Defined once here (mirrors iOS) so
 *  a new category is added in a single place. "Nearby Device" is deliberately absent: it is
 *  ambient noise, not a filter category. */
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
