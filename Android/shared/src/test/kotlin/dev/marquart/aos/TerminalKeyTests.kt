package dev.marquart.aos

import dev.marquart.aos.terminal.ArrowPad
import dev.marquart.aos.terminal.KeyBarLayout
import dev.marquart.aos.terminal.PasteEncoder
import dev.marquart.aos.terminal.StickyModifiers
import dev.marquart.aos.terminal.TerminalArrowKeys
import dev.marquart.aos.terminal.TerminalFontSize
import dev.marquart.aos.terminal.TerminalKey
import dev.marquart.aos.terminal.TerminalKeyEncoder
import dev.marquart.aos.terminal.TerminalModifiers
import dev.marquart.aos.terminal.TerminalRowText
import dev.marquart.aos.terminal.TerminalSwipe
import dev.marquart.aos.terminal.TerminalText
import org.junit.Test
import kotlin.math.abs
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val SHIFT = TerminalModifiers.SHIFT
private val ALT = TerminalModifiers.ALT
private val CONTROL = TerminalModifiers.CONTROL
private val NONE = TerminalModifiers.NONE

/** What the key bar's keys send (iOS TerminalKeyEncoderTests), as xterm sends it. */
class TerminalKeyEncoderTests {
    private fun bytes(key: TerminalKey, modifiers: TerminalModifiers = NONE, app: Boolean = false) =
        TerminalKeyEncoder.bytes(key, modifiers, app).toList()

    private fun esc(rest: String) = (byteArrayOf(0x1b) + rest.toByteArray()).toList()
    private fun of(vararg b: Int) = b.map { it.toByte() }

    @Test fun plainKeys() {
        assertEquals(of(0x1b), bytes(TerminalKey.Escape))
        assertEquals(of(0x09), bytes(TerminalKey.Tab))
        assertEquals(of(0x0d), bytes(TerminalKey.Enter))
        assertEquals(of(0x7f), bytes(TerminalKey.Backspace))
        assertEquals("~".toByteArray().toList(), bytes(TerminalKey.Text("~")))
        assertEquals("ä".toByteArray().toList(), bytes(TerminalKey.Text("ä")))
    }

    @Test fun arrowsFollowTheCursorKeyMode() {
        assertEquals(esc("[A"), bytes(TerminalKey.Up))
        assertEquals(esc("[B"), bytes(TerminalKey.Down))
        assertEquals(esc("[C"), bytes(TerminalKey.Right))
        assertEquals(esc("[D"), bytes(TerminalKey.Left))
        assertEquals(esc("OA"), bytes(TerminalKey.Up, app = true))
        assertEquals(esc("OH"), bytes(TerminalKey.Home, app = true))
        assertEquals(esc("[F"), bytes(TerminalKey.End))
    }

    @Test fun modifiedArrowsUseTheXtermParameter() {
        assertEquals(esc("[1;5A"), bytes(TerminalKey.Up, CONTROL))
        assertEquals(esc("[1;3D"), bytes(TerminalKey.Left, ALT))
        assertEquals(esc("[1;6C"), bytes(TerminalKey.Right, SHIFT + CONTROL))
        // Modifiers win over application cursor mode, as in xterm
        assertEquals(esc("[1;2B"), bytes(TerminalKey.Down, SHIFT, app = true))
    }

    @Test fun navigationAndFunctionKeys() {
        assertEquals(esc("[5~"), bytes(TerminalKey.PageUp))
        assertEquals(esc("[6;5~"), bytes(TerminalKey.PageDown, CONTROL))
        assertEquals(esc("[3~"), bytes(TerminalKey.ForwardDelete))
        assertEquals(esc("[2~"), bytes(TerminalKey.Insert))
        assertEquals(esc("OP"), bytes(TerminalKey.Function(1)))
        assertEquals(esc("OS"), bytes(TerminalKey.Function(4)))
        assertEquals(esc("[15~"), bytes(TerminalKey.Function(5)))
        assertEquals(esc("[21~"), bytes(TerminalKey.Function(10)))
        assertEquals(esc("[24~"), bytes(TerminalKey.Function(12)))
        assertEquals(esc("[1;2P"), bytes(TerminalKey.Function(1), SHIFT))
        assertEquals(esc("[15;5~"), bytes(TerminalKey.Function(5), CONTROL))
        assertTrue(bytes(TerminalKey.Function(13)).isEmpty())
    }

