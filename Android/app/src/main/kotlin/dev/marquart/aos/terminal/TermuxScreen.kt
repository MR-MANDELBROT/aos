package dev.marquart.aos.terminal

import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import java.lang.reflect.Method

/** Termux's TerminalEmulator as the screen a `MacTerminal` feeds (the view, TerminalHost, shows `emulator`). */
class TermuxScreen(private val events: TerminalScreen.Events) : TerminalScreen {
    private val output = object : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) = events.reply(data.copyOfRange(offset, offset + count))
        override fun titleChanged(oldTitle: String?, newTitle: String?) {}
        override fun onCopyTextToClipboard(text: String) = events.copyToClipboard(text)
        override fun onPasteTextFromClipboard() {}
        override fun onBell() {}
        override fun onColorsChanged() = events.colorsChanged()
    }

    val emulator: TerminalEmulator = TerminalEmulator(output, 80, 24, 0, 0, MacTerminal.SCROLLBACK, QuietSessionClient)

    override fun append(bytes: ByteArray) = emulator.append(bytes, bytes.size)
    override val scrollCounter: Int get() = emulator.scrollCounter
    override fun clearScrollCounter() = emulator.clearScrollCounter()
    override val cursorRow: Int get() = emulator.cursorRow
    override val columns: Int get() = emulator.mColumns
    override val rows: Int get() = emulator.mRows
    override val transcriptRows: Int get() = emulator.screen.activeTranscriptRows
    override val cursorKeysApplicationMode: Boolean get() = emulator.isCursorKeysApplicationMode

    // Termux keeps the mode to itself.
    override val bracketedPaste: Boolean get() = try {
        decsetBit?.invoke(emulator, 1 shl 10) as? Boolean ?: false
    } catch (_: Exception) {
        false
    }

    override fun rowText(row: Int): String = emulator.screen.getSelectedText(0, row, emulator.mColumns - 1, row, false, false)
    override fun lineWraps(row: Int): Boolean = emulator.screen.getLineWrap(row)

    private companion object {
        val decsetBit: Method? = try {
            TerminalEmulator::class.java.getDeclaredMethod("isDecsetInternalBitSet", Int::class.javaPrimitiveType).apply { isAccessible = true }
        } catch (_: Exception) {
            null
        }
    }
}

/** The Termux emulator of a terminal (the view draws it). */
val MacTerminal.emulator: TerminalEmulator get() = (screen as TermuxScreen).emulator

/** Termux's terminal client, as far as the emulator asks for one (cursor style, logging): nothing here. */
internal object QuietSessionClient : TerminalSessionClient {
    override fun onTextChanged(changedSession: TerminalSession) {}
    override fun onTitleChanged(changedSession: TerminalSession) {}
    override fun onSessionFinished(finishedSession: TerminalSession) {}
    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {}
    override fun onPasteTextFromClipboard(session: TerminalSession?) {}
    override fun onBell(session: TerminalSession) {}
    override fun onColorsChanged(session: TerminalSession) {}
    override fun onTerminalCursorStateChange(state: Boolean) {}
    override fun getTerminalCursorStyle(): Int? = null
    override fun logError(tag: String?, message: String?) {}
    override fun logWarn(tag: String?, message: String?) {}
    override fun logInfo(tag: String?, message: String?) {}
    override fun logDebug(tag: String?, message: String?) {}
    override fun logVerbose(tag: String?, message: String?) {}
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
    override fun logStackTrace(tag: String?, e: Exception?) {}
}
