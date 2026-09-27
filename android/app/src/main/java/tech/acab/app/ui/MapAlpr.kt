package tech.acab.app.ui

import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.TextView
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.FolderOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.infowindow.MarkerInfoWindow
import tech.acab.app.R
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.AcabPalette

/** Shared palette contract for the native map callout (DarkMapInfoWindow). The surface is
 * deliberately opaque: contrast must not change with a pale road tile, satellite imagery, or the
 * dark tile filter. Role colours (surfaceContainer, onSurface, onSurfaceVariant) and no border:
 * Route A draws no hairlines (L1), and the callout's elevation separates it from the tiles. */
internal data class MapInfoColors(
    val surface: Color,
    val primaryText: Color,
    val secondaryText: Color,
)

internal fun mapInfoColors(palette: AcabPalette): MapInfoColors = MapInfoColors(
    surface = palette.surfaceContainer,
    primaryText = palette.onSurface,
    secondaryText = palette.onSurfaceVariant,
)

/** Dark replacement for osmdroid's bundled light-grey bubble and hardcoded black type, for the
 * Remote-ID operator explanations on the main map. The known-ALPR rings no longer use it: a ring tap
 * opens the Compose callout MapScreen draws above the OSM credit ([AlprOverlayHolder.onRingTap]),
 * because this bubble drew under the floating chrome and ran off the screen edge (MAP-02). */
internal class DarkMapInfoWindow(mapView: MapView) :
    MarkerInfoWindow(R.layout.map_info_window, mapView) {
    private var applied: MapInfoColors? = null

    init {
        applyColors(mapInfoColors(Acab.palette))
    }

    fun applyColors(colors: MapInfoColors) {
        if (colors == applied) return
        applied = colors
        val density = mView.resources.displayMetrics.density
        mView.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor(colors.surface.toArgb())
            cornerRadius = 12f * density
        }
        mView.findViewById<TextView>(R.id.bubble_title)?.setTextColor(colors.primaryText.toArgb())
        mView.findViewById<TextView>(R.id.bubble_description)
            ?.setTextColor(colors.secondaryText.toArgb())
        mView.findViewById<TextView>(R.id.bubble_subdescription)
            ?.setTextColor(colors.secondaryText.toArgb())
        mView.elevation = 8f * density
    }

    override fun onOpen(item: Any?) {
        super.onOpen(item)
        val marker = item as? Marker ?: return
        mView.contentDescription = listOfNotNull(
            marker.title?.takeIf(String::isNotBlank),
            marker.snippet?.takeIf(String::isNotBlank),
            marker.subDescription?.takeIf(String::isNotBlank),
        ).joinToString(". ")
        mView.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    override fun onClose() {
        mView.contentDescription = null
        super.onClose()
    }
}

/** Source credit, one copy, tail of every reference-ring snippet. */
private const val ALPR_CREDIT = "DeFlock / OSM ODbL"

/** RING-PEEK, in words. The wide rim is a purely visual cue, so the ring's callout (and TalkBack
 *  reading it out) carries the same fact, the way iOS appends it to the ring's VoiceOver label.
 *  Says what was HEARD, not what was verified: a wide ring means a live detection landed on this
 *  mapped location, never that the mapped camera is confirmed or that the heard device is it. */
internal const val ALPR_PEEK_SNIPPET = "wide ring: a live detection was heard at this mapped location"

/** The callout title for a dataset row of tier 0, 1 or 2, BYTE-IDENTICAL to iOS
 *  ALPRAttribution.headline(tier:maker:) in ALPRDataset.swift, default arm included (iOS reads
 *  every other tier as tier 0; [alprMarkerText] only hands this 0, 1 and 2). A maker on a tier 0 or
 *  2 row carries a "?": the tag names it, nothing structured backs it. */
internal fun alprAttributionHeadline(tier: Int, maker: String): String = when (tier) {
    1 -> if (maker.isEmpty()) "mapped ALPR · sourced from DeFlock" else "$maker · mapped ALPR, via DeFlock"
    2 -> if (maker.isEmpty()) "ALPR candidate · legacy OSM tag" else "$maker? · legacy-tag ALPR candidate"
    else -> if (maker.isEmpty()) "mapped ALPR · canonical OSM tag" else "$maker? · canonical OSM ALPR"
}

