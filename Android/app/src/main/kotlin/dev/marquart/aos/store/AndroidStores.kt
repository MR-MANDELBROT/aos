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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// The Android stores (DataStore, the Keystore); the interfaces and the in-memory ones are in shared/store/Stores.kt.

private val json = storeJson

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

