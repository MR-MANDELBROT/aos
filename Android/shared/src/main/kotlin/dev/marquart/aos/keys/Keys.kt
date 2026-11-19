package dev.marquart.aos.keys

import dev.marquart.aos.core.P256
import dev.marquart.aos.core.P256Signer
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.core.SoftwareP256Signer
import java.security.PublicKey

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

    /** Windows: a non-exportable key in the TPM (CNG's Microsoft Platform Crypto Provider). */
    TPM,

    /** Windows: a non-exportable key in CNG's Microsoft Software Key Storage Provider (no TPM usable). */
    WINDOWS_SOFTWARE,

    /** Linux: a key file (0600) encrypted with a key kept in the Secret Service (GNOME Keyring, KWallet). */
    FILE_ENCRYPTED,

    /** A key file readable only by this user (0600), not encrypted: no Secret Service on this computer. */
    FILE,
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

/** The phone's keys, created on first use. Android: `AndroidKeystoreKeys`; desktop: `DesktopKeys` (CNG on Windows, a
 *  key file on Linux); tests and fallback: `MemoryKeys`. */
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

