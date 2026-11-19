package dev.marquart.aos

import dev.marquart.aos.companion.CompanionClient
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.companion.CompanionTransport
import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.core.BitwardenLogin
import dev.marquart.aos.core.BitwardenState
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionMessage
import dev.marquart.aos.core.CompanionRequest
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.Json
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.MacStayAwake
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SignInResult
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.core.int
import dev.marquart.aos.core.obj
import dev.marquart.aos.core.str
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Test
import java.time.Instant
import java.util.Collections
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A transport in between: what a program standing in for `aos-companion` on the Mac could do to the lines. */
class InterceptingTransport(
    private val inner: CompanionTransport,
    private val outgoing: (ByteArray) -> ByteArray = { it },
    private val incomingLine: (ByteArray) -> ByteArray = { it },
) : CompanionTransport {
    val answers: MutableList<String> = Collections.synchronizedList(mutableListOf())
    override suspend fun send(data: ByteArray) = inner.send(outgoing(data))
    override fun incoming(): Flow<ByteArray> = inner.incoming().map { chunk ->
        answers += chunk.toString(Charsets.UTF_8)
        incomingLine(chunk)
    }
    override suspend fun close() = inner.close()

    companion object {
        /** A JSON line changed as an object (the mock writes one whole line per chunk). */
        fun edit(line: ByteArray, change: (MutableMap<String, kotlinx.serialization.json.JsonElement>) -> Unit): ByteArray {
            val o = Json.parseObject(line.copyOf(line.size - 1)) ?: return line
            val map = o.toMutableMap()
            change(map)
            return Json.line(JsonObject(map))
        }
    }
}

private fun test(block: suspend () -> Unit) = runBlocking { withTimeout(30_000) { block() } }

/** iOS CompanionClientTests, MacStatusTests (against the mock), SealedScreenLoginTests, BitwardenSignInTests. */
class CompanionClientTests {
    private fun connected(server: MockCompanionServer = MockCompanionServer(keepsSecrets = true),
                          signer: CompanionSigner? = null): Pair<CompanionClient, MockCompanionServer> {
        val client = CompanionClient(server.makeTransport(), signer)
        client.start()
        return client to server
    }

    @Test fun helloStatusSubscribe() = test {
        val (client, server) = connected()
        val hello = client.hello("0.1.0", "Test Phone")
        assertEquals("Max’s MacBook Pro", hello.mac)
        assertEquals("0.2.0", hello.aos)
        assertTrue("mac.status" in hello.features && "term" in hello.features)
        val status = client.status()
        assertEquals("open", status.state.name)
        assertEquals("Claude Code", status.sessions.first().title)
        client.subscribe()
        assertTrue(server.isSubscribed)
        assertEquals(listOf("hello", "status", "subscribe"), server.received.map { it.op })
        assertEquals("Test Phone", server.received[0].fields["device"].str)
    }

    @Test fun requestsRunConcurrentlyAndMatchTheirIds() = test {
        val (client, server) = connected()
        val a = kotlinx.coroutines.coroutineScope {
            val mac = async { client.screen(ScreenTarget.MAC) }
            val workspace = async { client.screen(ScreenTarget.WORKSPACE) }
            val status = async { client.status() }
            Triple(mac.await(), workspace.await(), status.await())
        }
        assertEquals(ScreenEndpoint("127.0.0.1", 5900), a.first)
        assertEquals("aos", a.second.username)
        assertEquals("open", a.third.state.name)
        assertEquals(3, server.received.mapNotNull { it.fields["id"].int }.toSet().size)
    }

    @Test fun eventsArriveAfterSubscribe() = test {
        val (client, server) = connected()
        server.emit(CompanionEvent.Workspace(dev.marquart.aos.core.WorkspaceState.CLOSING)) // before subscribe: nothing
        client.subscribe()
        val request = SignInRequest("r1", "Claude Code", "www.amazon.de", "Rechnung", Instant.ofEpochSecond(1_800_000_000))
        val help = HelpRequest("h1", "Codex", "Captcha", HelpRequest.Region(1.0, 2.0, 3.0, 4.0))
        server.emit(CompanionEvent.SignIn(request))
        server.emit(CompanionEvent.Help(help))
        server.emit(CompanionEvent.SignInClosed("r1", SignInResult.FILLED))
        assertEquals(listOf(CompanionEvent.SignIn(request), CompanionEvent.Help(help), CompanionEvent.SignInClosed("r1", SignInResult.FILLED)),
            client.events.take(3).toList())
    }

