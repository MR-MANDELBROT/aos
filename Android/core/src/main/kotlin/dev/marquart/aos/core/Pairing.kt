package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * The one JSON line the phone sends to the Mac's pairing listener, and the proof in it (version 2: with the key the
 * phone signs its requests with). Docs/COMPANION.md, "Pairing", step 3.
 */
data class PairingRequest(
    val device: String,
    /** The device's public key exactly as it goes into `authorized_keys`: `ecdsa-sha2-nistp256 AAAA...` */
    val key: String,
    /** The signing key: P-256 in X9.63 form, standard base64. */
    val sign: String,
    val proof: String,
    val v: Int = 2,
) {
    /** The request as one line, terminated by "\n" (keys sorted, `/` not escaped). */
    fun line(): ByteArray {
        val obj = sortedJsonObject(
            "device" to JsonPrimitive(device), "key" to JsonPrimitive(key), "proof" to JsonPrimitive(proof),
            "sign" to JsonPrimitive(sign), "v" to JsonPrimitive(v),
        )
        return Bytes.utf8(Json.encode(obj) + "\n")
    }

    companion object {
        fun make(device: String, key: String, signingKeyX963: ByteArray, code: ByteArray): PairingRequest {
            val sign = Bytes.base64(signingKeyX963)
            return PairingRequest(device, key, sign, proof(code, key, device, sign))
        }

        /**
         * `base64(HMAC-SHA256(c, "aos-pair-request\n" + key + "\n" + device + "\n" + sign))`, with `c` as its raw 16
         * bytes, the message as UTF-8 and the result in standard base64 with padding. It covers both keys.
         */
        fun proof(code: ByteArray, key: String, device: String, sign: String): String =
            Bytes.base64(Bytes.hmacSha256(code, Bytes.utf8("aos-pair-request\n$key\n$device\n$sign")))

        /** The proof of version 1 (no signing key; the Mac refuses it now). Kept for its reference vector only. */
        fun proofV1(code: ByteArray, key: String, device: String): String =
            Bytes.base64(Bytes.hmacSha256(code, Bytes.utf8("$key\n$device")))

        /** Parses a request line (the test listener's side). */
        fun parse(line: ByteArray): PairingRequest? {
            val o = Json.parseObject(line) ?: return null
            return PairingRequest(
                device = o.string("device") ?: return null, key = o.string("key") ?: return null,
                sign = o.string("sign") ?: "", proof = o.string("proof") ?: return null,
                v = (o["v"] as? JsonPrimitive)?.intOrNull ?: 1,
            )
        }

        /** A device name the Mac can put into `authorized_keys` as a comment: one line, printable, at most 64. */
        fun sanitizedDeviceName(name: String): String {
            val replaced = buildString {
                var i = 0
                while (i < name.length) {
                    val cp = name.codePointAt(i)
                    if (Character.isISOControl(cp) || cp == 0x2028 || cp == 0x2029 || cp == 0x85) append(' ')
                    else appendCodePoint(cp)
                    i += Character.charCount(cp)
                }
            }
            val collapsed = replaced.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            val limited = if (collapsed.codePointCount(0, collapsed.length) > 64) {
                collapsed.substring(0, collapsed.offsetByCodePoints(0, 64))
            } else collapsed
            return limited.trim().ifEmpty { "Android" }
        }
    }
}

/**
 * The Mac's answer: `{"ok":true,"user":"<user>","companion":"<path>","mac":"<base64>"}` or `{"ok":false,"error":"..."}`.
 * `mac` is HMAC-SHA256(code, "aos-pair-answer\n" + user + "\n" + companion): only the Mac that shows the code can
 * write it, so nobody on the network can change the answer on its way.
 */
data class PairingResponse(
    val ok: Boolean,
    val user: String? = null,
    val companion: String? = null,
    val error: String? = null,
    val mac: String? = null,
) {
    /** The answer came from the Mac with this code, and names a plausible user and companion program. */
    fun isAuthentic(code: ByteArray): Boolean {
        if (!ok || user == null || companion == null || mac == null) return false
        val given = Bytes.base64Decode(mac) ?: return false
        val expected = authentication(code, user, companion)
        return Bytes.constantTimeEquals(given, expected) && isPlausibleUser(user) && isPlausibleCompanion(companion)
    }

    companion object {
        fun authentication(code: ByteArray, user: String, companion: String): ByteArray =
            Bytes.hmacSha256(code, Bytes.utf8("aos-pair-answer\n$user\n$companion"))

        fun parse(line: ByteArray): PairingResponse? {
            val o = Json.parseObject(line) ?: return null
            val ok = (o["ok"] as? JsonPrimitive)?.booleanOrNull ?: return null
            return PairingResponse(ok, o.string("user"), o.string("companion"), o.string("error"), o.string("mac"))
        }

        fun isPlausibleUser(user: String): Boolean =
            user.isNotEmpty() && user.length <= 64 && user.all { it.isLetterOrDigit() || it in "._-" }

        fun isPlausibleCompanion(companion: String): Boolean =
            companion.startsWith("/") && companion.endsWith("/aos-companion") && companion.length < 1024 &&
                companion.none { it.isISOControl() } && !companion.contains("/../")
    }
}

internal fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
