package dev.marquart.aos.desktop.system

import dev.marquart.aos.desktop.Os
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * One aOS per user: the first one listens on 127.0.0.1 (the port in instance.port, with a random token so no other
 * program can send it links). A second start hands its argument (an aos-pair:// link, or nothing: "show the
 * window") to the first one and ends.
 */
class SingleInstance(private val dir: File = Os.configDir) {
    private val portFile = File(dir, "instance.port")
    private var server: ServerSocket? = null

    /** Sends `message` to a running instance. True when one took it. */
    fun handOver(message: String): Boolean {
        val text = runCatching { portFile.readText().trim() }.getOrNull() ?: return false
        val (port, token) = text.split(' ').takeIf { it.size == 2 } ?: return false
        return runCatching {
            Socket(InetAddress.getLoopbackAddress(), port.toInt()).use { socket ->
                socket.soTimeout = 2_000
                socket.getOutputStream().write("$token\n$message\n".toByteArray())
                socket.getOutputStream().flush()
                socket.getInputStream().read() == 'k'.code
            }
        }.getOrDefault(false)
    }

    /** Listens for later starts; `onMessage` gets their argument (on a background thread). */
    fun listen(onMessage: (String) -> Unit) {
        val token = java.util.UUID.randomUUID().toString()
        val socket = ServerSocket(0, 5, InetAddress.getLoopbackAddress())
        server = socket
        Os.writePrivate(portFile, "${socket.localPort} $token".toByteArray())
        thread(name = "aos-instance", isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                runCatching {
                    client.use {
                        it.soTimeout = 2_000
                        val lines = it.getInputStream().bufferedReader().let { r -> listOf(r.readLine(), r.readLine()) }
                        if (lines[0] == token) {
                            it.getOutputStream().write('k'.code)
                            onMessage(lines[1] ?: "")
                        }
                    }
                }
            }
        }
    }

    fun close() {
        runCatching { server?.close() }
        portFile.delete()
    }
}
