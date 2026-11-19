package dev.marquart.aos.ui.platform

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

// The shared UI (Android/shared-ui) is compiled into the Android app and into the desktop app. What differs between
// them comes in two ways:
//
// 1. `Platform`: an object each app sets at start (Android: `AndroidPlatform` in app/.../ui/platform, desktop:
//    `DesktopPlatform` in desktop/.../ui/platform) for what the UI asks of the device (web pages, clipboard, the person's
//    confirmation, notifications, the back gesture).
// 2. Files with the same declarations in both apps (like `expect`/`actual` without the keywords), in this package:
//    `Resources.kt` with `PlatformContext`, `platformContext()`, `stringResource`, `pluralStringResource`,
//    `painterResource`, `PlatformContext.text/quantityText/rawText/locale/relativeTime`; and `R` (Android's generated
//    one; on the desktop a generated `dev.marquart.aos.R` over the same XML files, desktop/build.gradle.kts).
//    If one side changes a signature, the other side's build fails: that is the check.

/** What the person's confirmation came to (biometrics on Android, Windows Hello or a password on the desktop). */
enum class PresenceOutcome { SUCCESS, CANCELLED, FAILED, UNAVAILABLE }

enum class PlatformKind { ANDROID, WINDOWS, LINUX, MAC;
    val isDesktop: Boolean get() = this != ANDROID
}

interface Platform {
    val kind: PlatformKind

    /** "0.1.0" for Settings > Version. */
    val appVersion: String

    /** Opens a web page (Android: a Custom Tab; desktop: the default browser). */
    fun openWeb(url: String)

    fun copyToClipboard(text: String, label: String = "")
    fun clipboardText(): String?

    /** Hands text to another app (Android's share sheet). False when there is none: the text went to the clipboard. */
    fun share(text: String): Boolean

    /** Asks the person to confirm it is them before an approval or a sign-in is sent (iOS: Face ID). */
    suspend fun confirmPresence(reason: String): PresenceOutcome

    /** Notifications for requests while the app is in the background are allowed. */
    fun notificationsEnabled(): Boolean

    /** Settings > Notifications was tapped: asks for the permission or opens the system's settings. Calls `changed`
     *  when the answer may have changed. */
    @Composable fun rememberNotificationsAction(changed: () -> Unit): () -> Unit

    /** Asks once for the notification permission after pairing (Android 13+); null where there is nothing to ask. */
    @Composable fun rememberNotificationPermissionRequest(): (() -> Unit)?

    /** The system's back gesture or button (Android); on the desktop Escape does it. */
    @Composable fun BackHandler(enabled: Boolean, onBack: () -> Unit)

    /** The app is in front and active (Android: resumed; desktop: the window is shown). */
    @Composable fun isActive(): Boolean

    /** The camera box of the pairing page (Android: the QR scanner); null: no camera, pasting only. */
    val pairingScanner: (@Composable (modifier: Modifier, demo: Boolean, onCode: (String) -> Unit) -> Unit)?

    companion object {
        lateinit var current: Platform
    }
}

/** `Platform.current.BackHandler`, for the call sites. */
@Composable
fun BackHandler(enabled: Boolean = true, onBack: () -> Unit) = Platform.current.BackHandler(enabled, onBack)
