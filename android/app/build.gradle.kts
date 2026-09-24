plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "fr.soufiane.navette"
    compileSdk = 36

    defaultConfig {
        applicationId = "fr.soufiane.navette"
        minSdk = 34 // Galaxy S24 : Android 14 minimum
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Appli perso installée à la main : on signe la release avec la clé de debug.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core:1.16.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
