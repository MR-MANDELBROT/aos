package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.KeyPair
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals

/** The workspace's screen login comes sealed to a one-time key the request signs (iOS SealedScreenLoginTests, AOSKit
 *  ScreenSealTests). */
class ScreenSealTests {
    companion object {
        /** The public key of the private key 01..20 (also the signing vector's key). */
        const val PHONE_KEY = "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q="
        const val MAC_KEY = "BB8UAUa/sbJR+E9N2+DUzc/Xev2YSpUg41eUAh+DErue7JlaCLH6dwTfPcwLUKlmUmP7dxH5X5+KRJxQluR8iSs="
        const val BOX = "AAECAwQFBgcICQoL+APgE8Y8TlMJetK2W7N66yDO8c6j1i8jHiJdq6KMhUBWtWhTFg=="
        const val NONCE = "AAECAwQFBgcICQoLDA0ODw"
        val phoneScalar = ByteArray(32) { (it + 1).toByte() }
        val macScalar = ByteArray(32) { (it + 0x21).toByte() }
    }

    private val phone = P256.privateKey(phoneScalar)
    private val phonePublic = Bytes.base64Decode(PHONE_KEY)!!

    @Test fun theMacsReferenceVectorOpens() {
        // Sealed on the Mac side for the phone key 01..20 by the Mac key 21..40, phone 4853150ceae1, nonce 00..0f, GCM
        // nonce 00..0b
        assertContentEquals(phonePublic, P256.publicX963(phoneScalar))
        val sealed = ScreenSeal.Sealed(Bytes.base64Decode(MAC_KEY)!!, Bytes.base64Decode(BOX)!!)
        val plaintext = ScreenSeal.open(sealed, phone, phonePublic, "companion.screen", "4853150ceae1", NONCE)
        assertEquals("""{"password":"geheim"}""", plaintext.toString(Charsets.UTF_8))
        // One bit off anywhere, or another request's nonce: it doesn't open
        val changed = sealed.box.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
        assertFailsWith<ScreenSeal.Failure.Broken> {
            ScreenSeal.open(ScreenSeal.Sealed(sealed.key, changed), phone, phonePublic, "companion.screen", "4853150ceae1", NONCE)
        }
        assertFailsWith<ScreenSeal.Failure.Broken> {
            ScreenSeal.open(sealed, phone, phonePublic, "companion.screen", "4853150ceae1", "BBECAwQFBgcICQoLDA0ODw")
        }
    }

    @Test fun sealingHereGivesTheMacsBoxByteForByte() {
        // The Mac's one-time key 21..40 and the GCM nonce 00..0b: the same box as AOSKit's
        val mac = KeyPair(P256.publicKey(P256.publicX963(macScalar))!!, P256.privateKey(macScalar))
        assertEquals(MAC_KEY, Bytes.base64(P256.x963(mac.public)))
        val sealed = ScreenSeal.seal("""{"password":"geheim"}""".toByteArray(), phonePublic, "companion.screen",
            "4853150ceae1", NONCE, macKey = mac, gcmNonce = ByteArray(12) { it.toByte() })
        assertEquals(MAC_KEY, Bytes.base64(sealed.key))
        assertEquals(BOX, Bytes.base64(sealed.box))
    }

    @Test fun theReplyKeyIsSigned() {
        // The same digest the Mac's tests check (Python: sha256(b"reply:88:" + key + b"\n"))
        assertEquals("2c4f2b4babd1464127bd60006cf4448888d07a7b0aaff3dff22f2b97e76f0562", CompanionSignature.dataDigest(reply = PHONE_KEY))
        val fields = CompanionRequest.Screen(ScreenTarget.WORKSPACE, PHONE_KEY).signatureFields("k", 1, "n")
        assertEquals("2c4f2b4babd1464127bd60006cf4448888d07a7b0aaff3dff22f2b97e76f0562", fields.data)
        assertEquals("workspace", fields.target)
        // The Mac's own screen signs what it always signed
        assertEquals(CompanionSignature.dataDigest(), CompanionRequest.Screen(ScreenTarget.MAC).signatureFields("k", 1, "n").data)
        assertEquals("{\"id\":4,\"op\":\"screen\",\"reply\":\"K\",\"target\":\"workspace\"}\n",
            CompanionRequest.Screen(ScreenTarget.WORKSPACE, "K").line(4).toString(Charsets.UTF_8))
    }

    @Test fun aSealedLoginOpensOnlyForItsRequest() {
        val oneTime = P256.generate()
        val signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate())
        val request = CompanionRequest.Screen(ScreenTarget.WORKSPACE, Bytes.base64(P256.x963(oneTime.public)))
        val auth = signer.auth(request)
        val login = """{"host":"192.168.64.5","password":"geheim","port":5900,"username":"aos"}""".toByteArray()
        val sealed = ScreenSeal.seal(login, P256.x963(oneTime.public), "companion.screen", auth.key, auth.nonce)
        val response = CompanionResponse(4, true, null, JsonObject(mapOf("id" to JsonPrimitive(4), "sealed" to sealed.json)))
        assertEquals(ScreenEndpoint("192.168.64.5", 5900, "aos", "geheim"), ScreenSeal.login(response, oneTime, "companion.screen", auth))
        // Another request's signature (another nonce), or another one-time key: it doesn't open
        assertFailsWith<SealedLoginException.InvalidAnswer> { ScreenSeal.login(response, oneTime, "companion.screen", signer.auth(request)) }
        assertFailsWith<SealedLoginException.InvalidAnswer> { ScreenSeal.login(response, P256.generate(), "companion.screen", auth) }
        // Two seals of the same login differ (fresh key, fresh nonce)
        assertNotEquals(Bytes.base64(sealed.box), Bytes.base64(ScreenSeal.seal(login, P256.x963(oneTime.public), "companion.screen", auth.key, auth.nonce).box))
    }

    @Test fun noPlaintextLoginIsTaken() {
        val plain = CompanionResponse(4, true, null, Json.parseObject(
            """{"id":4,"ok":true,"host":"192.168.64.5","port":5900,"username":"aos","password":"geheim"}""".toByteArray())!!)
        assertFailsWith<SealedLoginException.UpdateMac> { ScreenSeal.login(plain, P256.generate(), "companion.screen", null) }
    }

    @Test fun hkdfLikeRfc5869() {
        // RFC 5869, test case 1
        val okm = ScreenSeal.hkdfSha256(Bytes.fromHex("0b".repeat(22)), Bytes.fromHex("000102030405060708090a0b0c"),
            Bytes.fromHex("f0f1f2f3f4f5f6f7f8f9"), 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", Bytes.hex(okm))
    }
}
