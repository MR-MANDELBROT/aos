package dev.marquart.aos.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Reference values computed independently (Python hmac/hashlib, ssh-keygen), the same as iOS Tests/PairingTests.swift
 *  and AOSKit's PairingTests. */
object Vectors {
    val code = ByteArray(16) { it.toByte() }
    const val CODE_BASE64URL = "AAECAwQFBgcICQoLDA0ODw"

    /** P-256 generator point as a public key. */
    const val P256_KEY = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
    const val P256_FINGERPRINT = "SHA256:SFMVDOrhOSBssOVH9hIcK/Z2XVf1oSVMjNCL8u2aICY"
    const val DEVICE = "Max’s iPhone"

    /** Pairing version 2 (AOSKit PairingTests.testProofReferenceVectorFromThePhone). */
    const val PROOF = "qkMRU/RXYOf3oLpMFcJHxT4LgNMUgtN2zEmhiHPFPoc="

    /** Version 1 (no signing key), iOS/NOTES.md "What the Mac side must match". */
    const val PROOF_V1 = "mrui6J5uTrdDd7yaEdlJQU6kWIO77PVkB04oYtW2SAQ="
    const val SIGN_BASE64 = "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="

    /** The Mac's id for a phone with `P256_KEY`. */
    const val P256_PHONE_ID = "4853150ceae1"

    /** A throwaway ed25519 key and what `ssh-keygen -lf` printed for it. */
    const val ED25519_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY"
    const val ED25519_FINGERPRINT = "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ"

    val generatorX963 = byteArrayOf(4) +
        Bytes.fromHex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296") +
        Bytes.fromHex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")
}

class PairingLinkTests {
    private val full = "aos-pair://v1?n=Max%E2%80%99s%20MacBook%20Pro&h=Maxs-MacBook-Pro.local,192.168.1.20,maxs-mbp.tail1234.ts.net&p=50123&s=22&u=max&k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ&c=AAECAwQFBgcICQoLDA0ODw"

    @Test fun parsesAllFields() {
        val link = PairingLink.parse(full)
        assertEquals("Max’s MacBook Pro", link.macName)
        assertEquals(listOf("Maxs-MacBook-Pro.local", "192.168.1.20", "maxs-mbp.tail1234.ts.net"), link.hosts)
        assertEquals(50123, link.pairingPort)
        assertEquals(22, link.sshPort)
        assertEquals("max", link.user)
        assertEquals(Vectors.ED25519_FINGERPRINT, link.hostKeyFingerprint)
        assertContentEquals(Vectors.code, link.code)
    }

    @Test fun toleratesWhitespaceEncodedCommasAndDefaults() {
        // Comma percent-encoded, no "s", fingerprint with padding, "+" left unencoded, surrounding white space
        val text = "  aos-pair://v1?h=mac.local%2C10.0.0.5&p=4000&u=max&k=SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ=&c=AAECAwQFBgcICQoLDA0ODw\n"
        val link = PairingLink.parse(text)
        assertEquals(listOf("mac.local", "10.0.0.5"), link.hosts)
        assertEquals(22, link.sshPort)
        assertEquals(Vectors.ED25519_FINGERPRINT, link.hostKeyFingerprint)
        assertEquals("mac.local", link.macName)
    }

    @Test fun roundTripsThroughItsUrl() {
        val link = PairingLink("Studio & Co / 2", listOf("studio.local", "fe80::1"), 61000, 2222, "max.m",
            Vectors.P256_FINGERPRINT, Vectors.code)
        assertEquals(link, PairingLink.parse(link.url))
    }

    @Test fun plainSpacesInAPastedLink() {
        val link = PairingLink.parse("aos-pair://v1?n=Max MacBook&h=mac.local&p=1&u=max&k=${Vectors.ED25519_FINGERPRINT}&c=${Vectors.CODE_BASE64URL}")
        assertEquals("Max MacBook", link.macName)
    }

    @Test fun rejectsBrokenLinks() {
        val k = "k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ"
        val c = "c=AAECAwQFBgcICQoLDA0ODw"
        fun error(text: String) = assertFailsWith<PairingLink.ParseError> { PairingLink.parse(text) }
        assertEquals(PairingLink.ParseError.NotAPairingLink, error("https://example.com/?h=a"))
        assertEquals(PairingLink.ParseError.NewerVersion, error("aos-pair://v2?h=a&p=1&u=m&$k&$c"))
        assertEquals(PairingLink.ParseError.NewerVersion, error("aos-pair://v3?h=a&p=1&u=m&$k&$c"))
        assertEquals(PairingLink.ParseError.Missing("h"), error("aos-pair://v1?p=1&u=m&$k&$c"))
        assertEquals(PairingLink.ParseError.Missing("u"), error("aos-pair://v1?h=a&p=1&$k&$c"))
        assertEquals(PairingLink.ParseError.Invalid("p"), error("aos-pair://v1?h=a&p=70000&u=m&$k&$c"))
        assertEquals(PairingLink.ParseError.Invalid("k"), error("aos-pair://v1?h=a&p=1&u=m&k=MD5:aa&$c"))
        // 15 bytes only
        assertEquals(PairingLink.ParseError.Invalid("c"), error("aos-pair://v1?h=a&p=1&u=m&$k&c=AAECAwQFBgcICQoLDA0O"))
        assertEquals(PairingLink.ParseError.Invalid("h"), error("aos-pair://v1?h=a/b&p=1&u=m&$k&$c"))
        assertEquals(PairingLink.ParseError.Invalid("u"), error("aos-pair://v1?h=a&p=1&u=a%0Ab&$k&$c"))
    }

