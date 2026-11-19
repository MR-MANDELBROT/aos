package dev.marquart.aos.companion

import dev.marquart.aos.core.CompanionAuth
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionMessage
import dev.marquart.aos.core.CompanionRequest
import dev.marquart.aos.core.CompanionResponse
import dev.marquart.aos.core.CompanionSigner
import dev.marquart.aos.core.CompanionUnsignableException
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.HelloResult
import dev.marquart.aos.core.LineSplitter
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacActionResult
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenSeal
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.SealedLoginException
import dev.marquart.aos.core.WorkspaceStatus
import dev.marquart.aos.core.int
import dev.marquart.aos.ssh.SessionChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** The byte pipe the companion API runs over: the exec channel of `aos-companion serve`, or memory in tests. */
interface CompanionTransport {
    suspend fun send(data: ByteArray)

    /** What arrives, in chunks of any size. Collected once. */
    fun incoming(): Flow<ByteArray>
    suspend fun close()
}

/** The exec channel of `'<companion>' serve` as a transport. */
class ExecTransport(private val channel: SessionChannel) : CompanionTransport {
    override suspend fun send(data: ByteArray) = channel.write(data)
    override fun incoming(): Flow<ByteArray> = channel.output
    override suspend fun close() = channel.close()
}

/** What went wrong with a companion request (English; the UI words them itself). */
sealed class CompanionError(message: String) : Exception(message) {
    data object Closed : CompanionError("The connection to aOS on the Mac ended.")
    data object Timeout : CompanionError("aOS on the Mac didn't answer in time.")

    /** The Mac answered with `ok: false`. */
    data class Refused(val reason: String, val code: String? = null) : CompanionError(reason)
    data object InvalidAnswer : CompanionError("aOS on the Mac sent an answer this app doesn't understand.")

    /** The Mac has no signing key for this phone (removed on the Mac, or never paired with a signing key). */
    data object PairAgain : CompanionError("Pair again to keep approving from this phone.")

    /** The request has a value that can't be signed (a line break where none may be). */
    data object Unsignable : CompanionError("This request couldn't be signed.")

    /** The Mac answered the workspace's screen without sealing its login (aOS on the Mac is older). */
    data object UpdateMac : CompanionError("Update aOS on the Mac to see the workspace from this phone.")

    /** The connection ended because the exec channel failed (exit status 127: aOS isn't where it was paired). */
    data class ChannelEnded(val failure: Throwable) : CompanionError(failure.message ?: "The connection to aOS on the Mac ended.")
}

/**
 * The phone's side of the companion API (Docs/COMPANION.md, "Companion API"): requests with ids, answers matched to
 * them (20 s timeout by default), events as a flow. With a signer every request carries this phone's signature (the
 * Mac refuses requests without one). Thread-safe; requests may run concurrently.
 *
 * `start()` once, then the requests. `events` ends when the connection ends; the reason is `closedReason`.
 */
