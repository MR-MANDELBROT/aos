package dev.marquart.aos.desktop.keys

import dev.marquart.aos.core.P256
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.desktop.native.CngProvider
import dev.marquart.aos.desktop.native.LibSecret
import dev.marquart.aos.desktop.store.Sealer
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.keys.KeyProvider
import dev.marquart.aos.keys.KeyStorage
import dev.marquart.aos.keys.MemoryKeys
import java.io.File
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// The computer's two keys (Docs/COMPANION.md, "Keys"), like the phone's: the SSH key and the companion signing key,
// both P-256. Windows: non-exportable CNG keys, in the TPM where there is one (`CngKeys`). Linux (and macOS in
// development): a key file per key under the app's folder, 0600, encrypted with a key kept in the Secret Service when
// there is one (`FileKeys`). MINA only ever gets a signing function (shared ssh/KeyAgent.kt).

/** Windows: CNG keys, the TPM first, the Software Key Storage Provider where the TPM can't make a P-256 key. */
class CngKeys : KeyProvider {
    private val lock = Any()
    private val cache = HashMap<String, DeviceKey>()

    private val tpm: CngProvider? by lazy { runCatching { CngProvider.open(CngProvider.PLATFORM) }.getOrNull() }
    private val software: CngProvider by lazy { CngProvider.open(CngProvider.SOFTWARE) }

    override fun sshKey() = key(SSH)
    override fun companionKey() = key(COMPANION)

    override fun reset() = synchronized(lock) {
        for (name in listOf(SSH, COMPANION)) {
            tpm?.delete(name)
            software.delete(name)
        }
        cache.clear()
    }

    private fun key(name: String): DeviceKey = synchronized(lock) {
        cache[name]?.let { return it }
        // A key that exists stays where it is (one in the software provider was made when the TPM didn't work).
        val key = tpm?.let { p -> runCatching { p.openExisting(name) }.getOrNull() }?.let { DeviceKey(it, KeyStorage.TPM) }
            ?: software.openExisting(name)?.let { DeviceKey(it, KeyStorage.WINDOWS_SOFTWARE) }
            ?: tpm?.let { p -> runCatching { DeviceKey(p.create(name), KeyStorage.TPM) }.getOrNull() }
            ?: DeviceKey(software.create(name), KeyStorage.WINDOWS_SOFTWARE)
        cache[name] = key
        key
    }

    companion object {
        const val SSH = "dev.marquart.aos.ssh-p256"
        const val COMPANION = "dev.marquart.aos.companion-p256"
    }
}

/**
 * Key files (Linux; macOS in development): `keys/<name>.key` in the app's folder, 0600, holding the key's 32-byte
 * scalar, AES-256-GCM encrypted with a key from `sealer` (the Secret Service) when there is one, else plain (the
 * file's permissions protect it; Settings says so).
 */
class FileKeys(private val dir: File = File(Os.configDir, "keys"), private val sealer: Sealer) : KeyProvider {
    private val lock = Any()
    private val cache = HashMap<String, DeviceKey>()

    override fun sshKey() = key("ssh")
    override fun companionKey() = key("companion")

    override fun reset() = synchronized(lock) {
        listOf("ssh", "companion").forEach { File(dir, "$it.key").delete() }
        cache.clear()
    }

    private fun key(name: String): DeviceKey = synchronized(lock) {
        cache[name]?.let { return it }
        val file = File(dir, "$name.key")
        val stored = if (file.isFile) runCatching { KeyFile.read(file.readBytes(), name, sealer) }.getOrNull() else null
        val (scalar, encrypted) = stored ?: run {
            val pair = P256.generate()
            val scalar = P256.fixed32((pair.private as ECPrivateKey).s)
            Os.privateDir(dir)
            Os.writePrivate(file, KeyFile.write(scalar, name, sealer))
            scalar to (sealer.kind != Sealer.Kind.NONE)
        }
        val key = DeviceKey(SoftwareP256Signer.fromScalar(scalar), if (encrypted) KeyStorage.FILE_ENCRYPTED else KeyStorage.FILE)
        cache[name] = key
        key
    }
}

/** The key file's format: "AOSK" 1, a flag (0 plain, 1 sealed), then the scalar (plain) or the sealer's output. */
object KeyFile {
    private val magic = byteArrayOf('A'.code.toByte(), 'O'.code.toByte(), 'S'.code.toByte(), 'K'.code.toByte(), 1)

    fun write(scalar: ByteArray, name: String, sealer: Sealer): ByteArray {
        val sealed = sealer.kind != Sealer.Kind.NONE
        return magic + byteArrayOf(if (sealed) 1 else 0) + (if (sealed) sealer.seal(scalar, "key:$name") else scalar)
    }

    /** The scalar and whether it was encrypted. Throws when the file is broken or can't be opened. */
    fun read(bytes: ByteArray, name: String, sealer: Sealer): Pair<ByteArray, Boolean> {
        require(bytes.size > magic.size + 1 && bytes.copyOfRange(0, magic.size).contentEquals(magic)) { "not a key file" }
        val body = bytes.copyOfRange(magic.size + 1, bytes.size)
        return when (bytes[magic.size].toInt()) {
            0 -> body.also { require(it.size == 32) } to false
            1 -> sealer.open(body, "key:$name").also { require(it.size == 32) } to true
            else -> throw IllegalArgumentException("unknown key file")
        }
    }
}

/** AES-256-GCM with a key kept in the Secret Service (created there on first use). `name` is the associated data. */
class SecretServiceSealer private constructor(private val key: ByteArray) : Sealer {
    override val kind = Sealer.Kind.SECRET_SERVICE

    override fun seal(value: ByteArray, name: String): ByteArray {
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(name.toByteArray())
        return nonce + cipher.doFinal(value)
    }

    override fun open(sealed: ByteArray, name: String): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 0, 12))
        cipher.updateAAD(name.toByteArray())
        return cipher.doFinal(sealed, 12, sealed.size - 12)
    }

    companion object {
        private const val NAME = "app-key"

        /** The sealer with the Secret Service's key, or null when there is no Secret Service. */
        fun open(): SecretServiceSealer? {
            if (!LibSecret.isAvailable) return null
            return runCatching {
                val existing = LibSecret.lookup(NAME)
                val key = existing?.let { java.util.Base64.getDecoder().decode(it) } ?: ByteArray(32).also {
                    SecureRandom().nextBytes(it)
                    LibSecret.store(NAME, "aOS (key file encryption)", java.util.Base64.getEncoder().encodeToString(it))
                }
                require(key.size == 32)
                SecretServiceSealer(key)
            }.getOrNull()
        }
    }
}

/** The keys this computer uses; memory where the platform's store fails (then they last as long as the app runs). */
object DesktopKeys {
    fun create(sealer: Sealer): KeyProvider = when {
        Os.isWindows -> runCatching { CngKeys().also { it.sshKey(); it.companionKey() } }.getOrElse { MemoryKeys() }
        else -> runCatching { FileKeys(sealer = sealer).also { it.sshKey(); it.companionKey() } }.getOrElse { MemoryKeys() }
    }
}
