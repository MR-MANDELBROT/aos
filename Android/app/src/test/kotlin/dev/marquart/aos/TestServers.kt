package dev.marquart.aos

import dev.marquart.aos.companion.MockCompanionServer
import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.PairingRequest
import dev.marquart.aos.core.PairingResponse
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.core.TermNoteFilter
import dev.marquart.aos.keys.DeviceKey
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.Environment
import org.apache.sshd.server.ExitCallback
import org.apache.sshd.server.Signal
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.channel.ChannelSession
import org.apache.sshd.server.command.Command
import org.apache.sshd.server.forward.AcceptAllForwardingFilter
import org.apache.sshd.server.shell.ShellFactory
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import kotlin.concurrent.thread

// Servers for the JVM tests, all on 127.0.0.1 inside the test process. Nothing here touches the Mac's own sshd, its
// ~/.ssh or aOS (iOS Tests/Support/TestSSHServer.swift, FakeServers.swift).

/** A port that was free a moment ago. */
fun freeLocalPort(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }

/**
 * An SSH server on Apache MINA SSHD with what the Mac offers the app: `'<companion>' serve` in an exec channel (the mock
 * companion on stdin and stdout), `term list`/`term end`/`term attach`, a login shell in a pseudo terminal (an echo,
 * recording its size), direct-tcpip, and an ed25519 host key. Logins: only `allowedKey` for `username`.
 */