/** User-visible attribution copy for one dataset row. These tiers describe source structure, not
 * external verification, so the words confirmed/unverified deliberately never appear. Tiers 0, 1
 * and 2 take the iOS titles ([alprAttributionHeadline]); the legacy dataset format and an unknown
 * tier are Android-only states and keep their own titles. [peek] adds the ring-peek sentence for a
 * ring a live detection pin is standing on, and nothing else: the title and the tier body stay
 * byte-identical, because the peek says something about the DETECTION, not about this row's
 * attribution. */
internal fun alprMarkerText(rawTier: Int, maker: String, peek: Boolean = false): Pair<String, String> {
    val title = when {
        rawTier == 0 || rawTier == 1 || rawTier == 2 -> alprAttributionHeadline(rawTier, maker)
        rawTier == ALPR_TIER_LEGACY_FORMAT && maker.isNotEmpty() ->
            "$maker ALPR camera, legacy dataset format"
        rawTier == ALPR_TIER_LEGACY_FORMAT -> "ALPR camera, legacy dataset format"
        maker.isNotEmpty() -> "$maker ALPR record, unknown attribution tier"
        else -> "ALPR record, unknown attribution tier"
    }
    // The resting body says "not a live detection" because a ring is a mapped RECORD, not proof
    // that anything transmitted. On a peeking ring that clause would contradict the peek sentence
    // in the same string, so it drops out: the peek sentence then carries the whole claim, and it
    // still only says what the beacon HEARD here, never that this camera is verified.
    val body = when (rawTier) {
        0 -> "canonical mapped ALPR, no structured manufacturer"
        2 -> if (peek) "legacy alias candidate" else "legacy alias candidate, not a live detection"
        ALPR_TIER_LEGACY_FORMAT -> "mapped by a legacy dataset without attribution tiers"
        1 -> if (peek) "a mapped location" else "a mapped location, not a live detection"
        else -> if (peek) "unknown attribution tier" else "unknown attribution tier, not a live detection"
    }
    val snippet = if (peek) "$body · $ALPR_PEEK_SNIPPET · $ALPR_CREDIT" else "$body · $ALPR_CREDIT"
    return title to snippet
}

/** How close a rendered detection pin has to be to a mapped-ALPR node before that node's ring
 *  draws WIDE (see rememberAlprMarker's peek variant). 25 m is about the spread between a
 *  phone-positioned sighting and the pole the camera is actually bolted to; wider starts claiming
 *  cameras the hit had nothing to do with, tighter misses the match that matters.
 *  THE SHARED NUMBER: iOS ALPRRingPeek.radiusMeters is the same 25 and both suites assert it. The
 *  enlarged ring's SIZE is deliberately not shared (each platform's pin artwork differs, so each
 *  derives its own; see rememberAlprMarker), but the match radius is one contract. */
internal const val ALPR_PEEK_RADIUS_M = 25.0

private const val METERS_PER_DEG_LAT = 111_320.0

/**
 * The detection pins of one map pass, bucketed into [ALPR_PEEK_RADIUS_M]-tall latitude bands so a
 * ring can ask "is any pin standing on me?" without walking the whole pin list.
 *
 * COST, honestly. Building this is one pass over the pins. Each [matches] call then reads at most
 * three buckets (the ring's own band and its two neighbours, which are the only bands that can
 * hold a point within the radius), so the common "no pin anywhere near this ring" case costs three
 * failed map lookups rather than one compare PER PIN. The plain linear version this replaced was
 * O(rings x pins): 500 rings against a few hundred pins is up to ~300k iterations for a pass that
 * usually matches nothing. Mirrors iOS ALPRRingPeek.matches, which bands the same way.
 *
 * Distances are equirectangular, exact to well under a metre at this range, with the longitude
 * scale taken from the RING: anything close enough to match is within 25 m, where the difference
 * between the two latitudes is far below GPS noise.
 */
internal class AlprPeekBands(pins: DoubleArray) {
    /** band index -> that band's pins, interleaved lat/lon. */
    private val bands: Map<Int, DoubleArray>

