// The demo's screen sharing server in the app (aOS's iOS DemoScreenServer for Android and the desktop): plain RFB 3.8 on 127.0.0.1, no
// authentication, raw encoding in the pixel format the client asks for. Unlike the iPhone's still picture it answers:
// clicks paint where they land, typed keys and text appear on it, clipboard text too, so a check in the emulator can
// see input arrive. Only debug builds start it. Written for aOS's Android app on 2026-11-19.

package dev.marquart.aos.screen

import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import kotlin.concurrent.thread

class DemoScreenServer private constructor(private val socket: ServerSocket, val width: Int, val height: Int, private val name: String) {
    val port: Int get() = socket.localPort

    /** What arrived (for checks): pointer events (x, y, buttons), keysyms that went down, clipboard text. */
    val pointerEvents: MutableList<Triple<Int, Int, Int>> = Collections.synchronizedList(ArrayList())
    val keysDown: MutableList<Int> = Collections.synchronizedList(ArrayList())
    @Volatile var clipboard: String? = null
        private set

    private val lock = Any()
    /** The picture (the platform draws it: DemoPicture in ScreenPlatform.kt). */
    private val picture = DemoPicture(width, height)
    private var typed = StringBuilder()
    private val clients = Collections.synchronizedList(ArrayList<Client>())

    init {
        drawBackground()
    }

    fun stop() {
        runCatching { socket.close() }
        synchronized(clients) { clients.toList() }.forEach { it.close() }
    }

    private fun accept() {
        while (!socket.isClosed) {
            val s = try {
                socket.accept()
            } catch (_: Exception) {
                break
            }
            val client = Client(s)
            clients += client
            thread(name = "aos-demo-screen", isDaemon = true) { client.serve() }
        }
    }

    // The picture

    private fun drawBackground() = synchronized(lock) {
        picture.background(name)
        drawTyped()
    }

    private fun drawTyped() = picture.typed("> " + typed.takeLast(60).toString())

    private fun changed(x: Int, y: Int, w: Int, h: Int) {
        synchronized(clients) { clients.toList() }.forEach { it.changed(x, y, w, h) }
    }

    private fun pointer(x: Int, y: Int, buttons: Int) {
        pointerEvents += Triple(x, y, buttons)
        if (buttons and 1 == 0) return
        synchronized(lock) {
            picture.dot(x, y)
        }
        changed(x - 12, y - 12, 24, 24)
    }

    private fun key(keysym: Int, down: Boolean) {
        if (!down) return
        keysDown += keysym
        synchronized(lock) {
            when {
                keysym == Keysym.BACKSPACE -> if (typed.isNotEmpty()) typed.setLength(typed.length - 1)
                keysym == Keysym.RETURN -> typed.clear()
                keysym in 0x20..0xff -> typed.append(keysym.toChar())
                keysym and 0xff000000.toInt() == 0x01000000 -> typed.appendCodePoint(keysym and 0xffffff)
                else -> return
            }
            drawTyped()
        }
        changed(0, (height * 0.40f).toInt(), width, (height * 0.08f).toInt() + 2)
    }

    private fun cutText(text: String) {
        clipboard = text
        synchronized(lock) {
            typed.append("[clipboard: ").append(text.take(40)).append("]")
            drawTyped()
        }
        changed(0, (height * 0.40f).toInt(), width, (height * 0.08f).toInt() + 2)
    }

