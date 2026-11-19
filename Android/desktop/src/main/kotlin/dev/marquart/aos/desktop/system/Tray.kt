package dev.marquart.aos.desktop.system

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.window.ApplicationScope
import androidx.compose.ui.window.Notification
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.TrayState
import androidx.compose.ui.window.rememberTrayState
import dev.marquart.aos.R
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.desktop.AppIcon
import dev.marquart.aos.desktop.DesktopStrings
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import java.awt.SystemTray

/** The tray icon: the connection's state, Open, Quit; and the notifications on Windows (balloons/toasts). */
class TrayHandle(val state: TrayState?) {
    /** The system has a tray (Windows, KDE; GNOME only with an extension): closing the window keeps the app there. */
    val isSupported: Boolean get() = state != null

    /** The request the last notification was about (a click on it opens it). */
    @Volatile var lastRequest: String? = null

    fun notify(title: String, text: String) {
        state?.sendNotification(Notification(title, text, Notification.Type.Info))
    }
}

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@Composable
fun ApplicationScope.TrayHost(model: AppModel, open: () -> Unit, quit: () -> Unit): TrayHandle {
    val supported = remember { runCatching { SystemTray.isSupported() }.getOrDefault(false) }
    if (!supported) return remember { TrayHandle(null) }
    val trayState = rememberTrayState()
    val handle = remember { TrayHandle(trayState) }
    val macs by model.macs.collectAsState()
    val connectionState by remember { model.connection.flatMapLatest { it?.state ?: flowOf(null) } }.collectAsState(null)
    val questions by model.questions.collectAsState()
    val status = when {
        macs.isEmpty() -> DesktopStrings.text(R.string.desktop_tray_not_paired)
        connectionState is MacConnection.State.Connected -> DesktopStrings.text(R.string.desktop_tray_connected, macs.first().name)
        connectionState is MacConnection.State.Connecting -> DesktopStrings.text(R.string.desktop_tray_connecting, macs.first().name)
        else -> DesktopStrings.text(R.string.desktop_tray_unreachable, macs.first().name)
    }
    Tray(
        icon = AppIcon.painter(),
        state = trayState,
        tooltip = if (questions.isEmpty()) "aOS: $status" else "aOS: " + DesktopStrings.quantityText(R.plurals.desktop_tray_waiting, questions.size, questions.size),
        onAction = open,
        menu = {
            Item(status, enabled = false, onClick = {})
            Separator()
            Item(DesktopStrings.text(R.string.desktop_tray_open), onClick = open)
            Item(DesktopStrings.text(R.string.desktop_tray_quit), onClick = quit)
        },
    )
    return handle
}
