package dev.marquart.aos.core

import java.io.ByteArrayOutputStream

/** OpenSSH text forms of public keys and their fingerprints, without an SSH library (iOS `SSHKeyFormat`). */
object SSHKeyFormat {
    const val P256_KEY_TYPE = "ecdsa-sha2-nistp256"

    /**
     * `ecdsa-sha2-nistp256 AAAA...` for a P-256 public key in X9.63 form, as in `authorized_keys` (RFC 5656: string
     * "ecdsa-sha2-nistp256", string "nistp256", string Q).
     */
    fun openSSHP256(x963: ByteArray): String = P256_KEY_TYPE + " " + Bytes.base64(p256Blob(x963))

    /** The binary key blob of a P-256 public key. */
    fun p256Blob(x963: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        appendString(Bytes.utf8(P256_KEY_TYPE), out)
        appendString(Bytes.utf8("nistp256"), out)
        appendString(x963, out)
        return out.toByteArray()
    }

    /** The binary key blob of an OpenSSH public key line (`<type> <base64> [comment]`). */
    fun blob(openSSHKey: String): ByteArray? {
        val parts = openSSHKey.split(' ').filter { it.isNotEmpty() }
        if (parts.size < 2) return null
        val blob = Bytes.base64Decode(parts[1]) ?: return null
        // The blob starts with the key type again; it must agree with the text.
        val type = readString(blob) ?: return null
        return if (type.contentEquals(Bytes.utf8(parts[0]))) blob else null
    }

    /** The key type inside a blob (`ssh-ed25519`, `ecdsa-sha2-nistp256`, ...). */
    fun keyType(blob: ByteArray): String? = readString(blob)?.toString(Charsets.UTF_8)

    /** `SHA256:<base64 without padding>`, exactly as `ssh-keygen -l` prints it. */
    fun fingerprint(blob: ByteArray): String = "SHA256:" + Bytes.base64(Bytes.sha256(blob)).replace("=", "")

    fun fingerprint(openSSHKey: String): String? = blob(openSSHKey)?.let(::fingerprint)

    /** The OpenSSH line of a key blob (`<type> <base64>`). */
    fun openSSHLine(blob: ByteArray): String? = keyType(blob)?.let { "$it ${Bytes.base64(blob)}" }

    /**
     * The id aOS on the Mac gives a paired phone: the first 12 hex characters (lowercase) of the SHA-256 of its key
     * blob, as in `aos-companion:<id>` in authorized_keys. Signed requests name it.
     */
    fun phoneId(openSSHKey: String): String? = blob(openSSHKey)?.let { Bytes.hex(Bytes.sha256(it)).substring(0, 12) }

    /** Accepts `SHA256:<base64>` with or without padding; the canonical form, or null if it isn't 32 bytes. */
    fun normalizedFingerprint(text: String): String? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("SHA256:")) return null
        val body = trimmed.removePrefix("SHA256:").replace("=", "")
        val digest = Bytes.base64DecodeUnpadded(body) ?: return null
        return if (digest.size == 32) "SHA256:$body" else null
    }

    /** Fingerprints compared in constant time (they're public, but it costs nothing). */
    fun fingerprintsEqual(a: String, b: String): Boolean = Bytes.constantTimeEquals(Bytes.utf8(a), Bytes.utf8(b))

    // SSH wire strings

    private fun appendString(value: ByteArray, out: ByteArrayOutputStream) {
        val n = value.size
        out.write(byteArrayOf((n ushr 24).toByte(), (n ushr 16).toByte(), (n ushr 8).toByte(), n.toByte()))
        out.write(value)
    }

    private fun readString(data: ByteArray): ByteArray? {
        if (data.size < 4) return null
        val length = ((data[0].toInt() and 0xFF) shl 24) or ((data[1].toInt() and 0xFF) shl 16) or
            ((data[2].toInt() and 0xFF) shl 8) or (data[3].toInt() and 0xFF)
        if (length <= 0 || data.size < 4 + length) return null
        return data.copyOfRange(4, 4 + length)
    }
}
