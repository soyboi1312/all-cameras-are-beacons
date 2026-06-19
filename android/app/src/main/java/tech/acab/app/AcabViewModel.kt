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

/** Holds the BLE manager so the connection survives configuration changes, and
 *  feeds the phone's location to it for geotagging non-drone detections. */
class AcabViewModel(app: Application) : AndroidViewModel(app) {
    val ble = AcabBleManager(app.applicationContext)

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

    /** Begin location updates once a location permission is granted. Uses GPS and
     *  network providers so a fix arrives quickly, and indoors too. Safe to call
     *  more than once; re-registering the same listener just refreshes it. */
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
        ble.disconnect()
        super.onCleared()
    }
}
