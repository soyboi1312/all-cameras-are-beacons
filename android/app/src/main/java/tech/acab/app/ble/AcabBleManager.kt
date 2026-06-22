package tech.acab.app.ble

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.ParcelUuid
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.model.displayName
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import java.io.File
import java.security.KeyStore
import java.time.Instant
import java.util.ArrayDeque
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

enum class ConnState { DISCONNECTED, SCANNING, CONNECTING, BONDING, READY }

/** How sightings are announced.
 *  BUZZER  = board buzzes, phone stays quiet (the normal case).
 *  VIBRATE = board muted, phone buzzes on each first sighting.
 *  SILENT  = board muted, no phone feedback either. */
enum class AlertMode { BUZZER, VIBRATE, SILENT }

/** A board found while scanning. */
data class FoundBoard(val device: BluetoothDevice, val name: String, val rssi: Int)

/** A device the user has chosen to silence (a whitelist entry). */
data class IgnoredDevice(val mac: String, val label: String)

/**
 * Drives the link to an OUI-Spy board: scan by service UUID, connect, bond (the GATT
 * service is encrypted), subscribe to the detection + status notifies, parse, and
 * write config. Android's BLE stack only does one op at a time, so the connect steps
 * are chained through the callbacks. Permissions are the caller's job — the UI asks
 * for SCAN/CONNECT before any of this runs.
 */
@SuppressLint("MissingPermission")
class AcabBleManager(private val context: Context) {

