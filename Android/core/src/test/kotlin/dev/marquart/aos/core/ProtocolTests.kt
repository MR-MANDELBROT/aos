package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun text(request: CompanionRequest, id: Int) = request.line(id).toString(Charsets.UTF_8)
private fun decode(json: String) = CompanionMessage.decode(json.toByteArray())
private fun event(e: CompanionEvent) = CompanionMessage.Event(e)

/** iOS CompanionProtocolTests and ProtocolUpdateTests. */
class CompanionProtocolTests {
    @Test fun requestLines() {
        assertEquals("{\"app\":\"0.1.0\",\"device\":\"Max\u2019s iPhone\",\"id\":1,\"op\":\"hello\"}\n",
            text(CompanionRequest.Hello("0.1.0", "Max\u2019s iPhone"), 1))
        assertEquals("{\"id\":2,\"op\":\"status\"}\n", text(CompanionRequest.Status, 2))
        assertEquals("{\"id\":3,\"op\":\"subscribe\"}\n", text(CompanionRequest.Subscribe, 3))
        assertEquals("{\"id\":4,\"op\":\"screen\",\"target\":\"workspace\"}\n", text(CompanionRequest.Screen(ScreenTarget.WORKSPACE), 4))
        assertEquals("{\"host\":\"github.com\",\"id\":5,\"op\":\"signin.answer\",\"password\":\"p\\\"w/\\n\",\"request\":\"r1\",\"totp\":\"123456\",\"username\":\"max\"}\n",
            text(CompanionRequest.SignInAnswer("r1", "github.com", "max", "p\"w/\n", "123456"), 5))
        assertEquals("{\"host\":\"github.com\",\"id\":6,\"op\":\"signin.answer\",\"password\":\"pw\",\"request\":\"r1\",\"username\":\"max\"}\n",
            text(CompanionRequest.SignInAnswer("r1", "github.com", "max", "pw", null), 6))
        assertEquals("{\"decline\":true,\"host\":\"github.com\",\"id\":7,\"op\":\"signin.answer\",\"request\":\"r1\"}\n",
            text(CompanionRequest.SignInDecline("r1", "github.com"), 7))
        assertEquals("{\"id\":8,\"op\":\"help.done\",\"request\":\"h1\"}\n", text(CompanionRequest.HelpDone("h1"), 8))
    }

    @Test fun newRequestLines() {
        assertEquals("{\"host\":\"a.de\",\"id\":1,\"op\":\"signin.answer\",\"request\":\"r3\",\"totp\":\"123456\"}\n",
            text(CompanionRequest.SignInCode("r3", "a.de", "123456"), 1))
        assertEquals("{\"allowed\":true,\"id\":2,\"op\":\"approval.answer\",\"request\":\"a1\"}\n",
            text(CompanionRequest.ApprovalAnswer("a1", true), 2))
        assertEquals("{\"allowed\":false,\"id\":3,\"op\":\"approval.answer\",\"request\":\"a1\"}\n",
            text(CompanionRequest.ApprovalAnswer("a1", false), 3))
        assertEquals("{\"id\":4,\"op\":\"type\",\"text\":\"Grüße 😀\"}\n", text(CompanionRequest.Type("Grüße 😀"), 4))
        assertEquals("{\"host\":\"a.de\",\"id\":5,\"login\":\"b1\",\"op\":\"signin.answer\",\"request\":\"r\"}\n",
            text(CompanionRequest.SignInLogin("r", "a.de", "b1"), 5))
        assertEquals("{\"id\":6,\"op\":\"display\",\"target\":\"workspace\",\"text\":\"1200x2322@2\"}\n",
            text(CompanionRequest.Display(ScreenTarget.WORKSPACE, "1200x2322@2"), 6))
    }

    @Test fun everyRequestIsExactlyOneLine() {
        val line = CompanionRequest.SignInAnswer("r", "h", "a\nb", "c\r\nd", null).line(1)
        assertEquals(1, line.count { it == 0x0A.toByte() })
        assertEquals(0x0A, line.last().toInt())
    }

