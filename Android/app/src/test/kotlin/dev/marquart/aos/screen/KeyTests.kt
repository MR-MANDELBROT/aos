package dev.marquart.aos.screen

import android.view.KeyEvent
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Hardware keys to the Mac's key codes and keysyms (OSS's MacKey/Keysym tables), typing from the on-screen keyboard. */
class KeyTests {
    @Test fun lettersAndDigitsSitWhereTheMacHasThem() {
        assertEquals(0, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_A))
        assertEquals(12, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_Q))
        assertEquals(6, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_Z))
        assertEquals(18, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_1))
        assertEquals(29, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_0))
        assertEquals(50, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_GRAVE))
        assertEquals(122, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_F1))
        assertEquals(111, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_F12))
        assertEquals(36, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_ENTER))
        assertEquals(51, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_DEL))
        assertEquals(117, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_FORWARD_DEL))
        assertEquals(126, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_DPAD_UP))
        assertEquals(76, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_NUMPAD_ENTER))
        assertEquals(92, AndroidKeys.macKeyCode(KeyEvent.KEYCODE_NUMPAD_9))
    }

    @Test fun theWindowsKeyIsCommandAndAltIsOption() {
        assertEquals(MacKey(55, Keysym.COMMAND_LEFT), AndroidKeys.macKey(KeyEvent.KEYCODE_META_LEFT, emptySet(), 0, 0))
        assertEquals(MacKey(54, Keysym.COMMAND_RIGHT), AndroidKeys.macKey(KeyEvent.KEYCODE_META_RIGHT, emptySet(), 0, 0))
        assertEquals(MacKey(58, Keysym.OPTION_LEFT), AndroidKeys.macKey(KeyEvent.KEYCODE_ALT_LEFT, emptySet(), 0, 0))
        assertEquals(MacKey(59, Keysym.CONTROL_LEFT), AndroidKeys.macKey(KeyEvent.KEYCODE_CTRL_LEFT, emptySet(), 0, 0))
        assertEquals(setOf(ModifierKey.COMMAND, ModifierKey.SHIFT),
            AndroidKeys.heldModifiers(KeyEvent.META_META_ON or KeyEvent.META_SHIFT_ON))
    }

    @Test fun aKeyTypesWhatItsCharacterIs() {
        assertEquals(MacKey(0, 'a'.code), AndroidKeys.macKey(KeyEvent.KEYCODE_A, emptySet(), 'a'.code, 'a'.code))
        assertEquals(MacKey(0, 'A'.code), AndroidKeys.macKey(KeyEvent.KEYCODE_A, setOf(ModifierKey.SHIFT), 'A'.code, 'A'.code))
        // Caps Lock: upper case without Shift, lower case with it
        assertEquals('A'.code, AndroidKeys.keysym(KeyEvent.KEYCODE_A, emptySet(), 'a'.code, 'a'.code, capsLock = true))
        assertEquals('a'.code, AndroidKeys.keysym(KeyEvent.KEYCODE_A, setOf(ModifierKey.SHIFT), 'A'.code, 'A'.code, capsLock = true))
        // A German layout's ü: its own keysym (Latin-1), at the key's position
        assertEquals(MacKey(33, 0xfc), AndroidKeys.macKey(KeyEvent.KEYCODE_LEFT_BRACKET, emptySet(), 0xfc, 0xfc))
        // Beyond Latin-1: a Unicode keysym
        assertEquals(0x0100_20ac, AndroidKeys.keysym(KeyEvent.KEYCODE_E, setOf(ModifierKey.OPTION), 0x20ac, 'e'.code))
    }

    @Test fun withCommandOrControlTheKeysOwnCharacterGoes() {
        // Control-C makes a control character on Android; the Mac gets "c" with Control held.
        assertEquals('c'.code, AndroidKeys.keysym(KeyEvent.KEYCODE_C, setOf(ModifierKey.CONTROL), 3, 'c'.code))
        assertEquals('C'.code, AndroidKeys.keysym(KeyEvent.KEYCODE_C, setOf(ModifierKey.COMMAND, ModifierKey.SHIFT), 'C'.code, 'C'.code))
    }

    @Test fun specialKeysHaveTheirKeysyms() {
        assertEquals(Keysym.RETURN, AndroidKeys.keysym(KeyEvent.KEYCODE_ENTER, emptySet(), 10, 10))
        assertEquals(Keysym.BACKSPACE, AndroidKeys.keysym(KeyEvent.KEYCODE_DEL, emptySet(), 0, 0))
        assertEquals(Keysym.function(5), AndroidKeys.keysym(KeyEvent.KEYCODE_F5, emptySet(), 0, 0))
        assertEquals(0xffc2, Keysym.function(5))
        assertEquals(Keysym.keypad(7), AndroidKeys.keysym(KeyEvent.KEYCODE_NUMPAD_7, emptySet(), '7'.code, '7'.code))
        assertEquals(Keysym.LEFT, AndroidKeys.keysym(KeyEvent.KEYCODE_DPAD_LEFT, emptySet(), 0, 0))
        assertNull(AndroidKeys.macKey(KeyEvent.KEYCODE_UNKNOWN, emptySet(), 0, 0))
    }

    @Test fun thePhoneKeepsItsOwnKeys() {
        assertTrue(AndroidKeys.isPhoneKey(KeyEvent.KEYCODE_VOLUME_UP))
        assertTrue(AndroidKeys.isPhoneKey(KeyEvent.KEYCODE_BACK))
        assertFalse(AndroidKeys.isPhoneKey(KeyEvent.KEYCODE_ESCAPE))
    }

    @Test fun keysymsAsOSSHasThem() {
        assertEquals(Keysym.RETURN, Keysym.character('\n'.code))
        assertEquals(Keysym.TAB, Keysym.character('\t'.code))
        assertEquals('é'.code, Keysym.character('é'.code))
        assertEquals(0x0101f600, Keysym.character(0x1f600))
        assertTrue(Keysym.typesInSecureInput('a'.code))
        assertTrue(Keysym.typesInSecureInput(Keysym.RETURN))
        assertFalse(Keysym.typesInSecureInput('é'.code))
        assertEquals(ModifierKey.OPTION, ModifierKey.of(Keysym.OPTION_RIGHT))
        assertEquals(MacKey(12, 'q'.code) to false, MacKey.usKeystroke('q'))
        assertEquals(MacKey(19, '@'.code) to true, MacKey.usKeystroke('@'))
        assertEquals(MacKey(111, Keysym.function(12)), MacKey.function(12))
        assertEquals(MacKey(36, Keysym.RETURN), MacKey.of(Keysym.RETURN))
    }
}