class TestSshServer private constructor(
    private val server: SshServer,
    val companion: MockCompanionServer,
    val hostKeyLine: String,
    /** The Mac's terminal sessions with state (attach, drop, take over); null: the fixed answers below. */
    val terms: FakeTermSessions? = null,
) {
    val port: Int get() = server.port
    val hostKeyFingerprint: String = SSHKeyFormat.fingerprint(hostKeyLine)!!
    private val log = Collections.synchronizedList(mutableListOf<String>())
    val events: List<String> get() = synchronized(log) { log.toList() }

    fun stop() = server.stop(true)

    companion object {
        const val COMPANION_PATH = CompanionCommand.DEFAULT_PATH

        fun start(allowedKey: DeviceKey?, username: String = "max",
                  companion: MockCompanionServer = MockCompanionServer(keepsSecrets = true),
                  terms: FakeTermSessions? = null): TestSshServer {
            val hostKey = KeyUtils.generateKeyPair("ssh-ed25519", 256)
            val server = SshServer.setUpDefaultServer()
            server.host = "127.0.0.1"
            server.port = 0
            server.keyPairProvider = KeyPairProvider.wrap(hostKey)
            server.setPublickeyAuthenticator { user, key, _ ->
                user == username && allowedKey != null && KeyUtils.compareKeys(key, allowedKey.javaPublicKey)
            }
            server.passwordAuthenticator = null
            server.keyboardInteractiveAuthenticator = null
            server.forwardingFilter = AcceptAllForwardingFilter.INSTANCE
            lateinit var test: TestSshServer
            server.setCommandFactory { _, command -> MacCommand(command, test) }
            server.shellFactory = ShellFactory { EchoShell(test) }
            server.start()
            test = TestSshServer(server, companion, PublicKeyEntry.toString(hostKey.public), terms)
            return test
        }
    }

    internal fun record(event: String) {
        log += event
    }

    /** One command in an exec channel, as the Mac's login shell would run it. */
    private class MacCommand(val command: String, val test: TestSshServer) : Command {
        lateinit var input: InputStream
        lateinit var output: OutputStream
        lateinit var error: OutputStream
        lateinit var exit: ExitCallback
        override fun setInputStream(`in`: InputStream) { input = `in` }
        override fun setOutputStream(out: OutputStream) { output = out }
        override fun setErrorStream(err: OutputStream) { error = err }
        override fun setExitCallback(callback: ExitCallback) { exit = callback }
        override fun destroy(channel: ChannelSession?) {}

        override fun start(channel: ChannelSession?, env: Environment) {
            val term = env.env["TERM"]
            test.record(if (term != null) "pty-exec $term ${env.env["COLUMNS"]}x${env.env["LINES"]} $command" else "exec $command")
            val quoted = CompanionCommand.shellQuoted(COMPANION_PATH)
            if (test.terms != null && command.startsWith("$quoted term ")) return heldTerm(channel, env)
            when {
                command == CompanionCommand.serve(COMPANION_PATH) -> serveCompanion()
                command.endsWith("' serve") -> {
                    // Another path: not there (the login shell says so, status 127)
                    error.write("zsh:1: no such file or directory: ${command.substringAfter('\'').substringBefore('\'')}\n".toByteArray())
                    error.flush()
                    exit.onExit(127)
                }
                command == "true" -> exit.onExit(0)
                command == "$quoted term list --json" -> {
                    output.write("""{"sessions":[{"id":"0123abcd","attached":false,"created":"2026-11-07T09:00:00Z","command":"zsh","cwd":"/Users/max"}]}""".toByteArray() + 0x0A)
                    output.flush()
                    exit.onExit(0)
                }
                command.startsWith("$quoted term end ") -> {
                    output.write("{\"ok\":true}\n".toByteArray()); output.flush(); exit.onExit(0)
                }
                command.startsWith("$quoted term attach") -> attach(env)
                else -> exit.onExit(2)
            }
        }

        /** The mock companion on stdin and stdout until the client closes the channel. */
        private fun serveCompanion() {
            val feeder = test.companion.attach(write = { data ->
                try {
                    synchronized(output) { output.write(data); output.flush() }
                } catch (_: IOException) {
                }
            }, hangUp = { try { exit.onExit(0) } catch (_: Exception) {} })
            thread(isDaemon = true, name = "test-companion") {
                val buffer = ByteArray(8192)
                try {
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        feeder.feed(buffer.copyOf(n))
                    }
                } catch (_: IOException) {
                }
                try { exit.onExit(0) } catch (_: Exception) {}
            }
        }

        /** `term ...` played by FakeTermSessions: its bytes out, typed bytes in, the channel's end as it says. */
        private fun heldTerm(channel: ChannelSession?, env: Environment) {
            env.addSignalListener({ _, _ -> test.record("size ${env.env["COLUMNS"]}x${env.env["LINES"]}") }, Signal.WINCH)
            val attached = FakeTermSessions.Attached(
                write = { data -> try { synchronized(output) { output.write(data); output.flush() } } catch (_: IOException) {} },
                error = { data -> try { error.write(data); error.flush() } catch (_: IOException) {} },
                close = { status ->
                    try {
                        // Without a status the connection just goes (the network dropped).
                        if (status == null) channel?.close(false) else exit.onExit(status)
                    } catch (_: Exception) {
                    }
                },
            )
            if (!test.terms!!.handle(command, COMPANION_PATH, attached)) return
            thread(isDaemon = true, name = "test-term-input") {
                val buffer = ByteArray(4096)
                try {
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        test.terms!!.input(buffer.copyOf(n), attached)
                    }
                } catch (_: IOException) {
                }
            }
        }

        /** `term attach`: a start note, a prompt, then an echo until "exit". */
        private fun attach(env: Environment) {
            env.addSignalListener({ _, _ -> test.record("size ${env.env["COLUMNS"]}x${env.env["LINES"]}") }, Signal.WINCH)
            output.write(TermNoteFilter.note("""{"t":"start","id":"0000aa01","from":0,"reset":true,"prefix":"","new":true}"""))
            output.write("Welcome to the held shell\r\n$ ".toByteArray())
            output.flush()
            echo(input, output) { status -> exit.onExit(status) }
        }
    }

    /** A login shell: a prompt, then an echo of what is typed until "exit\r". */
    private class EchoShell(val test: TestSshServer) : Command {
        lateinit var input: InputStream
        lateinit var output: OutputStream
        lateinit var exit: ExitCallback
        override fun setInputStream(`in`: InputStream) { input = `in` }
        override fun setOutputStream(out: OutputStream) { output = out }
        override fun setErrorStream(err: OutputStream) {}
        override fun setExitCallback(callback: ExitCallback) { exit = callback }
        override fun destroy(channel: ChannelSession?) {}
        override fun start(channel: ChannelSession?, env: Environment) {
            test.record("pty ${env.env["TERM"]} ${env.env["COLUMNS"]}x${env.env["LINES"]}")
            test.record("shell")
            env.addSignalListener({ _, _ -> test.record("size ${env.env["COLUMNS"]}x${env.env["LINES"]}") }, Signal.WINCH)
            output.write("Welcome\r\n$ ".toByteArray())
            output.flush()
            echo(input, output) { status -> exit.onExit(status) }
        }
    }
}

