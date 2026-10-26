plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.edwardshin.trailforge"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.edwardshin.trailforge"
        minSdk = 26
        targetSdk = 35
        versionCode = 16
        versionName = "1.5.4"
    }

    val releaseStore = file(
        System.getenv("TRAILFORGE_STORE_FILE") ?: "${rootProject.projectDir}/trailforge-release.jks"
    )
    if (releaseStore.exists()) {
        signingConfigs {
            create("release") {
                storeFile = releaseStore
                storePassword = System.getenv("TRAILFORGE_STORE_PASSWORD") ?: "trailforge"
                keyAlias = System.getenv("TRAILFORGE_KEY_ALIAS") ?: "trailforge"
                keyPassword = System.getenv("TRAILFORGE_KEY_PASSWORD") ?: "trailforge"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (releaseStore.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        buildConfig = false
    }
    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt"
            )
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("com.android.billingclient:billing-ktx:7.1.1")
    implementation("androidx.car.app:app:1.4.0")
}