    @Test fun tabEscapeAndBackspaceWithModifiers() {
        assertEquals(esc("[Z"), bytes(TerminalKey.Tab, SHIFT))
        assertEquals(of(0x1b, 0x09), bytes(TerminalKey.Tab, ALT))
        assertEquals(of(0x1b, 0x1b), bytes(TerminalKey.Escape, ALT))
        assertEquals(of(0x08), bytes(TerminalKey.Backspace, CONTROL))
        assertEquals(of(0x1b, 0x7f), bytes(TerminalKey.Backspace, ALT))
        assertEquals(of(0x1b, 0x0d), bytes(TerminalKey.Enter, ALT))
    }

    @Test fun controlTurnsCharactersIntoControlCodes() {
        fun ctrl(text: String) = bytes(TerminalKey.Text(text), CONTROL)
        assertEquals(of(0x03), ctrl("c"))
        assertEquals(of(0x03), ctrl("C"))
        assertEquals(of(0x01), ctrl("a"))
        assertEquals(of(0x1a), ctrl("z"))
        assertEquals(of(0x1b), ctrl("["))
        assertEquals(of(0x1c), ctrl("\\"))
        assertEquals(of(0x1d), ctrl("]"))
        assertEquals(of(0x1e), ctrl("^"))
        assertEquals(of(0x1f), ctrl("_"))
        assertEquals(of(0x1f), ctrl("/"))
        assertEquals(of(0x00), ctrl(" "))
        assertEquals(of(0x00), ctrl("@"))
        assertEquals(of(0x7f), ctrl("?"))
        // Nothing to map: sent as typed
        assertEquals("ä".toByteArray().toList(), ctrl("ä"))
        assertEquals("ab".toByteArray().toList(), ctrl("ab"))
    }

    @Test fun altIsMeta() {
        assertEquals(of(0x1b, 'x'.code), bytes(TerminalKey.Text("x"), ALT))
        assertEquals(of(0x1b, 'b'.code), bytes(TerminalKey.Text("b"), ALT))
        assertEquals(of(0x1b, 0x03), bytes(TerminalKey.Text("c"), ALT + CONTROL))
    }
}

/** The key bar's modifiers: tap for one key, double tap to lock, hold like a hardware key (iOS StickyModifierTests). */
class StickyModifierTests {
    @Test fun aTapHoldsAModifierForOneKey() {
        val m = StickyModifiers()
        assertTrue(m.active.isEmpty)
        assertEquals(StickyModifiers.State.ONCE, m.tap(CONTROL, 0.0))
        assertEquals(CONTROL, m.active)
        m.consume()
        assertEquals(StickyModifiers.State.OFF, m.state(CONTROL))
        assertTrue(m.active.isEmpty)
    }

    @Test fun aSecondTapTurnsItOffAgain() {
        val m = StickyModifiers()
        m.tap(CONTROL, 0.0)
        assertEquals(StickyModifiers.State.OFF, m.tap(CONTROL, 1.0))
        assertTrue(m.active.isEmpty)
    }

    @Test fun aDoubleTapLocksUntilTheNextTap() {
        val m = StickyModifiers()
        m.tap(ALT, 10.0)
        assertEquals(StickyModifiers.State.LOCKED, m.tap(ALT, 10.2))
        m.consume()
        m.consume()
        assertEquals(StickyModifiers.State.LOCKED, m.state(ALT))
        assertEquals(ALT, m.active)
        // A quick third tap unlocks; it doesn't start a new double tap
        assertEquals(StickyModifiers.State.OFF, m.tap(ALT, 10.3))
        assertEquals(StickyModifiers.State.ONCE, m.tap(ALT, 10.4))
    }