private fun echo(input: InputStream, output: OutputStream, done: (Int) -> Unit) {
    thread(isDaemon = true, name = "test-echo") {
        val typed = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        try {
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                output.write(buffer, 0, n)
                output.flush()
                typed.write(buffer, 0, n)
                if (typed.toString(Charsets.UTF_8).endsWith("exit\r")) break
            }
        } catch (_: IOException) {
        }
        done(0)
    }
}

/** Echoes every connection's bytes back (the far end of a direct-tcpip channel). */
class EchoTcpServer {
    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort

    init {
        thread(isDaemon = true, name = "test-echo-tcp") {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: IOException) { break }
                thread(isDaemon = true) {
                    socket.use { s ->
                        val buffer = ByteArray(4096)
                        while (true) {
                            val n = try { s.getInputStream().read(buffer) } catch (_: IOException) { -1 }
                            if (n < 0) break
                            s.getOutputStream().write(buffer, 0, n)
                        }
                    }
                }
            }
        }
    }

    fun stop() = server.close()
}

/** The Mac's pairing listener, as aOS checks a request (version 2, a P-256 signing key, the proof over both keys). */
class FakePairingListener(private val code: ByteArray, private val behavior: Behavior) {
    sealed class Behavior {
        data class Accept(val user: String, val companion: String) : Behavior()
        data class Tampered(val user: String, val companion: String) : Behavior()
        data class Refuse(val reason: String) : Behavior()
        data object HangUp : Behavior()
    }

    private val server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort
    val requests: MutableList<PairingRequest> = Collections.synchronizedList(mutableListOf())

    init {
        thread(isDaemon = true, name = "test-pairing") {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: IOException) { break }
                thread(isDaemon = true) { socket.use(::session) }
            }
        }
    }

    private fun session(socket: Socket) {
        val line = ByteArrayOutputStream()
        val input = socket.getInputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return
            if (b == 0x0A) break
            line.write(b)
        }
        if (behavior == Behavior.HangUp) return
        val request = PairingRequest.parse(line.toByteArray())
        fun reply(text: String) {
            socket.getOutputStream().apply { write((text + "\n").toByteArray()); flush() }
        }
        if (request == null) return reply("""{"ok":false,"error":"bad request"}""")
        requests += request
        val sign = Bytes.base64Decode(request.sign)
        if (request.v != 2 || sign == null || sign.size != 65 || P256.publicKey(sign) == null) {
            return reply("""{"ok":false,"error":"unsupported signing key"}""")
        }
        val proofOk = PairingRequest.proof(code, request.key, request.device, request.sign) == request.proof
        when (val b = behavior) {
            is Behavior.Accept -> if (proofOk) {
                val mac = Bytes.base64(PairingResponse.authentication(code, b.user, b.companion))
                reply("""{"ok":true,"user":"${b.user}","companion":"${b.companion}","mac":"$mac"}""")
            } else reply("""{"ok":false,"error":"wrong proof"}""")
            is Behavior.Tampered -> if (proofOk) {
                // Signed for the real path, then changed on the way
                val mac = Bytes.base64(PairingResponse.authentication(code, b.user, b.companion))
                reply("""{"ok":true,"user":"${b.user}","companion":"/bin/sh","mac":"$mac"}""")
            } else reply("""{"ok":false,"error":"wrong proof"}""")
            is Behavior.Refuse -> reply("""{"ok":false,"error":"${b.reason}"}""")
            Behavior.HangUp -> Unit
        }
    }

    fun stop() = server.close()
}