    // The way on the go (`w`, `t`, `tn`), as aOS on the Mac writes it (iOS TailnetLinkTests).
    private val base = "aos-pair://v1?n=Max%E2%80%99s%20MacBook%20Pro&h=Maxs-MacBook-Pro.local,192.168.1.20,100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net&p=50123&s=22&u=max&k=SHA256%3AIKIpT5qrBHciGB6LMk%2B7fuTQHDnNluSkoLBSGY4SWMQ&c=AAECAwQFBgcICQoLDA0ODw"

    @Test fun parsesTheWayAndTheTailnetHosts() {
        val link = PairingLink.parse("$base&w=aos&t=100.90.1.3,aos-maxs-macbook-pro.tail1234.ts.net&tn=max%40example.com")
        assertEquals(ReachWay.AOS_TAILSCALE, link.way)
        assertEquals(listOf("100.90.1.3", "aos-maxs-macbook-pro.tail1234.ts.net"), link.tailnetHosts)
        assertEquals("max@example.com", link.tailnetName)
        assertEquals(listOf("Maxs-MacBook-Pro.local", "192.168.1.20", "100.90.1.3", "aos-maxs-macbook-pro.tail1234.ts.net"), link.hosts)
        assertEquals(link, PairingLink.parse(link.url))
        assertTrue(link.url.contains("tn=max%40example.com"))
        assertEquals(ReachWay.TAILSCALE_APP, PairingLink.parse("$base&w=app").way)
        assertEquals(ReachWay.LOCAL_NETWORK, PairingLink.parse("$base&w=LAN").way)
    }

    @Test fun linksOfAnEarlierMacAndWhatIsntPlausible() {
        val old = PairingLink.parse(base)
        assertNull(old.way)
        assertEquals(emptyList(), old.tailnetHosts)
        assertNull(old.tailnetName)
        assertFalse(old.url.contains("&w="))
        val odd = PairingLink.parse("$base&w=vpn&t=100.90.1.3,evil/path,%20,100.90.1.3&tn=a%0Ab")
        assertNull(odd.way, "an unknown way counts as none")
        assertEquals(listOf("100.90.1.3"), odd.tailnetHosts, "no paths, no empty or repeated hosts")
        assertNull(odd.tailnetName, "no line breaks")
    }
}

class PairingProofTests {
    @Test fun proofMatchesTheReference() {
        assertEquals(Vectors.SIGN_BASE64, Bytes.base64(Vectors.generatorX963))
        assertEquals(Vectors.PROOF, PairingRequest.proof(Vectors.code, Vectors.P256_KEY, Vectors.DEVICE, Vectors.SIGN_BASE64))
    }

    @Test fun versionOneReferenceVector() {
        assertEquals(Vectors.PROOF_V1, PairingRequest.proofV1(Vectors.code, Vectors.P256_KEY, Vectors.DEVICE))
    }

    @Test fun requestLineIsOneJsonObject() {
        val request = PairingRequest.make(Vectors.DEVICE, Vectors.P256_KEY, Vectors.generatorX963, Vectors.code)
        val line = request.line()
        assertEquals(0x0A, line.last().toInt())
        assertFalse(line.dropLast(1).contains(0x0A.toByte()))
        assertEquals("{\"device\":\"Max’s iPhone\",\"key\":\"${Vectors.P256_KEY}\",\"proof\":\"${Vectors.PROOF}\",\"sign\":\"${Vectors.SIGN_BASE64}\",\"v\":2}\n",
            line.toString(Charsets.UTF_8))
        assertEquals(request, PairingRequest.parse(line.copyOf(line.size - 1)))
    }

    @Test fun theProofCoversTheSigningKey() {
        val other = Bytes.base64(P256.x963(P256.generate().public))
        assertNotEquals(Vectors.PROOF, PairingRequest.proof(Vectors.code, Vectors.P256_KEY, Vectors.DEVICE, other))
    }

    @Test fun phoneIdLikeTheMac() {
        assertEquals(Vectors.P256_PHONE_ID, SSHKeyFormat.phoneId(Vectors.P256_KEY))
    }