    @Test fun aTapAfterAKeyIsNotADoubleTap() {
        val m = StickyModifiers()
        m.tap(CONTROL, 0.0)
        m.consume()
        assertEquals(StickyModifiers.State.ONCE, m.tap(CONTROL, 0.1))
    }

    @Test fun tapsOfDifferentModifiersDontLock() {
        val m = StickyModifiers()
        m.tap(CONTROL, 0.0)
        assertEquals(StickyModifiers.State.ONCE, m.tap(ALT, 0.1))
        assertEquals(CONTROL + ALT, m.active)
        m.consume()
        assertTrue(m.active.isEmpty)
    }

    @Test fun holdingWorksLikeAHardwareKey() {
        val m = StickyModifiers()
        m.press(CONTROL)
        assertEquals(CONTROL, m.active)
        m.consume() // a key was sent while held
        assertEquals(CONTROL, m.active)
        assertEquals(StickyModifiers.State.OFF, m.release(CONTROL, 1.0))
        assertTrue(m.active.isEmpty)
    }

    @Test fun pressAndReleaseWithoutAKeyIsATap() {
        val m = StickyModifiers()
        m.press(CONTROL)
        assertEquals(StickyModifiers.State.ONCE, m.release(CONTROL, 1.0))
        m.press(CONTROL)
        assertEquals(StickyModifiers.State.LOCKED, m.release(CONTROL, 1.2))
    }

    @Test fun aCancelledTouchChangesNothing() {
        val m = StickyModifiers()
        m.press(ALT)
        assertEquals(StickyModifiers.State.OFF, m.release(ALT, 1.0, cancelled = true))
        assertTrue(m.active.isEmpty)
    }

    @Test fun resetClearsEverything() {
        val m = StickyModifiers()
        m.tap(CONTROL, 0.0)
        m.tap(CONTROL, 0.1)
        m.press(ALT)
        m.reset()
        assertTrue(m.active.isEmpty)
        assertEquals(StickyModifiers.State.OFF, m.state(CONTROL))
    }
}

/** Pasting: bracketed when the shell asked for it, control characters out, line breaks as the program expects them. */
class PasteEncoderTests {
    private val start = "\u001b[200~"
    private val end = "\u001b[201~"

    @Test fun bracketedPasteWrapsTheText() {
        assertEquals(start + "echo hi\nls" + end, PasteEncoder.bytes("echo hi\nls", bracketed = true).toString(Charsets.UTF_8))
    }

    @Test fun withoutBracketsLineBreaksAreReturns() {
        assertContentEquals("a\rb\rc\rd".toByteArray(), PasteEncoder.bytes("a\nb\r\nc\rd", bracketed = false))
    }

    @Test fun insideBracketsLineBreaksAreNewlines() {
        assertEquals("a\nb\nc\n", PasteEncoder.sanitized("a\r\nb\rc\n", bracketed = true))
    }

    @Test fun anEscapeInTheTextCannotEndTheBracket() {
        val pasted = PasteEncoder.bytes("safe\u001b[201~rm -rf ~\n", bracketed = true).toString(Charsets.UTF_8)
        assertEquals(start + "safe[201~rm -rf ~\n" + end, pasted)
        assertEquals(2, pasted.split(end).size)
    }

    @Test fun controlCharactersAreDroppedTabsStay() {
        assertEquals("a\tbcdef", PasteEncoder.sanitized("a\tb\u0003c\u0000d\u007fe\u009bf\u0008", bracketed = false))
        assertEquals("ä € 😀 日本", PasteEncoder.sanitized("ä € 😀 日本", bracketed = true))
    }

