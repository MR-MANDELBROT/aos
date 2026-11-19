package dev.marquart.aos.screen

import dev.marquart.aos.desktop.store.Prefs
import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.GradientPaint
import java.awt.RenderingHints
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO
import javax.swing.SwingUtilities

// The desktop side of the screen's shared code (shared-ui/.../screen); Android has the same declarations
// (app/.../screen/ScreenPlatform.kt). High performance video isn't decoded on the desktop (no cheap HEVC/H.264 decoder
// in the JVM): `DecoderSupport` offers no codec, so sessions run in standard mode (framebuffer updates).

typealias PlatformBitmap = BufferedImage

/** No video surface on the desktop (standard mode only). */
typealias VideoSurface = Any

fun uptimeMillis(): Long = System.nanoTime() / 1_000_000

fun postToMain(block: Runnable) = SwingUtilities.invokeLater(block)

object ScreenLog {
    fun info(message: String) {
        if (System.getProperty("aos.debug") != null) System.err.println("aos-screen: $message")
    }
}

object ScreenImages {
    fun framebufferBitmap(fb: Framebuffer, maxWidth: Int): BufferedImage? {
        val sampled = SampledPixels.of(fb, maxWidth) ?: return null
        return BufferedImage(sampled.width, sampled.height, BufferedImage.TYPE_INT_RGB).also {
            it.setRGB(0, 0, sampled.width, sampled.height, sampled.pixels, 0, sampled.width)
        }
    }

    fun jpeg(bitmap: BufferedImage): ByteArray {
        val image = if (bitmap.width <= 1280) bitmap else {
            val h = bitmap.height * 1280 / bitmap.width
            BufferedImage(1280, h, BufferedImage.TYPE_INT_RGB).also {
                val g = it.createGraphics()
                g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR)
                g.drawImage(bitmap, 0, 0, 1280, h, null)
                g.dispose()
            }
        }
        return ByteArrayOutputStream().use {
            ImageIO.write(image, "jpg", it)
            it.toByteArray()
        }
    }

    fun decode(jpeg: ByteArray): BufferedImage? = runCatching { ImageIO.read(jpeg.inputStream()) }.getOrNull()
}

/** The desktop decodes no video: nothing is offered, the session stays in standard mode. */
object DecoderSupport {
    val codecs: Set<VideoCodec> = emptySet()
    val maximumPixelRate: Long = 0
}

/** Never used on the desktop (DecoderSupport offers no codec); there for the shared SessionModel. */
class VideoDecoder(
    private val onSize: (width: Int, height: Int) -> Unit,
    private val requestKeyframe: () -> Unit,
    private val onFailure: (String) -> Unit,
) {
    fun setSurface(surface: VideoSurface?) {}
    fun format(info: VideoFormatInfo) = onFailure("no video decoder on this computer")
    fun unit(unit: VideoUnit) {}
    fun release() {}
}

/** The demo screen's picture, drawn with Java2D. */
class DemoPicture(private val width: Int, private val height: Int) {
    private val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)

    private fun draw(block: (java.awt.Graphics2D) -> Unit) {
        val g = image.createGraphics()
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
        try {
            block(g)
        } finally {
            g.dispose()
        }
    }

    fun background(name: String) = draw { g ->
        g.paint = GradientPaint(0f, 0f, Color(0x1d, 0x3b, 0x6e), width.toFloat(), height.toFloat(), Color(0x6a, 0x2c, 0x70))
        g.fillRect(0, 0, width, height)
        g.color = Color(255, 255, 255, 60)
        g.stroke = BasicStroke(1f)
        for (x in 0 until width step 80) g.drawLine(x, 0, x, height)
        for (y in 0 until height step 80) g.drawLine(0, y, width, y)
        g.color = Color.WHITE
        g.font = Font(Font.SANS_SERIF, Font.PLAIN, height / 14)
        g.drawString(name, (width * 0.06f).toInt(), (height * 0.18f).toInt())
        g.font = Font(Font.SANS_SERIF, Font.PLAIN, height / 32)
        g.color = Color(255, 255, 255, 220)
        g.drawString("aOS demo screen: plain RFB in the app", (width * 0.06f).toInt(), (height * 0.26f).toInt())
        g.drawString("Clicks paint dots, keys type below.", (width * 0.06f).toInt(), (height * 0.31f).toInt())
        g.color = Color(240, 240, 240, 160)
        g.fillRect(0, 0, width, height / 36)
        g.fillRoundRect((width * 0.25f).toInt(), (height * 0.9f).toInt(), width / 2, (height * 0.08f).toInt(), 40, 40)
    }

    fun typed(text: String) = draw { g ->
        val top = (height * 0.40f).toInt()
        g.color = Color(0, 0, 0, 200)
        g.fillRoundRect((width * 0.05f).toInt(), top, (width * 0.9f).toInt(), (height * 0.08f).toInt(), 24, 24)
        g.color = Color.WHITE
        g.font = Font(Font.MONOSPACED, Font.PLAIN, height / 24)
        g.drawString(text, (width * 0.07f).toInt(), top + (height * 0.055f).toInt())
    }

    fun dot(x: Int, y: Int) = draw { g ->
        g.color = Color(0xff, 0xc4, 0x00)
        g.fillOval(x - 10, y - 10, 20, 20)
    }

    fun pixels(out: IntArray, x: Int, y: Int, w: Int, h: Int) {
        image.getRGB(x, y, w, h, out, 0, w)
    }
}

/** The desktop's Prefs as the screen store's KeyValues. */
class PrefsKeyValues(private val prefs: Prefs) : KeyValues {
    override fun getBoolean(name: String, default: Boolean) = prefs.bool(name, default)
    override fun getFloat(name: String, default: Float) = prefs.string(name)?.toFloatOrNull() ?: default
    override fun getString(name: String, default: String?): String? = prefs.string(name) ?: default
    override fun putBoolean(name: String, value: Boolean) = prefs.set(name, value)
    override fun putFloat(name: String, value: Float) = prefs.set(name, value)
    override fun putString(name: String, value: String) = prefs.set(name, value)
    override fun remove(name: String) = prefs.set(name, null)
    override fun all(): Map<String, Any?> = prefs.all()
}
