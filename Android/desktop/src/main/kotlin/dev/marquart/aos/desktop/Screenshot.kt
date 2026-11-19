package dev.marquart.aos.desktop

import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import dev.marquart.aos.ui.demo.Demo
import dev.marquart.aos.ui.demo.DemoOptions
import dev.marquart.aos.ui.platform.PlatformContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.jetbrains.skia.EncodedImageFormat
import java.io.File

/** One picture of the demo's window, rendered off screen (Compose's ImageComposeScene): for the screenshots. */
object Screenshot {
    fun render(options: DemoOptions, file: File, width: Int, height: Int, waitMillis: Long, scale: Float = 2f,
               after: (dev.marquart.aos.ui.AosUi) -> Unit = {}) = runBlocking {
        withContext(Dispatchers.Main) {
            val ui = Demo.makeUi(PlatformContext(DesktopStrings.locale), options, deviceName = "Max’ PC")
            after(ui)
            val scene = ImageComposeScene((width * scale).toInt(), (height * scale).toInt(), Density(scale)) {
                AppContent(ui, null, options.dark)
            }
            try {
                // Let the demo's script run (loading, the sheets it opens) and the animations settle.
                val start = System.nanoTime()
                var frame = 0L
                while ((System.nanoTime() - start) / 1_000_000 < waitMillis) {
                    scene.render(frame)
                    frame += 16_000_000
                    delay(16)
                }
                repeat(60) { scene.render(frame); frame += 16_000_000 }
                val image = scene.render(frame)
                file.parentFile?.mkdirs()
                file.writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
            } finally {
                scene.close()
            }
        }
    }

    /** The set of pictures for the README and the coordinator (`--shots=<folder>`). */
    fun renderAll(dir: File, width: Int, height: Int) {
        val shots = listOf(
            Triple("overview-de-dark", "de", DemoOptions(dark = true)),
            Triple("overview-en-light", "en", DemoOptions(dark = false)),
            Triple("signin-de", "de", DemoOptions(sheet = "signin", dark = true)),
            Triple("approval-de", "de", DemoOptions(sheet = "approval", dark = true)),
            Triple("help-de", "de", DemoOptions(sheet = "help", dark = true)),
            Triple("settings-de", "de", DemoOptions(sheet = "settings", dark = true)),
            Triple("settings-en-light", "en", DemoOptions(sheet = "settings", dark = false)),
            Triple("connection-de", "de", DemoOptions(sheet = "connection", dark = true)),
            Triple("key-de", "de", DemoOptions(sheet = "key", dark = true)),
            Triple("pairing-paste-de", "de", DemoOptions(sheet = "pairing-scan", dark = true)),
            Triple("pairing-confirm-de", "de", DemoOptions(sheet = "pairing", dark = true)),
            Triple("welcome-de", "de", DemoOptions(unpaired = true, dark = true)),
            Triple("terminal-sessions-de", "de", DemoOptions(tab = "terminal", dark = true)),
            Triple("screen-de", "de", DemoOptions(tab = "screen", dark = true)),
            Triple("lock-de", "de", DemoOptions(sheet = "lock", dark = true)),
            Triple("chats-de", "de", DemoOptions(sheet = "chats", dark = true)),
            Triple("routines-de", "de", DemoOptions(sheet = "routines", dark = true)),
        )
        for ((name, lang, options) in shots) {
            DesktopStrings.use(java.util.Locale.forLanguageTag(lang))
            dev.marquart.aos.screen.ScreenHub.instance = null
            render(options, File(dir, "$name.png"), width, height, 2500)
            println("shot $name")
        }
        DesktopStrings.use(java.util.Locale.GERMAN)
        dev.marquart.aos.screen.ScreenHub.instance = null
        render(DemoOptions(tab = "screen", dark = true), File(dir, "screen-session-de.png"), width, height, 6000) { ui ->
            ui.model.showScreen(dev.marquart.aos.core.ScreenTarget.WORKSPACE)
        }
        println("shot screen-session-de")
        renderTerminal(File(dir, "terminal-jediterm.png"), 900, 520)
        println("shot terminal-jediterm")
    }

    /** The terminal itself (JediTerm fed by MacTerminal with the demo's output), painted off screen. */
    fun renderTerminal(file: File, width: Int, height: Int) = runBlocking {
        val terminal = withContext(Dispatchers.Main) {
            val ui = Demo.makeUi(PlatformContext(DesktopStrings.locale), DemoOptions(tab = "terminal", dark = true), deviceName = "Max’ PC")
            val terminals = dev.marquart.aos.desktop.terminal.DesktopTerminals.of(ui.model)
            terminals.dark = true
            terminals.openNew(Demo.mac)
            terminals.screenOf(terminals.existing(Demo.mac.id)!!)
        }
        val frame = withContext(Dispatchers.Main) {
            javax.swing.JFrame("aOS terminal").apply {
                isUndecorated = true
                contentPane.add(terminal.widget)
                setSize(width, height)
                setLocation(-10_000, -10_000)
                isVisible = true
            }
        }
        delay(2_500)
        withContext(Dispatchers.Main) {
            val image = java.awt.image.BufferedImage(width * 2, height * 2, java.awt.image.BufferedImage.TYPE_INT_RGB)
            val g = image.createGraphics()
            g.scale(2.0, 2.0)
            frame.contentPane.paint(g)
            g.dispose()
            file.parentFile?.mkdirs()
            javax.imageio.ImageIO.write(image, "png", file)
            frame.dispose()
        }
    }
}
