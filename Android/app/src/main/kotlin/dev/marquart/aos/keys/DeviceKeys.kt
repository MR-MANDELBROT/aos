package dev.marquart.aos.keys

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.P256Signer
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.core.SoftwareP256Signer
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

// The phone's two keys (Docs/COMPANION.md, "Keys"): the SSH key it logs in to the Mac with, and a second key of the same
// kind it signs every companion request with (the Mac got its public half at pairing). Both are P-256 keys in the
// Android Keystore (StrongBox where the phone has one, else the TEE), created on the phone and never leaving it: the
// app only ever holds handles, signs with java.security.Signature "SHA256withECDSA", and the SSH library gets only a
// signing function (ssh/KeyAgent.kt), never a private key.

/** Where a key lives. */
enum class KeyStorage {
    /** A separate secure chip (Titan M and the like). */
    STRONG_BOX,

    /** The phone's trusted execution environment. */
    TEE,

    /** The Keystore without secure hardware (some emulators). */
    KEYSTORE_SOFTWARE,

    /** In this process's memory only (tests, and the fallback when the Keystore fails). */
    MEMORY,
}

/** One of the phone's P-256 keys: signs, and knows its public key in the forms the Mac wants. */
class DeviceKey(val signer: P256Signer, val storage: KeyStorage) {
    /** X9.63 (65 bytes): the signing key the Mac keeps (`sign` in the pairing request). */
    val publicKeyX963: ByteArray get() = signer.publicKeyX963

    /** `ecdsa-sha2-nistp256 AAAA...`: what the Mac puts into `authorized_keys`. */
    val openSSHPublicKey: String = SSHKeyFormat.openSSHP256(signer.publicKeyX963)

    val fingerprint: String = SSHKeyFormat.fingerprint(openSSHPublicKey) ?: ""

    /** What aOS on the Mac calls this phone when this is its SSH key; signed requests name it. */
    val phoneId: String = SSHKeyFormat.phoneId(openSSHPublicKey) ?: ""

    /** The public key as JCA has it (the SSH library offers it to the server). */
    val javaPublicKey: PublicKey = P256.publicKey(signer.publicKeyX963)!!

    fun sign(message: ByteArray): ByteArray = signer.sign(message)
}

/** The phone's keys, created on first use. Android: `AndroidKeystoreKeys`; tests and fallback: `MemoryKeys`. */
interface KeyProvider {
    /** The SSH key (logs in to the Mac). */
    fun sshKey(): DeviceKey

    /** The key every companion request is signed with. */
    fun companionKey(): DeviceKey

    /** Forgets both keys (new ones next time); every Mac must then be paired again. */
    fun reset()
}

/** Keys in memory only: the JVM tests, and the fallback when the Keystore can't make a key. */
class MemoryKeys(
    private val ssh: SoftwareP256Signer = SoftwareP256Signer.generate(),
    private val companion: SoftwareP256Signer = SoftwareP256Signer.generate(),
) : KeyProvider {
    private var sshKey = DeviceKey(ssh, KeyStorage.MEMORY)
    private var companionKey = DeviceKey(companion, KeyStorage.MEMORY)
    override fun sshKey() = sshKey
    override fun companionKey() = companionKey
    override fun reset() {
        sshKey = DeviceKey(SoftwareP256Signer.generate(), KeyStorage.MEMORY)
        companionKey = DeviceKey(SoftwareP256Signer.generate(), KeyStorage.MEMORY)
    }
}

/**
 * The keys in the Android Keystore: non-exportable P-256 signing keys, StrongBox if available, else the TEE. Usable
 * without the person's authentication (the app reconnects and signs its heartbeat in the background, as on the iPhone);
 * approvals ask for the person's biometrics in the app before they are signed.
 */
class AndroidKeystoreKeys(private val strongBox: Boolean = true) : KeyProvider {
    private val keyStore: KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
    private val lock = Any()
    private var cache = HashMap<String, DeviceKey>()

    override fun sshKey(): DeviceKey = key(SSH_ALIAS)
    override fun companionKey(): DeviceKey = key(COMPANION_ALIAS)

    override fun reset() = synchronized(lock) {
        for (alias in listOf(SSH_ALIAS, COMPANION_ALIAS)) if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        cache.clear()
    }

    private fun key(alias: String): DeviceKey = synchronized(lock) {
        cache[alias]?.let { return it }
        if (!keyStore.containsAlias(alias)) create(alias)
        val entry = keyStore.getEntry(alias, null) as KeyStore.PrivateKeyEntry
        val signer = KeystoreSigner(entry.privateKey, P256.x963(entry.certificate.publicKey))
        DeviceKey(signer, storageOf(entry.privateKey)).also { cache[alias] = it }
    }

    private fun create(alias: String) {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setIsStrongBoxBacked(strongBox)
            .build()
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generator.initialize(spec(true))
                generator.generateKeyPair()
                return
            } catch (_: StrongBoxUnavailableException) {
                // No StrongBox on this phone: the TEE.
            } catch (_: java.security.ProviderException) {
                // Some phones report StrongBox but fail to make P-256 keys in it.
            }
        }
        generator.initialize(spec(false))
        generator.generateKeyPair()
    }

    private fun storageOf(key: PrivateKey): KeyStorage = try {
        val info = KeyFactory.getInstance(key.algorithm, PROVIDER).getKeySpec(key, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> KeyStorage.STRONG_BOX
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> KeyStorage.TEE
                else -> KeyStorage.KEYSTORE_SOFTWARE
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) KeyStorage.TEE else KeyStorage.KEYSTORE_SOFTWARE
        }
    } catch (_: Exception) {
        KeyStorage.KEYSTORE_SOFTWARE
    }

    companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val SSH_ALIAS = "dev.marquart.aos.ssh-p256"
        const val COMPANION_ALIAS = "dev.marquart.aos.companion-p256"
    }
}

/** Signs with a Keystore key: the private half stays in the Keystore, this holds a handle. */
class KeystoreSigner(private val privateKey: PrivateKey, override val publicKeyX963: ByteArray) : P256Signer {
    override fun sign(message: ByteArray): ByteArray {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(privateKey)
        signature.update(message)
        return P256.derToRaw(signature.sign())
    }
}

/** The Keystore's keys, or keys in memory where it fails (an emulator without a working Keystore). */
class KeystoreOrMemoryKeys : KeyProvider {
    private val keystore: KeyProvider? = try {
        AndroidKeystoreKeys().also { it.sshKey(); it.companionKey() }
    } catch (_: Exception) {
        null
    }
    private val fallback by lazy { MemoryKeys() }
    private val active: KeyProvider get() = keystore ?: fallback

    override fun sshKey() = active.sshKey()
    override fun companionKey() = active.companionKey()
    override fun reset() = active.reset()

    /** The Keystore didn't work: the keys live only as long as the app runs. */
    val isFallback: Boolean get() = keystore == null
}
