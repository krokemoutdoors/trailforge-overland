package com.edwardshin.trailforge

import android.util.Base64
import android.webkit.JavascriptInterface
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.Executors

class NativeFetchBridge(
    private val onResult: (String, String, Boolean) -> Unit
) {
    private val executor = Executors.newFixedThreadPool(6)
    private val allowed = setOf(
        "router.project-osrm.org",
        "overpass-api.de",
        "overpass.kumi.systems",
        "waterservices.usgs.gov",
        "services3.arcgis.com",
        "apps.fs.usda.gov",
        "wcc.sc.egov.usda.gov",
        "gis.blm.gov",
        "geocoding.geo.census.gov",
        "nominatim.openstreetmap.org",
        "server.arcgisonline.com",
        "basemap.nationalmap.gov",
        "tile.openstreetmap.org",
        "basemaps.cartocdn.com",
        "gis.clark.wa.gov"
    )

    @JavascriptInterface
    fun fetch(id: String?, url: String?, method: String?, body: String?) {
        val requestId = id ?: return
        val target = url ?: return
        executor.execute {
            try {
                val parsed = URI(target)
                if (!parsed.scheme.equals("https", true) || parsed.host !in allowed) {
                    deliver(requestId, "blocked host", false)
                    return@execute
                }
                val connection = (URL(target).openConnection() as HttpURLConnection).apply {
                    requestMethod = if (method.equals("POST", true)) "POST" else "GET"
                    connectTimeout = 20000
                    readTimeout = 40000
                    instanceFollowRedirects = true
                    setRequestProperty("Accept", "application/json,text/plain,*/*")
                    setRequestProperty("User-Agent", "TrailForgeOverland/1.3.0")
                    if (requestMethod == "POST") {
                        doOutput = true
                        setRequestProperty("Content-Type", "text/plain; charset=utf-8")
                        outputStream.use { stream ->
                            stream.write((body ?: "").toByteArray(Charsets.UTF_8))
                        }
                    }
                }
                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
                connection.disconnect()
                deliver(requestId, text, code in 200..299)
            } catch (error: Exception) {
                deliver(requestId, error.message ?: "network error", false)
            }
        }
    }

    @JavascriptInterface
    fun fetchBytes(id: String?, url: String?) {
        val requestId = id ?: return
        val target = url ?: return
        executor.execute {
            try {
                val parsed = URI(target)
                if (!parsed.scheme.equals("https", true) || parsed.host !in allowed) {
                    deliver(requestId, "blocked host", false)
                    return@execute
                }
                val connection = (URL(target).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 15000
                    readTimeout = 20000
                    instanceFollowRedirects = true
                    setRequestProperty("Accept", "image/png,image/jpeg,*/*")
                    setRequestProperty("User-Agent", "TrailForgeOverland/1.3.0")
                }
                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
                connection.disconnect()
                val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
                onResult(requestId, encoded, code in 200..299 && bytes.isNotEmpty())
            } catch (error: Exception) {
                deliver(requestId, error.message ?: "network error", false)
            }
        }
    }

    private fun deliver(id: String, text: String, ok: Boolean) {
        val encoded = Base64.encodeToString(text.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        onResult(id, encoded, ok)
    }
}
