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
 * Wire format (alpr.bin, little-endian): "ALP2" | epochDay:u32 | count:u32 | nMakers:u8 |
 * nMakers*(len:u8, utf8) | count*(latE7:i32, lonE7:i32) | count*(makerIdx:u8). Maker table index 0 is
 * always "" (unknown); the coord block matches ALP1, so an old cached ALP1 file still loads (all
 * makers unknown). We hold coords as an interleaved IntArray [latE7, lonE7, ...] plus a parallel
 * makerIdx IntArray and the self-describing table. Cached to files/ for instant, offline redraw.
 */
class AlprStore private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("acab.alpr", Context.MODE_PRIVATE)
    private val cacheFile = File(appContext.filesDir, "alpr.bin")

    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, false))
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    /** Interleaved latE7,lonE7 pairs. Empty until enabled + a dataset is present. */
    private val _nodes = MutableStateFlow(IntArray(0))
    val nodes: StateFlow<IntArray> = _nodes.asStateFlow()

    /** Per-node maker index into [makerTable] (0 = unknown), parallel to node count (= nodes.size/2).
     *  Plain @Volatile, not a flow: it only ever changes in the same parse as [_nodes], and the map
     *  overlay / detail screen read it right after observing a new nodes emission. */
    @Volatile var makerIdx: IntArray = IntArray(0); private set
    /** Self-describing maker names; index 0 is always "" (unknown). */
    @Volatile var makerTable: Array<String> = arrayOf(""); private set

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

    enum class RefreshOutcome { UPDATED, UP_TO_DATE, FAILED }

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
        }
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
            val manifestRaw = httpGetText(MANIFEST_URL) ?: return
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
            _nodes.value = parsed.coords
        }
    }

    /** Nearest mapped camera to (lat, lon) for the detail screen's "matches a mapped camera" line.
     *  ~2km bounding-box prefilter keeps it cheap over the full set; equirectangular distance is
     *  accurate to well under 1% at these ranges. On-device only. null when the box is empty. */
    fun nearest(lat: Double, lon: Double): Pair<Double, String>? {
        val nd = _nodes.value; if (nd.isEmpty()) return null
        val idx = makerIdx; val tbl = makerTable
        val box = 0.02; val cosLat = cos(lat * PI / 180)
        var bestM = Double.MAX_VALUE; var bestMaker = ""
        var i = 0
        while (i + 1 < nd.size) {
            val la = nd[i] / 1e7; val lo = nd[i + 1] / 1e7
            val node = i / 2; i += 2
            if (abs(la - lat) > box || abs(lo - lon) > box) continue
            val dLat = (la - lat) * 111_320; val dLon = (lo - lon) * 111_320 * cosLat
            val m = sqrt(dLat * dLat + dLon * dLon)
            if (m < bestM) { bestM = m; bestMaker = if (node < idx.size) tbl.getOrElse(idx[node]) { "" } else "" }
        }
        return if (bestM < Double.MAX_VALUE) bestM to bestMaker else null
    }

    companion object {
        private const val MANIFEST_URL = "https://soyboi.tech/data/alpr-latest.json"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_VERSION = "version"
        private const val KEY_LAST_CHECKED = "last_checked"

        @Volatile private var INSTANCE: AlprStore? = null
        fun getInstance(context: Context): AlprStore =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AlprStore(context.applicationContext).also { INSTANCE = it }
            }

        /** Parsed dataset: interleaved latE7,lonE7 coords + a parallel maker index + the table. */
        private class Parsed(val coords: IntArray, val makerIdx: IntArray, val table: Array<String>)

        /** Parse the "ALP2" binary (coords + per-node maker). Also accepts a legacy "ALP1" file
         *  (coords only, all makers unknown), so a cache from an older build still loads.
         *  Bounds-checked throughout; returns null on any malformation (bad length, a table that
         *  runs past the buffer, etc.). A maker index past the table resolves to "" at read time. */
        private fun parse(bytes: ByteArray): Parsed? {
            if (bytes.size < 12) return null
            val a = 'A'.code.toByte(); val l = 'L'.code.toByte(); val pC = 'P'.code.toByte()
            if (bytes[0] != a || bytes[1] != l || bytes[2] != pC) return null
            val v2 = bytes[3] == '2'.code.toByte()
            val v1 = bytes[3] == '1'.code.toByte()
            if (!v2 && !v1) return null
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            buf.position(4)
            buf.int                                  // epochDay (unused here)
            val count = buf.int
            if (count < 0 || count > 5_000_000) return null

            var table = arrayOf("")
            if (v2) {
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
            val idxBytes = if (v2) count else 0
            if (bytes.size.toLong() != coordStart.toLong() + count.toLong() * 8 + idxBytes) return null
            val coords = IntArray(count * 2)
            for (i in 0 until count) { coords[i * 2] = buf.int; coords[i * 2 + 1] = buf.int }
            val makerIdx = IntArray(count)
            if (v2) for (i in 0 until count) makerIdx[i] = buf.get().toInt() and 0xFF
            return Parsed(coords, makerIdx, table)
        }

        private fun sha256Hex(bytes: ByteArray): String {
            val d = MessageDigest.getInstance("SHA-256").digest(bytes)
            val sb = StringBuilder(d.size * 2)
            for (b in d) sb.append("%02x".format(b.toInt() and 0xFF))
            return sb.toString()
        }

        private fun httpGetText(url: String): String? = httpGet(url) { it.readBytes().decodeToString() }

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
                if (conn.responseCode != HttpURLConnection.HTTP_OK) return null
                conn.inputStream.use(read)
            } catch (_: Exception) {
                null
            } finally {
                conn?.disconnect()
            }
        }
    }
}
