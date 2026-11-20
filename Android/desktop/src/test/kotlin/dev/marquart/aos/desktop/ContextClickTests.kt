package dev.marquart.aos.desktop

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import dev.marquart.aos.ui.layout.contextClick
import kotlin.test.Test
import kotlin.test.assertEquals

/** The shared UI's secondary click (mouse, trackpad): it opens what a long press opens, and it is no tap. */
class ContextClickTests {
    @OptIn(ExperimentalComposeUiApi::class, ExperimentalFoundationApi::class)
    @Test fun aSecondaryClickOpensTheMenuAndIsNoTap() {
        var menus = 0
        var taps = 0
        val scene = ImageComposeScene(200, 200, Density(1f)) {
            Box(Modifier.size(200.dp).contextClick { menus++ }.combinedClickable(onClick = { taps++ }, onLongClick = { menus += 100 }))
        }
        try {
            scene.render()
            val at = Offset(60f, 60f)
            scene.sendPointerEvent(PointerEventType.Move, at)
            scene.sendPointerEvent(PointerEventType.Press, at, buttons = PointerButtons(isSecondaryPressed = true), button = PointerButton.Secondary)
            scene.sendPointerEvent(PointerEventType.Release, at, buttons = PointerButtons(), button = PointerButton.Secondary)
            scene.render()
            assertEquals(1, menus, "the secondary click opened the menu once")
            assertEquals(0, taps, "and wasn't taken for a tap")
            scene.sendPointerEvent(PointerEventType.Press, at, buttons = PointerButtons(isPrimaryPressed = true), button = PointerButton.Primary)
            scene.sendPointerEvent(PointerEventType.Release, at, buttons = PointerButtons(), button = PointerButton.Primary)
            scene.render()
            assertEquals(1, taps, "a primary click still taps")
            assertEquals(1, menus)
        } finally {
            scene.close()
        }
    }
}
