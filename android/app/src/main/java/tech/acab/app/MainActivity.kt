package tech.acab.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import tech.acab.app.ble.BoardKind
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.defaultLiveModeStartConfirmed
import tech.acab.app.ble.defaultLiveModeStartReady
import tech.acab.app.net.AlprStore
import tech.acab.app.ui.AcabApp
import tech.acab.app.ui.BeaconSegment
import tech.acab.app.ui.NearbyPermissionDenial
import tech.acab.app.ui.canRetryAllMissingPermissions
import tech.acab.app.ui.resolveNearbyPermissionDenial
import tech.acab.app.ui.theme.AcabTheme
import tech.acab.app.ui.theme.ContrastMode

class MainActivity : ComponentActivity() {
    private val vm: AcabViewModel by viewModels()
    private var permissionsGranted by mutableStateOf(false)
    private var locationGranted by mutableStateOf(false)
    private var notificationsAvailable by mutableStateOf(false)
    private var nearbyPermissionDenial by mutableStateOf(NearbyPermissionDenial.NONE)
    private var liveNotificationDenied by mutableStateOf(false)
    // True from the moment requestOptionalLocation opens the system Location dialog until its
    // result arrives. AcabApp holds the Live rationale back while it is up (contracts 9.1).
    private var locationRequestOutstanding by mutableStateOf(false)
    private var startDriveRequested = false
    private var defaultLiveStartPending = false
    private var scanAfterPermissionGrant = false

