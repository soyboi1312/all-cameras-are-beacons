package tech.acab.app

import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import androidx.lifecycle.AndroidViewModel
import tech.acab.app.ble.AcabBleManager

/** Keeps the BLE manager alive across config changes (so the connection survives),
 *  and feeds it the phone's location for geotagging non-drone detections. */
class AcabViewModel(app: Application) : AndroidViewModel(app) {
    // Process singleton, so the Drive-mode foreground service and this ViewModel share one
    // link (the service keeps it alive when the app is backgrounded mid-drive).
    val ble = AcabBleManager.getInstance(app)

    private val locationManager =
        app.getSystemService(Context.LOCATION_SERVICE) as LocationManager

    private val locListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            ble.setLocation(location.latitude, location.longitude)
        }
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    /** Start location updates once a location permission is granted. Uses both GPS
     *  and network providers so a fix comes in fast, and works indoors too. Safe to
     *  call more than once; re-registering the same listener just refreshes it. */
    @SuppressLint("MissingPermission")
    fun startLocation() {
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            runCatching {
                if (!locationManager.isProviderEnabled(provider)) return@runCatching
                locationManager.getLastKnownLocation(provider)
                    ?.let { ble.setLocation(it.latitude, it.longitude) }
                locationManager.requestLocationUpdates(provider, 5000L, 10f, locListener)
            }
        }
    }

    override fun onCleared() {
        runCatching { locationManager.removeUpdates(locListener) }
        // Keep the link if Drive mode's foreground service is holding it; else disconnect.
        if (!ble.driveModeOn) ble.disconnect()
        super.onCleared()
    }
}
