package dev.marquart.aos.ssh

import dev.marquart.aos.connection.TailnetConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.apache.sshd.client.channel.ChannelDirectTcpip
import org.apache.sshd.client.channel.ChannelExec
import org.apache.sshd.client.channel.ChannelShell
import org.apache.sshd.client.channel.ClientChannel
import org.apache.sshd.client.channel.PtyCapableChannelSession
import org.apache.sshd.client.session.ClientSession
import org.apache.sshd.common.channel.PtyMode
import org.apache.sshd.common.util.net.SshdSocketAddress
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * An SSH session channel: a command (`exec`), a login shell in a pseudo terminal, or a command in a pseudo terminal.
 * Bytes in both directions; what the remote side writes arrives in `output` (in order, one collector). `output`
 * completes when the channel closes: normally for exit status 0 (or none), with `Failure.Exited` otherwise (127: the
 * program isn't there).
 *
 * The terminal agent builds on this: `SshConnection.terminal(command, term, columns, rows)`, `write`, `resize`, `output`.
 */
class SessionChannel private constructor(private val channel: ClientChannel) {
    sealed class Mode {
        data class Exec(val command: String) : Mode()
        data class Shell(val term: String, val columns: Int, val rows: Int) : Mode()

        /** A command in a pseudo terminal (`ssh -t host command`): the terminal sessions on the Mac. */
        data class TerminalCommand(val command: String, val term: String, val columns: Int, val rows: Int) : Mode()
    }

    sealed class Failure(message: String) : IOException(message) {
        class Refused(val what: String) : Failure("The Mac refused to start $what.")

        /** The program ended with a status other than 0; `message` is what it wrote to stderr (at most 4 KB). */
        class Exited(val status: Int, val text: String) :
            Failure(text.ifEmpty { "The program ended (status $status)." })
    }

    private val incoming = Channel<ByteArray>(Channel.UNLIMITED)
    private val stderr = ByteArrayOutputStream()
    private val writeLock = Mutex()

    /** Standard output (and for a pseudo terminal, everything the terminal shows). One collector. */
    val output: Flow<ByteArray> = incoming.receiveAsFlow()

    /** The exit status, once the remote program reported one. */
    val exitStatus: Int? get() = channel.exitStatus

    val isOpen: Boolean get() = channel.isOpen && !channel.isClosing

    /** Sends bytes to the remote program's standard input (waits while the remote window is full). */
    suspend fun write(data: ByteArray) = writeLock.withLock {
        withContext(Dispatchers.IO) {
            val stream = channel.invertedIn
            stream.write(data)
            stream.flush()
        }
    }

    /** Tells the pseudo terminal its new size. */
    suspend fun resize(columns: Int, rows: Int) = withContext(Dispatchers.IO) {
        (channel as? PtyCapableChannelSession)?.sendWindowChange(columns, rows) ?: Unit
    }

    /** Ends standard input (the remote program reads end of file). */
    suspend fun closeInput() = writeLock.withLock {
        withContext(Dispatchers.IO) {
            try {
                channel.invertedIn.close()
            } catch (_: IOException) {
            }
        }
    }

    suspend fun close() = withContext(Dispatchers.IO) {
        try {
            channel.close(false)
        } catch (_: Exception) {
        }
        Unit
    }

    private fun finished() {
        val status = channel.exitStatus
        if (status != null && status != 0) {
            val text = synchronized(stderr) { stderr.toByteArray() }.toString(Charsets.UTF_8).trim()
            incoming.close(Failure.Exited(status, text))
        } else {
            incoming.close()
        }
    }

    companion object {
        /** Terminal modes for a pseudo terminal (what a terminal app on a Mac would send): UTF-8, DEL erases. */
        val DEFAULT_PTY_MODES: Map<PtyMode, Int> = mapOf(
            PtyMode.VINTR to 3, PtyMode.VQUIT to 28, PtyMode.VERASE to 127, PtyMode.VKILL to 21, PtyMode.VEOF to 4,
            PtyMode.VSUSP to 26, PtyMode.VWERASE to 23, PtyMode.VLNEXT to 22, PtyMode.ICRNL to 1, PtyMode.IXON to 0,
            PtyMode.IUTF8 to 1, PtyMode.ISIG to 1, PtyMode.ICANON to 1, PtyMode.IEXTEN to 1, PtyMode.ECHO to 1,
            PtyMode.ECHOE to 1, PtyMode.ECHOK to 1, PtyMode.ECHOCTL to 1, PtyMode.ECHOKE to 1, PtyMode.OPOST to 1,
            PtyMode.ONLCR to 1, PtyMode.CS8 to 1, PtyMode.TTY_OP_ISPEED to 38400, PtyMode.TTY_OP_OSPEED to 38400,
        )

        internal suspend fun open(session: ClientSession, mode: Mode): SessionChannel = withContext(Dispatchers.IO) {
            val channel: ClientChannel = when (mode) {
                is Mode.Exec -> session.createExecChannel(mode.command).also { it.isUsePty = false }
                is Mode.Shell -> session.createShellChannel().also { it.pty(mode.term, mode.columns, mode.rows) }
                is Mode.TerminalCommand -> session.createExecChannel(mode.command).also { it.pty(mode.term, mode.columns, mode.rows) }
            }
            val result = SessionChannel(channel)
            channel.setOut(object : OutputStream() {
                override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
                override fun write(b: ByteArray, off: Int, len: Int) {
                    if (len > 0) result.incoming.trySend(b.copyOfRange(off, off + len))
                }
            })
            channel.setErr(object : OutputStream() {
                override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
                override fun write(b: ByteArray, off: Int, len: Int) {
                    synchronized(result.stderr) {
                        val room = 4096 - result.stderr.size()
                        if (room > 0) result.stderr.write(b, off, minOf(len, room))
                    }
                }
            })
            val what = when (mode) {
                is Mode.Exec -> mode.command
                is Mode.Shell -> "a shell"
                is Mode.TerminalCommand -> mode.command
            }
            try {
                val opened = channel.open().awaitDone(15_000)
                if (!opened.isOpened) throw Failure.Refused(what)
            } catch (e: Throwable) {
                channel.close(true)
                if (e is Failure) throw e
                throw Failure.Refused(what)
            }
            channel.addCloseFutureListener { result.finished() }
            result
        }

        private fun PtyCapableChannelSession.pty(term: String, columns: Int, rows: Int) {
            isUsePty = true
            ptyType = term
            ptyColumns = columns
            ptyLines = rows
            ptyWidth = 0
            ptyHeight = 0
            ptyModes = DEFAULT_PTY_MODES
        }
    }
}

/**
 * A direct-tcpip channel (`ssh -L`): a TCP connection from the Mac to a host and port, as two byte streams. Reading
 * `input` waits for data (back pressure through the SSH window); `close` ends both directions.
 */
class DirectTcpipChannel private constructor(private val channel: ChannelDirectTcpip) : Closeable {
    val input: InputStream get() = channel.invertedOut
    val output: OutputStream get() = channel.invertedIn
    val isOpen: Boolean get() = channel.isOpen && !channel.isClosing

    override fun close() {
        try {
            channel.close(false)
        } catch (_: Exception) {
        }
    }

    /** The local side is done sending (the remote reads end of file). */
    fun closeOutput() {
        try {
            channel.invertedIn.close()
        } catch (_: IOException) {
        }
    }

    companion object {
        internal suspend fun open(session: ClientSession, host: String, port: Int): DirectTcpipChannel = withContext(Dispatchers.IO) {
            val channel = session.createDirectTcpipChannel(SshdSocketAddress("127.0.0.1", 0), SshdSocketAddress(host, port))
            try {
                val opened = channel.open().awaitDone(15_000)
                if (!opened.isOpened) throw IOException("The Mac refused the connection to $host:$port")
            } catch (e: Throwable) {
                channel.close(true)
                throw if (e is IOException) e else IOException("The Mac refused the connection to $host:$port", e)
            }
            DirectTcpipChannel(channel)
        }
    }
}

/**
 * A one-shot listener on 127.0.0.1 whose first connection is spliced to a tailnet connection: MINA connects to it like
 * to any host. Only loopback, closed after the first connection. Whatever connects first gets the bytes, but the SSH
 * host key check runs end to end with the Mac, so another local program can't pose as the Mac.
 */
internal class LoopbackBridge private constructor(private val server: ServerSocket, private val remote: TailnetConnection) : Closeable {
    val port: Int get() = server.localPort
    @Volatile private var socket: Socket? = null

    private fun start() {
        thread(name = "aos-tailnet-bridge", isDaemon = true) {
            try {
                server.soTimeout = 15_000
                val local = server.accept()
                socket = local
                server.close()
                pump(local.getInputStream(), remote.output) { close() }
                pump(remote.input, local.getOutputStream()) { close() }
            } catch (_: Exception) {
                close()
            }
        }
    }

    private fun pump(from: InputStream, to: OutputStream, done: () -> Unit) {
        thread(name = "aos-tailnet-pump", isDaemon = true) {
            val buffer = ByteArray(32 * 1024)
            try {
                while (true) {
                    val n = from.read(buffer)
                    if (n < 0) break
                    to.write(buffer, 0, n)
                    to.flush()
                }
            } catch (_: IOException) {
            }
            done()
        }
    }

    override fun close() {
        try { server.close() } catch (_: IOException) {}
        try { socket?.close() } catch (_: IOException) {}
        try { remote.close() } catch (_: IOException) {}
    }

    companion object {
        fun open(remote: TailnetConnection): LoopbackBridge {
            val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
            return LoopbackBridge(server, remote).also { it.start() }
        }
    }
}
