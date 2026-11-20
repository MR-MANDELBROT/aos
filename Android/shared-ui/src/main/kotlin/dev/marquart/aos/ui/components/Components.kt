package dev.marquart.aos.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import dev.marquart.aos.ui.platform.painterResource
import dev.marquart.aos.ui.platform.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.WindowInsets
import dev.marquart.aos.R
import dev.marquart.aos.ui.LocalAosUi
import dev.marquart.aos.ui.layout.WindowLayout
import dev.marquart.aos.ui.theme.AosTheme

/** A card with rounded corners on the grouped background (the iPhone's glass cards); `tint` colors it lightly. */
@Composable
fun AosCard(modifier: Modifier = Modifier, tint: Color? = null, padding: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    val colors = AosTheme.colors
    val background = if (tint == null) colors.card else blend(colors.card, tint, if (colors.isDark) 0.22f else 0.12f)
    Surface(modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), color = background) {
        Column(Modifier.padding(padding), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

fun blend(base: Color, over: Color, amount: Float): Color = Color(
    red = base.red + (over.red - base.red) * amount,
    green = base.green + (over.green - base.green) * amount,
    blue = base.blue + (over.blue - base.blue) * amount,
    alpha = 1f,
)

/** A large symbol in a tinted circle, the hero of a page. */
@Composable
fun HeroSymbol(icon: ImageVector, tint: Color = AosTheme.colors.indigo, size: Dp = 64.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(tint), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(size * 0.5f))
    }
}

@Composable
fun StatusDot(color: Color, modifier: Modifier = Modifier) {
    Box(modifier.size(9.dp).clip(CircleShape).background(color))
}

/** The width of the Overview's icon column: every row's text starts at the same place. */
val IconColumn = 30.dp

/** A row of the Overview: a symbol in the icon column, a title and a detail, something at the end. */
@Composable
fun OverviewRow(
    icon: ImageVector,
    title: String,
    modifier: Modifier = Modifier,
    detail: String? = null,
    tint: Color = AosTheme.colors.indigo,
    detailTint: Color = AosTheme.colors.secondary,
    onClick: (() -> Unit)? = null,
    accessory: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier.fillMaxWidth().then(if (onClick != null) Modifier.clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.width(IconColumn).size(24.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            if (!detail.isNullOrEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = detailTint)
        }
        accessory()
        if (onClick != null) Chevron()
    }
}

@Composable
fun Chevron() {
    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = AosTheme.colors.tertiary)
}

/** A line of the "what is where" kind: a symbol and a plain sentence. */
@Composable
fun FactRow(icon: ImageVector, text: String, tint: Color = AosTheme.colors.indigo) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.width(IconColumn).size(20.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = AosTheme.colors.secondary, modifier = Modifier.weight(1f))
    }
}

/** A letter in a tinted circle instead of a site's icon (nothing is loaded from the web). */
@Composable
fun Monogram(text: String, size: Dp = 36.dp) {
    val letter = text.trim().firstOrNull()?.uppercase() ?: "?"
    val indigo = AosTheme.colors.indigo
    Box(Modifier.size(size).clip(CircleShape).background(indigo.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
        Text(letter, color = indigo, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.45f).sp)
    }
}

/** A key or fingerprint: never hyphenated, broken into lines of fixed length when `lineLength` > 0. */
@Composable
fun KeyText(text: String, modifier: Modifier = Modifier, lineLength: Int = 0) {
    val shown = if (lineLength > 0) text.chunked(lineLength).joinToString("\n") else text
    SelectionContainer(modifier) {
        Text(shown, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall,
            maxLines = if (lineLength > 0) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis)
    }
}

/** What went wrong with the last action, under a card. */
@Composable
fun ProblemLine(text: String?) {
    if (text == null) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
        Icon(Icons.Rounded.Warning, contentDescription = null, tint = AosTheme.colors.orange, modifier = Modifier.size(18.dp))
        Text(text, style = MaterialTheme.typography.bodySmall)
    }
}

/** A notice with a symbol (a sheet's result). */
@Composable
fun NoticeCard(icon: ImageVector, text: String, tint: Color) {
    AosCard {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = tint)
            Text(text, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
        }
    }
}

