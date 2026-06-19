plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing material, read from ~/.gradle/gradle.properties or env vars so
// no keystore path or password is ever committed. Create the key once with:
//   keytool -genkey -v -keystore acab-release.jks -keyalg RSA -keysize 2048 \
//     -validity 10000 -alias acab
// then set ACAB_STORE_FILE / ACAB_STORE_PASSWORD / ACAB_KEY_ALIAS /
// ACAB_KEY_PASSWORD. Absent them, the release build is left unsigned; debug is
// unaffected either way.
val acabStoreFile = (findProperty("ACAB_STORE_FILE") as String?) ?: System.getenv("ACAB_STORE_FILE")
val acabStorePassword = (findProperty("ACAB_STORE_PASSWORD") as String?) ?: System.getenv("ACAB_STORE_PASSWORD")
val acabKeyAlias = (findProperty("ACAB_KEY_ALIAS") as String?) ?: System.getenv("ACAB_KEY_ALIAS")
val acabKeyPassword = (findProperty("ACAB_KEY_PASSWORD") as String?) ?: System.getenv("ACAB_KEY_PASSWORD")

android {
    namespace = "tech.acab.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "tech.acab.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 12
        versionName = "1.0"
    }

    signingConfigs {
        if (acabStoreFile != null) {
            create("release") {
                storeFile = file(acabStoreFile)
                storePassword = acabStorePassword
                keyAlias = acabKeyAlias
                keyPassword = acabKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Signed only when the ACAB_* signing material is present.
            if (acabStoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
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
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.01.00")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // OpenStreetMap, no Google dependency. Wired in when the map screen lands.
    implementation("org.osmdroid:osmdroid-android:6.1.20")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
