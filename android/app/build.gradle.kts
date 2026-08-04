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
    compileSdk = 36   // Android 16: compile against the Live Update promote APIs (targetSdk stays 35)

    defaultConfig {
        applicationId = "tech.acab.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 20
        versionName = "2.0.3"
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
            // R8 + resource shrink: Compose relies on R8 to finish its lambda/singleton
            // optimizations (unminified release Compose is measurably jankier), and
            // material-icons-extended is only shippable shrunk.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    // Lint policy, made explicit. NOTE these mostly RESTATE AGP defaults, they are documentation,
    // NOT the gate. The actual gate is the `:app:lintRelease` step in .github/workflows/
    // android-release.yml, because assembleRelease only triggers lintVitalRelease (the "fatal"
    // subset) and that PROVABLY misses real errors: with the bare <View> reintroduced in the
    // RemoteViews widget layout, lintVitalRelease still reported BUILD SUCCESSFUL (tested
    // 2026-07-30). Do not delete the CI step and assume this block covers you.
    // Warnings stay non-fatal, there are ~90 and triaging them should not block a release.
    lint {
        abortOnError = true
        warningsAsErrors = false
        checkReleaseBuilds = true
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.01.00")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.17.0")   // 1.17+ carries the Live Update promote APIs

    // Nordic legacy-DFU client, for updating the nRF52840 co-processor over BLE. The nRF runs the
    // Adafruit/Seeed bootloader, which speaks LEGACY Nordic DFU (service 0x1530), not secure DFU.
    // BSD-3, so it stays F-Droid-clean.
    implementation("no.nordicsemi.android:dfu:2.5.0")
    // The DFU library's abort is driven over a local broadcast (DfuBaseService.BROADCAST_ACTION).
    implementation("androidx.localbroadcastmanager:localbroadcastmanager:1.1.0")
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

    // Local JVM unit tests. The only suite here is the follow-evidence parity fixture set, which is
    // the ACTUAL guarantee that the Android and iOS scorers band the same journey the same way: the
    // scorer is deliberately pure Kotlin with no Android types, so it runs on a plain JVM against
    // the same vectors the Swift side asserts. Run with `./gradlew :app:testDebugUnitTest`.
    testImplementation("junit:junit:4.13.2")
}
