package dev.marquart.aos.desktop.store

import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.store.AppSettings
import dev.marquart.aos.store.MacStore
import dev.marquart.aos.store.SecretStore
import dev.marquart.aos.store.SettingsStore
import dev.marquart.aos.store.storeJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File

// What the desktop app keeps, as JSON files in its folder (Os.configDir, 0600): the paired Macs (nothing secret: names,
// addresses, the pinned host key), the settings, small preferences of the terminal, the screen and the desktop. Secrets
// go through `DesktopSecretStore` (DPAPI on Windows, the Secret Service on Linux).

class FileMacStore(private val file: File = File(Os.configDir, "macs.json")) : MacStore {
    override suspend fun load(): List<PairedMac> = withContext(Dispatchers.IO) {
        if (!file.isFile) return@withContext emptyList()
        runCatching { storeJson.decodeFromString(ListSerializer(PairedMac.serializer()), file.readText()) }.getOrDefault(emptyList())
    }

    override suspend fun save(macs: List<PairedMac>) = withContext(Dispatchers.IO) {
        Os.writePrivate(file, storeJson.encodeToString(ListSerializer(PairedMac.serializer()), macs).toByteArray())
    }
}

class FileSettingsStore(private val file: File = File(Os.configDir, "settings.json")) : SettingsStore {
    private val state = MutableStateFlow(read())
    private val lock = Mutex()
    override val settings: Flow<AppSettings> = state

    private fun read(): AppSettings = if (!file.isFile) AppSettings()
        else runCatching { storeJson.decodeFromString(AppSettings.serializer(), file.readText()) }.getOrDefault(AppSettings())

    override suspend fun update(change: (AppSettings) -> AppSettings) = lock.withLock {
        val next = change(state.value)
        withContext(Dispatchers.IO) { Os.writePrivate(file, storeJson.encodeToString(AppSettings.serializer(), next).toByteArray()) }
        state.value = next
    }
}

/** Small preferences by name (the terminal's font size, the screen's choices, the desktop's own settings). */
class Prefs(private val file: File) {
    private val values: MutableMap<String, String> = if (file.isFile) {
        runCatching { storeJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), file.readText()).toMutableMap() }
            .getOrDefault(HashMap())
    } else HashMap()

    @Synchronized fun string(name: String): String? = values[name]
    fun int(name: String, default: Int): Int = string(name)?.toIntOrNull() ?: default
    fun bool(name: String, default: Boolean): Boolean = string(name)?.toBooleanStrictOrNull() ?: default

    @Synchronized fun all(): Map<String, String> = HashMap(values)

    @Synchronized fun set(name: String, value: Any?) {
        if (value == null) values.remove(name) else values[name] = value.toString()
        Os.writePrivate(file, storeJson.encodeToString(MapSerializer(String.serializer(), String.serializer()), values).toByteArray())
    }

    companion object {
        fun named(name: String) = Prefs(File(Os.configDir, "$name.json"))
    }
}

/**
 * Secrets (the Mac's screen login), each value sealed by `Sealer` (DPAPI on Windows, a key from the Secret Service on
 * Linux; on a Linux without one, and on macOS in development, a 0600 file without encryption) and kept in
 * secrets.json (base64).
 */
class DesktopSecretStore(private val sealer: Sealer, private val file: File = File(Os.configDir, "secrets.json")) : SecretStore {
    private val lock = Mutex()

    private fun read(): MutableMap<String, String> = if (!file.isFile) HashMap() else runCatching {
        storeJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), file.readText()).toMutableMap()
    }.getOrDefault(HashMap())

    override suspend fun get(name: String): ByteArray? = lock.withLock {
        withContext(Dispatchers.IO) {
            val stored = read()[name] ?: return@withContext null
            runCatching { sealer.open(java.util.Base64.getDecoder().decode(stored), name) }.getOrNull()
        }
    }

    override suspend fun put(name: String, value: ByteArray?) = lock.withLock {
        withContext(Dispatchers.IO) {
            val all = read()
            if (value == null) all.remove(name) else all[name] = java.util.Base64.getEncoder().encodeToString(sealer.seal(value, name))
            Os.writePrivate(file, storeJson.encodeToString(MapSerializer(String.serializer(), String.serializer()), all).toByteArray())
        }
    }
}

/** Encrypts small values for this user (`name` is bound into the seal where the method allows). */
interface Sealer {
    /** How the values are protected (Settings shows it). */
    val kind: Kind
    fun seal(value: ByteArray, name: String): ByteArray
    fun open(sealed: ByteArray, name: String): ByteArray

    enum class Kind { DPAPI, SECRET_SERVICE, NONE }
}

/** No encryption: the file's permissions (0600) are the protection. */
object PlainSealer : Sealer {
    override val kind = Sealer.Kind.NONE
    override fun seal(value: ByteArray, name: String) = value
    override fun open(sealed: ByteArray, name: String) = sealed
}
