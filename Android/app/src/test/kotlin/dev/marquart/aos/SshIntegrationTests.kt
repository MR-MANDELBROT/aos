package dev.marquart.aos

import dev.marquart.aos.companion.CompanionClient
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.companion.ExecTransport
import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.ResolvedService
import dev.marquart.aos.connection.ServiceDiscovery
import dev.marquart.aos.connection.TailnetConnection
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.P256Signer
import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.core.TermNote
import dev.marquart.aos.core.TermNoteFilter
import dev.marquart.aos.core.str
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.keys.KeyStorage
import dev.marquart.aos.ssh.HostKeyPolicy
import dev.marquart.aos.ssh.LocalForwarder
import dev.marquart.aos.ssh.SessionChannel
import dev.marquart.aos.ssh.SshConnectException
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.ssh.SshLogin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail

/** A signer that holds only a function, as a Keystore key does: the SSH library can't get at any private key. */
class HandleOnlySigner(private val inner: P256Signer = SoftwareP256Signer.generate()) : P256Signer {
    val signatures = AtomicInteger(0)
    override val publicKeyX963: ByteArray get() = inner.publicKeyX963
    override fun sign(message: ByteArray): ByteArray = inner.sign(message).also { signatures.incrementAndGet() }
}

fun testKey(signer: P256Signer = HandleOnlySigner()) = DeviceKey(signer, KeyStorage.MEMORY)

