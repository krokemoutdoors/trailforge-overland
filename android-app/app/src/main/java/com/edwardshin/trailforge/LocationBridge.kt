package com.edwardshin.trailforge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import androidx.core.content.ContextCompat
import org.json.JSONObject

class LocationBridge(
    context: Context,
    private val onFix: (String) -> Unit
) {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var started = false

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) = publish(location)
        override fun onProviderEnabled(provider: String) = Unit
        override fun onProviderDisabled(provider: String) = Unit
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
    }

    @SuppressLint("MissingPermission")
    fun start() {
        if (!permitted()) return
        if (!started) {
            val providers = mutableListOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                providers.add(LocationManager.FUSED_PROVIDER)
            }
            for (provider in providers) {
                if (!manager.allProviders.contains(provider)) continue
                try {
                    manager.requestLocationUpdates(provider, 800L, 0f, listener, Looper.getMainLooper())
                } catch (_: IllegalArgumentException) {
                    // Provider disappeared between the check and the request.
                } catch (_: SecurityException) {
                    return
                }
            }
            started = true
        }
        for (provider in manager.allProviders) {
            val last = try {
                manager.getLastKnownLocation(provider)
            } catch (_: SecurityException) {
                null
            }
            if (last != null) publish(last)
        }
    }

    fun stop() {
        if (!started) return
        manager.removeUpdates(listener)
        started = false
    }

    private fun permitted(): Boolean {
        return ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun publish(location: Location) {
        val json = JSONObject()
        json.put("lat", location.latitude)
        json.put("lon", location.longitude)
        json.put("accuracy", if (location.hasAccuracy()) location.accuracy.toDouble() else JSONObject.NULL)
        json.put("altitude", if (location.hasAltitude()) location.altitude else JSONObject.NULL)
        json.put("speed", if (location.hasSpeed()) location.speed.toDouble() else JSONObject.NULL)
        json.put("heading", if (location.hasBearing()) location.bearing.toDouble() else JSONObject.NULL)
        json.put("time", location.time)
        json.put("source", "android")
        onFix(json.toString())
    }
}
