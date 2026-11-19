package dev.marquart.aos

import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.keys.MemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.LocalForwarder
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.AppSettings
import dev.marquart.aos.store.MemoryMacStore
import dev.marquart.aos.store.MemorySettingsStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.Socket
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Against the real Mac side: aOS's pairing listener (`aosctl pair-test` with a test sshd's own authorized_keys), that
 * sshd (OpenSSH), the real `aos-companion` and aOS. Runs only with `-Paos.live.link=<link>` (README.md, "Live check").
 * Prints what it saw, never a secret.
 */
class LiveMacTests {
    @Test fun pairAndUseTheRealMac() {
        val text = System.getProperty("aos.live.link").orEmpty()
        assumeTrue("no live link", text.isNotEmpty())
        val connector = SshConnector()
        val keys = MemoryKeys()
        val model = AppModel(keys, MemoryMacStore(), MemorySettingsStore(AppSettings(deviceName = "aOS Android Live Test")),
            connector, PairingClient(), FixedNetworkMonitor(), NoTailnet, "aOS Android Live Test", "0.1.0-live")
        println("LIVE phone id ${keys.sshKey().phoneId}")
        try {
            runBlocking {
                withTimeout(120_000) {
                    model.load()
                    val link = PairingLink.parse(text)
                    val mac = model.pair(link) { println("LIVE pairing step ${it.kind}") }
                    println("LIVE paired: user=${mac.user} companion=${mac.companionPath} host=${mac.lastHost} key=${mac.hostKey.substringBefore(' ')}")
                    assertEquals(link.hostKeyFingerprint, mac.hostKeyFingerprint)
                    val connection = model.connection.value!!
                    val settled = withTimeout(30_000) {
                        connection.companionState.first {
                            it == MacConnection.CompanionState.Ready || it is MacConnection.CompanionState.Unavailable ||
                                it == MacConnection.CompanionState.NeedsPairing
                        }
                    }
                    println("LIVE companion: $settled, connection: ${connection.state.value}")
                    if (settled == MacConnection.CompanionState.Ready) {
                        val hello = connection.hello.value!!
                        println("LIVE hello: mac=${hello.mac} aos=${hello.aos} features=${hello.features.sorted()}")
                        println("LIVE workspace: ${connection.workspace.value?.state?.name}")
                        if (MacAction.STATUS.raw in hello.features) {
                            connection.refreshMacStatus()
                            val status = connection.macStatus.value
                            println("LIVE mac.status: display=${status?.display?.state} lid=${status?.power?.lid} " +
                                "workspace=${status?.workspace?.state} session=${status?.session?.state} bitwarden=${status?.bitwarden?.state}")
                        }
                    }
                    val ssh = connection.ssh.value!!
                    // A terminal on the Mac, in the same SSH connection (OpenSSH's PTY, the login shell)
                    val shell = ssh.shell(columns = 80, rows = 24)
                    shell.write("echo aos-live-$((6*7))\n".toByteArray())
                    val seen = StringBuilder()
                    shell.output.first { seen.append(it.toString(Charsets.UTF_8)); seen.contains("aos-live-42") }
                    shell.close()
                    println("LIVE terminal ok")
                    // The Mac's terminal sessions through the real aos-companion (unsigned exec)
                    val sessions = connection.termSessions()
                    println("LIVE term list: ${sessions?.size ?: "unsupported"} sessions")
                    // direct-tcpip through OpenSSH: the Mac's own sshd banner on 127.0.0.1:22, through a LocalForwarder
                    val forwarder = LocalForwarder(ssh, "127.0.0.1", 22)
                    val port = forwarder.start()
                    val banner = Socket("127.0.0.1", port).use { s ->
                        s.soTimeout = 5000
                        val buffer = ByteArray(64)
                        val n = s.getInputStream().read(buffer)
                        String(buffer, 0, maxOf(n, 0), Charsets.US_ASCII).substringBefore('\r').substringBefore('\n')
                    }
                    forwarder.stop()
                    println("LIVE direct-tcpip banner: $banner")
                    assertTrue(banner.startsWith("SSH-2.0-"))
                    model.unpair(mac)
                }
            }
        } finally {
            model.connection.value?.close()
            connector.shutdown()
        }
    }
}
