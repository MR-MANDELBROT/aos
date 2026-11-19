package dev.marquart.aos.desktop

import dev.marquart.aos.ui.platform.PlatformKind
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions

/** The system the app runs on, and where it keeps its files. */
object Os {
    private val name = System.getProperty("os.name").lowercase()

    val kind: PlatformKind = when {
        name.startsWith("windows") -> PlatformKind.WINDOWS
        name.startsWith("mac") -> PlatformKind.MAC
        else -> PlatformKind.LINUX
    }
    val isWindows get() = kind == PlatformKind.WINDOWS
    val isLinux get() = kind == PlatformKind.LINUX
    val isMac get() = kind == PlatformKind.MAC

    /**
     * The app's own folder: Windows %APPDATA%\aOS, Linux $XDG_CONFIG_HOME/aos (~/.config/aos), macOS (development)
     * ~/Library/Application Support/aOS. `AOS_HOME` puts it elsewhere (tests, the live check, the screenshots).
     */
    val configDir: File by lazy {
        val override = System.getenv("AOS_HOME") ?: System.getProperty("aos.home")
        val dir = when {
            override != null -> File(override)
            isWindows -> File(System.getenv("APPDATA") ?: (System.getProperty("user.home") + "\\AppData\\Roaming"), "aOS")
            isMac -> File(System.getProperty("user.home"), "Library/Application Support/aOS")
            else -> File(System.getenv("XDG_CONFIG_HOME")?.takeIf { it.isNotBlank() } ?: (System.getProperty("user.home") + "/.config"), "aos")
        }
        privateDir(dir)
    }

    /** A folder only this user can read (0700 where there are POSIX permissions; Windows: the profile's ACLs). */
    fun privateDir(dir: File): File {
        dir.mkdirs()
        if (!isWindows) runCatching { Files.setPosixFilePermissions(dir.toPath(), PosixFilePermissions.fromString("rwx------")) }
        return dir
    }

    /** Writes a file only this user can read (0600), atomically (a temporary file renamed over it). */
    fun writePrivate(file: File, bytes: ByteArray) {
        file.parentFile?.let(::privateDir)
        val tmp = File(file.parentFile, "." + file.name + ".tmp")
        tmp.delete()
        if (!isWindows) {
            Files.createFile(tmp.toPath(), PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
        }
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) {
            file.delete()
            if (!tmp.renameTo(file)) {
                file.writeBytes(bytes)
                tmp.delete()
            }
        }
        if (!isWindows) runCatching { Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------")) }
    }

    /** The computer's name for pairing ("Max's PC"): the host name without its domain. */
    fun computerName(): String {
        val env = System.getenv("COMPUTERNAME") ?: System.getenv("HOSTNAME")
        val host = env ?: runCatching { java.net.InetAddress.getLocalHost().hostName }.getOrNull() ?: "Computer"
        return host.substringBefore('.').ifBlank { "Computer" }
    }

    fun commandExists(command: String): Boolean = System.getenv("PATH").orEmpty().split(File.pathSeparator)
        .any { File(it, command).canExecute() }
}
