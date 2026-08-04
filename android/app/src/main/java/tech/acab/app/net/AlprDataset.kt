package tech.acab.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * The "known ALPR cameras" map overlay , community-mapped license-plate-reader locations from
 * OpenStreetMap (the registry the DeFlock project maintains), shown as a quiet reference layer.
 *
 * PRIVACY: the phone downloads ONE static file from soyboi.tech and renders it locally. It never
 * queries Overpass, never sends its viewport anywhere, and the fetch only happens after the user
 * opts in. Same "nothing about where you are leaves the device" promise as the rest of the app.
 *
 * Wire format, little-endian. THREE versions are accepted; the magic's last byte selects:
 *   "ALP1"  epochDay:u32 | count:u32 | count*(latE7:i32, lonE7:i32)
 *   "ALP2"  ...plus nMakers:u8 | nMakers*(len:u8, utf8) | count*(makerIdx:u8)
 *   "ALP3"  ...plus count*(tier:u8)          1 = confirmed, 0 = unverified
 * Each version is a strict prefix of the next, so the parser shares the coord and maker paths and
 * only appends a read. Maker table index 0 is always "" (unknown). A pre-ALP3 file defaults every
 * tier to CONFIRMED, never unverified , the tier is an accusation and an old cache carries no
 * evidence for it (see parse()).
 *
 * WHICH ONE WE ACTUALLY RECEIVE depends on the manifest we poll, and this build polls the v3 one.
 * `alpr-latest.json` still serves ALP2 to the installed base and always will; see MANIFEST_URL
 * below for why that split exists and why it cannot be collapsed.
 *
 * We hold coords as an interleaved IntArray [latE7, lonE7, ...] plus parallel makerIdx and
 * confirmed arrays, and the self-describing table. Cached to files/ for instant, offline redraw.
 */