    @Test fun onlyUnbracketedLineBreaksRunCommands() {
        assertTrue(PasteEncoder.runsLines("ls\npwd", bracketed = false))
        assertTrue(PasteEncoder.runsLines("ls\n", bracketed = false))
        assertFalse(PasteEncoder.runsLines("ls\npwd", bracketed = true))
        assertFalse(PasteEncoder.runsLines("ls -la", bracketed = false))
    }
}

/** The pad and the swipe on the terminal (iOS ArrowPadTests, KeyBarLayoutTests' swipe rule). */
class ArrowTests {
    @Test fun directionsPastTheDeadZone() {
        assertNull(ArrowPad.key(5f, 5f))
        assertEquals(TerminalKey.Right, ArrowPad.key(20f, 4f))
        assertEquals(TerminalKey.Left, ArrowPad.key(-20f, 10f))
        assertEquals(TerminalKey.Up, ArrowPad.key(3f, -15f))
        assertEquals(TerminalKey.Down, ArrowPad.key(-6f, 30f))
    }

    @Test fun fartherIsFaster() {
        val near = ArrowPad.repeatInterval(12f)
        val middle = ArrowPad.repeatInterval(50f)
        val far = ArrowPad.repeatInterval(200f)
        assertTrue(near > middle && middle > far)
        assertTrue(abs(near - 0.3) < 0.001)
        assertTrue(abs(far - 0.04) < 0.001)
    }

    @Test fun swipesSidewaysAreArrowsAndUpOrDownOnlyAsFlicksAtTheEnd() {
        fun decide(dx: Float, dy: Float, speed: Float = 200f, after: Double = 0.05, atEnd: Boolean = true) =
            TerminalSwipe.decide(dx, dy, speed, after, atEnd)
        assertNull(decide(4f, 3f), "inside the dead zone")
        assertEquals(TerminalSwipe.Decision.ARROWS, decide(14f, 2f))
        assertEquals(TerminalSwipe.Decision.ARROWS, decide(-14f, 5f))
        assertEquals(TerminalSwipe.Decision.ARROWS, decide(14f, 2f, atEnd = false), "sideways also when scrolled back")
        assertEquals(TerminalSwipe.Decision.SCROLL, decide(2f, -14f), "a slow drag up or down scrolls")
        assertEquals(TerminalSwipe.Decision.ARROWS, decide(2f, -14f, speed = -900f), "a quick flick at the end is ↑")
        assertEquals(TerminalSwipe.Decision.SCROLL, decide(2f, 14f, speed = 900f, atEnd = false), "scrolled back: flicks scroll")
        assertEquals(TerminalSwipe.Decision.NONE, decide(14f, 0f, after = 0.6), "a resting finger is a long press")
        assertEquals(TerminalSwipe.Decision.NONE, decide(1f, 1f, after = 0.6))
    }

    @Test fun theScreenEdgesBelongToTheBackGesture() {
        assertTrue(TerminalSwipe.inEdge(10f, 400f))
        assertTrue(TerminalSwipe.inEdge(390f, 400f))
        assertFalse(TerminalSwipe.inEdge(200f, 400f))
    }
}

/** The key bar's row: the arrows in the middle at the start, every key at least 46 dp (iOS KeyBarLayoutTests). */
class KeyBarLayoutTests {
    @Test fun theArrowsSitInTheMiddle() {
        for (width in listOf(359f, 370f, 386f, 392f, 411f, 424f, 600f, 744f, 840f)) {
            for (arrows in TerminalArrowKeys.entries) {
                val layout = KeyBarLayout.of(width, arrows)
                assertTrue(abs(layout.centerMidX - width / 2) < 0.01f, "$arrows at $width")
                assertTrue(layout.keyWidth >= KeyBarLayout.MINIMUM_KEY - 0.01f, "$arrows at $width")
                assertTrue(layout.leading >= if (arrows == TerminalArrowKeys.PAD) 1 else 0)
            }
        }
        // A phone upright (the bar is about 386 dp wide): Esc, Control and Tab left of the pad
        assertEquals(3, KeyBarLayout.of(386f, TerminalArrowKeys.PAD).leading)
        assertEquals(2, KeyBarLayout.of(386f, TerminalArrowKeys.FOUR_KEYS).leading)
    }

