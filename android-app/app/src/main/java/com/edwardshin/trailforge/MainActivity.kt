package com.edwardshin.trailforge

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.webkit.GeolocationPermissions
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewAssetLoader

class MainActivity : AppCompatActivity() {
    private lateinit var webView: WebView
    private lateinit var locationBridge: LocationBridge
    private lateinit var sensorBridge: SensorBridge
    private lateinit var speechBridge: SpeechBridge
    private lateinit var billingBridge: BillingBridge
    private lateinit var fetchBridge: NativeFetchBridge
    private lateinit var hostBridge: HostBridge
    private lateinit var networkBridge: NetworkBridge
    private var pageReady = false
    private var networkStarted = false
    private var pendingGeo: Pair<String, GeolocationPermissions.Callback>? = null

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { grants ->
        val granted = grants[Manifest.permission.ACCESS_FINE_LOCATION] == true || hasFine()
        pendingGeo?.let { (origin, callback) ->
            callback.invoke(origin, granted, false)
            pendingGeo = null
        }
        if (granted) locationBridge.start()
        pushPermission(granted)
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)
        window.statusBarColor = Color.parseColor("#071018")
        window.navigationBarColor = Color.parseColor("#071018")
        WindowInsetsControllerCompat(window, window.decorView).isAppearanceLightStatusBars = false

        webView = WebView(this)
        setContentView(webView)
        webView.setBackgroundColor(Color.parseColor("#071018"))
        webView.setLayerType(WebView.LAYER_TYPE_HARDWARE, null)
        webView.isHorizontalScrollBarEnabled = false
        webView.isVerticalScrollBarEnabled = false

        val assetLoader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()

        locationBridge = LocationBridge(this) { json -> evaluate("window.TrailForge&&TrailForge.onNativeFix($json)") }
        sensorBridge = SensorBridge(this) { json -> evaluate("window.TrailForge&&TrailForge.onNativeAttitude($json)") }
        speechBridge = SpeechBridge(this)
        billingBridge = BillingBridge(this) { json -> evaluate("window.TrailForge&&TrailForge.onBilling($json)") }
        fetchBridge = NativeFetchBridge { id, body, ok ->
            val payload = org.json.JSONObject.quote(body)
            evaluate("window.TrailForge&&TrailForge.onNativeFetch(${org.json.JSONObject.quote(id)}, $ok, $payload)")
        }
        hostBridge = HostBridge(this)
        networkBridge = NetworkBridge(this) { online ->
            evaluate("window.TrailForge&&TrailForge.onNetwork($online)")
        }

        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            setGeolocationEnabled(true)
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_DEFAULT
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = false
            displayZoomControls = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            loadsImagesAutomatically = true
            userAgentString = "$userAgentString TrailForgeOverland/1.7.1"
        }

        webView.addJavascriptInterface(speechBridge, "TrailForgeSpeech")
        webView.addJavascriptInterface(billingBridge, "TrailForgeBilling")
        webView.addJavascriptInterface(fetchBridge, "TrailForgeNet")
        webView.addJavascriptInterface(hostBridge, "TrailForgeHost")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onGeolocationPermissionsShowPrompt(
                origin: String?,
                callback: GeolocationPermissions.Callback?
            ) {
                if (origin == null || callback == null) return
                if (hasFine()) {
                    callback.invoke(origin, true, false)
                } else {
                    pendingGeo = origin to callback
                    requestLocation()
                }
            }
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                val url = request?.url ?: return null
                return assetLoader.shouldInterceptRequest(url)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                pageReady = true
                sensorBridge.start()
                speechBridge.warmUp()
                billingBridge.start()
                if (!networkStarted) {
                    networkStarted = true
                    networkBridge.start()
                }
                if (hasFine()) locationBridge.start()
                pushPermission(hasFine())
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                webView.evaluateJavascript(
                    "(window.TrailForge&&TrailForge.onBack&&TrailForge.onBack())?1:0"
                ) { raw ->
                    if (raw == "1" || raw == "\"1\"") return@evaluateJavascript
                    runOnUiThread {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            }
        })

        webView.loadUrl("https://appassets.androidplatform.net/assets/index.html")
        if (!hasFine()) requestLocation()
    }

    override fun onResume() {
        super.onResume()
        if (pageReady) {
            sensorBridge.start()
            if (hasFine()) locationBridge.start()
            billingBridge.refresh()
        }
        webView.onResume()
    }

    override fun onPause() {
        webView.onPause()
        sensorBridge.stop()
        super.onPause()
    }

    override fun onDestroy() {
        if (networkStarted) networkBridge.stop()
        speechBridge.shutdown()
        billingBridge.destroy()
        locationBridge.stop()
        sensorBridge.stop()
        webView.removeJavascriptInterface("TrailForgeSpeech")
        webView.destroy()
        super.onDestroy()
    }

    private fun requestLocation() {
        permissionLauncher.launch(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            )
        )
    }

    private fun hasFine(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun pushPermission(granted: Boolean) {
        evaluate("window.TrailForge&&TrailForge.onLocationPermission($granted)")
    }

    private fun evaluate(script: String) {
        if (!::webView.isInitialized) return
        webView.post { webView.evaluateJavascript(script, null) }
    }
}