    init {
        // Transient boxing in the accumulator, then one flat DoubleArray per band: this runs once
        // per pin-set change over a few hundred points, never per ring and never per frame.
        val acc = HashMap<Int, MutableList<Double>>()
        var i = 0
        while (i + 1 < pins.size) {   // a truncated trailing half-pair is ignored, never read past
            val lat = pins[i]
            val lon = pins[i + 1]
            i += 2
            if (!usable(lat, lon)) continue
            acc.getOrPut(band(lat)) { ArrayList() }.apply { add(lat); add(lon) }
        }
        bands = if (acc.isEmpty()) emptyMap()
                else acc.mapValues { (_, v) -> v.toDoubleArray() }
    }

    /** No usable pins at all, so nothing can peek. Lets callers skip the per-ring loop entirely. */
    val isEmpty: Boolean get() = bands.isEmpty()

    /** True when a pin sits within [ALPR_PEEK_RADIUS_M] of [lat]/[lon]. */
    fun matches(lat: Double, lon: Double): Boolean {
        if (bands.isEmpty() || !usable(lat, lon)) return false
        val mPerDegLon = METERS_PER_DEG_LAT * Math.cos(Math.toRadians(lat))
        val home = band(lat)
        // Neighbours included on purpose: a band edge falls wherever it falls, so a ring and the
        // pin standing on it routinely land either side of one. Bands are radius-tall, so two
        // neighbours are enough; nothing further out can be within the radius.
        for (b in home - 1..home + 1) {
            val pins = bands[b] ?: continue
            var i = 0
            while (i + 1 < pins.size) {
                val y = (pins[i] - lat) * METERS_PER_DEG_LAT
                val x = (pins[i + 1] - lon) * mPerDegLon
                i += 2
                if (x * x + y * y <= ALPR_PEEK_RADIUS_M * ALPR_PEEK_RADIUS_M) return true
            }
        }
        return false
    }

    private companion object {
        private const val BAND_DEG = ALPR_PEEK_RADIUS_M / METERS_PER_DEG_LAT

        private fun band(lat: Double): Int = Math.floor(lat / BAND_DEG).toInt()

        /** A coordinate that can be bucketed without trapping. A corrupt cache row or a bad fix
         *  must degrade to "no match", never to a NaN or an out-of-range Double turning into a
         *  garbage band index. Mirrors iOS ALPRRingPeek.usable. */
        private fun usable(lat: Double, lon: Double): Boolean =
            !lat.isNaN() && !lon.isNaN() && !lat.isInfinite() && !lon.isInfinite() &&
                Math.abs(lat) <= 90.0 && Math.abs(lon) <= 180.0
    }
}

/** The four ring bitmaps the reference layer can draw: two attribution tiers, each in its normal
 *  and its ring-peek size. Bundled so the layer's update call keeps one identity check per input
 *  instead of four. */
class AlprRingIcons(
    val primary: BitmapDrawable,
    val unverified: BitmapDrawable,
    val primaryPeek: BitmapDrawable,
    val unverifiedPeek: BitmapDrawable,
)

/**
 * Manages the known-ALPR reference layer as its own osmdroid overlay, separate from the
 * Compose-driven detection markers. osmdroid doesn't recompose on pan/zoom, so this attaches a
 * debounced map listener that re-culls the (potentially large) camera set to the current viewport
 * without rebuilding the detection markers. Rendering only kicks in past a zoom threshold, and the
 * per-view count is capped, so the map stays responsive even with a big dataset.
 *
 * TWO SEPARATE JOBS, on purpose. [update] culls the whole dataset to the viewport and builds
 * markers; [setPeekPins] only re-stamps icons on the markers that cull already produced. The two
 * run at completely different cadences (viewport changes are gestures; the pin set changes every
 * time a new device is heard), and folding them together is what made a drive test rebuild the
 * layer continuously.
 */
class AlprOverlayHolder {
    private val folder = FolderOverlay()
    private val handler = Handler(Looper.getMainLooper())
    private var attachedTo: MapView? = null
    private var mapListener: MapListener? = null   // kept so detach() can remove it (no post-detach rebuilds)

    /** A ring tap: the tapped ring's title and snippet ([alprMarkerText]) for MapScreen's Compose
     *  callout. Fired again, with the new words, when the peek pass rewrites the SELECTED ring's
     *  copy (a live pin arrives on it or leaves it), so the open callout never reads stale. */
    var onRingTap: ((title: String, snippet: String) -> Unit)? = null
    // The selected ring, by coordinate: a re-cull (pan, zoom) rebuilds every Marker, so identity
    // would not survive it. NaN = nothing selected.
    private var selectedLat = Double.NaN
    private var selectedLon = Double.NaN

