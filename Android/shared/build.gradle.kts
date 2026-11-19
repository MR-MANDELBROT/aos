// :shared is the companion app without its UI, plain Kotlin on the JVM: SSH (Apache MINA), the companion client, the
// connection to the Mac with the interfaces the platform implements (network, discovery, aOS's Tailscale, keys,
// stores), the app model, the terminal's session logic and the screen's input logic. Android (:app) and the desktop
// (:desktop) both use it; their UI comes from ../shared-ui (a source folder compiled into each, see README.md).
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    `java-test-fixtures`
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api(project(":core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    // SSH: Apache MINA SSHD's client; net.i2p's EdDSA for the Mac's ssh-ed25519 host key; SLF4J's no-op binding (MINA
    // logs through SLF4J; nothing of it should reach a log, it could carry host names).
    api(libs.sshd.core)
    implementation(libs.eddsa)
    implementation(libs.slf4j.nop)
    // The in-process Mac for tests (an SSH server with the companion, a pairing listener): used by :app's and
    // :desktop's tests too.
    testFixturesApi(libs.sshd.core)
    testFixturesApi(libs.kotlinx.coroutines.core)
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.test {
    maxHeapSize = "1g"
    // The live check against the real Mac side (LiveMacTests): Tools/android.sh :shared:test --tests '*LiveMacTests*'
    // -Paos.live.link='aos-pair://...' (from `aosctl pair-test`; see README.md).
    val live = providers.gradleProperty("aos.live.link").orNull
    if (live != null) {
        systemProperty("aos.live.link", live)
        outputs.upToDateWhen { false }
    }
    testLogging.showStandardStreams = live != null
}