    @Test fun responses() {
        val hello = decode("""{"id":1,"ok":true,"mac":"Max’s MacBook","aos":"0.2.0","features":["mac.status","term"]}""")
        val r = assertIs<CompanionMessage.Response>(hello).response
        assertTrue(r.id == 1 && r.ok)
        assertEquals(HelloResult("Max’s MacBook", "0.2.0", setOf("mac.status", "term")), HelloResult.from(r))

        val status = decode("""{"id":2,"ok":true,"workspace":{"state":"open","purpose":"Rechnung laden","until":"2026-11-06T12:30:00Z"},"sessions":[{"title":"Claude Code","state":"running"}]}""")
        val ws = WorkspaceStatus.from(assertIs<CompanionMessage.Response>(status).response)
        assertEquals(WorkspaceState.OPEN, ws.state)
        assertEquals("Rechnung laden", ws.purpose)
        assertEquals(Instant.ofEpochSecond(1_793_968_200), ws.until)
        assertEquals(listOf("Claude Code"), ws.sessions.map { it.title })

        val screen = decode("""{"id":4,"ok":true,"host":"192.168.64.5","port":5900,"username":"aos","password":"secret"}""")
        assertEquals(ScreenEndpoint("192.168.64.5", 5900, "aos", "secret"),
            ScreenEndpoint.from(assertIs<CompanionMessage.Response>(screen).response))

        val failed = assertIs<CompanionMessage.Response>(decode("""{"id":9,"ok":false,"error":"no such request","code":"pair-again"}""")).response
        assertTrue(!failed.ok && failed.error == "no such request" && failed.code == "pair-again")
        // A number written with a fraction still is the id
        assertEquals(10, assertIs<CompanionMessage.Response>(decode("""{"id":10.0,"ok":true}""")).response.id)
    }

    @Test fun events() {
        assertEquals(event(CompanionEvent.SignIn(SignInRequest("r7", "Claude Code", "www.amazon.de", "Rechnung herunterladen",
            Instant.ofEpochSecond(1_793_966_400, 250_000_000)))),
            decode("""{"event":"signin","request":"r7","agent":"Claude Code","host":"www.amazon.de","purpose":"Rechnung herunterladen","expires":"2026-11-06T12:00:00.250Z"}"""))
        assertEquals(event(CompanionEvent.SignInClosed("r7", SignInResult.FILLED)), decode("""{"event":"signin.closed","request":"r7","result":"filled"}"""))
        assertEquals(event(CompanionEvent.SignInClosed("r7", SignInResult.UNKNOWN)), decode("""{"event":"signin.closed","request":"r7","result":"exploded"}"""))
        assertEquals(event(CompanionEvent.Help(HelpRequest("h1", "Codex", "Captcha", HelpRequest.Region(100.0, 200.0, 300.0, 150.0)))),
            decode("""{"event":"help","request":"h1","agent":"Codex","purpose":"Captcha","region":{"x":100,"y":200,"w":300,"h":150}}"""))
        assertEquals(event(CompanionEvent.Help(HelpRequest("h2", "Codex", "x", null))),
            decode("""{"event":"help","request":"h2","agent":"Codex","purpose":"x","region":{"x":0,"y":0,"w":0,"h":0}}"""))
        assertEquals(event(CompanionEvent.HelpClosed("h1")), decode("""{"event":"help.closed","request":"h1"}"""))
        assertEquals(event(CompanionEvent.Workspace(WorkspaceState.STARTING)), decode("""{"event":"workspace","state":"starting"}"""))
        assertEquals(event(CompanionEvent.Chats), decode("""{"event":"chats"}"""))
        assertEquals(event(CompanionEvent.SubscriptionEnded), decode("""{"event":"subscription","state":"ended"}"""))
        assertEquals(CompanionMessage.Ignored, decode("""{"event":"subscription","state":"other"}"""))
        // An offset in the date instead of Z
        val withOffset = assertIs<CompanionMessage.Event>(decode("""{"event":"approval","request":"a","expires":"2026-11-06T13:30:00+01:00"}"""))
        assertEquals(Instant.ofEpochSecond(1_793_968_200), (withOffset.event as CompanionEvent.Approval).request.expires)
    }

