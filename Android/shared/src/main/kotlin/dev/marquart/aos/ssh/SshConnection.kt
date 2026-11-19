package dev.marquart.aos.ssh

import dev.marquart.aos.connection.NoDiscovery
import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.connection.ServiceDiscovery
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.keys.DeviceKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.apache.sshd.client.SshClient
import org.apache.sshd.client.config.hosts.HostConfigEntryResolver
import org.apache.sshd.client.future.ConnectFuture
import org.apache.sshd.client.keyverifier.ServerKeyVerifier
import org.apache.sshd.client.session.ClientSession
import org.apache.sshd.common.AttributeRepository
import org.apache.sshd.common.NamedFactory
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.future.SshFuture
import org.apache.sshd.common.keyprovider.KeyIdentityProvider
import org.apache.sshd.common.signature.BuiltinSignatures
import org.apache.sshd.common.signature.Signature
import org.apache.sshd.core.CoreModuleProperties
import org.apache.sshd.client.auth.pubkey.UserAuthPublicKeyFactory
import java.io.IOException
import java.security.PublicKey
import java.time.Duration
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/** How the server's host key is checked. */
sealed class HostKeyPolicy {
    /** Pairing: the key must have this fingerprint (`SHA256:...` from the QR code). */
    data class Fingerprint(val fingerprint: String) : HostKeyPolicy()

    /** A key pinned earlier (OpenSSH public key line). */
    data class Pinned(val openSSHKey: String) : HostKeyPolicy()

    /** Nothing known yet: the connection stops at the key and reports it (`SshConnectException.UnknownHostKey`). */
    data object AskFirst : HostKeyPolicy()
}

/** Who logs in: this phone's key (the only login the Mac knows for it). */
data class SshLogin(val username: String, val key: DeviceKey)

/** Why connecting failed. */
sealed class SshConnectException(message: String) : IOException(message) {
    /** The server presented another key than expected: a different computer, or the Mac's key changed. */
    data class HostKeyMismatch(val host: String, val presented: String) :
        SshConnectException("$host answered with a different SSH key ($presented). If the Mac was set up again, pair it again.")

    /** First connection to a host: the key needs the person's OK. */
    data class UnknownHostKey(val host: String, val key: String, val fingerprint: String) :
        SshConnectException("$host is new. Its key: $fingerprint")

    data class AuthenticationFailed(val host: String) : SshConnectException("$host didn't accept the login.")

    /** No address answered. Each entry: the address and what went wrong there. */
    data class Unreachable(val failures: List<HostFailure>) :
        SshConnectException(if (failures.isEmpty()) "No address to try." else "Not reachable: " + failures.joinToString { it.host })

    /** The phone may not use the local network (Android's local network protection). */
    data object LocalNetworkDenied : SshConnectException("aOS may not use the local network.")

    data class HostFailure(val host: String, val reason: String)
}

/**
 * Connects to the Mac over SSH: Apache MINA SSHD's client, one for the app, configured for exactly this: public key
 * login with the phone's key through `DeviceKeyAgent` (never a key file, never `~/.ssh`), the host key checked by the
 * connection's policy, `ssh-ed25519` preferred for the host key (the fingerprint the Mac pins is its ed25519 key's),
 * keepalives every 15 s (three without an answer close the connection).
 */