    private val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
            as BluetoothManager).adapter
    private val scanner get() = adapter?.bluetoothLeScanner

    private val _state = MutableStateFlow(ConnState.DISCONNECTED)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _found = MutableStateFlow<List<FoundBoard>>(emptyList())
    val found: StateFlow<List<FoundBoard>> = _found.asStateFlow()

    private val _detections = MutableStateFlow<List<Detection>>(emptyList())
    val detections: StateFlow<List<Detection>> = _detections.asStateFlow()

    private val _status = MutableStateFlow<DeviceStatus?>(null)
    val status: StateFlow<DeviceStatus?> = _status.asStateFlow()

    private val _deviceName = MutableStateFlow<String?>(null)
    val deviceName: StateFlow<String?> = _deviceName.asStateFlow()

    private val _demoMode = MutableStateFlow(false)
    val demoMode: StateFlow<Boolean> = _demoMode.asStateFlow()

    private val _ignored = MutableStateFlow<List<IgnoredDevice>>(emptyList())
    val ignored: StateFlow<List<IgnoredDevice>> = _ignored.asStateFlow()

    private val _alertMode = MutableStateFlow(AlertMode.BUZZER)
    val alertMode: StateFlow<AlertMode> = _alertMode.asStateFlow()

    private val _driveMode = MutableStateFlow(false)
    val driveMode: StateFlow<Boolean> = _driveMode.asStateFlow()
    val driveModeOn: Boolean get() = _driveMode.value

    // Hide detection counts on the lock-screen notification (user setting, default on). The
    // shade (unlocked) and the app still show the full breakdown. Loaded from prefs in init.
    private val _redactLockScreen = MutableStateFlow(true)
    val redactLockScreen: StateFlow<Boolean> = _redactLockScreen.asStateFlow()

    private val prefs = context.getSharedPreferences("acab", Context.MODE_PRIVATE)

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION") context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private val notificationManager: NotificationManager? by lazy {
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
    }

    /** True when a Focus or Do Not Disturb is on, so vibrate alerts stay quiet.
     *  Reading the filter needs no permission; if we can't read it, just alert. */
    private fun focusSuppressed(): Boolean = when (notificationManager?.currentInterruptionFilter) {
        NotificationManager.INTERRUPTION_FILTER_PRIORITY,
        NotificationManager.INTERRUPTION_FILTER_NONE,
        NotificationManager.INTERRUPTION_FILTER_ALARMS -> true
        else -> false   // ALL, UNKNOWN, or null: alert as usual
    }

    init {
        loadIgnored()
        _alertMode.value = runCatching {
            AlertMode.valueOf(prefs.getString("alertMode", null) ?: "BUZZER")
        }.getOrDefault(AlertMode.BUZZER)
        _redactLockScreen.value = prefs.getBoolean("redactLock", true)
    }

    private var gatt: BluetoothGatt? = null
    private var target: BluetoothDevice? = null
    private val store = LinkedHashMap<String, Detection>()
    private val firstSeenAt = HashMap<String, Long>()
    private val lastSeenAt = HashMap<String, Long>()
    private val rssiHistory = HashMap<String, MutableList<Int>>()
    private val capturedLoc = HashMap<String, Pair<Double, Double>>()
    private val trackHistory = HashMap<String, MutableList<Pair<Double, Double>>>()   // drone flight paths
    private var lastLat: Double? = null
    private var lastLon: Double? = null

    // ---- offline buffer replay state ----
    // lastSeq is the highest contiguous seq we've filed; it survives a disconnect (so a
    // reconnect only re-pulls what we missed) and is persisted across app restarts.
    private var lastSeq: Long = prefs.getLong("lastSeq", 0L)
    private var histReceived = 0            // records filed during the current drain
    private var histHighestContiguous = 0L  // highest contiguous seq seen this drain

    // ---- serialized GATT op queue ----
    // Android allows one outstanding GATT op per connection, so every writeCharacteristic
    // / writeDescriptor goes through this single-in-flight queue. The callbacks
    // (onCharacteristicWrite / onDescriptorWrite) dequeue the next op. Inbound notifies
    // (onCharacteristicChanged) do NOT consume the slot.
    private val gattQueue = ArrayDeque<(BluetoothGatt) -> Unit>()
    private var gattBusy = false

    init {
        // Runs after the store/maps above are constructed, so the reload can populate them.
        loadPersistedDetections()   // replayed history survives an app restart
    }

    @Synchronized
    private fun enqueueGatt(op: (BluetoothGatt) -> Unit) {
        gattQueue.add(op)
        if (!gattBusy) dispatchGatt()
    }

    @Synchronized
    private fun dispatchGatt() {
        val g = gatt
        if (g == null) { gattQueue.clear(); gattBusy = false; return }
        val op = gattQueue.poll()
        if (op == null) { gattBusy = false; return }
        gattBusy = true
        runCatching { op(g) }.onFailure { gattBusy = false; dispatchGatt() }
    }

    /** A write finished (or failed) — free the slot and run the next queued op. */
    @Synchronized
    private fun onGattOpComplete() {
        gattBusy = false
        dispatchGatt()
    }

    // ---- scanning ----

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val dev = result.device
            val name = result.scanRecord?.deviceName ?: dev.name ?: "ACAB"
            val board = FoundBoard(dev, name, result.rssi)
            _found.value = (_found.value.filterNot { it.device.address == dev.address } + board)
                .sortedByDescending { it.rssi }
        }
    }

    fun startScan() {
        val s = scanner ?: return
        _found.value = emptyList()
        _state.value = ConnState.SCANNING
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(AcabProfile.SERVICE))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        s.startScan(listOf(filter), settings, scanCb)
    }

    fun stopScan() {
        scanner?.stopScan(scanCb)
        if (_state.value == ConnState.SCANNING) _state.value = ConnState.DISCONNECTED
    }

    // ---- connection ----

    fun connect(board: FoundBoard) {
        stopScan()
        _state.value = ConnState.CONNECTING
        target = board.device
        _deviceName.value = board.name
        ContextCompat.registerReceiver(
            context, bondReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        gatt = board.device.connectGatt(context, false, gattCb, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect() {
        gatt?.disconnect()
    }

    // ---- drive mode (foreground-service glanceable counter notification) ----

    /** Start the Drive-mode foreground service: an ongoing detection-counter notification
     *  (lock screen + shade; an Android 16 Live Update chip where supported), and the link
     *  stays alive in the background while it runs. The iOS Live Activity analog. */
    fun startDriveMode() {
        if (_driveMode.value) return
        _driveMode.value = true
        AcabLinkService.start(context)
    }

    fun endDriveMode() {
        if (!_driveMode.value) return
        _driveMode.value = false
        AcabLinkService.stop(context)
    }

    /** Hide/show detection counts on the lock-screen notification (the service re-renders). */
    fun setRedactLockScreen(on: Boolean) {
        _redactLockScreen.value = on
        prefs.edit().putBoolean("redactLock", on).apply()
    }

    private fun cleanup() {
        runCatching { context.unregisterReceiver(bondReceiver) }
        gatt?.close()
        gatt = null
        target = null
        // Drop any in-flight GATT ops; the slot is meaningless without a connection.
        // NOTE: lastSeq is deliberately NOT touched here — it must survive a disconnect so
        // the next session only re-pulls the records we actually missed.
        synchronized(this) { gattQueue.clear(); gattBusy = false }
        histReceived = 0
        histHighestContiguous = 0L
        store.clear()
        firstSeenAt.clear()
        lastSeenAt.clear()
        rssiHistory.clear()
        capturedLoc.clear()
        trackHistory.clear()
        _detections.value = emptyList()
        _status.value = null
        _deviceName.value = null
        _state.value = ConnState.DISCONNECTED
        // Don't hold the connectedDevice foreground service open with no live link (battery
        // drain + Android 14's FGS-without-device policy): if the board drops, end Drive mode
        // so the counter stops cleanly instead of a perpetual, non-reconnecting "Reconnecting…".
        if (_driveMode.value) endDriveMode()
    }

    // Bond before discovering services — the board insists on an encrypted link.
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val dev = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE)
            if (dev?.address != target?.address) return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                BluetoothDevice.BOND_BONDED -> gatt?.discoverServices()
                BluetoothDevice.BOND_NONE -> disconnect()   // declined or failed
            }
        }
    }

    private val gattCb = object : android.bluetooth.BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                // Already bonded? Go straight to discovery. Otherwise bond first.
                if (g.device.bondState == BluetoothDevice.BOND_BONDED) {
                    g.discoverServices()
                } else {
                    _state.value = ConnState.BONDING
                    g.device.createBond()
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                cleanup()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) g.requestMtu(247) else g.disconnect()
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            subscribe(g, AcabProfile.DETECTIONS)   // chain picks up in onDescriptorWrite
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            onGattOpComplete()   // CCCD write done — free the slot before queuing the next ops
            when (d.characteristic.uuid) {
                AcabProfile.DETECTIONS -> {
                    // The Detections subscription is live, so the board can now NOTIFY the
                    // replay. Hand it our key + clock, then ask for everything past lastSeq.
                    sendHandshake()
                    subscribe(g, AcabProfile.STATUS)
                }
                AcabProfile.STATUS -> {
                    charOf(g, AcabProfile.STATUS)?.let { g.readCharacteristic(it) }
                    _state.value = ConnState.READY
                    sendIgnoreList()   // re-push the whitelist for this session
                    setBuzzer(_alertMode.value == AlertMode.BUZZER)   // a fresh board boots with the buzzer on; sync it to the phone's mode
                }
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            onGattOpComplete()   // a config write finished — run the next queued op
        }

        // API 33+ passes the value in; older versions read it off characteristic.value.
        override fun onCharacteristicChanged(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray,
        ) = ingest(c.uuid, value)

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") ingest(c.uuid, c.value ?: ByteArray(0))
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int,
        ) { if (status == BluetoothGatt.GATT_SUCCESS) ingest(c.uuid, value) }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                @Suppress("DEPRECATION") ingest(c.uuid, c.value ?: ByteArray(0))
            }
        }
    }

    private fun subscribe(g: BluetoothGatt, charUuid: java.util.UUID) {
        enqueueGatt { gg ->
            val c = charOf(gg, charUuid)
            if (c == null) { onGattOpComplete(); return@enqueueGatt }
            gg.setCharacteristicNotification(c, true)
            val cccd = c.getDescriptor(AcabProfile.CCCD)
            if (cccd == null) { onGattOpComplete(); return@enqueueGatt }
            val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gg.writeDescriptor(cccd, enable)
            } else {
                @Suppress("DEPRECATION") cccd.value = enable
                @Suppress("DEPRECATION") gg.writeDescriptor(cccd)
            }
        }
    }

    private fun charOf(g: BluetoothGatt, uuid: java.util.UUID): BluetoothGattCharacteristic? =
        g.getService(AcabProfile.SERVICE)?.getCharacteristic(uuid)

    private fun ingest(uuid: java.util.UUID, bytes: ByteArray) {
        val json = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull() ?: return
        when (uuid) {
            AcabProfile.DETECTIONS -> {
                // The replay sentinel carries hist:"end" (a string, not the bool that live
                // and per-record hist frames use), so catch it before parsing a Detection.
                if (json.optString("hist") == "end") { onHistEnd(json.optInt("n", 0)); return }
                val d = Detection.fromJson(json)
                if (isIgnored(d.mac)) return    // whitelisted (the board mutes it too)
                if (d.hist) fileHistory(d) else fileLive(d)
            }
            AcabProfile.STATUS -> _status.value = DeviceStatus.fromJson(json)
        }
    }

    /** A live detection: timestamp is now, and a fresh sighting may buzz the phone. */
    private fun fileLive(d: Detection) {
        val now = System.currentTimeMillis()
        val firstTime = !firstSeenAt.containsKey(d.id)
        if (firstTime) {
            firstSeenAt[d.id] = now
            val la = lastLat; val lo = lastLon
            if (d.lat == null && la != null && lo != null) capturedLoc[d.id] = la to lo
        }
        lastSeenAt[d.id] = now
        file(d, now)
        if (_alertMode.value == AlertMode.VIBRATE && firstTime && !focusSuppressed()) alertHaptic(d.type)   // buzz on the first sighting, unless DND/Focus is on
    }

    /** A replayed history record. Use the board's recorded timestamp when it has one;
     *  otherwise fall back to a monotonically-DECREASING pseudo-time derived from seq, so
     *  the newest-first display never pulls old history up to "now". Never buzzes. */
    private fun fileHistory(d: Detection) {
        val ts = when {
            d.at > 0L -> d.at * 1000L                       // absolute: exact moment it was seen
            else -> HIST_PSEUDO_BASE - d.seq * 1000L        // approx: order-only, strictly before now
        }
        if (!firstSeenAt.containsKey(d.id) || ts < (firstSeenAt[d.id] ?: Long.MAX_VALUE)) {
            firstSeenAt[d.id] = ts
        }
        if (!lastSeenAt.containsKey(d.id)) lastSeenAt[d.id] = ts
        file(d, ts)
        // Advance the in-memory contiguous cursor, but DON'T persist lastSeq or rewrite the
        // whole detections file per record - onHistEnd checkpoints both once the drain ends.
        // If a drain is interrupted, we just re-drain from the last checkpoint; filing is
        // idempotent by id, so nothing is lost or duplicated (vs. a full write per record).
        if (d.seq == lastSeq + 1) lastSeq = d.seq
        if (d.seq > histHighestContiguous) histHighestContiguous = d.seq
        histReceived++
    }

    /** Shared filing path: dedup-by-id into the store, keep the RSSI trend and (for drones)
     *  the flight path, and republish. Does not vibrate. */
    private fun file(d: Detection, ts: Long) {
        val hist = rssiHistory.getOrPut(d.id) { mutableListOf() }
        hist.add(d.rssi)
        if (hist.size > 48) hist.subList(0, hist.size - 48).clear()
        store.remove(d.id)            // re-add so it sorts as the most recent
        store[d.id] = d
        // Bound memory over a long drive: keep only the most-recent STORE_CAP distinct devices.
        while (store.size > STORE_CAP) {
            val oldest = store.keys.firstOrNull() ?: break
            store.remove(oldest)
            firstSeenAt.remove(oldest); lastSeenAt.remove(oldest)
            rssiHistory.remove(oldest); capturedLoc.remove(oldest); trackHistory.remove(oldest)
        }
        val dla = d.lat; val dlo = d.lon
        if (d.type == DeviceType.DRONE && dla != null && dlo != null) {   // track the flight path
            val path = trackHistory.getOrPut(d.id) { mutableListOf() }
            if (path.lastOrNull() != (dla to dlo)) {
                path.add(dla to dlo)
                if (path.size > 60) path.subList(0, path.size - 60).clear()
            }
        }
        _detections.value = store.values.toList().asReversed()
    }

    /** The board finished replaying. Verify we filed exactly N records; on a mismatch
     *  (a dropped or duplicated notify) re-issue {sync} from the last good seq. On a clean
     *  drain, advance lastSeq to the highest seq the board reported and persist. */
    private fun onHistEnd(n: Int) {
        if (histReceived != n) {
            // Something slipped — ask the board to replay again from where we're solid.
            writeConfig(JSONObject().put("sync", lastSeq))
        } else {
            if (histHighestContiguous > lastSeq) {
                lastSeq = histHighestContiguous
                prefs.edit().putLong("lastSeq", lastSeq).apply()
            }
        }
        histReceived = 0
        histHighestContiguous = 0L
        persistDetections()
    }

    // ---- config writes ----

    fun writeConfig(obj: JSONObject) {
        if (gatt == null) return
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        enqueueGatt { g ->
            val c = charOf(g, AcabProfile.CONFIG)
            if (c == null) { onGattOpComplete(); return@enqueueGatt }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(c, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION") c.value = bytes
                @Suppress("DEPRECATION") c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION") g.writeCharacteristic(c)
            }
        }
    }

    fun setBodyCam(on: Boolean) = writeConfig(JSONObject().put("bodycam", on))
    fun setTracker(on: Boolean) = writeConfig(JSONObject().put("tracker", on))
    fun setBuzzer(on: Boolean) = writeConfig(JSONObject().put("buzzer", on))
    fun setVolume(v: Int, preview: Boolean = false) {
        val cfg = JSONObject().put("volume", v.coerceIn(0, 100))
        if (preview) cfg.put("beep", true)   // chirp once at the new level on release
        writeConfig(cfg)
    }
    fun setBleScan(on: Boolean) = writeConfig(JSONObject().put("ble", on))
    fun setWifiScan(on: Boolean) = writeConfig(JSONObject().put("wifi", on))

    /** Turn the board's offline detection buffer on or off (firmware default off). */
    fun setBuffer(on: Boolean) = writeConfig(JSONObject().put("buffer", on))

    /** Desert mode: the board reports EVERY device in range (not just signatures).
     *  Enabling it drops alerts to SILENT; with everything reporting in, the buzzer and
     *  haptics would otherwise never stop. The user can switch sound back on afterward. */
    fun setDesert(on: Boolean) {
        writeConfig(JSONObject().put("desert", on))
        if (on && _alertMode.value != AlertMode.SILENT) setAlertMode(AlertMode.SILENT)
    }

    // ---- offline-buffer handshake (key + clock + sync request) ----

    /** Right after the Detections subscription confirms: hand the board our long-lived
     *  key (so it can decrypt the buffer it kept while we were away), our current wall
     *  clock, then ask it to replay everything past the last seq we filed. Order matters,
     *  and the queue guarantees these land one at a time. */
    private fun sendHandshake() {
        writeConfig(JSONObject().put("key", keyHex()))
        writeConfig(JSONObject().put("epoch", System.currentTimeMillis() / 1000L))
        writeConfig(JSONObject().put("sync", lastSeq))
    }

    /** Pick how sightings get announced. VIBRATE and SILENT both mute the board's
     *  buzzer, for when a chirp would give you away; VIBRATE buzzes this phone instead. */
    fun setAlertMode(mode: AlertMode) {
        _alertMode.value = mode
        prefs.edit().putString("alertMode", mode.name).apply()
        setBuzzer(mode == AlertMode.BUZZER)
    }

    /** Buzz the phone on a fresh sighting — a double pulse for the priority threats. */
    private fun alertHaptic(type: DeviceType) {
        val vib = vibrator ?: return
        val effect = when (type) {
            DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN, DeviceType.DRONE ->
                VibrationEffect.createWaveform(longArrayOf(0, 70, 90, 70), -1)
            else -> VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE)
        }
        vib.vibrate(effect)
    }

    // ---- per-detection timing, RSSI trend, and map location ----

    fun firstSeen(id: String): Long? = firstSeenAt[id]
    fun lastSeen(id: String): Long? = lastSeenAt[id]
    fun rssiTrend(id: String): List<Int> = rssiHistory[id]?.toList() ?: emptyList()

    /** True when we haven't heard from this id lately (probably gone). */
    fun isStale(id: String, olderThanMs: Long = 45_000): Boolean {
        val ls = lastSeenAt[id] ?: return true
        return System.currentTimeMillis() - ls > olderThanMs
    }

    /** Where to drop the map pin: the detection's own coords (drones), or the phone's
     *  position from when we first heard it. */
    fun mapCoord(d: Detection): Pair<Double, Double>? {
        val la = d.lat; val lo = d.lon
        return if (la != null && lo != null) la to lo else capturedLoc[d.id]
    }

    /** A drone's accumulated flight path (empty for anything else). */
    fun track(id: String): List<Pair<Double, Double>> = trackHistory[id] ?: emptyList()

    /** The phone's last known coordinate (centers a no-GPS RSSI ring). */
    fun selfCoord(): Pair<Double, Double>? = lastLat?.let { la -> lastLon?.let { lo -> la to lo } }

    private var lastGpsSent = 0L
    /** Feed in the phone's location: geotag non-drone detections locally, and push it
     *  to a connected board so a Mesh-Detect uplink can carry where we are (throttled). */
    fun setLocation(lat: Double, lon: Double) {
        lastLat = lat; lastLon = lon
        val now = System.currentTimeMillis()
        if (_state.value == ConnState.READY && now - lastGpsSent > 15_000) {
            lastGpsSent = now
            writeConfig(JSONObject().put("lat", lat).put("lon", lon))
        }
    }

    // ---- log clear + CSV export ----

    /** Wipe the detection log, but stay connected. Also erases the board's offline buffer
     *  and the locally persisted copy, and resets the replay cursor so the two stay in step. */
    fun clearLog() {
        store.clear(); firstSeenAt.clear(); lastSeenAt.clear()
        rssiHistory.clear(); capturedLoc.clear(); trackHistory.clear()
        _detections.value = emptyList()
        writeConfig(JSONObject().put("clearlog", true))   // no-op if not connected
        lastSeq = 0L
        histReceived = 0
        histHighestContiguous = 0L
        prefs.edit().putLong("lastSeq", 0L).apply()
        detectionStore().delete()
    }

    /** CSV of the current log: when, what, and where for each detection. Location is
     *  the phone's rough position from when we first heard it (the board has no GPS),
     *  or blank if we didn't have one. */
    fun detectionsCsv(): String {
        val rows = StringBuilder(
            "detected_at,type,mac,rssi,source,matched_on,confidence,sightings,approx_lat,approx_lon")
        for (d in _detections.value) {
            val whenAt = firstSeenAt[d.id]?.let { Instant.ofEpochMilli(it).toString() } ?: ""
            val coord = mapCoord(d)
            val lat = coord?.let { "%.6f".format(it.first) } ?: ""
            val lon = coord?.let { "%.6f".format(it.second) } ?: ""
            rows.append('\n').append(
                listOf(whenAt, csvSafe(d.type.label), d.mac, d.rssi.toString(),
                    d.sourceLabel, d.methodLabel, d.confidence.toString(),
                    d.count.toString(), lat, lon).joinToString(","))
        }
        return rows.toString()
    }

    private fun csvSafe(s: String): String =
        if (s.contains(',') || s.contains('"') || s.contains('\n'))
            "\"" + s.replace("\"", "\"\"") + "\"" else s

    // ---- whitelist (ignored devices) ----

    fun isIgnored(mac: String): Boolean = _ignored.value.any { it.mac == mac.lowercase() }

    /** Silence a device: it stops alerting on the board and drops out of the app. */
    fun ignoreDevice(d: Detection) {
        val mac = d.mac.lowercase()
        if (isIgnored(mac)) return
        _ignored.value = _ignored.value + IgnoredDevice(mac, d.displayName)
        persistIgnored(); sendIgnoreList()
        store.keys.filter { store[it]?.mac?.lowercase() == mac }.toList().forEach { store.remove(it) }
        _detections.value = store.values.toList().asReversed()
    }

    /** Un-silence a device. */
    fun unignore(mac: String) {
        _ignored.value = _ignored.value.filterNot { it.mac == mac.lowercase() }
        persistIgnored(); sendIgnoreList()
    }

    private fun loadIgnored() {
        val raw = prefs.getString("ignored", null) ?: return
        runCatching {
            val arr = JSONArray(raw)
            _ignored.value = (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                IgnoredDevice(o.optString("mac"), o.optString("label"))
            }
        }
    }

    private fun persistIgnored() {
        val arr = JSONArray()
        _ignored.value.forEach { arr.put(JSONObject().put("mac", it.mac).put("label", it.label)) }
        prefs.edit().putString("ignored", arr.toString()).apply()
    }

    /** Push the ignore list to the board so it drops those MACs at the source. */
    private fun sendIgnoreList() {
        if (gatt == null) return
        val arr = JSONArray(); _ignored.value.forEach { arr.put(it.mac) }
        writeConfig(JSONObject().put("ignore", arr))
    }

    // ---- demo mode (explore the UI with sample data, no board) ----

    /** Seed sample detections so the whole UI works without a board.
     *  Behind the connect screen's "Continue without pairing" button. */
    fun seedDemoData() {
        _demoMode.value = true
        _deviceName.value = "ACAB"
        _status.value = DeviceStatus.fromJson(JSONObject(
            """{"fw":"ACAB 1.6","up":4920,"total":7,"ble":true,"wifi":true,"bodycam":false,"tracker":true,"buzzer":true,"vol":70,"gps":true}"""))
        val samples = listOf(
            """{"t":1,"s":1,"meth":1,"c":95,"mac":"AC:AB:00:7F:2A:10","rssi":-54,"name":"FlockSafety","lat":37.7799,"lon":-122.4202,"n":12,"new":true}""",
            """{"t":1,"s":0,"meth":4,"c":88,"mac":"AC:AB:00:91:5B:22","rssi":-67,"lat":37.7782,"lon":-122.4175,"n":4}""",
            """{"t":2,"s":0,"meth":2,"c":72,"mac":"AC:AB:00:3C:7E:01","rssi":-76,"det":"Raven audio v2","lat":37.7808,"lon":-122.4188,"n":2}""",
            """{"t":4,"s":2,"meth":7,"c":99,"mac":"DA:7E:E0:44:21:09","rssi":-61,"id":"1581F4FED0A2B7","lat":37.7816,"lon":-122.4169,"plat":37.7821,"plon":-122.4151,"alt":84,"n":1,"new":true}""",
            """{"t":3,"s":0,"meth":3,"c":45,"mac":"A0:0F:11:BA:7C:33","rssi":-88,"n":1}""",
            """{"t":5,"s":0,"meth":3,"c":85,"mac":"4C:00:12:19:AA:BB","rssi":-72,"det":"Apple Find My (offline)","lat":37.7791,"lon":-122.4196,"n":3}""",
        )
        val now = System.currentTimeMillis()
        val wobble = listOf(-6, -3, -7, -1, -4, 2, -2, 1, -3, 0, -1, 1, -2, 0)
        for (s in samples) {
            val d = Detection.fromJson(JSONObject(s))
            store[d.id] = d
            firstSeenAt[d.id] = now; lastSeenAt[d.id] = now
            rssiHistory[d.id] = wobble.map { (d.rssi + it).coerceIn(-99, -30) }.toMutableList()
        }
        _detections.value = store.values.toList().asReversed()
        _state.value = ConnState.READY
    }

    /** Drop out of demo mode, back to the connect screen. */
    fun exitDemo() {
        _demoMode.value = false
        clearLog()
        _status.value = null
        _deviceName.value = null
        _state.value = ConnState.DISCONNECTED
    }

    // ---- the long-lived buffer key (32 random bytes, generated once) ----
    //
    // The board needs the raw 32 bytes as hex to decrypt the records it buffered while we
    // were away, so we can't hand it an AndroidKeyStore handle directly — those don't
    // export their key material. Instead we generate 32 random bytes once, wrap them with
    // a non-exportable AES-GCM key held in the AndroidKeyStore, and persist only the
    // wrapped blob. The plaintext key never sits in SharedPreferences.

    private fun keyHex(): String = loadOrCreateKey().joinToString("") { "%02x".format(it) }

    private fun loadOrCreateKey(): ByteArray {
        prefs.getString("bufKey", null)?.let { stored ->
            runCatching { return unwrapKey(stored) }   // fall through and regenerate if unwrap fails
        }
        val raw = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        prefs.edit().putString("bufKey", wrapKey(raw)).apply()
        return raw
    }

    /** AES-GCM-encrypt the raw key with the Keystore wrapping key; store iv:ciphertext hex. */
    private fun wrapKey(raw: ByteArray): String {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, wrappingKey())
        val ct = cipher.doFinal(raw)
        return cipher.iv.joinToString("") { "%02x".format(it) } + ":" +
            ct.joinToString("") { "%02x".format(it) }
    }

    private fun unwrapKey(stored: String): ByteArray {
        val (ivHex, ctHex) = stored.split(":", limit = 2)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE, wrappingKey(),
            javax.crypto.spec.GCMParameterSpec(128, ivHex.hexToBytes()),
        )
        return cipher.doFinal(ctHex.hexToBytes())
    }

    /** The non-exportable AES key in the AndroidKeyStore that wraps the buffer key. */
    private fun wrappingKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    // ---- local persistence of filed detections (survives an app restart) ----

    private fun detectionStore(): File = File(context.filesDir, "detections.json")

    /** Snapshot the current store to disk as the same compact JSON the wire uses, tagged
     *  with the firstSeen pseudo/real timestamp so the order is restored on reload. */
    private fun persistDetections() {
        runCatching {
            val arr = JSONArray()
            for (d in store.values) {
                val o = detectionToJson(d)
                firstSeenAt[d.id]?.let { o.put("_fs", it) }
                arr.put(o)
            }
            detectionStore().writeText(arr.toString())
        }
    }

    /** Reload persisted detections on startup so replayed history isn't lost on a restart. */
    private fun loadPersistedDetections() {
        val raw = runCatching { detectionStore().readText() }.getOrNull() ?: return
        runCatching {
            val arr = JSONArray(raw)
            val entries = (0 until arr.length()).map { arr.getJSONObject(it) }
                .sortedBy { it.optLong("_fs", 0L) }   // oldest first, so asReversed() puts newest on top
            for (o in entries) {
                val d = Detection.fromJson(o)
                val fs = o.optLong("_fs", System.currentTimeMillis())
                firstSeenAt[d.id] = fs
                lastSeenAt[d.id] = fs
                rssiHistory.getOrPut(d.id) { mutableListOf() }.add(d.rssi)
                store[d.id] = d
            }
            _detections.value = store.values.toList().asReversed()
        }
    }

    /** Rebuild the compact wire JSON for a filed detection (enough to reload it). */
    private fun detectionToJson(d: Detection): JSONObject = JSONObject().apply {
        put("t", d.type.raw); put("s", d.source); put("meth", d.method); put("c", d.confidence)
        put("mac", d.mac); put("rssi", d.rssi); put("n", d.count)
        d.name?.let { put("name", it) }
        d.rid?.let { put("id", it) }
        d.detail?.let { put("det", it) }
        d.lat?.let { put("lat", it) }
        d.lon?.let { put("lon", it) }
        d.pilotLat?.let { put("plat", it) }
        d.pilotLon?.let { put("plon", it) }
        d.altitude?.let { put("alt", it) }
    }

    companion object {
        @Volatile private var INSTANCE: AcabBleManager? = null

        /** Process-wide singleton so the foreground service and the ViewModel share ONE
         *  link. The service owns the connect/disconnect lifecycle while Drive mode is on,
         *  so the ViewModel's onCleared() must not tear it down then. */
        fun getInstance(context: Context): AcabBleManager =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AcabBleManager(context.applicationContext).also { INSTANCE = it }
            }

        private const val KEY_ALIAS = "acab.buf.wrap"
        // A fixed point safely in the past that approx-time history counts down from, so a
        // seq-ordered replay lands strictly before "now" and keeps its relative order.
        private const val HIST_PSEUDO_BASE = 1_000_000_000_000L   // ~2001-09, far below any real wall clock
        // Cap on distinct devices held in memory / persisted, so a long drive can't grow the
        // store without bound. Evicts oldest-first; 500 unique devices is well beyond a session.
        private const val STORE_CAP = 500
    }
}

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

@Suppress("DEPRECATION")
private fun Intent.getParcelableExtraCompat(key: String): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        getParcelableExtra(key, BluetoothDevice::class.java)
    else getParcelableExtra(key)
