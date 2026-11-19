package dev.marquart.aos.desktop.terminal

import com.jediterm.core.util.TermSize
import com.jediterm.terminal.TerminalColor
import com.jediterm.terminal.TerminalMode
import com.jediterm.terminal.TtyConnector
import com.jediterm.terminal.model.JediTerminal
import com.jediterm.terminal.ui.JediTermWidget
import com.jediterm.terminal.ui.settings.DefaultSettingsProvider
import dev.marquart.aos.terminal.MacTerminal
import dev.marquart.aos.terminal.TerminalScreen
import java.awt.Font
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharsetDecoder
import java.nio.charset.CodingErrorAction
import java.util.EnumSet
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * JetBrains' JediTerm as the screen a `MacTerminal` feeds on the desktop. JediTerm's emulator runs on its own thread
 * and reads from a `TtyConnector`: here a queue that `append` fills with the Mac's output (decoded as UTF-8 across
 * chunks). What JediTerm sends back (typing, pastes, the emulator's answers) goes to `onInput` (MacTerminal.send),
 * size changes to `onResize` (MacTerminal.resized). The widget lives as long as the terminal: leaving the tab and
 * coming back shows the same screen.
 */
class JediTermScreen(
    private val events: TerminalScreen.Events,
    fontSize: Int,
    dark: Boolean,
) : TerminalScreen {
    /** Typing and the emulator's answers (set by the controller to MacTerminal.send). */
    @Volatile var onInput: (ByteArray) -> Unit = events::reply

    /** The size in characters changed (MacTerminal.resized). */
    @Volatile var onResize: (columns: Int, rows: Int) -> Unit = { _, _ -> }

    private val chunks = LinkedBlockingQueue<CharArray>()
    private var pending: CharArray? = null
    private var pendingAt = 0
    @Volatile private var open = true
    private val decoder: CharsetDecoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPLACE).onUnmappableCharacter(CodingErrorAction.REPLACE)
    private var leftover = ByteArray(0)

    private val settings = Settings(fontSize.toFloat(), dark)
    val widget: JediTermWidget = JediTermWidget(80, 24, settings)

    private val connector = object : TtyConnector {
        override fun read(buf: CharArray, offset: Int, length: Int): Int {
            while (open) {
                val current = pending ?: chunks.poll(250, TimeUnit.MILLISECONDS)?.also { pending = it; pendingAt = 0 } ?: continue
                val n = minOf(length, current.size - pendingAt)
                System.arraycopy(current, pendingAt, buf, offset, n)
                pendingAt += n
                if (pendingAt >= current.size) pending = null
                return n
            }
            return -1
        }

        override fun write(bytes: ByteArray) = onInput(bytes)
        override fun write(string: String) = onInput(string.toByteArray())
        override fun isConnected(): Boolean = open
        override fun resize(termSize: TermSize) = onResize(termSize.columns, termSize.rows)
        override fun waitFor(): Int {
            while (open) Thread.sleep(500)
            return 0
        }
        override fun ready(): Boolean = pending != null || chunks.isNotEmpty()
        override fun getName(): String = "Mac"
        override fun close() {
            open = false
        }
    }

    init {
        widget.ttyConnector = connector
        widget.start()
    }

    private val buffer get() = widget.terminalTextBuffer
    private val terminal get() = widget.terminal as JediTerminal
    private var historySeen = 0

    // TerminalScreen (MacTerminal's dispatcher: the Swing thread)

    override fun append(bytes: ByteArray) {
        val all = if (leftover.isEmpty()) bytes else leftover + bytes
        val input = ByteBuffer.wrap(all)
        val out = CharBuffer.allocate(all.size + 1)
        decoder.decode(input, out, false)
        leftover = if (input.hasRemaining()) ByteArray(input.remaining()).also { input.get(it) } else ByteArray(0)
        out.flip()
        if (out.hasRemaining()) chunks.add(CharArray(out.remaining()).also { out.get(it) })
    }

    /** JediTerm keeps the scrolled lines in its history; the counter is how much it grew since it was cleared. */
    override val scrollCounter: Int get() = (locked { buffer.historyLinesCount } - historySeen).coerceAtLeast(0)
    override fun clearScrollCounter() {
        historySeen = locked { buffer.historyLinesCount }
    }

    override val cursorRow: Int get() = (terminal.cursorY - 1).coerceAtLeast(0)
    override val columns: Int get() = buffer.width
    override val rows: Int get() = buffer.height
    override val transcriptRows: Int get() = locked { buffer.historyLinesCount }
    override val cursorKeysApplicationMode: Boolean get() = TerminalMode.CursorKey in modes()
    override val bracketedPaste: Boolean get() = TerminalMode.BracketedPasteMode in modes()
    override fun rowText(row: Int): String = locked { buffer.getLine(row).text }
    override fun lineWraps(row: Int): Boolean = locked { runCatching { buffer.getLine(row).isWrapped }.getOrDefault(false) }

    private inline fun <T> locked(block: () -> T): T {
        buffer.lock()
        try {
            return block()
        } finally {
            buffer.unlock()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun modes(): Set<TerminalMode> = runCatching {
        (modesField.get(terminal) as EnumSet<TerminalMode>).clone()
    }.getOrDefault(emptySet())

    fun setFontSize(size: Int) {
        settings.size = size.toFloat()
        runCatching { reinitFont.invoke(widget.terminalPanel) }
        widget.terminalPanel.revalidate()
        widget.terminalPanel.repaint()
    }

    fun close() {
        open = false
        runCatching { widget.close() }
    }

    private class Settings(var size: Float, private val dark: Boolean) : DefaultSettingsProvider() {
        override fun getTerminalFontSize(): Float = size
        override fun getTerminalFont(): Font {
            val names = listOf("JetBrains Mono", "Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Menlo", Font.MONOSPACED)
            val available = java.awt.GraphicsEnvironment.getLocalGraphicsEnvironment().availableFontFamilyNames.toSet()
            return Font(names.first { it in available || it == Font.MONOSPACED }, Font.PLAIN, size.toInt())
        }
        override fun getDefaultForeground(): TerminalColor = if (dark) TerminalColor.rgb(230, 230, 235) else TerminalColor.rgb(29, 29, 31)
        override fun getDefaultBackground(): TerminalColor = if (dark) TerminalColor.rgb(28, 28, 30) else TerminalColor.rgb(255, 255, 255)
        override fun getDefaultStyle(): com.jediterm.terminal.TextStyle = com.jediterm.terminal.TextStyle(defaultForeground, defaultBackground)
        override fun getBufferMaxLinesCount(): Int = MacTerminal.SCROLLBACK
        override fun copyOnSelect(): Boolean = false
        override fun audibleBell(): Boolean = false
        override fun scrollToBottomOnTyping(): Boolean = true
    }

    private companion object {
        val modesField = JediTerminal::class.java.getDeclaredField("myModes").apply { isAccessible = true }
        val reinitFont = com.jediterm.terminal.ui.TerminalPanel::class.java.getDeclaredMethod("reinitFontAndResize").apply { isAccessible = true }
    }
}