    private val requestPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        syncPermissionState()
        if (scanAfterPermissionGrant) {
            if (permissionsGranted) maybeStartPermissionScan()
            else scanAfterPermissionGrant = false
        }
    }

    private val requestLocation = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        locationRequestOutstanding = false
        syncPermissionState()
    }

    private val requestDriveNotification = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        syncPermissionState()
        liveNotificationDenied = !granted
        completeDefaultLiveStartIfPossible()
        // Live Mode stays usable when declined; Beacon settings surfaces the blocked surface.
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge on every OS version, not only the Android 15+ that targetSdk 36 forces it
        // on: without this, Android 8 to 14 paints its own navigation bar in the window colour
        // under the M3 NavigationBar (surfaceContainer), a two-tone band. The Compose tree already
        // pads for the bars (safeDrawing, statusBars, NavigationBar's own insets). Both bars are
        // transparent with the DARK style because the app is dark-only, so the bar icons stay
        // light even while the system is in light mode. The theme's bar colours still paint the
        // cold-start frame before this runs.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        defaultLiveStartPending = savedInstanceState?.getBoolean(KEY_DEFAULT_LIVE_PENDING) == true
        scanAfterPermissionGrant = savedInstanceState?.getBoolean(KEY_SCAN_AFTER_PERMISSION) == true
        liveNotificationDenied = savedInstanceState?.getBoolean(KEY_LIVE_NOTIFICATION_DENIED) == true
        // A rotation while the system Location dialog is up recreates this activity; the result is
        // re-delivered to the new instance, whose callback clears the flag.
        locationRequestOutstanding =
            savedInstanceState?.getBoolean(KEY_LOCATION_REQUEST_OUTSTANDING) == true
        syncPermissionState()
        // Prime the known-ALPR store at launch so a default-on install fetches the dataset
        // before the first Map open, matching iOS (ALPRStore.init refreshes at launch).
        // Construction is inert while the layer is switched off.
        AlprStore.getInstance(applicationContext)
        // Palette before the first frame: the persisted "always use higher contrast" switch
        // plus the system contrast inputs. Listeners keep it live while we are up.
        ContrastMode.load(this)
        ContrastMode.startListening(this)
        // Screenshot / UI-check hook, DEBUG builds only (see EXTRA_BOARD_KIND). Display-only: it
        // never touches the real remembered board, prefs or a radio call.
        if (BuildConfig.DEBUG) {
            debugBoardKindExtra(intent?.getStringExtra(EXTRA_BOARD_KIND))?.let(vm.ble::applyDebugBoardKind)
        }
        handleDeepLink(intent)
        // The permission prompt is NOT fired here anymore. The connect screen shows a
        // "before the system asks" rationale first, and its CTA calls onRequestPermissions,
        // so the OS prompt only appears after the user has seen why we ask.
        setContent {
            // The app's one MaterialTheme (colour scheme from the palette in force, M3 type
            // scale, M3 shapes). This is the only Compose root, so the only place it goes.
            AcabTheme {
                AcabApp(
                    ble = vm.ble,
                    permissionsGranted = permissionsGranted,
                    locationGranted = locationGranted,
                    notificationsAvailable = notificationsAvailable,
                    nearbyPermissionDenial = nearbyPermissionDenial,
                    liveNotificationDenied = liveNotificationDenied,
                    locationRequestOutstanding = locationRequestOutstanding,
                    onRequestPermissions = {
                        getSharedPreferences("acab_ui", MODE_PRIVATE).edit()
                            .putBoolean(KEY_NEARBY_PERMISSION_REQUESTED, true).apply()
                        nearbyPermissionDenial = NearbyPermissionDenial.NONE
                        scanAfterPermissionGrant = true
                        requestPermissions.launch(requestedPermissions())
                    },
                    onRequestLocation = ::requestOptionalLocation,
                    onStartDefaultLiveMode = ::startDefaultLiveMode,
                    onLiveNotificationDenialHandled = { liveNotificationDenied = false },
                    initialBeaconSegment = beaconSegmentExtra(intent?.getStringExtra(EXTRA_BEACON_SEGMENT)),
                )
            }
        }
    }

    // Re-sync when returning from system Settings, so granting there updates the UI without
    // needing a relaunch (previously the onCreate auto-request covered this path).
    override fun onResume() {
        super.onResume()
        syncPermissionState()
        ContrastMode.syncSystem(this)
        maybeStartPermissionScan()
        maybeStartRequestedDrive()
        completeDefaultLiveStartIfPossible()
    }

    override fun onDestroy() {
        ContrastMode.stopListening(this)
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(KEY_DEFAULT_LIVE_PENDING, defaultLiveStartPending)
        outState.putBoolean(KEY_SCAN_AFTER_PERMISSION, scanAfterPermissionGrant)
        outState.putBoolean(KEY_LIVE_NOTIFICATION_DENIED, liveNotificationDenied)
        outState.putBoolean(KEY_LOCATION_REQUEST_OUTSTANDING, locationRequestOutstanding)
        super.onSaveInstanceState(outState)
    }

    // launchMode=singleTask: a Live Mode notification tap lands here when the activity
    // already exists, instead of relaunching it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    /** Live Mode notification tap: raise the "open the Log tab, NEW filter" signal that
     *  MainScreen consumes once it's on screen. The extra is stripped after reading so a
     *  recreation replaying the same intent doesn't re-trigger the jump; a launch from
     *  recents after process death re-delivers the original intent (extra intact), so the
     *  HISTORY flag guards that replay too. */
    private fun handleDeepLink(intent: Intent?) {
        if (intent == null) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.getBooleanExtra(EXTRA_OPEN_LOG_NEW, false)) {
            openLogNew.value = true
            intent.removeExtra(EXTRA_OPEN_LOG_NEW)
        }
        if (intent.getBooleanExtra(EXTRA_START_DRIVE, false)) {
            startDriveRequested = true
            intent.removeExtra(EXTRA_START_DRIVE)
            maybeStartRequestedDrive()
        }
    }

    /** A Quick Settings tile is a background service on Android 14 and newer, so it cannot start
     * a location foreground service under while-in-use permission. Apply its request only after
     * this activity is actually visible. */
    private fun maybeStartRequestedDrive() {
        if (!startDriveRequested ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        startDriveRequested = false
        // Sample data seeds READY too, so the link check alone is not the honesty gate: a tile tap
        // under "Continue without pairing" would otherwise pin a real ongoing Live Mode
        // notification over canned rows, take location ownership into the background, and persist
        // the Live Mode preference from a demo action. Same rule startDefaultLiveMode applies, and
        // the one iOS keeps in liveModeCanRun.
        //
        // DriveModeTileService now greys the tile out under sample data as well, so a demo request
        // should not reach here at all. This stays as the backstop, because the request is applied
        // on a LATER resume: the tap can land on a render one emission stale, and demo can be
        // entered in the gap between the tap and this activity reaching RESUMED.
        if (vm.ble.state.value != ConnState.READY || vm.ble.demoMode.value) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
            requestDriveNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        vm.ble.startDriveMode()
    }

    /** Root-level default startup, invoked only after the setup checklist has completed. Keeping
     * this in the activity/root path means it runs regardless of the selected tab.
     * The explanatory UI decides whether this invocation should also trigger the one-time runtime
     * notification request; subsequent sessions simply restore the user's persisted choice. */
    private fun startDefaultLiveMode(requestNotification: Boolean) {
        if (vm.ble.state.value != ConnState.READY || vm.ble.demoMode.value ||
            !vm.ble.driveModeWanted.value) return
        // Treat this as an intent, not a one-shot callback. ActivityResult may deliver while the
        // activity is merely STARTED; consuming the flag there made the default path a no-op after
        // the user tapped Allow. It also has to survive rotation while the system dialog is up.
        defaultLiveStartPending = true
        if (requestNotification && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
            requestDriveNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        completeDefaultLiveStartIfPossible()
    }

    private fun completeDefaultLiveStartIfPossible() {
        if (!defaultLiveStartPending) return
        // An explicit Off or a switch into sample data cancels the queued default. A transient
        // reconnect or STARTED-only permission callback keeps it armed for the next usable edge.
        if (!vm.ble.driveModeWanted.value || vm.ble.demoMode.value) {
            defaultLiveStartPending = false
            return
        }
        // Do not consume the intent merely because startForegroundService accepted the request:
        // the service can still fail its foreground promotion asynchronously. Confirmation comes
        // from onLinkServiceStarted; until then a later resume is a bounded, user-visible retry.
        if (defaultLiveModeStartConfirmed(vm.ble.driveModeOn, vm.ble.driveServiceReady)) {
            defaultLiveStartPending = false
            return
        }
        if (!defaultLiveModeStartReady(
                pending = defaultLiveStartPending,
                activityResumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED),
                linkReady = vm.ble.state.value == ConnState.READY,
                demoMode = vm.ble.demoMode.value,
                wanted = vm.ble.driveModeWanted.value,
            )) return
        if (!vm.ble.driveModeOn) vm.ble.startDriveMode()
    }

    /** The pre-permission CTA says "Continue" and then scans, so a successful grant must do both.
     * Permission callbacks may arrive below RESUMED just like the notification result, and a
     * LOW_LATENCY scan must not be started until this activity is actually visible. */
    private fun maybeStartPermissionScan() {
        if (!scanAfterPermissionGrant || !permissionsGranted ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        scanAfterPermissionGrant = false
        vm.ble.startScan()
    }

    /** Recheck whether we can scan/connect, and kick off location if allowed. */
    private fun syncPermissionState() {
        permissionsGranted = requiredPermissions().all { hasPermission(it) }
        val permissionAsked = getSharedPreferences("acab_ui", MODE_PRIVATE)
            .getBoolean(KEY_NEARBY_PERMISSION_REQUESTED, false)
        val missingPermissions = requiredPermissions().filterNot(::hasPermission)
        nearbyPermissionDenial = resolveNearbyPermissionDenial(
            granted = permissionsGranted,
            requestedBefore = permissionAsked,
            // One permanently denied member of the required set still blocks scanning. A partial
            // grant must therefore go to Settings instead of re-requesting only the retryable half.
            canAskAgain = canRetryAllMissingPermissions(
                missingPermissions.map(::shouldShowRequestPermissionRationale),
            ),
        )
        locationGranted = hasLocationPermission()
        notificationsAvailable = DetectionNotifier.liveChannelDeliverable(this)
        if (notificationsAvailable) liveNotificationDenied = false
        vm.onPermissionsChanged(permissionsGranted, locationGranted)
    }

    // Android 12+ needs only Nearby Devices to find and pair with the beacon. Location is optional
    // there and is requested later from the setup checklist's Continue and from Map/geotagging
    // surfaces. On older Android, the platform itself gates BLE scanning on fine location, so it
    // remains part of the initial request.
    private fun requestedPermissions(): Array<String> = requiredPermissions()

    // What we actually need to scan and connect. On 12+ location is just for the
    // map, but pre-12 BLE scanning needs it too.
    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        else
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasLocationPermission() =
        hasPermission(Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun requestOptionalLocation() {
        if (hasLocationPermission()) {
            syncPermissionState()
            return
        }
        val prefs = getSharedPreferences("acab_ui", MODE_PRIVATE)
        val asked = prefs.getBoolean(KEY_LOCATION_REQUESTED, false)
        val permissions = locationPermissions()
        val permanentlyDenied = asked && permissions.none(::shouldShowRequestPermissionRationale)
        if (permanentlyDenied) {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null))
            )
            return
        }
        prefs.edit().putBoolean(KEY_LOCATION_REQUESTED, true).apply()
        // Only this path shows a system dialog over the app, so only this path raises the flag.
        locationRequestOutstanding = true
        requestLocation.launch(permissions)
    }

    private fun locationPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermission(p: String) =
        checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    companion object {
        /** Intent extra set by the drive-mode notification's contentIntent (AcabLinkService). */
        const val EXTRA_OPEN_LOG_NEW = "open_log_new"

        /** Quick Settings intent consumed only after the activity is visible. */
        const val EXTRA_START_DRIVE = "start_drive"

        /** Store-screenshot hook: "phone" opens the Beacon tab on its THIS PHONE segment; any
         *  other value, or no extra, opens BOARD. Parsed by [beaconSegmentExtra]. */
        const val EXTRA_BEACON_SEGMENT = "beacon_segment"

        /** DEBUG-only screenshot hook: a BoardKind raw value ("beacon", "ouiSpy", "meshDetect"),
         *  parsed by [debugBoardKindExtra] and honoured only when BuildConfig.DEBUG. The connect
         *  screen then lists a display-only "your <kind>" row (a tap does nothing) and reads that
         *  kind throughout, and sample data reports that kind's fw label, so the Beacon hero shows
         *  its title (AcabBleManager.applyDebugBoardKind). Example:
         *  adb shell am start -n tech.soyboi.beacons/tech.acab.app.MainActivity --es board_kind ouiSpy
         *  iOS twin: the `-boardKind ouiSpy|meshDetect|beacon` launch argument (ACABApp.swift). */
        const val EXTRA_BOARD_KIND = "board_kind"

        private const val KEY_LOCATION_REQUESTED = "location_requested"
        private const val KEY_NEARBY_PERMISSION_REQUESTED = "perms_requested"
        private const val KEY_DEFAULT_LIVE_PENDING = "default_live_pending"
        private const val KEY_SCAN_AFTER_PERMISSION = "scan_after_permission"
        private const val KEY_LIVE_NOTIFICATION_DENIED = "live_notification_denied"
        private const val KEY_LOCATION_REQUEST_OUTSTANDING = "location_request_outstanding"

        /** Pending deep link, as observable state rather than a MainScreen parameter:
         *  AcabApp sits between the activity and the tab shell, and the tap can arrive while
         *  the app is already composed. It stays raised until MainScreen is actually on
         *  screen (READY link) to consume it. */
        val openLogNew = mutableStateOf(false)
    }
}

/** The board kind named by [MainActivity.EXTRA_BOARD_KIND]: its exact raw value, else null, so a
 *  misspelt or empty extra is ignored rather than guessed at. */
internal fun debugBoardKindExtra(value: String?): BoardKind? = BoardKind.fromRaw(value)

/** The Beacon segment named by [MainActivity.EXTRA_BEACON_SEGMENT]: "phone" gives PHONE, anything
 *  else (including no extra) gives BOARD. iOS twin: the `-beacon-segment phone` launch argument. */
internal fun beaconSegmentExtra(value: String?): BeaconSegment = if (value == "phone") BeaconSegment.PHONE else BeaconSegment.BOARD
