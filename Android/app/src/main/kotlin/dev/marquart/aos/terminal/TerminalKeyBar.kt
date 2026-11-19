package dev.marquart.aos.terminal

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.OpenWith
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.marquart.aos.R
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The keys above the keyboard (iOS TerminalKeyBar): only what the phone's keyboard lacks. One row that scrolls as a
 * whole and snaps to keys. At its start the arrows sit in the middle of the screen (the swipe pad, or four keys:
 * TerminalSettings), Esc, Control and Tab to their left (more in landscape), Alt, Shift-Tab, paste, Home, End, Page Up,
 * Page Down, forward delete and F1 to F12 to their right. Every key is equally wide (KeyBarLayout). Modifiers stick for
 * the next key (tap), lock (double tap) or work while held. A drag that starts on the pad sends arrows instead of
 * scrolling the row.
 */
@Composable
fun TerminalKeyBar(terminal: MacTerminal, arrows: TerminalArrowKeys, onPaste: () -> Unit, modifier: Modifier = Modifier) {
    val modifierStates by terminal.modifierStates.collectAsState()
    val barName = stringResource(R.string.term_keys)
    BoxWithConstraints(modifier.fillMaxWidth().height(BAR_HEIGHT.dp).padding(horizontal = 8.dp, vertical = 4.dp)) {
        val layout = remember(maxWidth, arrows) { KeyBarLayout.of(maxWidth.value, arrows) }
        val state = rememberLazyListState()
        LaunchedEffect(layout) { state.scrollToItem(0) }
        val items = remember(layout, arrows) { barItems(layout, arrows) }
        LazyRow(
            state = state,
            flingBehavior = rememberSnapFlingBehavior(state),
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                .drawWithContent {
                    drawContent()
                    // A light edge only where more keys are: at rest the row starts and ends with whole keys.
                    val edge = (10.dp.toPx() / size.width).coerceAtMost(0.2f)
                    val left = if (state.canScrollBackward) 0.45f else 1f
                    val right = if (state.canScrollForward) 0.45f else 1f
                    drawRect(Brush.horizontalGradient(0f to Color.Black.copy(alpha = left), edge to Color.Black,
                        1 - edge to Color.Black, 1f to Color.Black.copy(alpha = right)), blendMode = BlendMode.DstIn)
                }
                .semantics { contentDescription = barName },
        ) {
            items(items.size) { index ->
                val item = items[index]
                Box(Modifier.width(item.width.dp).fillMaxHeight()) {
                    when (item) {
                        is BarItem.Key -> KeyButton(item, terminal)
                        is BarItem.ModifierKey -> ModifierButton(item.modifier, modifierStates[item.modifier.bits] ?: StickyModifiers.State.OFF, terminal)
                        is BarItem.Paste -> PasteButton(onPaste)
                        is BarItem.Pad -> ArrowPadButton(terminal)
                    }
                }
            }
        }
    }
}

const val BAR_HEIGHT = 58

private sealed class BarItem(val width: Float) {
    class Key(val key: TerminalKey, val label: String, val icon: ImageVector? = null, val extra: TerminalModifiers = TerminalModifiers.NONE,
              val repeats: Boolean = false, val name: Int, width: Float) : BarItem(width)
    class ModifierKey(val modifier: TerminalModifiers, width: Float) : BarItem(width)
    class Paste(width: Float) : BarItem(width)
    class Pad(width: Float) : BarItem(width)
}

