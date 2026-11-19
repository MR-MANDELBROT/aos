// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (Session/Keysym.swift,
// Session/MacKey.swift); Android's key codes take the place of the iPhone's HID usages.

package dev.marquart.aos.screen

import android.view.KeyEvent

/** Physical keyboards on Android: key codes to Mac key codes (ANSI positions, OSS's HID table) and keysyms. */
object AndroidKeys {
    private val letterCodes = intArrayOf(0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6)

    private val macKeyCodes: Map<Int, Int> = buildMap {
        letterCodes.forEachIndexed { i, code -> put(KeyEvent.KEYCODE_A + i, code) }
        // KEYCODE_0 .. KEYCODE_9
        listOf(29, 18, 19, 20, 21, 23, 22, 26, 28, 25).forEachIndexed { i, code -> put(KeyEvent.KEYCODE_0 + i, code) }
        listOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111).forEachIndexed { i, code -> put(KeyEvent.KEYCODE_F1 + i, code) }
        listOf(82, 83, 84, 85, 86, 87, 88, 89, 91, 92).forEachIndexed { i, code -> put(KeyEvent.KEYCODE_NUMPAD_0 + i, code) }
        putAll(
            mapOf(
                KeyEvent.KEYCODE_ENTER to 36, KeyEvent.KEYCODE_ESCAPE to 53, KeyEvent.KEYCODE_DEL to 51,
                KeyEvent.KEYCODE_TAB to 48, KeyEvent.KEYCODE_SPACE to 49, KeyEvent.KEYCODE_MINUS to 27,
                KeyEvent.KEYCODE_EQUALS to 24, KeyEvent.KEYCODE_LEFT_BRACKET to 33, KeyEvent.KEYCODE_RIGHT_BRACKET to 30,
                KeyEvent.KEYCODE_BACKSLASH to 42, KeyEvent.KEYCODE_SEMICOLON to 41, KeyEvent.KEYCODE_APOSTROPHE to 39,
                KeyEvent.KEYCODE_COMMA to 43, KeyEvent.KEYCODE_PERIOD to 47, KeyEvent.KEYCODE_SLASH to 44,
                KeyEvent.KEYCODE_GRAVE to 50, KeyEvent.KEYCODE_CAPS_LOCK to 57, KeyEvent.KEYCODE_SYSRQ to 105,
                KeyEvent.KEYCODE_SCROLL_LOCK to 107, KeyEvent.KEYCODE_BREAK to 113, KeyEvent.KEYCODE_INSERT to 114,
                KeyEvent.KEYCODE_MOVE_HOME to 115, KeyEvent.KEYCODE_PAGE_UP to 116, KeyEvent.KEYCODE_FORWARD_DEL to 117,
                KeyEvent.KEYCODE_MOVE_END to 119, KeyEvent.KEYCODE_PAGE_DOWN to 121, KeyEvent.KEYCODE_DPAD_RIGHT to 124,
                KeyEvent.KEYCODE_DPAD_LEFT to 123, KeyEvent.KEYCODE_DPAD_DOWN to 125, KeyEvent.KEYCODE_DPAD_UP to 126,
                KeyEvent.KEYCODE_NUM_LOCK to 71, KeyEvent.KEYCODE_NUMPAD_DIVIDE to 75, KeyEvent.KEYCODE_NUMPAD_MULTIPLY to 67,
                KeyEvent.KEYCODE_NUMPAD_SUBTRACT to 78, KeyEvent.KEYCODE_NUMPAD_ADD to 69, KeyEvent.KEYCODE_NUMPAD_ENTER to 76,
                KeyEvent.KEYCODE_NUMPAD_DOT to 65, KeyEvent.KEYCODE_NUMPAD_EQUALS to 81, KeyEvent.KEYCODE_NUMPAD_COMMA to 95,
                KeyEvent.KEYCODE_MENU to 110, KeyEvent.KEYCODE_HELP to 114,
                KeyEvent.KEYCODE_RO to 94, KeyEvent.KEYCODE_YEN to 93, KeyEvent.KEYCODE_KANA to 104, KeyEvent.KEYCODE_EISU to 102,
                KeyEvent.KEYCODE_CTRL_LEFT to 59, KeyEvent.KEYCODE_SHIFT_LEFT to 56, KeyEvent.KEYCODE_ALT_LEFT to 58,
                KeyEvent.KEYCODE_META_LEFT to 55, KeyEvent.KEYCODE_CTRL_RIGHT to 62, KeyEvent.KEYCODE_SHIFT_RIGHT to 60,
                KeyEvent.KEYCODE_ALT_RIGHT to 61, KeyEvent.KEYCODE_META_RIGHT to 54,
            ),
        )
    }

    private val specialKeysyms: Map<Int, Int> = buildMap {
        for (n in 1..12) put(KeyEvent.KEYCODE_F1 + n - 1, Keysym.function(n))
        for (d in 0..9) put(KeyEvent.KEYCODE_NUMPAD_0 + d, Keysym.keypad(d))
        putAll(
            mapOf(
                KeyEvent.KEYCODE_ENTER to Keysym.RETURN, KeyEvent.KEYCODE_ESCAPE to Keysym.ESCAPE,
                KeyEvent.KEYCODE_DEL to Keysym.BACKSPACE, KeyEvent.KEYCODE_TAB to Keysym.TAB,
                KeyEvent.KEYCODE_SPACE to Keysym.SPACE, KeyEvent.KEYCODE_FORWARD_DEL to Keysym.FORWARD_DELETE,
                KeyEvent.KEYCODE_MOVE_HOME to Keysym.HOME, KeyEvent.KEYCODE_MOVE_END to Keysym.END,
                KeyEvent.KEYCODE_PAGE_UP to Keysym.PAGE_UP, KeyEvent.KEYCODE_PAGE_DOWN to Keysym.PAGE_DOWN,
                KeyEvent.KEYCODE_DPAD_LEFT to Keysym.LEFT, KeyEvent.KEYCODE_DPAD_RIGHT to Keysym.RIGHT,
                KeyEvent.KEYCODE_DPAD_UP to Keysym.UP, KeyEvent.KEYCODE_DPAD_DOWN to Keysym.DOWN,
                KeyEvent.KEYCODE_INSERT to Keysym.INSERT, KeyEvent.KEYCODE_SYSRQ to Keysym.PRINT_SCREEN,
                KeyEvent.KEYCODE_SCROLL_LOCK to Keysym.SCROLL_LOCK, KeyEvent.KEYCODE_BREAK to Keysym.PAUSE,
                KeyEvent.KEYCODE_HELP to Keysym.HELP, KeyEvent.KEYCODE_MENU to Keysym.MENU,
                KeyEvent.KEYCODE_NUM_LOCK to Keysym.NUM_LOCK, KeyEvent.KEYCODE_NUMPAD_ENTER to Keysym.KEYPAD_ENTER,
                KeyEvent.KEYCODE_NUMPAD_MULTIPLY to Keysym.KEYPAD_MULTIPLY, KeyEvent.KEYCODE_NUMPAD_ADD to Keysym.KEYPAD_PLUS,
                KeyEvent.KEYCODE_NUMPAD_SUBTRACT to Keysym.KEYPAD_MINUS, KeyEvent.KEYCODE_NUMPAD_DOT to Keysym.KEYPAD_DECIMAL,
                KeyEvent.KEYCODE_NUMPAD_DIVIDE to Keysym.KEYPAD_DIVIDE, KeyEvent.KEYCODE_NUMPAD_EQUALS to Keysym.KEYPAD_EQUAL,
                KeyEvent.KEYCODE_SHIFT_LEFT to Keysym.SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT to Keysym.SHIFT_RIGHT,
                KeyEvent.KEYCODE_CTRL_LEFT to Keysym.CONTROL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT to Keysym.CONTROL_RIGHT,
                KeyEvent.KEYCODE_ALT_LEFT to Keysym.OPTION_LEFT, KeyEvent.KEYCODE_ALT_RIGHT to Keysym.OPTION_RIGHT,
                KeyEvent.KEYCODE_META_LEFT to Keysym.COMMAND_LEFT, KeyEvent.KEYCODE_META_RIGHT to Keysym.COMMAND_RIGHT,
            ),
        )
    }

    /** Keys the phone keeps for itself (volume, power, back and home buttons, media keys). */
    fun isPhoneKey(keyCode: Int): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN, KeyEvent.KEYCODE_VOLUME_MUTE, KeyEvent.KEYCODE_POWER,
        KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_APP_SWITCH, KeyEvent.KEYCODE_CAMERA,
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_MEDIA_PREVIOUS,
        KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_SEARCH, KeyEvent.KEYCODE_ASSIST, KeyEvent.KEYCODE_VOICE_ASSIST,
        -> true
        else -> false
    }

    /** The Mac's virtual key code where the Android key sits (ANSI), or null. */
    fun macKeyCode(keyCode: Int): Int? = macKeyCodes[keyCode]

    /** The keysym of a key that doesn't type a character (Return, arrows, F keys, modifiers). */
    fun specialKeysym(keyCode: Int): Int? = specialKeysyms[keyCode]

    /** The modifiers the event says are held. Android's Meta (the Windows key) is the Mac's Command. */
    fun heldModifiers(metaState: Int): Set<ModifierKey> = buildSet {
        if (metaState and KeyEvent.META_CTRL_ON != 0) add(ModifierKey.CONTROL)
        if (metaState and KeyEvent.META_ALT_ON != 0) add(ModifierKey.OPTION)
        if (metaState and KeyEvent.META_SHIFT_ON != 0) add(ModifierKey.SHIFT)
        if (metaState and KeyEvent.META_META_ON != 0) add(ModifierKey.COMMAND)
    }

    /**
     * The keysym a key types, as OSS works it out: special keys by their code; with Command or Control the key's own
     * character (upper case with Shift); otherwise what it types, or its own character for a control character.
     * `typed`: the character with all modifiers (0 for none), `base`: without Control, Alt and Meta.
     */
    fun keysym(keyCode: Int, held: Set<ModifierKey>, typed: Int, base: Int, capsLock: Boolean = false): Int? {
        specialKeysym(keyCode)?.let { return it }
        val codePoint: Int = if (ModifierKey.COMMAND in held || ModifierKey.CONTROL in held) {
            if (base == 0) return null
            val text = String(Character.toChars(base))
            (if (ModifierKey.SHIFT in held) text.uppercase() else text.lowercase()).codePointAt(0)
        } else {
            var c = if (typed >= 0x20 && typed != 0x7f) typed else base
            if (c == 0) return null
            if (Character.isLetter(c)) {
                val text = String(Character.toChars(c))
                val cased = if ((ModifierKey.SHIFT in held) != capsLock) text.uppercase() else text.lowercase()
                if (cased.codePointCount(0, cased.length) == 1) c = cased.codePointAt(0)
            }
            c
        }
        return Keysym.character(codePoint)
    }

    /** The Mac key for a hardware key event: its key code where it has one, with what it types. */
    fun macKey(keyCode: Int, held: Set<ModifierKey>, typed: Int, base: Int, capsLock: Boolean = false): MacKey? {
        val sym = keysym(keyCode, held, typed, base, capsLock)
        val code = macKeyCode(keyCode) ?: return sym?.let { MacKey(null, it) }
        return MacKey(code, sym ?: 0)
    }
}