    @Test fun theRowSnapsToWholeKeys() {
        val edges = listOf(0f, 50f, 100f, 160f, 210f)
        assertEquals(50f, KeyBarLayout.snapped(70f, edges, 300f))
        assertEquals(160f, KeyBarLayout.snapped(140f, edges, 300f))
        assertEquals(300f, KeyBarLayout.snapped(280f, edges, 300f), "the end of the row")
        assertEquals(0f, KeyBarLayout.snapped(140f, edges, 0f))
    }
}

/** Links and text for copying (iOS TerminalTextTests). */
class TerminalTextTests {
    @Test fun aLinkIsFoundWhole() {
        val row = "open https://example.com/a?b=1 (now)"
        val (columns, url) = TerminalText.linkAt(row, 12)!!
        assertEquals(5..29, columns)
        assertEquals("https://example.com/a?b=1", url)
        assertNull(TerminalText.linkAt(row, 1))
        assertNull(TerminalText.linkAt("get ftp://example.com/file", 8))
        // A sentence's full stop isn't part of it
        assertEquals("https://example.com", TerminalText.linkAt("see https://example.com.", 6)?.second)
        assertEquals("https://example.com/x", TerminalText.singleLink(" https://example.com/x "))
        assertNull(TerminalText.singleLink("look at https://example.com"))
    }

    @Test fun rowsJoinWhereTheyWrapped() {
        val rows = listOf(TerminalRowText(0, "$ echo aaaa", false), TerminalRowText(1, "bbbb  ", true),
            TerminalRowText(2, "aaaabbbb", false), TerminalRowText(3, "   ", false), TerminalRowText(4, "", false))
        assertEquals("$ echo aaaabbbb\naaaabbbb", TerminalText.joined(rows))
    }

    private fun screen(lines: List<String>, wrapped: Set<Int> = emptySet()) =
        lines.mapIndexed { i, text -> TerminalRowText(100 + i, text, i in wrapped) }

    @Test fun lastOutputIsBetweenTheLastCommandAndThePrompt() {
        val rows = screen(listOf("$ ls", "a.txt", "b.txt", "$ echo hi", "hi", "$ "))
        assertEquals("hi", TerminalText.lastOutput(rows, listOf(100, 103), 105))
        // A command row below the cursor (the screen was cleared since) doesn't count
        assertEquals("hi", TerminalText.lastOutput(rows, listOf(100, 103, 130), 105))
    }

    @Test fun aCommandWithoutOutputIsSkipped() {
        val rows = screen(listOf("$ ls", "a.txt", "b.txt", "$ cd /tmp", "$ "))
        assertEquals("a.txt\nb.txt", TerminalText.lastOutput(rows, listOf(100, 103), 104))
        assertNull(TerminalText.lastOutput(rows, listOf(103), 104))
    }

    @Test fun aWrappedCommandLineIsNotOutput() {
        // Row 103 continues the command typed on row 102; Return was pressed on 103.
        val rows = screen(listOf("$ cat x", "x", "$ a very long comma", "nd", "out", "$ "), wrapped = setOf(3))
        assertEquals("out", TerminalText.lastOutput(rows, listOf(100, 103), 105))
        assertEquals("x", TerminalText.lastOutput(rows, listOf(100, 103), 104))
    }

    @Test fun fontSizesStayInRange() {
        assertEquals(8, TerminalFontSize.clamped(3f))
        assertEquals(13, TerminalFontSize.clamped(13.4f))
        assertEquals(28, TerminalFontSize.clamped(40f))
    }
}