/** In this order from the left; the first ones fill the half left of the arrows. */
private fun barItems(layout: KeyBarLayout, arrows: TerminalArrowKeys): List<BarItem> {
    val w = layout.keyWidth
    val all: List<BarItem> = listOf(
        BarItem.Key(TerminalKey.Escape, "esc", name = R.string.term_key_escape, width = w),
        BarItem.ModifierKey(TerminalModifiers.CONTROL, w),
        BarItem.Key(TerminalKey.Tab, "tab", name = R.string.term_key_tab, width = w),
        BarItem.ModifierKey(TerminalModifiers.ALT, w),
        BarItem.Key(TerminalKey.Tab, "⇧tab", extra = TerminalModifiers.SHIFT, name = R.string.term_key_shift_tab, width = w),
        BarItem.Paste(w),
        BarItem.Key(TerminalKey.Home, "home", name = R.string.term_key_home, width = w),
        BarItem.Key(TerminalKey.End, "end", name = R.string.term_key_end, width = w),
        BarItem.Key(TerminalKey.PageUp, "pg↑", repeats = true, name = R.string.term_key_page_up, width = w),
        BarItem.Key(TerminalKey.PageDown, "pg↓", repeats = true, name = R.string.term_key_page_down, width = w),
        BarItem.Key(TerminalKey.ForwardDelete, "del", repeats = true, name = R.string.term_key_delete_forward, width = w),
    ) + (1..12).map { BarItem.Key(TerminalKey.Function(it), "F$it", name = 0, width = w) }
    val center: List<BarItem> = when (arrows) {
        TerminalArrowKeys.PAD -> listOf(BarItem.Pad(layout.centerWidth))
        // ← ↑ → ↓, as on the iPhone.
        TerminalArrowKeys.FOUR_KEYS -> listOf(
            BarItem.Key(TerminalKey.Left, "←", Icons.AutoMirrored.Rounded.ArrowBack, repeats = true, name = R.string.term_key_left, width = w),
            BarItem.Key(TerminalKey.Up, "↑", Icons.Rounded.ArrowUpward, repeats = true, name = R.string.term_key_up, width = w),
            BarItem.Key(TerminalKey.Right, "→", Icons.AutoMirrored.Rounded.ArrowForward, repeats = true, name = R.string.term_key_right, width = w),
            BarItem.Key(TerminalKey.Down, "↓", Icons.Rounded.ArrowDownward, repeats = true, name = R.string.term_key_down, width = w),
        )
    }
    return all.take(layout.leading) + center + all.drop(layout.leading)
}

