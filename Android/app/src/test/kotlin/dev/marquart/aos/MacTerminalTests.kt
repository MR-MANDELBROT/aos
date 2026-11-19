package dev.marquart.aos

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.TermuxScreen
import dev.marquart.aos.terminal.MemorySessionMemory
import dev.marquart.aos.terminal.SessionMemory
import dev.marquart.aos.terminal.TerminalKey
import dev.marquart.aos.terminal.TerminalModifiers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Mac's terminal against the test SSH server's held sessions (iOS HeldTerminalTests): attaching, dropping and coming
 * back for what was missed, ending, this phone again, another device, new sessions and switching, the Mac asleep, and an
 * aOS that can't hold sessions or refuses one.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MacTerminalTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    private val key = testKey()
    private val signing = SoftwareP256Signer.generate()
    private val fast = MacConnection.Timing(heartbeatMillis = 500, firstBackoffMillis = 200, maxBackoffMillis = 1000,
        companionRetrySeconds = 1, pairAgainRetrySeconds = 2, sleepGraceMillis = 2000, operationPollMillis = 300, livedMillis = 60_000)

    /** The terminal's own thread, as the main thread is in the app. */
    private val main = Dispatchers.Default.limitedParallelism(1)

    private class Setup(val server: TestSshServer, val terms: FakeTermSessions, val connection: MacConnection, val mac: PairedMac)

    private fun run(block: suspend Setup.() -> Unit) {
        val companion = MockCompanionServer(keepsSecrets = true)
        companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner(key.phoneId, signing.publicKeyX963) }
        val terms = FakeTermSessions()
        val server = TestSshServer.start(key, companion = companion, terms = terms)
        val mac = PairedMac(name = "Test Mac", hosts = listOf("127.0.0.1"), sshPort = server.port, user = "max",
            hostKey = server.hostKeyLine, hostKeyFingerprint = server.hostKeyFingerprint)
        val connection = MacConnection(mac, key, CompanionSigner(key.phoneId, signing), "Test Phone", "0.1.0", connector,
            FixedNetworkMonitor(), timing = fast)
        try {
            runBlocking {
                withTimeout(60_000) {
                    connection.start()
                    waitUntil(what = "ssh") { connection.ssh.value?.isActive == true }
                    Setup(server, terms, connection, mac).block()
                }
            }
        } finally {
            connection.close()
            server.stop()
        }
    }

    private fun Setup.terminal(memory: SessionMemory = MemorySessionMemory(), macId: String = UUID.randomUUID().toString()) =
        MacTerminal(macId, "Test Mac", memory, main, macConnection = { connection }, makeScreen = ::TermuxScreen)

    private suspend fun MacTerminal.screen() = onTerminal { screenText() }

    /** A terminal attached to a new session. */
    private suspend fun Setup.attached(memory: SessionMemory = MemorySessionMemory()): MacTerminal {
        val t = terminal(memory)
        t.connect()
        waitUntil(what = "connected") { t.phase.value == MacTerminal.Phase.Connected }
        return t
    }

    private fun type(t: MacTerminal, text: String) = t.send(text.toByteArray())

    @Test fun attachDropComeBackAndEnd() = run {
        val t = attached()
        assertEquals(listOf("attach new"), terms.log)
        assertEquals(listOf<String?>(key.phoneId), terms.clients, "the phone names itself when it attaches")
        val id = assertNotNull(t.holderId.value)
        waitUntil(what = "welcome") { runBlocking { t.screen() }.contains("Welcome to the held shell") }

        type(t, "hi there")
        waitUntil(what = "echo") { runBlocking { t.screen() }.contains("hi there") }

        // The connection drops: the terminal says so, attaches again by itself and gets only what it missed.
        type(t, "drop\r")
        try {
            waitUntil(what = "second attach") { terms.log.size == 2 }
        } catch (e: AssertionError) {
            throw AssertionError("${e.message}: phase ${t.phase.value}, log ${terms.log}, screen ${t.screen()}")
        }
        val seen = "Welcome to the held shell\r\n$ hi there".toByteArray().size
        assertEquals("attach $id have $seen", terms.log.last())
        waitUntil(what = "while away") { t.phase.value == MacTerminal.Phase.Connected && runBlocking { t.screen() }.contains("while away") }
        val screen = t.screen()
        assertContains(screen, "hi there", message = "nothing was cleared")
        assertEquals(2, screen.split("Welcome").size, "nothing came twice")

        // Ending: the Mac ends the session, the terminal says why and forgets it.
        t.endSession()
        waitUntil(what = "ended") { t.phase.value == MacTerminal.Phase.Ended }
        assertEquals(MacTerminal.EndReason.ENDED, t.endReason.value)
        assertNull(t.holderId.value)
        assertContains(terms.log, "end $id")
    }

    @Test fun aRelaunchStartsAfreshInTheSameSession() = run {
        val memory = MemorySessionMemory()
        val macId = UUID.randomUUID().toString()
        val first = terminal(memory, macId)
        first.connect()
        waitUntil { first.phase.value == MacTerminal.Phase.Connected }
        type(first, "remember me")
        waitUntil { runBlocking { first.screen() }.contains("remember me") }
        val id = assertNotNull(first.holderId.value)
        first.disconnect()
        waitUntil(what = "idle") { first.phase.value == MacTerminal.Phase.Idle }

        // The app was closed: a new terminal knows the session and gets its screen back (afresh, without --have).
        val second = terminal(memory, macId)
        assertEquals(id, second.holderId.value)
        second.connect()
        waitUntil { second.phase.value == MacTerminal.Phase.Connected && runBlocking { second.screen() }.contains("remember me") }
        assertEquals("attach $id", terms.log.last())

        // Typing "exit": the shell ended, the next connect starts a new one.
        type(second, "exit\r")
        waitUntil { second.phase.value == MacTerminal.Phase.Ended }
        assertEquals(MacTerminal.EndReason.EXITED, second.endReason.value)
        assertNull(second.holderId.value)
        assertNull(memory.holderId(macId))
    }

    /** What an attach channel opened by hand gets (as the connection of an earlier launch of the app, or of another
     *  device). */
    private fun Setup.attachByHand(id: String, client: String?): ByteArrayOutputStream {
        val received = ByteArrayOutputStream()
        CoroutineScope(Dispatchers.IO).launch {
            val ssh = connection.ssh.value!!
            val channel = ssh.terminal(TermAttach.attach(TestSshServer.COMPANION_PATH, id, null, client), columns = 80, rows = 24)
            try {
                channel.output.collect { synchronized(received) { received.write(it) } }
            } catch (_: Exception) {
            }
        }
        return received
    }

    private fun ByteArrayOutputStream.text() = synchronized(this) { toString(Charsets.UTF_8) }

    @Test fun thisPhoneAgainIsNoOtherDevice() = run {
        val t = attached()
        val id = assertNotNull(t.holderId.value)

        // An older connection of this phone attaches (one that lingered from before): the terminal's own channel hears
        // "replaced", which is no reason to say "another device"; it attaches again and has the session.
        val lingering = attachByHand(id, key.phoneId)
        waitUntil(what = "two attaches") { terms.log.count { it.startsWith("attach $id") } == 2 }
        waitUntil(what = "connected again") { t.phase.value == MacTerminal.Phase.Connected }
        assertNotEquals(MacTerminal.EndReason.TAKEN, t.endReason.value)
        waitUntil(what = "replaced") { lingering.text().contains("\"why\":\"replaced\"") }
        assertFalse(lingering.text().contains("\"why\":\"taken\""))

        // The list says which device has it: this phone.
        val entry = assertNotNull(connection.termSessions()?.firstOrNull { it.id == id })
        assertEquals(key.phoneId, entry.client)
        assertEquals(dev.marquart.aos.core.MacTermSession.Holder.Here, entry.holder(null, key.phoneId, null))
        t.disconnect()
    }

    @Test fun anotherDeviceTakesTheSession() = run {
        val t = attached()
        val id = assertNotNull(t.holderId.value)
        attachByHand(id, "ipad-2")
        waitUntil(what = "taken") { t.phase.value == MacTerminal.Phase.Ended }
        assertEquals(MacTerminal.EndReason.TAKEN, t.endReason.value)
        assertEquals(id, t.holderId.value, "it keeps running on the Mac: Open It Here attaches again")
        t.connect()
        waitUntil { t.phase.value == MacTerminal.Phase.Connected }
        assertEquals(key.phoneId, terms.clients.last())
        t.disconnect()
    }

    @Test fun newSessionsAndSwitchingKeepTheOthersRunning() = run {
        val t = attached()
        val first = assertNotNull(t.holderId.value)
        type(t, "in the first")
        waitUntil { runBlocking { t.screen() }.contains("in the first") }

        // New Session: another shell on the Mac, the terminal shows it afresh.
        t.startNewSession()
        assertEquals(MacTerminal.Phase.Connecting, t.phase.value, "connecting at once: nothing starts a second one")
        waitUntil { t.phase.value == MacTerminal.Phase.Connected && t.holderId.value != first }
        val second = assertNotNull(t.holderId.value)
        assertEquals(2, terms.log.count { it == "attach new" })
        waitUntil { !runBlocking { t.screen() }.contains("in the first") }

        // Back to the first: it is still there, with its output.
        t.switchTo(first)
        waitUntil { t.phase.value == MacTerminal.Phase.Connected && t.holderId.value == first }
        waitUntil { runBlocking { t.screen() }.contains("in the first") }
        assertEquals(setOf(first, second), connection.termSessions()!!.map { it.id }.toSet())
        t.disconnect()
    }

    @Test fun onlyOneAttachAtATime() = run {
        val t = terminal()
        t.connect()
        t.connect()
        t.connect()
        waitUntil { t.phase.value == MacTerminal.Phase.Connected }
        delay(500)
        assertEquals(listOf("attach new"), terms.log, "a quick second tap doesn't start a second session")
        t.disconnect()
    }

    @Test fun anOlderAosGivesAPlainShellWithANote() = run {
        terms.attachFails = 2
        terms.failText = "usage: aos-companion serve | hello\n"
        val t = terminal()
        t.connect()
        waitUntil(what = "plain shell") { t.phase.value == MacTerminal.Phase.Connected && !t.holdsSession.value }
        assertEquals(MacTerminal.Notice.Kind.UPDATE_AOS, t.notice.value?.kind)
        assertContains(server.events, "shell")
        waitUntil { runBlocking { t.screen() }.contains("Welcome") }
        type(t, "plain")
        waitUntil { runBlocking { t.screen() }.contains("plain") }
        t.disconnect()
        waitUntil { t.phase.value == MacTerminal.Phase.Ended }
    }

    @Test fun aosNotWherePairedGivesAPlainShellWithANote() = run {
        terms.attachFails = 127
        terms.failText = "zsh:1: no such file or directory: /Applications/aOS.app/Contents/MacOS/aos-companion\n"
        val t = terminal()
        t.connect()
        waitUntil { t.phase.value == MacTerminal.Phase.Connected && !t.holdsSession.value }
        assertEquals(MacTerminal.Notice.Kind.AOS_MISSING, t.notice.value?.kind)
        t.disconnect()
    }

    @Test fun aRefusalIsShownAndNotRetried() = run {
        terms.attachFails = 1
        terms.failText = "aOS holds at most 16 terminal sessions. End one first.\n"
        val t = terminal()
        t.connect()
        waitUntil(what = "failed") { t.phase.value is MacTerminal.Phase.Failed }
        assertEquals("aOS holds at most 16 terminal sessions. End one first.", (t.phase.value as MacTerminal.Phase.Failed).message)
        delay(1500)
        assertEquals(listOf("attach refused"), terms.log, "not again and again")
    }

    @Test fun theSizeReachesTheMac() = run {
        val t = attached()
        assertTrue(server.events.any { it.startsWith("pty-exec xterm-256color 80x24") && it.contains("term attach") })
        t.resized(100, 30)
        waitUntil(what = "resized") { "size 100x30" in server.events }
        t.disconnect()
    }

    @Test fun theKeyBarsModifiersApplyToTheNextKeyAndTypedText() = run {
        val t = attached()
        // Control tapped: the next letter is a control code, the one after is plain.
        t.pressModifier(TerminalModifiers.CONTROL)
        t.releaseModifier(TerminalModifiers.CONTROL, cancelled = false)
        waitUntil { t.modifierStates.value[TerminalModifiers.CONTROL.bits] == dev.marquart.aos.terminal.StickyModifiers.State.ONCE }
        assertTrue(t.onTerminal { typed('c'.code, false) })
        assertFalse(t.onTerminal { typed('c'.code, false) }, "used up: the view sends it as it is")
        // Alt and an arrow from the key bar
        t.pressModifier(TerminalModifiers.ALT)
        t.releaseModifier(TerminalModifiers.ALT, cancelled = false)
        delay(100)
        t.sendKey(TerminalKey.Left)
        t.sendKey(TerminalKey.Tab, TerminalModifiers.SHIFT)
        waitUntil(what = "keys at the Mac") { terms.received.size >= 1 + 6 + 3 }
        assertEquals(listOf<Byte>(0x03) + "\u001b[1;3D\u001b[Z".toByteArray().toList(), terms.received.toList())
        t.disconnect()
    }

    @Test fun pasteAsksFirstOnlyWhenLinesWouldRun() = run {
        val t = attached()
        t.paste("ls\npwd")
        waitUntil { t.pendingPaste.value == "ls\npwd" }
        t.cancelPaste()
        t.paste("one line")
        delay(200)
        assertNull(t.pendingPaste.value)
        // The program asks for bracketed paste (the fake echoes it back to the terminal): no question then.
        type(t, "\u001b[?2004h")
        delay(300)
        t.paste("ls\npwd")
        waitUntil(what = "bracketed paste at the Mac") { terms.received.toString(Charsets.UTF_8).contains("\u001b[200~ls\npwd\u001b[201~") }
        assertNull(t.pendingPaste.value)
        t.disconnect()
    }

    @Test fun afterSleepTheTerminalWaitsAndSaysSo() = run {
        assertTrue(connection.awaitReady(15_000))
        val t = attached()
        connection.perform(MacAction.SLEEP)
        assertNotNull(connection.sleepingSince.value, "sleeping at once, not connected")
        // The Mac sleeps 1.5 s later: its connection is closed then (it would die without a word).
        waitUntil(5_000, "closed") { connection.ssh.value == null }
        waitUntil(what = "reconnecting") { t.phase.value == MacTerminal.Phase.Reconnecting }
        assertNotNull(connection.sleepingSince.value, "the screen says the Mac is sleeping")
        // It "wakes": the terminal attaches again by itself and continues where it was.
        waitUntil(20_000, "attached again") { t.phase.value == MacTerminal.Phase.Connected }
        val id = assertNotNull(t.holderId.value)
        assertTrue(terms.log.last().startsWith("attach $id have "))
        t.disconnect()
    }
}
