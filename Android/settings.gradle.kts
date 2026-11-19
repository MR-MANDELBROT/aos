pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Termux's terminal-emulator and terminal-view (Apache-2.0), built by JitPack from a release tag; nothing
        // else comes from there.
        maven("https://jitpack.io") {
            content { includeGroup("com.github.termux.termux-app") }
        }
    }
}
rootProject.name = "aOS"
// :core is pure Kotlin (JVM): the protocol, pairing, crypto and models, shared with any later desktop client.
// :app is the Android app: keys, SSH, the companion client, the connection to the Mac, stores, state and UI.
include(":core", ":app")
