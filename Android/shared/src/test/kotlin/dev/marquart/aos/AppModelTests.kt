package dev.marquart.aos

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.connection.FixedNetworkMonitor
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.core.ApprovalRequest
import dev.marquart.aos.core.ApprovalResult
import dev.marquart.aos.core.BitwardenLogin
import dev.marquart.aos.core.BitwardenState
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.core.SignInResult
import dev.marquart.aos.core.str
import dev.marquart.aos.keys.MemoryKeys
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.store.MemoryMacStore
import dev.marquart.aos.store.MemorySettingsStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The app's state: the question queue (iOS RequestQueueTests, ApprovalQueueTests) and the whole flow from pairing to
 *  an answer (iOS EndToEndTests without the screen). */
class AppModelTests {
    companion object {
        val connector = SshConnector()

        @JvmStatic @AfterClass fun shutdown() = connector.shutdown()
    }

    private val keys = MemoryKeys()
    private val macStore = MemoryMacStore()

    private fun model() = AppModel(keys, macStore, MemorySettingsStore(), connector, PairingClient(), FixedNetworkMonitor(),
        NoTailnet, "Test Phone", "0.1.0", MacConnection.Timing(firstBackoffMillis = 200, maxBackoffMillis = 1000))

    private fun request(id: String) = SignInRequest(id, "Claude Code", "www.amazon.de", "x", Instant.now().plusSeconds(300))

    @Test fun laterKeepsARequestWaitingWithoutPoppingUpAgain() = runBlocking {
        val model = model()
        model.handle(CompanionEvent.SignIn(request("r1")))
        assertEquals("r1", model.presentedSignIn?.id)
        model.closeQuestionSheet() // "Later"
        delay(700)
        assertNull(model.presentedSignIn)
        assertEquals(listOf("r1"), model.signIns.map { it.id })
        // A new request comes up, the one put off doesn't
        model.handle(CompanionEvent.SignIn(request("r2")))
        assertEquals("r2", model.presentedSignIn?.id)
        model.handle(CompanionEvent.SignIn(request("r2"))) // the same event twice: once
        assertEquals(listOf("r1", "r2"), model.signIns.map { it.id })
        // The Mac closes r2: the sheet shows the result, then closes; r1 stays put off
        model.handle(CompanionEvent.SignInClosed("r2", SignInResult.FILLED))
        assertEquals(SignInResult.FILLED, model.signInResults.value["r2"])
        delay(2300)
        assertNull(model.presentedSignIn)
        assertEquals(listOf("r1"), model.signIns.map { it.id })
    }

    @Test fun aRequestThatComesAgainIsUpdatedNotShownAgain() = runBlocking {
        val model = model()
        val locked = request("r1").copy(bitwarden = BitwardenState.LOCKED)
        model.handle(CompanionEvent.SignIn(locked))
        assertEquals(BitwardenState.LOCKED, model.presentedSignIn?.bitwarden)
        model.closeQuestionSheet()
        delay(600)
        // Bitwarden was unlocked on the Mac: the same request comes with its logins
        val unlocked = locked.copy(bitwarden = BitwardenState.UNLOCKED, logins = listOf(BitwardenLogin("b1", "Amazon", "max", false)))
        model.handle(CompanionEvent.SignIn(unlocked))
        assertEquals(listOf(unlocked), model.signIns)
        assertNull(model.presentedSignIn, "still put off")
        model.present(AppModel.Question.SignIn(unlocked))
        model.handle(CompanionEvent.SignIn(locked)) // and back: the open sheet follows
        assertEquals(locked, model.presentedSignIn)
    }

    @Test fun approvalsQueueWithSignIns() = runBlocking {
        val model = model()
        val signIn = SignInRequest("s1", "Claude Code", "a.de", "")
        val approval = ApprovalRequest("a1", "Codex", "Rechnungen", 15)
        model.handle(CompanionEvent.SignIn(signIn))
        model.handle(CompanionEvent.Approval(approval))
        assertEquals(AppModel.Question.SignIn(signIn), model.presentedQuestion.value)
        assertEquals(2, model.waitingCount)
        // Answered elsewhere: the sign-in closes, the approval comes up next
        model.handle(CompanionEvent.SignInClosed("s1", SignInResult.DECLINED))
        delay(2300)
        assertEquals(AppModel.Question.Approval(approval), model.presentedQuestion.value)
        model.handle(CompanionEvent.ApprovalClosed("a1", ApprovalResult.ALLOWED))
        assertEquals(ApprovalResult.ALLOWED, model.approvalResults.value["a1"])
        assertTrue(model.approvals.isEmpty())
        // After a new subscribe the Mac sends the open questions again: each is shown once
        val next = ApprovalRequest("a2", "Codex", "")
        model.handle(CompanionEvent.Approval(next))
        model.handle(CompanionEvent.Approval(next))
        assertEquals(listOf(next), model.approvals)
    }

