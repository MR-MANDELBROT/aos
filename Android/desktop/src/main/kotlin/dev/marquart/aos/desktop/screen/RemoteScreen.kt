package dev.marquart.aos.desktop.screen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import dev.marquart.aos.screen.Framebuffer
import dev.marquart.aos.screen.PictureSink
import dev.marquart.aos.screen.PointerButton
import dev.marquart.aos.screen.ScreenArea
import dev.marquart.aos.screen.SessionModel
import dev.marquart.aos.screen.SessionPhase
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ColorType
import org.jetbrains.skia.Image
import org.jetbrains.skia.ImageInfo
import org.jetbrains.skia.Rect
import org.jetbrains.skia.SamplingMode
import java.awt.Cursor
import java.awt.Point
import java.awt.Toolkit
import java.awt.image.BufferedImage

/**
 * The picture of a screen session, drawn with Skia from libsharing's framebuffer (BGRA, standard mode): libsharing
 * writes into the framebuffer, each update marks its rectangle; the next frame copies the changed rows into a Skia
 * bitmap and draws it scaled to fit. The Mac's cursor comes as an image and is drawn at the pointer. The mouse and the
 * keyboard go to the Mac (DesktopKeys), the wheel scrolls there.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun RemoteScreen(session: SessionModel, modifier: Modifier = Modifier) {
    val renderer = remember(session) { FrameRenderer() }
    var frame by remember { mutableIntStateOf(0) }
    var size by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }
    val focus = remember { FocusRequester() }
    val density = LocalDensity.current.density
    val pressedKeys = remember { HashSet<Int>() }

    DisposableEffect(session) {
        session.pictureSink = object : PictureSink {
            override fun framebufferChanged(framebuffer: Framebuffer) = renderer.attach(framebuffer)
            override fun framebufferDirty(x: Int, y: Int, width: Int, height: Int) = renderer.dirty(y, height)
            override fun cursorChanged() = renderer.cursorChanged()
            override fun redraw() = renderer.dirtyAll()
            override fun videoChanged(active: Boolean) {}
        }
        onDispose { session.pictureSink = null }
    }
    // Frames: at most 60 a second, only when something changed.
    LaunchedEffect(renderer) {
        while (true) {
            kotlinx.coroutines.delay(16)
            if (renderer.takeChanged()) frame++
        }
    }
    LaunchedEffect(size, session.resolutionScale) {
        if (size.width > 0 && size.height > 0) {
            session.displayAreaChanged(ScreenArea(size.width / density.toDouble(), size.height / density.toDouble(), density.toDouble(),
                session.resolutionScale), size.width, size.height)
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }

    fun toImage(p: Offset): Offset? {
        val fit = renderer.fit(size.width.toFloat(), size.height.toFloat()) ?: return null
        return Offset(((p.x - fit.left) / fit.scale).coerceIn(0f, renderer.width - 1f), ((p.y - fit.top) / fit.scale).coerceIn(0f, renderer.height - 1f))
    }

    Canvas(
        modifier.fillMaxSize()
            .onSizeChanged { size = it }
            .pointerHoverIcon(PointerIcon(blankCursor))
            .focusRequester(focus)
            .focusable()
            .onPointerEvent(PointerEventType.Move) { e -> toImage(e.changes.first().position)?.let { session.movePointer(it.x, it.y) } }
            .onPointerEvent(PointerEventType.Press) { e ->
                focus.requestFocus()
                toImage(e.changes.first().position)?.let { session.movePointer(it.x, it.y) }
                var buttons = 0
                if (e.buttons.isPrimaryPressed) buttons = buttons or PointerButton.PRIMARY
                if (e.buttons.isSecondaryPressed) buttons = buttons or PointerButton.SECONDARY
                if (e.buttons.isTertiaryPressed) buttons = buttons or PointerButton.MIDDLE
                for (b in listOf(PointerButton.PRIMARY, PointerButton.SECONDARY, PointerButton.MIDDLE)) {
                    if (buttons and b != 0) session.press(b)
                }
            }
            .onPointerEvent(PointerEventType.Release) { e ->
                for ((b, down) in listOf(PointerButton.PRIMARY to e.buttons.isPrimaryPressed, PointerButton.SECONDARY to e.buttons.isSecondaryPressed,
                    PointerButton.MIDDLE to e.buttons.isTertiaryPressed)) {
                    if (!down) session.release(b)
                }
            }
            .onPointerEvent(PointerEventType.Scroll) { e ->
                val change = e.changes.first()
                toImage(change.position)?.let { session.movePointer(it.x, it.y) }
                session.scroll(-change.scrollDelta.x * WHEEL_PIXELS, -change.scrollDelta.y * WHEEL_PIXELS, null)
            }
            .onPreviewKeyEvent { event ->
                val code = event.key.nativeKeyCode
                val keyboard = session.keyboard
                when (event.type) {
                    KeyEventType.KeyDown -> {
                        if (code == java.awt.event.KeyEvent.VK_CAPS_LOCK) {
                            keyboard.capsLock(true)
                            return@onPreviewKeyEvent true
                        }
                        val held = DesktopKeys.held(event.isCtrlPressed, event.isAltPressed, event.isShiftPressed, event.isMetaPressed)
                        val repeat = code in pressedKeys
                        pressedKeys += code
                        keyboard.keyDown(code, held, DesktopKeys.macKey(code, held, event.utf16CodePoint), repeat)
                    }
                    KeyEventType.KeyUp -> {
                        pressedKeys -= code
                        keyboard.keyUp(code)
                    }
                    else -> false
                }
            },
    ) {
        @Suppress("UNUSED_EXPRESSION") frame
        renderer.draw(this, session)
    }
}

private const val WHEEL_PIXELS = 40f

private val blankCursor: Cursor by lazy {
    runCatching { Toolkit.getDefaultToolkit().createCustomCursor(BufferedImage(1, 1, BufferedImage.TYPE_INT_ARGB), Point(0, 0), "none") }
        .getOrDefault(Cursor.getDefaultCursor())
}

/** Keeps a Skia copy of libsharing's framebuffer, updated row ranges at a time. */
private class FrameRenderer {
    class Fit(val left: Float, val top: Float, val scale: Float)

