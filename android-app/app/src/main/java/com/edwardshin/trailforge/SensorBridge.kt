package com.edwardshin.trailforge

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import org.json.JSONObject
import kotlin.math.atan2
import kotlin.math.sqrt

class SensorBridge(
    context: Context,
    private val onAttitude: (String) -> Unit
) : SensorEventListener {
    private val sensorManager = context.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotation = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        ?: sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private var started = false
    private var haveRotation = false
    private var lastEmit = 0L
    private var ax = 0.0
    private var ay = 0.0
    private var az = 0.0
    private var gx = 0.0
    private var gy = 0.0
    private var gz = 0.0

    fun start() {
        if (started) return
        rotation?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        accelerometer?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        gyroscope?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        started = true
    }

    fun stop() {
        if (!started) return
        sensorManager.unregisterListener(this)
        started = false
        haveRotation = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                ax = event.values[0].toDouble()
                ay = event.values[1].toDouble()
                az = event.values[2].toDouble()
                if (!haveRotation) emit(accelPitch(), accelRoll(), Double.NaN, "accelerometer")
            }
            Sensor.TYPE_GYROSCOPE -> {
                gx = event.values[0].toDouble()
                gy = event.values[1].toDouble()
                gz = event.values[2].toDouble()
            }
            Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                haveRotation = true
                SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                SensorManager.getOrientation(rotationMatrix, orientation)
                val heading = (Math.toDegrees(orientation[0].toDouble()) + 360.0) % 360.0
                val pitch = Math.toDegrees(orientation[1].toDouble())
                val roll = Math.toDegrees(orientation[2].toDouble())
                emit(pitch, roll, heading, "rotation")
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun accelPitch(): Double {
        return Math.toDegrees(atan2(-ax, sqrt(ay * ay + az * az)))
    }

    private fun accelRoll(): Double {
        return Math.toDegrees(atan2(ay, az))
    }

    private fun emit(pitch: Double, roll: Double, heading: Double, source: String) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastEmit < 80) return
        lastEmit = now
        val json = JSONObject()
        json.put("pitch", pitch)
        json.put("roll", roll)
        json.put("heading", if (heading.isNaN()) JSONObject.NULL else heading)
        json.put("ax", ax)
        json.put("ay", ay)
        json.put("az", az)
        json.put("gx", gx)
        json.put("gy", gy)
        json.put("gz", gz)
        json.put("source", source)
        onAttitude(json.toString())
    }
}
