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

    // Release build: the library's verbose per-packet logging stays off.
    override fun isDebug(): Boolean = false
}
