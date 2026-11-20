package dev.marquart.aos.ui.layout

import androidx.compose.runtime.compositionLocalOf

/** The window's width in Material's classes (Android's WindowSizeClass breakpoints: 600, 840, 1200 dp). */
enum class WidthClass { COMPACT, MEDIUM, EXPANDED, LARGE }

/** The window's height (480, 900 dp). */
enum class HeightClass { COMPACT, MEDIUM, EXPANDED }

/** Where the tabs are: a bar at the bottom, a rail at the side, or a drawer that stays open. */
enum class Navigation { BAR, RAIL, DRAWER }

/**
 * A fold or hinge across the window (Jetpack WindowManager's FoldingFeature), in the window's dp from its top left.
 * `horizontal`: it runs from left to right (the halves are above and below it). `halfOpened`: the device stands like
 * a laptop or a book. `separating`: nothing should straddle it (half opened, or a hinge that hides pixels).
 */
data class Fold(
    val left: Float, val top: Float, val right: Float, val bottom: Float,
    val horizontal: Boolean, val halfOpened: Boolean, val separating: Boolean,
)

/**
 * What the window is like, and what the layout does with it. The decisions are here (and tested in
 * WindowLayoutTests), the views only ask: Android makes one from `currentWindowAdaptiveInfo()` and the folding
 * feature (app/.../ui/layout/WindowLayouts.kt), the desktop from its window's size.
 */
data class WindowLayout(
    val widthDp: Float,
    val heightDp: Float,
    val width: WidthClass = widthClass(widthDp),
    val height: HeightClass = heightClass(heightDp),
    val fold: Fold? = null,
    /** The least the window gets (the desktop always has its rail). */
    val minimumNavigation: Navigation = Navigation.BAR,
) {
    /** Compact: the bar. Medium and expanded: the rail. Large (1200 dp and more) and not flat: the open drawer. */
    val navigation: Navigation
        get() {
            val byWidth = when (width) {
                WidthClass.COMPACT -> Navigation.BAR
                WidthClass.MEDIUM, WidthClass.EXPANDED -> Navigation.RAIL
                WidthClass.LARGE -> if (height == HeightClass.COMPACT) Navigation.RAIL else Navigation.DRAWER
            }
            return if (byWidth.ordinal < minimumNavigation.ordinal) minimumNavigation else byWidth
        }

    /** The width the navigation takes at the side. */
    val navigationWidthDp: Float
        get() = when (navigation) {
            Navigation.BAR -> 0f
            Navigation.RAIL -> RAIL_WIDTH
            Navigation.DRAWER -> DRAWER_WIDTH
        }

    /** What is left for a tab's content. */
    val contentWidthDp: Float get() = (widthDp - navigationWidthDp).coerceAtLeast(0f)

    /** A fold nothing should straddle, running top to bottom: the panes go to its sides (a book). */
    val bookFold: Fold? get() = fold?.takeIf { it.separating && !it.horizontal }

    /** A fold nothing should straddle, running left to right: content above, controls below (a laptop). */
    val tableFold: Fold? get() = fold?.takeIf { it.separating && it.horizontal }

    /** The device stands on its lower half: the picture or the terminal above the fold, the keys below. */
    val isTabletop: Boolean get() = fold?.let { it.horizontal && it.halfOpened } == true

    /**
     * A list and its detail side by side: expanded width and a height that isn't a phone on its side, or a book's
     * two halves wide enough for a pane each.
     */
    val twoPane: Boolean
        get() {
            val book = bookFold
            if (book != null) return book.left - navigationWidthDp >= MIN_PANE && widthDp - book.right >= MIN_PANE
            return width >= WidthClass.EXPANDED && height != HeightClass.COMPACT
        }

    /** The list pane's width beside its detail (a book's fold decides it instead: TwoPane). */
    val listPaneDp: Float get() = (contentWidthDp * 0.38f).coerceIn(320f, 420f)

    /** The Overview's cards in columns. */
    val overviewColumns: Int
        get() = when {
            bookFold != null -> if (twoPane) 2 else 1
            contentWidthDp >= 1280f -> 3
            contentWidthDp >= 680f -> 2
            else -> 1
        }

    /** Questions and settings as a dialog in the middle instead of a sheet from the bottom edge. */
    val dialogSheets: Boolean get() = width >= WidthClass.MEDIUM && height >= HeightClass.MEDIUM

    companion object {
        /** Material's rail is 80 dp; the longest tab name ("Einstellungen") needs a little more. */
        const val RAIL_WIDTH = 88f
        const val DRAWER_WIDTH = 240f
        const val MIN_PANE = 280f

        /** A page's text and forms don't get wider than this (they sit in the middle of what is left). */
        const val MAX_PAGE_WIDTH = 720f

        fun widthClass(dp: Float): WidthClass = when {
            dp < 600f -> WidthClass.COMPACT
            dp < 840f -> WidthClass.MEDIUM
            dp < 1200f -> WidthClass.EXPANDED
            else -> WidthClass.LARGE
        }

        fun heightClass(dp: Float): HeightClass = when {
            dp < 480f -> HeightClass.COMPACT
            dp < 900f -> HeightClass.MEDIUM
            else -> HeightClass.EXPANDED
        }

        /** A phone held upright, for where nothing says otherwise (previews, tests). */
        val Phone = WindowLayout(411f, 891f)
    }
}

/** The window's layout where the views are (AosRoot provides it). */
val LocalWindowLayout = compositionLocalOf { WindowLayout.Phone }
