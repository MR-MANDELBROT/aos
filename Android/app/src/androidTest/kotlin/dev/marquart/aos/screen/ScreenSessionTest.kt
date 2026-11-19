package dev.marquart.aos.screen

import android.graphics.ImageFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * On a phone or the emulator: libsharing (the Go library) against the demo's plain RFB server in the app, with
 * aOS's session model (standard mode: the DirectFramebuffer, dirty rectangles, pointer, keys, clipboard); and the high
 * performance decoder (MediaCodec through VideoDecoder) with H.264 and HEVC streams made by ffmpeg
 * (assets/screen, `testsrc` 640x400), fed as libsharing hands them over: parameter sets apart, units length-prefixed.
 */
@RunWith(AndroidJUnit4::class)
class ScreenSessionTest {
    private val main = Handler(Looper.getMainLooper())

    private fun waitFor(what: String, seconds: Int = 20, condition: () -> Boolean) {
        val until = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < until) {
            if (condition()) return
            Thread.sleep(50)
        }
        fail("timed out waiting for $what")
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    @Test fun standardModeShowsThePictureAndInputArrives() {
        val server = DemoScreenServer.start(640, 400, "Test")
        try {
            val route = SessionRoute("test", "Test", "127.0.0.1", server.port, "", null, followsWindowShape = false, sharesClipboard = false)
            lateinit var model: SessionModel
            var phone: String? = "copied on the phone"
            onMain {
                model = SessionModel(route, RemoteSessions.factory, { main.post(it) })
                model.clipboard = object : ClipboardBridge {
                    override fun read() = phone
                    override fun write(text: String) { phone = text }
                }
                model.start()
            }
            waitFor("connected with a picture") { model.phase == SessionPhase.Connected && model.hasPicture }
            val fb = model.framebuffer!!
            assertEquals(640, fb.width)
            assertEquals(400, fb.height)
            // libsharing wrote the server's picture into the DirectFramebuffer: B, G, R, X
            fun pixel(x: Int, y: Int): Int {
                val at = y * fb.bytesPerRow + x * 4
                return (fb.pixels.get(at + 2).toInt() and 0xff shl 16) or (fb.pixels.get(at + 1).toInt() and 0xff shl 8) or (fb.pixels.get(at).toInt() and 0xff)
            }
            waitFor("the picture in the framebuffer") { pixel(320, 300) != 0 }

            // A click: the server paints a yellow dot and sends that rectangle again (an incremental update)
            val dirty = AtomicInteger()
            onMain {
                model.pictureSink = object : PictureSink {
                    override fun framebufferChanged(framebuffer: Framebuffer) {}
                    override fun framebufferDirty(x: Int, y: Int, width: Int, height: Int) { dirty.incrementAndGet() }
                    override fun cursorChanged() {}
                    override fun redraw() {}
                    override fun videoChanged(active: Boolean) {}
                }
                model.movePointer(100f, 300f)
                model.click(PointerButton.PRIMARY)
            }
            waitFor("the click at the server") { server.pointerEvents.any { it == Triple(100, 300, 1) } }
            waitFor("the dot in the picture") { pixel(100, 300) == 0xffc400 }
            assertTrue(dirty.get() > 0)

            // Text from the on-screen keyboard and a key from the key row
            onMain {
                model.keyboard.replaceText(0, "Hi!")
                model.keyboard.typeKey(MacKey.RETURN)
            }
            waitFor("the keys at the server") { server.keysDown.containsAll(listOf('H'.code, 'i'.code, '!'.code, Keysym.RETURN)) }

            // The phone's clipboard to the Mac on request
            onMain { model.sendClipboardToMac() }
            waitFor("the clipboard at the server") { server.clipboard == "copied on the phone" }

            onMain { model.close() }
            assertTrue(model.isClosed)
        } finally {
            server.stop()
        }
    }

    @Test fun h264StreamsAreDecoded() = decode("screen/testsrc.h264", VideoCodec.H264)

    @Test fun hevcStreamsAreDecoded() = decode("screen/testsrc.hevc", VideoCodec.HEVC)

