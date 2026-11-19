package dev.marquart.aos.desktop

import dev.marquart.aos.FakeTermSessions
import dev.marquart.aos.TestSshServer
import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.desktop.terminal.JediTermScreen
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.MemorySessionMemory
import dev.marquart.aos.testKey
import dev.marquart.aos.waitUntil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.swing.Swing
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

/** The Mac's terminal with JediTerm as its screen, against the in-process SSH server's held sessions. */
class DesktopTerminalTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    @Test fun jediTermShowsTheSessionAndComesBackAfterADrop() {
        val key = testKey()
        val signing = SoftwareP256Signer.generate()
        val companion = MockCompanionServer(keepsSecrets = true)
        companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner(key.phoneId, signing.publicKeyX963) }
        val terms = FakeTermSessions()
        val server = TestSshServer.start(key, companion = companion, terms = terms)
        val mac = PairedMac(name = "Test Mac", hosts = listOf("127.0.0.1"), sshPort = server.port, user = "max",
            hostKey = server.hostKeyLine, hostKeyFingerprint = server.hostKeyFingerprint)
        val connection = MacConnection(mac, key, CompanionSigner(key.phoneId, signing), "Test PC", "0.1.0", connector, FixedNetworkMonitor(),
            timing = MacConnection.Timing(heartbeatMillis = 500, firstBackoffMillis = 200, maxBackoffMillis = 1000))
        try {
            runBlocking {
                withTimeout(60_000) {
                    connection.start()
                    waitUntil(what = "ssh") { connection.ssh.value?.isActive == true }
                    lateinit var jedi: JediTermScreen
                    val t = MacTerminal(mac.id, mac.name, MemorySessionMemory(), Dispatchers.Swing, macConnection = { connection },
                        makeScreen = { events -> JediTermScreen(events, 13, dark = true).also { jedi = it } })
                    jedi.onResize = { c, r -> t.resized(c, r) }
                    t.connect()
                    waitUntil(what = "connected") { t.phase.value == MacTerminal.Phase.Connected }
                    waitUntil(what = "welcome") { runBlocking { t.onTerminal { screenText() } }.contains("Welcome to the held shell") }
                    // Typing goes from JediTerm's connector to the Mac (as the widget would send it).
                    jedi.widget.ttyConnector.write("hi jediterm")
                    waitUntil(what = "echo") { runBlocking { t.onTerminal { screenText() } }.contains("hi jediterm") }
                    jedi.widget.ttyConnector.write("drop\r")
                    waitUntil(what = "again") { terms.log.size == 2 }
                    waitUntil(what = "while away") { runBlocking { t.onTerminal { screenText() } }.contains("while away") }
                    val screen = t.onTerminal { screenText() }
                    assertContains(screen, "hi jediterm")
                    assertEquals(2, screen.split("Welcome").size, "nothing came twice")
                    t.close()
                    jedi.close()
                }
            }
        } finally {
            connection.close()
            server.stop()
        }
    }
}
