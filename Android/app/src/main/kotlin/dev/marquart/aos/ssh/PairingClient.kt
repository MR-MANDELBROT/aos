package dev.marquart.aos.ssh

import dev.marquart.aos.connection.NoDiscovery
import dev.marquart.aos.connection.ServiceDiscovery
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.PairingRequest
import dev.marquart.aos.core.PairingResponse
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket

/** Talks to the Mac's pairing listener: one JSON line out, one JSON line back (Docs/COMPANION.md, "Pairing"). */
class PairingClient(private val discovery: ServiceDiscovery = NoDiscovery) {
    sealed class Failure(message: String) : IOException(message) {
        /** No host of the pairing code answered on the pairing port. */
        data object Unreachable : Failure("The Mac didn't answer. Check that the phone is on the same network as the Mac and that the pairing code is still shown.")
        data object LocalNetworkDenied : Failure("aOS may not use the local network. Allow it in the app's settings, then try again.")

        /** The Mac closed the connection without answering (the code expired or was used). */
        data object NoAnswer : Failure("The Mac ended the pairing. Show a new pairing code on the Mac and scan it again.")
        data object InvalidAnswer : Failure("The Mac's answer wasn't understood. Update aOS on the Mac and on this phone.")

        /** The Mac said no, with its reason. */
        data class Refused(val reason: String) : Failure("The Mac refused the pairing: $reason")

        /** The answer wasn't signed with the code (changed on its way, or not from the Mac showing the code). */
        data object NotAuthentic : Failure("The answer didn't come from the Mac that shows this code. Pair again, on a network you trust.")
    }

    data class Result(val response: PairingResponse, val host: String)

    /**
     * Sends `request` to the first host of `link` that answers on the pairing port (all at once, a little apart; the
     * Mac's listener takes one pairing only, so the request goes out on one connection, the others close before
     * sending anything). If none answers, the listener is looked for over NSD (`_aos-pair._tcp`, a service named like
     * the Mac wins, otherwise the only one found). Returns the Mac's checked answer and the host that answered.
     */
    suspend fun send(request: PairingRequest, link: PairingLink, timeoutMillis: Long = 8000): Result {
        val line = request.line()
        var outcome = firstConnected(link.hosts.map { it to link.pairingPort }, timeoutMillis)
        var host = outcome.index?.let { link.hosts[it] } ?: link.hosts[0]
        if (outcome.socket == null && !outcome.denied) {
            val found = discovery.find(BONJOUR_PAIRING, link.macName, 3000, orOnlyOne = true)
            if (found != null) {
                outcome = firstConnected(listOf(found.host to found.port), timeoutMillis)
                host = link.hosts[0]
            }
        }
        val socket = outcome.socket ?: throw if (outcome.denied) Failure.LocalNetworkDenied else Failure.Unreachable
        val answer = socket.use { exchange(line, it, timeoutMillis) }
        if (answer.isEmpty()) throw Failure.NoAnswer
        return Result(decode(answer, link.code), host)
    }

    private class Outcome(val socket: Socket?, val index: Int?, val denied: Boolean)

    /** TCP to each endpoint, `staggerMillis` apart; the first that connects wins, the others are closed. */
    private suspend fun firstConnected(endpoints: List<Pair<String, Int>>, timeoutMillis: Long, staggerMillis: Long = 300): Outcome {
        if (endpoints.isEmpty()) return Outcome(null, null, false)
        val winner = CompletableDeferred<Outcome>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        var failures = 0
        var denied = false
        val lock = Any()
        try {
            endpoints.forEachIndexed { index, (host, port) ->
                scope.launch {
                    delay(staggerMillis * index)
                    if (winner.isCompleted) return@launch
                    val socket = Socket()
                    try {
                        runInterruptible { socket.connect(InetSocketAddress(host, port), timeoutMillis.toInt()) }
                        if (!winner.complete(Outcome(socket, index, false))) socket.close()
                    } catch (e: Throwable) {
                        try { socket.close() } catch (_: IOException) {}
                        val isDenied = (e.message ?: "").let { it.contains("EPERM") || it.contains("Operation not permitted") }
                        val all = synchronized(lock) {
                            failures++
                            denied = denied || isDenied
                            failures == endpoints.size
                        }
                        if (all) winner.complete(Outcome(null, null, synchronized(lock) { denied }))
                    }
                }
            }
            return withTimeoutOrNull(timeoutMillis + staggerMillis * endpoints.size) { winner.await() }
                ?: Outcome(null, null, synchronized(lock) { denied })
        } finally {
            scope.cancel()
        }
    }

    /** Sends the line and reads up to the first newline (or the end); empty when the Mac closed without a word. */
    private suspend fun exchange(line: ByteArray, socket: Socket, timeoutMillis: Long): ByteArray = withContext(Dispatchers.IO) {
        socket.soTimeout = (timeoutMillis + 2000).toInt()
        try {
            socket.getOutputStream().apply { write(line); flush() }
            val input = socket.getInputStream()
            val received = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (received.size() <= 64 * 1024) {
                val n = input.read(buffer)
                if (n < 0) break
                val newline = (0 until n).firstOrNull { buffer[it] == 0x0A.toByte() }
                if (newline != null) {
                    received.write(buffer, 0, newline)
                    break
                }
                received.write(buffer, 0, n)
            }
            received.toByteArray()
        } catch (_: java.net.SocketTimeoutException) {
            throw Failure.Unreachable
        } catch (e: IOException) {
            // A reset after the Mac closed: whatever came, else no answer.
            ByteArray(0)
        }
    }

    companion object {
        const val BONJOUR_PAIRING = "_aos-pair._tcp"

        fun decode(data: ByteArray, code: ByteArray): PairingResponse {
            val response = PairingResponse.parse(data) ?: throw Failure.InvalidAnswer
            if (!response.ok) throw Failure.Refused(response.error ?: "no reason given")
            if (!response.isAuthentic(code)) throw Failure.NotAuthentic
            return response
        }
    }
}
