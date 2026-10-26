package com.edwardshin.trailforge

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.text.SpannableString
import androidx.car.app.CarAppService
import androidx.car.app.model.CarIcon
import androidx.core.graphics.drawable.IconCompat
import androidx.car.app.CarContext
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.model.Action
import androidx.car.app.model.ActionStrip
import androidx.car.app.model.CarLocation
import androidx.car.app.model.ItemList
import androidx.car.app.model.ListTemplate
import androidx.car.app.model.Metadata
import androidx.car.app.model.Pane
import androidx.car.app.model.PaneTemplate
import androidx.car.app.model.Place
import androidx.car.app.model.PlaceMarker
import androidx.car.app.model.Row
import androidx.car.app.validation.HostValidator
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

class TrailForgeCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator {
        return HostValidator.Builder(applicationContext)
            .addAllowedHosts(R.array.hosts_allowlist)
            .build()
    }

    override fun onCreateSession(): Session = TrailForgeSession()
}

class TrailForgeSession : Session() {
    private var locationBridge: LocationBridge? = null

    override fun onCreateScreen(intent: Intent): Screen {
        locationBridge = LocationBridge(carContext) { }.also { it.start() }
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                locationBridge?.stop()
            }
        })
        return TrailForgeCarScreen(carContext)
    }
}

private data class HeadUnitPlace(
    val name: String,
    val detail: String,
    val latitude: Double,
    val longitude: Double
)

class TrailForgeCarScreen(carContext: CarContext) : Screen(carContext) {
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            invalidate()
            handler.postDelayed(this, 2000)
        }
    }

    init {
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                handler.post(tick)
            }

            override fun onStop(owner: LifecycleOwner) {
                handler.removeCallbacks(tick)
            }
        })
    }

    override fun onGetTemplate(): androidx.car.app.model.Template {
        val speed = if (PhoneTelemetryStore.hasFix) "${PhoneTelemetryStore.speedMph} MPH" else "0 MPH"
        val elevation = if (PhoneTelemetryStore.hasFix) "${PhoneTelemetryStore.altitudeFt} FT" else "— FT"
        val nearest = nearestTrail()
        val pane = Pane.Builder()
            .addRow(row("Speed", speed, PhoneTelemetryStore.latitude, PhoneTelemetryStore.longitude))
            .addRow(row("Elevation", "$elevation · phone GPS", PhoneTelemetryStore.latitude, PhoneTelemetryStore.longitude))
            .addRow(row("Active trail", "${nearest.name} · ${nearest.detail}", nearest.latitude, nearest.longitude))
            .addAction(
                Action.Builder()
                    .setTitle("Navigate")
                    .setOnClickListener { navigate(nearest.name, nearest.latitude, nearest.longitude) }
                    .build()
            )
            .build()
        val strip = ActionStrip.Builder()
            .addAction(
                Action.Builder()
                    .setTitle("Trails")
                    .setIcon(letterIcon("T"))
                    .setOnClickListener { screenManager.push(PlaceListScreen(carContext, "4x4 Trails & Corridors", trails())) }
                    .build()
            )
            .addAction(
                Action.Builder()
                    .setTitle("Camps")
                    .setIcon(letterIcon("C"))
                    .setOnClickListener { screenManager.push(PlaceListScreen(carContext, "<3° Flat Camps", camps())) }
                    .build()
            )
            .build()
        return PaneTemplate.Builder(pane)
            .setTitle("TrailForge")
            .setHeaderAction(Action.APP_ICON)
            .setActionStrip(strip)
            .build()
    }

    private fun nearestTrail(): HeadUnitPlace {
        return trails().minByOrNull { distance(it.latitude, it.longitude) } ?: trails().first()
    }

    private fun distance(lat: Double, lon: Double): Double {
        val dLat = lat - PhoneTelemetryStore.latitude
        val dLon = lon - PhoneTelemetryStore.longitude
        return dLat * dLat + dLon * dLon
    }
}

