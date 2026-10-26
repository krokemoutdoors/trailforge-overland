package com.edwardshin.trailforge

import android.content.Context
import android.media.AudioAttributes
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import android.webkit.JavascriptInterface
import java.util.Locale

class SpeechBridge(context: Context) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(context.applicationContext, this)
    @Volatile private var ready = false
    @Volatile private var muted = false

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (!ready) return
        tts.language = Locale.US
        tts.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        selectBestVoice()
        tts.setSpeechRate(0.95f)
        tts.setPitch(1.02f)
    }

    private fun selectBestVoice() {
        val voices = tts.voices ?: return
        val english = voices.filter { voice ->
            val locale = voice.locale ?: return@filter false
            locale == Locale.US ||
                (locale.language.equals("en", true) &&
                    (locale.country.equals("US", true) ||
                        voice.name.contains("en-US", true) ||
                        voice.name.contains("en_US", true)))
        }
        val pool = english.ifEmpty { voices.filter { it.locale?.language.equals("en", true) == true } }
        val best = pool.maxByOrNull { score(it) } ?: return
        if (score(best) <= 0) return
        tts.voice = best
    }

    private fun score(voice: Voice): Int {
        val features = voice.features ?: emptySet()
        if (features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) return -1
        val name = voice.name.lowercase(Locale.US)
        if (name.contains("legacy")) return -1
        var value = 0
        if (voice.quality >= Voice.QUALITY_VERY_HIGH) value += 500
        else if (voice.quality >= Voice.QUALITY_HIGH) value += 400
        val neural = listOf(
            "en-us-x-iob",
            "en-us-x-sfg",
            "en-us-x-tpf",
            "en-us-x-iom",
            "-local",
            "-network",
            "wavenet",
            "neural"
        )
        if (neural.any { name.contains(it) }) value += 80
        if (!voice.isNetworkConnectionRequired) value += 10
        return value
    }

    fun warmUp() {
        if (ready) tts.language = Locale.US
    }

    @JavascriptInterface
    fun speak(text: String?) {
        if (muted || text.isNullOrBlank() || !ready) return
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "tf-${System.currentTimeMillis()}")
    }

    @JavascriptInterface
    fun stop() {
        tts.stop()
    }

    @JavascriptInterface
    fun setMuted(value: Boolean) {
        muted = value
        if (value) tts.stop()
    }

    @JavascriptInterface
    fun isMuted(): Boolean = muted

    @JavascriptInterface
    fun isReady(): Boolean = ready

    fun shutdown() {
        tts.stop()
        tts.shutdown()
    }
}