    @Test fun theMockRoundTripsEveryEvent() {
        val events = listOf(
            CompanionEvent.SignIn(SignInRequest("r", "A", "h.de", "p", null, SignInRequest.Field.CODE,
                listOf(BitwardenLogin("b1", "GitHub", "max", true)), BitwardenState.UNLOCKED)),
            CompanionEvent.Approval(dev.marquart.aos.core.ApprovalRequest("a", "A", "p", 30, null)),
            CompanionEvent.ApprovalClosed("a", dev.marquart.aos.core.ApprovalResult.DECLINED),
            CompanionEvent.Mac("unavailable", "d"), CompanionEvent.Chats, CompanionEvent.SubscriptionEnded,
            CompanionEvent.Help(HelpRequest("h", "A", "p", HelpRequest.Region(10.0, 20.0, 30.5, 40.0))),
        )
        for (event in events) {
            val line = MockCompanionServer.line(event)
            assertEquals(CompanionMessage.Event(event), CompanionMessage.decode(line.copyOf(line.size - 1)))
        }
    }

    @Test fun signInAnswersDeclinesAndTheApprovedLogin() = test {
        val (client, server) = connected()
        client.answerSignIn("r1", "a.de", "max", "geheim", "123456")
        client.declineSignIn("r2", "a.de")
        client.helpDone("h1")
        client.answerSignIn("r3", "a.de", "b1")
        client.answerSignInCode("r4", "a.de", "654321")
        client.answerApproval("a1", true)
        client.type("Grüße")
        val r = server.received
        assertEquals("geheim", r[0].fields["password"].str)
        assertEquals("123456", r[0].fields["totp"].str)
        assertEquals(JsonPrimitive(true), r[1].fields["decline"])
        assertNull(r[1].fields["password"])
        assertEquals("help.done", r[2].op)
        assertEquals("b1", r[3].fields["login"].str)
        assertNull(r[3].fields["password"], "an approved Bitwarden login sends no password")
        assertEquals("654321", r[4].fields["totp"].str)
        assertNull(r[4].fields["username"])
        assertEquals(JsonPrimitive(true), r[5].fields["allowed"])
        assertEquals("Grüße", r[6].fields["text"].str)
    }

    @Test fun theDemoServerNeverKeepsPasswords() = test {
        val (client, server) = connected(MockCompanionServer(keepsSecrets = false))
        client.answerSignIn("r1", "a.de", "max", "geheim", null)
        assertEquals("•••", server.received[0].fields["password"].str)
    }

    @Test fun refusalsBecomeErrors() = test {
        val server = MockCompanionServer()
        server.update { it.refuse["help.done"] = "Der Arbeitsplatz ist geschlossen." }
        val (client, _) = connected(server)
        assertEquals(CompanionError.Refused("Der Arbeitsplatz ist geschlossen."), assertFailsWith<CompanionError.Refused> { client.helpDone("h") })
    }

    @Test fun aClosedConnectionFailsWaitingRequestsAndEndsEvents() = test {
        val (client, server) = connected()
        client.subscribe()
        server.disconnect()
        assertEquals(emptyList(), client.events.toList())
        assertFailsWith<CompanionError.Closed> { client.status() }
    }

    @Test fun requestsTimeOut() = test {
        val silent = object : CompanionTransport {
            override suspend fun send(data: ByteArray) {}
            override fun incoming(): Flow<ByteArray> = flow { awaitCancellation() }
            override suspend fun close() {}
        }
        val client = CompanionClient(silent)
        client.start()
        assertFailsWith<CompanionError.Timeout> { client.request(CompanionRequest.Status, 200) }
    }