class CompanionClient(
    private val transport: CompanionTransport,
    private val signer: CompanionSigner? = null,
) {
    private val nextId = AtomicInteger(1)
    private val pending = ConcurrentHashMap<Int, CompletableDeferred<CompanionResponse>>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var readJob: Job? = null
    private val eventChannel = Channel<CompanionEvent>(Channel.UNLIMITED)

    @Volatile var closedReason: Throwable? = null
        private set

    /** Events from the Mac (after `subscribe`). One collector. Completes when the connection ends. */
    val events: Flow<CompanionEvent> = eventChannel.receiveAsFlow()

    val isClosed: Boolean get() = closedReason != null

    /** Starts reading. Call once, before the first request. */
    @Synchronized fun start() {
        if (readJob != null) return
        readJob = scope.launch { read() }
    }

    suspend fun close() {
        transport.close()
        finish(CompanionError.Closed)
        scope.cancel()
    }

    // Requests

    suspend fun hello(app: String, device: String): HelloResult = HelloResult.from(request(CompanionRequest.Hello(app, device)))

    suspend fun status(timeoutMillis: Long = DEFAULT_TIMEOUT): WorkspaceStatus =
        WorkspaceStatus.from(request(CompanionRequest.Status, timeoutMillis))

    suspend fun subscribe() {
        request(CompanionRequest.Subscribe)
    }

    /** Where a screen is: the Mac's own (no login), or the workspace's with its login (`workspaceLogin`). */
    suspend fun screen(target: ScreenTarget): ScreenEndpoint {
        if (target == ScreenTarget.WORKSPACE) return workspaceLogin()
        return ScreenEndpoint.from(request(CompanionRequest.Screen(target))) ?: throw CompanionError.InvalidAnswer
    }

    /**
     * The workspace's screen sharing login: address, port, account name and password. The Mac seals it to a P-256 key
     * made for this one request (in memory only until the answer is open; the signature covers it), so `aos-companion`
     * and whatever stands in for it sees only ciphertext (`ScreenSeal`). An answer without a sealed login is refused
     * (`UpdateMac`), never taken in plaintext; one that doesn't open is `InvalidAnswer`.
     */
    suspend fun workspaceLogin(): ScreenEndpoint {
        val oneTime = P256.generate()
        val request = CompanionRequest.Screen(ScreenTarget.WORKSPACE, Bytes.base64(P256.x963(oneTime.public)))
        val (response, auth) = send(request)
        return try {
            ScreenSeal.login(response, oneTime, request.signedOp, auth)
        } catch (_: SealedLoginException.UpdateMac) {
            throw CompanionError.UpdateMac
        } catch (_: SealedLoginException.InvalidAnswer) {
            throw CompanionError.InvalidAnswer
        }
    }

    /** Approves one of the request's Bitwarden logins. `host` is the request's website (signed; the Mac checks it). */
    suspend fun answerSignIn(request: String, host: String, login: String) {
        request(CompanionRequest.SignInLogin(request, host, login))
    }

    /** A sign-in from another password app. The values only pass through; nothing here keeps or logs them. */
    suspend fun answerSignIn(request: String, host: String, username: String, password: String, totp: String?) {
        request(CompanionRequest.SignInAnswer(request, host, username, password, totp))
    }

    suspend fun declineSignIn(request: String, host: String) {
        request(CompanionRequest.SignInDecline(request, host))
    }

    /** A one-time code for a request whose field is `code`. */
    suspend fun answerSignInCode(request: String, host: String, code: String) {
        request(CompanionRequest.SignInCode(request, host, code))
    }

    suspend fun helpDone(request: String) {
        request(CompanionRequest.HelpDone(request))
    }

    suspend fun answerApproval(request: String, allowed: Boolean) {
        request(CompanionRequest.ApprovalAnswer(request, allowed))
    }

    /** Types text into the running workspace. */
    suspend fun type(text: String) {
        request(CompanionRequest.Type(text), 60_000)
    }

    /** The workspace's display in a size ("WIDTHxHEIGHT@SCALE") or its own size back ("reset"); the size it got. */
    suspend fun display(size: String): Pair<Int, Int> {
        val response = request(CompanionRequest.Display(ScreenTarget.WORKSPACE, size), 10_000)
        return (response.body["width"].int ?: 0) to (response.body["height"].int ?: 0)
    }

    /** The Overview: the Mac's status, or an action. A refusal comes as `MacRefusal` with the Mac's code. */
    suspend fun mac(action: MacAction, value: String? = null): MacActionResult {
        val response = request(CompanionRequest.Mac(action, value), refusalsThrow = false)
        if (!response.ok) {
            if (response.code == "pair-again") throw CompanionError.PairAgain
            throw MacRefusal(response.code, response.error ?: "")
        }
        return MacActionResult.from(response)
    }

    /** Sends a request and waits for the answer with its id. `refusalsThrow = false` returns an `ok: false` answer. */
    suspend fun request(request: CompanionRequest, timeoutMillis: Long = DEFAULT_TIMEOUT,
                        refusalsThrow: Boolean = true): CompanionResponse = send(request, timeoutMillis, refusalsThrow).first

    /** Sends a request, waits for its answer; also returns the signature it went with. */
    private suspend fun send(request: CompanionRequest, timeoutMillis: Long = DEFAULT_TIMEOUT,
                             refusalsThrow: Boolean = true): Pair<CompanionResponse, CompanionAuth?> {
        closedReason?.let { throw it }
        val id = nextId.getAndIncrement()
        val auth = try {
            signer?.auth(request)
        } catch (_: CompanionUnsignableException) {
            throw CompanionError.Unsignable
        }
        val line = request.line(id, auth)
        val deferred = CompletableDeferred<CompanionResponse>()
        pending[id] = deferred
        closedReason?.let { pending.remove(id); throw it }
        val response = try {
            withTimeout(timeoutMillis) {
                try {
                    transport.send(line)
                } catch (e: Exception) {
                    // The channel is going away: the reader says why (an exit status) when it ends, within the timeout.
                    closedReason?.let { throw it }
                }
                deferred.await()
            }
        } catch (_: TimeoutCancellationException) {
            throw CompanionError.Timeout
        } finally {
            pending.remove(id)
        }
        if (!response.ok) {
            if (!refusalsThrow) return response to auth
            if (response.code == "pair-again") throw CompanionError.PairAgain
            throw CompanionError.Refused(response.error ?: "aOS on the Mac said no.", response.code)
        }
        return response to auth
    }

    // Reading

    private suspend fun read() {
        val splitter = LineSplitter()
        try {
            transport.incoming().collect { chunk ->
                for (line in splitter.append(chunk)) {
                    if (line.isEmpty()) continue
                    val message = try {
                        CompanionMessage.decode(line)
                    } catch (_: CompanionMessage.DecodeException) {
                        // Not JSON (a login message of the shell, for example): skipped, never logged.
                        continue
                    }
                    handle(message)
                }
            }
            finish(CompanionError.Closed)
        } catch (e: kotlinx.coroutines.CancellationException) {
            finish(CompanionError.Closed)
        } catch (e: Throwable) {
            finish(if (e is SessionChannel.Failure) CompanionError.ChannelEnded(e) else CompanionError.Closed)
        }
    }

    private fun handle(message: CompanionMessage) {
        when (message) {
            is CompanionMessage.Response -> pending.remove(message.response.id)?.complete(message.response)
            is CompanionMessage.Event -> eventChannel.trySend(message.event)
            CompanionMessage.Ignored -> Unit
        }
    }

    private fun finish(error: Throwable) {
        synchronized(this) {
            if (closedReason != null) return
            closedReason = error
        }
        for (deferred in pending.values) deferred.completeExceptionally(error)
        pending.clear()
        eventChannel.close()
    }

    companion object {
        const val DEFAULT_TIMEOUT = 20_000L
    }
}
