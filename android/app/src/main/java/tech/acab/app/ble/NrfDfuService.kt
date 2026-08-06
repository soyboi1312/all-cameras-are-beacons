package tech.acab.app.ble

import android.app.Activity
import no.nordicsemi.android.dfu.DfuBaseService
import tech.acab.app.MainActivity

/**
 * The Nordic DFU library's worker service, updating the nRF52840 co-processor over BLE. The
 * library does all the DFU protocol work on this service; we only point its "open the app"
 * notification at MainActivity. Registered in AndroidManifest with the connectedDevice foreground
 * type so it survives while the transfer runs. Started/observed from AcabBleManager.
 */
class NrfDfuService : DfuBaseService() {
    override fun getNotificationTarget(): Class<out Activity> = MainActivity::class.java

    // Follows the build type: off in release, on in debug, so a bench stall (bootloader response
    // codes, PRN flow control) is diagnosable from logcat without a source edit. The library logs
    // under the "DfuBaseService" / "DfuImpl" tags.
    override fun isDebug(): Boolean = tech.acab.app.BuildConfig.DEBUG
}
