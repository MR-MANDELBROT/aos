package dev.marquart.aos.desktop.system

import com.sun.jna.Native
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.desktop.native.Pam
import dev.marquart.aos.desktop.native.Polkit
import dev.marquart.aos.desktop.native.WinHello
import dev.marquart.aos.ui.platform.PresenceOutcome
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.awt.Window

/** How the person confirms an approval or a sign-in on this computer (Settings > This computer). */
enum class PresenceMethod(val raw: String) {
    /** Windows Hello; on Linux the desktop's polkit dialog. */
    SYSTEM("system"),

    /** The account's password, in the app (Linux, through PAM). */
    PASSWORD("password"),

    /** No confirmation: approvals go out with a click (the person chose it). */
    OFF("off");

    companion object {
        fun of(raw: String?): PresenceMethod? = entries.firstOrNull { it.raw == raw }

        /** What a fresh install uses: Windows Hello, polkit where there is pkcheck, else the password, macOS off. */
        val default: PresenceMethod get() = when {
            Os.isWindows -> SYSTEM
            Os.isLinux -> if (Polkit.isAvailable) SYSTEM else PASSWORD
            else -> OFF
        }

        /** The choices this computer offers. */
        val choices: List<PresenceMethod> get() = when {
            Os.isWindows -> listOf(SYSTEM, OFF)
            Os.isLinux -> listOf(SYSTEM, PASSWORD, OFF)
            else -> listOf(OFF)
        }
    }
}

/** Asks the person to confirm it is them, the way `method` says. `askPassword` shows the app's password dialog. */
class Presence(
    private val method: () -> PresenceMethod,
    private val window: () -> Window?,
    private val askPassword: suspend (reason: String, wrong: Boolean) -> CharArray?,
) {
    suspend fun confirm(reason: String): PresenceOutcome = when (method()) {
        PresenceMethod.OFF -> PresenceOutcome.SUCCESS
        PresenceMethod.SYSTEM -> when {
            Os.isWindows -> withContext(Dispatchers.IO) {
                val hwnd = window()?.let { runCatching { Native.getWindowPointer(it) }.getOrNull() }
                when (runCatching { WinHello.verify(hwnd, reason) }.getOrDefault(WinHello.Result.FAILED)) {
                    WinHello.Result.VERIFIED -> PresenceOutcome.SUCCESS
                    WinHello.Result.CANCELED -> PresenceOutcome.CANCELLED
                    WinHello.Result.NOT_AVAILABLE -> PresenceOutcome.UNAVAILABLE
                    WinHello.Result.FAILED -> PresenceOutcome.FAILED
                }
            }
            Os.isLinux -> withContext(Dispatchers.IO) {
                when (Polkit.authorize()) {
                    Polkit.Result.AUTHORIZED -> PresenceOutcome.SUCCESS
                    Polkit.Result.DISMISSED -> PresenceOutcome.CANCELLED
                    Polkit.Result.DENIED -> PresenceOutcome.FAILED
                    Polkit.Result.UNAVAILABLE -> PresenceOutcome.UNAVAILABLE
                }
            }
            else -> PresenceOutcome.UNAVAILABLE
        }
        PresenceMethod.PASSWORD -> password(reason)
    }

    private suspend fun password(reason: String): PresenceOutcome {
        if (!Pam.isAvailable) return PresenceOutcome.UNAVAILABLE
        val user = System.getProperty("user.name")
        var wrong = false
        repeat(3) {
            val entered = askPassword(reason, wrong) ?: return PresenceOutcome.CANCELLED
            val ok = withContext(Dispatchers.IO) { Pam.check(user, entered) }
            entered.fill(' ')
            if (ok) return PresenceOutcome.SUCCESS
            wrong = true
        }
        return PresenceOutcome.FAILED
    }
}
