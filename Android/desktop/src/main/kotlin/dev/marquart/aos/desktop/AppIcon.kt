package dev.marquart.aos.desktop

import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import org.jetbrains.skia.Image
import java.awt.image.BufferedImage
import javax.imageio.ImageIO

/** The app's icon (the same art as Android's launcher icon), for the window, the tray and notifications. */
object AppIcon {
    private val bytes: ByteArray by lazy {
        AppIcon::class.java.getResourceAsStream("/aos/drawable/aos_icon_art.png")!!.use { it.readBytes() }
    }

    val bitmap: ImageBitmap by lazy { Image.makeFromEncoded(bytes).toComposeImageBitmap() }

    fun painter(): Painter = BitmapPainter(bitmap)

    val awtImage: BufferedImage by lazy { ImageIO.read(bytes.inputStream()) }

    /** The icon as a file (Linux notifications and .desktop entries take a path). */
    val file: java.io.File by lazy {
        val f = java.io.File(Os.configDir, "aos.png")
        if (!f.isFile) f.writeBytes(bytes)
        f
    }
}
