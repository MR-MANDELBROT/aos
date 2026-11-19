// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (Session/Keysym.swift,
// Session/MacKey.swift); Android's key codes take the place of the iPhone's HID usages.

package dev.marquart.aos.screen

import android.view.KeyEvent

/** X11 keysyms as screen sharing takes them (OSS's `Keysym`). */
object Keysym {
    const val BACKSPACE = 0xff08
    const val TAB = 0xff09
    const val RETURN = 0xff0d
    const val ESCAPE = 0xff1b
    const val FORWARD_DELETE = 0xffff
    const val HOME = 0xff50
    const val LEFT = 0xff51
    const val UP = 0xff52
    const val RIGHT = 0xff53
    const val DOWN = 0xff54
    const val PAGE_UP = 0xff55
    const val PAGE_DOWN = 0xff56
    const val END = 0xff57
    const val INSERT = 0xff63
    const val MENU = 0xff67
    const val HELP = 0xff6a
    const val NUM_LOCK = 0xff7f
    const val SCROLL_LOCK = 0xff14
    const val PAUSE = 0xff13
    const val PRINT_SCREEN = 0xff61
    const val KEYPAD_ENTER = 0xff8d
    const val KEYPAD_MULTIPLY = 0xffaa
    const val KEYPAD_PLUS = 0xffab
    const val KEYPAD_MINUS = 0xffad
    const val KEYPAD_DECIMAL = 0xffae
    const val KEYPAD_DIVIDE = 0xffaf
    const val KEYPAD_EQUAL = 0xffbd
    const val SPACE = 0x20

    const val SHIFT_LEFT = 0xffe1
    const val SHIFT_RIGHT = 0xffe2
    const val CONTROL_LEFT = 0xffe3
    const val CONTROL_RIGHT = 0xffe4
    const val CAPS_LOCK = 0xffe5
    const val OPTION_LEFT = 0xffe9
    const val OPTION_RIGHT = 0xffea
    const val COMMAND_LEFT = 0xffeb
    const val COMMAND_RIGHT = 0xffec

    const val POWER_OFF = 0x1008ff2a

    fun function(number: Int): Int = 0xffbe + (number.coerceIn(1, 35) - 1)

    fun keypad(digit: Int): Int = 0xffb0 + digit.coerceIn(0, 9)

    /** The keysym that types a character: Latin-1 as itself, everything else as a Unicode keysym. */
    fun character(codePoint: Int): Int = when (codePoint) {
        0x0a, 0x0d -> RETURN
        0x09 -> TAB
        0x08, 0x7f -> BACKSPACE
        0x1b -> ESCAPE
        in 0x20..0x7e, in 0xa0..0xff -> codePoint
        else -> 0x01000000 or codePoint
    }

    /** What the Mac types while a password field has the focus (secure input): ASCII and the function keys only. */
    fun typesInSecureInput(keysym: Int): Boolean = keysym in 0 until 0x80 || keysym in 0xff00..0xffff

    fun isModifier(keysym: Int): Boolean = keysym in SHIFT_LEFT..0xffee
}

/** The four modifier keys of a Mac keyboard, in the order they go down. */
enum class ModifierKey(val symbol: String) {
    CONTROL("⌃"), OPTION("⌥"), SHIFT("⇧"), COMMAND("⌘");

    val keysym: Int
        get() = when (this) {
            CONTROL -> Keysym.CONTROL_LEFT
            OPTION -> Keysym.OPTION_LEFT
            SHIFT -> Keysym.SHIFT_LEFT
            COMMAND -> Keysym.COMMAND_LEFT
        }

    val macKey: MacKey
        get() = when (this) {
            CONTROL -> MacKey.CONTROL
            OPTION -> MacKey.OPTION
            SHIFT -> MacKey.SHIFT
            COMMAND -> MacKey.COMMAND
        }

    companion object {
        fun of(keysym: Int): ModifierKey? = when (keysym) {
            Keysym.CONTROL_LEFT, Keysym.CONTROL_RIGHT -> CONTROL
            Keysym.OPTION_LEFT, Keysym.OPTION_RIGHT -> OPTION
            Keysym.SHIFT_LEFT, Keysym.SHIFT_RIGHT -> SHIFT
            Keysym.COMMAND_LEFT, Keysym.COMMAND_RIGHT -> COMMAND
            else -> null
        }
    }
}

/** A key on a Mac keyboard: its virtual key code (where it is) when known, and the keysym (what it types). */
data class MacKey(val keyCode: Int?, val keysym: Int) {
    val isModifier: Boolean get() = Keysym.isModifier(keysym)