    private fun decode(asset: String, codec: VideoCodec) {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open(asset).use { it.readBytes() }
        val (parameterSets, units) = AnnexB.accessUnits(bytes, codec)
        assertTrue(units.size >= 30, "${units.size} units")
        val thread = HandlerThread("reader").apply { start() }
        val reader = ImageReader.newInstance(640, 400, ImageFormat.YUV_420_888, 4)
        val frames = AtomicInteger()
        reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.close(); frames.incrementAndGet() }, Handler(thread.looper))
        var size: Pair<Int, Int>? = null
        var failure: String? = null
        val keyframes = AtomicInteger()
        val decoder = VideoDecoder({ w, h -> size = w to h }, { keyframes.incrementAndGet() }, { failure = it })
        try {
            decoder.setSurface(reader.surface)
            decoder.format(VideoFormatInfo(codec, parameterSets, 400, 1, false))
            // Units as libsharing delivers them: length-prefixed, 24 kHz clock; the first one isn't a sync unit, so
            // the decoder waits for the next sync unit.
            var timestamp = 0L
            for ((i, unit) in units.withIndex()) {
                val prefixed = AnnexB.lengthPrefixed(unit.second)
                decoder.unit(VideoUnit(prefixed, timestamp, 24_000, sync = unit.first, discontinuity = i == 0))
                timestamp += 800
                Thread.sleep(15)
            }
            waitFor("decoded frames", 15) { frames.get() >= 20 || failure != null }
            assertEquals(null, failure)
            assertEquals(640 to 400, size)
            assertTrue(keyframes.get() >= 1, "asks for a keyframe when it starts")
        } finally {
            decoder.release()
            reader.close()
            thread.quitSafely()
        }
    }
}

/** Splits an Annex B stream (what ffmpeg writes) the way libsharing hands video over. */
object AnnexB {
    fun nalUnits(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Pair<Int, Int>>() // (start code position, NAL start)
        var i = 0
        while (i + 3 <= data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                starts += (if (i > 0 && data[i - 1].toInt() == 0) i - 1 else i) to i + 3
                i += 3
            } else i++
        }
        return starts.mapIndexed { k, (_, nal) -> data.copyOfRange(nal, if (k + 1 < starts.size) starts[k + 1].first else data.size) }
    }

    /** The parameter sets, and the access units (sync, NAL units) of the pictures. */
    fun accessUnits(data: ByteArray, codec: VideoCodec): Pair<List<ByteArray>, List<Pair<Boolean, List<ByteArray>>>> {
        val sets = ArrayList<ByteArray>()
        val units = ArrayList<Pair<Boolean, MutableList<ByteArray>>>()
        for (nal in nalUnits(data)) {
            val type = VideoStream.nalType(codec, nal)
            when (codec) {
                VideoCodec.H264 -> when (type) {
                    7, 8 -> if (sets.none { it.contentEquals(nal) }) sets += nal
                    1, 5 -> {
                        val first = nal[1].toInt() and 0x80 != 0
                        if (first || units.isEmpty()) units += (type == 5) to mutableListOf(nal) else units.last().second += nal
                    }
                }
                VideoCodec.HEVC -> when (type) {
                    32, 33, 34 -> if (sets.none { it.contentEquals(nal) }) sets += nal
                    in 0..21 -> {
                        val first = nal[2].toInt() and 0x80 != 0
                        if (first || units.isEmpty()) units += (type in 16..21) to mutableListOf(nal) else units.last().second += nal
                    }
                }
            }
        }
        return sets to units
    }

    fun lengthPrefixed(nals: List<ByteArray>): ByteArray {
        val out = ByteArray(nals.sumOf { it.size + 4 })
        var at = 0
        for (nal in nals) {
            out[at] = (nal.size shr 24).toByte(); out[at + 1] = (nal.size shr 16).toByte()
            out[at + 2] = (nal.size shr 8).toByte(); out[at + 3] = nal.size.toByte()
            nal.copyInto(out, at + 4)
            at += nal.size + 4
        }
        return out
    }
}
