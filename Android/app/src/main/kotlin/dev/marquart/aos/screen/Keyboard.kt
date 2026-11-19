// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing
// (Session/SessionController.swift: keys, typing, sticky modifiers; SessionUI/KeyInputProxy.swift: typed text).
// Only the Mac's side of it: aOS's screens are Macs.

package dev.marquart.aos.screen

import java.text.BreakIterator

/** Where keys and text go (the session). */
interface KeyOutput {
    fun sendKey(key: MacKey, down: Boolean)
    fun sendText(text: String)
    fun pasteText(text: String)
}

/**
 * The keyboard side of a session, as OSS's SessionController does it: hardware keys by their position with what they
 * type, text from the on-screen keyboard as text (or keys while modifiers are held), the modifier keys of the key
 * row (a tap: for the next key; a long press: locked), Caps Lock, and letting go of everything.
 */
class Keyboard(private val out: KeyOutput) {
    /** Keys and clicks reach the Mac (connected, not observing). */
    var isControlling: () -> Boolean = { true }

    /** A password field on the Mac has the focus: only ASCII types there. */
    var secureInput = false

    /** The Mac's keyboard source composes (Japanese, Chinese): text is pasted instead of typed. */
    var macComposes = false

    /** Something can't be typed into a password field (the session says so). */
    var onSecureInputNotice: () -> Unit = {}

    /** A key or click may have moved the Mac's text cursor: the on-screen keyboard forgets what it typed. */
    var onTextCursorMayHaveMoved: () -> Unit = {}

    /** The modifiers of the key row changed (for showing them). */
    var onModifiersChanged: () -> Unit = {}

    private val pressedKeys = LinkedHashMap<Int, MacKey>()
    var sticky: Set<ModifierKey> = emptySet()
        private set(value) {
            field = value
            onModifiersChanged()
        }
    var locked: Set<ModifierKey> = emptySet()
        private set(value) {
            field = value
            onModifiersChanged()
        }
    private var capsLockEngaged = false

    // Hardware keys

    /** A hardware key went down (`id`: Android's key code). False: not for the Mac. */
    fun keyDown(id: Int, held: Set<ModifierKey>, mapped: MacKey?, repeat: Boolean = false): Boolean {
        if (!isControlling() || mapped == null) return false
        if (repeat) {
            val pressed = pressedKeys[id] ?: return true
            if (!pressed.isModifier) out.sendKey(pressed, true)
            return true
        }
        val modifier = ModifierKey.of(mapped.keysym)
        if (modifier != null && modifier in locked && mapped.keysym == modifier.keysym) return true
        if (!mapped.isModifier) onTextCursorMayHaveMoved()
        if (secureInput && !Keysym.typesInSecureInput(mapped.keysym)) {
            onSecureInputNotice()
            return true
        }
        pressedKeys.remove(id)?.let { out.sendKey(it, false) }
        if (mapped.isModifier) {
            pressedKeys[id] = mapped
            out.sendKey(mapped, true)
            return true
        }
        val stickyNow = sticky - held
        if (stickyNow.isNotEmpty()) {
            sticky = emptySet()
            tap(mapped, stickyNow)
            return true
        }
        pressedKeys[id] = mapped
        out.sendKey(mapped, true)
        return true
    }

    /** A hardware key came up. */
    fun keyUp(id: Int): Boolean {
        val pressed = pressedKeys.remove(id) ?: return false
        out.sendKey(pressed, false)
        return true
    }

    /** Caps Lock on a hardware keyboard: the Mac keeps its own state; a press toggles it there. */
    fun capsLock(down: Boolean) {
        if (!isControlling()) return
        if (down) {
            capsLockEngaged = !capsLockEngaged
            out.sendKey(MacKey.CAPS_LOCK, capsLockEngaged)
        }
    }

    // Text from the on-screen keyboard

    /** Deletes `count` characters before the Mac's text cursor and types `text` (KeyInputProxy's diff). False: what
     *  was typed went as keys (modifiers held), so the keyboard's text no longer matches. */
    fun replaceText(deleting: Int, text: String): Boolean {
        if (!isControlling()) return false
        val asText = (locked + sticky).all { it == ModifierKey.SHIFT }
        repeat(deleting) { tapKey(MacKey.BACKSPACE) }
        val typed = insertText(text)
        return asText && typed
    }

    private fun insertText(text: String): Boolean {
        var typed = true
        val characters = graphemes(text)
        if (!locked.all { it == ModifierKey.SHIFT }) {
            for (c in characters) typed = typeCharacter(c) && typed
            return typed
        }
        var rest = characters
        if (sticky.isNotEmpty() && rest.isNotEmpty()) {
            typed = typeCharacter(rest.first())
            rest = rest.drop(1)
        }
        return typeUnmodified(rest) && typed
    }

    private fun typeUnmodified(characters: List<String>): Boolean {
        var typed = true
        val run = StringBuilder()
        for (c in characters) {
            val key = when (c) {
                "\n", "\r", "\r\n" -> MacKey.RETURN
                "\t" -> MacKey.TAB
                else -> null
            }
            if (key == null) {
                run.append(c)
                continue
            }
            typed = typeText(run.toString()) && typed
            run.clear()
            tap(key, emptySet())
        }
        return typeText(run.toString()) && typed
    }