    /** Forget the selected ring (MapScreen closed the callout), so later peek passes stay quiet. */
    fun clearSelection() {
        selectedLat = Double.NaN
        selectedLon = Double.NaN
    }

    private fun isSelected(r: RingMarker): Boolean = r.lat == selectedLat && r.lon == selectedLon

    // Latest inputs, pushed from the Compose update pass.
    private var nodes: IntArray = IntArray(0)   // interleaved latE7, lonE7
    private var makerIdx: IntArray = IntArray(0)   // per-node maker index (parallel to nodes/2)
    private var makerTable: Array<String> = arrayOf("")
    private var confirmed: BooleanArray = BooleanArray(0)   // per-node tier, parallel to nodes/2
    private var rawTier: IntArray = IntArray(0)   // 0 no structured maker, 1 attributed, 2 legacy candidate
    private var enabled = false
    private var showUnverified = false   // draw the no-manufacturer tier at all (default off)
    private var icons: AlprRingIcons? = null
    // RING-PEEK: coordinates of the detection pins drawn by the Compose pass, interleaved lat/lon,
    // plus the latitude-band index built from them. A ring within ALPR_PEEK_RADIUS_M of one of
    // these draws wide so its rim clears the pin.
    private var peekPins: DoubleArray = DoubleArray(0)
    private var peekBands = AlprPeekBands(DoubleArray(0))

    /** One drawn ring, kept so the peek pass can restyle it without re-culling: the coordinate to
     *  test, the copy to rewrite, and the marker to restyle. At most [CAP] of these exist. */
    private class RingMarker(
        val lat: Double,
        val lon: Double,
        val tier: Int,
        val maker: String,
        val primary: Boolean,
        val marker: Marker,
    ) {
        var peek = false
    }

    /** The rings this viewport cull drew, in folder order. */
    private val rings = ArrayList<RingMarker>()

    /** Reports how many rings are currently drawn wide, so the legend can explain the wide ring
     *  only while one is actually on screen (a legend row naming something nothing on screen is
     *  using reads as a rendering bug). Fired from [applyPeek], and only when the number changes. */
    var onPeekCount: ((Int) -> Unit)? = null
    private var lastPeekCount = -1

    companion object {
        const val MIN_ZOOM = 11.0     // don't draw cameras zoomed further out than ~city level
        private const val CAP = 500           // max markers drawn in one viewport (matches iOS ALPRDataset)
        private const val DEBOUNCE_MS = 140L
    }

    /** Add our folder to the map (once) and start listening for pan/zoom. */
    internal fun attach(map: MapView) {
        if (attachedTo === map) return
        attachedTo = map
        if (!map.overlays.contains(folder)) map.overlays.add(folder)
        mapListener = object : MapListener {
            override fun onScroll(event: ScrollEvent?): Boolean { scheduleRebuild(map); return false }
            override fun onZoom(event: ZoomEvent?): Boolean { scheduleRebuild(map); return false }
        }.also { map.addMapListener(it) }
    }

    /** Push the current dataset + layer state from Compose and redraw now. Early-outs when nothing
     *  changed: the ~3 Hz detection publishes re-run the Compose update pass, and without this gate
     *  every publish re-scanned the full node array (119k nodes) and re-alloc'd up to CAP markers
     *  on the main thread. All the inputs are stable references (StateFlow value / remember), so
     *  identity checks are sound; viewport changes are covered by the debounced pan/zoom listener
     *  attach() installs, which re-culls without coming through here.
     *  The detection pins are NOT an input here on purpose: see [setPeekPins]. */
    fun update(map: MapView, nodes: IntArray, makerIdx: IntArray, makerTable: Array<String>,
               confirmed: BooleanArray, rawTier: IntArray, icons: AlprRingIcons,
               enabled: Boolean, showUnverified: Boolean) {
        if (nodes === this.nodes && makerIdx === this.makerIdx && enabled == this.enabled &&
            makerTable === this.makerTable && confirmed === this.confirmed &&
            rawTier === this.rawTier && showUnverified == this.showUnverified &&
            icons === this.icons) return
        this.nodes = nodes
        this.makerIdx = makerIdx
        this.makerTable = makerTable
        this.confirmed = confirmed
        this.rawTier = rawTier
        this.enabled = enabled
        this.showUnverified = showUnverified
        this.icons = icons
        rebuild(map)
    }

