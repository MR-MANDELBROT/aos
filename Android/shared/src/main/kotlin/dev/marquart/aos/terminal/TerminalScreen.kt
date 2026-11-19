package dev.marquart.aos.terminal

/**
 * The terminal emulator a `MacTerminal` feeds: Termux's TerminalEmulator on Android (`TermuxScreen`), JediTerm's on the
 * desktop. It keeps the screen and the scrollback; the view shows it. Called on the terminal's dispatcher only.
 *
 * Rows are numbered like Termux numbers them: 0 is the screen's first row, negative rows are the scrollback (down to
 * `-transcriptRows`).
 */
interface TerminalScreen {
    /** What the emulator reports back to the terminal. */
    interface Events {
        /** What the emulator answers (cursor position reports, device attributes): goes to the Mac like typing. */
        fun reply(bytes: ByteArray)

        /** The program asked to copy text (OSC 52). */
        fun copyToClipboard(text: String)

        /** The program changed the palette: the view redraws. */
        fun colorsChanged()
    }

    /** Output from the Mac (any split of UTF-8 and escape sequences). */
    fun append(bytes: ByteArray)

    /** Lines scrolled off the top since the counter was last cleared (the view reads and clears it, too). */
    val scrollCounter: Int
    fun clearScrollCounter()

    val cursorRow: Int
    val columns: Int
    val rows: Int

    /** Rows of scrollback above the screen. */
    val transcriptRows: Int

    /** DECCKM: the arrow keys send `ESC O A` instead of `ESC [ A`. */
    val cursorKeysApplicationMode: Boolean

    /** The program asked for bracketed paste (`CSI ? 2004 h`). */
    val bracketedPaste: Boolean

    /** A row's text (trailing blanks as the emulator keeps them). */
    fun rowText(row: Int): String

    /** The row continues on the next one (it was wrapped, not ended by a line break). */
    fun lineWraps(row: Int): Boolean
}