    @Test fun signInFieldsAndLogins() {
        fun field(json: String) = ((decode(json) as CompanionMessage.Event).event as CompanionEvent.SignIn).request.field
        assertEquals(SignInRequest.Field.CODE, field("""{"event":"signin","request":"r","host":"a.de","field":"code"}"""))
        assertEquals(SignInRequest.Field.USERNAME, field("""{"event":"signin","request":"r","host":"a.de","field":"username"}"""))
        assertEquals(SignInRequest.Field.PASSWORD, field("""{"event":"signin","request":"r","host":"a.de"}"""))
        assertEquals(SignInRequest.Field.PASSWORD, field("""{"event":"signin","request":"r","host":"a.de","field":"pin"}"""))
        val withLogins = ((decode("""{"event":"signin","request":"r","host":"a.de","field":"code","bitwarden":"unlocked","logins":[{"id":"b1","name":"A","username":"max","totp":true},{"id":"b2","name":"B","username":"m"},{"name":"no id"}]}""")
            as CompanionMessage.Event).event as CompanionEvent.SignIn).request
        assertEquals(BitwardenState.UNLOCKED, withLogins.bitwarden)
        assertEquals(listOf("b1", "b2"), withLogins.logins.map { it.id })
        assertEquals(listOf("b1"), withLogins.choices.map { it.id }, "a code: only logins with a key")
        val noState = ((decode("""{"event":"signin","request":"r","host":"a.de","bitwarden":"weird"}""") as CompanionMessage.Event).event as CompanionEvent.SignIn).request
        assertEquals(BitwardenState.OFF, noState.bitwarden)
    }

    @Test fun approvalsAndMacEvents() {
        assertEquals(event(CompanionEvent.Approval(ApprovalRequest("a1", "Codex", "Rechnungen", 15, Instant.ofEpochSecond(1_793_968_200)))),
            decode("""{"event":"approval","request":"a1","agent":"Codex","purpose":"Rechnungen","minutes":15,"expires":"2026-11-06T12:30:00Z"}"""))
        assertEquals(event(CompanionEvent.ApprovalClosed("a1", ApprovalResult.ALLOWED)), decode("""{"event":"approval.closed","request":"a1","result":"allowed"}"""))
        assertEquals(event(CompanionEvent.ApprovalClosed("a1", ApprovalResult.DECLINED)), decode("""{"event":"approval.closed","request":"a1","result":"declined"}"""))
        assertEquals(event(CompanionEvent.Mac("unavailable", "aOS isn't running")), decode("""{"event":"mac","state":"unavailable","detail":"aOS isn't running"}"""))
        assertEquals(CompanionMessage.Ignored, decode("""{"event":"approval","agent":"x"}"""))
    }

    @Test fun unknownOrBrokenLines() {
        assertEquals(CompanionMessage.Ignored, decode("""{"event":"future.thing","x":1}"""))
        assertEquals(CompanionMessage.Ignored, decode("""{"event":"signin","request":"r"}"""))
        assertEquals(CompanionMessage.Ignored, decode("""{"something":"else"}"""))
        assertEquals("notJSON", assertFailsWith<CompanionMessage.DecodeException> { decode("hello") }.reason)
        assertEquals("notJSON", assertFailsWith<CompanionMessage.DecodeException> { decode("Last login: Tue Nov 18") }.reason)
        assertEquals("notAnObject", assertFailsWith<CompanionMessage.DecodeException> { decode("[1]") }.reason)
    }

