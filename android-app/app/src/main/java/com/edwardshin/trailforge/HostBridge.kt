package com.edwardshin.trailforge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.webkit.JavascriptInterface

class HostBridge(private val activity: Activity) {
    @JavascriptInterface
    fun openUrl(url: String?) {
        if (url.isNullOrBlank() || !url.startsWith("https://")) return
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        activity.runOnUiThread {
            try {
                activity.startActivity(intent)
            } catch (_: Exception) {
                // No handler for this https URL on the device.
            }
        }
    }
}