    private val lock = Any()
    private var framebuffer: Framebuffer? = null
    private var bitmap: Bitmap? = null
    private var rows: ByteArray = ByteArray(0)
    private var dirtyTop = Int.MAX_VALUE
    private var dirtyBottom = -1
    @Volatile private var changed = true
    private var cursorImage: Image? = null
    private var cursorVersion = -1
    @Volatile private var cursorDirty = true
    val width: Int get() = framebuffer?.width ?: 1
    val height: Int get() = framebuffer?.height ?: 1

    fun attach(fb: Framebuffer) = synchronized(lock) {
        framebuffer = fb
        bitmap?.close()
        bitmap = Bitmap().apply { allocPixels(ImageInfo(fb.width, fb.height, ColorType.BGRA_8888, ColorAlphaType.OPAQUE)) }
        rows = ByteArray(fb.bytesPerRow * fb.height)
        dirtyAll()
    }

    fun dirty(y: Int, h: Int) = synchronized(lock) {
        dirtyTop = minOf(dirtyTop, y)
        dirtyBottom = maxOf(dirtyBottom, y + h)
        changed = true
    }

    fun dirtyAll() = synchronized(lock) {
        dirtyTop = 0
        dirtyBottom = framebuffer?.height ?: 0
        changed = true
    }

    fun cursorChanged() {
        cursorDirty = true
        changed = true
    }

    fun takeChanged(): Boolean = changed.also { changed = false }

    fun fit(w: Float, h: Float): Fit? {
        val fb = framebuffer ?: return null
        val scale = minOf(w / fb.width, h / fb.height)
        return Fit((w - fb.width * scale) / 2, (h - fb.height * scale) / 2, scale)
    }

    fun draw(scope: DrawScope, session: SessionModel) = synchronized(lock) {
        val canvas = scope.drawContext.canvas.nativeCanvas
        scope.drawRect(Color.Black)
        val fb = framebuffer ?: return@synchronized
        val bmp = bitmap ?: return@synchronized
        if (dirtyBottom > dirtyTop) {
            // The changed rows from libsharing's memory into the copy (libsharing may be writing: the next update repairs it).
            val top = dirtyTop.coerceIn(0, fb.height)
            val bottom = dirtyBottom.coerceIn(0, fb.height)
            val buffer = fb.pixels.duplicate()
            buffer.position(top * fb.bytesPerRow)
            buffer.get(rows, top * fb.bytesPerRow, (bottom - top) * fb.bytesPerRow)
            bmp.installPixels(bmp.imageInfo, rows, fb.bytesPerRow)
            dirtyTop = Int.MAX_VALUE
            dirtyBottom = -1
        }
        val fit = fit(scope.size.width, scope.size.height) ?: return@synchronized
        val image = Image.makeFromBitmap(bmp)
        canvas.drawImageRect(image, Rect.makeWH(fb.width.toFloat(), fb.height.toFloat()),
            Rect.makeXYWH(fit.left, fit.top, fb.width * fit.scale, fb.height * fit.scale), SamplingMode.LINEAR, null, true)
        image.close()
        // The Mac's pointer
        val cursor = session.cursor
        if (cursor != null && session.pointerVisible && session.phase == SessionPhase.Connected) {
            if (cursorDirty || cursorImage == null) {
                cursorImage?.close()
                cursorImage = Image.makeRaster(ImageInfo(cursor.width, cursor.height, ColorType.BGRA_8888, ColorAlphaType.UNPREMUL),
                    cursor.pixels, cursor.width * 4)
                cursorDirty = false
            }
            val ci = cursorImage!!
            val x = fit.left + (session.pointerX - cursor.hotspotX) * fit.scale
            val y = fit.top + (session.pointerY - cursor.hotspotY) * fit.scale
            canvas.drawImageRect(ci, Rect.makeWH(ci.width.toFloat(), ci.height.toFloat()),
                Rect.makeXYWH(x, y, ci.width * fit.scale, ci.height * fit.scale), SamplingMode.LINEAR, null, true)
        }
    }
}
