package dev.marquart.aos.ssh

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.Collections
import kotlin.concurrent.thread

/**
 * `ssh -L` on the phone: a listener on 127.0.0.1 (random port) whose connections each open a direct-tcpip channel
 * through the SSH connection to `targetHost:targetPort` as seen from the Mac.
 *
 * The screen client (Open Screen Sharing's libsharing) connects to a host and port with TCP, so it is pointed at this
 * listener: `start()` returns the port. Each new local connection asks `connection` for the SSH connection, so after
 * the Mac's connection was rebuilt (a network change) the screen client's next connection uses the new one. Only
 * loopback; the listener lives only while a screen is open (`stop()`).
 */
class LocalForwarder(
    val targetHost: String,
    val targetPort: Int,
    private val connection: suspend () -> SshConnection,
) {
    constructor(connection: SshConnection, targetHost: String, targetPort: Int) : this(targetHost, targetPort, { connection })

    private var server: ServerSocket? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val open = Collections.synchronizedSet(mutableSetOf<java.io.Closeable>())

    /** Why the last forwarded connection couldn't be opened (the Mac refused, for example). */
    @Volatile var lastError: Throwable? = null
        private set

    /** The local port while listening. */
    val port: Int? get() = server?.localPort

    /** Starts listening on 127.0.0.1; returns the local port. */
    fun start(): Int {
        server?.let { return it.localPort }
        val socket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        server = socket
        thread(name = "aos-forward-accept", isDaemon = true) {
            while (!socket.isClosed) {
                val local = try {
                    socket.accept()
                } catch (_: SocketException) {
                    break
                } catch (_: IOException) {
                    continue
                }
                local.tcpNoDelay = true
                open += local
                scope.launch { bridge(local) }
            }
        }
        return socket.localPort
    }

    /** Stops listening and closes every forwarded connection. */
    fun stop() {
        try {
            server?.close()
        } catch (_: IOException) {
        }
        server = null
        synchronized(open) { open.toList() }.forEach {
            try {
                it.close()
            } catch (_: IOException) {
            }
        }
        open.clear()
        scope.cancel()
    }

    private suspend fun bridge(local: Socket) {
        val channel = try {
            connection().directTcpip(targetHost, targetPort)
        } catch (e: Throwable) {
            lastError = e
            open -= local
            try { local.close() } catch (_: IOException) {}
            return
        }
        open += channel
        var finishedDirections = 0
        val done = {
            synchronized(this) {
                finishedDirections++
                if (finishedDirections == 2) {
                    channel.close()
                    try { local.close() } catch (_: IOException) {}
                    open -= channel
                    open -= local
                }
            }
        }
        val broken = {
            channel.close()
            try { local.close() } catch (_: IOException) {}
        }
        // Local socket -> SSH channel; at its end the Mac's side reads end of file.
        pump(local.getInputStream(), channel.output, onEnd = { channel.closeOutput() }, onError = broken, done = done)
        // SSH channel -> local socket: what the Mac sent last (a refused login's reason) still goes out, then the end.
        pump(channel.input, local.getOutputStream(), onEnd = { try { local.shutdownOutput() } catch (_: IOException) {} },
            onError = broken, done = done)
    }

    private fun pump(from: InputStream, to: OutputStream, onEnd: () -> Unit, onError: () -> Unit, done: () -> Unit) {
        thread(name = "aos-forward-pump", isDaemon = true) {
            val buffer = ByteArray(64 * 1024)
            try {
                while (true) {
                    val n = from.read(buffer)
                    if (n < 0) break
                    to.write(buffer, 0, n)
                    to.flush()
                }
                onEnd()
            } catch (_: IOException) {
                // A connection that broke (not one that ended): both directions go.
                onError()
            }
            done()
        }
    }
}
