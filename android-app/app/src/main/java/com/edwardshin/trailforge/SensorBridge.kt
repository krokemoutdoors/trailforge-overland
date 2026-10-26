package com.edwardshin.trailforge

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import android.view.WindowManager
import org.json.JSONObject
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * Publishes screen-aligned roll and pitch from gravity, remapped for the
 * current display rotation. Euler angles from [SensorManager.getOrientation]
 * gimbal-lock when a phone is mounted upright, and they swap axes in landscape.
 */
class SensorBridge(
    context: Context,
    private val onAttitude: (String) -> Unit
) : SensorEventListener {
    private val appContext = context.applicationContext
    private val sensorManager = appContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotation = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        ?: sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private val gravity = sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gyroscope = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    private val rotationMatrix = FloatArray(9)
    private val remappedMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private var started = false
    private var haveRotation = false
    private var haveGravity = false
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
        gravity?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        accelerometer?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        gyroscope?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        started = true
    }

    fun stop() {
        if (!started) return
        sensorManager.unregisterListener(this)
        started = false
        haveRotation = false
        haveGravity = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GRAVITY -> {
                haveGravity = true
                emitGravity(event.values[0].toDouble(), event.values[1].toDouble(), event.values[2].toDouble(), heading = Double.NaN, source = "gravity")
            }
            Sensor.TYPE_ACCELEROMETER -> {
                ax = event.values[0].toDouble()
                ay = event.values[1].toDouble()
                az = event.values[2].toDouble()
                if (!haveRotation && !haveGravity) {
                    emitGravity(ax, ay, az, heading = Double.NaN, source = "accelerometer")
                }
            }
            Sensor.TYPE_GYROSCOPE -> {
                gx = event.values[0].toDouble()
                gy = event.values[1].toDouble()
                gz = event.values[2].toDouble()
            }
            Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                haveRotation = true
                val heading = headingDegrees(event.values)
                if (!haveGravity) {
                    val device = gravityFromRotation(event.values)
                    emitGravity(device.first, device.second, device.third, heading, "rotation")
                } else if (!heading.isNaN()) {
                    emitGravity(lastDeviceX, lastDeviceY, lastDeviceZ, heading, "gravity")
                }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private var lastDeviceX = 0.0
    private var lastDeviceY = 0.0
    private var lastDeviceZ = -1.0

    private fun emitGravity(x: Double, y: Double, z: Double, heading: Double, source: String) {
        lastDeviceX = x
        lastDeviceY = y
        lastDeviceZ = z
        val screen = screenGravity(x, y, z, displayRotation())
        val unit = unitVector(screen.first, screen.second, screen.third)
        val roll = Math.toDegrees(atan2(unit.first, sqrt(unit.second * unit.second + unit.third * unit.third)))
        val pitch = Math.toDegrees(atan2(-unit.third, -unit.second))
        emit(pitch, roll, heading, unit, source)
    }

    private fun emit(pitch: Double, roll: Double, heading: Double, screen: Triple<Double, Double, Double>, source: String) {
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
        json.put("sx", screen.first)
        json.put("sy", screen.second)
        json.put("sz", screen.third)
        json.put("source", source)
        onAttitude(json.toString())
    }

    /**
     * Device gravity uses the natural portrait axes. Rotate into the screen:
     * x right, y up the glass, z out of the glass.
     */
    private fun screenGravity(x: Double, y: Double, z: Double, rotation: Int): Triple<Double, Double, Double> {
        return when (rotation) {
            Surface.ROTATION_90 -> Triple(-y, x, z)
            Surface.ROTATION_270 -> Triple(y, -x, z)
            Surface.ROTATION_180 -> Triple(-x, -y, z)
            else -> Triple(x, y, z)
        }
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int {
        val window = appContext.getSystemService(WindowManager::class.java)
        val rotation = window?.defaultDisplay?.rotation
        if (rotation != null) return rotation
        val displays = appContext.getSystemService(android.hardware.display.DisplayManager::class.java)
        return displays?.getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation ?: Surface.ROTATION_0
    }

    private fun headingDegrees(values: FloatArray): Double {
        SensorManager.getRotationMatrixFromVector(rotationMatrix, values)
        val axes = remapAxes(displayRotation())
        val ok = SensorManager.remapCoordinateSystem(rotationMatrix, axes.first, axes.second, remappedMatrix)
        SensorManager.getOrientation(if (ok) remappedMatrix else rotationMatrix, orientation)
        return (Math.toDegrees(orientation[0].toDouble()) + 360.0) % 360.0
    }

    private fun gravityFromRotation(values: FloatArray): Triple<Double, Double, Double> {
        // Device-frame gravity. [emitGravity] rotates this into the current screen orientation.
        SensorManager.getRotationMatrixFromVector(rotationMatrix, values)
        return Triple(-rotationMatrix[2].toDouble(), -rotationMatrix[5].toDouble(), -rotationMatrix[8].toDouble())
    }

    private fun remapAxes(rotation: Int): Pair<Int, Int> {
        return when (rotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
        }
    }

    private fun unitVector(x: Double, y: Double, z: Double): Triple<Double, Double, Double> {
        val magnitude = sqrt(x * x + y * y + z * z)
        if (magnitude < 0.2) return Triple(0.0, -1.0, 0.0)
        return Triple(x / magnitude, y / magnitude, z / magnitude)
    }
}
