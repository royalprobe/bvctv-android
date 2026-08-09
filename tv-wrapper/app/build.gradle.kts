plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "at.bvclustenau.bvctvweb"
    compileSdk = 35

    defaultConfig {
        // EIGENE Kennung — darf sich NICHT mit der nativen App
        // (com.example.vbtv_app) ueberschneiden, sonst wuerde eine die
        // andere ersetzen.
        applicationId = "at.bvclustenau.bvctvweb"
        minSdk = 22
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Debug-Schluessel genuegt: die App wird per adb aufgespielt,
            // nicht ueber einen Store verteilt.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Keine Abhaengigkeiten: android.webkit.WebView steckt im System, AppCompat
// waere fuer eine einzige Vollbild-Ansicht unnoetiger Ballast.
dependencies { }