    @Test fun linesThatArentJsonAreSkipped() = test {
        val toClient = Channel<ByteArray>(Channel.UNLIMITED)
        val scripted = object : CompanionTransport {
            override suspend fun send(data: ByteArray) {
                // answer id 1 after some shell noise, split across chunks
                toClient.send("Last login: today\n{\"id\":1,".toByteArray())
                toClient.send("\"ok\":true,\"mac\":\"M\",\"aos\":\"1\"}\n".toByteArray())
            }
            override fun incoming(): Flow<ByteArray> = toClient.receiveAsFlow()
            override suspend fun close() { toClient.close() }
        }
        val client = CompanionClient(scripted)
        client.start()
        assertEquals("M", client.hello("1", "d").mac)
    }

    @Test fun signedActionsAgainstTheMock() = test {
        val signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate())
        val server = MockCompanionServer(keepsSecrets = true)
        server.update { it.trustedPhone = MockCompanionServer.TrustedSigner(signer.phoneId, signer.key.publicKeyX963) }
        val (client, _) = connected(server, signer)
        assertEquals(MacStayAwake.LID_CLOSED, client.mac(MacAction.STATUS).status?.awake?.setting)
        assertEquals(MacStayAwake.LID_OPEN, client.mac(MacAction.STAY_AWAKE, "lidOpen").status?.awake?.setting)
        assertEquals("lidOpen", server.received.last().fields["text"].str)
        assertEquals(1.5, client.mac(MacAction.SLEEP).sleepsIn)
        assertEquals("off", client.mac(MacAction.DISPLAY_OFF).status?.display?.state)
        assertEquals("on", client.mac(MacAction.DISPLAY_ON).status?.display?.state)
        val chats = client.mac(MacAction.CHATS_LIST).chats!!
        assertTrue(chats.chats.isNotEmpty())
        server.update {
            it.refuse["workspace.start"] = "The workspace isn't set up yet."
            it.refuseCode["workspace.start"] = "not-set-up"
        }
        assertEquals(MacRefusal("not-set-up", "The workspace isn't set up yet."), assertFailsWith<MacRefusal> { client.mac(MacAction.WORKSPACE_START) })
        // Unsigned, or another phone: the Mac wants this phone paired again
        val (unsigned, _) = connected(server)
        assertFailsWith<CompanionError.PairAgain> { unsigned.mac(MacAction.STATUS) }
        assertFailsWith<CompanionError.PairAgain> { unsigned.status() }
        val (stranger, _) = connected(server, CompanionSigner("000000000000", SoftwareP256Signer.generate()))
        assertFailsWith<CompanionError.PairAgain> { stranger.helpDone("h1") }
        // The right id with a key the Mac doesn't have: refused, but not "pair again"
        val (impostor, _) = connected(server, CompanionSigner(signer.phoneId, SoftwareP256Signer.generate()))
        assertEquals("invalid", assertFailsWith<CompanionError.Refused> { impostor.answerApproval("a1", true) }.code)
    }

    @Test fun aChangedLineIsRefusedAndNoLineGoesThroughTwice() {
        val signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate())
        val server = MockCompanionServer(keepsSecrets = true)
        server.update { it.trustedPhone = MockCompanionServer.TrustedSigner(signer.phoneId, signer.key.publicKeyX963) }
        val request = CompanionRequest.SignInLogin("r1", "a.de", "l1")
        val line = request.line(1, signer.auth(request))
        val changed = line.toString(Charsets.UTF_8).replace("\"l1\"", "\"l2\"").toByteArray()
        assertContains(server.handle(changed)!!.toString(Charsets.UTF_8), "\"code\":\"invalid\"")
        assertContains(server.handle(line)!!.toString(Charsets.UTF_8), "\"ok\":true")
        assertContains(server.handle(line)!!.toString(Charsets.UTF_8), "\"ok\":false")
    }

    @Test fun helloSaysWhatTheMacOffers() = test {
        val server = MockCompanionServer(keepsSecrets = true)
        assertTrue("mac.status" in connected(server).first.hello("1", "d").features)
        server.update { it.oldMac = true }
        assertTrue(connected(server).first.hello("1", "d").features.isEmpty())
    }

    // The workspace's screen login, sealed (iOS SealedScreenLoginTests)

    private val login = ScreenEndpoint("192.168.64.5", 5900, "aos", "geheim")

    private fun signedMock(): Pair<MockCompanionServer, CompanionSigner> {
        val signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate())
        val server = MockCompanionServer(keepsSecrets = true)
        server.update {
            it.trustedPhone = MockCompanionServer.TrustedSigner(signer.phoneId, signer.key.publicKeyX963)
            it.screens[ScreenTarget.WORKSPACE] = login
        }
        return server to signer
    }

    @Test fun theSealedLoginRoundTrip() = test {
        val (server, signer) = signedMock()
        val transport = InterceptingTransport(server.makeTransport())
        val client = CompanionClient(transport, signer)
        client.start()
        assertEquals(login, client.workspaceLogin())
        val sent = server.received.last()
        assertEquals("screen", sent.op)
        assertEquals("workspace", sent.fields["target"].str)
        assertEquals(88, sent.fields["reply"].str?.length)
        val answer = transport.answers.last()
        assertContains(answer, "\"sealed\"")
        assertFalse(answer.contains("geheim") || answer.contains("192.168.64.5") || answer.contains("username"))
        // `screen(WORKSPACE)` is the same, with a new key each time
        assertEquals(login, client.screen(ScreenTarget.WORKSPACE))
        val keys = server.received.filter { it.op == "screen" }.mapNotNull { it.fields["reply"].str }
        assertEquals(2, keys.toSet().size)
        // The Mac's own screen stays as it was (no login, no key)
        assertEquals(ScreenEndpoint("127.0.0.1", 5900), client.screen(ScreenTarget.MAC))
        assertNull(server.received.last().fields["reply"])
    }

    @Test fun aSwappedKeyFailsTheSignature() = test {
        val (server, signer) = signedMock()
        val theirs = Bytes.base64(dev.marquart.aos.core.P256.x963(dev.marquart.aos.core.P256.generate().public))
        val transport = InterceptingTransport(server.makeTransport(), outgoing = { line ->
            InterceptingTransport.edit(line) { if (it["reply"] != null) it["reply"] = JsonPrimitive(theirs) }
        })
        val client = CompanionClient(transport, signer)
        client.start()
        assertFailsWith<CompanionError.Refused> { client.workspaceLogin() }
        assertTrue(transport.answers.last().contains("\"code\":\"invalid\""))
        assertTrue(transport.answers.none { it.contains("sealed") })
    }

    @Test fun aTamperedBoxDoesntOpen() = test {
        val (server, signer) = signedMock()
        val transport = InterceptingTransport(server.makeTransport(), incomingLine = { line ->
            InterceptingTransport.edit(line) { o ->
                val sealed = o["sealed"].obj ?: return@edit
                val box = Bytes.base64Decode(sealed["box"].str!!)!!
                box[box.size - 1] = (box[box.size - 1].toInt() xor 1).toByte()
                o["sealed"] = JsonObject(sealed + ("box" to JsonPrimitive(Bytes.base64(box))))
            }
        })
        val client = CompanionClient(transport, signer)
        client.start()
        assertFailsWith<CompanionError.InvalidAnswer> { client.workspaceLogin() }
    }

    @Test fun noPlaintextLoginIsTaken() = test {
        val (server, signer) = signedMock()
        val transport = InterceptingTransport(server.makeTransport(), incomingLine = { line ->
            InterceptingTransport.edit(line) { o ->
                if (o["sealed"] == null) return@edit
                o.remove("sealed")
                o["host"] = JsonPrimitive("192.168.64.5"); o["port"] = JsonPrimitive(5900)
                o["username"] = JsonPrimitive("aos"); o["password"] = JsonPrimitive("geheim")
            }
        })
        val client = CompanionClient(transport, signer)
        client.start()
        assertFailsWith<CompanionError.UpdateMac> { client.workspaceLogin() }
    }

    @Test fun aRequestWithALineBreakCantBeSigned() = test {
        val (client, _) = connected(signer = CompanionSigner("4853150ceae1", SoftwareP256Signer.generate()))
        assertFailsWith<CompanionError.Unsignable> { client.helpDone("a\nb") }
    }
}
