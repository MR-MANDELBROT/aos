package dev.marquart.aos.terminal

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

// The terminal's input logic without Android views: what a key sends, how the key bar's modifiers behave, how a paste
// is encoded, how the key bar divides its width, when a swipe on the terminal is arrow keys, and how text is found on
// the screen (iOS Sources/Terminal/TerminalKeys.swift). The views use it; TerminalKeyTests covers it on the JVM.

/** Modifiers for the next key. The values are the xterm modifier bits, so `xtermParameter` is 1 + bits. */
@JvmInline
value class TerminalModifiers(val bits: Int) {
    operator fun plus(other: TerminalModifiers) = TerminalModifiers(bits or other.bits)
    operator fun contains(other: TerminalModifiers) = other.bits != 0 && bits and other.bits == other.bits
    val isEmpty: Boolean get() = bits == 0

    /** The parameter in `ESC [ 1 ; <p> A` and friends. */
    val xtermParameter: Int get() = 1 + bits

    companion object {
        val NONE = TerminalModifiers(0)
        val SHIFT = TerminalModifiers(1)

        /** Alt (Option on the iPhone). Sent as meta: Esc before the key. */
        val ALT = TerminalModifiers(2)
        val CONTROL = TerminalModifiers(4)
    }
}

/** A key the key bar (or the swipe) sends. */
sealed class TerminalKey {
    data object Escape : TerminalKey()
    data object Tab : TerminalKey()
    data object Enter : TerminalKey()
    data object Backspace : TerminalKey()
    data object Up : TerminalKey()
    data object Down : TerminalKey()
    data object Left : TerminalKey()
    data object Right : TerminalKey()
    data object Home : TerminalKey()
    data object End : TerminalKey()
    data object PageUp : TerminalKey()
    data object PageDown : TerminalKey()
    data object Insert : TerminalKey()
    data object ForwardDelete : TerminalKey()

    /** F1 to F12. */
    data class Function(val number: Int) : TerminalKey()

    /** Text as typed (a letter of the on-screen keyboard). */
    data class Text(val text: String) : TerminalKey()
}

/** What a key sends to the program in the terminal: the sequences xterm sends (TERM is xterm-256color), with modifiers
 *  in the xterm way. */
object TerminalKeyEncoder {
    private const val ESC: Byte = 0x1b

    fun bytes(key: TerminalKey, modifiers: TerminalModifiers = TerminalModifiers.NONE, applicationCursor: Boolean = false): ByteArray {
        val meta = if (TerminalModifiers.ALT in modifiers) byteArrayOf(ESC) else ByteArray(0)
        return when (key) {
            TerminalKey.Escape -> meta + ESC
            TerminalKey.Tab -> if (TerminalModifiers.SHIFT in modifiers) meta + csi("Z") else meta + 0x09.toByte()
            TerminalKey.Enter -> meta + 0x0d.toByte()
            TerminalKey.Backspace -> meta + (if (TerminalModifiers.CONTROL in modifiers) 0x08 else 0x7f).toByte()
            TerminalKey.Up -> cursor('A', modifiers, applicationCursor)
            TerminalKey.Down -> cursor('B', modifiers, applicationCursor)
            TerminalKey.Right -> cursor('C', modifiers, applicationCursor)
            TerminalKey.Left -> cursor('D', modifiers, applicationCursor)
            TerminalKey.Home -> cursor('H', modifiers, applicationCursor)
            TerminalKey.End -> cursor('F', modifiers, applicationCursor)
            TerminalKey.Insert -> tilde(2, modifiers)
            TerminalKey.ForwardDelete -> tilde(3, modifiers)
            TerminalKey.PageUp -> tilde(5, modifiers)
            TerminalKey.PageDown -> tilde(6, modifiers)
            is TerminalKey.Function -> when (key.number) {
                in 1..4 -> {
                    val final = 'P' + (key.number - 1)
                    if (modifiers.isEmpty) byteArrayOf(ESC, 'O'.code.toByte(), final.code.toByte())
                    else csi("1;${modifiers.xtermParameter}$final")
                }
                in 5..12 -> tilde(intArrayOf(15, 17, 18, 19, 20, 21, 23, 24)[key.number - 5], modifiers)
                else -> ByteArray(0)
            }
            is TerminalKey.Text -> meta + textBytes(key.text, TerminalModifiers.CONTROL in modifiers)
        }
    }