    /** One viewer: the handshake, then its messages. */
    private inner class Client(private val s: Socket) {
        private val out: OutputStream = s.getOutputStream()
        private var bigEndian = false
        private var shifts = intArrayOf(16, 8, 0)
        private var maxima = intArrayOf(255, 255, 255)
        private var bytesPerPixel = 4
        private var waiting = false
        private var dirty: IntArray? = null

        fun close() = runCatching { s.close() }

        fun serve() {
            try {
                val input = DataInputStream(s.getInputStream())
                write("RFB 003.008\n".toByteArray())
                input.readFully(ByteArray(12))
                write(byteArrayOf(1, 1)) // one security type: None
                input.readUnsignedByte()
                write(byteArrayOf(0, 0, 0, 0)) // SecurityResult OK
                input.readUnsignedByte() // ClientInit
                val nameBytes = name.toByteArray()
                val init = java.io.ByteArrayOutputStream()
                init.write(u16(width)); init.write(u16(height))
                init.write(byteArrayOf(32, 24, 0, 1)) // 32 bits, depth 24, little endian, true color
                init.write(u16(255)); init.write(u16(255)); init.write(u16(255))
                init.write(byteArrayOf(16, 8, 0, 0, 0, 0))
                init.write(u32(nameBytes.size)); init.write(nameBytes)
                write(init.toByteArray())
                while (true) {
                    when (val type = input.readUnsignedByte()) {
                        0 -> { // SetPixelFormat
                            val f = ByteArray(19).also { input.readFully(it) }
                            val p = f.copyOfRange(3, 19)
                            bytesPerPixel = maxOf(1, (p[0].toInt() and 0xff) / 8)
                            bigEndian = p[2].toInt() != 0
                            maxima = intArrayOf(be16(p, 4), be16(p, 6), be16(p, 8))
                            shifts = intArrayOf(p[10].toInt() and 0xff, p[11].toInt() and 0xff, p[12].toInt() and 0xff)
                        }
                        2 -> { // SetEncodings
                            input.readUnsignedByte()
                            val count = input.readUnsignedShort()
                            input.readFully(ByteArray(4 * count))
                        }
                        3 -> { // FramebufferUpdateRequest
                            val incremental = input.readUnsignedByte() != 0
                            input.readFully(ByteArray(8))
                            if (!incremental) sendRect(0, 0, width, height) else requestIncremental()
                        }
                        4 -> { // KeyEvent
                            val down = input.readUnsignedByte() != 0
                            input.readFully(ByteArray(2))
                            key(input.readInt(), down)
                        }
                        5 -> { // PointerEvent
                            val buttons = input.readUnsignedByte()
                            val x = input.readUnsignedShort()
                            val y = input.readUnsignedShort()
                            pointer(x, y, buttons)
                        }
                        6 -> { // ClientCutText
                            input.readFully(ByteArray(3))
                            val length = input.readInt()
                            val text = ByteArray(length).also { input.readFully(it) }
                            cutText(String(text, Charsets.ISO_8859_1))
                        }
                        else -> throw IllegalStateException("message $type isn't plain RFB")
                    }
                }
            } catch (_: Exception) {
            } finally {
                clients -= this
                close()
            }
        }

        private fun requestIncremental() {
            val rect = synchronized(this) {
                val d = dirty
                if (d == null) waiting = true
                dirty = null
                d
            } ?: return
            sendRect(rect[0], rect[1], rect[2] - rect[0], rect[3] - rect[1])
        }

        fun changed(x: Int, y: Int, w: Int, h: Int) {
            val l = x.coerceIn(0, width); val t = y.coerceIn(0, height)
            val r = (x + w).coerceIn(0, width); val b = (y + h).coerceIn(0, height)
            if (r <= l || b <= t) return
            val send = synchronized(this) {
                val d = dirty
                dirty = if (d == null) intArrayOf(l, t, r, b) else intArrayOf(minOf(d[0], l), minOf(d[1], t), maxOf(d[2], r), maxOf(d[3], b))
                if (waiting) {
                    waiting = false
                    dirty.also { dirty = null }
                } else null
            } ?: return
            thread(isDaemon = true) { runCatching { sendRect(send[0], send[1], send[2] - send[0], send[3] - send[1]) } }
        }

        private fun sendRect(x: Int, y: Int, w: Int, h: Int) {
            val pixels = IntArray(w * h)
            synchronized(lock) { picture.pixels(pixels, x, y, w, h) }
            val data = ByteArray(16 + w * h * bytesPerPixel)
            u16(0).copyInto(data, 0) // FramebufferUpdate, padding
            u16(1).copyInto(data, 2)
            u16(x).copyInto(data, 4); u16(y).copyInto(data, 6); u16(w).copyInto(data, 8); u16(h).copyInto(data, 10)
            u32(0).copyInto(data, 12) // raw
            var at = 16
            for (argb in pixels) {
                val r = (argb shr 16 and 0xff) * maxima[0] / 255
                val g = (argb shr 8 and 0xff) * maxima[1] / 255
                val b = (argb and 0xff) * maxima[2] / 255
                val value = (r shl shifts[0]) or (g shl shifts[1]) or (b shl shifts[2])
                for (k in 0 until bytesPerPixel) {
                    val shift = if (bigEndian) 8 * (bytesPerPixel - 1 - k) else 8 * k
                    data[at + k] = (value shr shift).toByte()
                }
                at += bytesPerPixel
            }
            write(data)
        }

        private fun write(bytes: ByteArray) = synchronized(out) {
            out.write(bytes)
            out.flush()
        }
    }

    companion object {
        /** Starts a server on 127.0.0.1 (a free port) with a picture of `width` by `height`. */
        fun start(width: Int = 1280, height: Int = 800, name: String = "Demo"): DemoScreenServer {
            val socket = ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"))
            return DemoScreenServer(socket, width, height, name).also { server -> thread(name = "aos-demo-accept", isDaemon = true) { server.accept() } }
        }

        private fun u16(v: Int) = byteArrayOf((v shr 8).toByte(), v.toByte())
        private fun u32(v: Int) = byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte())
        private fun be16(b: ByteArray, at: Int) = (b[at].toInt() and 0xff shl 8) or (b[at + 1].toInt() and 0xff)
    }
}