/** The keyboard side of a session (OSS's SessionController keys, KeyInputProxy's typed text). */
class KeyboardTests {
    private class Recorder : KeyOutput {
        val events = ArrayList<String>()
        override fun sendKey(key: MacKey, down: Boolean) {
            events += (if (down) "+" else "-") + name(key)
        }
        override fun sendText(text: String) { events += "text:$text" }
        override fun pasteText(text: String) { events += "paste:$text" }

        private fun name(key: MacKey) = when (key.keysym) {
            Keysym.COMMAND_LEFT -> "cmd"
            Keysym.SHIFT_LEFT -> "shift"
            Keysym.OPTION_LEFT -> "opt"
            Keysym.CONTROL_LEFT -> "ctrl"
            Keysym.BACKSPACE -> "bs"
            Keysym.RETURN -> "return"
            Keysym.TAB -> "tab"
            Keysym.ESCAPE -> "esc"
            else -> if (key.keysym in 0x20..0x7e) key.keysym.toChar().toString() else "0x" + key.keysym.toString(16)
        }
    }

    @Test fun textFromTheOnScreenKeyboardGoesAsText() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        assertTrue(keyboard.replaceText(0, "Hallo"))
        assertTrue(keyboard.replaceText(2, "p\nok"))
        assertEquals(listOf("text:Hallo", "+bs", "-bs", "+bs", "-bs", "text:p", "+return", "-return", "text:ok"), out.events)
    }

    @Test fun beyondTheBasicPlaneOrWithAnInputMethodTextIsPasted() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.replaceText(0, "😀")
        keyboard.macComposes = true
        keyboard.replaceText(0, "日本")
        assertEquals(listOf("paste:😀", "paste:日本"), out.events)
    }

    @Test fun aTappedModifierHoldsForTheNextKeyOnly() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.toggleSticky(ModifierKey.COMMAND)
        assertEquals(setOf(ModifierKey.COMMAND), keyboard.sticky)
        // Command-C from the on-screen keyboard: keys, not text, and the field's text no longer counts
        assertFalse(keyboard.replaceText(0, "c"))
        keyboard.replaceText(0, "d")
        assertEquals(listOf("+cmd", "+c", "-c", "-cmd", "text:d"), out.events)
        assertTrue(keyboard.sticky.isEmpty())
    }

    @Test fun aLockedModifierStaysDownUntilTappedAgain() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.setLocked(ModifierKey.OPTION, true)
        keyboard.typeKey(MacKey.LEFT)
        keyboard.typeKey(MacKey.LEFT)
        keyboard.toggleSticky(ModifierKey.OPTION)
        assertEquals(listOf("+opt", "+0xff51", "-0xff51", "+0xff51", "-0xff51", "-opt"), out.events)
    }

    @Test fun optionWithTextUsesTheUSKeyAndShift() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.setLocked(ModifierKey.OPTION, true)
        keyboard.replaceText(0, "@")
        assertEquals(listOf("+opt", "+shift", "+@", "-@", "-shift"), out.events)
    }

    @Test fun hardwareKeysGoDownAndUpWithTheirCode() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        val a = MacKey(0, 'a'.code)
        assertTrue(keyboard.keyDown(KeyEvent.KEYCODE_A, emptySet(), a))
        assertTrue(keyboard.keyDown(KeyEvent.KEYCODE_A, emptySet(), a, repeat = true))
        assertTrue(keyboard.keyUp(KeyEvent.KEYCODE_A))
        assertFalse(keyboard.keyUp(KeyEvent.KEYCODE_A))
        assertEquals(listOf("+a", "+a", "-a"), out.events)
    }

    @Test fun nothingGoesWhileNotControlling() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.isControlling = { false }
        assertFalse(keyboard.keyDown(KeyEvent.KEYCODE_A, emptySet(), MacKey(0, 'a'.code)))
        assertFalse(keyboard.replaceText(0, "x"))
        keyboard.typeKey(MacKey.ESCAPE)
        assertTrue(out.events.isEmpty())
    }

    @Test fun passwordFieldsTakeOnlyASCII() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        var notices = 0
        keyboard.onSecureInputNotice = { notices++ }
        keyboard.secureInput = true
        assertFalse(keyboard.replaceText(0, "pässword"))
        assertEquals(listOf("text:pssword"), out.events)
        assertEquals(1, notices)
    }

    @Test fun lettingGoReleasesEverything() {
        val out = Recorder()
        val keyboard = Keyboard(out)
        keyboard.keyDown(KeyEvent.KEYCODE_SHIFT_LEFT, emptySet(), MacKey.SHIFT)
        keyboard.keyDown(KeyEvent.KEYCODE_A, setOf(ModifierKey.SHIFT), MacKey(0, 'A'.code))
        keyboard.setLocked(ModifierKey.COMMAND, true)
        out.events.clear()
        keyboard.releaseAll()
        assertEquals(listOf("-A", "-shift", "-cmd"), out.events)
        assertTrue(keyboard.locked.isEmpty())
    }

    @Test fun chordsPressTheirModifiersAroundTheKey() {
        val out = Recorder()
        Keyboard(out).sendChord(KeyChord.APP_SWITCHER)
        assertEquals(listOf("+cmd", "+tab", "-tab", "-cmd"), out.events)
    }

    @Test fun theTypedTextIsComparedByCharacters() {
        assertEquals(0 to "lo", Keyboard.diff("Hal", "Hallo"))
        assertEquals(2 to "p", Keyboard.diff("Hallo", "Halp"))
        assertEquals(1 to "", Keyboard.diff("ae\u0301", "a"))
        assertEquals(listOf("a", "\uD83D\uDE00", "e\u0301"), Keyboard.graphemes("a\uD83D\uDE00e\u0301"))
    }
}
