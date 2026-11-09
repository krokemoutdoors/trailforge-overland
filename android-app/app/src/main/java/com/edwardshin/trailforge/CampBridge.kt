package com.edwardshin.trailforge

import android.content.Context
import android.webkit.JavascriptInterface
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class CampBridge(private val context: Context) {
    @JavascriptInterface
    fun noteCenter(lat: String?, lon: String?) {
        if (lat.isNullOrBlank() || lon.isNullOrBlank()) return
        context.getSharedPreferences("trailforge-camps", Context.MODE_PRIVATE)
            .edit()
            .putString("lat", lat)
            .putString("lon", lon)
            .apply()
    }

    @JavascriptInterface
    fun pending(): String {
        val prefs = context.getSharedPreferences("trailforge-camps", Context.MODE_PRIVATE)
        val payload = prefs.getString("pending", "") ?: ""
        if (payload.isNotEmpty()) prefs.edit().remove("pending").apply()
        return payload
    }

    fun schedule() {
        val request = PeriodicWorkRequestBuilder<CampRefreshWorker>(24, TimeUnit.HOURS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            "trailforge-camp-refresh",
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }
}
