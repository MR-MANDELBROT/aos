package dev.marquart.aos.ui.layout

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.marquart.aos.ui.theme.AosTheme

/**
 * A list and its detail side by side. The list has the layout's width (`listWidth` to say otherwise); on a device
 * that stands like a book the panes go to the sides of the fold, and nothing is under the hinge.
 */
@Composable
fun TwoPane(
    modifier: Modifier = Modifier,
    listWidth: Dp? = null,
    list: @Composable BoxScope.() -> Unit,
    detail: @Composable BoxScope.() -> Unit,
) {
    val layout = LocalWindowLayout.current
    val density = LocalDensity.current
    // Where this starts in the window (beside the rail or the drawer): the fold's place is the window's.
    var left by remember { mutableFloatStateOf(layout.navigationWidthDp) }
    val book = layout.bookFold
    val first = if (book != null) (book.left - left).coerceAtLeast(WindowLayout.MIN_PANE).dp else listWidth ?: layout.listPaneDp.dp
    val gap = if (book != null) (book.right - book.left).dp else 0.dp
    Row(modifier.fillMaxSize().onGloballyPositioned { left = with(density) { it.positionInWindow().x.toDp().value } }) {
        Box(Modifier.width(first).fillMaxHeight(), content = list)
        if (gap > 0.dp) Spacer(Modifier.width(gap))
        else Box(Modifier.width(1.dp).fillMaxHeight().background(AosTheme.colors.separator))
        Box(Modifier.weight(1f).fillMaxHeight(), content = detail)
    }
}

/**
 * Cards in columns side by side (the Overview in a wide window): equal widths, or, with two of them on a device that
 * stands like a book, to the sides of its fold.
 */
@Composable
fun Columns(count: Int, spacing: Dp, modifier: Modifier = Modifier, column: @Composable ColumnScope.(Int) -> Unit) {
    val layout = LocalWindowLayout.current
    val density = LocalDensity.current
    var left by remember { mutableFloatStateOf(layout.navigationWidthDp) }
    val book = layout.bookFold?.takeIf { count == 2 }
    Row(modifier.fillMaxWidth().onGloballyPositioned { left = with(density) { it.positionInWindow().x.toDp().value } },
        horizontalArrangement = Arrangement.spacedBy(if (book != null) 0.dp else spacing)) {
        for (index in 0 until count) {
            val width = if (book != null && index == 0) Modifier.width((book.left - left - spacing.value / 2).coerceAtLeast(120f).dp) else Modifier.weight(1f)
            Column(width, verticalArrangement = Arrangement.spacedBy(spacing)) { column(index) }
            if (book != null && index == 0) Spacer(Modifier.width((book.right - book.left).dp + spacing))
        }
    }
}

/** In the detail pane while nothing is chosen. */
@Composable
fun PanePlaceholder(icon: ImageVector, text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Column(modifier.fillMaxSize().background(AosTheme.colors.background).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(icon, contentDescription = null, tint = AosTheme.colors.tertiary, modifier = Modifier.size(48.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge, color = AosTheme.colors.secondary, textAlign = TextAlign.Center)
        action?.invoke()
    }
}

/**
 * A sheet for a question or for settings: from the bottom edge on a phone, a dialog in the middle of a large window
 * (above the fold when the device stands on its lower half).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdaptiveSheet(
    onDismiss: () -> Unit,
    containerColor: Color = AosTheme.colors.background,
    sheetState: SheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    content: @Composable ColumnScope.() -> Unit,
) {
    val layout = LocalWindowLayout.current
    if (!layout.dialogSheets) {
        ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = containerColor, dragHandle = null,
            content = content)
        return
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val table = layout.tableFold
        Box(Modifier.fillMaxSize().clickable(interactionSource = null, indication = null, onClick = onDismiss)) {
            Box(
                Modifier.fillMaxWidth().then(if (table != null) Modifier.height(table.top.coerceAtLeast(240f).dp) else Modifier.fillMaxHeight())
                    .windowInsetsPadding(WindowInsets.safeDrawing).padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Surface(
                    Modifier.widthIn(max = SHEET_DIALOG_WIDTH).fillMaxWidth().clickable(interactionSource = null, indication = null) {},
                    shape = RoundedCornerShape(28.dp), color = containerColor, shadowElevation = 12.dp,
                    // In the dark the dialog's black needs an edge against the dimmed window behind it.
                    border = if (AosTheme.colors.isDark) BorderStroke(1.dp, AosTheme.colors.separator) else null,
                ) {
                    Column(Modifier.padding(vertical = 8.dp), content = content)
                }
            }
        }
    }
}

val SHEET_DIALOG_WIDTH = 560.dp

/** A click with the mouse's or trackpad's secondary button: where a long press opens a menu, this opens it too. */
fun Modifier.contextClick(onClick: () -> Unit): Modifier = pointerInput(onClick) {
    awaitPointerEventScope {
        while (true) {
            // Before the row's own click: a secondary click isn't a tap.
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.type == PointerEventType.Press && event.buttons.isSecondaryPressed) {
                event.changes.forEach { it.consume() }
                onClick()
            }
        }
    }
}