    @Test fun lineSplitter() {
        val splitter = LineSplitter(limit = 16)
        assertEquals(emptyList(), splitter.append("{\"a\":".toByteArray()).map { String(it) })
        assertEquals(listOf("{\"a\":1}", "{\"b\":2}"), splitter.append("1}\r\n{\"b\":2}\n{".toByteArray()).map { String(it) })
        assertEquals(listOf("{}"), splitter.append("}\n".toByteArray()).map { String(it) })
        assertFailsWith<LineSplitter.LineTooLongException> { splitter.append(ByteArray(17) { 0x41 }) }
        // Lines up to 1 MiB by default
        val big = LineSplitter()
        val line = ByteArray(1 shl 20) { 0x41 }
        assertEquals(1, big.append(line + byteArrayOf(0x0A)).size)
    }

    @Test fun commands() {
        assertEquals("'/Applications/aOS.app/Contents/MacOS/aos-companion' serve", CompanionCommand.serve(CompanionCommand.DEFAULT_PATH))
        assertEquals("'/a b/it'\\''s/aos-companion' serve", CompanionCommand.serve("/a b/it's/aos-companion"))
    }
}

/** Signed requests (Docs/COMPANION.md, "Signed requests"): the text the phone signs is the one the Mac rebuilds. */
class SignedRequestTests {
    /** The same reference vector as the Mac's tests (AOSKit CompanionSignatureTests.testReferenceVector). */
    @Test fun referenceVector() {
        val request = CompanionRequest.SignInLogin("r1", "github.com", "2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5")
        val message = CompanionSignature.message(request.signatureFields("4853150ceae1", 1_793_966_400, "AAECAwQFBgcICQoLDA0ODw"))!!
        assertEquals("""
            aos-companion-v1
            op=signin.answer
            key=4853150ceae1
            ts=1793966400
            nonce=AAECAwQFBgcICQoLDA0ODw
            request=r1
            decision=login
            login=2c1f3b9e-58a0-4b8e-9a4b-b0e1a2c3d4e5
            host=github.com
            target=
            data=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """.trimIndent(), message.toString(Charsets.UTF_8))
        // Signed once with the private key 01 02 ... 20 on the Mac side; valid here too
        val publicKey = P256.publicKey(Bytes.base64Decode("BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q=")!!)!!
        val signature = Bytes.base64Decode("GFcC/pLIqdTnqSkGq/dgSPzvKwrS+An71RilVLIyBblhUdc88QPnXNY4gvOfxo7ZfiDf4tRnBoFjdtXUhA3AWg==")!!
        assertTrue(P256.verify(publicKey, message, signature))
        // And the key 01..20 is that public key
        val scalar = ByteArray(32) { (it + 1).toByte() }
        assertEquals("BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q=",
            Bytes.base64(P256.publicX963(scalar)))
        // A signature made here with that key checks out with the Mac's public key as well
        val ours = SoftwareP256Signer.fromScalar(scalar).sign(message)
        assertTrue(P256.verify(publicKey, message, ours))
    }

    @Test fun dataDigestsLikeTheMac() {
        assertEquals("7f8b51cc0836cd46dc9b0f4cf097aab22db8990f183b3d9b5a0ecf48ab1a6c1f", CompanionSignature.dataDigest(username = "max", password = "geheim"))
        assertEquals("5ea585c8aefd5374907cd0e73a2ce0bdf2218de624576cad57ae294e322d69f7", CompanionSignature.dataDigest(text = "Grüße 😀"))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", CompanionSignature.dataDigest())
    }

