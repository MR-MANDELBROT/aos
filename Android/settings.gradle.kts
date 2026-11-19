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
    }
}
rootProject.name = "aOS"
// :core is pure Kotlin (JVM): the protocol, pairing, crypto and models, shared with any later desktop client.
// :app is the Android app: keys, SSH, the companion client, the connection to the Mac, stores, state and UI.
include(":core", ":app")
