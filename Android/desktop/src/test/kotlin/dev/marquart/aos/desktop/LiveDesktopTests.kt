package dev.marquart.aos.desktop

import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.desktop.connection.JmdnsDiscovery
import dev.marquart.aos.desktop.connection.PollingNetworkMonitor
import dev.marquart.aos.desktop.keys.FileKeys
import dev.marquart.aos.desktop.store.FileMacStore
import dev.marquart.aos.desktop.store.FileSettingsStore
import dev.marquart.aos.desktop.store.PlainSealer
import dev.marquart.aos.desktop.terminal.JediTermScreen
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.MemorySessionMemory
import dev.marquart.aos.waitUntil
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.swing.Swing
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The desktop app's stack against the real Mac side (README.md "Live check": a test sshd on 127.0.0.1:2222 and
 * `aosctl pair-test`): key files, file stores, JmDNS and the polling network monitor, pairing with aOS's real pairing
 * listener, the real `aos-companion`, and a held terminal session shown in JediTerm. Runs only with
 * -Paos.live.link=<link>. Prints what it saw, never a secret.
 */
class LiveDesktopTests {
    @Test fun pairAndUseTheRealMacFromTheDesktop() {
        val text = System.getProperty("aos.live.link").orEmpty()
        assumeTrue("no live link", text.isNotEmpty())
        val dir = Files.createTempDirectory("aos-live").toFile()
        val discovery = JmdnsDiscovery()
        val connector = SshConnector(discovery = discovery)
        val keys = FileKeys(java.io.File(dir, "keys"), PlainSealer)
        val network = PollingNetworkMonitor()
        val model = AppModel(keys, FileMacStore(java.io.File(dir, "macs.json")), FileSettingsStore(java.io.File(dir, "settings.json")),
            connector, PairingClient(discovery), network, NoTailnet, "aOS Desktop Live Test", "0.1.0-live")
        println("LIVE desktop phone id ${keys.sshKey().phoneId} (${keys.sshKey().storage})")
        var terminal: MacTerminal? = null
        var jedi: JediTermScreen? = null
        try {
            runBlocking {
                withTimeout(180_000) {
                    model.load()
                    val link = PairingLink.parse(text)
                    val mac = model.pair(link) { println("LIVE pairing step ${it.kind}") }
                    assertEquals(link.hostKeyFingerprint, mac.hostKeyFingerprint)
                    println("LIVE paired: user=${mac.user} host=${mac.lastHost}; stored ${FileMacStore(java.io.File(dir, "macs.json")).load().size} Mac")
                    val connection = model.connection.value!!
                    val settled = withTimeout(30_000) {
                        connection.companionState.first {
                            it == MacConnection.CompanionState.Ready || it is MacConnection.CompanionState.Unavailable ||
                                it == MacConnection.CompanionState.NeedsPairing
                        }
                    }
                    println("LIVE companion: $settled, connection: ${connection.state.value}")
                    waitUntil(30_000, "ssh") { connection.ssh.value?.isActive == true }

                    val t = MacTerminal(mac.id, mac.name, MemorySessionMemory(), Dispatchers.Swing, macConnection = { model.connection.value },
                        makeScreen = { events -> JediTermScreen(events, 13, dark = true).also { jedi = it } })
                    terminal = t
                    jedi!!.onResize = { c, r -> t.resized(c, r) }
                    suspend fun screen() = t.onTerminal { screenText() }
                    t.connect()
                    waitUntil(30_000, "attached") { t.phase.value == MacTerminal.Phase.Connected }
                    val id = t.holderId.value!!
                    t.resized(100, 30)
                    jedi!!.widget.ttyConnector.write("stty size; echo aos-desk-\$((6*7))\r")
                    waitUntil(15_000, "echo") { runBlocking { screen() }.contains("aos-desk-42") }
                    println("LIVE JediTerm shows the Mac's session $id; size line: ${screen().lines().firstOrNull { it.trim().matches(Regex("\\d+ \\d+")) }}")
                    t.send("sleep 2; echo away-\$((7*6))\r".toByteArray())
                    Thread.sleep(300)
                    connection.ssh.value!!.closeNow()
                    waitUntil(10_000, "reconnecting") { t.phase.value == MacTerminal.Phase.Reconnecting }
                    waitUntil(60_000, "attached again") { t.phase.value == MacTerminal.Phase.Connected }
                    waitUntil(15_000, "missed output") { runBlocking { screen() }.contains("away-42") }
                    assertEquals(1, screen().split("aos-desk-42").size - 1, "nothing came twice")
                    println("LIVE reattached with what it missed")
                    t.endSession()
                    waitUntil(15_000, "ended") { t.phase.value == MacTerminal.Phase.Ended }
                    assertTrue(model.connection.value!!.termSessions()!!.none { it.id == id })
                    println("LIVE ended")
                    model.unpair(mac)
                }
            }
        } finally {
            terminal?.close()
            jedi?.close()
            model.connection.value?.close()
            connector.shutdown()
            dir.deleteRecursively()
        }
    }
}
