import java.util.Properties

// The Go library (libsharing and tailnetkit, one aar: third_party/README.md), built by Tools/go-android.sh and not
// checked in. Without it the app still builds: no node of aOS's own (src/notailnet instead of src/tailnet).
val aosgo: File = rootProject.file("third_party/aosgo/aosgo.aar")
// -Paos.withoutGo=true builds as if it were missing.
val hasAosgo = aosgo.isFile && providers.gradleProperty("aos.withoutGo").orNull != "true"

// The release key (for the APK on the website and the releases page) is in keystore.properties, never in the
// repository: storeFile, storePassword, keyAlias, keyPassword. Without it a release build stays unsigned.
val releaseKey = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.isFile) f.inputStream().use { load(it) }
}
// -Paos.abis=arm64-v8a builds the phones' ABI only (the published APK); default both (a phone, the emulator).
val abis: List<String> = (providers.gradleProperty("aos.abis").orNull ?: "arm64-v8a,x86_64").split(",").map { it.trim() }

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "dev.marquart.aos"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.marquart.aos"
        minSdk = 29
        // 36: Android 17's local network permission (enforced for apps that target 37) needs its own flow first.
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        // The Go library has these two (a phone, the emulator).
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += abis }
    }

    // The UI shared with the desktop app (../shared-ui: Compose code and its strings, see README.md).
    sourceSets.getByName("main").kotlin.directories.add("../shared-ui/src/main/kotlin")
    sourceSets.getByName("main").res.directories.add("../shared-ui/src/main/res")
    sourceSets.getByName("test").kotlin.directories.add("../shared-ui/src/test/kotlin")
    sourceSets.getByName("main").kotlin.directories.add(if (hasAosgo) "src/tailnet/kotlin" else "src/notailnet/kotlin")
    // The screen's session engine: libsharing from the Go library (dev.marquart.aos.screen), else a stand-in.
    sourceSets.getByName("main").kotlin.directories.add(if (hasAosgo) "src/libsharing/kotlin" else "src/nolibsharing/kotlin")

    signingConfigs {
        if (releaseKey.getProperty("storeFile") != null) create("release") {
            storeFile = file(releaseKey.getProperty("storeFile"))
            storePassword = releaseKey.getProperty("storePassword")
            keyAlias = releaseKey.getProperty("keyAlias")
            keyPassword = releaseKey.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfigs.findByName("release")?.let { signingConfig = it }
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += setOf(
            "META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*",
            "META-INF/INDEX.LIST",
        )
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.all { test ->
            test.maxHeapSize = "1g"
            // The live check against the real Mac side (LiveTerminalTests; LiveMacTests is in :shared):
            // Tools/android.sh :app:testDebugUnitTest --tests '*LiveTerminalTests*' -Paos.live.link='aos-pair://...'
            // (from `aosctl pair-test`; see README.md).
            val live = providers.gradleProperty("aos.live.link").orNull
            if (live != null) {
                test.systemProperty("aos.live.link", live)
                test.outputs.upToDateWhen { false }
            }
            test.testLogging.showStandardStreams = live != null
        }
    }
}

dependencies {
    implementation(project(":core"))
    // The app without UI (SSH, companion, connection, model, terminal and screen logic), shared with the desktop app.
    implementation(project(":shared"))
    if (hasAosgo) implementation(files(aosgo))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    // Large screens: the window's size class and the fold (ui/layout/WindowLayouts.kt).
    implementation(libs.androidx.compose.material3.adaptive)
    implementation(libs.androidx.window)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    // SSH (Apache MINA SSHD, EdDSA, SLF4J's no-op binding) comes with :shared.
    // The terminal: Termux's emulator and view, fed from the SSH channel (dev.marquart.aos.terminal).
    implementation(libs.termux.terminal.view)
    implementation(libs.termux.terminal.emulator)
    // The UI (dev.marquart.aos.ui): icons, biometric prompts, Custom Tabs, the pairing code's QR scanner.
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.browser)
    implementation(libs.zxing.embedded)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(kotlin("test-junit"))
    testImplementation(testFixtures(project(":shared")))
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(kotlin("test-junit"))
}
