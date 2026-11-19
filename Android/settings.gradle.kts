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
        // JetBrains' JediTerm (the desktop's terminal, LGPL-3.0/Apache-2.0) is only published there.
        maven("https://packages.jetbrains.team/maven/p/ij/intellij-dependencies") {
            content { includeGroup("org.jetbrains.jediterm") }
        }
    }
}
rootProject.name = "aOS"
// :core is pure Kotlin (JVM): the protocol, pairing, crypto and models.
// :shared is the app without UI (JVM): SSH, the companion client, the connection, the model, terminal and screen logic.
// shared-ui/ is the Compose UI both apps compile in (a source folder, not a module).
// :app is the Android app, :desktop the one for Windows and Linux (Compose Multiplatform; runs on macOS for development).
include(":core", ":shared", ":app")
if (file("desktop/build.gradle.kts").exists()) include(":desktop")
