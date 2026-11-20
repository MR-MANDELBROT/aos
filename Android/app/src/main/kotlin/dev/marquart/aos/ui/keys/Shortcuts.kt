package dev.marquart.aos.ui.keys

import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.KeyboardShortcutInfo
import android.content.Context
import dev.marquart.aos.R

/**
 * The app's keyboard shortcuts (a tablet's keyboard, a Chromebook, a desktop window). The tabs are Ctrl+1 to 4, as a
 * browser's; what belongs to the terminal has Shift too (Ctrl+Shift+T, V, C, plus and minus), as in desktop terminals,
 * so Ctrl+letter stays the shell's. MainActivity takes them before the view with the focus (the terminal would send
 * them to the Mac); a running screen session is a window of its own and gets every key for the Mac.
 * `onProvideKeyboardShortcuts` lists them in the system's shortcuts helper.
 */
enum class AppShortcut(val label: Int, val keyCode: Int, val shift: Boolean) {
    OVERVIEW(R.string.shortcut_overview, KeyEvent.KEYCODE_1, false),
    TERMINAL(R.string.shortcut_terminal, KeyEvent.KEYCODE_2, false),
    SCREEN(R.string.shortcut_screen, KeyEvent.KEYCODE_3, false),
    SETTINGS(R.string.shortcut_settings, KeyEvent.KEYCODE_4, false),
    NEW_SESSION(R.string.shortcut_new_session, KeyEvent.KEYCODE_T, true),
    PASTE(R.string.shortcut_paste, KeyEvent.KEYCODE_V, true),
    COPY_SCREEN(R.string.shortcut_copy_screen, KeyEvent.KEYCODE_C, true),
    BIGGER_TEXT(R.string.shortcut_bigger_text, KeyEvent.KEYCODE_EQUALS, true),
    SMALLER_TEXT(R.string.shortcut_smaller_text, KeyEvent.KEYCODE_MINUS, true);

    /** The modifiers as KeyEvent's meta state (for the shortcuts helper). */
    val modifiers: Int get() = KeyEvent.META_CTRL_ON or if (shift) KeyEvent.META_SHIFT_ON else 0

    /** Only while a terminal is on screen. */
    val needsTerminal: Boolean get() = this == PASTE || this == COPY_SCREEN || this == BIGGER_TEXT || this == SMALLER_TEXT

    companion object {
        /** The shortcut a key with these modifiers is: Ctrl, with or without Shift as the shortcut says, nothing else. */
        fun match(keyCode: Int, metaState: Int): AppShortcut? {
            val ctrl = metaState and KeyEvent.META_CTRL_ON != 0
            val shift = metaState and KeyEvent.META_SHIFT_ON != 0
            val others = metaState and (KeyEvent.META_ALT_ON or KeyEvent.META_META_ON) != 0
            if (!ctrl || others) return null
            // The plus of a number pad or of a layout with a key of its own counts as the equals key's.
            val code = if (keyCode == KeyEvent.KEYCODE_PLUS || keyCode == KeyEvent.KEYCODE_NUMPAD_ADD) KeyEvent.KEYCODE_EQUALS
                else if (keyCode == KeyEvent.KEYCODE_NUMPAD_SUBTRACT) KeyEvent.KEYCODE_MINUS else keyCode
            return entries.firstOrNull { it.keyCode == code && it.shift == shift }
        }

        /** The list for the system's shortcuts helper. */
        fun group(context: Context): KeyboardShortcutGroup = KeyboardShortcutGroup(context.getString(R.string.app_name),
            entries.map { KeyboardShortcutInfo(context.getString(it.label), it.keyCode, it.modifiers) })
    }
}
