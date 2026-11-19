package dev.marquart.aos

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NetworkPath
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.core.str
import dev.marquart.aos.ssh.SshConnector
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import java.util.Collections
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Polls a condition (the connection's state machine runs on its own dispatcher). */
suspend fun waitUntil(timeoutMillis: Long = 10_000, what: String = "condition", condition: () -> Boolean) {
    val deadline = System.currentTimeMillis() + timeoutMillis
    while (!condition()) {
        if (System.currentTimeMillis() > deadline) throw AssertionError("$what not met within $timeoutMillis ms")
        delay(25)
    }
}

/** The connection to the Mac against the in-process SSH server and mock companion (iOS EndToEndTests' connection
 *  part, WorkspaceOperationTests' round with the Mac). */
class MacConnectionTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    private val key = testKey()
    private val signing = SoftwareP256Signer.generate()
    private val fast = MacConnection.Timing(heartbeatMillis = 500, firstBackoffMillis = 200, maxBackoffMillis = 1000,
        companionRetrySeconds = 1, pairAgainRetrySeconds = 2, sleepGraceMillis = 2000, operationPollMillis = 300, livedMillis = 60_000)

    private fun macFor(server: TestSshServer, hostKey: String = server.hostKeyLine) = PairedMac(name = "Test Mac",
        hosts = listOf("127.0.0.1"), sshPort = server.port, user = "max", hostKey = hostKey,
        hostKeyFingerprint = server.hostKeyFingerprint)

    private fun run(block: suspend (TestSshServer, MacConnection, MutableList<CompanionEvent>) -> Unit) {
        val companion = MockCompanionServer(keepsSecrets = true)
        companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner(key.phoneId, signing.publicKeyX963) }
        val server = TestSshServer.start(key, companion = companion)
        val connection = MacConnection(macFor(server), key, CompanionSigner(key.phoneId, signing), "Test Phone", "0.1.0",
            connector, FixedNetworkMonitor(), timing = fast)
        val events = Collections.synchronizedList(mutableListOf<CompanionEvent>())
        connection.onEvent = { events += it }
        try {
            runBlocking { withTimeout(60_000) { block(server, connection, events) } }
        } finally {
            connection.close()
            server.stop()
        }
    }

    @Test fun connectsWithThePinnedKeyAndRunsTheCompanion() = run { server, connection, events ->
        val changed = Collections.synchronizedList(mutableListOf<PairedMac>())
        connection.onMacChanged = { changed += it }
        connection.start()
        assertTrue(connection.awaitReady(15_000))
        assertEquals(MacConnection.State.Connected::class, connection.state.value::class)
        assertEquals("127.0.0.1", (connection.state.value as MacConnection.State.Connected).host)
        assertEquals("Max’s MacBook Pro", connection.hello.value?.mac)
        assertEquals("open", connection.workspace.value?.state?.name)
        // Hello, subscribe, status, in this order, all signed by this phone
        assertEquals(listOf("hello", "subscribe", "status"), server.companion.received.take(3).map { it.op })
        assertEquals("127.0.0.1", changed.single().lastHost)
        // Events reach the app model; the heartbeat keeps asking
        val request = SignInRequest("e2e", "Claude Code", "github.com", "Push")
        server.companion.emit(CompanionEvent.SignIn(request))
        waitUntil(what = "event") { events.contains(CompanionEvent.SignIn(request)) }
        waitUntil(what = "heartbeat") { server.companion.received.count { it.op == "status" } >= 2 }
        // The Mac app away for a moment, then back
        server.companion.emit(CompanionEvent.Mac("unavailable", "aOS isn't running"))
        waitUntil { connection.macAppProblem.value == "aOS isn't running" }
        server.companion.emit(CompanionEvent.Mac("available", ""))
        waitUntil { connection.macAppProblem.value == null }
        // Answers go through it
        connection.answerSignIn("e2e", "github.com", "max", "geheim", "123456")
        assertEquals("geheim", server.companion.received.last().fields["password"].str)
        assertEquals(ScreenEndpoint("192.168.64.5", 5900, "aos", "demo-only"), connection.screenEndpoint(ScreenTarget.WORKSPACE))
        // The Overview
        connection.refreshMacStatus()
        assertEquals("on", connection.macStatus.value?.display?.state)
        assertEquals("off", connection.perform(MacAction.DISPLAY_OFF).status?.display?.state)
        assertEquals("off", connection.macStatus.value?.display?.state)
        connection.refreshChats()
        assertNotNull(connection.chats.value)
        // The terminal's helpers
        assertEquals(listOf("0123abcd"), connection.termSessions()?.map { it.id })
        assertTrue(connection.endTermSession("0123abcd"))
    }

    @Test fun startingAndClosingTheWorkspaceStayUnderWayUntilTheMacIsDone() = run { server, connection, _ ->
        server.companion.update { it.workspaceStepMillis = 400 }
        connection.start()
        assertTrue(connection.awaitReady(15_000))
        connection.refreshMacStatus()
        assertEquals("open", connection.workspaceState)
        val seen = Collections.synchronizedList(mutableListOf<String>())
        connection.perform(MacAction.WORKSPACE_STOP)
        assertEquals("open", connection.reportedWorkspaceState, "the Mac's answer: the state before")
        waitUntil {
            connection.workspaceState?.let { if (seen.lastOrNull() != it) seen += it }
            connection.workspaceOperation.value == null
        }
        assertEquals(listOf("closing", "stopped"), seen.toList())
        assertNull(connection.workspaceTimeout.value)
        seen.clear()
        connection.perform(MacAction.WORKSPACE_START)
        assertEquals("starting", connection.workspaceState)
        waitUntil {
            connection.workspaceState?.let { if (seen.lastOrNull() != it) seen += it }
            connection.workspaceOperation.value == null
        }
        assertEquals(listOf("starting", "running"), seen.toList())
        // Refused: nothing under way
        server.companion.update { it.refuse["workspace.stop"] = "Not now." }
        assertFailsWith<MacRefusal> { connection.perform(MacAction.WORKSPACE_STOP) }
        assertNull(connection.workspaceOperation.value)
        assertEquals("running", connection.workspaceState)
    }

    @Test fun sleepClosesTheConnectionAndWaitsBeforeTryingAgain() = run { server, connection, _ ->
        connection.start()
        assertTrue(connection.awaitReady(15_000))
        val result = connection.perform(MacAction.SLEEP)
        assertEquals(1.5, result.sleepsIn)
        assertNotNull(connection.sleepingSince.value)
        // Closed 0.5 s after the Mac's 1.5 s; then no attempt during the grace (1 s here)
        waitUntil(what = "going to sleep") { (connection.state.value as? MacConnection.State.Unreachable)?.message == "The Mac is going to sleep." }
        // It "wakes": the next connection ends sleeping
        waitUntil(15_000, "awake again") { connection.isConnected && connection.sleepingSince.value == null }
    }

    @Test fun theMacForgettingThisPhoneMeansPairAgain() = run { server, connection, _ ->
        connection.start()
        assertTrue(connection.awaitReady(15_000))
        server.companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner("000000000000", signing.publicKeyX963) }
        server.companion.emit(CompanionEvent.SubscriptionEnded)
        waitUntil { connection.companionState.value == MacConnection.CompanionState.NeedsPairing }
    }

    @Test fun aChangedHostKeyNeedsThePerson() {
        val server = TestSshServer.start(key)
        val other = TestSshServer.start(key)
        val connection = MacConnection(macFor(server, hostKey = other.hostKeyLine), key, null, "Test Phone", "0.1.0", connector,
            FixedNetworkMonitor(), timing = fast)
        try {
            runBlocking {
                connection.start()
                waitUntil { connection.state.value is MacConnection.State.NeedsAttention }
                assertTrue((connection.state.value as MacConnection.State.NeedsAttention).message.contains("different computer"))
            }
        } finally {
            connection.close()
            server.stop()
            other.stop()
        }
    }

    @Test fun anUnreachableMacIsRetriedAndANetworkChangeTriesAtOnce() {
        val network = FixedNetworkMonitor()
        val mac = PairedMac(name = "Gone", hosts = listOf("127.0.0.1"), sshPort = freeLocalPort(), user = "max",
            hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8Rl2qwv75VjkzLHaW5OyZu4CaxGsZU2+cYoDrSFSrY",
            hostKeyFingerprint = "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ", way = "lan")
        val connection = MacConnection(mac, key, null, "Test Phone", "0.1.0", connector, network,
            timing = fast.copy(firstBackoffMillis = 60_000, maxBackoffMillis = 60_000))
        try {
            runBlocking {
                connection.start()
                waitUntil { connection.state.value is MacConnection.State.Unreachable }
                val first = connection.state.value as MacConnection.State.Unreachable
                assertTrue(first.message.contains("same network only"), first.message)
                assertNotNull(first.nextAttempt)
                // A new network: at once, not in a minute
                network.path.value = NetworkPath(true, "other wifi")
                waitUntil(5_000) { connection.state.value is MacConnection.State.Connecting || connection.state.value != first }
            }
        } finally {
            connection.close()
        }
    }

    @Test fun anOlderMacWithoutTheOverview() = run { server, connection, _ ->
        server.companion.update { it.oldMac = true }
        connection.start()
        assertTrue(connection.awaitReady(15_000))
        assertTrue(connection.macStatusUnsupported)
        assertTrue(!connection.chatsSupported)
        connection.refreshMacStatus()
        assertNull(connection.macStatus.value)
        assertIs<MacConnection.CompanionState.Ready>(connection.companionState.value)
    }
}
