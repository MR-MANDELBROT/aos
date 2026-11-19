package dev.marquart.aos.connection

import android.content.Context
import dev.marquart.aos.tailnetkit.Listener
import dev.marquart.aos.tailnetkit.Node
import dev.marquart.aos.tailnetkit.State
import dev.marquart.aos.tailnetkit.Tailnetkit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.runInterruptible
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/** Built with third_party/aosgo/aosgo.aar: aOS's own Tailscale node (tailnetkit, third_party/README.md). */
object Tailnets {
    const val AVAILABLE = true

    fun create(context: Context, deviceName: String): EmbeddedTailnet =
        EmbeddedTailnet(File(context.noBackupFilesDir, "Tailnet"), EmbeddedTailnet.hostname(deviceName))
}

/**
 * aOS's own Tailscale node in this app (the iPhone's `EmbeddedTailnet`), as the connection's `TailnetDialer`. The node's
 * state lives in `dir` (out of backups); "set up" means that folder exists (the node was started once). Signing in
 * (`state.authURL()` in a Custom Tab while `needsLogin()`), Settings > Connection and signing out are the UI's: it calls
 * `setUp()`, watches `state`, and `signOut()`.
 *
 * Dialing: the node can't hand a socket to the JVM; it connects through the tailnet, then listens once on 127.0.0.1
 * and takes only a connection from the port we bound first (third_party/README.md, "Dialing the Mac").
 */
class EmbeddedTailnet(private val dir: File, private val hostname: String) : TailnetDialer {
    private var node: Node? = null
    private val _state = MutableStateFlow<State?>(null)
    private val _ready = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /** The node's state as it last reported it (null before it started). */
    val state: StateFlow<State?> = _state

    override val isSetUp: Boolean get() = dir.isDirectory
    override val isRunning: Boolean get() = _state.value?.isRunning == true
    override val ready: Flow<Unit> = _ready.asSharedFlow()

    override fun startIfSetUp() {
        if (isSetUp) setUp()
    }

    /** Makes and starts the node (first time: then it needs a sign-in). Runs its blocking calls on a thread of its own. */
    @Synchronized fun setUp() {
        if (node != null) return
        thread(name = "aos-tailnet-start", isDaemon = true) {
            try {
                dir.mkdirs()
                dir.setReadable(false, false); dir.setReadable(true, true)
                dir.setWritable(false, false); dir.setWritable(true, true)
                dir.setExecutable(false, false); dir.setExecutable(true, true)
                val created = Tailnetkit.newNode(dir.absolutePath, hostname, "", null)
                synchronized(this) { node = created }
                created.start(Listener { state ->
                    val wasRunning = _state.value?.isRunning == true
                    _state.value = state
                    if (state.isRunning && !wasRunning) _ready.tryEmit(Unit)
                })
            } catch (_: Exception) {
                synchronized(this) { node = null }
            }
        }
    }

    /** Leaves the tailnet; the node's state is deleted. */
    fun signOut() {
        val current = synchronized(this) { node.also { node = null } }
        try { current?.logout() } catch (_: Exception) {}
        current?.close()
        _state.value = null
        dir.deleteRecursively()
    }

    override suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection {
        val node = synchronized(this) { node } ?: throw IOException("aOS's Tailscale doesn't run")
        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        val socket = Socket()
        try {
            socket.bind(InetSocketAddress(loopback, 0))
            val local = runInterruptible(Dispatchers.IO) { node.dial(host, port, timeoutMillis.toInt(), socket.localPort) }
            runInterruptible(Dispatchers.IO) { socket.connect(InetSocketAddress(loopback, local), 5_000) }
            socket.tcpNoDelay = true
        } catch (e: Exception) {
            socket.close()
            throw if (e is IOException) e else IOException(e.message, e)
        }
        return object : TailnetConnection {
            override val input: InputStream = socket.getInputStream()
            override val output: OutputStream = socket.getOutputStream()
            override fun close() = socket.close()
        }
    }

    companion object {
        /** `aos-<device name>` as a DNS label (lowercase letters, digits, hyphens; at most 63). */
        fun hostname(deviceName: String): String {
            val label = deviceName.lowercase().map { if (it in 'a'..'z' || it in '0'..'9') it else '-' }.joinToString("")
                .split('-').filter { it.isNotEmpty() }.joinToString("-")
            return ("aos-" + label.ifEmpty { "android" }).take(63).trimEnd('-')
        }
    }
}