    /** Text with Control held: a letter or one of the classic symbols becomes its control character; anything else is
     *  sent as it is. */
    fun textBytes(text: String, control: Boolean): ByteArray {
        if (control && text.codePointCount(0, text.length) == 1) controlByte(text.codePointAt(0))?.let { return byteArrayOf(it) }
        return text.toByteArray(Charsets.UTF_8)
    }

    /** Control and a character, as a terminal keyboard sends it (Control-2 is NUL, Control-/ is US and so on). */
    fun controlByte(codePoint: Int): Byte? {
        if (codePoint >= 128) return null
        val c = codePoint.toChar()
        return when (c) {
            in 'a'..'z' -> (codePoint - 0x60).toByte()
            in 'A'..'Z' -> (codePoint - 0x40).toByte()
            '@', ' ', '2' -> 0x00
            '[', '3' -> 0x1b
            '\\', '4' -> 0x1c
            ']', '5' -> 0x1d
            '^', '6', '~' -> 0x1e
            '_', '7', '-', '/' -> 0x1f
            '?', '8' -> 0x7f
            else -> null
        }
    }

    private fun csi(rest: String): ByteArray = byteArrayOf(ESC, '['.code.toByte()) + rest.toByteArray(Charsets.US_ASCII)

    /** Arrows, Home and End: `ESC [ A` (or `ESC O A` in application cursor mode); with modifiers `ESC [ 1 ; m A`. */
    private fun cursor(final: Char, modifiers: TerminalModifiers, applicationCursor: Boolean): ByteArray {
        if (!modifiers.isEmpty) return csi("1;${modifiers.xtermParameter}$final")
        return byteArrayOf(ESC, (if (applicationCursor) 'O' else '[').code.toByte(), final.code.toByte())
    }

    /** `ESC [ n ~`, with modifiers `ESC [ n ; m ~`. */
    private fun tilde(code: Int, modifiers: TerminalModifiers): ByteArray =
        if (modifiers.isEmpty) csi("$code~") else csi("$code;${modifiers.xtermParameter}~")
}

/** The key bar's modifiers. A tap holds one for the next key, a double tap locks it until the next tap, and holding it
 *  down while pressing another key works like on a hardware keyboard. Times in seconds. */
class StickyModifiers(var doubleTapInterval: Double = 0.35) {
    enum class State { OFF, ONCE, LOCKED }

    private val states = HashMap<Int, State>()

    /** Modifiers whose key is down right now, and whether a key was sent while it was. */
    private val held = HashMap<Int, Boolean>()
    private var lastTap: Pair<Int, Double>? = null

    fun state(of: TerminalModifiers): State = states[of.bits] ?: State.OFF
    fun isHeld(modifier: TerminalModifiers): Boolean = held.containsKey(modifier.bits)

    /** What applies to the next key: modifiers that are on and modifiers whose key is down. */
    val active: TerminalModifiers
        get() = ALL.fold(TerminalModifiers.NONE) { result, m -> if (state(m) != State.OFF || isHeld(m)) result + m else result }

    /** The modifier key went down. */
    fun press(modifier: TerminalModifiers) {
        held[modifier.bits] = false
    }

    /** The modifier key went up. If no key was sent while it was down, that was a tap. `cancelled` (the touch was taken
     *  away) changes nothing. */
    fun release(modifier: TerminalModifiers, at: Double, cancelled: Boolean = false): State {
        val usedWhileHeld = held.remove(modifier.bits) ?: false
        if (usedWhileHeld || cancelled) return state(modifier)
        return tap(modifier, at)
    }

