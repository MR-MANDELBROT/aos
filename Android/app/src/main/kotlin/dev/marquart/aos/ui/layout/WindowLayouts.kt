package dev.marquart.aos.ui.layout

import android.app.Activity
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.currentWindowDpSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.platform.LocalDensity
import androidx.window.core.layout.WindowSizeClass
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

// Android's side of ui/layout/WindowLayout.kt: the window's size class from material3-adaptive (the window, not the
// display: split screen, freeform and desktop windows count as what they are) and the fold from Jetpack WindowManager.

/** The window's layout, following its size, the device's posture and the fold's place. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun rememberWindowLayout(activity: Activity): WindowLayout {
    val sizeClass = currentWindowAdaptiveInfo(supportLargeAndXLargeWidth = true).windowSizeClass
    val size = currentWindowDpSize()
    val density = LocalDensity.current.density
    val folding by produceState<FoldingFeature?>(null, activity) {
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).collect { info ->
            value = info.displayFeatures.filterIsInstance<FoldingFeature>().firstOrNull()
        }
    }
    val fold = folding?.let {
        foldOf(it.bounds.left, it.bounds.top, it.bounds.right, it.bounds.bottom, density,
            horizontal = it.orientation == FoldingFeature.Orientation.HORIZONTAL,
            halfOpened = it.state == FoldingFeature.State.HALF_OPENED, separating = it.isSeparating)
    }
    return WindowLayout(size.width.value, size.height.value, widthClassOf(sizeClass), heightClassOf(sizeClass), fold)
}

fun widthClassOf(sizeClass: WindowSizeClass): WidthClass = when {
    sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_LARGE_LOWER_BOUND) -> WidthClass.LARGE
    sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_EXPANDED_LOWER_BOUND) -> WidthClass.EXPANDED
    sizeClass.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND) -> WidthClass.MEDIUM
    else -> WidthClass.COMPACT
}

fun heightClassOf(sizeClass: WindowSizeClass): HeightClass = when {
    sizeClass.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_EXPANDED_LOWER_BOUND) -> HeightClass.EXPANDED
    sizeClass.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND) -> HeightClass.MEDIUM
    else -> HeightClass.COMPACT
}

/** A folding feature's bounds (the window's pixels) as the layout's fold (dp). */
fun foldOf(left: Int, top: Int, right: Int, bottom: Int, density: Float, horizontal: Boolean, halfOpened: Boolean, separating: Boolean): Fold =
    Fold(left / density, top / density, right / density, bottom / density, horizontal, halfOpened, separating)
