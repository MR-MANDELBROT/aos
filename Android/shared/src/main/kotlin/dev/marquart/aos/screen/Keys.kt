// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (Session/Keysym.swift,
// Session/MacKey.swift); Android's key codes take the place of the iPhone's HID usages.

package dev.marquart.aos.screen

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
