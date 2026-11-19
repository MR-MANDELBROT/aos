package dev.marquart.aos.store

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.PairedMac
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// What the app keeps (iOS Sources/Services/Stores.swift): the paired Mac (nothing secret in it: names, addresses, the
// pinned public host key), the settings, and secrets (the Mac's screen login, later) encrypted with a Keystore key.
// All of it is excluded from backups (res/xml/data_extraction_rules.xml): it belongs to this phone's keys.

private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

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

private val Context.aosStore: DataStore<Preferences> by preferencesDataStore(name = "aos")
private val Context.secretStore: DataStore<Preferences> by preferencesDataStore(name = "aos-secrets")

/** The paired Macs in DataStore, as JSON. */
class DataStoreMacStore(private val context: Context) : MacStore {
    private val key = stringPreferencesKey("macs")

    override suspend fun load(): List<PairedMac> {
        val text = context.aosStore.data.first()[key] ?: return emptyList()
        return runCatching { json.decodeFromString(ListSerializer(PairedMac.serializer()), text) }.getOrDefault(emptyList())
    }

    override suspend fun save(macs: List<PairedMac>) {
        val text = json.encodeToString(ListSerializer(PairedMac.serializer()), macs)
        context.aosStore.edit { it[key] = text }
    }
}

class DataStoreSettingsStore(private val context: Context) : SettingsStore {
    private val key = stringPreferencesKey("settings")

    override val settings: Flow<AppSettings> = context.aosStore.data.map { prefs ->
        prefs[key]?.let { runCatching { json.decodeFromString(AppSettings.serializer(), it) }.getOrNull() } ?: AppSettings()
    }

    override suspend fun update(change: (AppSettings) -> AppSettings) {
        context.aosStore.edit { prefs ->
            val current = prefs[key]?.let { runCatching { json.decodeFromString(AppSettings.serializer(), it) }.getOrNull() } ?: AppSettings()
            prefs[key] = json.encodeToString(AppSettings.serializer(), change(current))
        }
    }
}

/**
 * Secrets in their own DataStore file, each value AES-256-GCM encrypted with a key in the Android Keystore (never
 * exported; it can't be read off the phone). Stored as base64 of `nonce || ciphertext || tag`.
 */
class KeystoreSecretStore(private val context: Context) : SecretStore {
    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return generator.generateKey()
    }

    override suspend fun get(name: String): ByteArray? {
        val stored = context.secretStore.data.first()[stringPreferencesKey(name)] ?: return null
        val data = Bytes.base64Decode(stored) ?: return null
        if (data.size < 12 + 16) return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 0, 12))
            cipher.updateAAD(Bytes.utf8(name))
            cipher.doFinal(data, 12, data.size - 12)
        }.getOrNull()
    }

    override suspend fun put(name: String, value: ByteArray?) {
        val prefKey = stringPreferencesKey(name)
        if (value == null) {
            context.secretStore.edit { it.remove(prefKey) }
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(Bytes.utf8(name))
        val sealed = cipher.iv + cipher.doFinal(value)
        context.secretStore.edit { it[prefKey] = Bytes.base64(sealed) }
    }

    private companion object {
        const val ALIAS = "dev.marquart.aos.secrets"
    }
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