    @Test fun helpRequestsOpenTheScreenWithoutConnecting() = runBlocking {
        val model = model()
        val help = HelpRequest("h1", "Codex", "Captcha")
        model.handle(CompanionEvent.Help(help))
        model.handle(CompanionEvent.Help(help))
        assertEquals(listOf(help), model.helpRequests.value)
        assertEquals(help, model.activeHelp.value)
        model.handle(CompanionEvent.HelpClosed("h1"))
        assertTrue(model.helpRequests.value.isEmpty())
        assertNull(model.activeHelp.value)
    }

    @Test fun pairServeAnswerAndUnpair() {
        val companion = MockCompanionServer(keepsSecrets = true)
        val key = keys.sshKey()
        val server = TestSshServer.start(key, companion = companion)
        val code = ByteArray(16) { (it * 7 + 3).toByte() }
        val listener = FakePairingListener(code, FakePairingListener.Behavior.Accept("max", TestSshServer.COMPANION_PATH))
        val model = model()
        // The Mac checks every companion request against the signing key it got at pairing
        companion.update { it.trustedPhone = MockCompanionServer.TrustedSigner(key.phoneId, keys.companionKey().publicKeyX963) }
        try {
            runBlocking {
                withTimeout(60_000) {
                    model.load()
                    val link = PairingLink("Test Mac", listOf("192.0.2.1", "127.0.0.1"), listener.port, server.port, "max",
                        server.hostKeyFingerprint, code)
                    val steps = mutableListOf<AppModel.PairingStepKind>()
                    val started = System.currentTimeMillis()
                    val mac = model.pair(link) { steps += it.kind }
                    assertTrue(System.currentTimeMillis() - started < 6000, "the dead first address doesn't hold pairing up")
                    assertEquals(listOf(AppModel.PairingStepKind.CONTACTING_MAC, AppModel.PairingStepKind.CHECKING_KEY,
                        AppModel.PairingStepKind.DONE), steps)
                    val sent = listener.requests.single()
                    assertEquals(key.openSSHPublicKey, sent.key)
                    assertEquals(java.util.Base64.getEncoder().encodeToString(keys.companionKey().publicKeyX963), sent.sign)
                    assertEquals("Test Phone", sent.device)
                    assertEquals(server.hostKeyLine, mac.hostKey)
                    assertEquals("127.0.0.1", mac.lastHost)
                    assertEquals(listOf(mac.id), macStore.macs.map { it.id })

                    // The model connects by itself (pinned key) and starts the companion
                    val connection = model.connection.value!!
                    assertTrue(connection.awaitReady(20_000))
                    waitUntil { model.connectionState.value is MacConnection.State.Connected }

                    // A sign-in request comes up as the sheet; the answer reaches the Mac
                    companion.emit(CompanionEvent.SignIn(SignInRequest("e2e", "Claude Code", "github.com", "Push", Instant.now().plusSeconds(120))))
                    waitUntil { model.presentedSignIn?.id == "e2e" }
                    connection.answerSignIn("e2e", "github.com", "b1")
                    assertEquals("b1", companion.received.last().fields["login"].str)
                    companion.emit(CompanionEvent.SignInClosed("e2e", SignInResult.FILLED))
                    waitUntil { model.signInResults.value["e2e"] == SignInResult.FILLED }

                    // Opening the workspace needs the person
                    companion.emit(CompanionEvent.Approval(ApprovalRequest("e2e-open", "Codex", "Rechnungen", 15)))
                    waitUntil { model.approvals.any { it.id == "e2e-open" } }
                    connection.answerApproval("e2e-open", true)
                    assertEquals("approval.answer", companion.received.last().op)

                    // Unpairing forgets the Mac
                    model.unpair(mac)
                    assertTrue(macStore.macs.isEmpty())
                    assertNull(model.connection.value)
                }
            }
        } finally {
            model.connection.value?.close()
            listener.stop()
            server.stop()
        }
    }
}