    @Test fun deviceNamesAreOneLine() {
        assertEquals("Max iPhone", PairingRequest.sanitizedDeviceName("Max\n iPhone\u0007"))
        assertEquals("Android", PairingRequest.sanitizedDeviceName("   "))
        assertEquals(64, PairingRequest.sanitizedDeviceName("x".repeat(100)).length)
    }

    @Test fun decodesTheAnswer() {
        val ok = PairingResponse.parse("""{"ok":true,"user":"max","companion":"/Applications/aOS.app/Contents/MacOS/aos-companion"}""".toByteArray())!!
        assertTrue(ok.ok && ok.user == "max" && ok.companion!!.endsWith("aos-companion"))
        val failed = PairingResponse.parse("""{"ok":false,"error":"wrong code"}""".toByteArray())!!
        assertTrue(!failed.ok && failed.error == "wrong code")
    }

    @Test fun answerChecks() {
        val companion = "/Applications/aOS.app/Contents/MacOS/aos-companion"
        val mac = PairingResponse.authentication(Vectors.code, "max", companion)
        val r = PairingResponse(true, "max", companion, null, Bytes.base64(mac))
        assertTrue(r.isAuthentic(Vectors.code))
        assertFalse(r.copy(user = "root").isAuthentic(Vectors.code))
        assertFalse(r.isAuthentic(ByteArray(16) { 7 }))
        assertFalse(PairingResponse.isPlausibleCompanion("/bin/sh"))
        assertFalse(PairingResponse.isPlausibleCompanion("relative/aos-companion"))
        assertFalse(PairingResponse.isPlausibleCompanion("/a/../aos-companion"))
        assertFalse(PairingResponse.isPlausibleUser("max; rm"))
        // The reference vector the Mac's tests use too
        assertEquals("0jxhZL+aq9pEAtFLHRsylSojkicfFjA8AE3G/gHWyic=", Bytes.base64(mac))
    }
}

class SSHKeyFormatTests {
    @Test fun p256PublicKeyInOpenSSHForm() {
        assertEquals(Vectors.P256_KEY, SSHKeyFormat.openSSHP256(Vectors.generatorX963))
    }

    @Test fun fingerprintsLikeSshKeygen() {
        assertEquals(Vectors.ED25519_FINGERPRINT, SSHKeyFormat.fingerprint(Vectors.ED25519_KEY))
        assertEquals(Vectors.P256_FINGERPRINT, SSHKeyFormat.fingerprint(Vectors.P256_KEY))
        assertEquals(Vectors.ED25519_FINGERPRINT, SSHKeyFormat.fingerprint(Vectors.ED25519_KEY + " comment here"))
        // type text and blob disagree
        assertNull(SSHKeyFormat.fingerprint("ssh-rsa " + Vectors.ED25519_KEY.split(" ")[1]))
        assertEquals("ssh-ed25519", SSHKeyFormat.keyType(SSHKeyFormat.blob(Vectors.ED25519_KEY)!!))
    }

    @Test fun normalizesFingerprints() {
        assertEquals(Vectors.ED25519_FINGERPRINT, SSHKeyFormat.normalizedFingerprint(Vectors.ED25519_FINGERPRINT + "="))
        assertNull(SSHKeyFormat.normalizedFingerprint("SHA256:abc"))
        assertTrue(SSHKeyFormat.fingerprintsEqual(Vectors.ED25519_FINGERPRINT, Vectors.ED25519_FINGERPRINT))
        assertFalse(SSHKeyFormat.fingerprintsEqual(Vectors.ED25519_FINGERPRINT, Vectors.P256_FINGERPRINT))
    }

    @Test fun base64Url() {
        assertContentEquals(Vectors.code, Bytes.base64UrlDecode(Vectors.CODE_BASE64URL))
        assertEquals("-_8", Bytes.base64UrlEncode(byteArrayOf(0xfb.toByte(), 0xff.toByte())))
        assertContentEquals(byteArrayOf(0xfb.toByte(), 0xff.toByte()), Bytes.base64UrlDecode("-_8"))
        assertNull(Bytes.base64UrlDecode("a+b"))
    }

    @Test fun p256Math() {
        // The scalar 1 is the generator; DER and raw signatures convert both ways
        assertContentEquals(Vectors.generatorX963, P256.publicX963(ByteArray(31) + byteArrayOf(1)))
        val signer = SoftwareP256Signer.generate()
        val sig = signer.sign("hello".toByteArray())
        assertEquals(64, sig.size)
        assertTrue(P256.verify(P256.publicKey(signer.publicKeyX963)!!, "hello".toByteArray(), sig))
        assertFalse(P256.verify(P256.publicKey(signer.publicKeyX963)!!, "hellO".toByteArray(), sig))
        assertContentEquals(sig, P256.derToRaw(P256.rawToDer(sig)!!))
        assertNull(P256.publicKey(ByteArray(65).also { it[0] = 4 }), "not a point on the curve")
    }
}

