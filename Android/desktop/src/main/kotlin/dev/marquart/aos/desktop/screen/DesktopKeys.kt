package dev.marquart.aos.desktop.screen

import dev.marquart.aos.screen.Keysym
import dev.marquart.aos.screen.MacKey
import dev.marquart.aos.screen.ModifierKey
import java.awt.event.KeyEvent as Awt

/**
 * The computer's keyboard for the Mac's screen (Android's AndroidKeys with AWT's key codes): where a key sits (the
 * Mac's virtual key code, ANSI positions) and what it types (the keysym). Ctrl is the Mac's Control, Alt its Option,
 * the Windows (Super) key its Command; the session's ⌘ button holds Command for the next key where the system keeps
 * the Windows key for itself.
 */
object DesktopKeys {
    private val letterCodes = intArrayOf(0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6)

    private val macKeyCodes: Map<Int, Int> = buildMap {
        letterCodes.forEachIndexed { i, code -> put(Awt.VK_A + i, code) }
        listOf(29, 18, 19, 20, 21, 23, 22, 26, 28, 25).forEachIndexed { i, code -> put(Awt.VK_0 + i, code) }
        listOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111).forEachIndexed { i, code -> put(Awt.VK_F1 + i, code) }
        listOf(82, 83, 84, 85, 86, 87, 88, 89, 91, 92).forEachIndexed { i, code -> put(Awt.VK_NUMPAD0 + i, code) }
        putAll(mapOf(
            Awt.VK_ENTER to 36, Awt.VK_ESCAPE to 53, Awt.VK_BACK_SPACE to 51, Awt.VK_TAB to 48, Awt.VK_SPACE to 49,
            Awt.VK_MINUS to 27, Awt.VK_EQUALS to 24, Awt.VK_OPEN_BRACKET to 33, Awt.VK_CLOSE_BRACKET to 30,
            Awt.VK_BACK_SLASH to 42, Awt.VK_SEMICOLON to 41, Awt.VK_QUOTE to 39, Awt.VK_COMMA to 43, Awt.VK_PERIOD to 47,
            Awt.VK_SLASH to 44, Awt.VK_BACK_QUOTE to 50, Awt.VK_CAPS_LOCK to 57, Awt.VK_PRINTSCREEN to 105,
            Awt.VK_SCROLL_LOCK to 107, Awt.VK_PAUSE to 113, Awt.VK_INSERT to 114, Awt.VK_HOME to 115, Awt.VK_PAGE_UP to 116,
            Awt.VK_DELETE to 117, Awt.VK_END to 119, Awt.VK_PAGE_DOWN to 121, Awt.VK_RIGHT to 124, Awt.VK_LEFT to 123,
            Awt.VK_DOWN to 125, Awt.VK_UP to 126, Awt.VK_NUM_LOCK to 71, Awt.VK_DIVIDE to 75, Awt.VK_MULTIPLY to 67,
            Awt.VK_SUBTRACT to 78, Awt.VK_ADD to 69, Awt.VK_DECIMAL to 65, Awt.VK_CONTEXT_MENU to 110,
            Awt.VK_LESS to 10, // the ISO key left of Z
            Awt.VK_CONTROL to 59, Awt.VK_SHIFT to 56, Awt.VK_ALT to 58, Awt.VK_WINDOWS to 55, Awt.VK_META to 55,
            Awt.VK_ALT_GRAPH to 61,
        ))
    }

    private val specialKeysyms: Map<Int, Int> = buildMap {
        for (n in 1..12) put(Awt.VK_F1 + n - 1, Keysym.function(n))
        for (d in 0..9) put(Awt.VK_NUMPAD0 + d, Keysym.keypad(d))
        putAll(mapOf(
            Awt.VK_ENTER to Keysym.RETURN, Awt.VK_ESCAPE to Keysym.ESCAPE, Awt.VK_BACK_SPACE to Keysym.BACKSPACE,
            Awt.VK_TAB to Keysym.TAB, Awt.VK_SPACE to Keysym.SPACE, Awt.VK_DELETE to Keysym.FORWARD_DELETE,
            Awt.VK_HOME to Keysym.HOME, Awt.VK_END to Keysym.END, Awt.VK_PAGE_UP to Keysym.PAGE_UP,
            Awt.VK_PAGE_DOWN to Keysym.PAGE_DOWN, Awt.VK_LEFT to Keysym.LEFT, Awt.VK_RIGHT to Keysym.RIGHT,
            Awt.VK_UP to Keysym.UP, Awt.VK_DOWN to Keysym.DOWN, Awt.VK_INSERT to Keysym.INSERT,
            Awt.VK_PRINTSCREEN to Keysym.PRINT_SCREEN, Awt.VK_SCROLL_LOCK to Keysym.SCROLL_LOCK, Awt.VK_PAUSE to Keysym.PAUSE,
            Awt.VK_CONTEXT_MENU to Keysym.MENU, Awt.VK_NUM_LOCK to Keysym.NUM_LOCK, Awt.VK_MULTIPLY to Keysym.KEYPAD_MULTIPLY,
            Awt.VK_ADD to Keysym.KEYPAD_PLUS, Awt.VK_SUBTRACT to Keysym.KEYPAD_MINUS, Awt.VK_DECIMAL to Keysym.KEYPAD_DECIMAL,
            Awt.VK_DIVIDE to Keysym.KEYPAD_DIVIDE,
            Awt.VK_SHIFT to Keysym.SHIFT_LEFT, Awt.VK_CONTROL to Keysym.CONTROL_LEFT, Awt.VK_ALT to Keysym.OPTION_LEFT,
            Awt.VK_ALT_GRAPH to Keysym.OPTION_RIGHT, Awt.VK_WINDOWS to Keysym.COMMAND_LEFT, Awt.VK_META to Keysym.COMMAND_LEFT,
        ))
    }

    /** The modifiers held, from AWT's modifier bits. */
    fun held(ctrl: Boolean, alt: Boolean, shift: Boolean, meta: Boolean): Set<ModifierKey> = buildSet {
        if (ctrl) add(ModifierKey.CONTROL)
        if (alt) add(ModifierKey.OPTION)
        if (shift) add(ModifierKey.SHIFT)
        if (meta) add(ModifierKey.COMMAND)
    }

    /** The key's own character without modifiers (letters and digits by their code, else what it typed). */
    private fun base(keyCode: Int, typed: Int): Int = when (keyCode) {
        in Awt.VK_A..Awt.VK_Z -> 'a'.code + keyCode - Awt.VK_A
        in Awt.VK_0..Awt.VK_9 -> '0'.code + keyCode - Awt.VK_0
        else -> if (typed in 0x20 until 0x7f || (typed >= 0xa0 && typed != 0xffff)) typed else 0
    }

    /** The keysym a key types, as Android's AndroidKeys.keysym works it out. */
    fun keysym(keyCode: Int, held: Set<ModifierKey>, typed: Int): Int? {
        specialKeysyms[keyCode]?.let { return it }
        val base = base(keyCode, typed)
        val codePoint = if (ModifierKey.COMMAND in held || ModifierKey.CONTROL in held) {
            if (base == 0) return null
            val text = String(Character.toChars(base))
            (if (ModifierKey.SHIFT in held) text.uppercase() else text.lowercase()).codePointAt(0)
        } else {
            val c = if (typed >= 0x20 && typed != 0x7f && typed != 0xffff) typed else base
            if (c == 0) return null
            c
        }
        return Keysym.character(codePoint)
    }

    fun macKey(keyCode: Int, held: Set<ModifierKey>, typed: Int): MacKey? {
        val sym = keysym(keyCode, held, typed) ?: return null
        return MacKey(macKeyCodes[keyCode], sym)
    }
}
