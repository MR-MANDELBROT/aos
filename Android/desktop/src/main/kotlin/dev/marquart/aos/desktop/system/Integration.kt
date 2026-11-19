package dev.marquart.aos.desktop.system

import com.sun.jna.platform.win32.Advapi32Util
import com.sun.jna.platform.win32.WinReg
import dev.marquart.aos.desktop.Os
import java.io.File

/**
 * How the app starts again (start at login, the aos-pair:// handler): the packages' launchers say so with
 * -Daos.launcher. Linux: the path of the `aos` script. Windows: "windows", and the command is this process's own
 * (runtime\bin\javaw.exe, the Go library's path, -jar aOS.jar), so no console window opens. Null when started from
 * Gradle (development): then nothing is registered.
 */
object Launcher {
    val command: List<String>? get() {
        val launcher = System.getProperty("aos.launcher") ?: return null
        if (launcher != "windows") return listOf(launcher)
        val exe = ProcessHandle.current().info().command().orElse(null) ?: return null
        val javaw = exe.replace(Regex("java\\.exe$", RegexOption.IGNORE_CASE), "javaw.exe")
        val jar = runCatching { java.io.File(Launcher::class.java.protectionDomain.codeSource.location.toURI()).path }.getOrNull() ?: return null
        return buildList {
            add(javaw)
            add("-Daos.launcher=windows")
            System.getProperty("aosgo.library")?.let { add("-Daosgo.library=$it") }
            add("-jar")
            add(jar)
        }
    }

    /** The command as one line for the registry, each part quoted. */
    fun line(vararg extra: String): String? = command?.let { (it + extra).joinToString(" ") { part -> "\"$part\"" } }
}

/** Start at login: Windows' Run key (HKCU), Linux's XDG autostart (~/.config/autostart/aos.desktop). */
object Autostart {
    private const val RUN = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private val linuxFile: File get() = File(System.getenv("XDG_CONFIG_HOME")?.takeIf { it.isNotBlank() }
        ?: (System.getProperty("user.home") + "/.config"), "autostart/aos.desktop")

    val isSupported: Boolean get() = (Os.isWindows || Os.isLinux) && Launcher.command != null

    fun set(on: Boolean) {
        val command = Launcher.command ?: return
        when {
            Os.isWindows -> if (on) {
                Advapi32Util.registrySetStringValue(WinReg.HKEY_CURRENT_USER, RUN, "aOS", Launcher.line("--background")!!)
            } else if (Advapi32Util.registryValueExists(WinReg.HKEY_CURRENT_USER, RUN, "aOS")) {
                Advapi32Util.registryDeleteValue(WinReg.HKEY_CURRENT_USER, RUN, "aOS")
            }
            Os.isLinux -> if (on) {
                linuxFile.parentFile.mkdirs()
                linuxFile.writeText(desktopEntry(command[0], "--background", scheme = false))
            } else {
                linuxFile.delete()
            }
        }
    }
}

/**
 * aos-pair:// opens this app (the pairing link from the Mac). The Windows installer and the Linux package register it
 * too; the app registers it for the current user at start as well, so the zip and the tar.gz work the same:
 * Windows HKCU\Software\Classes\aos-pair, Linux ~/.local/share/applications/aos.desktop with
 * MimeType=x-scheme-handler/aos-pair (and xdg-mime as the default for it).
 */
object UrlScheme {
    fun register() {
        val command = Launcher.command ?: return
        runCatching {
            when {
                Os.isWindows -> {
                    val base = "Software\\Classes\\aos-pair"
                    val hk = WinReg.HKEY_CURRENT_USER
                    Advapi32Util.registryCreateKey(hk, "$base\\shell\\open\\command")
                    Advapi32Util.registrySetStringValue(hk, base, "", "URL:aOS pairing link")
                    Advapi32Util.registrySetStringValue(hk, base, "URL Protocol", "")
                    Advapi32Util.registrySetStringValue(hk, "$base\\shell\\open\\command", "", Launcher.line("%1")!!)
                }
                Os.isLinux -> {
                    val apps = File(System.getenv("XDG_DATA_HOME")?.takeIf { it.isNotBlank() }
                        ?: (System.getProperty("user.home") + "/.local/share"), "applications")
                    // The package's system-wide entry (/usr/share/applications/aos.desktop) is enough when it is there.
                    if (File("/usr/share/applications/aos.desktop").isFile) return
                    apps.mkdirs()
                    File(apps, "aos.desktop").writeText(desktopEntry(command[0], "%u", scheme = true))
                    if (Os.commandExists("xdg-mime")) ProcessBuilder("xdg-mime", "default", "aos.desktop", "x-scheme-handler/aos-pair").start()
                    if (Os.commandExists("update-desktop-database")) ProcessBuilder("update-desktop-database", apps.path).start()
                }
            }
        }
    }
}

internal fun desktopEntry(exec: String, argument: String, scheme: Boolean): String = buildString {
    appendLine("[Desktop Entry]")
    appendLine("Type=Application")
    appendLine("Name=aOS")
    appendLine("Comment=Approve sign-ins, open the terminal and the screen of your Mac")
    appendLine("Comment[de]=Anmeldungen freigeben, Terminal und Bildschirm deines Macs öffnen")
    appendLine("Exec=\"$exec\" $argument")
    val icon = File(File(exec).parentFile, "aos.png")
    appendLine("Icon=${if (icon.isFile) icon.path else "aos"}")
    appendLine("Categories=Network;RemoteAccess;")
    if (scheme) appendLine("MimeType=x-scheme-handler/aos-pair;")
    appendLine("StartupWMClass=aOS")
    if (!scheme) appendLine("X-GNOME-Autostart-enabled=true")
}
