package dev.marquart.aos

import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.keys.MemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.AppSettings
import dev.marquart.aos.store.MemoryMacStore
import dev.marquart.aos.store.MemorySettingsStore
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.TermuxScreen
import dev.marquart.aos.terminal.MemorySessionMemory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The terminal against the real Mac side (README.md, "Live check"): a session of the real `aos-companion term attach`
 * through a test sshd, the connection dropping and the terminal getting what it missed, ending the session. Runs only
 * with `-Paos.live.link=<link>`; leaves no session behind.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LiveTerminalTests {
    @Test fun aRealHeldSession() {
        val text = System.getProperty("aos.live.link").orEmpty()
        assumeTrue("no live link", text.isNotEmpty())
        val connector = SshConnector()
        val keys = MemoryKeys()
        val model = AppModel(keys, MemoryMacStore(), MemorySettingsStore(AppSettings(deviceName = "aOS Android Live Test")),
            connector, PairingClient(), FixedNetworkMonitor(), NoTailnet, "aOS Android Live Test", "0.1.0-live")
        val main = Dispatchers.Default.limitedParallelism(1)
        var terminal: MacTerminal? = null
        try {
            runBlocking {
                withTimeout(120_000) {
                    model.load()
                    val mac = model.pair(PairingLink.parse(text))
                    val connection = model.connection.value!!
                    waitUntil(30_000, "ssh") { connection.ssh.value?.isActive == true }
                    val t = MacTerminal(mac.id, mac.name, MemorySessionMemory(), main, macConnection = { model.connection.value }, makeScreen = ::TermuxScreen)
                    terminal = t
                    suspend fun screen() = t.onTerminal { screenText() }
                    t.connect()
                    waitUntil(30_000, "attached") { t.phase.value == MacTerminal.Phase.Connected }
                    val id = t.holderId.value!!
                    println("LIVE term attach: session $id")
                    t.resized(100, 30)
                    t.send("stty size; echo aos-term-\$((6*7))\r".toByteArray())
                    waitUntil(15_000, "echo") { runBlocking { screen() }.contains("aos-term-42") }
                    assertTrue(screen().contains("30 100"), "the size reached the Mac: ${screen()}")
                    println("LIVE echo and size ok")

                    // Output while the connection is gone, then the connection drops: the terminal attaches again with
                    // --have and gets exactly what it missed.
                    t.send("sleep 2; echo while-away-\$((7*6))\r".toByteArray())
                    Thread.sleep(300)
                    connection.ssh.value!!.closeNow()
                    waitUntil(10_000, "reconnecting") { t.phase.value == MacTerminal.Phase.Reconnecting }
                    println("LIVE dropped; reconnecting")
                    waitUntil(60_000, "attached again") { t.phase.value == MacTerminal.Phase.Connected }
                    waitUntil(15_000, "missed output") { runBlocking { screen() }.contains("while-away-42") }
                    val after = screen()
                    assertEquals(1, after.split("aos-term-42").size - 1, "nothing came twice: $after")
                    assertEquals(id, t.holderId.value)
                    println("LIVE reattached to the same session with what it missed")

                    val listed = model.connection.value!!.termSessions()!!.first { it.id == id }
                    assertEquals(keys.sshKey().phoneId, listed.client)
                    println("LIVE term list: attached=${listed.attached} client is this phone, command=${listed.command}")

                    t.endSession()
                    waitUntil(15_000, "ended") { t.phase.value == MacTerminal.Phase.Ended }
                    assertTrue(model.connection.value!!.termSessions()!!.none { it.id == id })
                    println("LIVE ended: ${t.endReason.value}")
                    model.unpair(mac)
                }
            }
        } finally {
            terminal?.close()
            model.connection.value?.close()
            connector.shutdown()
        }
    }
}