    /** RING-PEEK: hand over the coordinates of the detection pins the Compose pass just drew,
     *  interleaved lat/lon.
     *
     *  DELIBERATELY NOT PART OF [update]. The pin set changes whenever any new device is heard,
     *  which on a drive test is thousands of times a session, while the rings themselves only
     *  change when the viewport or the dataset does. Feeding the pins into [update] defeated its
     *  identity early-out and put the full 119k-node cull plus up to CAP Marker allocations on the
     *  main thread at detection-arrival cadence. This path never touches the node array and never
     *  allocates a Marker: it indexes the pins once and swaps icons on the <= CAP rings already
     *  drawn.
     *
     *  Identity, not contents: the caller keeps the SAME array instance while the pins it drew are
     *  unchanged, so the ~3 Hz publishes, which the caller's rebuild gate absorbs, and the rebuilds
     *  that redraw every pin in the same place (a tracker crumb lands, the age minute rolls over,
     *  a label toggle) cost nothing at all. */
    fun setPeekPins(map: MapView, pins: DoubleArray) {
        if (pins === peekPins) return
        peekPins = pins
        peekBands = AlprPeekBands(pins)
        applyPeek(map)
    }

    private fun scheduleRebuild(map: MapView) {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ rebuild(map) }, DEBOUNCE_MS)
    }

    /** Repopulate the folder from the viewport. Cheap: a bounds check per node + capped markers. */
    private fun rebuild(map: MapView) {
        // A still-pending debounced rebuild can fire after the MapView left the window (tab switch),
        // by which point osmdroid has nulled the FolderOverlay's item list. Bail rather than NPE.
        if (folder.items == null) return
        folder.items.clear()
        rings.clear()
        val ic = icons
        if (!enabled || ic == null || nodes.isEmpty() || map.zoomLevelDouble < MIN_ZOOM) {
            map.invalidate(); reportPeekCount(0); return
        }
        val box = map.boundingBox
        val nLat = box.latNorth; val sLat = box.latSouth
        val eLon = box.lonEast; val wLon = box.lonWest
        var drawn = 0
        var i = 0
        val n = nodes.size
        while (i + 1 < n) {
            val lat = nodes[i] / 1e7
            val lon = nodes[i + 1] / 1e7
            i += 2
            if (lat in sLat..nLat && lon in wLon..eLon) {
                val node = i / 2 - 1                    // i was already advanced by 2 above
                val maker = if (node < makerIdx.size) makerTable.getOrElse(makerIdx[node]) { "" } else ""
                val tier = rawTier.getOrElse(node) {
                    if (node < confirmed.size && confirmed[node]) 1 else 0
                }
                val attributed = tier == 1
                val primary = attributed || tier == ALPR_TIER_LEGACY_FORMAT
                // Hidden by default: a pin with no manufacturer recorded is the one users drive to,
                // find nothing at, and blame the app for. Skipped BEFORE the drawn++ so hiding them
                // buys headroom under CAP rather than silently costing it.
                if (!primary && !showUnverified) continue
                // too many visible in view: draw none, wait for zoom-in
                if (drawn >= CAP) { folder.items.clear(); rings.clear(); break }
                val marker = Marker(map).apply {
                    position = GeoPoint(lat, lon)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    // Resting size here; applyPeek below is the ONLY place the wide variant is
                    // chosen, so the peek decision lives in one pass whether it runs with this
                    // cull or on its own after a pin arrives.
                    this.icon = if (primary) ic.primary else ic.unverified
                    // Tapping a reference camera names the maker (when OSM has it) + credits the
                    // source. The snippet also has to say what a pin IS: a mapped location, not a
                    // live detection. Most fixed ALPRs backhaul over cellular and are silent to
                    // this hardware whether or not one is standing there, and a user who reads a
                    // pin as a detection concludes the device is broken.
                    // The two BODY lines below are word-identical to iOS. The TITLES are not, and
                    // deliberately: they were written for osmdroid's info-window title, and they
                    // now head MapScreen's Compose callout (MapAlprCallout); they carry the same
                    // fact as the iOS callout's headline in their own words.
                    // TIER FIRST, then maker. Testing maker first titled a hand-typed node
                    // "Flock Safety ALPR camera" while the snippet underneath said no
                    // manufacturer was recorded. Mirrors iOS MapTabView.
                    alprMarkerText(tier, maker).let { (markerTitle, markerSnippet) ->
                        title = markerTitle
                        snippet = markerSnippet
                    }
                    // No osmdroid bubble: the tap hands the words to MapScreen's Compose callout
                    // (onRingTap), which sits above the OSM credit with a close control instead
                    // of under the floating chrome. Consumed, so osmdroid never opens its default
                    // InfoWindow either.
                    setOnMarkerClickListener { m, _ ->
                        selectedLat = lat
                        selectedLon = lon
                        onRingTap?.invoke(m.title.orEmpty(), m.snippet.orEmpty())
                        true
                    }
                }
                folder.add(marker)
                rings.add(RingMarker(lat, lon, tier, maker, primary, marker))
                drawn++
            }
        }
        // RING-PEEK, stamped once over the set just drawn rather than inside the loop: the pin
        // index is shared across every ring, and this is the same pass a later pin change re-runs
        // on its own.
        applyPeek(map)
        map.invalidate()
    }

    /** Restyle the rings this cull already drew for the current pin set: wide where a rendered
     *  detection pin is standing on the camera, resting size everywhere else.
     *
     *  Bounded by what is ON SCREEN, never by the dataset: at most [CAP] rings, each testing three
     *  latitude bands of pins (see [AlprPeekBands]). No node scan, no Marker allocation, and no
     *  repaint at all unless a ring actually changed state. */
    private fun applyPeek(map: MapView) {
        if (rings.isEmpty()) { reportPeekCount(0); return }
        val ic = icons ?: return
        val anyPins = !peekBands.isEmpty
        var peeking = 0
        var changed = false
        for (r in rings) {
            val peek = anyPins && peekBands.matches(r.lat, r.lon)
            if (peek) peeking++
            if (peek == r.peek) continue
            r.peek = peek
            changed = true
            r.marker.icon = when {
                r.primary && peek -> ic.primaryPeek
                r.primary -> ic.primary
                peek -> ic.unverifiedPeek
                else -> ic.unverified
            }
            // The enlarged rim is a sighted-only cue, so the copy carries the same fact for the
            // callout and TalkBack. Re-send the SELECTED ring's words: the callout shows what it
            // was handed at tap time, so without this the one ring the user is actually reading
            // keeps stale copy.
            alprMarkerText(r.tier, r.maker, peek).let { (markerTitle, markerSnippet) ->
                r.marker.title = markerTitle
                r.marker.snippet = markerSnippet
                if (isSelected(r)) onRingTap?.invoke(markerTitle, markerSnippet)
            }
        }
        if (changed) map.invalidate()
        reportPeekCount(peeking)
    }

    private fun reportPeekCount(n: Int) {
        if (n == lastPeekCount) return
        lastPeekCount = n
        onPeekCount?.invoke(n)
    }

    fun detach() {
        handler.removeCallbacksAndMessages(null)
        mapListener?.let { attachedTo?.removeMapListener(it) }   // no pan/zoom rebuilds after teardown
        mapListener = null
        // THE map->log CRASH: osmdroid's MapView.onDetachedFromWindow() (fired when the tab switches
        // away) runs BEFORE Compose's onRelease calls this, and it can already have torn the
        // FolderOverlay's item list down to null - so a bare .clear() here NPE'd. Guard it; the
        // folder is going away regardless.
        folder.items?.clear()
        rings.clear()
        attachedTo = null
        // Drop the cached inputs so a (theoretical) re-attach can't early-out of the first
        // update against the now-empty folder.
        nodes = IntArray(0)
        makerIdx = IntArray(0)
        makerTable = arrayOf("")
        confirmed = BooleanArray(0)
        rawTier = IntArray(0)
        enabled = false
        showUnverified = false
        icons = null
        onRingTap = null
        clearSelection()
        peekPins = DoubleArray(0)
        peekBands = AlprPeekBands(DoubleArray(0))
        // Nothing is drawn any more, so say so before the callback goes: a legend row left
        // explaining a wide ring that no longer exists is exactly the rendering-bug read this
        // count exists to prevent.
        reportPeekCount(0)
        onPeekCount = null
        lastPeekCount = -1
    }
}