class SshConnector(
    private val tailnet: TailnetDialer = NoTailnet,
    private val discovery: ServiceDiscovery = NoDiscovery,
    private val keepalive: Duration = Duration.ofSeconds(15),
) {
    /** Per session: the login and the host key check (MINA hands it to the verifier and the agent). */
    internal class Setup(val login: SshLogin, val check: HostKeyCheck)

    internal class HostKeyCheck(val host: String, val policy: HostKeyPolicy) {
        @Volatile var presented: String? = null
        @Volatile var rejection: SshConnectException? = null

        fun verify(key: PublicKey): Boolean {
            val line = PublicKeyEntry.toString(key)
            val fingerprint = SSHKeyFormat.fingerprint(line) ?: ""
            presented = line
            rejection = when (policy) {
                is HostKeyPolicy.Fingerprint ->
                    if (SSHKeyFormat.fingerprintsEqual(fingerprint, policy.fingerprint)) null
                    else SshConnectException.HostKeyMismatch(host, fingerprint)
                is HostKeyPolicy.Pinned ->
                    if (SSHKeyFormat.fingerprintsEqual(fingerprint, SSHKeyFormat.fingerprint(policy.openSSHKey) ?: "")) null
                    else SshConnectException.HostKeyMismatch(host, fingerprint)
                HostKeyPolicy.AskFirst -> SshConnectException.UnknownHostKey(host, line, fingerprint)
            }
            return rejection == null
        }
    }

    private val client: SshClient by lazy { makeClient() }

    private fun makeClient(): SshClient {
        val client = SshClient.setUpDefaultClient()
        // Nothing from the file system: no ~/.ssh/config, no key files, no known_hosts.
        client.hostConfigEntryResolver = HostConfigEntryResolver.EMPTY
        client.keyIdentityProvider = KeyIdentityProvider.EMPTY_KEYS_PROVIDER
        client.serverKeyVerifier = ServerKeyVerifier { session, _, key ->
            setupOf(session)?.check?.verify(key) ?: false
        }
        client.agentFactory = DeviceKeyAgentFactory
        client.userAuthFactories = listOf(UserAuthPublicKeyFactory.INSTANCE)
        // Host key algorithms in this order (the server picks the first it has): the Mac's ed25519 key first.
        val signatures: List<NamedFactory<Signature>> = listOf(BuiltinSignatures.ed25519, BuiltinSignatures.nistp256,
            BuiltinSignatures.nistp384, BuiltinSignatures.nistp521, BuiltinSignatures.rsaSHA512, BuiltinSignatures.rsaSHA256)
            .filter { it.isSupported }
        client.signatureFactories = signatures
        CoreModuleProperties.HEARTBEAT_INTERVAL.set(client, keepalive)
        CoreModuleProperties.HEARTBEAT_REPLY_WAIT.set(client, Duration.ofSeconds(10))
        CoreModuleProperties.HEARTBEAT_NO_REPLY_MAX.set(client, 3)
        CoreModuleProperties.IDLE_TIMEOUT.set(client, Duration.ZERO)
        CoreModuleProperties.NIO2_READ_TIMEOUT.set(client, Duration.ZERO)
        client.start()
        return client
    }

    /** Stops the client (the app's process ends, tests). */
    fun shutdown() {
        try {
            client.stop()
        } catch (_: Exception) {
        }
    }

    /** Connects to the first of `hosts` that answers (pairing: the hosts of the link). */
    suspend fun connectHosts(hosts: List<String>, port: Int, login: SshLogin, hostKey: HostKeyPolicy,
                             perHostTimeoutMillis: Long = 8000, staggerMillis: Long = 400): SshConnection =
        connect(hosts.map { SSHRoute.Host(it) }, port, login, hostKey, perHostTimeoutMillis, staggerMillis)

    /**
     * Connects along `routes` in their order (ConnectionPlan): the attempts start one after the other, `staggerMillis`
     * apart, and run in parallel after that; the first complete login wins and the others are closed. When all fail, the
     * most telling error is thrown (a denied local network, then a refused login, an unknown key, another key, else
     * "unreachable" with each host's reason).
     */
    suspend fun connect(routes: List<SSHRoute>, port: Int, login: SshLogin, hostKey: HostKeyPolicy,
                        perHostTimeoutMillis: Long = 8000, staggerMillis: Long = 400): SshConnection {
        if (routes.isEmpty()) throw SshConnectException.Unreachable(emptyList())
        val winner = CompletableDeferred<SshConnection>()
        val failures = mutableListOf<Pair<String, Throwable>>()
        val lock = Any()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val jobs = mutableListOf<Job>()
        try {
            routes.forEachIndexed { index, route ->
                jobs += scope.launch {
                    if (index > 0) delay(staggerMillis * index)
                    if (winner.isCompleted) return@launch
                    try {
                        val connection = withTimeout(perHostTimeoutMillis + 2000) {
                            connectOne(route, port, login, hostKey, perHostTimeoutMillis)
                        }
                        if (!winner.complete(connection)) connection.closeNow()
                    } catch (e: Throwable) {
                        val all = synchronized(lock) {
                            failures += route.host to e
                            failures.size == routes.size
                        }
                        if (all) winner.completeExceptionally(summarize(synchronized(lock) { failures.toList() }))
                    }
                }
            }
            return winner.await()
        } finally {
            scope.cancel()
        }
    }

    private suspend fun connectOne(route: SSHRoute, port: Int, login: SshLogin, policy: HostKeyPolicy,
                                   timeoutMillis: Long): SshConnection {
        val host = route.host
        var bridge: LoopbackBridge? = null
        val (targetHost, targetPort, address) = when (route) {
            is SSHRoute.Host -> Triple(host, port, host)
            is SSHRoute.Tailnet -> {
                if (!tailnet.isRunning) throw IOException("aOS's Tailscale doesn't run")
                val connection = tailnet.dial(host, port, timeoutMillis)
                val opened = LoopbackBridge.open(connection)
                bridge = opened
                Triple("127.0.0.1", opened.port, host)
            }
            is SSHRoute.Bonjour -> {
                val found = discovery.find(BONJOUR_SSH, host, timeoutMillis.coerceAtMost(4000), orOnlyOne = false)
                    ?: throw IOException("not found over Bonjour")
                Triple(found.host, found.port, found.host)
            }
        }
        val check = HostKeyCheck(host, policy)
        val setup = Setup(login, check)
        var session: ClientSession? = null
        try {
            val future = client.connect(login.username, targetHost, targetPort,
                AttributeRepository.ofKeyValuePair(SETUP, setup))
            session = future.awaitSession(timeoutMillis)
            session.addCloseFutureListener { bridge?.close() }
            val auth = session.auth()
            val done = auth.awaitDone(timeoutMillis)
            if (!done.isSuccess) {
                check.rejection?.let { throw it }
                throw SshConnectException.AuthenticationFailed(host)
            }
            val presented = check.presented ?: throw SshConnectException.HostKeyMismatch(host, "?")
            return SshConnection(session, route, presented, address)
        } catch (e: Throwable) {
            withContext(NonCancellable) {
                session?.close(true)
                bridge?.close()
            }
            check.rejection?.let { throw it }
            if (e is SshConnectException) throw e
            val text = describe(e)
            if (text.contains("No more authentication methods", ignoreCase = true) ||
                text.contains("authentication", ignoreCase = true) && text.contains("fail", ignoreCase = true)) {
                throw SshConnectException.AuthenticationFailed(host)
            }
            throw e
        }
    }

    companion object {
        internal val SETUP = AttributeRepository.AttributeKey<Setup>()

        /**
         * MINA asks for a home folder in some of its defaults (on Android there is none, and it throws). The app gives
         * it an empty folder of its own (`AosApp`): nothing is ever read from or written there, the client is
         * configured to use no files at all. Call before the first `SshConnector`.
         */
        fun useHomeFolder(folder: java.io.File) {
            folder.mkdirs()
            org.apache.sshd.common.util.io.PathUtils.setUserHomeFolderResolver { folder.toPath() }
        }

        /** The setup a connection was started with (MINA keeps it in the session's connection context). */
        internal fun setupOf(session: org.apache.sshd.common.session.Session?): Setup? {
            session ?: return null
            session.getAttribute(SETUP)?.let { return it }
            return (session as? ClientSession)?.connectionContext?.getAttribute(SETUP)
        }
        const val BONJOUR_SSH = "_ssh._tcp"

        /** Login and host key problems say more than "not reachable"; a denied local network says the most. */
        internal fun summarize(failures: List<Pair<String, Throwable>>): SshConnectException {
            val errors = failures.map { it.second }
            if (errors.any { it == SshConnectException.LocalNetworkDenied || isLocalNetworkDenial(it) }) {
                return SshConnectException.LocalNetworkDenied
            }
            errors.filterIsInstance<SshConnectException.AuthenticationFailed>().firstOrNull()?.let { return it }
            errors.filterIsInstance<SshConnectException.UnknownHostKey>().firstOrNull()?.let { return it }
            errors.filterIsInstance<SshConnectException.HostKeyMismatch>().firstOrNull()?.let { return it }
            return SshConnectException.Unreachable(failures.map { SshConnectException.HostFailure(it.first, describe(it.second)) })
        }

        private fun isLocalNetworkDenial(error: Throwable): Boolean {
            var e: Throwable? = error
            while (e != null) {
                val message = e.message ?: ""
                if (message.contains("EPERM") || message.contains("Operation not permitted")) return true
                e = e.cause
            }
            return false
        }

        internal fun describe(error: Throwable): String = when (error) {
            is kotlinx.coroutines.TimeoutCancellationException -> "timeout"
            is java.net.UnknownHostException -> "unknown host"
            is java.net.ConnectException -> error.message ?: "refused"
            else -> error.message ?: error.javaClass.simpleName
        }
    }
}

