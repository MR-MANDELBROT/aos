package dev.marquart.aos.desktop.system

import dev.marquart.aos.desktop.store.Prefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The desktop's own settings (desktop.json): confirmation, start at login, the window's close button. */
class DesktopSettings(private val prefs: Prefs) {
    private val _presence = MutableStateFlow(PresenceMethod.of(prefs.string("presence"))?.takeIf { it in PresenceMethod.choices }
        ?: PresenceMethod.default)
    private val _startAtLogin = MutableStateFlow(prefs.bool("startAtLogin", false))
    private val _keepRunning = MutableStateFlow(prefs.bool("keepRunning", true))
    private val _notifications = MutableStateFlow(prefs.bool("notifications", true))

    val presence: StateFlow<PresenceMethod> = _presence.asStateFlow()

    /** Start with the system's login (hidden in the tray). */
    val startAtLogin: StateFlow<Boolean> = _startAtLogin.asStateFlow()

    /** Closing the window keeps aOS in the tray (requests still arrive as notifications). */
    val keepRunning: StateFlow<Boolean> = _keepRunning.asStateFlow()

    /** Desktop notifications for requests while the window isn't in front. */
    val notifications: StateFlow<Boolean> = _notifications.asStateFlow()

    /** The first start: the app registers aos-pair:// and asks nothing. */
    var firstStartDone: Boolean
        get() = prefs.bool("firstStartDone", false)
        set(value) = prefs.set("firstStartDone", value)

    fun setPresence(method: PresenceMethod) {
        _presence.value = method
        prefs.set("presence", method.raw)
    }

    fun setStartAtLogin(on: Boolean) {
        _startAtLogin.value = on
        prefs.set("startAtLogin", on)
    }

    fun setKeepRunning(on: Boolean) {
        _keepRunning.value = on
        prefs.set("keepRunning", on)
    }

    fun setNotifications(on: Boolean) {
        _notifications.value = on
        prefs.set("notifications", on)
    }
}
