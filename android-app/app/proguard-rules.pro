-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

-keep class com.edwardshin.trailforge.** { *; }

-keep class com.android.vending.billing.** { *; }
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**

-keep class androidx.car.app.** { *; }
-dontwarn androidx.car.app.**
-keep class com.edwardshin.trailforge.TrailForgeCarAppService { *; }
