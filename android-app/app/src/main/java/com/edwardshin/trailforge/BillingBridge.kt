package com.edwardshin.trailforge

import android.app.Activity
import android.webkit.JavascriptInterface
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import org.json.JSONArray
import org.json.JSONObject

class BillingBridge(
    private val activity: Activity,
    private val onUpdate: (String) -> Unit
) : PurchasesUpdatedListener {
    private val catalog = listOf(
        "com.edwardshin.trailforge.pro.annual" to BillingClient.ProductType.SUBS,
        "com.edwardshin.trailforge.pro.monthly" to BillingClient.ProductType.SUBS,
        "com.edwardshin.trailforge.founders.lifetime" to BillingClient.ProductType.INAPP
    )
    private val titles = mapOf(
        "com.edwardshin.trailforge.pro.annual" to "TrailForge Pro Annual",
        "com.edwardshin.trailforge.pro.monthly" to "Weekend Expedition Monthly",
        "com.edwardshin.trailforge.founders.lifetime" to "Lifetime Overland Founders Pass"
    )
    private val fallbackPrices = mapOf(
        "com.edwardshin.trailforge.pro.annual" to "$24.99",
        "com.edwardshin.trailforge.pro.monthly" to "$4.99",
        "com.edwardshin.trailforge.founders.lifetime" to "$59.99"
    )
    private val details = linkedMapOf<String, ProductDetails>()
    private var pro = false
    private var connected = false

    private val billingClient: BillingClient = BillingClient.newBuilder(activity)
        .setListener(this)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder().enableOneTimeProducts().build()
        )
        .build()

    fun start() {
        if (billingClient.isReady) {
            queryProducts()
            queryPurchases()
            return
        }
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                connected = result.responseCode == BillingClient.BillingResponseCode.OK
                if (connected) {
                    queryProducts()
                    queryPurchases()
                } else {
                    emit()
                }
            }

            override fun onBillingServiceDisconnected() {
                connected = false
                emit()
            }
        })
    }

    fun refresh() {
        if (billingClient.isReady) queryPurchases()
    }

    fun destroy() {
        billingClient.endConnection()
    }

    @JavascriptInterface
    fun purchase(productId: String?) {
        val id = productId ?: return
        val product = details[id] ?: return
        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(product)
        product.subscriptionOfferDetails?.firstOrNull()?.offerToken?.let { token ->
            productParams.setOfferToken(token)
        }
        val flow = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(productParams.build()))
            .build()
        activity.runOnUiThread {
            billingClient.launchBillingFlow(activity, flow)
        }
    }

    @JavascriptInterface
    fun restore() {
        if (billingClient.isReady) queryPurchases() else start()
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            purchases.forEach { handle(it) }
        }
        emit()
    }

    private fun queryProducts() {
        val products = catalog.map { (id, type) ->
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(id)
                .setProductType(type)
                .build()
        }
        val params = QueryProductDetailsParams.newBuilder().setProductList(products).build()
        billingClient.queryProductDetailsAsync(params) { _, productDetailsList ->
            details.clear()
            productDetailsList.orEmpty().forEach { product ->
                details[product.productId] = product
            }
            emit()
        }
    }

    private fun queryPurchases() {
        val owned = mutableListOf<Purchase>()
        val subs = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        val inapp = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.INAPP)
            .build()
        billingClient.queryPurchasesAsync(subs) { _, purchases ->
            owned.addAll(purchases)
            billingClient.queryPurchasesAsync(inapp) { _, more ->
                owned.addAll(more)
                pro = false
                owned.forEach { handle(it) }
                emit()
            }
        }
    }

    private fun handle(purchase: Purchase) {
        val ours = purchase.products.any { id -> catalog.any { it.first == id } }
        if (!ours) return
        if (purchase.purchaseState == Purchase.PurchaseState.PURCHASED) {
            pro = true
            if (!purchase.isAcknowledged) {
                val ack = AcknowledgePurchaseParams.newBuilder()
                    .setPurchaseToken(purchase.purchaseToken)
                    .build()
                billingClient.acknowledgePurchase(ack) { emit() }
            }
        }
    }

    private fun emit() {
        val products = JSONArray()
        for ((id, type) in catalog) {
            val product = details[id]
            products.put(
                JSONObject()
                    .put("id", id)
                    .put("type", type)
                    .put("title", product?.title ?: titles[id])
                    .put("price", priceOf(product) ?: fallbackPrices[id])
                    .put("available", product != null)
            )
        }
        val json = JSONObject()
            .put("ready", billingClient.isReady)
            .put("pro", pro)
            .put("products", products)
            .toString()
        onUpdate(json)
    }

    private fun priceOf(product: ProductDetails?): String? {
        if (product == null) return null
        product.oneTimePurchaseOfferDetails?.formattedPrice?.let { return it }
        val phases = product.subscriptionOfferDetails
            ?.firstOrNull()
            ?.pricingPhases
            ?.pricingPhaseList
            ?: return null
        return phases.lastOrNull { it.priceAmountMicros > 0 }?.formattedPrice
            ?: phases.lastOrNull()?.formattedPrice
    }
}
