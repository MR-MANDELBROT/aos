package dev.marquart.aos.core

import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Base64 variants, hex and hashes, the way the Mac and the iPhone write them. */
object Bytes {
    /** Standard base64 with padding. */
    fun base64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

    /** Standard base64; null when it isn't valid (padding required, as Foundation's `Data(base64Encoded:)`). */
    fun base64Decode(text: String): ByteArray? {
        if (text.length % 4 != 0) return null
        if (!text.all { it.isLetterOrDigit() && it.code < 128 || it == '+' || it == '/' || it == '=' }) return null
        return try {
            Base64.getDecoder().decode(text)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    /** Standard base64 with or without padding. */
    fun base64DecodeUnpadded(text: String): ByteArray? {
        val remainder = text.length % 4
        if (remainder == 1) return null
        val padded = if (remainder > 0) text + "=".repeat(4 - remainder) else text
        return base64Decode(padded)
    }

    /** base64url (RFC 4648 section 5), padding optional. */
    fun base64UrlDecode(text: String): ByteArray? {
        val unpadded = text.replace("=", "")
        if (!unpadded.all { it.code < 128 && (it.isLetterOrDigit() || it == '-' || it == '_') }) return null
        return base64DecodeUnpadded(unpadded.replace('-', '+').replace('_', '/'))
    }

    /** base64url without padding. */
    fun base64UrlEncode(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun hex(data: ByteArray): String = buildString(data.size * 2) {
        for (b in data) {
            append("0123456789abcdef"[(b.toInt() shr 4) and 0xF])
            append("0123456789abcdef"[b.toInt() and 0xF])
        }
    }

    fun fromHex(text: String): ByteArray {
        require(text.length % 2 == 0) { "odd hex length" }
        return ByteArray(text.length / 2) { i -> text.substring(2 * i, 2 * i + 2).toInt(16).toByte() }
    }

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message)
    }

    /** Compares in constant time (for the length of the shorter input; different lengths never match). */
    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)
}
