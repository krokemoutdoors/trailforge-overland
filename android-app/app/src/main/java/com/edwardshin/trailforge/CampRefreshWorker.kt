package com.edwardshin.trailforge

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class CampRefreshWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences("trailforge-camps", Context.MODE_PRIVATE)
        val lat = prefs.getString("lat", null)?.toDoubleOrNull() ?: return Result.success()
        val lon = prefs.getString("lon", null)?.toDoubleOrNull() ?: return Result.success()
        val camps = JSONArray()
        readArcGIS(
            "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RecreationOpportunities_01/MapServer/0/query",
            lat, lon, "markeractivity='Campground Camping'"
        ).forEach { row ->
            val name = row.optString("recareaname")
            addCamp(camps, "usfs-rec-" + row.opt("recareaid"), name, "USFS", row.opt("latitude"), row.opt("longitude"), "USFS")
        }
        readArcGIS(
            "https://gis.blm.gov/arcgis/rest/services/recreation/BLM_Natl_Recreation_Sites_Facilities/MapServer/8/query",
            lat, lon, "1=1"
        ).forEach { row ->
            addCamp(camps, "blm-camp-" + row.opt("FacilityID"), row.optString("FacilityName"), "BLM", row.opt("FacilityLatitude"), row.opt("FacilityLongitude"), "BLM")
        }
        val key = BuildConfig.RIDB_API_KEY
        if (key.isNotBlank()) {
            val url = "https://ridb.recreation.gov/api/v1/facilities?latitude=$lat&longitude=$lon&radius=15&limit=40&offset=0"
            val root = getJson(url, key)
            val rows = root?.optJSONArray("RECDATA") ?: JSONArray()
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val kind = row.optString("FacilityTypeDescription") + " " + row.optString("FacilityName")
                if (!kind.contains("camp", ignoreCase = true)) continue
                addCamp(
                    camps,
                    "ridb-" + row.opt("FacilityID"),
                    row.optString("FacilityName"),
                    "Recreation.gov",
                    row.opt("FacilityLatitude"),
                    row.opt("FacilityLongitude"),
                    "Recreation.gov"
                )
            }
        }
        val payload = JSONObject()
            .put("fetchedAt", System.currentTimeMillis())
            .put("lat", lat)
            .put("lon", lon)
            .put("camps", camps)
        prefs.edit().putString("pending", payload.toString()).apply()
        return Result.success()
    }

    private fun addCamp(camps: JSONArray, id: String, name: String, agency: String, lat: Any?, lon: Any?, source: String) {
        val y = (lat as? Number)?.toDouble() ?: lat?.toString()?.toDoubleOrNull() ?: return
        val x = (lon as? Number)?.toDouble() ?: lon?.toString()?.toDoubleOrNull() ?: return
        if (name.isBlank() || kotlin.math.abs(y) > 90 || kotlin.math.abs(x) > 180) return
        camps.put(JSONObject()
            .put("id", id)
            .put("name", name)
            .put("agency", agency)
            .put("lat", y)
            .put("lon", x)
            .put("source", source))
    }

    private fun readArcGIS(endpoint: String, lat: Double, lon: Double, where: String): List<JSONObject> {
        val query = "where=" + URLEncoder.encode(where, "UTF-8") +
            "&geometry=$lon,$lat&geometryType=esriGeometryPoint&inSR=4326" +
            "&spatialRel=esriSpatialRelIntersects&distance=18000&units=esriSRUnit_Meter" +
            "&outFields=*&returnGeometry=false&resultRecordCount=40&f=json"
        val root = getJson("$endpoint?$query", null) ?: return emptyList()
        val features = root.optJSONArray("features") ?: return emptyList()
        val rows = mutableListOf<JSONObject>()
        for (index in 0 until features.length()) {
            features.optJSONObject(index)?.optJSONObject("attributes")?.let { rows.add(it) }
        }
        return rows
    }

    private fun getJson(url: String, apiKey: String?): JSONObject? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15000
            readTimeout = 20000
            setRequestProperty("Accept", "application/json")
            setRequestProperty("User-Agent", "TrailForgeOverland/1.7.7")
            if (!apiKey.isNullOrBlank()) setRequestProperty("apikey", apiKey)
        }
        return try {
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else null
            val text = stream?.bufferedReader()?.use { it.readText() } ?: return null
            JSONObject(text)
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }
}
