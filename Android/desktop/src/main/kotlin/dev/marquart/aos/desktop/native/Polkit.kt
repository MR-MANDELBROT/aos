package dev.marquart.aos.desktop.native

import dev.marquart.aos.desktop.Os
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Linux: asks the desktop's polkit agent (the system's own authentication dialog). With the package installed, the
 * action dev.marquart.aos.confirm asks for the person's own password (auth_self, desktop/packaging/linux/dev.marquart.aos.confirm.policy);
 * without it org.freedesktop.policykit.exec, which asks an administrator's password (on most desktops the person's
 * own, if they are one).
 */
object Polkit {
    enum class Result { AUTHORIZED, DISMISSED, DENIED, UNAVAILABLE }

    const val ACTION = "dev.marquart.aos.confirm"
    private const val FALLBACK = "org.freedesktop.policykit.exec"

    val isAvailable: Boolean get() = Os.isLinux && Os.commandExists("pkcheck")

    val action: String get() = if (File("/usr/share/polkit-1/actions/$ACTION.policy").isFile) ACTION else FALLBACK

    /** Blocks until the person answered. */
    fun authorize(): Result {
        if (!isAvailable) return Result.UNAVAILABLE
        val process = ProcessBuilder("pkcheck", "--action-id", action, "--process", processSpec(), "--allow-user-interaction")
            .redirectErrorStream(true).start()
        process.inputStream.readBytes()
        if (!process.waitFor(5, TimeUnit.MINUTES)) {
            process.destroy()
            return Result.DISMISSED
        }
        return when (process.exitValue()) {
            0 -> Result.AUTHORIZED
            2 -> Result.DISMISSED
            1 -> Result.DENIED
            else -> Result.UNAVAILABLE
        }
    }

    /** "pid,start-time,uid" (pkcheck's race-free form) from /proc; just the pid if that can't be read. */
    private fun processSpec(): String {
        val pid = ProcessHandle.current().pid()
        return runCatching {
            val stat = File("/proc/$pid/stat").readText()
            val start = stat.substringAfterLast(')').trim().split(' ')[19]
            val uid = File("/proc/$pid/status").readLines().first { it.startsWith("Uid:") }.split(Regex("\\s+"))[1]
            "$pid,$start,$uid"
        }.getOrDefault(pid.toString())
    }
}
