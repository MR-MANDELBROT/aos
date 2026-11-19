package dev.marquart.aos.store

import dev.marquart.aos.core.PairedMac
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// What the app keeps (iOS Sources/Services/Stores.swift): the paired Mac (nothing secret in it: names, addresses, the
// pinned public host key), the settings, and secrets (the Mac's screen login, later) encrypted with a Keystore key.
// All of it is excluded from backups (res/xml/data_extraction_rules.xml): it belongs to this phone's keys.

/** How the stores write their JSON (Android's DataStore, the desktop's files). */
val storeJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

/** The paired Macs, the active one first. */
interface MacStore {
    suspend fun load(): List<PairedMac>
    suspend fun save(macs: List<PairedMac>)
}

/** The app's settings (not secret). Fields a later version adds get defaults. */
@Serializable
data class AppSettings(
    /** How this phone calls itself towards the Mac (pairing, hello); null: the device's name. */
    val deviceName: String? = null,
    /** Keep the connection this long after the app leaves the foreground (iOS: 25 s). */
    val backgroundGraceSeconds: Int = 25,
    /** "Unlock to open aOS" (biometrics or the screen lock), at start and after `autoLockMinutes` in the background. */
    val requireUnlock: Boolean = false,
    /** Minutes in the background before the app locks again; 0 locks right away. */
    val autoLockMinutes: Int = 5,
    /** The app asked for the notification permission once (Android 13+); it doesn't ask again by itself. */
    val notificationsAsked: Boolean = false,
)

interface SettingsStore {
    val settings: Flow<AppSettings>
    suspend fun update(change: (AppSettings) -> AppSettings)
    suspend fun current(): AppSettings = settings.first()
}

/** Secrets, encrypted at rest. Values are bytes; the caller decides what goes in (never logged). */
interface SecretStore {
    suspend fun get(name: String): ByteArray?
    suspend fun put(name: String, value: ByteArray?)
}

/** In memory (tests). */
class MemoryMacStore(initial: List<PairedMac> = emptyList()) : MacStore {
    @Volatile var macs: List<PairedMac> = initial
    override suspend fun load() = macs
    override suspend fun save(macs: List<PairedMac>) {
        this.macs = macs
    }
}

class MemorySettingsStore(initial: AppSettings = AppSettings()) : SettingsStore {
    private val state = MutableStateFlow(initial)
    override val settings: Flow<AppSettings> = state
    override suspend fun update(change: (AppSettings) -> AppSettings) {
        state.value = change(state.value)
    }
}

class MemorySecretStore : SecretStore {
    private val values = HashMap<String, ByteArray>()
    override suspend fun get(name: String) = synchronized(values) { values[name] }
    override suspend fun put(name: String, value: ByteArray?) {
        synchronized(values) { if (value == null) values.remove(name) else values[name] = value }
    }
}