    @Test fun whatEachRequestSigns() {
        fun fields(r: CompanionRequest) = r.signatureFields("k", 1, "n")
        assertEquals("companion.status", fields(CompanionRequest.Status).op)
        assertEquals("companion.hello", fields(CompanionRequest.Hello("1", "d")).op)
        assertEquals("workspace", fields(CompanionRequest.Screen(ScreenTarget.WORKSPACE)).target)
        assertEquals("decline", fields(CompanionRequest.SignInDecline("r", "a.de")).decision)
        assertEquals(CompanionSignature.dataDigest(totp = "123456"), fields(CompanionRequest.SignInCode("r", "a.de", "123456")).data)
        // An empty code doesn't go out, so it isn't signed either
        assertEquals(CompanionSignature.dataDigest(username = "u", password = "p"), fields(CompanionRequest.SignInAnswer("r", "a.de", "u", "p", "")).data)
        assertEquals("deny", fields(CompanionRequest.ApprovalAnswer("a", false)).decision)
        assertEquals("companion.type", fields(CompanionRequest.Type("x")).op)
        assertEquals("done", fields(CompanionRequest.HelpDone("h")).decision)
        assertEquals("help.done", fields(CompanionRequest.HelpDone("h")).op)
    }

    @Test fun signedLinesCheckOutTheWayTheMacReadsThem() {
        val key = SoftwareP256Signer.generate()
        val signer = CompanionSigner("4853150ceae1", key)
        val requests = listOf(
            CompanionRequest.Hello("1", "d"), CompanionRequest.Status, CompanionRequest.Subscribe,
            CompanionRequest.Screen(ScreenTarget.MAC), CompanionRequest.Screen(ScreenTarget.WORKSPACE),
            CompanionRequest.Screen(ScreenTarget.WORKSPACE, "BFFcPW6545a5BNP+yn9U/c0MwemXvzddylFa0KbDtANfRTa+OlDzGPv5pUdZAqIhUCvvDVfgjFOyzApW8X2fk1Q="),
            CompanionRequest.SignInLogin("r", "a.de", "l"),
            CompanionRequest.SignInAnswer("r", "a.de", "max", "p\"w ü", "123456"),
            CompanionRequest.SignInAnswer("r", "a.de", "max", "pw", ""),
            CompanionRequest.SignInDecline("r", "a.de"), CompanionRequest.SignInCode("r", "a.de", "000111"),
            CompanionRequest.HelpDone("h"), CompanionRequest.ApprovalAnswer("a", true), CompanionRequest.Type("Grüße 😀"),
            CompanionRequest.Display(ScreenTarget.WORKSPACE, "reset"),
            CompanionRequest.Mac(MacAction.STATUS), CompanionRequest.Mac(MacAction.STAY_AWAKE, "lidClosed"),
            CompanionRequest.Mac(MacAction.CHATS_DELETE, "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e01"),
        )
        val publicKey = P256.publicKey(key.publicKeyX963)!!
        for (request in requests) {
            val line = request.line(1, signer.auth(request))
            val o = Json.parseObject(line)!!
            val auth = CompanionAuth.from(o["auth"])!!
            assertEquals("4853150ceae1", auth.key)
            assertEquals(22, auth.nonce.length)
            val rebuilt = MacSideSignature.fields(o["op"].str!!, o, auth)
            assertEquals(request.signatureFields(auth.key, auth.ts, auth.nonce), rebuilt, request.op)
            val message = CompanionSignature.message(rebuilt)!!
            assertTrue(P256.verify(publicKey, message, Bytes.base64Decode(auth.sig)!!), request.op)
        }
    }

    @Test fun lineBreaksCantBeSigned() {
        val signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate())
        assertFailsWith<CompanionUnsignableException> { signer.auth(CompanionRequest.HelpDone("a\nb")) }
        assertFailsWith<CompanionUnsignableException> { signer.auth(CompanionRequest.SignInLogin("r", "a.de\r", "l")) }
        // Free text is hashed, so a line break there is fine
        assertNotNull(signer.auth(CompanionRequest.Type("two\nlines")))
    }

    @Test fun authJson() {
        val auth = CompanionAuth("k", 5, "n", "s")
        assertEquals("""{"key":"k","nonce":"n","sig":"s","ts":5}""", Json.encode(auth.json))
        assertEquals(auth, CompanionAuth.from(auth.json))
        assertNull(CompanionAuth.from(JsonObject(mapOf("key" to JsonPrimitive("k")))))
    }
}