/** One of the Mac's states as a small tile: a symbol, a value and a word under it. */
@Composable
fun StatusTile(icon: ImageVector, value: String, caption: String, modifier: Modifier = Modifier,
               tint: Color = AosTheme.colors.indigo, captionTint: Color = AosTheme.colors.secondary) {
    Column(
        modifier.clip(RoundedCornerShape(14.dp)).background(AosTheme.colors.gray.copy(alpha = 0.12f)).padding(vertical = 10.dp, horizontal = 2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Text(value, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(caption, style = MaterialTheme.typography.labelSmall, color = captionTint, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The app icon as rendered from the Mac's Icon Composer icon (light and dark). */
@Composable
fun AppIconImage(size: Dp = 72.dp) {
    // By the app's theme, not the system's (the demo can differ from the system).
    val art = if (AosTheme.colors.isDark) R.drawable.aos_icon_art_dark else R.drawable.aos_icon_art
    Image(painterResource(art), contentDescription = null, modifier = Modifier.size(size))
}

// Pages

/** True where a page is the detail beside its list: its title bar shows no back arrow (the list is right there). */
val LocalPaneRoot = compositionLocalOf { false }

/** A page with a title bar (back arrow when it was pushed) on the grouped background. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Page(
    title: String,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    bottom: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        containerColor = AosTheme.colors.background,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    // The first page beside its list has no way back of its own (LocalPaneRoot).
                    if (onBack != null && !LocalPaneRoot.current) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back))
                        }
                    }
                },
                actions = actions,
                colors = TopAppBarDefaults.topAppBarColors(containerColor = AosTheme.colors.background,
                    scrolledContainerColor = AosTheme.colors.background),
            )
        },
        bottomBar = bottom,
        content = content,
    )
}

/**
 * A scrolling column of sections and cards, as the iPhone's forms. In a wide window or pane it keeps a readable
 * width in the middle (the whole width scrolls). `scrollKey`: the scroll position is the page's (AosUi.scroll), so it
 * stays when the window changes its shape.
 */
@Composable
fun PageColumn(padding: PaddingValues, scrollKey: String? = null, maxWidth: Dp = WindowLayout.MAX_PAGE_WIDTH.dp,
               content: @Composable ColumnScope.() -> Unit) {
    val scroll = if (scrollKey != null) LocalAosUi.current.scroll(scrollKey) else rememberScrollState()
    Box(Modifier.fillMaxSize().padding(padding).verticalScroll(scroll), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = maxWidth).fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

/** A group of rows on a card, with a header above and a footer below (a Form's section). */
@Composable
fun Section(header: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        if (header != null) {
            Text(header, style = MaterialTheme.typography.labelLarge, color = AosTheme.colors.secondary,
                modifier = Modifier.padding(start = 16.dp, bottom = 6.dp))
        }
        Surface(shape = RoundedCornerShape(20.dp), color = AosTheme.colors.card, modifier = Modifier.fillMaxWidth()) {
            Column(content = content)
        }
        if (footer != null) {
            Text(footer, style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp))
        }
    }
}

/** A row of a section; a divider follows unless it is the last (pass `divider = false`). */
@Composable
fun SectionRow(
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    divider: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp).heightIn(min = 28.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
    if (divider) HorizontalDivider(Modifier.padding(start = 16.dp), color = AosTheme.colors.separator)
}

/** A label and its value on one row: the label as wide as it needs (at most about half), the value after it. */
@Composable
fun LabeledRow(label: String, value: String, divider: Boolean = true, valueColor: Color = AosTheme.colors.secondary) {
    SectionRow(divider = divider) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.widthIn(max = 170.dp))
        Text(value, style = MaterialTheme.typography.bodyLarge, color = valueColor, modifier = Modifier.weight(1f),
            textAlign = androidx.compose.ui.text.style.TextAlign.End)
    }
}

/** A row that opens a page. */
@Composable
fun NavRow(icon: ImageVector?, title: String, detail: String? = null, divider: Boolean = true, tint: Color = AosTheme.colors.indigo,
           selected: Boolean = false, onClick: () -> Unit) {
    // `selected`: its page is the one shown beside the list (two panes).
    SectionRow(if (selected) Modifier.background(AosTheme.colors.indigo.copy(alpha = 0.12f)) else Modifier, onClick = onClick, divider = divider) {
        if (icon != null) Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall, color = AosTheme.colors.secondary)
        }
        Chevron()
    }
}

/** A row that does something (a button in a list). */
@Composable
fun ActionRow(icon: ImageVector?, title: String, divider: Boolean = true, destructive: Boolean = false, enabled: Boolean = true,
              onClick: () -> Unit) {
    val color = when {
        !enabled -> AosTheme.colors.tertiary
        destructive -> AosTheme.colors.red
        else -> AosTheme.colors.indigo
    }
    SectionRow(onClick = onClick, enabled = enabled, divider = divider) {
        if (icon != null) Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(24.dp))
        Text(title, style = MaterialTheme.typography.bodyLarge, color = color, modifier = Modifier.weight(1f))
    }
}

/** Text in a section, as a row. */
@Composable
fun TextRow(text: String, divider: Boolean = true, color: Color = Color.Unspecified) {
    SectionRow(divider = divider) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = color, modifier = Modifier.weight(1f))
    }
}

/** A question before something that ends or removes something: its title, what happens, the action and Cancel. */
@Composable
fun ConfirmDialog(
    title: String,
    message: String?,
    confirm: String,
    destructive: Boolean = true,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = message?.let { { Text(it) } },
        confirmButton = {
            TextButton(onClick = { onDismiss(); onConfirm() }) {
                Text(confirm, color = if (destructive) AosTheme.colors.red else AosTheme.colors.indigo)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** A small spinner in a row or button. */
@Composable
fun SmallSpinner(color: Color = AosTheme.colors.indigo) {
    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = color)
}

/** Shown in a page's place while there is nothing: a symbol, a title, a line. */
@Composable
fun EmptyState(icon: ImageVector, title: String, text: String? = null) {
    Column(Modifier.fillMaxWidth().padding(vertical = 48.dp, horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, contentDescription = null, tint = AosTheme.colors.secondary, modifier = Modifier.size(44.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (text != null) Text(text, style = MaterialTheme.typography.bodyMedium, color = AosTheme.colors.secondary,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