    /** A tap: off becomes once; once becomes locked if the tap before was moments ago, else off; locked becomes off. */
    fun tap(modifier: TerminalModifiers, at: Double): State {
        val quick = lastTap?.let { it.first == modifier.bits && at - it.second <= doubleTapInterval } ?: false
        val next = when (state(modifier)) {
            State.OFF -> State.ONCE
            State.ONCE -> if (quick) State.LOCKED else State.OFF
            State.LOCKED -> State.OFF
        }
        states[modifier.bits] = next
        lastTap = if (next == State.ONCE) modifier.bits to at else null
        return next
    }

    /** A key was sent with the active modifiers: the ones for one key are used up. */
    fun consume() {
        for ((key, state) in states.entries.toList()) if (state == State.ONCE) states[key] = State.OFF
        for (key in held.keys.toList()) held[key] = true
        lastTap = null
    }

    fun reset() {
        states.clear()
        held.clear()
        lastTap = null
    }

    /** For Compose: changes when anything does. */
    fun snapshot(): Map<Int, State> = ALL.associate { it.bits to (if (isHeld(it) && state(it) == State.OFF) State.ONCE else state(it)) }

    companion object {
        val ALL = listOf(TerminalModifiers.CONTROL, TerminalModifiers.ALT, TerminalModifiers.SHIFT)
    }
}

/** Pasted text for the terminal. With bracketed paste (the shell asked for it with `CSI ? 2004 h`) the text is wrapped
 *  in `ESC [ 200 ~` and `ESC [ 201 ~`, so the shell inserts it instead of running it. Control characters are taken out
 *  in both cases: an Esc in the text could end the bracket early and run what follows. */
object PasteEncoder {
    val BRACKET_START = "\u001b[200~".toByteArray()
    val BRACKET_END = "\u001b[201~".toByteArray()

    fun bytes(text: String, bracketed: Boolean): ByteArray {
        val body = sanitized(text, bracketed).toByteArray(Charsets.UTF_8)
        return if (bracketed) BRACKET_START + body + BRACKET_END else body
    }

    /** Line breaks become what the program expects (a newline inside a bracket, Return otherwise); tabs stay; other
     *  control characters (C0, DEL, C1) go. */
    fun sanitized(text: String, bracketed: Boolean): String {
        val newline = if (bracketed) '\n' else '\r'
        val out = StringBuilder(text.length)
        var previousWasCR = false
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            when {
                cp == 0x0d -> out.append(newline)
                cp == 0x0a -> if (!previousWasCR) out.append(newline)
                cp == 0x09 -> out.append('\t')
                cp in 0x00..0x1f || cp in 0x7f..0x9f -> Unit
                else -> out.appendCodePoint(cp)
            }
            previousWasCR = cp == 0x0d
            i += Character.charCount(cp)
        }
        return out.toString()
    }

    /** Without bracketed paste every line break is a Return: the shell runs the lines as they arrive. */
    fun runsLines(text: String, bracketed: Boolean): Boolean = !bracketed && sanitized(text, false).contains('\r')
}

/** The arrows in the middle of the key bar (the terminal's settings). */
enum class TerminalArrowKeys {
    /** One pad: swipe from it towards a direction. */
    PAD,

    /** ← ↑ → ↓ as keys of their own. */
    FOUR_KEYS,
}

/**
 * How the key bar divides its width (dp): every key is `keyWidth` wide (a calm row like a keyboard's), the arrows sit
 * in the middle and `leading` keys fill the half to their left exactly, so at the start of the scroll the arrows are in
 * the middle of the screen. The rest follows to the right; the whole row scrolls.
 */
