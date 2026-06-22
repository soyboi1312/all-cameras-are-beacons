package tech.acab.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import tech.acab.app.ui.AcabApp
import tech.acab.app.ui.theme.Acab

class MainActivity : ComponentActivity() {
    private val vm: AcabViewModel by viewModels()
    private var permissionsGranted by mutableStateOf(false)

    private val requestPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { syncPermissionState() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        syncPermissionState()
        // Ask for anything still missing (this also catches upgrades where Bluetooth
        // was granted but location was never asked for). Fresh launches only, so a
        // rotation doesn't nag again.
        if (savedInstanceState == null && !requestedPermissions().all { hasPermission(it) }) {
            requestPermissions.launch(requestedPermissions())
        }
        setContent {
            // Space Grotesk is the default face for any non-mono Text, like the iOS
            // app. Doesn't touch component colors.
            CompositionLocalProvider(
                LocalTextStyle provides LocalTextStyle.current.copy(fontFamily = Acab.display)
            ) {
                AcabApp(
                    ble = vm.ble,
                    permissionsGranted = permissionsGranted,
                    onRequestPermissions = { requestPermissions.launch(requestedPermissions()) },
                )
            }
        }
    }

    /** Recheck whether we can scan/connect, and kick off location if allowed. */
    private fun syncPermissionState() {
        permissionsGranted = requiredPermissions().all { hasPermission(it) }
        if (hasLocationPermission()) vm.startLocation()
    }

    // Everything we ask for in one prompt: BLE plus location for the map. On Android
    // 12+ you have to request COARSE alongside FINE or the FINE request is ignored —
    // that's why the location prompt used to never show up.
    private fun requestedPermissions(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        // Drive-mode counter notification (Android 13+ runtime grant).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }.toTypedArray()

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

    private fun hasPermission(p: String) =
        checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
}
