package dev.marquart.aos

import dev.marquart.aos.connection.ResolvedService
import dev.marquart.aos.connection.ServiceDiscovery
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.PairingRequest
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.ssh.PairingClient
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** The pairing listener's exchange (iOS PairingClientTests). */
class PairingClientTests {
    private val code = ByteArray(16) { it.toByte() }
    private val key = SSHKeyFormat.openSSHP256(P256.x963(P256.generate().public))
    private val request = PairingRequest.make("Test Phone", key, P256.x963(P256.generate().public), code)

    private fun link(port: Int, hosts: List<String> = listOf("127.0.0.1")) = PairingLink("Test Mac", hosts, port, 22, "max",
        "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ", code)

    private fun test(block: suspend () -> Unit) = runBlocking { withTimeout(30_000) { block() } }

    @Test fun pairsWithAValidProof() = test {
        val listener = FakePairingListener(code, FakePairingListener.Behavior.Accept("max", "/x/aos-companion"))
        try {
            val result = PairingClient().send(request, link(listener.port))
            assertEquals("max", result.response.user)
            assertEquals("/x/aos-companion", result.response.companion)
            assertEquals("127.0.0.1", result.host)
            assertEquals(listOf(request), listener.requests.toList())
        } finally {
            listener.stop()
        }
    }

    @Test fun aWrongCodeIsRefused() = test {
        val listener = FakePairingListener(ByteArray(16) { 7 }, FakePairingListener.Behavior.Accept("max", "/x/aos-companion"))
        try {
            assertEquals(PairingClient.Failure.Refused("wrong proof"),
                assertFailsWith<PairingClient.Failure.Refused> { PairingClient().send(request, link(listener.port)) })
        } finally {
            listener.stop()
        }
    }

    @Test fun aChangedAnswerIsRejected() = test {
        val listener = FakePairingListener(code, FakePairingListener.Behavior.Tampered("max", "/x/aos-companion"))
        try {
            assertFailsWith<PairingClient.Failure.NotAuthentic> { PairingClient().send(request, link(listener.port)) }
        } finally {
            listener.stop()
        }
    }

    @Test fun aHangUpAndAClosedPort() = test {
        val hangUp = FakePairingListener(code, FakePairingListener.Behavior.HangUp)
        try {
            assertFailsWith<PairingClient.Failure.NoAnswer> { PairingClient().send(request, link(hangUp.port)) }
        } finally {
            hangUp.stop()
        }
        assertFailsWith<PairingClient.Failure.Unreachable> { PairingClient().send(request, link(freeLocalPort()), 2000) }
    }

    @Test fun theFirstHostThatAnswersWinsAndBonjourIsTheFallback() = test {
        val listener = FakePairingListener(code, FakePairingListener.Behavior.Accept("max", "/x/aos-companion"))
        try {
            // A dead first address doesn't hold pairing up
            val start = System.currentTimeMillis()
            val result = PairingClient().send(request, link(listener.port, listOf("192.0.2.1", "127.0.0.1")))
            assertEquals("127.0.0.1", result.host)
            assert(System.currentTimeMillis() - start < 4000)
            // None of the hosts answers: the listener found over NSD by the Mac's name
            val discovery = object : ServiceDiscovery {
                override suspend fun find(type: String, name: String?, timeoutMillis: Long, orOnlyOne: Boolean) =
                    if (type == "_aos-pair._tcp" && name == "Test Mac") ResolvedService("Test Mac", "127.0.0.1", listener.port) else null
            }
            val viaBonjour = PairingClient(discovery).send(request, link(freeLocalPort()), 2000)
            assertEquals("max", viaBonjour.response.user)
            assertEquals(2, listener.requests.size)
        } finally {
            listener.stop()
        }
    }

    @Test fun theProofThePhoneSendsIsTheOneTheMacChecks() {
        assertEquals(PairingRequest.proof(code, key, "Test Phone", request.sign), request.proof)
        assertEquals(65, Bytes.base64Decode(request.sign)!!.size)
    }
}
