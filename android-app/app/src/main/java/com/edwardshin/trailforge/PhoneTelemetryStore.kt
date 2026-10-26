package com.edwardshin.trailforge

object PhoneTelemetryStore {
    @Volatile var latitude: Double = 37.9589
    @Volatile var longitude: Double = -107.7352
    @Volatile var speedMph: Int = 0
    @Volatile var altitudeFt: Int = 0
    @Volatile var hasFix: Boolean = false

    fun update(latitude: Double, longitude: Double, speedMps: Double, altitudeMeters: Double) {
        this.latitude = latitude
        this.longitude = longitude
        speedMph = if (speedMps >= 0) (speedMps * 2.2369362920544).toInt().coerceAtLeast(0) else 0
        if (!altitudeMeters.isNaN()) {
            altitudeFt = (altitudeMeters * 3.280839895).toInt()
        }
        hasFix = true
    }
}