    private fun typeText(text: String): Boolean {
        if (text.isEmpty()) return true
        if (secureInput) {
            val ascii = text.filter { it.code < 0x80 }
            if (ascii.isNotEmpty()) out.sendText(ascii)
            if (ascii.length != text.length) {
                onSecureInputNotice()
                return false
            }
            return true
        }
        // ScreensharingAgent types one UTF-16 unit per Unicode keysym: beyond the basic plane, or with a Mac keyboard
        // source that composes, the text is pasted instead (OSS).
        val inBasicPlane = text.codePoints().allMatch { it <= 0xffff }
        if (inBasicPlane && !macComposes) out.sendText(text) else out.pasteText(text)
        return true
    }

    private fun typeCharacter(character: String): Boolean {
        val modifiers = locked + sticky
        var shift = false
        val key: MacKey = when (character) {
            "\n", "\r", "\r\n" -> MacKey.RETURN
            "\t" -> MacKey.TAB
            else -> {
                val us = if (ModifierKey.OPTION in modifiers && character.length == 1) MacKey.usKeystroke(character[0]) else null
                if (us != null) {
                    shift = us.second
                    us.first
                } else {
                    var text = character
                    if (ModifierKey.COMMAND in modifiers || ModifierKey.CONTROL in modifiers) {
                        text = if (ModifierKey.SHIFT in modifiers) text.uppercase() else text.lowercase()
                    }
                    if (text.isEmpty()) return false
                    MacKey.of(Keysym.character(text.codePointAt(0)))
                }
            }
        }
        val stickyNow = sticky
        sticky = emptySet()
        if (secureInput && !Keysym.typesInSecureInput(key.keysym)) {
            onSecureInputNotice()
            return false
        }
        val pressing = if (shift) stickyNow + ModifierKey.SHIFT else stickyNow
        tap(key, pressing - locked)
        return true
    }

    // Keys from the key row and the menus

    /** A key from the key row (Escape, Tab, arrows): with the modifiers that were tapped before it. */
    fun typeKey(key: MacKey) {
        if (!isControlling()) return
        onTextCursorMayHaveMoved()
        tapKey(key)
    }

    /** A shortcut (Cmd-Tab, Control-Up). */
    fun sendChord(chord: KeyChord) {
        if (!isControlling()) return
        onTextCursorMayHaveMoved()
        tap(chord.key, chord.modifiers.toSet())
    }

    private fun tapKey(key: MacKey) {
        val stickyNow = sticky
        sticky = emptySet()
        tap(key, stickyNow)
    }

    private fun tap(key: MacKey, modifiers: Set<ModifierKey>) {
        val held = ModifierKey.entries.filter { it in modifiers }.map { it.macKey }
        held.forEach { out.sendKey(it, true) }
        out.sendKey(key, true)
        out.sendKey(key, false)
        held.reversed().forEach { out.sendKey(it, false) }
    }

    /** A tap on a modifier of the key row: for the next key or click; again: not; a locked one lets go. */
    fun toggleSticky(modifier: ModifierKey) {
        when {
            modifier in locked -> setLocked(modifier, false)
            modifier in sticky -> sticky = sticky - modifier
            isControlling() -> sticky = sticky + modifier
        }
    }

    /** A long press on a modifier: held down until tapped again. */
    fun setLocked(modifier: ModifierKey, isLocked: Boolean) {
        if (isLocked == modifier in locked || (isLocked && !isControlling())) return
        sticky = sticky - modifier
        locked = if (isLocked) locked + modifier else locked - modifier
        out.sendKey(modifier.macKey, isLocked)
    }

    /** Modifiers tapped for the next click go down with it (OSS's pointer modifiers); returns what to let go after. */
    fun takeStickyForClick(): Set<ModifierKey> {
        val stickyNow = sticky - locked
        if (stickyNow.isEmpty()) return emptySet()
        sticky = emptySet()
        ModifierKey.entries.filter { it in stickyNow }.forEach { out.sendKey(it.macKey, true) }
        return stickyNow
    }

    fun releaseClickModifiers(modifiers: Set<ModifierKey>) {
        ModifierKey.entries.reversed().filter { it in modifiers }.forEach { out.sendKey(it.macKey, false) }
    }

    /** Lets go of every key (the session goes, the app leaves, observe mode). */
    fun releaseAll() {
        val keys = pressedKeys.values.sortedBy { if (it.isModifier) 1 else 0 }
        pressedKeys.clear()
        keys.forEach { out.sendKey(it, false) }
        if (capsLockEngaged) {
            capsLockEngaged = false
            out.sendKey(MacKey.CAPS_LOCK, false)
        }
        locked.forEach { out.sendKey(it.macKey, false) }
        if (locked.isNotEmpty()) locked = emptySet()
        if (sticky.isNotEmpty()) sticky = emptySet()
    }

    companion object {
        /** User-perceived characters (Swift's `Character`), so one backspace deletes one of them. */
        fun graphemes(text: String): List<String> {
            if (text.isEmpty()) return emptyList()
            val it = BreakIterator.getCharacterInstance()
            it.setText(text)
            val result = ArrayList<String>()
            var start = it.first()
            var end = it.next()
            while (end != BreakIterator.DONE) {
                result += text.substring(start, end)
                start = end
                end = it.next()
            }
            return result
        }

        /** How to get from what the keyboard typed so far to its text now: characters to delete at the end, and what
         *  to type then (KeyInputProxy's `sendTypedText`). */
        fun diff(typed: String, now: String): Pair<Int, String> {
            val old = graphemes(typed)
            val new = graphemes(now)
            var kept = 0
            while (kept < old.size && kept < new.size && old[kept] == new[kept]) kept++
            return (old.size - kept) to new.drop(kept).joinToString("")
        }
    }
}