/** The order the phone tries: the same network, the tailnet, Bonjour (iOS ConnectionPlanTests). */
class ConnectionPlanTests {
    private fun mac(hosts: List<String>, tailnet: List<String>?, way: ReachWay?, last: String? = null) = PairedMac(
        name = "Max’s MacBook Pro", hosts = hosts, user = "max", hostKey = Vectors.ED25519_KEY,
        hostKeyFingerprint = Vectors.ED25519_FINGERPRINT, lastHost = last, way = way?.raw, tailnetHosts = tailnet)

    private val bonjour = SSHRoute.Bonjour("Max’s MacBook Pro")

    @Test fun theSameNetworkFirstThenTheTailnetThenBonjour() {
        val paired = mac(listOf("Maxs-MacBook-Pro.local", "192.168.1.20", "100.90.1.3", "aos-mac.tail1234.ts.net"),
            listOf("100.90.1.3", "aos-mac.tail1234.ts.net"), ReachWay.AOS_TAILSCALE, last = "192.168.1.20")
        assertEquals(listOf(SSHRoute.Host("192.168.1.20"), SSHRoute.Host("Maxs-MacBook-Pro.local"),
            SSHRoute.Tailnet("100.90.1.3"), SSHRoute.Tailnet("aos-mac.tail1234.ts.net"),
            SSHRoute.Host("100.90.1.3"), SSHRoute.Host("aos-mac.tail1234.ts.net"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = true, systemVPN = true))
        assertEquals(listOf(SSHRoute.Host("192.168.1.20"), SSHRoute.Host("Maxs-MacBook-Pro.local"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = false, systemVPN = false))
        assertEquals(listOf(SSHRoute.Host("192.168.1.20"), SSHRoute.Host("Maxs-MacBook-Pro.local"),
            SSHRoute.Host("100.90.1.3"), SSHRoute.Host("aos-mac.tail1234.ts.net"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = false, systemVPN = true))
    }

    @Test fun aTailnetAddressThatWorkedLastStillComesAfterTheSameNetwork() {
        val paired = mac(listOf("mac.local", "100.90.1.3"), listOf("100.90.1.3"), ReachWay.TAILSCALE_APP, last = "100.90.1.3")
        assertEquals(listOf(SSHRoute.Host("mac.local"), SSHRoute.Host("100.90.1.3"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = false, systemVPN = true))
    }

    @Test fun aMacPairedBeforeTheWayExistedUsesTheTailnetAddressesAmongItsHosts() {
        val paired = mac(listOf("mac.local", "10.0.0.5", "maxs-mbp.tail1234.ts.net", "100.101.102.103"), null, null)
        assertEquals(listOf("100.101.102.103", "maxs-mbp.tail1234.ts.net"), ConnectionPlan.tailnetHosts(paired))
        assertEquals(listOf(SSHRoute.Host("mac.local"), SSHRoute.Host("10.0.0.5"), SSHRoute.Tailnet("100.101.102.103"),
            SSHRoute.Tailnet("maxs-mbp.tail1234.ts.net"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = true, systemVPN = false))
    }

    @Test fun onlyTheSameNetwork() {
        val paired = mac(listOf("mac.local", "192.168.1.20"), emptyList(), ReachWay.LOCAL_NETWORK)
        assertEquals(listOf(SSHRoute.Host("mac.local"), SSHRoute.Host("192.168.1.20"), bonjour),
            ConnectionPlan.routes(paired, embeddedNode = true, systemVPN = true))
    }

    @Test fun routesKnowWhetherTheyGoThroughATailnet() {
        assertTrue(SSHRoute.Tailnet("mac").isTailnet)
        assertTrue(SSHRoute.Host("100.90.1.3").isTailnet)
        assertTrue(SSHRoute.Host("mac.tail1234.ts.net").isTailnet)
        assertTrue(SSHRoute.Host("fd7a:115c:a1e0::1").isTailnet)
        assertFalse(SSHRoute.Host("192.168.1.20").isTailnet)
        assertFalse(SSHRoute.Host("100.128.0.1").isTailnet)
        assertFalse(SSHRoute.Bonjour("mac").isTailnet)
    }

    @Test fun pairedMacHostsToTryAndJson() {
        val paired = mac(listOf("a", "b", "c"), null, null, last = "b")
        assertEquals(listOf("b", "a", "c"), paired.hostsToTry)
        val json = kotlinx.serialization.json.Json.encodeToString(PairedMac.serializer(), paired)
        assertEquals(paired, kotlinx.serialization.json.Json.decodeFromString(PairedMac.serializer(), json))
    }
}