data class KeyBarLayout(val keyWidth: Float, val leading: Int, val centerWidth: Float) {
    /** Where the middle of the arrows is at the start of the scroll (it should be the bar's middle). */
    val centerMidX: Float get() = leading * keyWidth + centerWidth / 2

    companion object {
        const val PAD_WIDTH = 60f

        /** Keys get at least this much room (a 40 dp plate, a 46 dp touch area). */
        const val MINIMUM_KEY = 46f

        /** The layout for a bar `width` dp wide (what the scroll area shows). */
        fun of(width: Float, arrows: TerminalArrowKeys): KeyBarLayout {
            val half = maxOf(width, 2 * MINIMUM_KEY) / 2
            return when (arrows) {
                TerminalArrowKeys.PAD -> {
                    val room = half - PAD_WIDTH / 2
                    val n = maxOf(1, (room / MINIMUM_KEY).toInt())
                    KeyBarLayout(room / n, n, PAD_WIDTH)
                }
                TerminalArrowKeys.FOUR_KEYS -> {
                    // Four arrow keys and the keys on the left all as wide as one another: n + 2 keys fill half the bar.
                    val slots = maxOf(2, (half / MINIMUM_KEY).toInt())
                    val key = half / slots
                    KeyBarLayout(key, slots - 2, 4 * key)
                }
            }
        }

        /** The nearest key edge to `x` (the start, a key's left edge, or the end of the row). */
        fun snapped(x: Float, edges: List<Float>, maxOffset: Float): Float {
            if (maxOffset <= 0) return 0f
            var best = 0f
            for (edge in edges + maxOffset) if (edge <= maxOffset && abs(edge - x) < abs(best - x)) best = edge
            return best
        }
    }
}

/**
 * Swiping on the terminal itself sends arrow keys, like the key bar's pad (the terminal's settings, on by default).
 * The rule, decided once the finger has moved `DEAD_ZONE` dp (and only if it started moving within `START_WINDOW`; a
 * finger that rests first is a long press, which selects text):
 *
 * - Sideways: ← or →, anywhere on the terminal (sideways drags do nothing else there).
 * - Up or down: ↑ or ↓ only for a quick flick, and only while the terminal shows its end (not scrolled back). A slower
 *   drag scrolls the scrollback as always; once scrolled back, flicks scroll too.
 * - Then like on the pad: keep the finger down to repeat, faster the farther it is from where it started; moving back
 *   past the start sends the other direction.
 * - Never with two fingers (pinch), at the screen's edges (Android's back gesture), or while text is selected.
 */
object TerminalSwipe {
    enum class Decision {
        /** Arrow keys: the gesture is ours. */
        ARROWS,

        /** The terminal scrolls (or a full-screen program gets the drag). */
        SCROLL,

        /** Too late: the finger rested before it moved (a long press). */
        NONE,
    }

    const val DEAD_ZONE = 12f

    /** Faster than this (dp per second) when it leaves the dead zone: a flick. */
    const val FLICK_SPEED = 450f
    const val START_WINDOW = 0.3

    /** Touches that begin this close to the screen's left or right edge belong to the back gesture. */
    const val EDGE_MARGIN = 24f

    /** null while the finger is still inside the dead zone. Translation and velocity in dp, dp/s; elapsed in seconds. */
    fun decide(dx: Float, dy: Float, velocityY: Float, elapsed: Double, atEnd: Boolean): Decision? {
        if (hypot(dx, dy) < DEAD_ZONE) return if (elapsed > START_WINDOW) Decision.NONE else null
        if (elapsed > START_WINDOW) return Decision.NONE
        if (abs(dx) >= abs(dy) * 1.2f) return Decision.ARROWS
        return if (atEnd && abs(velocityY) >= FLICK_SPEED) Decision.ARROWS else Decision.SCROLL
    }

    /** A touch that starts here is the system's (the back gesture from either edge). */
    fun inEdge(x: Float, width: Float): Boolean = x < EDGE_MARGIN || x > width - EDGE_MARGIN
}