/** Waits for a MINA future without blocking a thread. */
internal suspend fun <F : SshFuture<F>> F.awaitDone(timeoutMillis: Long): F = withTimeout(timeoutMillis) {
    suspendCancellableCoroutine { continuation ->
        addListener { done -> if (continuation.isActive) continuation.resume(done) }
    }
}

/** The connected session, or the reason it didn't connect. A session that arrives after a timeout is closed. */
internal suspend fun ConnectFuture.awaitSession(timeoutMillis: Long): ClientSession {
    try {
        val done = awaitDone(timeoutMillis)
        if (done.isConnected) return done.session
        throw done.exception?.let { if (it is IOException) it else IOException(it.message, it) } ?: IOException("not connected")
    } catch (e: Throwable) {
        addListener { late -> if (late.isConnected) late.session.close(true) }
        cancel()
        throw e
    }
}

/**
 * One open SSH connection to the Mac. Channels in it: exec (the companion, `term list`), a command or a shell in a
 * pseudo terminal (the terminal), direct-tcpip (the screens). Thread-safe.
 */
class SshConnection internal constructor(
    val session: ClientSession,
    /** How it was reached. */
    val route: SSHRoute,
    /** The host key the server presented (OpenSSH line). */
    val hostKey: String,
    /** The address it reached (an IP or name; the tailnet host for the tailnet node; the resolved one for Bonjour). */
    val address: String,
) {
    /** The host the route names (what the app remembers as the address that worked). */
    val host: String get() = route.host
    val hostKeyFingerprint: String = SSHKeyFormat.fingerprint(hostKey) ?: ""

    val isActive: Boolean get() = session.isOpen && !session.isClosing

    private val closeHandlers = mutableListOf<() -> Unit>()
    private val closed = AtomicBoolean(false)

    init {
        session.addCloseFutureListener {
            if (closed.compareAndSet(false, true)) synchronized(closeHandlers) { closeHandlers.toList() }.forEach { it() }
        }
    }

    /** Runs `handler` once when the connection closes (from either side); at once if it is closed already. */
    fun onClose(handler: () -> Unit) {
        val runNow = synchronized(closeHandlers) {
            if (closed.get()) true else {
                closeHandlers += handler
                false
            }
        }
        if (runNow) handler()
    }

    suspend fun close() = withContext(Dispatchers.IO) { closeNow() }

    fun closeNow() {
        try {
            session.close(true)
        } catch (_: Exception) {
        }
    }

    /** A command in an exec channel with stdin and stdout as byte streams (8-bit clean, no terminal). */
    suspend fun exec(command: String): SessionChannel = SessionChannel.open(session, SessionChannel.Mode.Exec(command))

    /** An interactive login shell in a pseudo terminal. */
    suspend fun shell(term: String = "xterm-256color", columns: Int, rows: Int): SessionChannel =
        SessionChannel.open(session, SessionChannel.Mode.Shell(term, columns, rows))

    /** A command in a pseudo terminal (the Mac's terminal sessions: `aos-companion term attach`). */
    suspend fun terminal(command: String, term: String = "xterm-256color", columns: Int, rows: Int): SessionChannel =
        SessionChannel.open(session, SessionChannel.Mode.TerminalCommand(command, term, columns, rows))

    /** Runs a command and collects what it prints (at most `limit` bytes), for `term list` and `term end`. */
    suspend fun run(command: String, timeoutMillis: Long = 15_000, limit: Int = 1 shl 20): ByteArray {
        val channel = exec(command)
        try {
            return withTimeout(timeoutMillis) {
                val out = java.io.ByteArrayOutputStream()
                try {
                    channel.output.collect { chunk ->
                        out.write(chunk)
                        if (out.size() > limit) throw LimitReached()
                    }
                } catch (_: LimitReached) {
                }
                out.toByteArray()
            }
        } finally {
            withContext(NonCancellable) { channel.close() }
        }
    }

    private class LimitReached : Exception()

    /** A TCP connection from the Mac to `targetHost:targetPort` (as `ssh -L` does), as two byte streams. */
    suspend fun directTcpip(targetHost: String, targetPort: Int): DirectTcpipChannel =
        DirectTcpipChannel.open(session, targetHost, targetPort)

    /** The key type the server presented (`ssh-ed25519`). */
    val hostKeyType: String get() = hostKey.substringBefore(' ')

    override fun toString() = "SshConnection(${route.host}, $hostKeyFingerprint)"
}
