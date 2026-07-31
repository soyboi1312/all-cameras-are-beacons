package tech.acab.app.svc

import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import tech.acab.app.R
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.ConnState

/**
 * Quick Settings "Drive mode" tile (F28): toggles the drive-mode foreground service from the
 * shade, the Android analog of the iOS Control Center toggle (DriveModeControl.swift). Goes
 * through AcabBleManager.startDriveMode / endDriveMode, the exact same path as the in-app
 * switch on the Device screen, so the driveMode flow (and that switch) stays in sync.
 */
class DriveModeTileService : TileService() {

    private val scope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
    private var listenJob: Job? = null

    override fun onStartListening() {
        super.onStartListening()
        val ble = AcabBleManager.getInstance(applicationContext)
        // Key off the manager's driveMode flag, not AcabLinkService.isRunning: the link service
        // can be held up for a background OTA reconnect with Drive mode never turned on, and
        // reading isRunning would then paint the tile ACTIVE for that OTA-only hold. driveModeOn
        // is the user-intent flag and flips synchronously with the in-app switch.
        //
        // Track the flows for as long as the shade is open, not a one-shot snapshot: drive mode
        // can end without a tap while we're listening (board disconnect via cleanup(), the
        // reconnect give-up watchdog), and a stale ACTIVE tile would then jump straight to
        // UNAVAILABLE on tap. StateFlows emit their current value immediately, so this also
        // covers the initial render.
        listenJob?.cancel()
        listenJob = scope.launch {
            combine(ble.driveMode, ble.state) { running, state ->
                running to (state == ConnState.READY)
            }.collect { (running, linked) ->
                // R7: with no board linked the tile is UNAVAILABLE (greyed), not a tappable
                // control that snaps back. A running session stays togglable so you can always
                // turn it off.
                render(active = running, available = linked || running)
            }
        }
    }

    override fun onStopListening() {
        listenJob?.cancel()
        listenJob = null
        super.onStopListening()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onClick() {
        super.onClick()
        val ble = AcabBleManager.getInstance(applicationContext)
        val turnOn = !ble.driveModeOn
        if (turnOn) {
            // No board linked: starting drive mode would just pin a permanent
            // "Reconnecting…" foreground notification. Show it as unavailable.
            if (ble.state.value != ConnState.READY) {
                render(active = false, available = false)
                return
            }
            // The service dies NOT_STICKY under memory pressure without resetting the
            // manager's driveMode flag; clear it first so startDriveMode can't early-return
            // on a stale true.
            ble.endDriveMode()
            ble.startDriveMode()
        } else {
            ble.endDriveMode()
        }
        // Render the intent we just applied; startDriveMode/endDriveMode flip driveModeOn
        // synchronously, and the flow collector re-renders on the emission either way.
        render(turnOn)
    }

    private fun render(active: Boolean, available: Boolean = true) {
        val tile = qsTile ?: return
        tile.state = when {
            !available -> Tile.STATE_UNAVAILABLE
            active -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        // Sentence case, matching the notification channel ("Drive mode") and the in-app
        // switch row; the deliberate all-caps "DRIVE MODE" notification title stays as-is.
        tile.label = "Drive mode"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_qs_drive)
        tile.updateTile()
    }
}
