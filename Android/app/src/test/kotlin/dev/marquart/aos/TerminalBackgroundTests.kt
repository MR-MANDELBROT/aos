package dev.marquart.aos

import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.keys.MemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.AppSettings
import dev.marquart.aos.store.MemoryMacStore
import dev.marquart.aos.store.MemorySettingsStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import kotlin.test.assertTrue

/** The app in the background with a terminal open: the foreground service holds the connection past the grace period
 *  (AppModel.holdsConnectionInBackground, set by TerminalController), and lets it go when the terminals close. */
class TerminalBackgroundTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    @Test fun anOpenTerminalKeepsTheConnectionInTheBackground() = runBlocking {
        val keys = MemoryKeys()
        val server = TestSshServer.start(keys.sshKey())
        val mac = PairedMac(name = "Test Mac", hosts = listOf("127.0.0.1"), sshPort = server.port, user = "max",
            hostKey = server.hostKeyLine, hostKeyFingerprint = server.hostKeyFingerprint)
        val model = AppModel(keys, MemoryMacStore(listOf(mac)), MemorySettingsStore(AppSettings(backgroundGraceSeconds = 1)),
            connector, PairingClient(), FixedNetworkMonitor(), NoTailnet, "Test Phone", "0.1.0",
            MacConnection.Timing(firstBackoffMillis = 200, maxBackoffMillis = 1000))
        try {
            withTimeout(40_000) {
                model.load()
                waitUntil(what = "connected") { model.connection.value?.ssh?.value?.isActive == true }
                var holding = true
                model.holdsConnectionInBackground = { holding }
                model.onBackground()
                // Well past the grace period: still connected while a terminal holds it.
                delay(2_500)
                assertTrue(model.connection.value?.ssh?.value?.isActive == true, "kept while a terminal is open")
                // The terminals closed: the connection goes at the next check (every 5 s).
                holding = false
                waitUntil(8_000, "let go") { model.connection.value?.ssh?.value == null }
                assertTrue(model.connectionState.value == MacConnection.State.Idle)
                // Back in the foreground it connects again.
                model.onForeground()
                waitUntil(what = "connected again") { model.connection.value?.ssh?.value?.isActive == true }
            }
        } finally {
            model.connection.value?.close()
            server.stop()
        }
    }
}
