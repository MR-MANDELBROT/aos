package dev.marquart.aos.desktop.native

import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.WString
import com.sun.jna.ptr.IntByReference
import com.sun.jna.ptr.LongByReference
import dev.marquart.aos.core.P256Signer
import java.security.MessageDigest

// Windows CNG (ncrypt.dll) through JNA: non-exportable P-256 keys in the TPM (Microsoft Platform Crypto Provider) or,
// where there is no usable TPM, in the Microsoft Software Key Storage Provider. The private key never leaves CNG: the
// app holds a handle and asks CNG to sign SHA-256 hashes (raw r || s, the IEEE P1363 form the Mac wants).

@Suppress("FunctionName")
internal interface NCrypt : Library {
    fun NCryptOpenStorageProvider(phProvider: LongByReference, pszProviderName: WString, dwFlags: Int): Int
    fun NCryptOpenKey(hProvider: Long, phKey: LongByReference, pszKeyName: WString, dwLegacyKeySpec: Int, dwFlags: Int): Int
    fun NCryptCreatePersistedKey(hProvider: Long, phKey: LongByReference, pszAlgId: WString, pszKeyName: WString, dwLegacyKeySpec: Int, dwFlags: Int): Int
    fun NCryptSetProperty(hObject: Long, pszProperty: WString, pbInput: ByteArray, cbInput: Int, dwFlags: Int): Int
    fun NCryptFinalizeKey(hKey: Long, dwFlags: Int): Int
    fun NCryptExportKey(hKey: Long, hExportKey: Long, pszBlobType: WString, pParameterList: Pointer?, pbOutput: ByteArray?, cbOutput: Int, pcbResult: IntByReference, dwFlags: Int): Int
    fun NCryptSignHash(hKey: Long, pPaddingInfo: Pointer?, pbHashValue: ByteArray, cbHashValue: Int, pbSignature: ByteArray?, cbSignature: Int, pcbResult: IntByReference, dwFlags: Int): Int
    fun NCryptDeleteKey(hKey: Long, dwFlags: Int): Int
    fun NCryptFreeObject(hObject: Long): Int

    companion object {
        val lib: NCrypt by lazy { Native.load("ncrypt", NCrypt::class.java) }
    }
}

class CngException(val status: Int, what: String) : Exception("$what failed (0x%08x)".format(status))

/** A CNG key storage provider (opened once, kept for the process). */
class CngProvider private constructor(val name: String, private val handle: Long) {
    val isTpm: Boolean get() = name == PLATFORM

    /** The key named `keyName`, or null when there is none. */
    fun openExisting(keyName: String): CngKey? {
        val key = LongByReference()
        val status = NCrypt.lib.NCryptOpenKey(handle, key, WString(keyName), 0, SILENT)
        if (status == NTE_BAD_KEYSET) return null
        check(status, "NCryptOpenKey")
        return CngKey(key.value)
    }

    /** Makes a non-exportable P-256 key named `keyName`. */
    fun create(keyName: String): CngKey {
        val key = LongByReference()
        check(NCrypt.lib.NCryptCreatePersistedKey(handle, key, WString("ECDSA_P256"), WString(keyName), 0, 0), "NCryptCreatePersistedKey")
        // Not exportable (the default of both providers; set explicitly where the provider takes it).
        NCrypt.lib.NCryptSetProperty(key.value, WString("Export Policy"), ByteArray(4), 4, PERSIST)
        val status = NCrypt.lib.NCryptFinalizeKey(key.value, SILENT)
        if (status != 0) {
            NCrypt.lib.NCryptDeleteKey(key.value, 0)
            throw CngException(status, "NCryptFinalizeKey")
        }
        return CngKey(key.value)
    }

    /** Deletes the key named `name` if it exists. */
    fun delete(keyName: String) {
        val key = LongByReference()
        if (NCrypt.lib.NCryptOpenKey(handle, key, WString(keyName), 0, SILENT) == 0) NCrypt.lib.NCryptDeleteKey(key.value, 0)
    }

    companion object {
        const val PLATFORM = "Microsoft Platform Crypto Provider"
        const val SOFTWARE = "Microsoft Software Key Storage Provider"
        internal const val NTE_BAD_KEYSET = 0x80090016.toInt()
        internal const val SILENT = 0x40
        internal const val PERSIST = 0x80000000.toInt()

        fun open(name: String): CngProvider {
            val provider = LongByReference()
            check(NCrypt.lib.NCryptOpenStorageProvider(provider, WString(name), 0), "NCryptOpenStorageProvider($name)")
            return CngProvider(name, provider.value)
        }

        internal fun check(status: Int, what: String) {
            if (status != 0) throw CngException(status, what)
        }
    }
}

/** A handle to a CNG P-256 key: signs, and knows its public key. */
class CngKey internal constructor(private val handle: Long) : P256Signer {
    /** 0x04 || X || Y from CNG's BCRYPT_ECCPUBLIC_BLOB (magic, length, X, Y). */
    override val publicKeyX963: ByteArray = run {
        val size = IntByReference()
        CngProvider.check(NCrypt.lib.NCryptExportKey(handle, 0, WString("ECCPUBLICBLOB"), null, null, 0, size, 0), "NCryptExportKey")
        val blob = ByteArray(size.value)
        CngProvider.check(NCrypt.lib.NCryptExportKey(handle, 0, WString("ECCPUBLICBLOB"), null, blob, blob.size, size, 0), "NCryptExportKey")
        eccPublicBlobToX963(blob)
    }

    @Synchronized
    override fun sign(message: ByteArray): ByteArray {
        val hash = MessageDigest.getInstance("SHA-256").digest(message)
        val size = IntByReference()
        val signature = ByteArray(64)
        CngProvider.check(NCrypt.lib.NCryptSignHash(handle, null, hash, hash.size, signature, signature.size, size, CngProvider.SILENT), "NCryptSignHash")
        return signature.copyOf(size.value)
    }

    companion object {
        /** BCRYPT_ECCKEY_BLOB: ULONG magic (ECS1 = P-256 public), ULONG cbKey (32), then X and Y. */
        fun eccPublicBlobToX963(blob: ByteArray): ByteArray {
            require(blob.size >= 8) { "short key blob" }
            val length = (blob[4].toInt() and 0xff) or (blob[5].toInt() and 0xff shl 8) or (blob[6].toInt() and 0xff shl 16) or (blob[7].toInt() and 0xff shl 24)
            require(length == 32 && blob.size >= 8 + 64) { "not a P-256 key blob" }
            return byteArrayOf(4) + blob.copyOfRange(8, 8 + 64)
        }
    }
}
