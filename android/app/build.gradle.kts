import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Clé de publication : android/keystore.properties (hors git) ou variables d'environnement (CI).
// Sans elle, la release est signée avec la clé de debug, comme avant.
val keystoreProps = Properties().apply {
    rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun signingValue(key: String, env: String): String? = keystoreProps.getProperty(key) ?: System.getenv(env)

android {
    namespace = "fr.soufiane.navette"
    compileSdk = 36

    defaultConfig {
        applicationId = "fr.soufiane.navette"
        minSdk = 34 // Galaxy S24 : Android 14 minimum
        targetSdk = 36
        // Fixés par la CI à partir de l'étiquette de version.
        versionCode = (findProperty("navetteBuild") as String?)?.toInt() ?: 1
        versionName = (findProperty("navetteVersion") as String?) ?: "0.1.0"
    }

    signingConfigs {
        val storePath = signingValue("storeFile", "NAVETTE_KEYSTORE")
        if (storePath != null) {
            create("release") {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "NAVETTE_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "NAVETTE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "NAVETTE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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
