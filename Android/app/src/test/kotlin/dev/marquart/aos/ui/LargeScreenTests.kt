package dev.marquart.aos.ui

import android.view.KeyEvent
import androidx.window.core.layout.WindowSizeClass
import androidx.window.core.layout.computeWindowSizeClass
import dev.marquart.aos.ui.keys.AppShortcut
import dev.marquart.aos.ui.layout.HeightClass
import dev.marquart.aos.ui.layout.Navigation
import dev.marquart.aos.ui.layout.WidthClass
import dev.marquart.aos.ui.layout.WindowLayout
import dev.marquart.aos.ui.layout.foldOf
import dev.marquart.aos.ui.layout.heightClassOf
import dev.marquart.aos.ui.layout.widthClassOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Android's side of the large-screen layout: Jetpack's window size class and fold as the layout's, the shortcuts. */
class LargeScreenTests {
    private fun sizeClass(width: Float, height: Float) =
        WindowSizeClass.BREAKPOINTS_V2.computeWindowSizeClass(width, height)

    private fun layout(width: Float, height: Float): WindowLayout {
        val c = sizeClass(width, height)
        return WindowLayout(width, height, widthClassOf(c), heightClassOf(c))
    }

    @Test fun jetpacksSizeClassBecomesTheLayouts() {
        assertEquals(WidthClass.COMPACT, widthClassOf(sizeClass(411f, 891f)))
        assertEquals(WidthClass.MEDIUM, widthClassOf(sizeClass(800f, 1280f)))
        assertEquals(WidthClass.EXPANDED, widthClassOf(sizeClass(841f, 701f)))
        assertEquals(WidthClass.LARGE, widthClassOf(sizeClass(1280f, 800f)))
        assertEquals(HeightClass.COMPACT, heightClassOf(sizeClass(891f, 411f)))
        assertEquals(HeightClass.MEDIUM, heightClassOf(sizeClass(1280f, 800f)))
        assertEquals(HeightClass.EXPANDED, heightClassOf(sizeClass(800f, 1280f)))
    }

    @Test fun jetpacksClassesAgreeWithTheLayoutsOwnBreakpoints() {
        for ((w, h) in listOf(320f to 480f, 599f to 479f, 600f to 480f, 839f to 899f, 840f to 900f, 1199f to 700f, 1200f to 700f, 1920f to 1080f)) {
            val c = sizeClass(w, h)
            assertEquals(WindowLayout.widthClass(w), widthClassOf(c), "width $w")
            assertEquals(WindowLayout.heightClass(h), heightClassOf(c), "height $h")
        }
    }

    @Test fun sizeClassToLayoutMode() {
        assertEquals(Navigation.BAR, layout(411f, 891f).navigation)
        assertEquals(Navigation.RAIL, layout(800f, 1280f).navigation)
        assertEquals(Navigation.RAIL, layout(841f, 701f).navigation)
        assertEquals(Navigation.DRAWER, layout(1280f, 800f).navigation)
        assertTrue(layout(1280f, 800f).twoPane)
        assertTrue(layout(841f, 701f).twoPane)
        assertEquals(false, layout(800f, 1280f).twoPane)
        assertEquals(false, layout(891f, 411f).twoPane)
    }

    @Test fun aFoldsPixelsBecomeDp() {
        val fold = foldOf(0, 1104, 2208, 1104, density = 2.625f, horizontal = true, halfOpened = true, separating = true)
        assertEquals(1104 / 2.625f, fold.top)
        assertEquals(2208 / 2.625f, fold.right)
        val table = WindowLayout(841f, 841f, fold = fold)
        assertTrue(table.isTabletop)
        assertEquals(fold, table.tableFold)
    }

    @Test fun shortcutsAreControlWithOrWithoutShift() {
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        val ctrlShift = ctrl or KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        assertEquals(AppShortcut.OVERVIEW, AppShortcut.match(KeyEvent.KEYCODE_1, ctrl))
        assertEquals(AppShortcut.TERMINAL, AppShortcut.match(KeyEvent.KEYCODE_2, ctrl))
        assertEquals(AppShortcut.SCREEN, AppShortcut.match(KeyEvent.KEYCODE_3, ctrl))
        assertEquals(AppShortcut.SETTINGS, AppShortcut.match(KeyEvent.KEYCODE_4, ctrl))
        assertEquals(AppShortcut.NEW_SESSION, AppShortcut.match(KeyEvent.KEYCODE_T, ctrlShift))
        assertEquals(AppShortcut.PASTE, AppShortcut.match(KeyEvent.KEYCODE_V, ctrlShift))
        assertEquals(AppShortcut.COPY_SCREEN, AppShortcut.match(KeyEvent.KEYCODE_C, ctrlShift))
        assertEquals(AppShortcut.BIGGER_TEXT, AppShortcut.match(KeyEvent.KEYCODE_EQUALS, ctrlShift))
        assertEquals(AppShortcut.BIGGER_TEXT, AppShortcut.match(KeyEvent.KEYCODE_PLUS, ctrlShift))
        assertEquals(AppShortcut.SMALLER_TEXT, AppShortcut.match(KeyEvent.KEYCODE_MINUS, ctrlShift))
    }

    @Test fun theShellsKeysStayTheShells() {
        val ctrl = KeyEvent.META_CTRL_ON
        // Ctrl+letter is the terminal's (Ctrl+C, Ctrl+T, Ctrl+V), and so are plain keys and Alt.
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_C, ctrl))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_T, ctrl))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_V, ctrl))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_MINUS, ctrl))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_1, 0))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_1, KeyEvent.META_ALT_ON))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_1, ctrl or KeyEvent.META_ALT_ON))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_1, ctrl or KeyEvent.META_META_ON))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_1, ctrl or KeyEvent.META_SHIFT_ON))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_TAB, 0))
        assertNull(AppShortcut.match(KeyEvent.KEYCODE_ESCAPE, 0))
    }

    @Test fun everyShortcutIsItsOwnKey() {
        assertEquals(AppShortcut.entries.size, AppShortcut.entries.map { it.keyCode to it.shift }.toSet().size)
        assertTrue(AppShortcut.entries.filter { it.needsTerminal }.all { it.shift })
    }
}
