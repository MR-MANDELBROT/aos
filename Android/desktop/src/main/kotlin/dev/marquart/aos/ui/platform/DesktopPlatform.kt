package dev.marquart.aos.ui.platform

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import dev.marquart.aos.desktop.BuildInfo
import dev.marquart.aos.desktop.Os
import java.awt.Desktop
import java.awt.Toolkit
import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.StringSelection
import java.net.URI

/** What the shared UI asks of the desktop (see Platform.kt). Made once by Main. */
class DesktopPlatform(
    /** Asks the person to confirm it is them (system/Presence.kt). */
    private val presence: suspend (String) -> PresenceOutcome,
    private val notificationsOn: () -> Boolean,
    /** Settings > Notifications: the desktop's own switch (there is no system permission to ask for). */
    private val toggleNotifications: () -> Unit,
) : Platform {
    override val kind: PlatformKind = Os.kind
    override val appVersion: String = BuildInfo.VERSION

    /** The window is shown (not hidden in the tray, not minimized). */
    var windowActive by mutableStateOf(true)

    override fun openWeb(url: String) {
        val uri = runCatching { URI(url) }.getOrNull() ?: return
        if (uri.scheme != "https" && uri.scheme != "http") return
        val opened = runCatching {
            if (Desktop.isDesktopSupported() && Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)) {
                Desktop.getDesktop().browse(uri)
                true
            } else false
        }.getOrDefault(false)
        if (!opened) runCatching {
            when {
                Os.isWindows -> ProcessBuilder("rundll32", "url.dll,FileProtocolHandler", uri.toString()).start()
                Os.isMac -> ProcessBuilder("open", uri.toString()).start()
                else -> ProcessBuilder("xdg-open", uri.toString()).start()
            }
        }
    }

    override fun copyToClipboard(text: String, label: String) {
        runCatching { Toolkit.getDefaultToolkit().systemClipboard.setContents(StringSelection(text), null) }
    }

    override fun clipboardText(): String? = runCatching {
        Toolkit.getDefaultToolkit().systemClipboard.getData(DataFlavor.stringFlavor) as? String
    }.getOrNull()

    override fun share(text: String): Boolean {
        copyToClipboard(text)
        return false
    }

    override suspend fun confirmPresence(reason: String): PresenceOutcome = presence(reason)

    override fun notificationsEnabled(): Boolean = notificationsOn()

    @Composable
    override fun rememberNotificationsAction(changed: () -> Unit): () -> Unit = {
        toggleNotifications()
        changed()
    }

    @Composable
    override fun rememberNotificationPermissionRequest(): (() -> Unit)? = null

    // Escape: the innermost page or sheet that wants "back" gets it (the window's key handler calls `back`).
    private val backStack = ArrayList<() -> Boolean>()

    @Composable
    override fun BackHandler(enabled: Boolean, onBack: () -> Unit) {
        val currentEnabled by rememberUpdatedState(enabled)
        val currentOnBack by rememberUpdatedState(onBack)
        val entry = remember { { if (currentEnabled) { currentOnBack(); true } else false } }
        DisposableEffect(entry) {
            synchronized(backStack) { backStack += entry }
            onDispose { synchronized(backStack) { backStack -= entry } }
        }
    }

    /** Escape was pressed: true when a page or sheet took it. */
    fun back(): Boolean {
        val entries = synchronized(backStack) { backStack.toList() }
        return entries.asReversed().any { it() }
    }

    @Composable
    override fun isActive(): Boolean = windowActive

    override val pairingScanner: (@Composable (Modifier, Boolean, (String) -> Unit) -> Unit)? = null
}
