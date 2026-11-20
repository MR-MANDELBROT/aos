package dev.marquart.aos.ui

import dev.marquart.aos.ui.layout.Fold
import dev.marquart.aos.ui.layout.HeightClass
import dev.marquart.aos.ui.layout.Navigation
import dev.marquart.aos.ui.layout.WidthClass
import dev.marquart.aos.ui.layout.WindowLayout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The layout's decisions: which window gets which navigation, panes, columns and sheets. */
class WindowLayoutTests {
    private val phone = WindowLayout(411f, 891f)
    private val phoneOnItsSide = WindowLayout(891f, 411f)
    private val tabletUpright = WindowLayout(800f, 1280f)
    private val tablet = WindowLayout(1280f, 800f)
    private val unfolded = WindowLayout(841f, 701f)
    private val splitScreenHalf = WindowLayout(636f, 800f)
    private val splitScreenThird = WindowLayout(420f, 800f)

    @Test fun sizeClassesHaveMaterialsBreakpoints() {
        assertEquals(WidthClass.COMPACT, WindowLayout.widthClass(599.9f))
        assertEquals(WidthClass.MEDIUM, WindowLayout.widthClass(600f))
        assertEquals(WidthClass.MEDIUM, WindowLayout.widthClass(839f))
        assertEquals(WidthClass.EXPANDED, WindowLayout.widthClass(840f))
        assertEquals(WidthClass.LARGE, WindowLayout.widthClass(1200f))
        assertEquals(HeightClass.COMPACT, WindowLayout.heightClass(479f))
        assertEquals(HeightClass.MEDIUM, WindowLayout.heightClass(480f))
        assertEquals(HeightClass.EXPANDED, WindowLayout.heightClass(900f))
    }

    @Test fun navigationFollowsTheWidth() {
        assertEquals(Navigation.BAR, phone.navigation)
        assertEquals(Navigation.RAIL, tabletUpright.navigation)
        assertEquals(Navigation.RAIL, unfolded.navigation)
        assertEquals(Navigation.DRAWER, tablet.navigation)
        // A phone on its side is wide but flat: the rail, never the drawer.
        assertEquals(Navigation.RAIL, phoneOnItsSide.navigation)
        assertEquals(Navigation.RAIL, WindowLayout(1300f, 420f).navigation)
        // A tablet's window in split screen is what its own size says.
        assertEquals(Navigation.RAIL, splitScreenHalf.navigation)
        assertEquals(Navigation.BAR, splitScreenThird.navigation)
    }

    @Test fun theDesktopAlwaysHasAtLeastItsRail() {
        assertEquals(Navigation.RAIL, WindowLayout(520f, 700f, minimumNavigation = Navigation.RAIL).navigation)
        assertEquals(Navigation.RAIL, WindowLayout(1100f, 760f, minimumNavigation = Navigation.RAIL).navigation)
        assertEquals(Navigation.DRAWER, WindowLayout(1400f, 900f, minimumNavigation = Navigation.RAIL).navigation)
    }

    @Test fun contentIsWhatTheNavigationLeaves() {
        assertEquals(411f, phone.contentWidthDp)
        assertEquals(800f - WindowLayout.RAIL_WIDTH, tabletUpright.contentWidthDp)
        assertEquals(1280f - WindowLayout.DRAWER_WIDTH, tablet.contentWidthDp)
    }

    @Test fun twoPanesNeedAnExpandedWindowThatIsNotFlat() {
        assertFalse(phone.twoPane)
        assertFalse(tabletUpright.twoPane, "medium width: one pane beside the rail")
        assertTrue(tablet.twoPane)
        assertTrue(unfolded.twoPane)
        assertFalse(phoneOnItsSide.twoPane, "a phone on its side keeps one pane (the terminal needs the width)")
        assertFalse(splitScreenHalf.twoPane)
        assertTrue(WindowLayout(1100f, 760f, minimumNavigation = Navigation.RAIL).twoPane, "the desktop's first window")
    }

