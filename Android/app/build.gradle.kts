// The Go library (libsharing and tailnetkit, one aar: third_party/README.md), built by Tools/go-android.sh and not
// checked in. Without it the app still builds: no node of aOS's own (src/notailnet instead of src/tailnet).
val aosgo: File = rootProject.file("third_party/aosgo/aosgo.aar")
// -Paos.withoutGo=true builds as if it were missing.
val hasAosgo = aosgo.isFile && providers.gradleProperty("aos.withoutGo").orNull != "true"

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
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    sourceSets.getByName("main").kotlin.directories.add(if (hasAosgo) "src/tailnet/kotlin" else "src/notailnet/kotlin")

    buildTypes {
        release {
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
            // The live check against the real Mac side (LiveMacTests): Tools/android.sh :app:testDebugUnitTest
            // --tests '*LiveMacTests*' -Paos.live.link='aos-pair://...' (from `aosctl pair-test`; see README.md).
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
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    // SSH: Apache MINA SSHD's client; net.i2p's EdDSA for the Mac's ssh-ed25519 host key; SLF4J's no-op binding
    // (MINA logs through SLF4J; nothing of it should reach logcat, it could carry host names).
    implementation(libs.sshd.core)
    implementation(libs.eddsa)
    implementation(libs.slf4j.nop)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(kotlin("test-junit"))
}
