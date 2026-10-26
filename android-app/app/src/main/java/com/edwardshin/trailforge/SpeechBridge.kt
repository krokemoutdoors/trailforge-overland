package com.edwardshin.trailforge

import android.content.Context
import android.speech.tts.TextToSpeech
import android.webkit.JavascriptInterface
import java.util.Locale

class SpeechBridge(context: Context) : TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(context.applicationContext, this)
    @Volatile private var ready = false
    @Volatile private var muted = false

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            tts.language = Locale.US
            tts.setSpeechRate(0.96f)
        }
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