/** The swipe pad of the key bar: a drag from the pad sends arrows in its direction, faster the farther it goes. */
object ArrowPad {
    const val DEAD_ZONE = 12f

    fun key(dx: Float, dy: Float, deadZone: Float = DEAD_ZONE): TerminalKey? {
        if (hypot(dx, dy) < deadZone) return null
        if (abs(dx) > abs(dy)) return if (dx > 0) TerminalKey.Right else TerminalKey.Left
        return if (dy > 0) TerminalKey.Down else TerminalKey.Up
    }

    /** Time between repeated arrows (seconds): 0.3 s just past the dead zone down to 0.04 s at 100 dp. */
    fun repeatInterval(distance: Float): Double {
        val t = ((distance - DEAD_ZONE) / (100 - DEAD_ZONE)).coerceIn(0f, 1f)
        return 0.3 - t * 0.26
    }

    /** The first repeat comes after this long (seconds). */
    const val FIRST_REPEAT = 0.35
}

/** A row of the terminal as text, for copying. */
data class TerminalRowText(val row: Int, val text: String, val isWrapped: Boolean)

object TerminalText {
    private val LINK = Regex("""https?://[^\s<>"'`]+""", RegexOption.IGNORE_CASE)

    /** The web address that covers `column` of a row, as its columns and its text (only http and https). */
    fun linkAt(row: String, column: Int): Pair<IntRange, String>? {
        for (match in LINK.findAll(row)) {
            var end = match.range.last
            // Punctuation that ends a sentence isn't part of the address.
            while (end > match.range.first && row[end] in ".,;:!?)]}") end--
            if (column in match.range.first..end) return (match.range.first..end) to row.substring(match.range.first, end + 1)
        }
        return null
    }

    /** Is this text one web address (the selection, before offering to open it)? */
    fun singleLink(text: String): String? {
        val trimmed = text.trim()
        return if (trimmed.isNotEmpty() && linkAt(trimmed, 0)?.second == trimmed) trimmed else null
    }

    /** Rows as text: a wrapped row continues the line before it; blank lines at the end are dropped. */
    fun joined(rows: List<TerminalRowText>): String {
        val lines = mutableListOf<String>()
        for (row in rows) {
            if (row.isWrapped && lines.isNotEmpty()) lines[lines.size - 1] = lines.last() + row.text else lines += row.text
        }
        while (lines.isNotEmpty() && lines.last().isBlank()) lines.removeAt(lines.size - 1)
        return lines.joinToString("\n") { it.trimEnd() }
    }

    /** The output of the last command that printed something. `commandRows` are the rows where Return was pressed at
     *  the shell (oldest first), `cursorRow` is where the cursor is now (the next prompt); output is what lies between a
     *  command row and the next one. */
    fun lastOutput(rows: List<TerminalRowText>, commandRows: List<Int>, cursorRow: Int): String? {
        // Rows at or below the cursor are from before the screen was cleared.
        val commands = commandRows.filter { it < cursorRow }
        if (rows.isEmpty() || commands.isEmpty()) return null
        val byRow = rows.associateBy { it.row }
        val ends = commands.drop(1) + cursorRow
        for ((command, next) in commands.zip(ends).reversed()) {
            var end = next
            // The first rows of a long command line that wrapped belong to that line, not to the output before it.
            while (end > command + 1 && byRow[end]?.isWrapped == true) end--
            if (end <= command + 1) continue
            val output = joined((command + 1 until end).mapNotNull { byRow[it] })
            if (output.isNotBlank()) return output
        }
        return null
    }
}

/** Font sizes (sp) for pinch to zoom and the menu. */
object TerminalFontSize {
    const val MIN = 8
    const val MAX = 28
    const val STANDARD = 13

    fun clamped(size: Float): Int = size.roundToInt().coerceIn(MIN, MAX)
}