    @Test fun theListPaneKeepsAReadableWidth() {
        assertEquals(320f, WindowLayout(840f, 700f).listPaneDp)
        assertEquals((1040f * 0.38f), tablet.listPaneDp)
        assertEquals(420f, WindowLayout(1800f, 1000f).listPaneDp)
    }

    @Test fun theOverviewsColumns() {
        assertEquals(1, phone.overviewColumns)
        assertEquals(1, splitScreenHalf.overviewColumns)
        assertEquals(2, tabletUpright.overviewColumns)
        assertEquals(2, unfolded.overviewColumns)
        assertEquals(2, tablet.overviewColumns)
        assertEquals(2, phoneOnItsSide.overviewColumns)
        assertEquals(3, WindowLayout(1600f, 1000f).overviewColumns)
    }

    @Test fun questionsAreADialogInALargeWindow() {
        assertFalse(phone.dialogSheets)
        assertFalse(phoneOnItsSide.dialogSheets, "no room for a dialog in a flat window")
        assertTrue(tabletUpright.dialogSheets)
        assertTrue(tablet.dialogSheets)
        assertTrue(unfolded.dialogSheets)
        assertTrue(splitScreenHalf.dialogSheets)
        assertFalse(splitScreenThird.dialogSheets)
    }

    @Test fun aFlatFoldChangesNothing() {
        val flat = unfolded.copy(fold = Fold(420f, 0f, 420f, 701f, horizontal = false, halfOpened = false, separating = false))
        assertNull(flat.bookFold)
        assertNull(flat.tableFold)
        assertFalse(flat.isTabletop)
        assertTrue(flat.twoPane)
        assertEquals(unfolded.listPaneDp, flat.listPaneDp)
    }

    @Test fun tabletopPutsTheKeysBelowTheFold() {
        val table = WindowLayout(701f, 841f, fold = Fold(0f, 420f, 701f, 420f, horizontal = true, halfOpened = true, separating = true))
        assertTrue(table.isTabletop)
        assertNotNull(table.tableFold)
        assertNull(table.bookFold)
        // A flip phone standing on its lower half is still a compact window with its bar.
        val flip = WindowLayout(412f, 900f, fold = Fold(0f, 450f, 412f, 450f, horizontal = true, halfOpened = true, separating = true))
        assertTrue(flip.isTabletop)
        assertEquals(Navigation.BAR, flip.navigation)
    }

    @Test fun aBookHasAPaneOnEachSideOfItsFold() {
        val book = unfolded.copy(fold = Fold(420f, 0f, 421f, 701f, horizontal = false, halfOpened = true, separating = true))
        assertNotNull(book.bookFold)
        assertFalse(book.isTabletop)
        assertTrue(book.twoPane)
        assertEquals(2, book.overviewColumns)
        // A hinge that hides pixels separates even when the device lies flat (two screens).
        val dual = WindowLayout(1114f, 720f, fold = Fold(540f, 0f, 574f, 720f, horizontal = false, halfOpened = false, separating = true))
        assertTrue(dual.twoPane)
        // A fold too close to the rail leaves no room for a pane beside it: one pane.
        val narrow = WindowLayout(700f, 600f, fold = Fold(300f, 0f, 300f, 600f, horizontal = false, halfOpened = true, separating = true))
        assertFalse(narrow.twoPane)
        assertEquals(1, narrow.overviewColumns)
    }

    @Test fun pagesForgetTheirScrollPositionWhenTheyArePopped() {
        val removed = mutableListOf<String>()
        val stack = PageStack<String> { removed += it }
        stack.push("a")
        stack.push("b")
        stack.pop()
        assertEquals(listOf("b"), removed)
        stack.set("a", "c")
        assertEquals(listOf("b"), removed, "a stays, c is new")
        stack.set()
        assertEquals(listOf("b", "a", "c"), removed)
        stack.pop()
        assertEquals(3, removed.size)
    }
}