/** A key's plate: rounded, inset 3 dp, gives way a little while pressed. */
@Composable
private fun Plate(pressed: Boolean, on: Boolean = false, accent: Boolean = false, content: @Composable () -> Unit) {
    val scale by animateFloatAsState(if (pressed) 0.94f else 1f, tween(if (pressed) 60 else 180), label = "key")
    val colors = MaterialTheme.colorScheme
    val fill = when {
        on -> colors.primary
        pressed -> colors.onSurface.copy(alpha = 0.22f)
        accent -> colors.primary.copy(alpha = 0.16f)
        else -> colors.onSurface.copy(alpha = 0.08f)
    }
    Box(
        Modifier.fillMaxSize().padding(3.dp).scale(scale).clip(RoundedCornerShape(12.dp)).background(fill),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
private fun KeyLabel(text: String, color: Color) {
    Text(text, color = color, fontSize = if (text.length == 1) 19.sp else 15.sp, fontWeight = FontWeight.Medium, maxLines = 1)
}

@Composable
private fun KeyButton(item: BarItem.Key, terminal: MacTerminal) {
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var pressed by remember { mutableStateOf(false) }
    val name = if (item.name != 0) stringResource(item.name) else item.label
    Box(
        Modifier.fillMaxSize()
            .semantics { contentDescription = name; role = Role.Button }
            .pointerInput(item) {
                detectTapGestures(onPress = {
                    pressed = true
                    haptics.performHapticFeedback(HapticFeedbackType.KeyboardTap)
                    var fired = false
                    var repeat: Job? = null
                    if (item.repeats) {
                        // Held: the first repeat after 0.4 s, then 14 a second.
                        repeat = scope.launch {
                            delay(400)
                            while (true) {
                                fired = true
                                terminal.sendKey(item.key, item.extra)
                                delay(70)
                            }
                        }
                    }
                    val released = tryAwaitRelease()
                    repeat?.cancel()
                    pressed = false
                    if (released && !fired) terminal.sendKey(item.key, item.extra)
                })
            },
    ) {
        Plate(pressed) {
            val ink = MaterialTheme.colorScheme.onSurface
            if (item.icon != null) Icon(item.icon, contentDescription = null, tint = ink, modifier = Modifier.size(20.dp))
            else KeyLabel(item.label, ink)
        }
    }
}

@Composable
private fun ModifierButton(modifier: TerminalModifiers, state: StickyModifiers.State, terminal: MacTerminal) {
    val haptics = LocalHapticFeedback.current
    var pressed by remember { mutableStateOf(false) }
    val label = when (modifier) {
        TerminalModifiers.CONTROL -> "ctrl"
        TerminalModifiers.ALT -> "alt"
        else -> "shift"
    }
    val name = stringResource(if (modifier == TerminalModifiers.CONTROL) R.string.term_key_control else R.string.term_key_alt)
    val stateText = stringResource(when (state) {
        StickyModifiers.State.OFF -> R.string.term_modifier_off
        StickyModifiers.State.ONCE -> R.string.term_modifier_once
        StickyModifiers.State.LOCKED -> R.string.term_modifier_locked
    })
    val on = state != StickyModifiers.State.OFF
    Box(
        Modifier.fillMaxSize()
            .semantics { contentDescription = name; stateDescription = stateText; role = Role.Switch }
            .pointerInput(modifier) {
                detectTapGestures(onPress = {
                    pressed = true
                    terminal.pressModifier(modifier)
                    val released = tryAwaitRelease()
                    pressed = false
                    terminal.releaseModifier(modifier, cancelled = !released) { new ->
                        haptics.performHapticFeedback(if (new == StickyModifiers.State.LOCKED) HapticFeedbackType.LongPress
                            else HapticFeedbackType.SegmentTick)
                    }
                })
            },
    ) {
        Plate(pressed, on = on) {
            val ink = if (on) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
            KeyLabel(label, ink)
            if (state == StickyModifiers.State.LOCKED) {
                Box(Modifier.align(Alignment.BottomCenter).offset(y = (-5).dp).size(16.dp, 3.dp)
                    .clip(RoundedCornerShape(1.5.dp)).background(ink))
            }
        }
    }
}

@Composable
private fun PasteButton(onPaste: () -> Unit) {
    val haptics = LocalHapticFeedback.current
    var pressed by remember { mutableStateOf(false) }
    val name = stringResource(R.string.term_paste)
    Box(
        Modifier.fillMaxSize()
            .semantics { contentDescription = name; role = Role.Button }
            .pointerInput(Unit) {
                detectTapGestures(onPress = {
                    pressed = true
                    haptics.performHapticFeedback(HapticFeedbackType.KeyboardTap)
                    val released = tryAwaitRelease()
                    pressed = false
                    if (released) onPaste()
                })
            },
    ) {
        Plate(pressed) {
            Icon(Icons.Rounded.ContentPaste, contentDescription = null, tint = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.size(20.dp))
        }
    }
}

/** The swipe pad: drag from it towards a direction to send arrows; the farther the drag, the faster they repeat. */
@Composable
private fun ArrowPadButton(terminal: MacTerminal) {
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current.density
    var current by remember { mutableStateOf<TerminalKey?>(null) }
    var tracking by remember { mutableStateOf(false) }
    val name = stringResource(R.string.term_arrow_pad)
    val hint = stringResource(R.string.term_arrow_pad_hint)
    Box(
        Modifier.fillMaxSize()
            .semantics { contentDescription = "$name. $hint" }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    tracking = true
                    var distance = 0f
                    var repeat: Job? = null
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) break
                            change.consume()
                            val dx = (change.position.x - down.position.x) / density
                            val dy = (change.position.y - down.position.y) / density
                            distance = kotlin.math.hypot(dx, dy)
                            val key = ArrowPad.key(dx, dy)
                            if (key != current) {
                                current = key
                                repeat?.cancel()
                                if (key != null) {
                                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                                    terminal.sendKey(key)
                                    repeat = scope.launch {
                                        delay((ArrowPad.FIRST_REPEAT * 1000).toLong())
                                        while (true) {
                                            terminal.sendKey(key)
                                            delay((ArrowPad.repeatInterval(distance) * 1000).toLong())
                                        }
                                    }
                                }
                            }
                        }
                    } finally {
                        repeat?.cancel()
                        current = null
                        tracking = false
                    }
                }
            },
    ) {
        Plate(pressed = false, accent = true, on = false) {
            val icon = when (current) {
                TerminalKey.Up -> Icons.Rounded.ArrowUpward
                TerminalKey.Down -> Icons.Rounded.ArrowDownward
                TerminalKey.Left -> Icons.AutoMirrored.Rounded.ArrowBack
                TerminalKey.Right -> Icons.AutoMirrored.Rounded.ArrowForward
                else -> Icons.Rounded.OpenWith
            }
            Box(Modifier.fillMaxSize().background(if (tracking) MaterialTheme.colorScheme.primary.copy(alpha = 0.14f) else Color.Transparent),
                contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(24.dp))
            }
        }
    }
}