class AlprStore private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("acab.alpr", Context.MODE_PRIVATE)
    private val cacheFile = File(appContext.filesDir, "alpr.bin")

    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, false))
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    /** Show the community-mapped nodes nobody could name a manufacturer for. DEFAULT OFF.
     *
     *  These are the pins that get the APP blamed. A node with no manufacturer recorded is
     *  disproportionately a solar panel on a pole that someone marked in passing, and when a user
     *  drives to one and finds nothing there they conclude the detector is broken, not that an OSM
     *  contributor guessed. 8.1% of nodes across five metros, 22% in Chicago, so not a rounding
     *  error. Still DOWNLOADED and still counted in the manifest: hiding them is a display
     *  decision, deleting them would make the data-quality problem invisible rather than absent.
     *  Mirrors iOS ALPRStore.showUnverified. */
    private val _showUnverified = MutableStateFlow(prefs.getBoolean(KEY_SHOW_UNVERIFIED, false))
    val showUnverified: StateFlow<Boolean> = _showUnverified.asStateFlow()

    /** How many of [confirmed] are tier-0. A flow, not a scan: the settings caption reads it on
     *  every recomposition and the array is six figures long. Assigned with [confirmed]. */
    private val _unverifiedCount = MutableStateFlow(0)
    val unverifiedCount: StateFlow<Int> = _unverifiedCount.asStateFlow()

    /** Interleaved latE7,lonE7 pairs. Empty until enabled + a dataset is present. */
    private val _nodes = MutableStateFlow(IntArray(0))
    val nodes: StateFlow<IntArray> = _nodes.asStateFlow()

    /** Per-node maker index into [makerTable] (0 = unknown), parallel to node count (= nodes.size/2).
     *  Plain @Volatile, not a flow: it only ever changes in the same parse as [_nodes], and the map
     *  overlay / detail screen read it right after observing a new nodes emission. */
    @Volatile var makerIdx: IntArray = IntArray(0); private set
    /** Self-describing maker names; index 0 is always "" (unknown). */
    @Volatile var makerTable: Array<String> = arrayOf(""); private set
    /** Per-node confidence, parallel to the node count: true when the mapper picked the
     *  manufacturer from an editor preset (it carries a wikidata id), false when it was typed
     *  freehand or left blank. The false set is small (7-14%) and is where misidentified pins
     *  concentrate, so the map draws it amber + dashed and says so. Mirrors iOS nodeConfirmed. */
    @Volatile var confirmed: BooleanArray = BooleanArray(0); private set

    /** True while ANY fetch is in flight, including the sub-second manifest freshness check.
     *  Drives the toggle's spinner, and suppresses the "couldn't load" hint so a first load
     *  never flashes a false error before the points arrive. */
    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    /** True only while the dataset BINARY is downloading/parsing. Narrower than [loading] on
     *  purpose: enabling an already-cached layer still runs a manifest check, so keying the
     *  legend's auto-expand off [loading] force-opened it on every enable and every launch. */
    private val _downloading = MutableStateFlow(false)
    val downloading: StateFlow<Boolean> = _downloading.asStateFlow()

    /** Manifest `updated` stamp of the dataset in hand. Seeded from prefs so the settings
     *  caption can show the cached dataset's date offline, before (or without) a fetch. */
    private val _updated = MutableStateFlow(prefs.getString(KEY_VERSION, null))
    val updated: StateFlow<String?> = _updated.asStateFlow()

    /** Epoch millis of the last COMPLETED manifest check (fresh download or confirmed-current),
     *  persisted so "checked 2h ago" survives relaunch. Null = never checked. */
    private val _lastChecked = MutableStateFlow(prefs.getLong(KEY_LAST_CHECKED, 0L).takeIf { it > 0L })
    val lastChecked: StateFlow<Long?> = _lastChecked.asStateFlow()

    /** How the most recent fetch ended, for the settings menu's transient outcome line. */
    private val _lastOutcome = MutableStateFlow<RefreshOutcome?>(null)
    val lastOutcome: StateFlow<RefreshOutcome?> = _lastOutcome.asStateFlow()

    /**
     * NOT_PUBLISHED is a 404 on the manifest, and it is deliberately NOT folded into FAILED. This
     * build polls its own manifest URL (see MANIFEST_URL), so between an app release and the
     * dataset being published there is a legitimate window where the file does not exist yet.
     * Reporting that as "check your connection" sends the user to debug a working network.
     * Mirrors iOS ALPRStore.RefreshOutcome.notPublished.
     */
    enum class RefreshOutcome { UPDATED, UP_TO_DATE, FAILED, NOT_PUBLISHED }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val fetching = AtomicBoolean(false)

    init {
        if (_enabled.value) loadThenRefresh()
    }

    /** Opt in (loads cache + downloads/freshens) or opt out (drops the in-memory points; the
     *  cache is kept so re-enabling is instant). */
    fun setEnabled(on: Boolean) {
        if (on == _enabled.value) return
        _enabled.value = on
        prefs.edit().putBoolean(KEY_ENABLED, on).apply()
        if (on) {
            loadThenRefresh()
        } else {
            _nodes.value = IntArray(0)
            makerIdx = IntArray(0)
            makerTable = arrayOf("")
            confirmed = BooleanArray(0)
            _unverifiedCount.value = 0
        }
    }

    /** Toggle the unverified tier on the map. No refetch: the nodes are already loaded, this only
     *  changes what the overlay and [nearest] are willing to hand back. */
    fun setShowUnverified(on: Boolean) {
        if (on == _showUnverified.value) return
        _showUnverified.value = on
        prefs.edit().putBoolean(KEY_SHOW_UNVERIFIED, on).apply()
    }

    /** Freshen if the layer is on. Non-blocking, failure-tolerant. */
    fun refresh(force: Boolean = false) {
        if (!_enabled.value) return
        if (!fetching.compareAndSet(false, true)) return
        // Flip loading SYNCHRONOUSLY on the caller's thread: the settings menu's "check for
        // updates" row keys its disabled/spinner state (and its wait-for-outcome effect) off
        // this flow, so it must read in-flight before the tap handler returns, not whenever
        // the IO coroutine gets scheduled.
        _loading.value = true
        scope.launch {
            try {
                doFetch()
            } finally {
                fetching.set(false)
            }
        }
    }

    /** Disk load + network freshen, sequenced in ONE IO coroutine. Off the caller's thread:
     *  this is called from composition / a chip tap, and the synchronous ~1 MB readBytes +
     *  238k-int parse was a guaranteed main-thread hitch (and StrictMode DiskReadViolation)
     *  right on the Map tab transition. Sequencing load before fetch under the one [fetching]
     *  gate means doFetch's freshness check can never observe a not-yet-loaded empty array
     *  (and re-download a fresh cache), and a slow disk load can never land after, and
     *  clobber, a just-downloaded newer dataset. */
    private fun loadThenRefresh() {
        if (!fetching.compareAndSet(false, true)) return
        scope.launch {
            try {
                loadFromDisk()
                doFetch()
            } finally {
                fetching.set(false)
            }
        }
    }

    private fun doFetch() {
        _loading.value = true
        var outcome = RefreshOutcome.FAILED
        try {
            val manifestRaw = httpGetText(MANIFEST_URL)
            if (manifestRaw == null) {
                // 404 means the dataset has not been published for this build's manifest yet,
                // which is a rollout state, not a fault. Anything else stays FAILED.
                if (lastStatus == HttpURLConnection.HTTP_NOT_FOUND) outcome = RefreshOutcome.NOT_PUBLISHED
                return
            }
            val m = JSONObject(manifestRaw)
            if (m.optInt("schema", 0) != 1) return
            val data = m.optJSONObject("data") ?: return
            val url = data.optString("url", "")
            val sha = data.optString("sha256", "").lowercase()
            val size = data.optLong("size", 0L)
            val updated = m.optString("updated", "")
            if (!url.startsWith("https://") || sha.isEmpty() || size <= 0) return
            // A valid manifest in hand = the freshness check completed; stamp it now so
            // "checked 2h ago" stays honest even if the download below fails.
            markChecked()
            // Already have this version loaded? Nothing to do.
            if (updated == prefs.getString(KEY_VERSION, null) && _nodes.value.isNotEmpty()) {
                _updated.value = updated
                outcome = RefreshOutcome.UP_TO_DATE
                return
            }
            // Past here we are committed to a real download, so the legend may auto-open to
            // surface the data credit. Everything above was a freshness check.
            _downloading.value = true
            try {
                val bytes = httpGetBytes(url, size) ?: return
                if (bytes.size.toLong() != size) return
                if (sha256Hex(bytes) != sha) return
                val parsed = parse(bytes) ?: return
                cacheFile.writeBytes(bytes)
                prefs.edit().putString(KEY_VERSION, updated).apply()
                makerIdx = parsed.makerIdx           // set BEFORE the nodes emit so a collector
                makerTable = parsed.table            // waking on new nodes sees the matching makers
                confirmed = parsed.confirmed         // same ordering rule: tiers land before nodes
                _unverifiedCount.value = parsed.confirmed.count { !it }
                _nodes.value = parsed.coords
                _updated.value = updated
                outcome = RefreshOutcome.UPDATED
            } finally {
                _downloading.value = false
            }
        } catch (_: Exception) {
            // keep whatever we already have
        } finally {
            // outcome BEFORE loading, so an observer waking on loading=false reads the
            // verdict of THIS fetch, never the previous one's
            _lastOutcome.value = outcome
            _loading.value = false
        }
    }

    private fun markChecked() {
        val now = System.currentTimeMillis()
        prefs.edit().putLong(KEY_LAST_CHECKED, now).apply()
        _lastChecked.value = now
    }

    private fun loadFromDisk() {
        if (!cacheFile.exists()) return
        val parsed = runCatching { parse(cacheFile.readBytes()) }.getOrNull() ?: return
        // Re-check after the read: the load is async now, and a quick toggle-on/off must not
        // leave ~1 MB of nodes resident while the layer is off ("opt out drops the points").
        if (_enabled.value) {
            makerIdx = parsed.makerIdx
            makerTable = parsed.table
            confirmed = parsed.confirmed
            _unverifiedCount.value = parsed.confirmed.count { !it }
            _nodes.value = parsed.coords
        }
    }

    /** Nearest mapped camera to (lat, lon) for the detail screen's "matches a mapped camera" line.
     *  ~2km bounding-box prefilter keeps it cheap over the full set; equirectangular distance is
     *  accurate to well under 1% at these ranges. On-device only. null when the box is empty. */
    fun nearest(lat: Double, lon: Double): Triple<Double, String, Boolean>? {
        val nd = _nodes.value; if (nd.isEmpty()) return null
        val idx = makerIdx; val tbl = makerTable; val conf = confirmed
        // Never corroborate a detection against a node the user cannot see on the map. Vouching for
        // a hit using evidence we have decided is untrustworthy is worse than staying quiet.
        val skipUnverified = !_showUnverified.value
        val box = 0.02; val cosLat = cos(lat * PI / 180)
        var bestM = Double.MAX_VALUE; var bestMaker = ""; var bestConfirmed = true
        var i = 0
        while (i + 1 < nd.size) {
            val la = nd[i] / 1e7; val lo = nd[i + 1] / 1e7
            val node = i / 2; i += 2
            if (abs(la - lat) > box || abs(lo - lon) > box) continue
            if (skipUnverified && node < conf.size && !conf[node]) continue
            val dLat = (la - lat) * 111_320; val dLon = (lo - lon) * 111_320 * cosLat
            val m = sqrt(dLat * dLat + dLon * dLon)
            if (m < bestM) {
                bestM = m
                bestMaker = if (node < idx.size) tbl.getOrElse(idx[node]) { "" } else ""
                bestConfirmed = if (node < conf.size) conf[node] else true
            }
        }
        return if (bestM < Double.MAX_VALUE) Triple(bestM, bestMaker, bestConfirmed) else null
    }

    companion object {
        /** The V3 manifest, deliberately a SEPARATE URL from the one shipped builds poll.
         *  alpr-latest.json still serves ALP2 and always will: an already-installed app
         *  exact-length-checks the binary and REJECTS an ALP3 file outright rather than ignoring
         *  the tail, and its reject path returns before it stamps KEY_VERSION, so it would
         *  re-download and re-fail forever with a map frozen at the last good dataset. Pointing new
         *  builds at their own manifest means the rollout cannot break the installed base whatever
         *  order the stores approve things in. Keep in lockstep with iOS ALPRStore.manifestURL and
         *  the generator's dual-publish block (soyboi.tech/tools/build_alpr_dataset.py). */
        private const val MANIFEST_URL = "https://soyboi.tech/data/alpr-v3-latest.json"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_SHOW_UNVERIFIED = "show_unverified"
        private const val KEY_VERSION = "version"
        private const val KEY_LAST_CHECKED = "last_checked"

        @Volatile private var INSTANCE: AlprStore? = null
        fun getInstance(context: Context): AlprStore =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AlprStore(context.applicationContext).also { INSTANCE = it }
            }

        /** Parsed dataset: interleaved latE7,lonE7 coords + a parallel maker index + the table. */
        private class Parsed(val coords: IntArray, val makerIdx: IntArray, val table: Array<String>,
                            val confirmed: BooleanArray)

        /** Parse the "ALP3" binary (coords + per-node maker + per-node confidence tier). Also
         *  accepts a legacy "ALP2" (coords + makers) and "ALP1" (coords only), so a cache from an
         *  older build still loads. Bounds-checked throughout; returns null on any malformation
         *  (bad length, a table that runs past the buffer, etc.). A maker index past the table
         *  resolves to "" at read time.
         *
         *  A pre-ALP3 file defaults every node to CONFIRMED, never unverified. The tier is an
         *  accusation ("nobody picked this manufacturer from a preset, so it may be misidentified")
         *  and a cache predating the field carries no evidence either way; defaulting the other way
         *  would paint a whole stale map amber purely because the file is old.
         *  Mirrors iOS ALPRStore.parse constant for constant. */
        private fun parse(bytes: ByteArray): Parsed? {
            if (bytes.size < 12) return null
            val a = 'A'.code.toByte(); val l = 'L'.code.toByte(); val pC = 'P'.code.toByte()
            if (bytes[0] != a || bytes[1] != l || bytes[2] != pC) return null
            val v3 = bytes[3] == '3'.code.toByte()
            val v2 = bytes[3] == '2'.code.toByte()
            val v1 = bytes[3] == '1'.code.toByte()
            val hasMakers = v2 || v3
            if (!v1 && !hasMakers) return null
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            buf.position(4)
            buf.int                                  // epochDay (unused here)
            val count = buf.int
            if (count < 0 || count > 5_000_000) return null

            var table = arrayOf("")
            if (hasMakers) {
                if (buf.remaining() < 1) return null
                val nMakers = buf.get().toInt() and 0xFF
                val list = ArrayList<String>(nMakers)
                repeat(nMakers) {
                    if (buf.remaining() < 1) return null
                    val len = buf.get().toInt() and 0xFF
                    if (buf.remaining() < len) return null
                    val sb = ByteArray(len); buf.get(sb); list.add(String(sb, Charsets.UTF_8))
                }
                if (list.isEmpty()) return null       // index 0 must exist
                table = list.toTypedArray()
            }
            val coordStart = buf.position()
            val idxBytes = if (hasMakers) count.toLong() else 0L
            val tierBytes = if (v3) count.toLong() else 0L
            if (bytes.size.toLong() != coordStart.toLong() + count.toLong() * 8 + idxBytes + tierBytes) return null
            val coords = IntArray(count * 2)
            for (i in 0 until count) { coords[i * 2] = buf.int; coords[i * 2 + 1] = buf.int }
            val makerIdx = IntArray(count)
            if (hasMakers) for (i in 0 until count) makerIdx[i] = buf.get().toInt() and 0xFF
            val confirmed = BooleanArray(count) { true }          // pre-v3: no evidence, so no accusation
            if (v3) for (i in 0 until count) confirmed[i] = (buf.get().toInt() and 0xFF) == 1
            return Parsed(coords, makerIdx, table, confirmed)
        }

        private fun sha256Hex(bytes: ByteArray): String {
            val d = MessageDigest.getInstance("SHA-256").digest(bytes)
            val sb = StringBuilder(d.size * 2)
            for (b in d) sb.append("%02x".format(b.toInt() and 0xFF))
            return sb.toString()
        }

        private fun httpGetText(url: String): String? = httpGet(url) { it.readBytes().decodeToString() }

        /** Last HTTP status seen by httpGet, so the manifest fetch can tell a 404 ("not published
         *  yet") from a dead network. Only read immediately after a failed httpGetText on the
         *  manifest; it is best-effort, not a general-purpose channel. */
        @Volatile private var lastStatus: Int = 0

        /** Stream-read with a bounded loop (AND-SEC-2), aborting once the total exceeds the
         *  manifest-declared size (hard-capped at 8 MB), so a misconfigured/compromised server
         *  can't OOM the app before the size + SHA gate runs. Mirrors the OTA download path. */
        private fun httpGetBytes(url: String, declaredSize: Long): ByteArray? = httpGet(url) { input ->
            val cap = declaredSize.coerceIn(1L, MAX_DATASET_BYTES)
            val out = java.io.ByteArrayOutputStream(cap.toInt())
            val tmp = ByteArray(16 * 1024)
            var total = 0L
            while (true) {
                val r = input.read(tmp)
                if (r < 0) break
                total += r
                if (total > cap) throw java.io.IOException("alpr dataset exceeds declared size")
                out.write(tmp, 0, r)
            }
            out.toByteArray()
        }

        private const val MAX_DATASET_BYTES = 8L * 1024 * 1024

        private fun <T> httpGet(url: String, read: (java.io.InputStream) -> T): T? {
            var conn: HttpURLConnection? = null
            return try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 8_000
                    readTimeout = 30_000
                }
                lastStatus = conn.responseCode
                if (conn.responseCode != HttpURLConnection.HTTP_OK) return null
                conn.inputStream.use(read)
            } catch (_: Exception) {
                lastStatus = 0          // transport failure, not an HTTP status
                null
            } finally {
                conn?.disconnect()
            }
        }
    }
}
