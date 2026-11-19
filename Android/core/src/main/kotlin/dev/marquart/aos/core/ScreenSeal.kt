package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.KeyPair
import java.security.PrivateKey
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The workspace's screen login, readable only by this phone (Docs/COMPANION.md, "The workspace's screen login"). The
 * same scheme as aOS on the Mac (AOSKit `ScreenSeal`) and the iPhone; all test the same reference vector.
 *
 * The `screen` request for the workspace carries a fresh P-256 key-agreement key, made for this one request and kept in
 * memory only until the answer is open; the signature covers it. The Mac answers with its own fresh key and an AES-GCM
 * box: ECDH, then HKDF-SHA256 (salt `aos-screen-v1`) over a context naming the op, this phone, the request's nonce and
 * both keys, which is also the box's additional data.
 */
object ScreenSeal {
    const val VERSION = "aos-screen-v1"

    /** The answer: the Mac's one-time public key (X9.63, 65 bytes) and the box (12-byte nonce, ciphertext, tag). */
    class Sealed(val key: ByteArray, val box: ByteArray) {
        val json: JsonObject
            get() = sortedJsonObject("v" to JsonPrimitive(1), "key" to JsonPrimitive(Bytes.base64(key)),
                "box" to JsonPrimitive(Bytes.base64(box)))

        companion object {
            /** `{"v":1,"key":"<base64>","box":"<base64>"}` in the answer. */
            fun from(value: kotlinx.serialization.json.JsonElement?): Sealed? {
                val o = value.obj ?: return null
                if (o["v"].int != 1) return null
                val key = o["key"].str?.let(Bytes::base64Decode) ?: return null
                val box = o["box"].str?.let(Bytes::base64Decode) ?: return null
                return Sealed(key, box)
            }
        }
    }

    sealed class Failure(message: String) : Exception(message) {
        class BadKey : Failure("bad key")
        class BadContext : Failure("bad context")
        class Broken : Failure("the box doesn't open")
    }

    /**
     * What binds the box to one request, these lines joined with "\n" (no newline at the end); HKDF's info and AES-GCM's
     * additional data:
     *
     *     aos-screen-v1
     *     op=companion.screen
     *     key=<phone id>
     *     nonce=<the request's nonce>
     *     phone=<base64 X9.63 of this phone's one-time key>
     *     mac=<base64 X9.63 of the Mac's one-time key>
     */
    fun context(op: String, phone: String, nonce: String, phoneKey: ByteArray, macKey: ByteArray): ByteArray? {
        if (listOf(op, phone, nonce).any { it.contains('\n') || it.contains('\r') }) return null
        val lines = listOf(VERSION, "op=$op", "key=$phone", "nonce=$nonce", "phone=${Bytes.base64(phoneKey)}",
            "mac=${Bytes.base64(macKey)}")
        return Bytes.utf8(lines.joinToString("\n"))
    }

    /** HKDF-SHA256 (RFC 5869), 32 bytes. */
    fun hkdfSha256(secret: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        val prk = Bytes.hmacSha256(salt, secret)
        val out = java.io.ByteArrayOutputStream()
        var previous = ByteArray(0)
        var counter = 1
        while (out.size() < length) {
            previous = Bytes.hmacSha256(prk, previous + info + byteArrayOf(counter.toByte()))
            out.write(previous)
            counter++
        }
        return out.toByteArray().copyOf(length)
    }

    private fun sharedSecret(own: PrivateKey, peerX963: ByteArray): ByteArray {
        val peer = P256.publicKey(peerX963) ?: throw Failure.BadKey()
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(own)
        agreement.doPhase(peer, true)
        return agreement.generateSecret()
    }

    private fun symmetricKey(secret: ByteArray, context: ByteArray) =
        SecretKeySpec(hkdfSha256(secret, Bytes.utf8(VERSION), context), "AES")

    /** Opens the Mac's answer with the one-time key this phone sent (`phoneKey`, its public half `phonePublic`), for
     *  the request it signed. */
    fun open(sealed: Sealed, phoneKey: PrivateKey, phonePublic: ByteArray, op: String, phone: String, nonce: String): ByteArray {
        if (sealed.key.size != 65 || P256.publicKey(sealed.key) == null) throw Failure.BadKey()
        val info = context(op, phone, nonce, phonePublic, sealed.key) ?: throw Failure.BadContext()
        try {
            val secret = sharedSecret(phoneKey, sealed.key)
            if (sealed.box.size < 12 + 16) throw Failure.Broken()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, symmetricKey(secret, info), GCMParameterSpec(128, sealed.box, 0, 12))
            cipher.updateAAD(info)
            return cipher.doFinal(sealed.box, 12, sealed.box.size - 12)
        } catch (e: Failure) {
            throw e
        } catch (_: Exception) {
            throw Failure.Broken()
        }
    }

    /**
     * The Mac's side, for the in-memory Mac of the tests and the demo: seals `plaintext` to the phone's one-time key.
     * `macKey` and `gcmNonce` are fresh unless given (the reference vector gives them).
     */
    fun seal(plaintext: ByteArray, phoneKey: ByteArray, op: String, phone: String, nonce: String,
             macKey: KeyPair = P256.generate(), gcmNonce: ByteArray = ByteArray(12).also { SecureRandom().nextBytes(it) }): Sealed {
        if (phoneKey.size != 65 || P256.publicKey(phoneKey) == null) throw Failure.BadKey()
        val macPublic = P256.x963(macKey.public)
        val info = context(op, phone, nonce, phoneKey, macPublic) ?: throw Failure.BadContext()
        val secret = sharedSecret(macKey.private, phoneKey)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, symmetricKey(secret, info), GCMParameterSpec(128, gcmNonce))
        cipher.updateAAD(info)
        return Sealed(macPublic, gcmNonce + cipher.doFinal(plaintext))
    }

    /**
     * The workspace's login in the answer to a `screen` request: opened with the request's one-time key and the
     * signature it went with. An answer without a sealed login (an older Mac, or someone answering in its place in
     * plaintext) is never taken: `UpdateMac`. One that doesn't open: `InvalidAnswer`.
     */
    fun login(response: CompanionResponse, oneTime: KeyPair, op: String, auth: CompanionAuth?): ScreenEndpoint {
        val sealed = Sealed.from(response.body["sealed"]) ?: throw SealedLoginException.UpdateMac()
        val plaintext = try {
            open(sealed, oneTime.private, P256.x963(oneTime.public), op, auth?.key ?: "", auth?.nonce ?: "")
        } catch (_: Failure) {
            throw SealedLoginException.InvalidAnswer()
        }
        val o = Json.parseObject(plaintext) ?: throw SealedLoginException.InvalidAnswer()
        return ScreenEndpoint.from(o) ?: throw SealedLoginException.InvalidAnswer()
    }
}

/** Why a workspace screen login wasn't taken (the app maps these to its CompanionError). */
sealed class SealedLoginException(message: String) : Exception(message) {
    /** The Mac answered without sealing the login (aOS on the Mac is older). */
    class UpdateMac : SealedLoginException("Update aOS on the Mac to see the workspace from this phone.")

    /** It didn't open (changed on its way, or for another request). */
    class InvalidAnswer : SealedLoginException("aOS on the Mac sent an answer this app doesn't understand.")
}