    companion object {
        val RETURN = MacKey(36, Keysym.RETURN)
        val TAB = MacKey(48, Keysym.TAB)
        val SPACE = MacKey(49, Keysym.SPACE)
        val BACKSPACE = MacKey(51, Keysym.BACKSPACE)
        val ESCAPE = MacKey(53, Keysym.ESCAPE)
        val FORWARD_DELETE = MacKey(117, Keysym.FORWARD_DELETE)
        val HOME = MacKey(115, Keysym.HOME)
        val END = MacKey(119, Keysym.END)
        val PAGE_UP = MacKey(116, Keysym.PAGE_UP)
        val PAGE_DOWN = MacKey(121, Keysym.PAGE_DOWN)
        val LEFT = MacKey(123, Keysym.LEFT)
        val RIGHT = MacKey(124, Keysym.RIGHT)
        val DOWN = MacKey(125, Keysym.DOWN)
        val UP = MacKey(126, Keysym.UP)
        val COMMAND = MacKey(55, Keysym.COMMAND_LEFT)
        val SHIFT = MacKey(56, Keysym.SHIFT_LEFT)
        val OPTION = MacKey(58, Keysym.OPTION_LEFT)
        val CONTROL = MacKey(59, Keysym.CONTROL_LEFT)

        /** ScreensharingAgent sets the Caps Lock flag on key-down and clears it on key-up (OSS). */
        val CAPS_LOCK = MacKey(57, 0)

        private val functionKeyCodes = intArrayOf(
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        )

        fun function(number: Int): MacKey =
            MacKey(if (number in 1..functionKeyCodes.size) functionKeyCodes[number - 1] else null, Keysym.function(number))

        private val namedKeyCodes: Map<Int, Int> = buildMap {
            for (key in listOf(RETURN, TAB, SPACE, BACKSPACE, ESCAPE, FORWARD_DELETE, HOME, END, PAGE_UP, PAGE_DOWN,
                LEFT, RIGHT, DOWN, UP, COMMAND, SHIFT, OPTION, CONTROL, MacKey(54, Keysym.COMMAND_RIGHT),
                MacKey(60, Keysym.SHIFT_RIGHT), MacKey(61, Keysym.OPTION_RIGHT), MacKey(62, Keysym.CONTROL_RIGHT),
                MacKey(114, Keysym.HELP))) put(key.keysym, key.keyCode!!)
            functionKeyCodes.forEachIndexed { i, code -> put(Keysym.function(i + 1), code) }
        }

        /** The key for a keysym, with its key code when it is one of the named keys. */
        fun of(keysym: Int): MacKey = MacKey(namedKeyCodes[keysym], keysym)

        private val letterCodes = intArrayOf(0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6)

        private val usKeystrokes: Map<Char, Pair<Int, Boolean>> = buildMap {
            letterCodes.forEachIndexed { i, code ->
                put('a' + i, code to false)
                put('A' + i, code to true)
            }
            "1234567890-=[]\\;',./` ".toList().zip(listOf(18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50, 49))
                .forEach { (c, code) -> put(c, code to false) }
            "!@#$%^&*()_+{}|:\"<>?~".toList().zip(listOf(18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50))
                .forEach { (c, code) -> put(c, code to true) }
        }

        /** The US keyboard's key for an ASCII character, and whether it needs Shift (for Option shortcuts). */
        fun usKeystroke(character: Char): Pair<MacKey, Boolean>? {
            val (code, shift) = usKeystrokes[character] ?: return null
            return MacKey(code, character.code) to shift
        }
    }
}

/** Keys and modifiers pressed together (Cmd-Tab, Control-Up). */
data class KeyChord(val modifiers: List<ModifierKey>, val key: MacKey) {
    companion object {
        val APP_SWITCHER = KeyChord(listOf(ModifierKey.COMMAND), MacKey.TAB)
        val SPOTLIGHT = KeyChord(listOf(ModifierKey.COMMAND), MacKey.SPACE)
        val FORCE_QUIT = KeyChord(listOf(ModifierKey.COMMAND, ModifierKey.OPTION), MacKey.ESCAPE)
        val SCREENSHOT = KeyChord(listOf(ModifierKey.COMMAND, ModifierKey.SHIFT), MacKey(21, '4'.code))
        val LOCK_SCREEN = KeyChord(listOf(ModifierKey.CONTROL, ModifierKey.COMMAND), MacKey(12, 'q'.code))
        val PREVIOUS_INPUT_SOURCE = KeyChord(listOf(ModifierKey.CONTROL), MacKey.SPACE)
    }
}

/** macOS's system commands (libsharing's SystemCommand*), with the shortcut OSS falls back to. */
enum class SystemCommand(val fallback: KeyChord?) {
    MISSION_CONTROL(KeyChord(listOf(ModifierKey.CONTROL), MacKey.UP)),
    APP_WINDOWS(KeyChord(listOf(ModifierKey.CONTROL), MacKey.DOWN)),
    SHOW_DESKTOP(KeyChord(emptyList(), MacKey.function(11))),
    LAUNCHPAD(null),
}

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