private class PlaceListScreen(
    carContext: CarContext,
    private val title: String,
    private val places: List<HeadUnitPlace>
) : Screen(carContext) {
    override fun onGetTemplate(): androidx.car.app.model.Template {
        val clickable = ItemList.Builder()
        for (place in places) {
            clickable.addItem(
                Row.Builder()
                    .setTitle(place.name)
                    .addText(place.detail)
                    .setMetadata(placeMetadata(place.latitude, place.longitude))
                    .setOnClickListener {
                        navigate(place.name, place.latitude, place.longitude)
                    }
                    .build()
            )
        }
        return ListTemplate.Builder()
            .setTitle(title)
            .setHeaderAction(Action.BACK)
            .setSingleList(clickable.build())
            .build()
    }
}

private fun letterIcon(letter: String): CarIcon {
    val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = Color.WHITE
    paint.textSize = 36f
    paint.textAlign = Paint.Align.CENTER
    canvas.drawText(letter, 32f, 44f, paint)
    return CarIcon.Builder(IconCompat.createWithBitmap(bitmap)).build()
}

private fun row(title: String, text: String, latitude: Double, longitude: Double): Row {
    return Row.Builder()
        .setTitle(title)
        .addText(SpannableString(text))
        .setMetadata(placeMetadata(latitude, longitude))
        .build()
}

private fun placeMetadata(latitude: Double, longitude: Double): Metadata {
    val place = Place.Builder(CarLocation.create(latitude, longitude))
        .setMarker(PlaceMarker.Builder().build())
        .build()
    return Metadata.Builder().setPlace(place).build()
}

private fun Screen.navigate(name: String, latitude: Double, longitude: Double) {
    val uri = Uri.parse("geo:$latitude,$longitude?q=$latitude,$longitude(${Uri.encode(name)})")
    try {
        carContext.startCarApp(Intent(CarContext.ACTION_NAVIGATE, uri))
    } catch (_: Exception) {
        // The head unit rejected the navigation handoff.
    }
}

private fun trails(): List<HeadUnitPlace> = listOf(
    HeadUnitPlace("Imogene Pass", "CO · high clearance · rig-fit check", 37.9589, -107.7352),
    HeadUnitPlace("Black Bear Pass", "CO · locker recommended", 37.910, -107.760),
    HeadUnitPlace("Engineer Pass", "CO · Alpine Loop", 37.975, -107.610),
    HeadUnitPlace("Ophir Pass", "CO · USFS", 37.853, -107.778),
    HeadUnitPlace("Rubicon Trail", "CA · high clearance", 38.990, -120.250),
    HeadUnitPlace("White Rim Trail", "UT · Canyonlands", 38.450, -109.920),
    HeadUnitPlace("Hell's Revenge", "UT · Moab · caution", 38.573, -109.549),
    HeadUnitPlace("WA Backcountry Corridor", "WABDR ref · public roads", 47.300, -120.500),
    HeadUnitPlace("Magruder Corridor", "ID / MT · USFS", 45.700, -114.850),
    HeadUnitPlace("Schnebly Hill", "AZ · Sedona", 34.848, -111.740)
)

private fun camps(): List<HeadUnitPlace> = listOf(
    HeadUnitPlace("Imogene Flat Pad", "<3° dispersed camp", 37.970, -107.720),
    HeadUnitPlace("Alpine Loop Pad", "<3° dispersed camp", 37.960, -107.640),
    HeadUnitPlace("White Rim Pad", "<3° canyon bench", 38.430, -109.900),
    HeadUnitPlace("Moab Sand Pad", "<3° slickrock edge", 38.560, -109.560),
    HeadUnitPlace("Rubicon Meadow", "<3° granite camp", 39.000, -120.230),
    HeadUnitPlace("Magruder Bench", "<3° forest camp", 45.680, -114.820)
)