/** The SSH paths end to end against the in-process MINA server (iOS SSHIntegrationTests). */
class SshIntegrationTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    private val signer = HandleOnlySigner()
    private val key = testKey(signer)

    private fun withServer(allowed: DeviceKey? = key, companion: MockCompanionServer = MockCompanionServer(keepsSecrets = true),
                           block: suspend (TestSshServer) -> Unit) {
        val server = TestSshServer.start(allowed, companion = companion)
        try {
            runBlocking { withTimeout(60_000) { block(server) } }
        } finally {
            server.stop()
        }
    }

    @Test fun pairedLoginWithTheFingerprintFromTheCodeSignedByAHandleOnlyKey() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key),
            HostKeyPolicy.Fingerprint(server.hostKeyFingerprint))
        assertEquals("127.0.0.1", connection.host)
        assertEquals(server.hostKeyLine, connection.hostKey)
        assertEquals(server.hostKeyFingerprint, connection.hostKeyFingerprint)
        assertEquals("ssh-ed25519", connection.hostKeyType)
        assertTrue(signer.signatures.get() >= 1, "the login was signed through the phone's signer")
        connection.close()
    }

    @Test fun aDifferentHostKeyIsRefused() = withServer { server ->
        val other = "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ"
        val e = assertFailsWith<SshConnectException.HostKeyMismatch> {
            connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Fingerprint(other))
        }
        assertEquals(SshConnectException.HostKeyMismatch("127.0.0.1", server.hostKeyFingerprint), e)
        assertFailsWith<SshConnectException.HostKeyMismatch> {
            connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key),
                HostKeyPolicy.Pinned("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY"))
        }
        assertEquals(0, signer.signatures.get(), "nothing signed for a Mac that isn't the Mac")
    }

    @Test fun unknownHostsStopAtTheKey() = withServer { server ->
        val e = assertFailsWith<SshConnectException.UnknownHostKey> {
            connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.AskFirst)
        }
        assertEquals(server.hostKeyLine, e.key)
        assertEquals(server.hostKeyFingerprint, e.fingerprint)
        // Trusting it: the next connection pins it
        connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(e.key)).close()
    }

    @Test fun aKeyTheServerDoesntTakeFailsTheLogin() = withServer(allowed = testKey()) { server ->
        assertEquals(SshConnectException.AuthenticationFailed("127.0.0.1"), assertFailsWith<SshConnectException.AuthenticationFailed> {
            connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        })
        assertFailsWith<SshConnectException.AuthenticationFailed> {
            connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("root", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        }
    }

    @Test fun unreachableAddressesAreSkipped() = withServer { server ->
        val start = System.currentTimeMillis()
        // 192.0.2.1 is TEST-NET (never answers), "nonexistent.invalid" never resolves
        val connection = connector.connectHosts(listOf("192.0.2.1", "nonexistent.invalid", "127.0.0.1"), server.port,
            SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        assertEquals("127.0.0.1", connection.host)
        assertTrue(System.currentTimeMillis() - start < 5000)
        connection.close()
        val closed = freeLocalPort()
        val e = assertFailsWith<SshConnectException.Unreachable> {
            connector.connectHosts(listOf("127.0.0.1"), closed, SshLogin("max", key), HostKeyPolicy.AskFirst, perHostTimeoutMillis = 2000)
        }
        assertEquals(listOf("127.0.0.1"), e.failures.map { it.host })
    }

    @Test fun companionOverAnExecChannelWithSignedRequests() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val signing = SoftwareP256Signer.generate()
        val companionSigner = CompanionSigner(key.phoneId, signing)
        server.companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner(key.phoneId, signing.publicKeyX963) }
        val channel = connection.exec(CompanionCommand.serve(TestSshServer.COMPANION_PATH))
        val client = CompanionClient(ExecTransport(channel), companionSigner)
        client.start()
        assertEquals("Max’s MacBook Pro", client.hello("0.1.0", "Test").mac)
        assertEquals("open", client.status().state.name)
        client.subscribe()
        val request = SignInRequest("r9", "Claude Code", "github.com", "Push")
        server.companion.emit(CompanionEvent.SignIn(request))
        assertEquals(CompanionEvent.SignIn(request), client.events.first())
        client.answerSignIn("r9", "github.com", "max", "p@ss \"w\" ü", "000111")
        val answer = server.companion.received.last()
        assertEquals("p@ss \"w\" ü", answer.fields["password"].str)
        assertEquals(key.phoneId, answer.fields["auth"]?.let { (it as kotlinx.serialization.json.JsonObject)["key"] }.str)
        assertEquals(listOf("exec '/Applications/aOS.app/Contents/MacOS/aos-companion' serve"), server.events)
        client.close()
        connection.close()
    }

    @Test fun aMissingCompanionIsReportedAsNotInstalled() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val channel = connection.exec(CompanionCommand.serve("/nowhere/aos-companion"))
        val client = CompanionClient(ExecTransport(channel))
        client.start()
        val e = assertFailsWith<CompanionError.ChannelEnded> { client.hello("1", "d") }
        val exited = assertIs<SessionChannel.Failure.Exited>(e.failure)
        assertEquals(127, exited.status)
        assertContains(MacConnection.companionMessage(e), "isn't installed")
        connection.close()
    }

    @Test fun termListAndEndInExecChannels() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val list = TermAttach.sessions(connection.run(TermAttach.list(TestSshServer.COMPANION_PATH)))!!
        assertEquals(listOf("0123abcd"), list.map { it.id })
        assertEquals("{\"ok\":true}\n", connection.run(TermAttach.end(TestSshServer.COMPANION_PATH, "0123abcd")!!).toString(Charsets.UTF_8))
        connection.close()
    }

    @Test fun termAttachInAPseudoTerminalWithNotesAndResize() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val command = TermAttach.attach(TestSshServer.COMPANION_PATH, null, null, key.phoneId)
        val terminal = connection.terminal(command, columns = 80, rows = 24)
        val filter = TermNoteFilter()
        val notes = mutableListOf<TermNote>()
        val text = StringBuilder()
        terminal.output.first { chunk ->
            for (piece in filter.feed(chunk)) when (piece) {
                is TermNoteFilter.Piece.Note -> notes += piece.note
                is TermNoteFilter.Piece.Bytes -> text.append(piece.data.toString(Charsets.UTF_8))
            }
            text.endsWith("$ ")
        }
        assertEquals("0000aa01", (notes.single() as TermNote.Start).id)
        assertEquals("Welcome to the held shell\r\n$ ", text.toString())
        terminal.resize(120, 40)
        terminal.write("exit\r".toByteArray())
        terminal.output.collect { }
        assertContains(server.events, "pty-exec xterm-256color 80x24 $command")
        assertContains(server.events, "size 120x40")
        connection.close()
    }

    @Test fun shellInAPseudoTerminal() = withServer { server ->
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val shell = connection.shell(columns = 80, rows = 24)
        val seen = StringBuilder()
        shell.write("hello ü\r".toByteArray())
        shell.output.first { seen.append(it.toString(Charsets.UTF_8)); seen.contains("hello ü\r") }
        assertTrue(seen.startsWith("Welcome\r\n$ "))
        shell.resize(100, 30)
        shell.write("exit\r".toByteArray())
        shell.output.collect { }
        assertContains(server.events, "pty xterm-256color 80x24")
        assertContains(server.events, "shell")
        assertContains(server.events, "size 100x30")
        connection.close()
    }

    @Test fun theForwarderCarriesTcpThroughDirectTcpip() = withServer { server ->
        val echo = EchoTcpServer()
        val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        val forwarder = LocalForwarder(connection, "127.0.0.1", echo.port)
        val localPort = forwarder.start()
        try {
            repeat(2) { round ->
                Socket("127.0.0.1", localPort).use { socket ->
                    val message = "screen bytes $round ü".toByteArray()
                    socket.getOutputStream().write(message)
                    val back = ByteArray(message.size)
                    var read = 0
                    while (read < back.size) {
                        val n = socket.getInputStream().read(back, read, back.size - read)
                        if (n < 0) break
                        read += n
                    }
                    assertEquals(message.toString(Charsets.UTF_8), back.toString(Charsets.UTF_8))
                }
            }
            assertEquals(null, forwarder.lastError)
        } finally {
            forwarder.stop()
            echo.stop()
            connection.close()
        }
    }

    @Test fun theTailnetRouteCarriesSshThroughTheDialer() = withServer { server ->
        val dialer = object : TailnetDialer {
            val dials = AtomicInteger(0)
            override val isSetUp = true
            override val isRunning = true
            override val ready: Flow<Unit> = emptyFlow()
            override suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection {
                dials.incrementAndGet()
                // The test's "tailnet": a plain socket to the server (the real node hands over a socket pair's end)
                val socket = Socket("127.0.0.1", server.port)
                return object : TailnetConnection {
                    override val input: InputStream = socket.getInputStream()
                    override val output: OutputStream = socket.getOutputStream()
                    override fun close() = socket.close()
                }
            }
        }
        val tailnetConnector = SshConnector(tailnet = dialer)
        try {
            val connection = tailnetConnector.connect(listOf(SSHRoute.Tailnet("100.90.1.3")), 22, SshLogin("max", key),
                HostKeyPolicy.Pinned(server.hostKeyLine))
            assertEquals("100.90.1.3", connection.host)
            assertIs<SSHRoute.Tailnet>(connection.route)
            assertEquals(1, dialer.dials.get())
            assertEquals("{\"ok\":true}\n", connection.run(TermAttach.end(TestSshServer.COMPANION_PATH, "0123abcd")!!).toString(Charsets.UTF_8))
            connection.close()
        } finally {
            tailnetConnector.shutdown()
        }
        // Without a node the route fails, and a same-network route still wins
        val e = assertFailsWith<SshConnectException.Unreachable> {
            connector.connect(listOf(SSHRoute.Tailnet("100.90.1.3")), 22, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine))
        }
        assertEquals("100.90.1.3", e.failures.single().host)
    }

    @Test fun theBonjourRouteResolvesTheMacsName() = withServer { server ->
        val discovery = object : ServiceDiscovery {
            override suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean): ResolvedService? =
                if (type == "_ssh._tcp" && name == "Max’s MacBook Pro") ResolvedService(name, "127.0.0.1", server.port) else null
        }
        val bonjourConnector = SshConnector(discovery = discovery)
        try {
            val connection = bonjourConnector.connect(listOf(SSHRoute.Host("192.0.2.1"), SSHRoute.Bonjour("Max’s MacBook Pro")),
                22, SshLogin("max", key), HostKeyPolicy.Pinned(server.hostKeyLine), perHostTimeoutMillis = 3000, staggerMillis = 100)
            assertIs<SSHRoute.Bonjour>(connection.route)
            assertEquals("127.0.0.1", connection.address)
            connection.close()
        } finally {
            bonjourConnector.shutdown()
        }
    }

    @Test fun anUnreachableRaceNamesEveryHost() = runBlocking {
        val e = assertFailsWith<SshConnectException.Unreachable> {
            connector.connectHosts(listOf("nonexistent.invalid", "127.0.0.1"), freeLocalPort(), SshLogin("max", key),
                HostKeyPolicy.AskFirst, perHostTimeoutMillis = 2000, staggerMillis = 50)
        }
        assertEquals(setOf("nonexistent.invalid", "127.0.0.1"), e.failures.map { it.host }.toSet())
        if (e.failures.isEmpty()) fail("no failures")
    }
}
